-- Credit account statements (credit_account_statement, credit_counterparties):
--   * opening balance + charges - credits = closing balance, with a running balance on every line;
--   * every ledger entry is its own line: invoices, payments (allocated and unallocated), reversals,
--     credit notes (cancellation), debit notes and write-offs - nothing netted away;
--   * range boundaries are inclusive, opening = everything dated before the range;
--   * the true balance (an overpayment is negative), reconciled with credit_exposure() and balance_today;
--   * the ageing block follows credit_aging_summary (as of today, outstanding invoices only);
--   * access: same finance-only gate as the registers, both sides, nothing across organisations,
--     no probing of unrelated businesses; the 2,000-line cap is flagged as truncated.
-- Run after setup.sql + migrations (through 20261022100000_credit_account_statements.sql).
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
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
  -- Restore the caller's identity rather than clearing it, so direct checks that follow still run as them.
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;

-- Extra staff. Wholesaler (Alpha): finance, accountant, assistant, warehouse. Pharmacy (Good): accountant, cashier, assistant.
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a1', 'afin@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000041"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a2', 'aacc@zz.test', '{"full_name":"Alpha Accountant","phone":"+233241000042"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a3', 'aass@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000043"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a4', 'awh@zz.test', '{"full_name":"Alpha Warehouse","phone":"+233241000044"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b1', 'gacc@zz.test', '{"full_name":"Good Accountant","phone":"+233241000045"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b2', 'gcash@zz.test', '{"full_name":"Good Cashier","phone":"+233241000046"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b3', 'gass@zz.test', '{"full_name":"Good Assistant","phone":"+233241000047"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = v.biz), v.uid, v.r::public.staff_role, 'active', now()
FROM (VALUES
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a1'::uuid, 'finance'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a2'::uuid, 'accountant'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a3'::uuid, 'assistant'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a4'::uuid, 'warehouse'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000b1'::uuid, 'accountant'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000b2'::uuid, 'cashier'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000b3'::uuid, 'assistant')) v(biz, uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'AC Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.ac AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Other Pharmacy') other_p,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other_w,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  '30000000-0000-0000-0000-0000000000a1'::uuid u_wfin,
  '30000000-0000-0000-0000-0000000000a2'::uuid u_wacc,
  '30000000-0000-0000-0000-0000000000a3'::uuid u_wass,
  '30000000-0000-0000-0000-0000000000a4'::uuid u_wwh,
  '30000000-0000-0000-0000-0000000000b1'::uuid u_pacc,
  '30000000-0000-0000-0000-0000000000b2'::uuid u_pcash,
  '30000000-0000-0000-0000-0000000000b3'::uuid u_pass,
  (SELECT id FROM public.products WHERE name='AC Item') p_item;
CREATE TABLE zz.ac_runs(label TEXT PRIMARY KEY, order_id UUID);
-- Direct checks below run as the wholesaler owner (a signed-in identity); val_as() switches and restores it.
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.ac), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ac)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.ac UNION ALL SELECT alpha, other_p, 1000000, 30 FROM zz.ac;

-- Three real credit invoices for Good Pharmacy: 500, 300 and 200.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset inv1_
INSERT INTO zz.ac_runs SELECT 'inv1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset inv2_
INSERT INTO zz.ac_runs SELECT 'inv2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset inv3_
INSERT INTO zz.ac_runs SELECT 'inv3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Due dates for the ageing block: inv1 is 35 days late (31-60), inv2 10 days late (1-30).
UPDATE public.orders SET credit_due_date = current_date - 35 WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='inv1');
UPDATE public.orders SET credit_due_date = current_date - 10 WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='inv2');

-- History. Payment 1: 200 bank transfer to inv1. Payment 2: 150 cash, 100 to inv2 and 50 left unallocated.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 200, ''bank_transfer'', ''BT-1'', NULL, ''First part'', NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.ac_runs WHERE label='inv1'), 'amount', 200))::text));
  PERFORM zz.check('finance records payment BT-1 (200 to inv1)', r NOT LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 150, ''cash'', ''CASH-2'', NULL, ''Counter'', NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.ac_runs WHERE label='inv2'), 'amount', 100))::text));
  PERFORM zz.check('finance records payment CASH-2 (100 to inv2, 50 unallocated)', r NOT LIKE 'ERR%', r);
END $$;

-- Backdate the history (the ledger is append-only by convention; a test fixture may set created_at).
UPDATE public.credit_ledger_entries SET created_at = (current_date - 40) + time '10:00' WHERE entry_type = 'invoice' AND order_id = (SELECT order_id FROM zz.ac_runs WHERE label='inv1');
UPDATE public.credit_ledger_entries SET created_at = (current_date - 10) + time '10:00' WHERE entry_type = 'invoice' AND order_id = (SELECT order_id FROM zz.ac_runs WHERE label='inv2');
UPDATE public.credit_ledger_entries SET created_at = (current_date - 20) + time '10:00' WHERE payment_id = (SELECT id FROM public.credit_payments WHERE reference = 'BT-1');
UPDATE public.credit_ledger_entries SET created_at = (current_date - 5) + time '10:00' WHERE payment_id = (SELECT id FROM public.credit_payments WHERE reference = 'CASH-2');
-- On-account adjustments (no invoice): a debit note of 25 three days ago and a write-off of 50 two days ago.
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_at, note)
SELECT alpha, good, NULL::uuid, 'debit_note', 'debit', 25, (current_date - 3) + time '10:00', 'Late fee' FROM zz.ac
UNION ALL SELECT alpha, good, NULL, 'write_off', 'credit', 50, (current_date - 2) + time '10:00', 'Goodwill' FROM zz.ac;

-- Today: reverse the 100 allocated to inv2 (cash was returned), and cancel inv3 (releases its 200).
DO $$
DECLARE r TEXT; e UUID;
BEGIN
  SELECT id INTO e FROM public.credit_ledger_entries WHERE entry_type = 'payment' AND order_id = (SELECT order_id FROM zz.ac_runs WHERE label='inv2');
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT public.reverse_credit_ledger_entry(%L, ''Cash was returned'')::text', e));
  PERFORM zz.check('the owner reverses the 100 allocated to inv2', r NOT LIKE 'ERR%', r);
END $$;
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='inv3');

-- 1. The statement for the last 30 days.
DO $$
DECLARE s JSONB; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac); n INT; kinds TEXT;
BEGIN
  s := public.credit_account_statement(a, g, current_date - 30, current_date);
  PERFORM zz.check('opening balance = everything before the range (inv1 500 dated 40 days ago)', (s->>'opening_balance')::numeric = 500, s->>'opening_balance');
  PERFORM zz.check('charges in range = inv2 300 + debit note 25 + inv3 200 + reversal 100 = 625', (s->>'total_charges')::numeric = 625, s->>'total_charges');
  PERFORM zz.check('credits in range = payment 200 + 100 + unallocated 50 + write-off 50 + credit note 200 = 600', (s->>'total_credits')::numeric = 600, s->>'total_credits');
  PERFORM zz.check('closing = opening + charges - credits = 525', (s->>'closing_balance')::numeric = 525, s->>'closing_balance');
  PERFORM zz.check('nine lines, not truncated', (s->>'line_count')::int = 9 AND jsonb_array_length(s->'lines') = 9 AND (s->>'truncated')::boolean = false, s->>'line_count');
  PERFORM zz.check('the last line''s running balance equals the closing balance', (s->'lines'->8->>'balance')::numeric = 525);
  PERFORM zz.check('balance_today (all entries) = 525 and agrees with credit_exposure()', (s->>'balance_today')::numeric = 525 AND public.credit_exposure(a, g) = 525);
  SELECT count(*) INTO n FROM (
    SELECT (l->>'balance')::numeric AS bal,
      COALESCE(lag((l->>'balance')::numeric) OVER (ORDER BY ord), (s->>'opening_balance')::numeric) + (l->>'debit')::numeric - (l->>'credit')::numeric AS expected
    FROM jsonb_array_elements(s->'lines') WITH ORDINALITY t(l, ord)
  ) x WHERE x.bal <> x.expected;
  PERFORM zz.check('every line''s balance = the previous balance + its charge - its credit', n = 0, n::text);
  PERFORM zz.check('lines are in date order', (SELECT bool_and((l->>'date') >= COALESCE(prev, '')) FROM (SELECT l, lag(l->>'date') OVER (ORDER BY ord) AS prev FROM jsonb_array_elements(s->'lines') WITH ORDINALITY t(l, ord)) y) IS NOT FALSE);
  SELECT string_agg(k || '=' || c, ' ' ORDER BY k) INTO kinds FROM (SELECT l->>'entry_type' k, count(*) c FROM jsonb_array_elements(s->'lines') l GROUP BY 1) q;
  PERFORM zz.check('entry types: 2 invoices, 3 payments, 1 reversal, 1 credit note, 1 debit note, 1 write-off',
    kinds = 'credit_note=1 debit_note=1 invoice=2 payment=3 reversal=1 write_off=1', kinds);
  PERFORM zz.check('a payment line carries its method and reference',
    EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'payment' AND l->>'method' = 'bank_transfer' AND l->>'reference' = 'BT-1' AND (l->>'credit')::numeric = 200));
  PERFORM zz.check('the unallocated 50 is its own line with no invoice',
    EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'payment' AND (l->>'credit')::numeric = 50 AND l->'order_id' = 'null'::jsonb AND l->>'reference' = 'CASH-2'));
  PERFORM zz.check('the reversal is a 100 charge that says it reversed a payment',
    EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'reversal' AND (l->>'debit')::numeric = 100 AND l->>'reversed_type' = 'payment'));
  PERFORM zz.check('a cancelled order shows BOTH its 200 invoice and the 200 credit note that released it',
    EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'invoice' AND (l->>'debit')::numeric = 200)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'credit_note' AND (l->>'credit')::numeric = 200));
  PERFORM zz.check('the debit note and the write-off carry their notes',
    EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'debit_note' AND l->>'note' = 'Late fee')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'write_off' AND l->>'note' = 'Goodwill'));
  PERFORM zz.check('invoice lines carry the order number', EXISTS (SELECT 1 FROM jsonb_array_elements(s->'lines') l WHERE l->>'entry_type' = 'invoice' AND l->>'order_number' IS NOT NULL));
  PERFORM zz.check('the parties are named from the wholesaler''s view', s->'business'->>'name' = 'Alpha Wholesale' AND s->'counterparty'->>'name' = 'Good Pharmacy' AND s->>'side' = 'wholesaler');
END $$;

-- 2. Range boundaries.
DO $$
DECLARE s JSONB; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac);
BEGIN
  s := public.credit_account_statement(a, g, current_date - 60, current_date - 30);
  PERFORM zz.check('60..30 days ago: opening 0, just inv1 500, closing 500', (s->>'opening_balance')::numeric = 0 AND (s->>'line_count')::int = 1 AND (s->>'closing_balance')::numeric = 500, s::text);
  s := public.credit_account_statement(a, g, current_date - 40, current_date - 40);
  PERFORM zz.check('a one-day range is inclusive at both ends (inv1 is dated exactly 40 days ago)', (s->>'line_count')::int = 1 AND (s->>'opening_balance')::numeric = 0, s->>'line_count');
  s := public.credit_account_statement(a, g, current_date - 39, current_date - 39);
  PERFORM zz.check('the next day: nothing in range, the opening balance already includes inv1', (s->>'line_count')::int = 0 AND (s->>'opening_balance')::numeric = 500 AND (s->>'closing_balance')::numeric = 500 AND s->'lines' = '[]'::jsonb);
  s := public.credit_account_statement(a, g, current_date - 45, current_date - 41);
  PERFORM zz.check('before any activity: opening 0, closing 0, no lines', (s->>'opening_balance')::numeric = 0 AND (s->>'closing_balance')::numeric = 0 AND (s->>'line_count')::int = 0);
  s := public.credit_account_statement(a, g, current_date + 1, current_date + 5);
  PERFORM zz.check('after all activity: opening = closing = 525', (s->>'opening_balance')::numeric = 525 AND (s->>'closing_balance')::numeric = 525 AND (s->>'line_count')::int = 0);
  s := public.credit_account_statement(a, g, current_date - 19, current_date - 6);
  PERFORM zz.check('a middle range: opening 300 (500 - 200), inv2 +300 -> closing 600', (s->>'opening_balance')::numeric = 300 AND (s->>'closing_balance')::numeric = 600 AND (s->>'line_count')::int = 1, s::text);
  PERFORM zz.check('a middle range that ends in the past still reports the balance today', (s->>'balance_today')::numeric = 525);
END $$;

-- 3. Ageing (as of today, outstanding invoices only) agrees with the summary function.
DO $$
DECLARE s JSONB; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac); agg TEXT;
BEGIN
  s := public.credit_account_statement(a, g, current_date - 30, current_date);
  SELECT string_agg((x->>'bucket') || '=' || (x->>'invoices') || '/' || ((x->>'outstanding_ghs')::numeric(12,2))::text, ' ' ORDER BY x->>'bucket') INTO agg FROM jsonb_array_elements(s->'aging') x;
  PERFORM zz.check('ageing: all five buckets; inv1 300 left (31-60 days), inv2 300 (1-30 days); the cancelled invoice is not aged',
    agg = 'current=0/0.00 d1_30=1/300.00 d31_60=1/300.00 d61_90=0/0.00 d90_plus=0/0.00', agg);
  PERFORM zz.check('the ageing block is dated today', (s->>'aging_as_of')::date = current_date);
  PERFORM zz.check('the ageing block equals credit_aging_summary for the same pair',
    (SELECT sum((x->>'outstanding_ghs')::numeric) FROM jsonb_array_elements(s->'aging') x) = (SELECT sum(outstanding_ghs) FROM public.credit_aging_summary(a, g)));
END $$;

-- 4. Validation and unrelated parties.
DO $$
DECLARE r TEXT; q TEXT; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac);
BEGIN
  q := 'SELECT public.credit_account_statement(%L, %L, %L, %L)::text';
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a, g, current_date, current_date - 1));
  PERFORM zz.check('a range that runs backwards is refused', r = 'ERR: Choose a valid date range for the statement.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), 'SELECT public.credit_account_statement(''' || a || ''', ''' || g || ''', NULL, current_date)::text');
  PERFORM zz.check('a missing date is refused', r = 'ERR: Choose a valid date range for the statement.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a, g, current_date - 2000, current_date));
  PERFORM zz.check('more than five years is refused', r = 'ERR: A statement can cover at most five years.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a, gen_random_uuid(), current_date - 30, current_date));
  PERFORM zz.check('an unknown counterparty is not found', r = 'ERR: Statement not found.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a, (SELECT other_w FROM zz.ac), current_date - 30, current_date));
  PERFORM zz.check('another wholesaler cannot be the counterparty of a wholesaler', r = 'ERR: Statement not found.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, g, (SELECT other_w FROM zz.ac), current_date - 30, current_date));
  PERFORM zz.check('a pharmacy cannot open a statement with a supplier it has no credit relationship with (names cannot be probed)', r = 'ERR: Statement not found.', r);
END $$;

-- 5. Access, wholesaler side.
DO $$
DECLARE r TEXT; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac);
  q TEXT := 'SELECT (public.credit_account_statement(%L, %L, current_date - 30, current_date)->>''closing_balance'')';
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a, g));   PERFORM zz.check('wholesaler owner can open the statement', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_wm FROM zz.ac), format(q, a, g));   PERFORM zz.check('wholesaler manager can', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(q, a, g)); PERFORM zz.check('wholesaler finance can', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(q, a, g)); PERFORM zz.check('wholesaler accountant can', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(q, a, g));   PERFORM zz.check('wholesaler cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(q, a, g)); PERFORM zz.check('wholesaler assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(q, a, g));  PERFORM zz.check('wholesaler warehouse user cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(q, a, g));   PERFORM zz.check('another wholesaler''s owner cannot read Alpha''s statement', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, a, g));   PERFORM zz.check('a pharmacy owner cannot pass the wholesaler id to read it as receivables', r = 'ERR: You do not have access to these accounts.', r);
END $$;

-- 6. Access, pharmacy side: the same ledger, seen as payables.
DO $$
DECLARE r TEXT; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac); s JSONB;
  q TEXT := 'SELECT (public.credit_account_statement(%L, %L, current_date - 30, current_date)->>''closing_balance'')';
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, g, a));    PERFORM zz.check('pharmacy owner sees the same closing balance from its side', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(q, g, a));  PERFORM zz.check('pharmacy accountant can', r IN ('525.00', '525'), r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(q, g, a)); PERFORM zz.check('pharmacy cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(q, g, a));  PERFORM zz.check('pharmacy assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, g, a));    PERFORM zz.check('another pharmacy cannot read Good Pharmacy''s statement', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, g, a));    PERFORM zz.check('a wholesaler cannot pass a pharmacy id to read its payables', r = 'ERR: You do not have access to these accounts.', r);
  s := zz.val_as((SELECT u_po FROM zz.ac), format('SELECT public.credit_account_statement(%L, %L, current_date - 30, current_date)::text', g, a))::jsonb;
  PERFORM zz.check('from the pharmacy side the counterparty is the supplier and the side is pharmacy', s->'counterparty'->>'name' = 'Alpha Wholesale' AND s->>'side' = 'pharmacy' AND jsonb_array_length(s->'lines') = 9, s::text);
END $$;

-- 7. Isolation: Other Pharmacy has no activity, so its statement is empty and shows none of Good's lines.
DO $$
DECLARE s JSONB;
BEGIN
  s := public.credit_account_statement((SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac), current_date - 60, current_date);
  PERFORM zz.check('a different customer''s statement contains none of Good Pharmacy''s lines', (s->>'line_count')::int = 0 AND (s->>'closing_balance')::numeric = 0, s::text);
END $$;

-- 8. The counterparty list.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format('SELECT string_agg(counterparty_name, '','' ORDER BY counterparty_name) FROM public.credit_counterparties(%L)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('Alpha''s accountant sees Good Pharmacy and Other Pharmacy (it has credit terms with both)', r = 'Good Pharmacy,Other Pharmacy', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format('SELECT string_agg(counterparty_name, '','') FROM public.credit_counterparties(%L)', (SELECT good FROM zz.ac)));
  PERFORM zz.check('Good Pharmacy''s accountant sees only its supplier', r = 'Alpha Wholesale', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format('SELECT count(*)::text FROM public.credit_counterparties(%L)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('the list has the same gate (cashier refused)', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format('SELECT count(*)::text FROM public.credit_counterparties(%L)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('another wholesaler cannot list Alpha''s customers', r = 'ERR: You do not have access to these accounts.', r);
END $$;

-- 9. An overpayment is a negative balance; a very long statement is capped and says so.
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_at, note)
SELECT (SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac), NULL::uuid, 'adjustment', 'credit', 40, (current_date - 4) + time '09:00', 'Overpaid';
DO $$
DECLARE s JSONB;
BEGIN
  s := public.credit_account_statement((SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac), current_date - 10, current_date);
  PERFORM zz.check('a customer who has overpaid shows a NEGATIVE balance (credit held), not zero', (s->>'closing_balance')::numeric = -40 AND (s->'lines'->0->>'balance')::numeric = -40, s::text);
  PERFORM zz.check('credit_exposure() floors the same balance at zero (limits are unaffected)', public.credit_exposure((SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac)) = 0);
END $$;
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_at, note)
SELECT (SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac), NULL::uuid, 'adjustment', 'debit', 1, (current_date - 1) + time '09:00' + (g || ' seconds')::interval, 'bulk'
FROM generate_series(1, 2005) g;
DO $$
DECLARE s JSONB;
BEGIN
  s := public.credit_account_statement((SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac), current_date - 1, current_date);
  PERFORM zz.check('2,005 lines: capped at 2,000, flagged truncated, and the true count and closing balance are still reported',
    jsonb_array_length(s->'lines') = 2000 AND (s->>'truncated')::boolean AND (s->>'line_count')::int = 2005 AND (s->>'closing_balance')::numeric = -40 + 2005, s->>'line_count');
  PERFORM zz.check('the running balance on the 2,000th returned line is still correct', (s->'lines'->1999->>'balance')::numeric = -40 + 2000);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
