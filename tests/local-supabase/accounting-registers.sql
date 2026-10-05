-- Accounting registers: one aging rule, finance-only access, server-side filters.
--   * credit_aging_bucket: exact boundaries (current / 1-30 / 31-60 / 61-90 / 90+ days past due);
--   * aging applies to the OUTSTANDING balance (a part-paid invoice counts only what is still owed);
--   * credit_invoice_register / credit_aging_summary / list_credit_payments: filters, paging, totals;
--   * access: wholesaler owner/manager/finance/accountant and pharmacy owner/manager/accountant only,
--     active staff, approved business; nothing leaks across organizations.
-- Run after setup.sql + migrations (through 20261021100000_accounting_registers.sql).
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

-- The aging rule itself, at every boundary.
DO $$
BEGIN
  PERFORM zz.check('credit_aging_bucket(due +1 days) = current', public.credit_aging_bucket(current_date + (1), current_date) = 'current');
  PERFORM zz.check('credit_aging_bucket(due +0 days) = current', public.credit_aging_bucket(current_date + (0), current_date) = 'current');
  PERFORM zz.check('credit_aging_bucket(due -1 days) = d1_30', public.credit_aging_bucket(current_date + (-1), current_date) = 'd1_30');
  PERFORM zz.check('credit_aging_bucket(due -30 days) = d1_30', public.credit_aging_bucket(current_date + (-30), current_date) = 'd1_30');
  PERFORM zz.check('credit_aging_bucket(due -31 days) = d31_60', public.credit_aging_bucket(current_date + (-31), current_date) = 'd31_60');
  PERFORM zz.check('credit_aging_bucket(due -60 days) = d31_60', public.credit_aging_bucket(current_date + (-60), current_date) = 'd31_60');
  PERFORM zz.check('credit_aging_bucket(due -61 days) = d61_90', public.credit_aging_bucket(current_date + (-61), current_date) = 'd61_90');
  PERFORM zz.check('credit_aging_bucket(due -90 days) = d61_90', public.credit_aging_bucket(current_date + (-90), current_date) = 'd61_90');
  PERFORM zz.check('credit_aging_bucket(due -91 days) = d90_plus', public.credit_aging_bucket(current_date + (-91), current_date) = 'd90_plus');
  PERFORM zz.check('credit_aging_bucket(no due date) = current', public.credit_aging_bucket(NULL, current_date) = 'current');
END $$;

-- Invoices: nine 100-GHS invoices (one per boundary), a 10,000 invoice that will be part-paid, one that
-- will be paid in full, one cancelled, and one for the other pharmacy.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset due_tomorrow_
INSERT INTO zz.ac_runs SELECT 'due_tomorrow', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset due_today_
INSERT INTO zz.ac_runs SELECT 'due_today', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_1_
INSERT INTO zz.ac_runs SELECT 'late_1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_30_
INSERT INTO zz.ac_runs SELECT 'late_30', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_31_
INSERT INTO zz.ac_runs SELECT 'late_31', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_60_
INSERT INTO zz.ac_runs SELECT 'late_60', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_61_
INSERT INTO zz.ac_runs SELECT 'late_61', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_90_
INSERT INTO zz.ac_runs SELECT 'late_90', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset late_91_
INSERT INTO zz.ac_runs SELECT 'late_91', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 100, 'category', 'nhis')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset partial_
INSERT INTO zz.ac_runs SELECT 'partial', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset paidfull_
INSERT INTO zz.ac_runs SELECT 'paidfull', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset cancelled_
INSERT INTO zz.ac_runs SELECT 'cancelled', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ac), (SELECT other_p FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset other_p1_
INSERT INTO zz.ac_runs SELECT 'other_p1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

UPDATE public.orders SET credit_due_date = current_date + (1) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow');
UPDATE public.orders SET credit_due_date = current_date + (0) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='due_today');
UPDATE public.orders SET credit_due_date = current_date + (-1) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_1');
UPDATE public.orders SET credit_due_date = current_date + (-30) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_30');
UPDATE public.orders SET credit_due_date = current_date + (-31) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_31');
UPDATE public.orders SET credit_due_date = current_date + (-60) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_60');
UPDATE public.orders SET credit_due_date = current_date + (-61) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_61');
UPDATE public.orders SET credit_due_date = current_date + (-90) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_90');
UPDATE public.orders SET credit_due_date = current_date + (-91) WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='late_91');
UPDATE public.orders SET credit_due_date = current_date - 45 WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='partial');
UPDATE public.orders SET credit_due_date = current_date - 10 WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='paidfull');
UPDATE public.orders SET credit_due_date = current_date + 5 WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='other_p1');
-- Pay the 200 invoice in full and part-pay the 10,000 invoice by 8,000 (as the wholesaler's finance user).
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 8200, ''bank_transfer'', ''BT-1'', NULL, ''Settlement'', NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(
      jsonb_build_object('order_id', (SELECT order_id FROM zz.ac_runs WHERE label='partial'), 'amount', 8000),
      jsonb_build_object('order_id', (SELECT order_id FROM zz.ac_runs WHERE label='paidfull'), 'amount', 200))::text));
  PERFORM zz.check('finance records an 8,200 payment: 8,000 part-pays the big invoice, 200 clears the small one', r NOT LIKE 'ERR%', r);
END $$;
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='cancelled');

-- 1. Bucket of each boundary invoice, as the register reports it.
DO $$
BEGIN
  PERFORM zz.check('due_tomorrow: bucket current', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow')) = 'current');
  PERFORM zz.check('due_today: bucket current', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='due_today')) = 'current');
  PERFORM zz.check('late_1: bucket d1_30', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_1')) = 'd1_30');
  PERFORM zz.check('late_30: bucket d1_30', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_30')) = 'd1_30');
  PERFORM zz.check('late_31: bucket d31_60', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_31')) = 'd31_60');
  PERFORM zz.check('late_60: bucket d31_60', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_60')) = 'd31_60');
  PERFORM zz.check('late_61: bucket d61_90', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_61')) = 'd61_90');
  PERFORM zz.check('late_90: bucket d61_90', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_90')) = 'd61_90');
  PERFORM zz.check('late_91: bucket d90_plus', (SELECT aging_bucket FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='late_91')) = 'd90_plus');
  PERFORM zz.check('the part-paid invoice is aged on what is STILL OWED: 2,000 outstanding, 45 days late, bucket d31_60',
    (SELECT outstanding_ghs = 2000 AND invoice_ghs = 10000 AND paid_ghs = 8000 AND days_overdue = 45 AND aging_bucket = 'd31_60'
       FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='partial')));
  PERFORM zz.check('a fully paid invoice has no bucket and no days overdue',
    (SELECT aging_bucket IS NULL AND days_overdue IS NULL AND status = 'paid' FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='paidfull')));
  PERFORM zz.check('a cancelled invoice shows as cancelled, not as paid, with no bucket',
    (SELECT aging_bucket IS NULL AND status = 'cancelled' FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='cancelled')));
  PERFORM zz.check('days overdue is 0 for an invoice not yet due',
    (SELECT days_overdue = 0 FROM public.credit_invoice_register((SELECT alpha FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow')));
END $$;

-- 2. Summary: all five buckets, outstanding only.
DO $$
DECLARE s TEXT;
BEGIN
  SELECT string_agg(bucket || '=' || invoices || '/' || outstanding_ghs, ' ' ORDER BY CASE bucket WHEN 'current' THEN 1 WHEN 'd1_30' THEN 2 WHEN 'd31_60' THEN 3 WHEN 'd61_90' THEN 4 ELSE 5 END)
    INTO s FROM public.credit_aging_summary((SELECT alpha FROM zz.ac));
  PERFORM zz.check('summary: current 3 invoices / 500, 1-30: 2 / 200, 31-60: 3 / 2,200, 61-90: 2 / 200, 90+: 1 / 100',
    s = 'current=3/500.00 d1_30=2/200.00 d31_60=3/2200.00 d61_90=2/200.00 d90_plus=1/100.00', s);
  SELECT string_agg(bucket || '=' || invoices || '/' || outstanding_ghs, ' ' ORDER BY bucket) INTO s FROM public.credit_aging_summary((SELECT alpha FROM zz.ac), (SELECT other_p FROM zz.ac));
  PERFORM zz.check('summary filtered to one pharmacy: only its 300 (current); the other buckets are present and zero',
    s = 'current=1/300.00 d1_30=0/0.00 d31_60=0/0.00 d61_90=0/0.00 d90_plus=0/0.00', s);
  PERFORM zz.check('the summary excludes paid and cancelled invoices (total owed is 3,200)',
    (SELECT sum(outstanding_ghs) FROM public.credit_aging_summary((SELECT alpha FROM zz.ac))) = 3200);
END $$;

-- 3. Filters, search and paging.
DO $$
DECLARE a UUID := (SELECT alpha FROM zz.ac);
BEGIN
  PERFORM zz.check('status outstanding: the 11 invoices still owed (paid and cancelled excluded)', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, 'outstanding')) = 11);
  PERFORM zz.check('no filter: all 13 invoices', (SELECT count(*) FROM public.credit_invoice_register(a)) = 13);
  PERFORM zz.check('bucket d31_60 returns its 3 invoices', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, 'd31_60')) = 3);
  PERFORM zz.check('bucket d90_plus returns 1', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, 'd90_plus')) = 1);
  PERFORM zz.check('counterparty filter: Other Pharmacy has 1 invoice', (SELECT count(*) FROM public.credit_invoice_register(a, (SELECT other_p FROM zz.ac))) = 1);
  PERFORM zz.check('status paid: 1', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, 'paid')) = 1);
  PERFORM zz.check('status cancelled: 1', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, 'cancelled')) = 1);
  PERFORM zz.check('due-date range 60 to 31 days ago: the three invoices due -31, -45, -60',
    (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, NULL, NULL, current_date - 60, current_date - 31)) = 3);
  PERFORM zz.check('invoice-date range today..today covers all 13', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, current_date, current_date)) = 13);
  PERFORM zz.check('invoice-date range from tomorrow returns none', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, current_date + 1, NULL)) = 0);
  PERFORM zz.check('outstanding at least 1,000 returns just the part-paid invoice', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1000)) = 1);
  PERFORM zz.check('outstanding between 1 and 150 returns the nine 100-GHS invoices', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 1, 150)) = 9);
  PERFORM zz.check('search by pharmacy name finds Other Pharmacy''s invoice', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'other pharm')) = 1);
  PERFORM zz.check('search by order number finds exactly that invoice',
    (SELECT count(*) FROM public.credit_invoice_register(a, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, (SELECT order_number FROM public.orders WHERE id = (SELECT order_id FROM zz.ac_runs WHERE label='partial')))) = 1);
  PERFORM zz.check('paging: page size 5 returns 5 rows and reports 11 in total',
    (SELECT count(*) = 5 AND max(total_count) = 11 FROM public.credit_invoice_register(a, NULL, 'outstanding', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 5, 0)));
  PERFORM zz.check('paging: the last page (offset 10) has 1 row', (SELECT count(*) FROM public.credit_invoice_register(a, NULL, 'outstanding', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 5, 10)) = 1);
  PERFORM zz.check('rows are ordered by due date, oldest first (the 91-days-late invoice leads)',
    (SELECT days_overdue FROM public.credit_invoice_register(a, NULL, 'outstanding') ORDER BY due_date ASC NULLS LAST LIMIT 1) = 91);
END $$;

-- 4. Validation.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L, NULL, ''bogus'')', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('an unknown status is refused', r = 'ERR: Invalid status filter.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L, NULL, NULL, ''d200'')', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('an unknown aging bucket is refused', r = 'ERR: Invalid aging bucket.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 5000, 0)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('a page size above 2000 is refused', r = 'ERR: The page size must be between 1 and 2000.', r);
END $$;

-- 5. Access: wholesaler side.
DO $$
DECLARE r TEXT; q TEXT := 'SELECT count(*)::text FROM public.credit_invoice_register(%L)'; a UUID := (SELECT alpha FROM zz.ac);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, a));    PERFORM zz.check('wholesaler owner can open the register', r = '13', r);
  r := zz.val_as((SELECT u_wm FROM zz.ac), format(q, a));    PERFORM zz.check('wholesaler manager can', r = '13', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(q, a));  PERFORM zz.check('wholesaler finance can', r = '13', r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(q, a));  PERFORM zz.check('wholesaler accountant can', r = '13', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(q, a));    PERFORM zz.check('wholesaler cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wass FROM zz.ac), format(q, a));  PERFORM zz.check('wholesaler assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wwh FROM zz.ac), format(q, a));   PERFORM zz.check('wholesaler warehouse user cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(q, a));    PERFORM zz.check('another wholesaler''s owner cannot read Alpha''s accounts', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, a));    PERFORM zz.check('a pharmacy owner cannot pass a wholesaler id to read its receivables', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format('SELECT count(*)::text FROM public.credit_aging_summary(%L)', a));
  PERFORM zz.check('the aging summary has the same gate', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format('SELECT count(*)::text FROM public.list_credit_payments(%L)', a));
  PERFORM zz.check('the payment register has the same gate', r = 'ERR: You do not have access to these accounts.', r);
END $$;

-- 6. Access: pharmacy side, and isolation.
DO $$
DECLARE r TEXT; q TEXT := 'SELECT count(*)::text FROM public.credit_invoice_register(%L)'; g UUID := (SELECT good FROM zz.ac);
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ac), format(q, g));    PERFORM zz.check('pharmacy owner sees its payables (12 invoices; the other pharmacy''s is not included)', r = '12', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ac), format(q, g));  PERFORM zz.check('pharmacy accountant can', r = '12', r);
  r := zz.val_as((SELECT u_pcash FROM zz.ac), format(q, g)); PERFORM zz.check('pharmacy cashier cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_pass FROM zz.ac), format(q, g));  PERFORM zz.check('pharmacy assistant cannot', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, g));    PERFORM zz.check('another pharmacy cannot read Good Pharmacy''s payables', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(q, g));    PERFORM zz.check('a wholesaler cannot read a pharmacy''s payables by passing its id', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format(q, (SELECT other_p FROM zz.ac)));
  PERFORM zz.check('another pharmacy sees only its own single invoice', r = '1', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L, %L)', (SELECT other_p FROM zz.ac), (SELECT other_w FROM zz.ac)));
  PERFORM zz.check('a counterparty filter can only narrow, never widen: filtering by another supplier finds nothing', r = '0', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format('SELECT counterparty_name FROM public.credit_invoice_register(%L) LIMIT 1', g));
  PERFORM zz.check('on the pharmacy side the counterparty is the supplier', r = 'Alpha Wholesale', r);
END $$;

-- 7. Inactive staff and unapproved businesses are refused.
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '30000000-0000-0000-0000-0000000000a2';
-- Only a platform admin may change verification status: do this step as the fixture admin.
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='admin')::text, false);
UPDATE public.businesses SET verification_status = 'pending' WHERE id = (SELECT other_p FROM zz.ac);
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L)', (SELECT alpha FROM zz.ac)));
  PERFORM zz.check('an inactive (suspended) accountant is refused', r = 'ERR: You do not have access to these accounts.', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format('SELECT count(*)::text FROM public.credit_invoice_register(%L)', (SELECT other_p FROM zz.ac)));
  PERFORM zz.check('an unapproved business is refused even for its owner', r = 'ERR: You do not have access to these accounts.', r);
END $$;
UPDATE public.business_staff SET status = 'active' WHERE user_id = '30000000-0000-0000-0000-0000000000a2';
UPDATE public.businesses SET verification_status = 'approved' WHERE id = (SELECT other_p FROM zz.ac);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ac)::text, false);

-- 8. Payment register. Two more payments: 500 cash, 100 allocated to the 'due tomorrow' invoice
--    (400 left unallocated), then that 100 allocation is reversed.
DO $$
DECLARE r TEXT; e UUID;
BEGIN
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(
    'SELECT public.record_credit_payment(%L, %L, 500, ''cash'', ''CASH-1'', NULL, ''Counter payment'', NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac),
    jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow'), 'amount', 100))::text));
  PERFORM zz.check('accountant records a 500 cash payment with only 100 allocated', r NOT LIKE 'ERR%', r);
  SELECT id INTO e FROM public.credit_ledger_entries WHERE entry_type = 'payment' AND order_id = (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow');
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT public.reverse_credit_ledger_entry(%L, ''Cash was returned'')::text', e));
  PERFORM zz.check('the owner reverses that 100 allocation', r NOT LIKE 'ERR%', r);
END $$;
DO $$
DECLARE a UUID := (SELECT alpha FROM zz.ac);
BEGIN
  PERFORM zz.check('the register lists both payments, newest first', (SELECT count(*) = 2 AND (array_agg(reference ORDER BY paid_at DESC, payment_id))[1] IN ('CASH-1', 'BT-1') FROM public.list_credit_payments(a)));
  PERFORM zz.check('bank transfer BT-1: 8,200 paid, fully allocated, nothing unallocated or reversed',
    (SELECT amount_ghs = 8200 AND allocated_ghs = 8200 AND unallocated_ghs = 0 AND reversed_ghs = 0 AND allocation_count = 2 AND counterparty_name = 'Good Pharmacy'
       FROM public.list_credit_payments(a) WHERE reference = 'BT-1'));
  PERFORM zz.check('cash CASH-1: 500 paid, 100 allocated, 400 unallocated, 100 reversed',
    (SELECT amount_ghs = 500 AND allocated_ghs = 100 AND unallocated_ghs = 400 AND reversed_ghs = 100 AND allocation_count = 1 FROM public.list_credit_payments(a) WHERE reference = 'CASH-1'));
  PERFORM zz.check('method filter: cash returns 1', (SELECT count(*) FROM public.list_credit_payments(a, NULL, NULL, NULL, 'cash')) = 1);
  PERFORM zz.check('date filter: tomorrow onward returns none', (SELECT count(*) FROM public.list_credit_payments(a, NULL, current_date + 1, NULL)) = 0);
  PERFORM zz.check('counterparty filter: payments from Other Pharmacy: none', (SELECT count(*) FROM public.list_credit_payments(a, (SELECT other_p FROM zz.ac))) = 0);
  PERFORM zz.check('the reversal restored the invoice''s balance (due-tomorrow is owed again, 100)',
    (SELECT outstanding_ghs = 100 FROM public.credit_invoice_register(a) r WHERE r.order_id = (SELECT order_id FROM zz.ac_runs WHERE label='due_tomorrow')));
  PERFORM zz.check('the pharmacy sees the same two payments, with the supplier as counterparty',
    zz.val_as((SELECT u_po FROM zz.ac), format('SELECT count(*)::text || ''/'' || min(counterparty_name) FROM public.list_credit_payments(%L)', (SELECT good FROM zz.ac))) = '2/Alpha Wholesale');
  PERFORM zz.check('an invalid payment method filter is refused',
    zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT count(*)::text FROM public.list_credit_payments(%L, NULL, NULL, NULL, ''barter'')', a)) = 'ERR: Invalid payment method.');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
