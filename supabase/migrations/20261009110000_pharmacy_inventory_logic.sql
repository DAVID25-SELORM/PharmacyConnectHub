-- Pharmacy-owned inventory, part 2: logic.
-- create_pharmacy_inventory_item / adjust_pharmacy_inventory_stock /
-- update_pharmacy_inventory_item_details / preview_pharmacy_inventory_import.
--
-- Day-to-day item actions (create/adjust/edit) are gated at the 'process' tier (owner/manager/
-- cashier/warehouse) -- routine stock work. Bulk import is gated tighter, owner/manager only,
-- mirroring preview_wholesaler_import's own gating for the same reason: a "replace" import can
-- silently zero out stock for anything not in the uploaded file.

-- ---------------------------------------------------------------------------
-- create_pharmacy_inventory_item: add a single new tracked item.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_pharmacy_inventory_item(
  p_pharmacy_id UUID,
  p_name TEXT,
  p_brand TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_form TEXT DEFAULT NULL,
  p_pack_size TEXT DEFAULT NULL,
  p_stock INTEGER DEFAULT 0,
  p_reorder_level INTEGER DEFAULT NULL,
  p_unit_cost_ghs NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_item_id UUID;
  v_identity TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RAISE EXCEPTION 'A name is required.'; END IF;
  IF COALESCE(p_stock, 0) < 0 THEN RAISE EXCEPTION 'Stock cannot be negative.'; END IF;

  SELECT id, type, verification_status INTO v_business FROM public.businesses WHERE id = p_pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF NOT public.can_act_for_business(p_pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to manage inventory for this pharmacy.';
  END IF;

  v_identity := public.product_import_identity(p_name, p_brand, p_form, p_pack_size);
  IF EXISTS (
    SELECT 1 FROM public.pharmacy_inventory_items i
    WHERE i.pharmacy_id = p_pharmacy_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = v_identity
  ) THEN
    RAISE EXCEPTION 'This item is already tracked. Adjust its stock instead of creating a duplicate.';
  END IF;

  INSERT INTO public.pharmacy_inventory_items (pharmacy_id, name, brand, category, form, pack_size, stock, reorder_level, unit_cost_ghs)
  VALUES (p_pharmacy_id, btrim(p_name), NULLIF(btrim(p_brand), ''), NULLIF(btrim(p_category), ''),
    NULLIF(btrim(p_form), ''), NULLIF(btrim(p_pack_size), ''), COALESCE(p_stock, 0), p_reorder_level, p_unit_cost_ghs)
  RETURNING id INTO v_item_id;

  IF COALESCE(p_stock, 0) > 0 THEN
    INSERT INTO public.pharmacy_inventory_movements (item_id, pharmacy_id, kind, quantity_delta, stock_after, created_by)
    VALUES (v_item_id, p_pharmacy_id, 'receive', p_stock, p_stock, auth.uid());
  END IF;

  RETURN v_item_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- adjust_pharmacy_inventory_stock: receive more stock, correct a count, or write units off.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adjust_pharmacy_inventory_stock(
  p_item_id UUID,
  p_quantity_delta INTEGER,
  p_kind TEXT,
  p_reason TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_new_stock INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_quantity_delta IS NULL OR p_quantity_delta = 0 THEN RAISE EXCEPTION 'Enter a non-zero quantity.'; END IF;
  IF p_kind NOT IN ('receive', 'adjust', 'write_off') THEN RAISE EXCEPTION 'Invalid movement kind.'; END IF;
  IF p_kind = 'write_off' AND p_quantity_delta > 0 THEN RAISE EXCEPTION 'A write-off must reduce stock.'; END IF;
  IF p_reason IS NOT NULL AND p_reason NOT IN ('damaged', 'expired', 'count_correction', 'other') THEN
    RAISE EXCEPTION 'Invalid reason.';
  END IF;

  SELECT id, pharmacy_id, stock INTO v_item FROM public.pharmacy_inventory_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found.'; END IF;
  IF NOT public.can_act_for_business(v_item.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to manage inventory for this pharmacy.';
  END IF;

  v_new_stock := v_item.stock + p_quantity_delta;
  IF v_new_stock < 0 THEN RAISE EXCEPTION 'This would take stock below zero (currently %).', v_item.stock; END IF;

  UPDATE public.pharmacy_inventory_items SET stock = v_new_stock WHERE id = p_item_id;
  INSERT INTO public.pharmacy_inventory_movements (item_id, pharmacy_id, kind, quantity_delta, stock_after, reason, note, created_by)
  VALUES (p_item_id, v_item.pharmacy_id, p_kind, p_quantity_delta, v_new_stock, p_reason, NULLIF(btrim(p_note), ''), auth.uid());
END;
$$;

-- ---------------------------------------------------------------------------
-- update_pharmacy_inventory_item_details: edit metadata without touching stock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_pharmacy_inventory_item_details(
  p_item_id UUID,
  p_name TEXT,
  p_brand TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_form TEXT DEFAULT NULL,
  p_pack_size TEXT DEFAULT NULL,
  p_reorder_level INTEGER DEFAULT NULL,
  p_unit_cost_ghs NUMERIC DEFAULT NULL,
  p_active BOOLEAN DEFAULT true
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_identity TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN RAISE EXCEPTION 'A name is required.'; END IF;

  SELECT id, pharmacy_id INTO v_item FROM public.pharmacy_inventory_items WHERE id = p_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory item not found.'; END IF;
  IF NOT public.can_act_for_business(v_item.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to manage inventory for this pharmacy.';
  END IF;

  v_identity := public.product_import_identity(p_name, p_brand, p_form, p_pack_size);
  IF EXISTS (
    SELECT 1 FROM public.pharmacy_inventory_items i
    WHERE i.pharmacy_id = v_item.pharmacy_id AND i.id <> p_item_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = v_identity
  ) THEN
    RAISE EXCEPTION 'Another item with this same name/brand/form/pack size already exists.';
  END IF;

  UPDATE public.pharmacy_inventory_items SET
    name = btrim(p_name), brand = NULLIF(btrim(p_brand), ''), category = NULLIF(btrim(p_category), ''),
    form = NULLIF(btrim(p_form), ''), pack_size = NULLIF(btrim(p_pack_size), ''),
    reorder_level = p_reorder_level, unit_cost_ghs = p_unit_cost_ghs, active = COALESCE(p_active, true)
  WHERE id = p_item_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- preview_pharmacy_inventory_import: preview/confirm bulk import, mirroring
-- preview_wholesaler_import's shape (hash-based idempotency, server-computed confirm token that
-- invalidates if inventory changed between preview and confirm).
-- p_items shape: [{ name, brand?, category?, form?, pack_size?, stock?, unitCostGhs?, reorderLevel?, source_row? }]
-- p_mode: 'replace' (stock = input), 'add' (stock += input), 'details' (stock untouched).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.preview_pharmacy_inventory_import(
  p_pharmacy_id UUID,
  p_items JSONB,
  p_mode TEXT,
  p_confirm_token TEXT DEFAULT NULL,
  p_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_item public.pharmacy_inventory_items%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_cost NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.pharmacy_inventory_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = p_pharmacy_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'pharmacy' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved pharmacy account is required.';
  END IF;
  IF NOT public.can_act_for_business(p_pharmacy_id, 'manage') THEN
    RAISE EXCEPTION 'Only owners and managers can import inventory.';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('replace', 'add', 'details') THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected an item array.'; END IF;
  IF jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 items at a time.';
  END IF;

  payload_hash := md5(p_items::TEXT || p_mode || p_pharmacy_id::TEXT);
  IF p_confirm_token IS NOT NULL THEN
    IF p_request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    LOCK TABLE public.pharmacy_inventory_items IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.pharmacy_inventory_import_runs WHERE id = p_request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.pharmacy_id <> p_pharmacy_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR NULLIF(btrim(item->>'name'), '') IS NULL THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Missing item name.'));
      CONTINUE;
    END IF;
    IF item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$' THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Stock must be a whole number.'));
      CONTINUE;
    END IF;
    IF COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    input_cost := NULLIF(item->>'unitCostGhs', '')::NUMERIC;

    identity_key := public.product_import_identity(item->>'name', item->>'brand', item->>'form', item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated item identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);

    SELECT count(*) INTO matches FROM public.pharmacy_inventory_items i WHERE i.pharmacy_id = p_pharmacy_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing items match. Resolve the collision first.'));
      CONTINUE;
    END IF;

    SELECT * INTO old_item FROM public.pharmacy_inventory_items i WHERE i.pharmacy_id = p_pharmacy_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = identity_key;

    new_stock := CASE
      WHEN p_mode = 'details' THEN COALESCE(old_item.stock, 0)
      WHEN input_stock IS NULL THEN COALESCE(old_item.stock, 0)
      WHEN p_mode = 'add' THEN COALESCE(old_item.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;

    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_item.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_item.id IS NULL THEN 'new' ELSE 'existing' END,
      'stock_before', old_item.stock, 'stock_after', new_stock,
      'cost_before', old_item.unit_cost_ghs, 'cost_after', COALESCE(input_cost, old_item.unit_cost_ghs),
      'item', item
    ));
  END LOOP;

  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', p_mode);
  IF p_confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF p_confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.pharmacy_inventory_items (pharmacy_id, name, brand, category, form, pack_size, stock, reorder_level, unit_cost_ghs)
      VALUES (p_pharmacy_id, item->>'name', NULLIF(btrim(item#>>'{item,brand}'), ''),
        NULLIF(btrim(item#>>'{item,category}'), ''), NULLIF(btrim(item#>>'{item,form}'), ''),
        NULLIF(btrim(item#>>'{item,pack_size}'), ''), (item->>'stock_after')::INTEGER,
        NULLIF(item#>>'{item,reorderLevel}', '')::INTEGER, (item->>'cost_after')::NUMERIC)
      RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.pharmacy_inventory_items SET
        name = item->>'name', brand = NULLIF(btrim(item#>>'{item,brand}'), ''),
        category = NULLIF(btrim(item#>>'{item,category}'), ''), form = NULLIF(btrim(item#>>'{item,form}'), ''),
        pack_size = NULLIF(btrim(item#>>'{item,pack_size}'), ''), stock = (item->>'stock_after')::INTEGER,
        reorder_level = COALESCE(NULLIF(item#>>'{item,reorderLevel}', '')::INTEGER, reorder_level),
        unit_cost_ghs = (item->>'cost_after')::NUMERIC
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;

    IF COALESCE((item->>'stock_before')::INTEGER, 0) <> (item->>'stock_after')::INTEGER THEN
      INSERT INTO public.pharmacy_inventory_movements (item_id, pharmacy_id, kind, quantity_delta, stock_after, note, created_by)
      VALUES (saved_id, p_pharmacy_id, 'import', (item->>'stock_after')::INTEGER - COALESCE((item->>'stock_before')::INTEGER, 0),
        (item->>'stock_after')::INTEGER, 'Bulk import (' || p_mode || ')', auth.uid());
    END IF;

    PERFORM public.write_audit_log('Pharmacy inventory imported', biz.name, 'pharmacy_inventory_item', saved_id, item->>'name',
      jsonb_build_object('request_id', p_request_id, 'mode', p_mode, 'stock_before', item->'stock_before', 'stock_after', item->'stock_after'));
  END LOOP;

  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.pharmacy_inventory_import_runs (id, pharmacy_id, created_by, payload_hash, result)
    VALUES (p_request_id, p_pharmacy_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_pharmacy_inventory_item(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.adjust_pharmacy_inventory_stock(UUID, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_pharmacy_inventory_item_details(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.preview_pharmacy_inventory_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_pharmacy_inventory_item(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_pharmacy_inventory_stock(UUID, INTEGER, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_pharmacy_inventory_item_details(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, NUMERIC, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_pharmacy_inventory_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;
