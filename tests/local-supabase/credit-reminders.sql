-- Credit due-date reminders (credit_reminder_kind, generate_credit_reminders, refresh_my_credit_reminders):
--   * every reminder level boundary (due in 1-3 days, due today, 1-6, 7-29, 30+ days overdue);
--   * one grouped notification per business per level; each invoice announced ONCE per level, again only
--     when it reaches a more urgent level; paid, cancelled, written-off and disputed invoices are skipped;
--     a part-paid invoice is reminded for what is left;
--   * recipients: owner + active staff who can open Accounting, nobody else; the wholesaler hears only about
--     overdue invoices; nothing crosses organisations;
--   * the scheduler entry point is not callable by users; the page-load entry point is finance-only and throttled.
-- Run after setup.sql + migrations (through 20261024100000_credit_due_reminders.sql).
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


-- Good Pharmacy's assistant becomes an INACTIVE accountant: must receive nothing.
UPDATE public.business_staff SET role = 'accountant'::public.staff_role, status = 'inactive' WHERE user_id = '30000000-0000-0000-0000-0000000000b3';

CREATE TABLE zz.cr_orders(label TEXT PRIMARY KEY, order_id UUID, order_number TEXT);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset r4_
INSERT INTO zz.cr_orders SELECT 'r4', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (4) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'r4');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset r3_
INSERT INTO zz.cr_orders SELECT 'r3', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (3) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'r3');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset r1_
INSERT INTO zz.cr_orders SELECT 'r1', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (1) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'r1');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset r0_
INSERT INTO zz.cr_orders SELECT 'r0', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (0) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'r0');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l1_
INSERT INTO zz.cr_orders SELECT 'l1', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-1) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l1');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l6_
INSERT INTO zz.cr_orders SELECT 'l6', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-6) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l6');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l7_
INSERT INTO zz.cr_orders SELECT 'l7', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-7) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l7');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l29_
INSERT INTO zz.cr_orders SELECT 'l29', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-29) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l29');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset l30_
INSERT INTO zz.cr_orders SELECT 'l30', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-30) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l30');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset paid_
INSERT INTO zz.cr_orders SELECT 'paid', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-10) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'paid');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset cancelled_
INSERT INTO zz.cr_orders SELECT 'cancelled', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-10) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'cancelled');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset disputed_
INSERT INTO zz.cr_orders SELECT 'disputed', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-10) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'disputed');
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset partial_
INSERT INTO zz.cr_orders SELECT 'partial', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date + (-2) WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'partial');
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ac), (SELECT other_p FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset other_
INSERT INTO zz.cr_orders SELECT 'other', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'other');

-- Settle one invoice, part-pay another (100 left), cancel one, dispute one.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 200, ''bank_transfer'', ''BT-9'', NULL, ''Part'', NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(
      jsonb_build_object('order_id', (SELECT order_id FROM zz.cr_orders WHERE label='paid'), 'amount', 100),
      jsonb_build_object('order_id', (SELECT order_id FROM zz.cr_orders WHERE label='partial'), 'amount', 100))::text));
  PERFORM zz.check('finance records 200: clears the "paid" invoice and part-pays "partial" (100 left)', r NOT LIKE 'ERR%', r);
END $$;
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'cancelled');
UPDATE public.orders SET credit_disputed_at = now() WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'disputed');

-- 1. The levels, at every boundary.
DO $$
BEGIN
  PERFORM zz.check('due in 4 days: no reminder yet', public.credit_reminder_kind(current_date + 4, current_date) IS NULL);
  PERFORM zz.check('due in 3 days: due_soon', public.credit_reminder_kind(current_date + 3, current_date) = 'due_soon');
  PERFORM zz.check('due in 1 day: due_soon', public.credit_reminder_kind(current_date + 1, current_date) = 'due_soon');
  PERFORM zz.check('due today: due_today', public.credit_reminder_kind(current_date, current_date) = 'due_today');
  PERFORM zz.check('1 day overdue: overdue_1', public.credit_reminder_kind(current_date - 1, current_date) = 'overdue_1');
  PERFORM zz.check('6 days overdue: overdue_1', public.credit_reminder_kind(current_date - 6, current_date) = 'overdue_1');
  PERFORM zz.check('7 days overdue: overdue_7', public.credit_reminder_kind(current_date - 7, current_date) = 'overdue_7');
  PERFORM zz.check('29 days overdue: overdue_7', public.credit_reminder_kind(current_date - 29, current_date) = 'overdue_7');
  PERFORM zz.check('30 days overdue: overdue_30', public.credit_reminder_kind(current_date - 30, current_date) = 'overdue_30');
  PERFORM zz.check('400 days overdue: still overdue_30', public.credit_reminder_kind(current_date - 400, current_date) = 'overdue_30');
  PERFORM zz.check('no due date: no reminder', public.credit_reminder_kind(NULL, current_date) IS NULL);
END $$;

-- 2. First run. (Run counts are kept in a table: psql variables are not expanded inside DO blocks.)
CREATE TABLE zz.cr_runs(seq SERIAL PRIMARY KEY, label TEXT, n INTEGER);
DO $$ BEGIN INSERT INTO zz.cr_runs(label, n) SELECT 'first', public.generate_credit_reminders(NULL); END $$;
DO $$
DECLARE n INTEGER := (SELECT n FROM zz.cr_runs WHERE label = 'first');
BEGIN
  PERFORM zz.check('the first run creates 23 notifications (Good 5 levels x 2 people, Alpha 3 levels x 4 people, Other Pharmacy 1)', n = 23, n::text);
  PERFORM zz.check('23 reminders exist in total', (SELECT count(*) FROM public.notifications WHERE type = 'credit_reminder') = 23);
END $$;

-- 3. Who got what.
DO $$
DECLARE
  cnt INT; t TEXT;
BEGIN
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_po FROM zz.ac);
  PERFORM zz.check('Good Pharmacy''s owner gets all five levels', cnt = 5, cnt::text);
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = '30000000-0000-0000-0000-0000000000b1';
  PERFORM zz.check('Good Pharmacy''s accountant gets all five levels', cnt = 5, cnt::text);
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = '30000000-0000-0000-0000-0000000000b2';
  PERFORM zz.check('Good Pharmacy''s cashier gets nothing (cannot open Accounting)', cnt = 0, cnt::text);
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = '30000000-0000-0000-0000-0000000000b3';
  PERFORM zz.check('an inactive (suspended) accountant gets nothing', cnt = 0, cnt::text);
  FOREACH t IN ARRAY ARRAY['w_owner', 'w_manager'] LOOP
    SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT id FROM zz.u WHERE k = t);
    PERFORM zz.check('Alpha''s ' || t || ' gets the three overdue levels only', cnt = 3, cnt::text);
  END LOOP;
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id IN ('30000000-0000-0000-0000-0000000000a1', '30000000-0000-0000-0000-0000000000a2');
  PERFORM zz.check('Alpha''s finance user and accountant each get the three overdue levels', cnt = 6, cnt::text);
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id IN ((SELECT u_wc FROM zz.ac), '30000000-0000-0000-0000-0000000000a3', '30000000-0000-0000-0000-0000000000a4');
  PERFORM zz.check('Alpha''s cashier, assistant and warehouse user get nothing', cnt = 0, cnt::text);
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_wx FROM zz.ac);
  PERFORM zz.check('another wholesaler gets nothing', cnt = 0, cnt::text);
  PERFORM zz.check('the wholesaler is never told about due_soon or due_today (that is the pharmacy''s reminder)',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_wo FROM zz.ac) AND metadata->>'kind' IN ('due_soon', 'due_today')));
  SELECT count(*) INTO cnt FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_px FROM zz.ac);
  PERFORM zz.check('Other Pharmacy''s owner gets just its own due-today reminder', cnt = 1 AND (SELECT metadata->>'kind' FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_px FROM zz.ac)) = 'due_today');
END $$;

-- 4. What each notification says.
DO $$
DECLARE r RECORD; good_owner UUID := (SELECT u_po FROM zz.ac); alpha_owner UUID := (SELECT u_wo FROM zz.ac);
BEGIN
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = good_owner AND metadata->>'kind' = 'due_soon';
  PERFORM zz.check('pharmacy due_soon: titled and totals 2 invoices / GHS 200.00, links to its Accounting', r.title = 'Credit payments due soon' AND r.body LIKE '2 invoices, GHS 200.00 outstanding: %' AND r.link = '/pharmacy/accounting', r.title || ' / ' || r.body || ' / ' || COALESCE(r.link, 'null'));
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = good_owner AND metadata->>'kind' = 'due_today';
  PERFORM zz.check('pharmacy due_today: 1 invoice, GHS 100.00', r.title = 'Credit payments due today' AND r.body LIKE '1 invoice, GHS 100.00 outstanding: %', r.body);
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = good_owner AND metadata->>'kind' = 'overdue_1';
  PERFORM zz.check('pharmacy overdue_1: 3 invoices, GHS 300.00 (the part-paid one counts for the 100 still owed)', r.body LIKE '3 invoices, GHS 300.00 outstanding: %', r.body);
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = good_owner AND metadata->>'kind' = 'overdue_7';
  PERFORM zz.check('pharmacy overdue_7: 2 invoices, GHS 200.00', r.title = 'Credit payments overdue by 7 days or more' AND r.body LIKE '2 invoices, GHS 200.00 outstanding: %', r.body);
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = good_owner AND metadata->>'kind' = 'overdue_30';
  PERFORM zz.check('pharmacy overdue_30: 1 invoice, GHS 100.00', r.title = 'Credit payments overdue by 30 days or more' AND r.body LIKE '1 invoice, GHS 100.00 outstanding: %', r.body);
  SELECT * INTO r FROM public.notifications WHERE type = 'credit_reminder' AND user_id = alpha_owner AND metadata->>'kind' = 'overdue_1';
  PERFORM zz.check('wholesaler overdue_1: 3 invoices, GHS 300.00, names the customer, links to its Accounting',
    r.title = 'Customer credit payments overdue' AND r.body LIKE '3 invoices, GHS 300.00 outstanding: %(Good Pharmacy)%' AND r.link = '/wholesaler/accounting', r.title || ' / ' || r.body);
  PERFORM zz.check('the invoice numbers are listed',
    (SELECT body FROM public.notifications WHERE type = 'credit_reminder' AND user_id = alpha_owner AND metadata->>'kind' = 'overdue_30') LIKE '%' || (SELECT order_number FROM zz.cr_orders WHERE label = 'l30') || '%');
  PERFORM zz.check('metadata carries the business, the level and the invoice count', (SELECT metadata->>'invoices' = '3' AND metadata->>'business_id' = (SELECT alpha FROM zz.ac)::text FROM public.notifications WHERE type = 'credit_reminder' AND user_id = alpha_owner AND metadata->>'kind' = 'overdue_1'));
  PERFORM zz.check('paid, cancelled and disputed invoices and the one due in 4 days are in NO reminder',
    NOT EXISTS (SELECT 1 FROM public.notifications n JOIN zz.cr_orders c ON c.label IN ('paid', 'cancelled', 'disputed', 'r4') WHERE n.type = 'credit_reminder' AND position(c.order_number IN n.body) > 0));
  PERFORM zz.check('nothing in Good Pharmacy''s notifications mentions Other Pharmacy''s invoice',
    NOT EXISTS (SELECT 1 FROM public.notifications n WHERE n.type = 'credit_reminder' AND n.user_id IN (good_owner, '30000000-0000-0000-0000-0000000000b1') AND position((SELECT order_number FROM zz.cr_orders WHERE label = 'other') IN n.body) > 0));
END $$;

-- 5. Once per level; escalation announces again; a lifted dispute is announced.
DO $$ BEGIN INSERT INTO zz.cr_runs(label, n) SELECT 'second', public.generate_credit_reminders(NULL); END $$;
DO $$
BEGIN
  PERFORM zz.check('running again straight away creates nothing (each invoice is announced once per level)', (SELECT n FROM zz.cr_runs WHERE label = 'second') = 0 AND (SELECT count(*) FROM public.notifications WHERE type = 'credit_reminder') = 23);
END $$;
UPDATE public.orders SET credit_due_date = current_date - 7 WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l1');
DO $$ BEGIN INSERT INTO zz.cr_runs(label, n) SELECT 'escalated', public.generate_credit_reminders(NULL); END $$;
DO $$
DECLARE n INTEGER := (SELECT n FROM zz.cr_runs WHERE label = 'escalated');
BEGIN
  PERFORM zz.check('an invoice that reaches a more urgent level is announced again: 1 invoice, pharmacy (2 people) + wholesaler (4 people) = 6', n = 6, n::text);
  PERFORM zz.check('only the NEW level was announced (one new overdue_7 for the pharmacy, 1 invoice)', (SELECT body LIKE '1 invoice, GHS 100.00 outstanding: %' FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_po FROM zz.ac) AND metadata->>'kind' = 'overdue_7' ORDER BY created_at DESC, id LIMIT 1));
END $$;
UPDATE public.orders SET credit_disputed_at = NULL WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'disputed');
DO $$ BEGIN INSERT INTO zz.cr_runs(label, n) SELECT 'undisputed', public.generate_credit_reminders(NULL); END $$;
DO $$
DECLARE n INTEGER := (SELECT n FROM zz.cr_runs WHERE label = 'undisputed');
BEGIN
  PERFORM zz.check('once a dispute is lifted the invoice is announced at its level (10 days overdue = overdue_7): 6 notifications', n = 6, n::text);
  PERFORM zz.check('and it is logged once', (SELECT count(*) FROM public.credit_reminders_sent WHERE order_id = (SELECT order_id FROM zz.cr_orders WHERE label = 'disputed')) = 1);
END $$;
-- Paying an invoice in full stops its reminders: settle the 29-days-overdue invoice, then make it look 31 days overdue (a new level).
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 100, ''cash'', ''C-30'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.cr_orders WHERE label='l29'), 'amount', 100))::text));
  PERFORM zz.check('finance settles the 29-days-overdue invoice', r NOT LIKE 'ERR%', r);
END $$;
UPDATE public.orders SET credit_due_date = current_date - 31 WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'l29');
DO $$ BEGIN INSERT INTO zz.cr_runs(label, n) SELECT 'paid_then_older', public.generate_credit_reminders(NULL); END $$;
DO $$
BEGIN
  PERFORM zz.check('a paid invoice is never reminded about, even when its due date would put it at a new level', (SELECT n FROM zz.cr_runs WHERE label = 'paid_then_older') = 0);
END $$;

-- 6. Scheduler entry point is not for users; the page-load entry point is finance-only and throttled.
DO $$
DECLARE r TEXT; alpha UUID := (SELECT alpha FROM zz.ac); good UUID := (SELECT good FROM zz.ac);
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ac), 'SELECT public.generate_credit_reminders(NULL)::text');
  PERFORM zz.check('a user cannot run the generator directly', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', alpha));
  PERFORM zz.check('a wholesaler cashier cannot refresh', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', alpha));
  PERFORM zz.check('another wholesaler cannot refresh Alpha''s', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', good));
  PERFORM zz.check('a pharmacy cashier cannot refresh', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', alpha));
  PERFORM zz.check('Alpha''s finance user can refresh; nothing is new', r = 'ran:0', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', alpha));
  PERFORM zz.check('a second refresh within 6 hours is skipped', r = 'skipped', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', good));
  PERFORM zz.check('the pharmacy accountant can refresh its own business', r = 'ran:0', r);
END $$;

-- 7. A refresh announces what is due, to the right people.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset fresh_
INSERT INTO zz.cr_orders SELECT 'fresh', id, order_number FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET credit_due_date = current_date WHERE id = (SELECT order_id FROM zz.cr_orders WHERE label = 'fresh');
DELETE FROM public.credit_reminder_runs;
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format('SELECT public.refresh_my_credit_reminders(%L)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('a refresh by Alpha''s finance user announces the new due-today invoice to the PHARMACY (owner + accountant = 2)', r = 'ran:2', r);
  PERFORM zz.check('the wholesaler''s own people are not told about a due-today invoice',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_wo FROM zz.ac) AND body LIKE '%' || (SELECT order_number FROM zz.cr_orders WHERE label = 'fresh') || '%'));
  PERFORM zz.check('the pharmacy owner received the new due-today reminder',
    EXISTS (SELECT 1 FROM public.notifications WHERE type = 'credit_reminder' AND user_id = (SELECT u_po FROM zz.ac) AND body LIKE '%' || (SELECT order_number FROM zz.cr_orders WHERE label = 'fresh') || '%'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
