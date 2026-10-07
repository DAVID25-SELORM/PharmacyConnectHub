-- The older Credit-tab readers are finance-only: list_credit_invoices, get_credit_invoice,
-- wholesaler_ar_summary, pharmacy_ap_summary now use can_view_accounting().
--   wholesaler: owner, manager, finance, accountant   pharmacy: owner, manager, accountant
-- Cashiers, assistants, warehouse users, suspended staff, other organisations: refused, on both sides.
-- The data returned to the allowed roles is unchanged; the writers keep their own checks.
-- Run after setup.sql + migrations (through 20261026100000_credit_reads_finance_only.sql).
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
SELECT id, 'CR Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.ac AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
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
  (SELECT id FROM public.products WHERE name='CR Item') p_item;
CREATE TABLE zz.cr_orders(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.ac), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ac)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.ac;

SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset i1_
INSERT INTO zz.cr_orders SELECT 'i1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset i2_
INSERT INTO zz.cr_orders SELECT 'i2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Alpha's side: the wholesaler's invoices list and receivables summary.
DO $$
DECLARE r TEXT; a UUID := (SELECT alpha FROM zz.ac); denied TEXT := 'ERR: You do not have access to these credit invoices.';
  q TEXT := 'SELECT count(*)::text FROM public.list_credit_invoices(%L, NULL, NULL)';
  s TEXT := 'SELECT (public.wholesaler_ar_summary(%L)->>''total_outstanding_ghs'')';
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a));   PERFORM zz.check('list: wholesaler owner sees both invoices', r = '2', r);
  r := zz.val_as((SELECT u_wm FROM zz.ac), format(q, a));   PERFORM zz.check('list: wholesaler manager can', r = '2', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(q, a)); PERFORM zz.check('list: wholesaler finance can', r = '2', r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(q, a)); PERFORM zz.check('list: wholesaler accountant can', r = '2', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(q, a));   PERFORM zz.check('list: wholesaler cashier is refused', r = denied, r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(q, a)); PERFORM zz.check('list: wholesaler assistant is refused', r = denied, r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(q, a));  PERFORM zz.check('list: wholesaler warehouse user is refused', r = denied, r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(q, a));   PERFORM zz.check('list: another wholesaler is refused', r = denied, r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, a));   PERFORM zz.check('list: a pharmacy owner cannot list Alpha''s invoices by passing its id', r = denied, r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(s, a));   PERFORM zz.check('receivables summary: owner sees 300 outstanding', r IN ('300.00', '300'), r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(s, a)); PERFORM zz.check('receivables summary: finance can', r IN ('300.00', '300'), r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(s, a)); PERFORM zz.check('receivables summary: accountant can', r IN ('300.00', '300'), r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(s, a));   PERFORM zz.check('receivables summary: cashier is refused', r = 'ERR: You do not have access to this wholesaler''s receivables.', r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(s, a));  PERFORM zz.check('receivables summary: warehouse is refused', r = 'ERR: You do not have access to this wholesaler''s receivables.', r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(s, a)); PERFORM zz.check('receivables summary: assistant is refused', r = 'ERR: You do not have access to this wholesaler''s receivables.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(s, a));   PERFORM zz.check('receivables summary: another wholesaler is refused', r = 'ERR: You do not have access to this wholesaler''s receivables.', r);
END $$;

-- Good Pharmacy's side: its invoices list and payables summary.
DO $$
DECLARE r TEXT; g UUID := (SELECT good FROM zz.ac); denied TEXT := 'ERR: You do not have access to these credit invoices.';
  q TEXT := 'SELECT count(*)::text FROM public.list_credit_invoices(NULL, %L, NULL)';
  s TEXT := 'SELECT (public.pharmacy_ap_summary(%L)->>''total_supplier_debt_ghs'')';
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, g));    PERFORM zz.check('list: pharmacy owner sees both invoices', r = '2', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(q, g));  PERFORM zz.check('list: pharmacy accountant can', r = '2', r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(q, g)); PERFORM zz.check('list: pharmacy cashier is refused', r = denied, r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(q, g));  PERFORM zz.check('list: pharmacy assistant is refused', r = denied, r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, g));    PERFORM zz.check('list: another pharmacy is refused', r = denied, r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, g));    PERFORM zz.check('list: a wholesaler cannot list a pharmacy''s invoices by passing its id', r = denied, r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(s, g));    PERFORM zz.check('payables summary: owner sees 300 owed', r IN ('300.00', '300'), r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(s, g));  PERFORM zz.check('payables summary: accountant can', r IN ('300.00', '300'), r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(s, g)); PERFORM zz.check('payables summary: cashier is refused', r = 'ERR: You do not have access to this pharmacy''s payables.', r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(s, g));  PERFORM zz.check('payables summary: assistant is refused', r = 'ERR: You do not have access to this pharmacy''s payables.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(s, g));    PERFORM zz.check('payables summary: another pharmacy is refused', r = 'ERR: You do not have access to this pharmacy''s payables.', r);
END $$;

-- One invoice's detail: either party's finance roles; nobody else.
DO $$
DECLARE r TEXT; o UUID := (SELECT order_id FROM zz.cr_orders WHERE label = 'i2');
  q TEXT := 'SELECT (public.get_credit_invoice(%L)->>''invoice_ghs'')';
  denied TEXT := 'ERR: You do not have access to this invoice.';
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, o));    PERFORM zz.check('detail: wholesaler owner sees the 200 invoice', r IN ('200.00', '200'), r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(q, o));  PERFORM zz.check('detail: wholesaler finance can', r IN ('200.00', '200'), r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(q, o));  PERFORM zz.check('detail: wholesaler accountant can', r IN ('200.00', '200'), r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, o));    PERFORM zz.check('detail: pharmacy owner can', r IN ('200.00', '200'), r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(q, o));  PERFORM zz.check('detail: pharmacy accountant can', r IN ('200.00', '200'), r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(q, o));    PERFORM zz.check('detail: wholesaler cashier is refused', r = denied, r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(q, o));   PERFORM zz.check('detail: wholesaler warehouse is refused', r = denied, r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(q, o));  PERFORM zz.check('detail: wholesaler assistant is refused', r = denied, r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(q, o)); PERFORM zz.check('detail: pharmacy cashier is refused', r = denied, r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(q, o));  PERFORM zz.check('detail: pharmacy assistant is refused', r = denied, r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, o));    PERFORM zz.check('detail: another pharmacy is refused', r = denied, r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(q, o));    PERFORM zz.check('detail: another wholesaler is refused', r = denied, r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT jsonb_array_length(public.get_credit_invoice(%L)->''lines'')::text', o));
  PERFORM zz.check('detail: the ledger lines are still returned to the allowed roles (the invoice entry)', r = '1', r);
END $$;

-- The payment writer keeps its own rules (unchanged by this migration).
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 100, ''cash'', ''C-1'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.cr_orders WHERE label='i1'), 'amount', 100))::text));
  PERFORM zz.check('the accountant can still record a payment', r NOT LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 100, ''cash'', ''C-2'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.cr_orders WHERE label='i2'), 'amount', 100))::text));
  PERFORM zz.check('a cashier still cannot record one', r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT (public.wholesaler_ar_summary(%L)->>''total_outstanding_ghs'')', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('the summary reflects the payment: 200 left', r IN ('200.00', '200'), r);
END $$;

-- A suspended accountant and an unapproved business are refused too (can_view_accounting rules).
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '30000000-0000-0000-0000-0000000000a2';
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format('SELECT count(*)::text FROM public.list_credit_invoices(%L, NULL, NULL)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('a suspended accountant is refused', r = 'ERR: You do not have access to these credit invoices.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
