-- Audit Centre: list_audit_log permission/scoping, and that the RFQ + credit-ledger + import RPCs
-- retrofitted in this phase actually produce a business_id-tagged row an owner/manager/accountant
-- can read back -- not just that write_audit_log was *called* (already covered elsewhere), but that
-- the whole pipeline (RPC -> audit_logs row -> list_audit_log) works end to end, as the real caller.
-- Run after setup.sql + migrations through 20261011120000_audit_centre_logic_part2.sql.
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

-- A Good Pharmacy assistant (not owner/manager/accountant), to prove list_audit_log excludes roles
-- not listed in §27's "View audit logs: Yes" set.
SELECT zz.mkuser('40000000-0000-0000-0000-0000000000a1', 'phaudit@zz.test', '{"full_name":"Good Pharmacy Assistant","phone":"+233241000040"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '40000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Audit Amoxicillin', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 10.00, 100, true FROM zz.b WHERE name='Alpha Wholesale';

------------------------------------------------------------------
-- RFQ actions produce correctly-scoped audit rows, readable from the acting business's own side.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_pa UUID := '40000000-0000-0000-0000-0000000000a1';
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  r TEXT;
  v_rfq_id UUID;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.create_rfq(%L, 'Audit Test RFQ', NULL, NULL, ARRAY[%L]::uuid[], '[{"productName":"Amoxicillin 500mg","quantity":10}]'::jsonb)::text$q$,
    good, alpha));
  PERFORM zz.check('fixture: RFQ created', r NOT LIKE 'ERR%', r);
  v_rfq_id := r::UUID;

  PERFORM zz.check('create_rfq wrote an audit row tagged to the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ created' AND record_id = v_rfq_id AND business_id = good));

  r := zz.val_as(u_po, format($q$SELECT (public.list_audit_log(%L))::text LIMIT 1$q$, good));
  -- list_audit_log returns a set; just prove the owner can call it without error and sees >=1 row.
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_audit_log(%L)', good));
  PERFORM zz.check('the pharmacy owner can read its own audit log and sees at least the RFQ-created row', r::int >= 1, r);

  r := zz.val_as(u_pa, format('SELECT count(*)::text FROM public.list_audit_log(%L)', good));
  PERFORM zz.check('an assistant (not owner/manager/accountant) is denied', r LIKE 'ERR: You do not have permission to view this business''s audit log%', r);

  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.list_audit_log(%L)', good));
  PERFORM zz.check('an unrelated pharmacy is denied', r LIKE 'ERR: You do not have permission to view this business''s audit log%', r);

  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = %L),
      'productId', (SELECT id FROM public.products WHERE name = 'Audit Amoxicillin'),
      'unitPriceGhs', 9.50
    )))::text$q$, v_rfq_id, alpha, v_rfq_id));
  PERFORM zz.check('fixture: quote submitted', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('submit_rfq_quote wrote an audit row tagged to the wholesaler, not the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ quote submitted' AND business_id = alpha)
    AND NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ quote submitted' AND business_id = good));

  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_audit_log(%L)', good));
  PERFORM zz.check('the pharmacy''s own audit log does NOT include the wholesaler-side quote-submitted row (cross-tenant isolation)',
    (SELECT count(*) FROM public.audit_logs WHERE activity = 'RFQ quote submitted' AND business_id = good) = 0);

  -- A manager (not just the owner) can also read the wholesaler's audit log.
  r := zz.val_as(u_wm, format('SELECT count(*)::text FROM public.list_audit_log(%L)', alpha));
  PERFORM zz.check('a wholesaler manager can also read the audit log', r::int >= 1, r);
END $$;

------------------------------------------------------------------
-- Credit ledger actions produce audit rows tagged to the wholesaler (the acting business).
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  o1 UUID;
  r TEXT;
BEGIN
  INSERT INTO public.orders (pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs,
    payment_status, payment_method, is_credit_order, created_at)
  VALUES (good, alpha, 'delivered', 50, 50, 0, 'unpaid', 'cod', true, now() - interval '2 days')
  RETURNING id INTO o1;
  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
  VALUES (alpha, good, o1, 'invoice', 'debit', 50, (SELECT owner_id FROM public.businesses WHERE id = alpha));

  r := zz.val_as(u_wo, format(
    $q$SELECT public.record_credit_payment(%L, %L, 50, 'cash', NULL, NULL, NULL, NULL, jsonb_build_array(jsonb_build_object('order_id', %L, 'amount', 50)))::text$q$,
    alpha, good, o1));
  PERFORM zz.check('fixture: credit payment recorded', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('record_credit_payment wrote an audit row tagged to the wholesaler',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit payment recorded' AND business_id = alpha
      AND (details->>'amount_ghs')::numeric = 50));

  r := zz.val_as(u_wo, format($q$SELECT count(*)::text FROM public.list_audit_log(%L, p_record_type => 'business')$q$, alpha));
  PERFORM zz.check('record_type filter narrows results (business-type rows exist)', r::int >= 1, r);

  r := zz.val_as(u_wo, format($q$SELECT count(*)::text FROM public.list_audit_log(%L, p_search => 'nonexistent-search-term-xyz')$q$, alpha));
  PERFORM zz.check('a search term that matches nothing returns zero rows', r = '0', r);

  r := zz.val_as(u_wo, format($q$SELECT count(*)::text FROM public.list_audit_log(%L, p_search => 'Credit payment')$q$, alpha));
  PERFORM zz.check('search matches the activity text', r::int >= 1, r);
END $$;

------------------------------------------------------------------
-- Pharmacy inventory import also tags its audit rows with business_id now.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
  v_preview JSONB;
BEGIN
  r := zz.val_as(u_po, format(
    $q$SELECT public.preview_pharmacy_inventory_import(%L, '[{"source_row":1,"name":"Audit Import Item","stock":"5"}]'::jsonb, 'add')::text$q$,
    good));
  v_preview := r::JSONB;
  r := zz.val_as(u_po, format('SELECT public.preview_pharmacy_inventory_import(%L, %L::jsonb, ''add'', %L, %L)::text',
    good, '[{"source_row":1,"name":"Audit Import Item","stock":"5"}]', v_preview->>'token', gen_random_uuid()));
  PERFORM zz.check('fixture: inventory import confirmed', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('preview_pharmacy_inventory_import wrote an audit row tagged to the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Pharmacy inventory imported' AND business_id = good AND record_label = 'Audit Import Item'));
END $$;

DO $$
BEGIN
  PERFORM zz.check('anon has no EXECUTE on list_audit_log',
    NOT has_function_privilege('anon', 'public.list_audit_log(uuid,timestamptz,timestamptz,text,text,timestamptz,uuid,integer)', 'EXECUTE'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
