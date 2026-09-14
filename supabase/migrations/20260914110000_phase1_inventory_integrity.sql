-- Phase 1. Run phase1_read_only_review.sql before applying. No historical repairs.
BEGIN;
LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.products WHERE stock IS NULL OR stock < 0) THEN
    RAISE EXCEPTION 'Invalid legacy stock: review and reconcile explicitly before migrating.';
  END IF;
END $$;

CREATE TABLE public.inventory_opening_balances (
  product_id UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  quantity INTEGER NOT NULL CHECK(quantity >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.inventory_opening_balances(product_id,wholesaler_id,quantity)
SELECT id,wholesaler_id,stock FROM public.products;

-- Private transaction context. Unlike custom GUCs, clients cannot forge this context.
CREATE TABLE public.inventory_operation_context (
  transaction_id BIGINT PRIMARY KEY,
  actor_id UUID,
  movement_type TEXT NOT NULL,
  order_id UUID,
  import_run_id UUID,
  request_id UUID,
  reason TEXT
);
CREATE TABLE public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  actor_id UUID,
  order_id UUID REFERENCES public.orders(id),
  import_run_id UUID REFERENCES public.product_import_runs(id) DEFERRABLE INITIALLY DEFERRED,
  request_id UUID,
  movement_type TEXT NOT NULL CHECK(movement_type IN
    ('product_created','manual_add','manual_remove','manual_reconciliation','checkout_deduction',
     'order_cancellation_restore','import_add','import_replace','admin_adjustment')),
  quantity_delta BIGINT NOT NULL,
  quantity_before INTEGER NOT NULL CHECK(quantity_before >= 0),
  quantity_after INTEGER NOT NULL CHECK(quantity_after >= 0),
  reason TEXT,
  source_operation TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK(quantity_after::BIGINT - quantity_before = quantity_delta)
);
CREATE INDEX inventory_movements_tenant_product ON public.inventory_movements(wholesaler_id,product_id,created_at);
CREATE UNIQUE INDEX inventory_order_movement_once ON public.inventory_movements(order_id,product_id,movement_type)
WHERE movement_type IN ('checkout_deduction','order_cancellation_restore');
CREATE TABLE public.stock_adjustment_requests (
  id UUID PRIMARY KEY, actor_id UUID NOT NULL, product_id UUID NOT NULL,
  payload JSONB NOT NULL, result INTEGER
);
CREATE TABLE public.checkout_requests (
  id UUID PRIMARY KEY, actor_id UUID NOT NULL, pharmacy_id UUID NOT NULL,
  payload JSONB NOT NULL, order_count INTEGER,
  order_ids UUID[], created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DO $$ DECLARE tbl TEXT; BEGIN
  FOREACH tbl IN ARRAY ARRAY['inventory_opening_balances','inventory_operation_context','inventory_movements',
    'stock_adjustment_requests','checkout_requests'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated,service_role',tbl);
  END LOOP;
END $$;
GRANT SELECT ON public.inventory_movements,public.inventory_opening_balances TO authenticated;
CREATE POLICY inventory_history_tenant ON public.inventory_movements FOR SELECT TO authenticated USING (
  EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=wholesaler_id AND b.type='wholesaler'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IS NOT NULL)));
CREATE POLICY inventory_opening_tenant ON public.inventory_opening_balances FOR SELECT TO authenticated USING (
  EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=wholesaler_id AND b.type='wholesaler'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IS NOT NULL)));

CREATE FUNCTION public.phase1_inventory_history_immutable() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Inventory history is immutable; record a corrective operation.'; END $$;
CREATE TRIGGER inventory_history_immutable BEFORE UPDATE OR DELETE ON public.inventory_movements
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
CREATE TRIGGER inventory_opening_immutable BEFORE UPDATE OR DELETE ON public.inventory_opening_balances
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();

CREATE FUNCTION public.phase1_record_inventory() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE ctx public.inventory_operation_context%ROWTYPE; previous INTEGER;
BEGIN
  previous := CASE WHEN TG_OP='INSERT' THEN 0 ELSE OLD.stock END;
  IF TG_OP='UPDATE' AND NEW.stock=OLD.stock THEN RETURN NEW; END IF;
  SELECT * INTO ctx FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  -- New zero-stock products have a real creation baseline, not a fabricated past movement.
  IF TG_OP='INSERT' THEN
    INSERT INTO public.inventory_opening_balances(product_id,wholesaler_id,quantity) VALUES(NEW.id,NEW.wholesaler_id,0);
  END IF;
  IF NEW.stock=previous THEN RETURN NEW; END IF;
  INSERT INTO public.inventory_movements(product_id,wholesaler_id,actor_id,order_id,import_run_id,request_id,
    movement_type,quantity_delta,quantity_before,quantity_after,reason,source_operation)
  VALUES(NEW.id,NEW.wholesaler_id,coalesce(ctx.actor_id,auth.uid()),ctx.order_id,ctx.import_run_id,ctx.request_id,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_created' ELSE 'admin_adjustment' END),
    NEW.stock::BIGINT-previous,previous,NEW.stock,ctx.reason,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_insert' ELSE 'database_maintenance' END));
  RETURN NEW;
END $$;
CREATE TRIGGER phase1_inventory_movement AFTER INSERT OR UPDATE OF stock ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase1_record_inventory();
REVOKE ALL ON FUNCTION public.phase1_record_inventory(),public.phase1_inventory_history_immutable() FROM PUBLIC,anon,authenticated,service_role;

-- Clear all UPDATE grants including columns; grant only known metadata. Existing RLS stays active.
REVOKE UPDATE,DELETE,TRUNCATE ON public.products FROM PUBLIC,anon,authenticated,service_role;
DO $$ DECLARE c RECORD; BEGIN
  FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='products' LOOP
    EXECUTE format('REVOKE UPDATE(%I) ON public.products FROM PUBLIC,anon,authenticated,service_role',c.column_name);
  END LOOP;
END $$;
GRANT UPDATE(name,brand,category,form,pack_size,price_ghs,image_hue,active) ON public.products TO authenticated;

CREATE FUNCTION public.adjust_product_stock(_product_id UUID,_operation TEXT,_quantity INTEGER,
  _request_id UUID,_expected_stock INTEGER DEFAULT NULL,_reason TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.products%ROWTYPE; prior public.stock_adjustment_requests%ROWTYPE; payload JSONB; v_result INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  IF _request_id IS NULL OR _quantity IS NULL OR _quantity<0 OR _operation IS NULL
    OR _operation NOT IN ('add','remove','reconcile') OR (_operation<>'reconcile' AND _quantity=0) THEN
    RAISE EXCEPTION 'A request ID and valid nonblank stock quantity are required.';
  END IF;
  SELECT * INTO p FROM public.products WHERE id=_product_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory access denied.'; END IF;
  PERFORM 1 FROM public.businesses WHERE id=p.wholesaler_id FOR SHARE;
  IF NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p.wholesaler_id
    AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager'))) THEN
    RAISE EXCEPTION 'Inventory access denied.';
  END IF;
  payload:=jsonb_build_array(_product_id,_operation,_quantity,_expected_stock,nullif(btrim(_reason),''));
  INSERT INTO public.stock_adjustment_requests(id,actor_id,product_id,payload)
    VALUES(_request_id,auth.uid(),_product_id,payload) ON CONFLICT DO NOTHING;
  SELECT * INTO prior FROM public.stock_adjustment_requests WHERE id=_request_id FOR UPDATE;
  IF prior.actor_id<>auth.uid() OR prior.payload<>payload THEN RAISE EXCEPTION 'Stock request ID already used for different data.'; END IF;
  IF prior.result IS NOT NULL THEN RETURN prior.result; END IF;
  SELECT * INTO p FROM public.products WHERE id=_product_id FOR UPDATE;
  IF _operation='reconcile' AND (_expected_stock IS NULL OR p.stock<>_expected_stock) THEN
    RAISE EXCEPTION 'Stock changed since count preview. Refresh and confirm a new reconciliation.';
  END IF;
  v_result:=CASE _operation WHEN 'add' THEN p.stock+_quantity WHEN 'remove' THEN p.stock-_quantity ELSE _quantity END;
  IF v_result<0 THEN RAISE EXCEPTION 'Cannot remove more than available stock.'; END IF;
  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,request_id,reason)
    VALUES(txid_current(),auth.uid(),CASE _operation WHEN 'add' THEN 'manual_add' WHEN 'remove' THEN 'manual_remove' ELSE 'manual_reconciliation' END,_request_id,nullif(btrim(_reason),''));
  UPDATE public.products SET stock=v_result WHERE id=_product_id;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  UPDATE public.stock_adjustment_requests SET result=v_result WHERE id=_request_id;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.adjust_product_stock(UUID,TEXT,INTEGER,UUID,INTEGER,TEXT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.adjust_product_stock(UUID,TEXT,INTEGER,UUID,INTEGER,TEXT) TO authenticated;

-- Retire the keyless entry point; existing clients must supply a durable key.
DROP FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB);
CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _request_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
  v_request public.checkout_requests%ROWTYPE;
  v_payload JSONB;
  v_ids UUID[] := ARRAY[]::UUID[];
  v_line RECORD;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(_items) = 'array' THEN _items ELSE '[]'::jsonb END) x
    WHERE jsonb_typeof(x) <> 'object' OR coalesce(x->>'quantity', '') !~ '^[1-9][0-9]*$'
      OR nullif(x->>'productId', '') IS NULL) THEN
    RAISE EXCEPTION 'Invalid checkout item.';
  END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id FOR SHARE;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  IF _request_id IS NULL THEN RAISE EXCEPTION 'Checkout request ID is required.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('productId',product_id,'quantity',quantity) ORDER BY product_id)
    INTO v_payload FROM (SELECT (x->>'productId')::UUID product_id,sum((x->>'quantity')::BIGINT) quantity
    FROM jsonb_array_elements(_items) x GROUP BY (x->>'productId')::UUID) normalized;
  INSERT INTO public.checkout_requests(id,actor_id,pharmacy_id,payload)
    VALUES(_request_id,_caller_id,_pharmacy_id,v_payload) ON CONFLICT DO NOTHING;
  SELECT * INTO v_request FROM public.checkout_requests WHERE id=_request_id FOR UPDATE;
  IF v_request.actor_id<>_caller_id OR v_request.pharmacy_id<>_pharmacy_id OR v_request.payload<>v_payload THEN
    RAISE EXCEPTION 'Checkout request ID already used for different data or account.';
  END IF;
  IF v_request.order_count IS NOT NULL THEN RETURN v_request.order_count; END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      b.type AS wholesaler_type,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    ORDER BY p.id
    FOR UPDATE OF p FOR SHARE OF b
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' OR v_product.wholesaler_type <> 'wholesaler' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    -- All product rows stay locked; deductions follow order insertion below.

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.order_stock_deductions(order_id, product_id, wholesaler_id, quantity)
    SELECT v_order_id, product_id, wholesaler_id, quantity FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,order_id,request_id)
      VALUES(txid_current(),_caller_id,'checkout_deduction',v_order_id,_request_id);
    FOR v_line IN SELECT * FROM tmp_locked_products WHERE wholesaler_id=v_wholesaler.wholesaler_id ORDER BY product_id LOOP
      UPDATE public.products SET stock=stock-v_line.quantity WHERE id=v_line.product_id;
    END LOOP;
    DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
    v_ids:=array_append(v_ids,v_order_id);
    v_order_count := v_order_count + 1;
  END LOOP;

  UPDATE public.checkout_requests SET order_count=v_order_count,order_ids=v_ids WHERE id=_request_id;
  DROP TABLE tmp_requested_items,tmp_locked_products;
  RETURN v_order_count;
END;
$$;


REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB,UUID) TO service_role;
CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE deduction RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.order_stock_deductions WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'Legacy order has no verified stock deduction. Manual reconciliation is required.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_stock_deductions d FULL JOIN
      (SELECT product_id, sum(quantity) quantity FROM public.order_items WHERE order_id = NEW.id GROUP BY product_id) i
      ON d.product_id = i.product_id AND d.order_id = NEW.id
    WHERE (d.order_id = NEW.id OR d.order_id IS NULL)
      AND (d.product_id IS NULL OR i.product_id IS NULL OR d.quantity <> i.quantity OR d.wholesaler_id <> NEW.wholesaler_id)
  ) THEN RAISE EXCEPTION 'Order deduction evidence does not match order items.'; END IF;
  FOR deduction IN SELECT * FROM public.order_stock_deductions WHERE order_id = NEW.id ORDER BY product_id FOR UPDATE LOOP
    IF deduction.restored_at IS NOT NULL THEN RAISE EXCEPTION 'Stock was already restored.'; END IF;
    INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,order_id,reason)
      VALUES(txid_current(),auth.uid(),'order_cancellation_restore',NEW.id,NEW.cancellation_reason);
    UPDATE public.products SET stock = stock + deduction.quantity WHERE id = deduction.product_id AND wholesaler_id = deduction.wholesaler_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Deducted product supplier mismatch.'; END IF;
    DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
    UPDATE public.order_stock_deductions SET restored_at = now() WHERE order_id = deduction.order_id AND product_id = deduction.product_id;
  END LOOP;
  RETURN NEW;
END $$;


CREATE OR REPLACE FUNCTION public.preview_wholesaler_import(
  _business_id UUID, _products JSONB, _mode TEXT,
  _confirm_token TEXT DEFAULT NULL, _request_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_product public.products%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_price NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.product_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = _business_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'wholesaler' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved wholesaler account is required.';
  END IF;
  IF NOT (biz.owner_id = auth.uid() OR COALESCE(public.get_staff_role(auth.uid(), _business_id)::TEXT IN ('owner', 'manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only owners and managers can import products.';
  END IF;
  IF _mode NOT IN ('replace', 'add', 'details') OR _mode IS NULL THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(_products) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected a product array.'; END IF;
  IF jsonb_array_length(_products) = 0 OR jsonb_array_length(_products) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 products at a time.';
  END IF;
  payload_hash := md5(_products::TEXT || _mode || _business_id::TEXT);
  IF _confirm_token IS NOT NULL THEN
    IF _request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    -- Serialize commits against imports, manual edits, and order stock updates.
    -- This short transaction lock also protects missing rows (new products).
    LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.product_import_runs WHERE id = _request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.wholesaler_id <> _business_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(_products) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR nullif(btrim(item->>'name'), '') IS NULL
      OR coalesce(item->>'price_ghs', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      OR (item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$') THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Invalid name, price or stock.'));
      CONTINUE;
    END IF;
    input_price := (item->>'price_ghs')::NUMERIC;
    IF input_price <= 0 OR input_price > 99999999.99 OR COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Price or stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    identity_key := public.product_import_identity(item->>'name', item->>'brand', coalesce(nullif(item->>'form', ''), 'Tablet'), item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated product identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);
    SELECT count(*) INTO matches FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing products match. Resolve the catalogue collision first.'));
      CONTINUE;
    END IF;
    SELECT * INTO old_product FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    new_stock := CASE
      WHEN _mode = 'details' THEN coalesce(old_product.stock, 0)
      WHEN input_stock IS NULL THEN coalesce(old_product.stock, 0)
      WHEN _mode = 'add' THEN coalesce(old_product.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;
    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_product.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_product.id IS NULL THEN 'new' ELSE 'existing' END,
      'before', CASE WHEN old_product.id IS NULL THEN NULL ELSE to_jsonb(old_product) END,
      'price_before', old_product.price_ghs, 'price_after', input_price,
      'stock_before', old_product.stock, 'stock_after', new_stock,
      'product', item
    ));
  END LOOP;
  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', _mode);
  IF _confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF _confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,import_run_id,request_id)
    VALUES(txid_current(),auth.uid(),CASE WHEN _mode='add' THEN 'import_add' ELSE 'import_replace' END,_request_id,_request_id);
  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.products (wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, image_hue, active)
      VALUES (_business_id, item->>'name', nullif(btrim(item#>>'{product,brand}'), ''),
        coalesce(nullif(item#>>'{product,category}', ''), 'Other'), coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        nullif(btrim(item#>>'{product,pack_size}'), ''), (item->>'price_after')::NUMERIC, (item->>'stock_after')::INTEGER,
        coalesce((item#>>'{product,image_hue}')::INTEGER, 200), TRUE) RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.products SET name = item->>'name', brand = nullif(btrim(item#>>'{product,brand}'), ''),
        category = coalesce(nullif(item#>>'{product,category}', ''), 'Other'), form = coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        pack_size = nullif(btrim(item#>>'{product,pack_size}'), ''), price_ghs = (item->>'price_after')::NUMERIC,
        stock = (item->>'stock_after')::INTEGER, image_hue = coalesce((item#>>'{product,image_hue}')::INTEGER, 200)
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;
    PERFORM public.write_audit_log('Inventory imported', biz.name, 'product', saved_id, item->>'name',
      jsonb_build_object('request_id', _request_id, 'mode', _mode, 'before', item->'before',
        'after', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = saved_id)));
  END LOOP;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

COMMIT;
