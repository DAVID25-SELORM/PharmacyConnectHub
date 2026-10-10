-- RECORD ONLY, do not run. The text of the leftover four-argument create_marketplace_orders found in production on 2026-10-10 (see drop-legacy-checkout-overload.sql).
CREATE OR REPLACE FUNCTION public.create_marketplace_orders(_caller_id uuid, _pharmacy_id uuid, _items jsonb, _request_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    INSERT INTO public.server_audit_context(transaction_id,actor_id) VALUES(txid_current(),_caller_id);
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
    DELETE FROM public.server_audit_context WHERE transaction_id=txid_current();

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
$function$
