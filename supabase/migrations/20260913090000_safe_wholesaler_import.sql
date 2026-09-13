-- Additive safe-import workflow. Existing products and order references are retained.
-- Old clients must upgrade: the previous RPC bypassed preview and confirmation.
DROP FUNCTION IF EXISTS public.import_wholesaler_products(UUID, JSONB);

CREATE OR REPLACE FUNCTION public.product_import_identity(name TEXT, brand TEXT, form TEXT, pack_size TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_build_array(
    regexp_replace(lower(coalesce(name, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(brand, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(form, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(pack_size, '')), '[^a-z0-9./+%]', '', 'g')
  )::TEXT
$$;
-- Decimal points remain significant: 2.5 mg must never match 25 mg.
CREATE INDEX products_import_identity_idx ON public.products
  (wholesaler_id, public.product_import_identity(name, brand, form, pack_size));

CREATE TABLE public.product_import_runs (
  id UUID PRIMARY KEY,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  created_by UUID NOT NULL REFERENCES auth.users(id),
  payload_hash TEXT NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.product_import_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_import_runs FROM PUBLIC, authenticated;

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
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;
