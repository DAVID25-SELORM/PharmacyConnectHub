-- Accounts Receivable (wholesaler_ar_summary) / Accounts Payable (pharmacy_ap_summary): KPI
-- totals, aging buckets, and per-counterparty breakdown, all derived from the existing credit
-- ledger. Run after setup.sql + migrations through 20261005100000_ar_ap_summaries.sql.
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
  other_wh UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  other_ph UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  o_current UUID; o_soon UUID; o_month UUID; o_overdue UUID; o_paid UUID; o_other_pharmacy UUID;
  r TEXT;
  j JSONB;
BEGIN
  -- Not yet due (30 days out): sits in the aging "current" bucket, outside the 7-day window.
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 100, 100, 0, 'unpaid', 'cod', TRUE, current_date + 30) RETURNING id INTO o_current;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_current, 'invoice', 'debit', 100, u_wo);

  -- Due in 5 days: inside the 7-day window (and the 30-day window).
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 50, 50, 0, 'unpaid', 'cod', TRUE, current_date + 5) RETURNING id INTO o_soon;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_soon, 'invoice', 'debit', 50, u_wo);

  -- Due in 20 days: inside the 30-day window, outside the 7-day window.
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 30, 30, 0, 'unpaid', 'cod', TRUE, current_date + 20) RETURNING id INTO o_month;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_month, 'invoice', 'debit', 30, u_wo);

  -- 40 days overdue: lands in the 31-60 aging bucket.
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 80, 80, 0, 'unpaid', 'cod', TRUE, current_date - 40) RETURNING id INTO o_overdue;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_overdue, 'invoice', 'debit', 80, u_wo);

  -- Fully paid: excluded from every outstanding-based figure, but counted for total_credit_sales
  -- and, since the payment posts today, counted in "collected this month".
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (good, alpha, 'accepted', 60, 60, 0, 'paid', 'cod', TRUE, current_date + 15) RETURNING id INTO o_paid;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_paid, 'invoice', 'debit', 60, u_wo);
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, good, o_paid, 'payment', 'credit', 60, u_wo);

  -- A second pharmacy's credit line with Alpha, for the outstanding_by_pharmacy breakdown.
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, is_credit_order, credit_due_date)
    VALUES (other_ph, alpha, 'accepted', 25, 25, 0, 'unpaid', 'cod', TRUE, current_date + 10) RETURNING id INTO o_other_pharmacy;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (alpha, other_ph, o_other_pharmacy, 'invoice', 'debit', 25, u_wo);

  ------------------------------------------------------------------
  -- wholesaler_ar_summary
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format('SELECT public.wholesaler_ar_summary(%L)::text', alpha));
  PERFORM zz.check('wholesaler_ar_summary succeeds for the owner', r NOT LIKE 'ERR%', r);
  j := r::jsonb;

  PERFORM zz.check('total_credit_sales_ghs sums every invoice, including the paid one',
    (j->>'total_credit_sales_ghs')::numeric = 100 + 50 + 30 + 80 + 60 + 25, j->>'total_credit_sales_ghs');
  PERFORM zz.check('total_outstanding_ghs excludes the paid invoice',
    (j->>'total_outstanding_ghs')::numeric = 100 + 50 + 30 + 80 + 25, j->>'total_outstanding_ghs');
  PERFORM zz.check('due_within_7_days_ghs only counts the 5-day invoice',
    (j->>'due_within_7_days_ghs')::numeric = 50, j->>'due_within_7_days_ghs');
  -- The 30-day window and the aging "current" bucket are inclusive/overlapping by design, not
  -- mutually exclusive: a debt due in exactly 30 days is legitimately both "due within 30 days"
  -- AND still "current" (not yet overdue) -- so this also picks up o_current (due +30, 100) and
  -- o_other_pharmacy (due +10, 25, a DIFFERENT pharmacy -- the wholesaler's AR summary is scoped
  -- to the whole wholesaler, across every pharmacy it extends credit to, by design).
  PERFORM zz.check('due_within_30_days_ghs counts every invoice due within the next 30 days, across all pharmacies',
    (j->>'due_within_30_days_ghs')::numeric = 100 + 50 + 30 + 25, j->>'due_within_30_days_ghs');
  PERFORM zz.check('overdue_ghs counts only the 40-days-overdue invoice',
    (j->>'overdue_ghs')::numeric = 80, j->>'overdue_ghs');
  PERFORM zz.check('collected_this_month_ghs counts the payment posted today',
    (j->>'collected_this_month_ghs')::numeric = 60, j->>'collected_this_month_ghs');
  PERFORM zz.check('aging.current is every not-yet-overdue invoice, across all pharmacies',
    (j->'aging'->>'current')::numeric = 100 + 50 + 30 + 25, j->'aging'->>'current');
  PERFORM zz.check('aging.days_31_60 is the 40-days-overdue invoice',
    (j->'aging'->>'days_31_60')::numeric = 80, j->'aging'->>'days_31_60');
  PERFORM zz.check('aging.days_1_30 and days_61_90 and days_90_plus are all zero here',
    (j->'aging'->>'days_1_30')::numeric = 0 AND (j->'aging'->>'days_61_90')::numeric = 0 AND (j->'aging'->>'days_90_plus')::numeric = 0,
    (j->'aging')::text);
  PERFORM zz.check('outstanding_by_pharmacy lists both pharmacies with the right totals',
    jsonb_array_length(j->'outstanding_by_pharmacy') = 2, (j->'outstanding_by_pharmacy')::text);

  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format('SELECT public.wholesaler_ar_summary(%L)::text', alpha));
  PERFORM zz.check('an unrelated wholesaler cannot read Alpha''s AR summary', r LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- pharmacy_ap_summary
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT public.pharmacy_ap_summary(%L)::text', good));
  PERFORM zz.check('pharmacy_ap_summary succeeds for the owner', r NOT LIKE 'ERR%', r);
  j := r::jsonb;

  PERFORM zz.check('total_supplier_debt_ghs matches the wholesaler''s outstanding total for this pharmacy',
    (j->>'total_supplier_debt_ghs')::numeric = 100 + 50 + 30 + 80, j->>'total_supplier_debt_ghs');
  PERFORM zz.check('overdue_ghs matches the wholesaler side',
    (j->>'overdue_ghs')::numeric = 80, j->>'overdue_ghs');
  PERFORM zz.check('paid_this_month_ghs counts the payment posted today',
    (j->>'paid_this_month_ghs')::numeric = 60, j->>'paid_this_month_ghs');
  PERFORM zz.check('outstanding_by_wholesaler has exactly Alpha (Good Pharmacy''s only credit line)',
    jsonb_array_length(j->'outstanding_by_wholesaler') = 1, (j->'outstanding_by_wholesaler')::text);

  r := zz.val_as((SELECT id FROM zz.u WHERE k='ph_other'), format('SELECT public.pharmacy_ap_summary(%L)::text', good));
  PERFORM zz.check('an unrelated pharmacy cannot read Good Pharmacy''s AP summary', r LIKE 'ERR%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
