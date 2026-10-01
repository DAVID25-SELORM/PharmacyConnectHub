-- customer_statement() + the credit ledger: the documented gap this closes is that a credit
-- order with a PARTIAL payment (recorded via record_credit_payment) used to show as fully
-- outstanding on the statement until paid off completely, because the old logic only emitted a
-- payment line once orders.payment_status flipped to 'paid'. These tests call the RPC the same way
-- the frontend does -- via zz.val_as, as the actual pharmacy/wholesaler owner, never as the
-- postgres superuser -- which is the only way to catch a regression on the SECURITY DEFINER change
-- (credit_ledger_entries' own RLS only allows admins to SELECT it directly; before this fix's
-- SECURITY INVOKER -> SECURITY DEFINER change, these same assertions would have silently seen zero
-- ledger-based lines instead of an error, which is why this needs an explicit test, not just a
-- manual check).
-- Run after setup.sql + migrations through 20261010100000_customer_statement_credit_ledger.sql.
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

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  o1 UUID; o2 UUID; o3 UUID;
  v_first_payment_entry UUID;
  r TEXT;
  s JSONB;
BEGIN
  -- o1: credit order, GHS 200, paid in two partial instalments (80 then 70) -- never reaching the
  -- full amount, so payment_status stays 'unpaid' throughout (matches record_credit_payment's own
  -- behaviour: it only flips payment_status once the allocation covers the full outstanding
  -- balance). This is exactly the case that used to show as fully outstanding on the statement.
  INSERT INTO public.orders (pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs,
    payment_status, payment_method, is_credit_order, created_at)
  VALUES (good, alpha, 'delivered', 200, 200, 0, 'unpaid', 'cod', true, now() - interval '10 days')
  RETURNING id INTO o1;
  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
  VALUES (alpha, good, o1, 'invoice', 'debit', 200, (SELECT owner_id FROM public.businesses WHERE id = alpha));

  r := zz.val_as(u_wo, format(
    $q$SELECT public.record_credit_payment(%L, %L, 80, 'cash', NULL, (now() - interval '8 days')::text::timestamptz, NULL, NULL,
      jsonb_build_array(jsonb_build_object('order_id', %L, 'amount', 80)))::text$q$,
    alpha, good, o1));
  PERFORM zz.check('fixture: first partial payment (80) recorded', r NOT LIKE 'ERR%', r);
  -- record_credit_payment's p_paid_at only backdates credit_payments.paid_at (the receipt date);
  -- the ledger entry's own created_at is always "now" by append-only-ledger design. Backdate it
  -- directly here so the opening-balance test below has a genuinely historical line to net.
  UPDATE public.credit_ledger_entries SET created_at = now() - interval '8 days'
  WHERE order_id = o1 AND entry_type = 'payment' AND amount_ghs = 80;

  r := zz.val_as(u_wo, format(
    $q$SELECT public.record_credit_payment(%L, %L, 70, 'mobile_money', NULL, (now() - interval '3 days')::text::timestamptz, NULL, NULL,
      jsonb_build_array(jsonb_build_object('order_id', %L, 'amount', 70)))::text$q$,
    alpha, good, o1));
  PERFORM zz.check('fixture: second partial payment (70) recorded', r NOT LIKE 'ERR%', r);
  UPDATE public.credit_ledger_entries SET created_at = now() - interval '3 days'
  WHERE order_id = o1 AND entry_type = 'payment' AND amount_ghs = 70;

  PERFORM zz.check('fixture: o1 payment_status is still unpaid (80+70=150 < 200)',
    (SELECT payment_status::text FROM public.orders WHERE id = o1) = 'unpaid');

  ------------------------------------------------------------------
  -- The core fix: the statement now shows the real partial-payment history for o1, called as the
  -- actual wholesaler owner (not postgres), which is what proves SECURITY DEFINER is working.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format(
    $q$SELECT public.customer_statement(%L, %L, now() - interval '200 days', now() + interval '1 day')::text$q$,
    alpha, good));
  PERFORM zz.check('statement call succeeds for the wholesaler owner', r NOT LIKE 'ERR%', r);
  s := r::JSONB;

  PERFORM zz.check('o1 contributes 2 payment lines (80 and 70), not zero',
    (SELECT COUNT(*) FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o1::text AND (l->>'kind') = 'payment') = 2,
    s::text);
  PERFORM zz.check('the two payment lines total 150, matching what was actually paid',
    (SELECT COALESCE(SUM((l->>'credit')::numeric), 0) FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o1::text) = 150,
    s::text);
  PERFORM zz.check('o1''s order (debit) line is still the full 200, not reduced by the payments',
    (SELECT (l->>'debit')::numeric FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o1::text AND (l->>'kind') = 'order') = 200,
    s::text);
  PERFORM zz.check('closing balance reflects 200 - 150 = 50 still owed on o1 (this pharmacy has no other orders yet)',
    (s->>'closing_balance')::numeric = 50, s::text);

  ------------------------------------------------------------------
  -- A date range that starts strictly AFTER the first partial payment but before the second must
  -- show the correct opening balance (200 - 80 = 120), proving the opening-balance computation
  -- correctly nets ledger-based lines too, not just the old order/cash-payment lines. Run this
  -- before o2/o3 exist below, so the -5-day boundary only ever has to account for o1's own events.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format(
    $q$SELECT public.customer_statement(%L, %L, now() - interval '5 days', now() + interval '1 day')::text$q$,
    alpha, good));
  s := r::JSONB;
  PERFORM zz.check('opening balance mid-range correctly nets the first partial payment (200-80=120 carried in)',
    (s->>'opening_balance')::numeric = 120, s::text);

  ------------------------------------------------------------------
  -- o2: a second credit order, paid via the LEGACY "Confirm payment received" path (a direct
  -- payment_status update, not record_credit_payment) -- the mirror trigger should still produce a
  -- ledger entry the statement picks up, proving both payment paths feed the same statement logic.
  ------------------------------------------------------------------
  INSERT INTO public.orders (pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs,
    payment_status, payment_method, is_credit_order, created_at)
  VALUES (good, alpha, 'delivered', 100, 100, 0, 'unpaid', 'cod', true, now() - interval '6 days')
  RETURNING id INTO o2;
  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
  VALUES (alpha, good, o2, 'invoice', 'debit', 100, (SELECT owner_id FROM public.businesses WHERE id = alpha));

  UPDATE public.orders SET payment_status = 'paid', paid_at = now() - interval '5 days',
    payment_confirmed_at = now() - interval '5 days', payment_confirmed_by = (SELECT owner_id FROM public.businesses WHERE id = alpha)
  WHERE id = o2;

  PERFORM zz.check('fixture: the legacy mirror trigger posted a 100 payment entry for o2',
    EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = o2 AND entry_type = 'payment' AND direction = 'credit' AND amount_ghs = 100));

  r := zz.val_as(u_po, format(
    $q$SELECT public.customer_statement(%L, %L, now() - interval '200 days', now() + interval '1 day')::text$q$,
    alpha, good));
  s := r::JSONB;
  PERFORM zz.check('the pharmacy owner sees o2 fully paid via the legacy path',
    (SELECT COALESCE(SUM((l->>'credit')::numeric), 0) FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o2::text) = 100,
    s::text);
  PERFORM zz.check('closing balance now reflects o1''s remaining 50 only (o2 fully settled)',
    (s->>'closing_balance')::numeric = 50, s::text);

  ------------------------------------------------------------------
  -- o3 + a reversal: a fully-paid credit order whose payment then gets reversed (e.g. a bounced
  -- cheque) must go back to looking outstanding on the statement -- not silently still "paid".
  ------------------------------------------------------------------
  INSERT INTO public.orders (pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs,
    payment_status, payment_method, is_credit_order, created_at)
  VALUES (good, alpha, 'delivered', 40, 40, 0, 'unpaid', 'cod', true, now() - interval '4 days')
  RETURNING id INTO o3;
  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
  VALUES (alpha, good, o3, 'invoice', 'debit', 40, (SELECT owner_id FROM public.businesses WHERE id = alpha));

  r := zz.val_as(u_wo, format(
    $q$SELECT public.record_credit_payment(%L, %L, 40, 'cheque', NULL, (now() - interval '2 days')::text::timestamptz, NULL, NULL,
      jsonb_build_array(jsonb_build_object('order_id', %L, 'amount', 40)))::text$q$,
    alpha, good, o3));
  PERFORM zz.check('fixture: o3 paid in full (40)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('fixture: o3 payment_status flipped to paid', (SELECT payment_status::text FROM public.orders WHERE id = o3) = 'paid');

  SELECT id INTO v_first_payment_entry FROM public.credit_ledger_entries WHERE order_id = o3 AND entry_type = 'payment' LIMIT 1;
  r := zz.val_as(u_wo, format($q$SELECT public.reverse_credit_ledger_entry(%L, 'Cheque bounced')::text$q$, v_first_payment_entry));
  PERFORM zz.check('fixture: the payment was reversed', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('fixture: o3 payment_status reopened to unpaid after the reversal',
    (SELECT payment_status::text FROM public.orders WHERE id = o3) = 'unpaid');

  r := zz.val_as(u_wo, format(
    $q$SELECT public.customer_statement(%L, %L, now() - interval '200 days', now() + interval '1 day')::text$q$,
    alpha, good));
  s := r::JSONB;
  PERFORM zz.check('o3 nets to zero on the statement: the +40 payment and its -40 reversal cancel out',
    (SELECT COALESCE(SUM((l->>'credit')::numeric) - SUM((l->>'debit')::numeric), 0)
     FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o3::text AND (l->>'kind') = 'payment') = 0,
    s::text);
  PERFORM zz.check('o3''s payment and reversal are 2 distinct lines (both visible, not collapsed)',
    (SELECT COUNT(*) FROM jsonb_array_elements(s->'lines') l WHERE (l->>'order_id') = o3::text AND (l->>'kind') = 'payment') = 2,
    s::text);
  PERFORM zz.check('closing balance now also includes o3''s reopened 40 (50 + 40 = 90)',
    (s->>'closing_balance')::numeric = 90, s::text);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
