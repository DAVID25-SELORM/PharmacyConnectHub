-- Pharmacy-owned inventory: create/adjust/edit a single item, and the preview/confirm bulk
-- import RPC (mirroring preview_wholesaler_import's proven shape). Standalone from marketplace
-- orders by design -- these tests never touch orders/order_items.
-- Run after setup.sql + migrations through 20261009110000_pharmacy_inventory_logic.sql.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

-- A Good Pharmacy assistant (not in the 'process' tier), to prove assistants cannot manage
-- inventory even though owner/manager/cashier/warehouse can.
SELECT zz.mkuser('40000000-0000-0000-0000-0000000000f1', 'phasst@zz.test', '{"full_name":"Good Pharmacy Assistant","phone":"+233241000030"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '40000000-0000-0000-0000-0000000000f1', 'assistant', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

------------------------------------------------------------------
-- create_pharmacy_inventory_item
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pa UUID := '40000000-0000-0000-0000-0000000000f1';
  r TEXT;
  v_item_id UUID;
BEGIN
  ------------------------------------------------------------------
  -- Validation
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format($q$SELECT public.create_pharmacy_inventory_item(%L, '')::text$q$, good));
  PERFORM zz.check('create_item: blank name rejected', r LIKE 'ERR: A name is required%', r);
  r := zz.val_as(u_po, format($q$SELECT public.create_pharmacy_inventory_item(%L, 'Paracetamol 500mg', NULL, NULL, NULL, NULL, -5)::text$q$, good));
  PERFORM zz.check('create_item: negative stock rejected', r LIKE 'ERR: Stock cannot be negative%', r);

  ------------------------------------------------------------------
  -- Permission: owner/manager/cashier/warehouse (process tier) can create; assistant cannot;
  -- an unrelated pharmacy's owner cannot create for Good Pharmacy.
  ------------------------------------------------------------------
  r := zz.val_as(u_pa, format($q$SELECT public.create_pharmacy_inventory_item(%L, 'Paracetamol 500mg')::text$q$, good));
  PERFORM zz.check('create_item: an assistant is denied', r LIKE 'ERR: You do not have permission to manage inventory%', r);
  r := zz.val_as(u_px, format($q$SELECT public.create_pharmacy_inventory_item(%L, 'Paracetamol 500mg')::text$q$, good));
  PERFORM zz.check('create_item: a different pharmacy is denied', r LIKE 'ERR: You do not have permission to manage inventory%', r);

  ------------------------------------------------------------------
  -- Successful creation with initial stock.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Paracetamol 500mg', 'Generic', 'Analgesic', 'Tablet', '20s', 50, 10, 4.50)::text$q$,
    good));
  PERFORM zz.check('create_item: succeeds for the owner', r NOT LIKE 'ERR%', r);
  v_item_id := r::UUID;

  PERFORM zz.check('create_item: row stored with correct fields',
    (SELECT stock = 50 AND reorder_level = 10 AND unit_cost_ghs = 4.50 AND active
     FROM public.pharmacy_inventory_items WHERE id = v_item_id));
  PERFORM zz.check('create_item: a receive movement was logged for the initial stock',
    (SELECT COUNT(*) = 1 FROM public.pharmacy_inventory_movements
     WHERE item_id = v_item_id AND kind = 'receive' AND quantity_delta = 50 AND stock_after = 50));

  ------------------------------------------------------------------
  -- Identity collision: the exact same name/brand/form/pack size for the same pharmacy is
  -- rejected (case/whitespace-insensitive, via product_import_identity).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, '  paracetamol 500MG ', 'generic', NULL, ' tablet', '20S')::text$q$, good));
  PERFORM zz.check('create_item: a near-duplicate identity is rejected', r LIKE 'ERR: This item is already tracked%', r);

  -- A different pharmacy may track an item with the identical name (no cross-tenant collision).
  r := zz.val_as(u_px, format($q$SELECT public.create_pharmacy_inventory_item(%L, 'Paracetamol 500mg')::text$q$, otherp));
  PERFORM zz.check('create_item: a different pharmacy can track the same-named item', r NOT LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- RLS: Good Pharmacy staff can read its own items; an unrelated pharmacy cannot.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.pharmacy_inventory_items WHERE id = %L', v_item_id));
  PERFORM zz.check('rls: the owner can read its own item', r = '1', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.pharmacy_inventory_items WHERE id = %L', v_item_id));
  PERFORM zz.check('rls: an unrelated pharmacy cannot read it', r = '0', r);
END $$;

------------------------------------------------------------------
-- adjust_pharmacy_inventory_stock
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  v_item_id UUID := (SELECT id FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Paracetamol 500mg');
  r TEXT;
BEGIN
  r := zz.val_as(u_px, format('SELECT public.adjust_pharmacy_inventory_stock(%L, 10, ''receive'')::text', v_item_id));
  PERFORM zz.check('adjust: an unrelated pharmacy is denied', r LIKE 'ERR: You do not have permission to manage inventory%', r);

  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, 0, ''receive'')::text', v_item_id));
  PERFORM zz.check('adjust: a zero delta is rejected', r LIKE 'ERR: Enter a non-zero quantity%', r);

  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, 5, ''write_off'')::text', v_item_id));
  PERFORM zz.check('adjust: a write-off with a positive delta is rejected', r LIKE 'ERR: A write-off must reduce stock%', r);

  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, -5, ''write_off'', ''not_a_real_reason'')::text', v_item_id));
  PERFORM zz.check('adjust: an invalid reason is rejected', r LIKE 'ERR: Invalid reason%', r);

  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, -1000, ''write_off'', ''damaged'')::text', v_item_id));
  PERFORM zz.check('adjust: cannot take stock below zero', r LIKE 'ERR: This would take stock below zero%', r);

  -- Receive 20 more (50 -> 70).
  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, 20, ''receive'', NULL, ''delivery from a non-platform supplier'')::text', v_item_id));
  PERFORM zz.check('adjust: receive succeeds', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('adjust: stock is now 70', (SELECT stock = 70 FROM public.pharmacy_inventory_items WHERE id = v_item_id));

  -- Write off 8 as damaged (70 -> 62).
  r := zz.val_as(u_po, format('SELECT public.adjust_pharmacy_inventory_stock(%L, -8, ''write_off'', ''damaged'')::text', v_item_id));
  PERFORM zz.check('adjust: write-off succeeds', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('adjust: stock is now 62', (SELECT stock = 62 FROM public.pharmacy_inventory_items WHERE id = v_item_id));

  PERFORM zz.check('adjust: 3 movements logged total (1 initial receive + 2 adjustments), including one ending at stock_after=62',
    (SELECT COUNT(*) = 3 FROM public.pharmacy_inventory_movements WHERE item_id = v_item_id)
    AND EXISTS (SELECT 1 FROM public.pharmacy_inventory_movements WHERE item_id = v_item_id AND stock_after = 62));
END $$;

------------------------------------------------------------------
-- update_pharmacy_inventory_item_details
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  v_item_id UUID := (SELECT id FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Paracetamol 500mg');
  v_other_id UUID;
  r TEXT;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.update_pharmacy_inventory_item_details(%L, 'Paracetamol 500mg Tabs', 'Generic Co', 'Analgesic', 'Tablet', '20s', 15, 5.00, true)::text$q$,
    v_item_id));
  PERFORM zz.check('update_details: succeeds', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('update_details: fields updated, stock untouched (still 62)',
    (SELECT name = 'Paracetamol 500mg Tabs' AND brand = 'Generic Co' AND reorder_level = 15 AND unit_cost_ghs = 5.00 AND stock = 62
     FROM public.pharmacy_inventory_items WHERE id = v_item_id));
  PERFORM zz.check('update_details: did not log a movement (metadata-only edit)',
    (SELECT COUNT(*) FROM public.pharmacy_inventory_movements WHERE item_id = v_item_id) = 3);

  -- Create a second item, then try to rename it to collide with the first.
  r := zz.val_as(u_po, format($q$SELECT public.create_pharmacy_inventory_item(%L, 'Amoxicillin 250mg')::text$q$, good));
  v_other_id := r::UUID;
  r := zz.val_as(u_po, format(
    $q$SELECT public.update_pharmacy_inventory_item_details(%L, 'Paracetamol 500mg Tabs', 'Generic Co', 'Analgesic', 'Tablet', '20s')::text$q$,
    v_other_id));
  PERFORM zz.check('update_details: renaming into a collision with another item is rejected', r LIKE 'ERR: Another item with this same name%', r);
END $$;

------------------------------------------------------------------
-- preview_pharmacy_inventory_import
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_pc UUID;
  r TEXT;
  v_preview JSONB;
  v_token TEXT;
  v_req1 UUID := gen_random_uuid();
  v_req2 UUID := gen_random_uuid();
BEGIN
  -- A Good Pharmacy cashier, to prove import is gated at 'manage' (owner/manager only), unlike
  -- single-item create/adjust which allow cashiers too.
  PERFORM zz.mkuser('40000000-0000-0000-0000-0000000000f2', 'phcash2@zz.test', '{"full_name":"Good Pharmacy Cashier 2","phone":"+233241000031"}');
  INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
  VALUES (good, '40000000-0000-0000-0000-0000000000f2', 'cashier', 'active', now());
  u_pc := '40000000-0000-0000-0000-0000000000f2';

  r := zz.val_as(u_pc, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[{"name":"Vitamin C 500mg","stock":10}]'::jsonb, 'add')::text$q$, good));
  PERFORM zz.check('import: a cashier is denied (manage tier only)', r LIKE 'ERR: Only owners and managers can import%', r);

  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[]'::jsonb, 'add')::text$q$, good));
  PERFORM zz.check('import: an empty array is rejected', r LIKE 'ERR: Import between 1 and 5000%', r);

  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[{"name":"Vitamin C 500mg","stock":10}]'::jsonb, 'bogus_mode')::text$q$, good));
  PERFORM zz.check('import: an invalid mode is rejected', r LIKE 'ERR: Invalid import mode%', r);

  -- Preview: 1 brand-new item, 1 updating the existing "Amoxicillin 250mg" (created above, stock
  -- 0), 1 row with a missing name, 2 duplicate rows of the same identity.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'add')::text$q$,
    good,
    '[
      {"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},
      {"source_row":2,"name":"Amoxicillin 250mg","stock":"40"},
      {"source_row":3,"name":""},
      {"source_row":4,"name":"Ibuprofen 400mg","stock":"5"},
      {"source_row":5,"name":"Ibuprofen 400mg","stock":"7"}
    ]'
  ));
  PERFORM zz.check('import preview: succeeds (returns JSON, not an error)', r NOT LIKE 'ERR%', r);
  v_preview := r::JSONB;
  PERFORM zz.check('import preview: 2 issues (blank name + duplicate row)', jsonb_array_length(v_preview->'issues') = 2, v_preview::text);
  PERFORM zz.check('import preview: 3 valid plan rows (Vitamin C new, Amoxicillin existing, first Ibuprofen)',
    jsonb_array_length(v_preview->'rows') = 3, v_preview::text);
  PERFORM zz.check('import preview: Vitamin C planned as new with stock_after=25',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'rows') row WHERE row->>'name' = 'Vitamin C 500mg' AND row->>'kind' = 'new' AND (row->>'stock_after')::int = 25));
  PERFORM zz.check('import preview: Amoxicillin planned as existing, mode=add so stock_after = 0+40 = 40',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'rows') row WHERE row->>'name' = 'Amoxicillin 250mg' AND row->>'kind' = 'existing' AND (row->>'stock_after')::int = 40));
  v_token := v_preview->>'token';

  -- Confirming with issues still present must fail even with a request id.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'add', %L, %L)::text$q$,
    good,
    '[
      {"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},
      {"source_row":2,"name":"Amoxicillin 250mg","stock":"40"},
      {"source_row":3,"name":""},
      {"source_row":4,"name":"Ibuprofen 400mg","stock":"5"},
      {"source_row":5,"name":"Ibuprofen 400mg","stock":"7"}
    ]',
    v_token, v_req1
  ));
  PERFORM zz.check('import confirm: rejected while issues remain', r LIKE 'ERR: Fix all import issues before confirming%', r);

  -- Clean payload (no issues), confirm it for real.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'add')::text$q$,
    good,
    '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},{"source_row":2,"name":"Amoxicillin 250mg","stock":"40"}]'
  ));
  v_preview := r::JSONB;
  v_token := v_preview->>'token';

  -- Stale token (from before another change landed) must be rejected.
  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''add'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},{"source_row":2,"name":"Amoxicillin 250mg","stock":"40"}]',
    'not-the-real-token', v_req1));
  PERFORM zz.check('import confirm: a wrong/stale token is rejected', r LIKE 'ERR: Inventory changed since preview%', r);

  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''add'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},{"source_row":2,"name":"Amoxicillin 250mg","stock":"40"}]',
    v_token, v_req1));
  PERFORM zz.check('import confirm: succeeds with the matching token', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('import confirm: Vitamin C created with stock 25 and cost 3.00',
    (SELECT stock = 25 AND unit_cost_ghs = 3.00 FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Vitamin C 500mg'));
  PERFORM zz.check('import confirm: Amoxicillin updated to stock 40 (mode=add, was 0)',
    (SELECT stock = 40 FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Amoxicillin 250mg'));
  PERFORM zz.check('import confirm: an import movement was logged for Amoxicillin (0 -> 40)',
    EXISTS (
      SELECT 1 FROM public.pharmacy_inventory_movements m
      JOIN public.pharmacy_inventory_items i ON i.id = m.item_id
      WHERE i.pharmacy_id = good AND i.name = 'Amoxicillin 250mg' AND m.kind = 'import' AND m.quantity_delta = 40 AND m.stock_after = 40
    ));

  -- Re-running the SAME request id + payload (an idempotent retry, e.g. a client-side resend) must
  -- return the stored result without creating a second Vitamin C row or a second movement.
  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''add'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25","unitCostGhs":"3.00"},{"source_row":2,"name":"Amoxicillin 250mg","stock":"40"}]',
    v_token, v_req1));
  PERFORM zz.check('import confirm: idempotent retry with the same request id succeeds without duplicating', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('import confirm: still exactly 1 Vitamin C row after the retry',
    (SELECT COUNT(*) = 1 FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Vitamin C 500mg'));

  -- A different request id with the SAME payload is treated as a brand new import -- "add" mode
  -- on top of the now-25-stock Vitamin C adds another 25 (not a duplicate row, a second addition).
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'add')::text$q$,
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25"}]'));
  v_preview := r::JSONB;
  v_token := v_preview->>'token';
  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''add'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"25"}]', v_token, v_req2));
  PERFORM zz.check('import confirm: a second distinct import request adds again (25 + 25 = 50)',
    (SELECT stock = 50 FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Vitamin C 500mg'));

  -- 'details' mode must never touch stock.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'details')::text$q$,
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"999","unitCostGhs":"9.99"}]'));
  v_preview := r::JSONB;
  PERFORM zz.check('import preview (details mode): stock_after unchanged despite a different input stock',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_preview->'rows') row WHERE row->>'name' = 'Vitamin C 500mg' AND (row->>'stock_after')::int = 50));

  -- 'replace' mode sets stock to exactly the input value.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, 'replace')::text$q$,
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"12"}]'));
  v_preview := r::JSONB;
  v_token := v_preview->>'token';
  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''replace'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Vitamin C 500mg","stock":"12"}]', v_token, gen_random_uuid()));
  PERFORM zz.check('import confirm (replace mode): stock set to exactly 12, not added', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('import confirm (replace mode): stock is now 12', (SELECT stock = 12 FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Vitamin C 500mg'));
END $$;

DO $$
BEGIN
  PERFORM zz.check('anon has no EXECUTE on any pharmacy inventory RPC',
    NOT has_function_privilege('anon', 'public.create_pharmacy_inventory_item(uuid,text,text,text,text,text,integer,integer,numeric,text,text,text,text,text,text,date,numeric,text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.adjust_pharmacy_inventory_stock(uuid,integer,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.update_pharmacy_inventory_item_details(uuid,text,text,text,text,text,integer,numeric,boolean,text,text,text,text,text,text,date,numeric,text,text,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.preview_pharmacy_inventory_import(uuid,jsonb,text,text,uuid)', 'EXECUTE'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
