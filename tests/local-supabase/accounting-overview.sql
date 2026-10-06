-- Accounting overview (accounting_overview): the numbers behind the finance part of the dashboard.
--   * totals, overdue, due-soon (today..+7 days), disputed, all on the OUTSTANDING balance;
--   * the five aging buckets agree with credit_aging_summary AND with the Credit tab's own summary
--     (wholesaler_ar_summary / pharmacy_ap_summary) - one aging rule across every screen;
--   * top overdue counterparties, largest first, bounded by p_top;
--   * payments in the last 30 days, and money on account that is not matched to an invoice;
--   * both sides see the same ledger; finance-only access; nothing crosses organisations.
-- Run after setup.sql + migrations (through 20261025100000_accounting_overview.sql).
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
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;

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
SELECT id, 'AO Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true FROM zz.b WHERE name='Alpha Wholesale';
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
  (SELECT id FROM public.products WHERE name='AO Item') p_item;
CREATE TABLE zz.ao_runs(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.ac), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ac)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.ac UNION ALL SELECT alpha, other_p, 1000000, 30 FROM zz.ac;

-- Nothing owed yet: every figure is zero, all five buckets are present.
DO $$
DECLARE o JSONB := public.accounting_overview((SELECT alpha FROM zz.ac));
BEGIN
  PERFORM zz.check('with no credit invoices every total is zero', (o->>'outstanding_ghs')::numeric = 0 AND (o->>'invoice_count')::int = 0 AND (o->>'overdue_ghs')::numeric = 0 AND (o->>'due_soon_count')::int = 0, o::text);
  PERFORM zz.check('all five aging buckets are present even when empty', jsonb_array_length(o->'aging') = 5 AND (SELECT bool_and((x->>'outstanding_ghs')::numeric = 0) FROM jsonb_array_elements(o->'aging') x));
  PERFORM zz.check('top_overdue is an empty list, and payments and on-account are zero', o->'top_overdue' = '[]'::jsonb AND (o->'payments_30d'->>'count')::int = 0 AND (o->'on_account'->>'total_ghs')::numeric = 0);
END $$;

-- Invoices for Good Pharmacy (100 each unless noted), due dates set below.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset c1_
INSERT INTO zz.ao_runs SELECT 'c1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset d3_
INSERT INTO zz.ao_runs SELECT 'd3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset d0_
INSERT INTO zz.ao_runs SELECT 'd0', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l5_
INSERT INTO zz.ao_runs SELECT 'l5', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l40_
INSERT INTO zz.ao_runs SELECT 'l40', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l100_
INSERT INTO zz.ao_runs SELECT 'l100', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset disp_
INSERT INTO zz.ao_runs SELECT 'disp', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset paid_
INSERT INTO zz.ao_runs SELECT 'paid', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset cancelled_
INSERT INTO zz.ao_runs SELECT 'cancelled', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset partial_
INSERT INTO zz.ao_runs SELECT 'partial', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ac), (SELECT other_p FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset o1_
INSERT INTO zz.ao_runs SELECT 'o1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

UPDATE public.orders SET credit_due_date = current_date + 10 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='c1');
UPDATE public.orders SET credit_due_date = current_date + 3 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='d3');
UPDATE public.orders SET credit_due_date = current_date WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='d0');
UPDATE public.orders SET credit_due_date = current_date - 5 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='l5');
UPDATE public.orders SET credit_due_date = current_date - 40 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='l40');
UPDATE public.orders SET credit_due_date = current_date - 100 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='l100');
UPDATE public.orders SET credit_due_date = current_date - 10 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='disp');
UPDATE public.orders SET credit_due_date = current_date - 10 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='paid');
UPDATE public.orders SET credit_due_date = current_date - 10 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='cancelled');
UPDATE public.orders SET credit_due_date = current_date - 2 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='partial');
UPDATE public.orders SET credit_due_date = current_date - 20 WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='o1');
UPDATE public.orders SET credit_disputed_at = now() WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='disp');
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.ao_runs WHERE label='cancelled');

-- Payments. P1 (200): clears "paid", part-pays "partial" - then dated 40 days ago (outside the 30-day window).
-- P2 (150, cash): 50 to "c1" and 100 left unmatched ("on account").
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 200, ''bank_transfer'', ''P1'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(
      jsonb_build_object('order_id', (SELECT order_id FROM zz.ao_runs WHERE label='paid'), 'amount', 100),
      jsonb_build_object('order_id', (SELECT order_id FROM zz.ao_runs WHERE label='partial'), 'amount', 100))::text));
  PERFORM zz.check('finance records P1: 100 clears "paid", 100 part-pays "partial"', r NOT LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 150, ''cash'', ''P2'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.ao_runs WHERE label='c1'), 'amount', 50))::text));
  PERFORM zz.check('the accountant records P2: 50 to "c1", 100 unmatched', r NOT LIKE 'ERR%', r);
END $$;
UPDATE public.credit_payments SET paid_at = now() - interval '40 days' WHERE reference = 'P1';

-- 1. Alpha's overview (the wholesaler's receivables).
DO $$
DECLARE o JSONB := public.accounting_overview((SELECT alpha FROM zz.ac)); a UUID := (SELECT alpha FROM zz.ac); s TEXT;
BEGIN
  PERFORM zz.check('outstanding = 1,050 on 9 invoices (paid and cancelled excluded; "c1" and "partial" count what is left)', (o->>'outstanding_ghs')::numeric = 1050 AND (o->>'invoice_count')::int = 9, (o->>'outstanding_ghs') || '/' || (o->>'invoice_count'));
  PERFORM zz.check('overdue = 800 on 6 invoices (everything past its due date, disputed included)', (o->>'overdue_ghs')::numeric = 800 AND (o->>'overdue_count')::int = 6, (o->>'overdue_ghs') || '/' || (o->>'overdue_count'));
  PERFORM zz.check('due soon = 200 on 2 invoices (due today and in 3 days; the one due in 10 days is not)', (o->>'due_soon_ghs')::numeric = 200 AND (o->>'due_soon_count')::int = 2, (o->>'due_soon_ghs') || '/' || (o->>'due_soon_count'));
  PERFORM zz.check('disputed = 100 on 1 invoice (still owed, and reported separately)', (o->>'disputed_ghs')::numeric = 100 AND (o->>'disputed_count')::int = 1);
  SELECT string_agg((x->>'bucket') || '=' || (x->>'invoices') || '/' || ((x->>'outstanding_ghs')::numeric(12,2))::text, ' ' ORDER BY (SELECT ord FROM (VALUES ('current', 1), ('d1_30', 2), ('d31_60', 3), ('d61_90', 4), ('d90_plus', 5)) k(b, ord) WHERE k.b = x->>'bucket'))
    INTO s FROM jsonb_array_elements(o->'aging') x;
  PERFORM zz.check('aging: current 3 / 250, 1-30: 4 / 500, 31-60: 1 / 200, 61-90: 0, 90+: 1 / 100', s = 'current=3/250.00 d1_30=4/500.00 d31_60=1/200.00 d61_90=0/0.00 d90_plus=1/100.00', s);
  PERFORM zz.check('the buckets add up to the outstanding total', (SELECT sum((x->>'outstanding_ghs')::numeric) FROM jsonb_array_elements(o->'aging') x) = (o->>'outstanding_ghs')::numeric);
  PERFORM zz.check('overdue is exactly the sum of every bucket except current', (SELECT sum((x->>'outstanding_ghs')::numeric) FROM jsonb_array_elements(o->'aging') x WHERE x->>'bucket' <> 'current') = (o->>'overdue_ghs')::numeric);
  PERFORM zz.check('the aging buckets equal credit_aging_summary, bucket for bucket',
    (SELECT bool_and((x->>'outstanding_ghs')::numeric = c.outstanding_ghs AND (x->>'invoices')::bigint = c.invoices)
       FROM jsonb_array_elements(o->'aging') x JOIN public.credit_aging_summary(a) c ON c.bucket = x->>'bucket'));
  PERFORM zz.check('and equal the Credit tab''s own summary (wholesaler_ar_summary): total and every aging bucket - one rule on every screen',
    (SELECT (r->>'total_outstanding_ghs')::numeric = (o->>'outstanding_ghs')::numeric
        AND (r->'aging'->>'current')::numeric = 250 AND (r->'aging'->>'days_1_30')::numeric = 500 AND (r->'aging'->>'days_31_60')::numeric = 200
        AND (r->'aging'->>'days_61_90')::numeric = 0 AND (r->'aging'->>'days_90_plus')::numeric = 100
        FROM (SELECT public.wholesaler_ar_summary(a) AS r) q),
    (SELECT public.wholesaler_ar_summary(a)::text));
END $$;

-- 2. Top overdue counterparties, payments and money on account.
DO $$
DECLARE o JSONB := public.accounting_overview((SELECT alpha FROM zz.ac)); t JSONB;
BEGIN
  PERFORM zz.check('top overdue: Good Pharmacy first (700 on 5 invoices, oldest 100 days), then Other Pharmacy (100 on 1, 20 days)',
    jsonb_array_length(o->'top_overdue') = 2
    AND o->'top_overdue'->0->>'counterparty_name' = 'Good Pharmacy' AND (o->'top_overdue'->0->>'overdue_ghs')::numeric = 700 AND (o->'top_overdue'->0->>'invoices')::int = 5 AND (o->'top_overdue'->0->>'oldest_days_overdue')::int = 100
    AND o->'top_overdue'->1->>'counterparty_name' = 'Other Pharmacy' AND (o->'top_overdue'->1->>'overdue_ghs')::numeric = 100 AND (o->'top_overdue'->1->>'invoices')::int = 1 AND (o->'top_overdue'->1->>'oldest_days_overdue')::int = 20,
    o->>'top_overdue');
  t := public.accounting_overview((SELECT alpha FROM zz.ac), 1);
  PERFORM zz.check('p_top = 1 returns only the largest', jsonb_array_length(t->'top_overdue') = 1 AND t->'top_overdue'->0->>'counterparty_name' = 'Good Pharmacy');
  PERFORM zz.check('a customer with nothing overdue is not listed', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o->'top_overdue') x WHERE (x->>'overdue_ghs')::numeric <= 0));
  PERFORM zz.check('payments in the last 30 days: only P2 (150); P1 was 40 days ago', (o->'payments_30d'->>'count')::int = 1 AND (o->'payments_30d'->>'total_ghs')::numeric = 150, o->>'payments_30d');
  PERFORM zz.check('on account: the 100 of P2 not matched to an invoice, with one customer', (o->'on_account'->>'total_ghs')::numeric = 100 AND (o->'on_account'->>'parties')::int = 1, o->>'on_account');
  PERFORM zz.check('the date is today', (o->>'as_of')::date = current_date AND o->>'side' = 'wholesaler');
END $$;

-- 3. The pharmacy side sees the same ledger as payables.
DO $$
DECLARE o JSONB := zz.val_as((SELECT u_po FROM zz.ac), format('SELECT public.accounting_overview(%L)::text', (SELECT good FROM zz.ac)))::jsonb;
BEGIN
  PERFORM zz.check('Good Pharmacy owes 950 (Alpha''s 1,050 less Other Pharmacy''s 100), 700 overdue', (o->>'outstanding_ghs')::numeric = 950 AND (o->>'overdue_ghs')::numeric = 700 AND o->>'side' = 'pharmacy', o::text);
  PERFORM zz.check('its top overdue is the supplier: Alpha Wholesale, 700', jsonb_array_length(o->'top_overdue') = 1 AND o->'top_overdue'->0->>'counterparty_name' = 'Alpha Wholesale' AND (o->'top_overdue'->0->>'overdue_ghs')::numeric = 700);
  PERFORM zz.check('it sees the same payment (150) and the same 100 on account', (o->'payments_30d'->>'total_ghs')::numeric = 150 AND (o->'on_account'->>'total_ghs')::numeric = 100);
  PERFORM zz.check('its aging equals the Credit tab''s own summary (pharmacy_ap_summary)',
    (SELECT (r->'aging'->>'current')::numeric = 250 AND (r->'aging'->>'days_1_30')::numeric = 400 AND (r->'aging'->>'days_31_60')::numeric = 200 AND (r->'aging'->>'days_90_plus')::numeric = 100
       FROM (SELECT zz.val_as((SELECT u_po FROM zz.ac), format('SELECT public.pharmacy_ap_summary(%L)::text', (SELECT good FROM zz.ac)))::jsonb AS r) q),
    zz.val_as((SELECT u_po FROM zz.ac), format('SELECT public.pharmacy_ap_summary(%L)::text', (SELECT good FROM zz.ac))));
END $$;

-- 4. Isolation: the other pharmacy sees only its own 100, none of Good Pharmacy's.
DO $$
DECLARE o JSONB := zz.val_as((SELECT u_px FROM zz.ac), format('SELECT public.accounting_overview(%L)::text', (SELECT other_p FROM zz.ac)))::jsonb;
BEGIN
  PERFORM zz.check('the other pharmacy: 100 owed, all overdue, no payments, nothing on account', (o->>'outstanding_ghs')::numeric = 100 AND (o->>'overdue_ghs')::numeric = 100 AND (o->'payments_30d'->>'count')::int = 0 AND (o->'on_account'->>'total_ghs')::numeric = 0, o::text);
END $$;

-- 5. Validation and access.
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '30000000-0000-0000-0000-0000000000a2';
DO $$
DECLARE r TEXT; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac);
  q TEXT := 'SELECT (public.accounting_overview(%L)->>''invoice_count'')';
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT public.accounting_overview(%L, 0)::text', a));
  PERFORM zz.check('a list size of 0 is refused', r = 'ERR: The list size must be between 1 and 20.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT public.accounting_overview(%L, 21)::text', a));
  PERFORM zz.check('a list size above 20 is refused', r = 'ERR: The list size must be between 1 and 20.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a));   PERFORM zz.check('wholesaler owner can open it', r = '9', r);
  r := zz.val_as((SELECT u_wm FROM zz.ac), format(q, a));   PERFORM zz.check('wholesaler manager can', r = '9', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(q, a)); PERFORM zz.check('wholesaler finance can', r = '9', r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(q, a)); PERFORM zz.check('a suspended (inactive) accountant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(q, a));   PERFORM zz.check('wholesaler cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(q, a)); PERFORM zz.check('wholesaler assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(q, a));  PERFORM zz.check('wholesaler warehouse user cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(q, a));   PERFORM zz.check('another wholesaler cannot read Alpha''s', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, a));   PERFORM zz.check('a pharmacy owner cannot pass the wholesaler''s id', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, g));   PERFORM zz.check('pharmacy owner can open its own', r = '8', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(q, g)); PERFORM zz.check('pharmacy accountant can', r = '8', r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(q, g)); PERFORM zz.check('pharmacy cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(q, g)); PERFORM zz.check('pharmacy assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, g));   PERFORM zz.check('another pharmacy cannot read Good Pharmacy''s', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, g));   PERFORM zz.check('a wholesaler cannot pass a pharmacy''s id', r = 'ERR: You do not have access to these accounts.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
