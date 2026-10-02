-- Pharmacy inventory item types: create/update/adjust/import across Medicine, Medical Consumable,
-- Medical Equipment and Non-Medical Item, plus the audit-logging gap closed in this phase (create/
-- adjust/update previously logged nothing at all) and backward compatibility for pre-existing rows.
-- Run after setup.sql + migrations through 20261012110000_pharmacy_item_type_logic.sql.
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

------------------------------------------------------------------
-- Backward compatibility: a row created before item_type existed (simulated with a direct insert
-- naming no item_type) defaults to 'medicine', and nothing about it breaks.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  v_id UUID;
BEGIN
  INSERT INTO public.pharmacy_inventory_items (pharmacy_id, name, brand, form, pack_size, stock)
  VALUES (good, 'Legacy Paracetamol', 'Generic', 'Tablet', '20s', 10)
  RETURNING id INTO v_id;
  PERFORM zz.check('backward compat: a row inserted without item_type defaults to medicine',
    (SELECT item_type = 'medicine' FROM public.pharmacy_inventory_items WHERE id = v_id));
END $$;

------------------------------------------------------------------
-- create_pharmacy_inventory_item: one item per type, with that type's fields, plus validation and
-- identity isolation across types.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
  v_med_id UUID;
  v_consumable_id UUID;
  v_equip_id UUID;
  v_nonmed_id UUID;
BEGIN
  ------------------------------------------------------------------
  -- Invalid item_type is rejected with a friendly error (not a raw constraint violation).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Mystery Item', NULL, NULL, NULL, NULL, 0, NULL, NULL, 'surgical_tape')::text$q$,
    good));
  PERFORM zz.check('create_item: an invalid item_type is rejected', r LIKE 'ERR: Invalid item type%', r);

  ------------------------------------------------------------------
  -- Medicine: generic_name, strength, manufacturer, barcode, batch_number, expiry_date, supplier,
  -- selling_price_ghs all round-trip.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Amoxicillin 500mg', 'Generic', 'Antibiotics', 'Capsule', '10s', 50, 10, 4.50,
      'medicine', 'Amoxicillin', '500mg', 'GSK', '6009000001', 'B-2201', '2027-06-30', 6.00, 'Alpha Wholesale')::text$q$,
    good));
  PERFORM zz.check('create_item: medicine succeeds', r NOT LIKE 'ERR%', r);
  v_med_id := r::UUID;
  PERFORM zz.check('create_item: medicine fields stored correctly',
    (SELECT item_type = 'medicine' AND generic_name = 'Amoxicillin' AND strength = '500mg' AND manufacturer = 'GSK'
       AND barcode = '6009000001' AND batch_number = 'B-2201' AND expiry_date = '2027-06-30' AND selling_price_ghs = 6.00
       AND supplier = 'Alpha Wholesale'
     FROM public.pharmacy_inventory_items WHERE id = v_med_id));

  ------------------------------------------------------------------
  -- Medical Consumable: unit_of_measure, pack_size, barcode, batch/expiry ("where applicable").
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Latex Gloves', 'MedSafe', 'PPE', NULL, '100s', 20, 5, 25.00,
      'medical_consumable', NULL, NULL, NULL, '6009000002', NULL, NULL, 35.00, 'Beta Supplies', 'box')::text$q$,
    good));
  PERFORM zz.check('create_item: medical consumable succeeds', r NOT LIKE 'ERR%', r);
  v_consumable_id := r::UUID;
  PERFORM zz.check('create_item: consumable fields stored correctly (no form, has unit_of_measure)',
    (SELECT item_type = 'medical_consumable' AND form IS NULL AND unit_of_measure = 'box' AND barcode = '6009000002'
       AND selling_price_ghs = 35.00
     FROM public.pharmacy_inventory_items WHERE id = v_consumable_id));

  ------------------------------------------------------------------
  -- Medical Equipment: model, serial_number, warranty_info -- no form/pack_size/expiry needed.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'BP Monitor', 'Omron', 'Diagnostics', NULL, NULL, 3, 1, 180.00,
      'medical_equipment', NULL, NULL, NULL, NULL, NULL, NULL, 250.00, 'Gamma Medical', NULL, 'HEM-7120', 'SN-88213', '2 years')::text$q$,
    good));
  PERFORM zz.check('create_item: medical equipment succeeds', r NOT LIKE 'ERR%', r);
  v_equip_id := r::UUID;
  PERFORM zz.check('create_item: equipment fields stored correctly',
    (SELECT item_type = 'medical_equipment' AND model = 'HEM-7120' AND serial_number = 'SN-88213'
       AND warranty_info = '2 years' AND batch_number IS NULL AND expiry_date IS NULL
     FROM public.pharmacy_inventory_items WHERE id = v_equip_id));

  ------------------------------------------------------------------
  -- Non-Medical Item: SKU/barcode, unit -- no form/pack_size/batch/expiry/manufacturer/strength.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Facial Tissue', 'SoftCare', 'Shop items', NULL, NULL, 40, 10, 3.00,
      'non_medical', NULL, NULL, NULL, '6009000003', NULL, NULL, 5.00, NULL, 'pack')::text$q$,
    good));
  PERFORM zz.check('create_item: non-medical succeeds', r NOT LIKE 'ERR%', r);
  v_nonmed_id := r::UUID;
  PERFORM zz.check('create_item: non-medical fields stored correctly',
    (SELECT item_type = 'non_medical' AND barcode = '6009000003' AND unit_of_measure = 'pack'
       AND generic_name IS NULL AND manufacturer IS NULL
     FROM public.pharmacy_inventory_items WHERE id = v_nonmed_id));

  ------------------------------------------------------------------
  -- Identity is scoped per item_type: a medicine and a non-medical item that share the exact same
  -- name/brand (and both have no form/pack_size) do NOT collide as "the same item".
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Facial Tissue', 'SoftCare', NULL, NULL, NULL, 5)::text$q$, good));
  PERFORM zz.check('create_item: same name/brand as a non-medical item, but item_type=medicine (default), does not collide',
    r NOT LIKE 'ERR%', r);

  -- But the exact same name/brand/item_type IS still rejected as a duplicate.
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Facial Tissue', 'SoftCare', 'Shop items', NULL, NULL, 1, NULL, NULL, 'non_medical')::text$q$,
    good));
  PERFORM zz.check('create_item: same name/brand/item_type is still rejected as a duplicate', r LIKE 'ERR: This item is already tracked%', r);

  ------------------------------------------------------------------
  -- Audit logging gap closed: create now writes an audit_logs row (it did not before this phase).
  ------------------------------------------------------------------
  PERFORM zz.check('create_item: writes an audit log row tagged to the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Pharmacy inventory item added' AND record_id = v_med_id AND business_id = good));
END $$;

------------------------------------------------------------------
-- update_pharmacy_inventory_item_details: can change item_type and its fields; now audit-logged.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
  v_id UUID;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Thermometer', 'Braun', 'Diagnostics', NULL, NULL, 5, NULL, NULL, 'medical_equipment')::text$q$,
    good));
  v_id := r::UUID;

  r := zz.val_as(u_po, format(
    $q$SELECT public.update_pharmacy_inventory_item_details(%L, 'Thermometer', 'Braun', 'Diagnostics', NULL, NULL, 2, 45.00, true,
      'medical_equipment', NULL, NULL, NULL, NULL, NULL, NULL, 60.00, 'Gamma Medical', NULL, 'TH-900', 'SN-5521', '1 year')::text$q$,
    v_id));
  PERFORM zz.check('update_details: succeeds with equipment fields', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('update_details: equipment fields updated',
    (SELECT model = 'TH-900' AND serial_number = 'SN-5521' AND warranty_info = '1 year' AND selling_price_ghs = 60.00
     FROM public.pharmacy_inventory_items WHERE id = v_id));

  PERFORM zz.check('update_details: writes an audit log row (gap closed)',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Pharmacy inventory item updated' AND record_id = v_id AND business_id = good));

  -- Invalid item_type on update is rejected too.
  r := zz.val_as(u_po, format(
    $q$SELECT public.update_pharmacy_inventory_item_details(%L, 'Thermometer', NULL, NULL, NULL, NULL, NULL, NULL, true, 'not_a_type')::text$q$,
    v_id));
  PERFORM zz.check('update_details: an invalid item_type is rejected', r LIKE 'ERR: Invalid item type%', r);
END $$;

------------------------------------------------------------------
-- adjust_pharmacy_inventory_stock: now audit-logged (it did not log at all before this phase).
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
  v_id UUID;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_pharmacy_inventory_item(%L, 'Cotton Wool', 'MedSafe', 'PPE', NULL, NULL, 10, NULL, NULL, 'medical_consumable')::text$q$,
    good));
  v_id := r::UUID;

  r := zz.val_as(u_po, format($q$SELECT public.adjust_pharmacy_inventory_stock(%L, 5, 'receive')::text$q$, v_id));
  PERFORM zz.check('adjust: succeeds', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('adjust: writes an audit log row (gap closed)',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Pharmacy inventory stock adjusted' AND record_id = v_id AND business_id = good
      AND (details->>'quantity_delta')::int = 5));
END $$;

------------------------------------------------------------------
-- preview_pharmacy_inventory_import: itemType per row, defaulting to medicine when absent,
-- validated, and scoped identity (no cross-type collision during import either).
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
  v_preview JSONB;
  v_token TEXT;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[
      {"name":"Nebulizer","itemType":"medical_equipment","stock":"2","model":"NEB-1","serialNumber":"SN-01","source_row":1},
      {"name":"Gauze Roll","itemType":"medical_consumable","stock":"30","unitOfMeasure":"roll","expiryDate":"2026-12-31","source_row":2},
      {"name":"Bottled Water","itemType":"non_medical","stock":"24","unitOfMeasure":"bottle","source_row":3},
      {"name":"Ibuprofen 200mg","stock":"50","source_row":4}
    ]'::jsonb, 'add')::text$q$,
    good));
  v_preview := r::JSONB;
  PERFORM zz.check('import preview: succeeds across mixed item types', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('import preview: no issues for valid mixed-type rows', jsonb_array_length(v_preview->'issues') = 0, r);
  PERFORM zz.check('import preview: a row with no itemType defaults to medicine',
    (SELECT (row->>'item_type') = 'medicine' FROM jsonb_array_elements(v_preview->'rows') row WHERE row->>'name' = 'Ibuprofen 200mg'));
  PERFORM zz.check('import preview: an explicit itemType is carried through',
    (SELECT (row->>'item_type') = 'medical_equipment' FROM jsonb_array_elements(v_preview->'rows') row WHERE row->>'name' = 'Nebulizer'));
  v_token := v_preview->>'token';

  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[
      {"name":"Nebulizer","itemType":"medical_equipment","stock":"2","model":"NEB-1","serialNumber":"SN-01","source_row":1},
      {"name":"Gauze Roll","itemType":"medical_consumable","stock":"30","unitOfMeasure":"roll","expiryDate":"2026-12-31","source_row":2},
      {"name":"Bottled Water","itemType":"non_medical","stock":"24","unitOfMeasure":"bottle","source_row":3},
      {"name":"Ibuprofen 200mg","stock":"50","source_row":4}
    ]'::jsonb, 'add', %L, %L)::text$q$,
    good, v_token, gen_random_uuid()));
  PERFORM zz.check('import confirm: succeeds', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('import confirm: Nebulizer saved as medical_equipment with model/serial',
    (SELECT item_type = 'medical_equipment' AND model = 'NEB-1' AND serial_number = 'SN-01'
     FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Nebulizer'));
  PERFORM zz.check('import confirm: Gauze Roll saved as medical_consumable with unit_of_measure and expiry_date',
    (SELECT item_type = 'medical_consumable' AND unit_of_measure = 'roll' AND expiry_date = '2026-12-31'
     FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Gauze Roll'));
  PERFORM zz.check('import confirm: Bottled Water saved as non_medical',
    (SELECT item_type = 'non_medical' AND unit_of_measure = 'bottle'
     FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Bottled Water'));
  PERFORM zz.check('import confirm: Ibuprofen (no itemType given) saved as medicine',
    (SELECT item_type = 'medicine' FROM public.pharmacy_inventory_items WHERE pharmacy_id = good AND name = 'Ibuprofen 200mg'));

  -- An invalid itemType in a row is a per-row issue, not a hard failure of the whole import.
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[{"name":"Mystery","itemType":"not_a_type","stock":"1","source_row":1}]'::jsonb, 'add')::text$q$,
    good));
  v_preview := r::JSONB;
  PERFORM zz.check('import preview: an invalid itemType is reported as a row issue',
    jsonb_array_length(v_preview->'issues') = 1 AND (v_preview->'issues'->0->>'message') = 'Invalid item type.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
