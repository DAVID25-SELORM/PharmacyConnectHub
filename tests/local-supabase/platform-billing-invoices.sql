-- Platform billing, Phase 4: invoices and payment records. Issuing (once per real period, never for shadow, never while billing is off), the numbers and lines, closing empty periods, credit carried
-- forward, an invoiced period being final (late entries land in the current period), manual payments (partial, full, over, reversed, repeated), overdue, settings, who can read and who can write,
-- the administrator's money numbers, and the reconciliation finding each deliberately introduced inconsistency. Run after setup.sql + migrations (through 20261204110000_platform_billing_invoices.sql).
GRANT USAGE ON SCHEMA zz TO authenticated, anon;
GRANT SELECT ON zz.b, zz.u TO authenticated, anon;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;
CREATE FUNCTION zz.anon(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
CREATE FUNCTION zz.try(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  BEGIN
    IF p_sql ~* '^[[:space:]]*select' THEN EXECUTE p_sql INTO r; ELSE EXECUTE p_sql; END IF;
  EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  RETURN r;
END $$;

CREATE TABLE zz.bx AS SELECT (SELECT id FROM zz.b WHERE name='Good Pharmacy') good, (SELECT id FROM zz.u WHERE k='admin') u_admin;
CREATE SEQUENCE zz.ordn START 1;
CREATE FUNCTION zz.adm(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.val_as((SELECT u_admin FROM zz.bx), p_sql) $$;
-- A wholesaler with its own owner (so licence and owner keys differ), approved.
CREATE FUNCTION zz.mkws(p_name TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_u UUID := gen_random_uuid(); v_b UUID;
BEGIN
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', replace(lower(p_name), ' ', '') || '@zz.test', '{}', '{"provider":"email"}', now(), now());
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', p_name, 'LIC-' || p_name, 'approved') RETURNING id INTO v_b;
  RETURN v_b;
END $$;
CREATE FUNCTION zz.owner(p_b UUID) RETURNS UUID LANGUAGE sql AS $$ SELECT owner_id FROM public.businesses WHERE id = p_b $$;
CREATE FUNCTION zz.mkplan(p_code TEXT, p_params JSONB) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm(format('SELECT public.admin_billing_create_plan(%L, ''wholesaler'', %L, NULL, ''standard'', ''Plan for tests'')::text', p_code, 'Plan ' || p_code))::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Terms for tests'')::text', pid, p_params::text));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, FALSE, ''Switch on for tests'')::text', pid));
  RETURN p_code;
END $$;
CREATE FUNCTION zz.sub(p_b UUID, p_plan TEXT, p_starts TIMESTAMPTZ DEFAULT '2026-01-01 00:00+00', p_mode TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, %L, %L, %L, ''Start for tests'')::text', p_b, p_plan, p_starts, p_mode)) $$;
-- An order (pending), worth p_goods plus a delivery fee, to be delivered at p_at.
CREATE FUNCTION zz.mkorder(p_ws UUID, p_goods NUMERIC, p_fee NUMERIC, p_at TIMESTAMPTZ, p_eff NUMERIC DEFAULT NULL, p_ph UUID DEFAULT NULL) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.orders(order_number, pharmacy_id, wholesaler_id, total_ghs, delivery_fee_ghs, delivered_at) VALUES ('ORD-B' || nextval('zz.ordn'), COALESCE(p_ph, (SELECT good FROM zz.bx)), p_ws, p_goods + p_fee, p_fee, p_at) RETURNING id INTO v_id;
  IF p_eff IS NOT NULL THEN PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = p_eff WHERE id = v_id; END IF;
  RETURN v_id;
END $$;
CREATE FUNCTION zz.advance(p_order UUID, p_to TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE s TEXT;
BEGIN
  FOREACH s IN ARRAY (CASE p_to WHEN 'accepted' THEN ARRAY['accepted'] WHEN 'packed' THEN ARRAY['accepted', 'packed'] WHEN 'dispatched' THEN ARRAY['accepted', 'packed', 'dispatched']
                                WHEN 'cancelled' THEN ARRAY['cancelled'] ELSE ARRAY['accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] END) LOOP
    -- only the steps still ahead of where the order already is
    IF array_position(ARRAY['pending', 'accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'], (SELECT status::text FROM public.orders WHERE id = p_order))
       < array_position(ARRAY['pending', 'accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'], s) OR s = 'cancelled' THEN
      EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', s, p_order);
    END IF;
  END LOOP;
END $$;
CREATE FUNCTION zz.deliver(p_order UUID) RETURNS VOID LANGUAGE sql AS $$ SELECT zz.advance(p_order, 'delivered') $$;
CREATE FUNCTION zz.go(p_ws UUID, p_goods NUMERIC, p_fee NUMERIC, p_at TIMESTAMPTZ) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v UUID := zz.mkorder(p_ws, p_goods, p_fee, p_at);
BEGIN PERFORM zz.deliver(v); RETURN v; END $$;
-- How an order was billed: outcome / free source and number / charged.
CREATE FUNCTION zz.a(p_order UUID, p_shadow BOOLEAN DEFAULT FALSE) RETURNS TEXT LANGUAGE sql AS $$
  SELECT outcome || '/' || COALESCE(free_source || free_seq, '-') || '/' || charged_amount FROM public.order_billing_assessments WHERE order_id = p_order AND kind = 'primary' AND shadow = p_shadow $$;
CREATE FUNCTION zz.per(p_b UUID, p_start TIMESTAMPTZ, p_shadow BOOLEAN DEFAULT FALSE) RETURNS public.billing_periods LANGUAGE sql AS $$
  SELECT * FROM public.billing_periods WHERE business_id = p_b AND period_start = p_start AND shadow = p_shadow $$;
CREATE FUNCTION zz.nass(p_b UUID, p_shadow BOOLEAN DEFAULT FALSE) RETURNS INT LANGUAGE sql AS $$ SELECT count(*)::int FROM public.order_billing_assessments WHERE business_id = p_b AND shadow = p_shadow $$;

-- Setup: a small marketplace with three closed months and the current one --------------------------------------------------------------------------------------------------------------------------
UPDATE public.billing_settings SET mode = 'active';
CREATE TABLE zz.t AS SELECT date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '3 months' AS m3, date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '2 months' AS m2,
                           date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' - interval '1 month' AS m1, date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m0,
                           GREATEST(now(), date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' + interval '2 days') AS run_at;
CREATE FUNCTION zz.run_at() RETURNS TIMESTAMPTZ LANGUAGE sql AS $$ SELECT GREATEST(clock_timestamp(), (SELECT m0 FROM zz.t) + interval '2 days') $$;
SELECT zz.mkplan('inv_ws', '{"subscription_amount":100,"free_trial_days":0,"onboarding_free_orders":0,"monthly_free_orders":1,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":30}'::jsonb);
SELECT zz.mkplan('inv_zero', '{"subscription_amount":0,"transaction_fee_percentage":1}'::jsonb);
SELECT zz.mkplan('inv_cr', '{"subscription_amount":20,"transaction_fee_percentage":0}'::jsonb);
DO $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm('SELECT public.admin_billing_create_plan(''inv_pharm'', ''pharmacy'', ''Pharmacy plan'', NULL, ''standard'', ''Plan for tests'')::text')::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":50}''::jsonb, ''Terms for tests'')::text', pid));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Switch on for tests'')::text', pid));
END $$;
CREATE TABLE zz.w AS SELECT zz.mkws('Inv W1') w1, zz.mkws('Inv W2') w2, zz.mkws('Inv W3') w3, zz.mkws('Inv W4') w4, zz.mkws('Inv WS') ws;
SELECT zz.sub((SELECT w1 FROM zz.w), 'inv_ws', (SELECT m3 FROM zz.t));
SELECT zz.sub((SELECT w2 FROM zz.w), 'inv_zero', (SELECT m3 FROM zz.t));
SELECT zz.sub((SELECT w3 FROM zz.w), 'inv_cr', (SELECT m3 FROM zz.t));
SELECT zz.sub((SELECT w4 FROM zz.w), 'inv_cr', (SELECT m3 FROM zz.t));
SELECT zz.sub((SELECT ws FROM zz.w), 'inv_zero', (SELECT m3 FROM zz.t), 'shadow');
SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''inv_pharm'', %L, NULL, ''Start for tests'')::text', (SELECT good FROM zz.bx), (SELECT m3 FROM zz.t)));
CREATE TABLE zz.users AS SELECT zz.owner((SELECT w1 FROM zz.w)) w1_owner, zz.owner((SELECT w2 FROM zz.w)) w2_owner, (SELECT id FROM zz.u WHERE k = 'ph_owner') po, (SELECT id FROM zz.u WHERE k = 'ph_other') px;
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f1', 'invmgr@zz.test', '{"full_name":"Inv Manager","phone":"+233241000091"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f2', 'invcash@zz.test', '{"full_name":"Inv Cashier","phone":"+233241000092"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f3', 'invfin@zz.test', '{"full_name":"Inv Finance","phone":"+233241000093"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f4', 'invacc@zz.test', '{"full_name":"Inv Accountant","phone":"+233241000094"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT w1 FROM zz.w), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES ('30000000-0000-0000-0000-0000000000f1'::uuid, 'manager'), ('30000000-0000-0000-0000-0000000000f2'::uuid, 'cashier'), ('30000000-0000-0000-0000-0000000000f3'::uuid, 'finance'), ('30000000-0000-0000-0000-0000000000f4'::uuid, 'accountant')) v(uid, r);

-- Orders in the three closed months -------------------------------------------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE zz.o (k TEXT PRIMARY KEY, id UUID);
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); w2 UUID := (SELECT w2 FROM zz.w); i INT; v UUID; m3 TIMESTAMPTZ := (SELECT m3 FROM zz.t); m1 TIMESTAMPTZ := (SELECT m1 FROM zz.t);
BEGIN
  -- July: Inv W1 delivers three orders of GHS 1,000: the first is the month's free one, the others pay GHS 10.00 each.
  FOR i IN 1..3 LOOP v := zz.go(w1, 1000, 25, m3 + interval '5 days' + make_interval(mins => i)); INSERT INTO zz.o VALUES ('w1_jul' || i, v); END LOOP;
  -- September: five orders: one free, three at GHS 10.00 reach the GHS 30.00 cap, the fifth pays nothing.
  FOR i IN 1..5 LOOP v := zz.go(w1, 1000, 25, m1 + interval '5 days' + make_interval(mins => i)); INSERT INTO zz.o VALUES ('w1_sep' || i, v); END LOOP;
  -- Inv W2 (no subscription fee): one order in July pays GHS 10.00.
  v := zz.go(w2, 1000, 0, m3 + interval '6 days'); INSERT INTO zz.o VALUES ('w2_jul1', v);
  PERFORM public.billing_open_periods(now());
END $$;
-- Manual entries that Phase 5 will create through the admin controls, put into the open periods directly so that the invoice lines can be tested now.
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); w3 UUID := (SELECT w3 FROM zz.w); w4 UUID := (SELECT w4 FROM zz.w); p UUID;
BEGIN
  SELECT id INTO p FROM public.billing_periods WHERE business_id = w1 AND period_start = (SELECT m2 FROM zz.t) AND NOT shadow;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, credit_amount, reason, source, idempotency_key) VALUES (w1, p, 'manual_credit', 15, 'Goodwill credit', 'admin', 'inv-test-credit-w1');
  UPDATE public.billing_periods SET credits_amount = 15 WHERE id = p;
  SELECT id INTO p FROM public.billing_periods WHERE business_id = w1 AND period_start = (SELECT m1 FROM zz.t) AND NOT shadow;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, charged_amount, reason, source, idempotency_key) VALUES (w1, p, 'manual_debit', 10, 'Onboarding support', 'admin', 'inv-test-debit-w1');
  UPDATE public.billing_periods SET debits_amount = 10 WHERE id = p;
  -- Inv W3 and Inv W4 are given credits larger than their July subscription: the surplus carries forward.
  SELECT id INTO p FROM public.billing_periods WHERE business_id = w3 AND period_start = (SELECT m3 FROM zz.t) AND NOT shadow;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, credit_amount, reason, source, idempotency_key) VALUES (w3, p, 'manual_credit', 30, 'Service credit', 'admin', 'inv-test-credit-w3');
  UPDATE public.billing_periods SET credits_amount = 30 WHERE id = p;
  SELECT id INTO p FROM public.billing_periods WHERE business_id = w4 AND period_start = (SELECT m3 FROM zz.t) AND NOT shadow;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, credit_amount, reason, source, idempotency_key) VALUES (w4, p, 'manual_credit', 40, 'Service credit', 'admin', 'inv-test-credit-w4');
  UPDATE public.billing_periods SET credits_amount = 40 WHERE id = p;
END $$;

-- 1. Before the run: nothing is invoiced; the open periods hold the figures ---------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); p public.billing_periods;
BEGIN
  PERFORM zz.check('1: before the run there are no invoices and no payments', (SELECT count(*) FROM public.billing_invoices) = 0 AND (SELECT count(*) FROM public.billing_payments) = 0);
  p := zz.per(w1, (SELECT m3 FROM zz.t));
  PERFORM zz.check('1: Inv W1''s July period holds 100.00 + 20.00 of fees (one free, two at GHS 10.00) and is still open', p.status = 'open' AND p.subscription_amount = 100 AND p.transaction_fees_amount = 20 AND p.amount_due = 120, p::text);
  p := zz.per(w1, (SELECT m1 FROM zz.t));
  PERFORM zz.check('1: September stopped at the GHS 30.00 cap with a GHS 10.00 manual charge: due 140.00', p.transaction_fees_amount = 30 AND p.debits_amount = 10 AND p.amount_due = 140 AND p.chargeable_orders = 4, p::text);
  PERFORM zz.check('1: the current month''s period is open and is never invoiced', (SELECT count(*) FROM public.billing_periods WHERE business_id = w1 AND period_start = (SELECT m0 FROM zz.t) AND status = 'open') = 1);
  PERFORM zz.check('1: reconciliation is clean before invoicing (the engine and the manual entries agree)', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 2. Issuing: which modes, and how often ---------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r JSONB;
BEGIN
  UPDATE public.billing_settings SET mode = 'shadow';
  r := public.billing_issue_invoices(now());
  PERFORM zz.check('2: in SHADOW mode nothing is invoiced', r ->> 'skipped' = 'not_active' AND (SELECT count(*) FROM public.billing_invoices) = 0, r::text);
  UPDATE public.billing_settings SET mode = 'disabled';
  r := public.billing_issue_invoices(now());
  PERFORM zz.check('2: when DISABLED nothing is invoiced', r ->> 'skipped' = 'not_active' AND (SELECT count(*) FROM public.billing_invoices) = 0, r::text);
  UPDATE public.billing_settings SET mode = 'active';
  r := public.billing_issue_invoices((SELECT m2 FROM zz.t) + interval '12 hours');
  PERFORM zz.check('2: a run "in the past" finds no period that has ended long enough (the delay holds): July and later are not yet due for invoicing', (r ->> 'invoices_issued')::int = 0, r::text);
  r := public.billing_issue_invoices(zz.run_at());
  PERFORM zz.check('2: the run issues 11 invoices (Inv W1 3, Inv W2 1, Inv W3 2, Inv W4 2, the pharmacy 3) and closes the empty periods without an invoice', (r ->> 'invoices_issued')::int = 11, r::text);
  PERFORM zz.check('2: running it again changes nothing (one invoice per period)', (public.billing_issue_invoices(zz.run_at()) ->> 'invoices_issued')::int = 0 AND (SELECT count(*) FROM public.billing_invoices) = 11);
  PERFORM zz.check('2: the scheduled run does the same work and also reports invoices (and still nothing new)', public.billing_run_scheduled(zz.run_at()) -> 'invoices' ->> 'invoices_issued' = '0');
END $$;

-- 3. What an invoice says ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); i public.billing_invoices; l TEXT;
BEGIN
  PERFORM zz.check('3: invoice numbers are DXB-<year>-<6 digits>, one after another from 000001 with no gap',
    (SELECT array_agg(substring(invoice_number FROM '[0-9]+$')::int ORDER BY invoice_number) FROM public.billing_invoices) = ARRAY[1,2,3,4,5,6,7,8,9,10,11]
    AND (SELECT bool_and(invoice_number ~ ('^DXB-' || to_char(now(), 'YYYY') || '-[0-9]{6}$')) FROM public.billing_invoices)
    AND (SELECT last_invoice_number FROM public.billing_settings) = 11);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w1, (SELECT m3 FROM zz.t))).id;
  PERFORM zz.check('3: Inv W1''s July invoice: subscription 100.00 + fees 20.00 = 120.00, issued as "issued", due 14 days after it was issued', i.total_amount = 120 AND i.subscription_amount = 100 AND i.transaction_fees_amount = 20
    AND i.status = 'issued' AND i.amount_paid = 0 AND i.outstanding_amount = 120 AND i.due_at = i.issued_at + interval '14 days' AND i.credit_brought_forward = 0, i::text);
  SELECT string_agg(kind || ':' || amount, ' | ' ORDER BY line_no) INTO l FROM public.billing_invoice_lines WHERE invoice_id = i.id;
  PERFORM zz.check('3: the lines are one subscription line and one platform-fee line, adding up to the total', l = 'subscription:100.00 | transaction_fees:20.00', l);
  PERFORM zz.check('3: the fee line says how many orders were chargeable (2 of 3 eligible)', (SELECT description FROM public.billing_invoice_lines WHERE invoice_id = i.id AND kind = 'transaction_fees') = 'Platform transaction fees (2 chargeable orders of 3 eligible)',
    (SELECT description FROM public.billing_invoice_lines WHERE invoice_id = i.id AND kind = 'transaction_fees'));
  PERFORM zz.check('3: the period follows its invoice: status invoiced, nothing paid yet', (zz.per(w1, (SELECT m3 FROM zz.t))).status = 'invoiced' AND (zz.per(w1, (SELECT m3 FROM zz.t))).amount_paid = 0);
  PERFORM zz.check('3: the invoice keeps a summary of the period (free orders, chargeable orders, sales, plan)', i.summary ->> 'plan_code' = 'inv_ws' AND (i.summary ->> 'eligible_orders')::int = 3 AND (i.summary ->> 'free_monthly_orders')::int = 1
    AND (i.summary ->> 'chargeable_orders')::int = 2 AND (i.summary ->> 'billable_gmv')::numeric = 3000 AND i.summary ->> 'period_label' IS NOT NULL, i.summary::text);
  PERFORM zz.check('3: it keeps who it is from (the platform) and who it is to (name, licence, type) as they were then', i.issuer ->> 'name' = 'DrugXOne' AND i.customer ->> 'name' = 'Inv W1' AND i.customer ->> 'type' = 'wholesaler'
    AND i.customer ->> 'license_number' = 'LIC-Inv W1', i.customer::text);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w1, (SELECT m2 FROM zz.t))).id;
  SELECT string_agg(kind || ':' || amount || ':' || description, ' | ' ORDER BY line_no) INTO l FROM public.billing_invoice_lines WHERE invoice_id = i.id;
  PERFORM zz.check('3: August (no orders): the subscription less the GHS 15.00 goodwill credit = 85.00, the credit shown with its own reason', i.total_amount = 85 AND l LIKE 'subscription:100.00:%| credit:-15.00:Goodwill credit', l);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w1, (SELECT m1 FROM zz.t))).id;
  SELECT string_agg(kind || ':' || amount, ' | ' ORDER BY line_no) INTO l FROM public.billing_invoice_lines WHERE invoice_id = i.id;
  PERFORM zz.check('3: September: subscription 100.00 + fees 30.00 (capped) + the manual charge 10.00 = 140.00', i.total_amount = 140 AND l = 'subscription:100.00 | transaction_fees:30.00 | other_charge:10.00', l);
  PERFORM zz.check('3: every invoice''s lines add up to its total', NOT EXISTS (SELECT 1 FROM public.billing_invoices v WHERE v.total_amount <> (SELECT sum(amount) FROM public.billing_invoice_lines WHERE invoice_id = v.id)));
  PERFORM zz.check('3: the cap holds in the invoice too: no invoice charges more than the plan''s GHS 30.00 fee cap', (SELECT max(transaction_fees_amount) FROM public.billing_invoices WHERE business_id = w1) <= 30);
END $$;

-- 4. Periods with nothing to pay are closed, not invoiced; surplus credit carries forward -------------------------------------------------------------------------------------------------------
DO $$
DECLARE w2 UUID := (SELECT w2 FROM zz.w); w3 UUID := (SELECT w3 FROM zz.w); w4 UUID := (SELECT w4 FROM zz.w); i public.billing_invoices; l TEXT;
BEGIN
  PERFORM zz.check('4: Inv W2 (no subscription fee) is invoiced for July only: August and September had nothing to pay and are closed without an invoice',
    (SELECT count(*) FROM public.billing_invoices WHERE business_id = w2) = 1 AND (zz.per(w2, (SELECT m2 FROM zz.t))).status = 'closed' AND (zz.per(w2, (SELECT m1 FROM zz.t))).status = 'closed');
  PERFORM zz.check('4: Inv W3''s July credit (30.00) was larger than its subscription (20.00): the period closes with no invoice, leaving 10.00 of credit', (zz.per(w3, (SELECT m3 FROM zz.t))).status = 'closed'
    AND (zz.per(w3, (SELECT m3 FROM zz.t))).amount_due = -10);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w3, (SELECT m2 FROM zz.t))).id;
  SELECT string_agg(kind || ':' || amount, ' | ' ORDER BY line_no) INTO l FROM public.billing_invoice_lines WHERE invoice_id = i.id;
  PERFORM zz.check('4: August: 20.00 less the 10.00 brought forward = 10.00 to pay, with a line saying so', i.total_amount = 10 AND i.credit_brought_forward = 10 AND l = 'subscription:20.00 | credit_brought_forward:-10.00', l);
  PERFORM zz.check('4: the period shows the credit as applied (paid amount counts the credit used), so its balance is the invoice''s', (zz.per(w3, (SELECT m2 FROM zz.t))).amount_paid = 10 AND (zz.per(w3, (SELECT m2 FROM zz.t))).outstanding_amount = 10);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w3, (SELECT m1 FROM zz.t))).id;
  PERFORM zz.check('4: September: the credit is used up, so the full 20.00', i.total_amount = 20 AND i.credit_brought_forward = 0, i::text);
  PERFORM zz.check('4: Inv W3 has no credit left', public._billing_available_credit(w3) = 0);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w4, (SELECT m2 FROM zz.t))).id;
  PERFORM zz.check('4: Inv W4 (credit 40.00 on a 20.00 subscription): August is covered completely: an invoice of 0.00, already paid, and the period paid', i.total_amount = 0 AND i.credit_brought_forward = 20 AND i.status = 'paid'
    AND i.paid_at IS NOT NULL AND (zz.per(w4, (SELECT m2 FROM zz.t))).status = 'paid', i::text);
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = (zz.per(w4, (SELECT m1 FROM zz.t))).id;
  PERFORM zz.check('4: September is a plain 20.00 once the credit is spent', i.total_amount = 20 AND i.credit_brought_forward = 0 AND public._billing_available_credit(w4) = 0, i::text);
  PERFORM zz.check('4: the pharmacy is invoiced its subscription for July, August and September (no fee lines)', (SELECT count(*) FROM public.billing_invoices WHERE business_id = (SELECT good FROM zz.bx) AND total_amount = 50) = 3
    AND NOT EXISTS (SELECT 1 FROM public.billing_invoice_lines l2 JOIN public.billing_invoices v ON v.id = l2.invoice_id WHERE v.business_id = (SELECT good FROM zz.bx) AND l2.kind <> 'subscription'));
  PERFORM zz.check('4: the SHADOW world is never invoiced (Inv WS has shadow periods and no invoice)', (SELECT count(*) FROM public.billing_periods WHERE business_id = (SELECT ws FROM zz.w) AND shadow) >= 3
    AND NOT EXISTS (SELECT 1 FROM public.billing_invoices WHERE business_id = (SELECT ws FROM zz.w)) AND NOT EXISTS (SELECT 1 FROM public.billing_periods WHERE shadow AND status <> 'open'));
END $$;

CREATE FUNCTION zz.inv(p_b UUID, p_month TIMESTAMPTZ) RETURNS UUID LANGUAGE sql AS $$
  SELECT i.id FROM public.billing_invoices i JOIN public.billing_periods p ON p.id = i.period_id WHERE i.business_id = p_b AND p.period_start = p_month $$;
CREATE FUNCTION zz.pay(p_inv UUID, p_amount TEXT, p_method TEXT DEFAULT 'bank_transfer', p_ref TEXT DEFAULT NULL, p_key TEXT DEFAULT NULL, p_reason TEXT DEFAULT 'Recorded for the test', p_at TEXT DEFAULT 'now() - interval ''1 hour''') RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.adm(format('SELECT public.admin_billing_record_payment(%L, %s, %L, %L, %s, ''Received by bank'', %L, %L)::text', p_inv, p_amount, p_method, p_ref, p_at, p_reason, p_key)) $$;
CREATE FUNCTION zz.invs(p_inv UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT status || '/' || amount_paid || '/' || outstanding_amount FROM public.billing_invoices WHERE id = p_inv $$;

-- 5. An invoiced period is final: late entries land in the current period -------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); late UUID; a public.order_billing_assessments; aug_before TEXT; jul_before TEXT; oct public.billing_periods; v_ord UUID := (SELECT id FROM zz.o WHERE k = 'w1_jul2'); jul public.billing_periods := zz.per(w1, (SELECT m3 FROM zz.t));
BEGIN
  PERFORM zz.check('5: Inv W1 has a period for every month from July (the August that no order touched was filled in)', (SELECT count(*) FROM public.billing_periods WHERE business_id = w1 AND NOT shadow AND period_start < (SELECT m0 FROM zz.t)) = 3);
  aug_before := (zz.per(w1, (SELECT m2 FROM zz.t)))::text;
  jul_before := jul::text;
  -- A delivery dated in August, assessed only now (after August was invoiced)
  late := zz.go(w1, 1000, 25, (SELECT m2 FROM zz.t) + interval '10 days');
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = late AND kind = 'primary' AND NOT shadow;
  PERFORM zz.check('5: a late August delivery is billed in the CURRENT period (October), not in the invoiced August', a.period_id = (zz.per(w1, (SELECT m0 FROM zz.t))).id AND a.delivered_at = (SELECT m2 FROM zz.t) + interval '10 days', a::text);
  PERFORM zz.check('5: it uses October''s monthly free order (October''s allowance is unused)', a.outcome = 'free_monthly' AND a.free_seq = 1, a.outcome);
  PERFORM zz.check('5: August''s period and invoice did not move at all', (zz.per(w1, (SELECT m2 FROM zz.t)))::text = aug_before AND (SELECT total_amount FROM public.billing_invoices WHERE id = zz.inv(w1, (SELECT m2 FROM zz.t))) = 85);
  -- A change in value after delivery of a July order (a delivery credit)
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 525 WHERE id = v_ord;
  PERFORM zz.check('5: a fall in a July order''s value (delivery credit) becomes a fee credit in October''s period', EXISTS (SELECT 1 FROM public.order_billing_assessments x WHERE x.order_id = v_ord AND x.kind = 'adjustment' AND x.period_id = (zz.per(w1, (SELECT m0 FROM zz.t))).id AND x.charged_amount < 0)
    AND (zz.per(w1, (SELECT m0 FROM zz.t))).credits_amount > 0, (SELECT string_agg(kind || ':' || charged_amount, ',') FROM public.order_billing_assessments WHERE order_id = v_ord));
  PERFORM zz.check('5: July''s period and invoice did not move either', (zz.per(w1, (SELECT m3 FROM zz.t)))::text = jul_before AND (SELECT total_amount FROM public.billing_invoices WHERE id = zz.inv(w1, (SELECT m3 FROM zz.t))) = 120);
  PERFORM zz.check('5: the reconciliation is still clean (nothing was added to an invoiced period)', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); jul UUID := (zz.per(w1, (SELECT m3 FROM zz.t))).id; i UUID := zz.inv(w1, (SELECT m3 FROM zz.t)); r TEXT;
BEGIN
  r := zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, charged_amount, reason, source, idempotency_key) VALUES (%L, %L, ''manual_debit'', 5, ''Late charge'', ''admin'', ''inv-late-1'')', w1, jul));
  PERFORM zz.check('5: even directly, nothing can be written into an invoiced period''s ledger', r LIKE 'ERR: This billing period is already invoiced or closed%', r);
  r := zz.try(format('UPDATE public.billing_periods SET transaction_fees_amount = 99 WHERE id = %L', jul));
  PERFORM zz.check('5: an invoiced period''s figures cannot be changed', r LIKE 'ERR: An invoiced billing period is final%', r);
  r := zz.try(format('UPDATE public.billing_periods SET status = ''open'' WHERE id = %L', jul));
  PERFORM zz.check('5: an invoiced period cannot be reopened', r LIKE 'ERR: An invoiced billing period cannot be reopened%', r);
  r := zz.try(format('UPDATE public.billing_invoices SET subscription_amount = 1 WHERE id = %L', i));
  PERFORM zz.check('5: an issued invoice''s figures cannot be edited', r LIKE 'ERR: An issued invoice cannot be edited%', r);
  r := zz.try(format('UPDATE public.billing_invoices SET invoice_number = ''DXB-2026-999999'' WHERE id = %L', i));
  PERFORM zz.check('5: nor its number', r LIKE 'ERR: An issued invoice cannot be edited%', r);
  r := zz.try(format('DELETE FROM public.billing_invoices WHERE id = %L', i));
  PERFORM zz.check('5: an invoice can never be deleted', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('UPDATE public.billing_invoice_lines SET amount = 1 WHERE invoice_id = %L', i));
  PERFORM zz.check('5: invoice lines can never be edited', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('DELETE FROM public.billing_invoice_lines WHERE invoice_id = %L', i));
  PERFORM zz.check('5: or deleted', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, kind, period_id, delivered_at, billable_gmv, outcome, percentage, charged_amount, terms_snapshot, rule_version) SELECT business_id, order_id, ''adjustment'', %L, delivered_at, 0, ''chargeable'', 0, 0, ''{}'', ''x'' FROM public.order_billing_assessments WHERE business_id = %L LIMIT 1', jul, w1));
  PERFORM zz.check('5: nor can an order assessment be written into an invoiced period', r LIKE 'ERR: This billing period is already invoiced or closed%', r);
END $$;

-- 6. Payments --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); jul UUID := zz.inv(w1, (SELECT m3 FROM zz.t)); sep UUID := zz.inv(w1, (SELECT m1 FROM zz.t)); r TEXT; j JSONB; n INT; zero UUID := zz.inv((SELECT w4 FROM zz.w), (SELECT m2 FROM zz.t));
BEGIN
  PERFORM zz.check('6: the owner of the business cannot record a payment (only an administrator can)', zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.admin_billing_record_payment(%L, 10, ''cash'', NULL, now(), NULL, ''Recorded for the test'', NULL)::text', jul)) LIKE 'ERR: Only platform administrators%');
  PERFORM zz.check('6: nor a signed-out visitor', zz.anon(format('SELECT public.admin_billing_record_payment(%L, 10, ''cash'', NULL, now(), NULL, ''Recorded for the test'', NULL)::text', jul)) LIKE 'ERR: permission denied%');
  PERFORM zz.check('6: a reason is required', zz.pay(jul, '10', 'cash', NULL, NULL, 'no') LIKE 'ERR: A reason of at least 5 characters%');
  PERFORM zz.check('6: the amount must be positive', zz.pay(jul, '0') LIKE 'ERR: Enter the amount received%' AND zz.pay(jul, '-5') LIKE 'ERR: Enter the amount received%' AND zz.pay(jul, 'NULL') LIKE 'ERR: Enter the amount received%');
  PERFORM zz.check('6: with at most two decimals (no half pesewas)', zz.pay(jul, '10.123') LIKE 'ERR: Enter the amount received%');
  PERFORM zz.check('6: the method must be one we know', zz.pay(jul, '10', 'barter') LIKE 'ERR: Choose how the payment was made%');
  PERFORM zz.check('6: the date received cannot be in the future', zz.pay(jul, '10', 'cash', NULL, NULL, 'Recorded for the test', 'now() + interval ''2 days''') LIKE 'ERR: Enter the date the payment was received%');
  PERFORM zz.check('6: an unknown invoice is refused', zz.pay(gen_random_uuid(), '10') LIKE 'ERR: Invoice not found%');
  PERFORM zz.check('6: nothing was recorded by those refusals', (SELECT count(*) FROM public.billing_payments) = 0);
  -- part payment
  j := zz.pay(jul, '50', 'bank_transfer', 'TXN-1')::jsonb;
  PERFORM zz.check('6: a part payment of 50.00 on the 120.00 invoice leaves it partially paid with 70.00 outstanding', j ->> 'invoice_status' = 'partially_paid' AND (j ->> 'outstanding')::numeric = 70 AND zz.invs(jul) = 'partially_paid/50.00/70.00', j::text);
  PERFORM zz.check('6: the period follows the invoice (partially paid, 50.00 paid, 70.00 outstanding)', (zz.per(w1, (SELECT m3 FROM zz.t))).status = 'partially_paid' AND (zz.per(w1, (SELECT m3 FROM zz.t))).amount_paid = 50 AND (zz.per(w1, (SELECT m3 FROM zz.t))).outstanding_amount = 70);
  PERFORM zz.check('6: more than the balance is refused, in plain words', zz.pay(jul, '80', 'cash') LIKE 'ERR: This payment is more than the balance of this invoice (70.00 outstanding)%', zz.pay(jul, '80', 'cash'));
  PERFORM zz.check('6: the same reference for the same method is refused (even with other capitals or spaces)', zz.pay(jul, '5', 'bank_transfer', ' txn-1 ') LIKE 'ERR: A payment with this reference was already recorded%');
  j := zz.pay(jul, '70', 'mobile_money', 'TXN-1')::jsonb;
  PERFORM zz.check('6: the same reference with another method is a different payment: paying the last 70.00 settles the invoice', j ->> 'invoice_status' = 'paid' AND zz.invs(jul) = 'paid/120.00/0.00', j::text);
  PERFORM zz.check('6: a paid invoice has the date it was settled and its period is paid', (SELECT paid_at IS NOT NULL FROM public.billing_invoices WHERE id = jul) AND (zz.per(w1, (SELECT m3 FROM zz.t))).status = 'paid');
  PERFORM zz.check('6: nothing more can be paid on a settled invoice', zz.pay(jul, '1') LIKE 'ERR: This payment is more than the balance%');
  PERFORM zz.check('6: nor on an invoice that was settled by credit', zz.pay(zero, '1') LIKE 'ERR: This payment is more than the balance%');
  -- idempotency
  j := zz.pay(sep, '40', 'cash', NULL, 'dup-key-1')::jsonb;
  PERFORM zz.check('6: a payment with a request key is recorded once', (j ->> 'replayed') = 'false' AND (SELECT count(*) FROM public.billing_payments WHERE invoice_id = sep) = 1, j::text);
  j := zz.pay(sep, '40', 'cash', NULL, 'dup-key-1')::jsonb;
  PERFORM zz.check('6: the same request sent again (a double click) returns the first answer and records nothing more', (j ->> 'replayed') = 'true' AND (SELECT count(*) FROM public.billing_payments WHERE invoice_id = sep) = 1 AND zz.invs(sep) = 'partially_paid/40.00/100.00', j::text);
  PERFORM zz.check('6: the same key for a different amount or invoice is refused', zz.pay(sep, '41', 'cash', NULL, 'dup-key-1') LIKE 'ERR: This request key was already used for a different payment%' AND zz.pay(jul, '40', 'cash', NULL, 'dup-key-1') LIKE 'ERR: This request key was already used%');
  -- reversal
  n := (SELECT count(*) FROM public.billing_payments);
  PERFORM zz.check('6: only an administrator can reverse a payment', zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.admin_billing_reverse_payment(%L, ''Mistaken payment'')::text', (SELECT id FROM public.billing_payments WHERE invoice_id = sep))) LIKE 'ERR: Only platform administrators%');
  PERFORM zz.check('6: a reversal needs a reason', zz.adm(format('SELECT public.admin_billing_reverse_payment(%L, ''no'')::text', (SELECT id FROM public.billing_payments WHERE invoice_id = sep))) LIKE 'ERR: A reason of at least 5 characters%');
  j := zz.adm(format('SELECT public.admin_billing_reverse_payment(%L, ''Cash was never handed over'')::text', (SELECT id FROM public.billing_payments WHERE invoice_id = sep AND kind = 'payment')))::jsonb;
  PERFORM zz.check('6: a reversal puts the invoice back to unpaid (issued, 140.00 outstanding) and keeps both records', j ->> 'invoice_status' = 'issued' AND zz.invs(sep) = 'issued/0.00/140.00' AND (SELECT count(*) FROM public.billing_payments WHERE invoice_id = sep) = 2
    AND (zz.per(w1, (SELECT m1 FROM zz.t))).status = 'invoiced' AND (zz.per(w1, (SELECT m1 FROM zz.t))).amount_paid = 0, j::text);
  PERFORM zz.check('6: a payment cannot be reversed twice, and a reversal cannot be reversed', zz.adm(format('SELECT public.admin_billing_reverse_payment(%L, ''Second attempt'')::text', (SELECT id FROM public.billing_payments WHERE invoice_id = sep AND kind = 'payment'))) LIKE 'ERR: This payment has already been reversed%'
    AND zz.adm(format('SELECT public.admin_billing_reverse_payment(%L, ''Reverse the reversal'')::text', (SELECT id FROM public.billing_payments WHERE invoice_id = sep AND kind = 'reversal'))) LIKE 'ERR: Only a payment can be reversed%');
  PERFORM zz.check('6: an unknown payment is refused', zz.adm(format('SELECT public.admin_billing_reverse_payment(%L, ''Does not exist'')::text', gen_random_uuid())) LIKE 'ERR: Payment not found%');
  j := zz.pay(sep, '140', 'cheque', 'CHQ-77')::jsonb;
  PERFORM zz.check('6: after a reversal the invoice can be paid properly', j ->> 'invoice_status' = 'paid' AND zz.invs(sep) = 'paid/140.00/0.00', j::text);
  -- immutability and audit
  r := zz.try(format('UPDATE public.billing_payments SET amount = 1 WHERE invoice_id = %L', sep));
  PERFORM zz.check('6: payment records can never be edited', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('DELETE FROM public.billing_payments WHERE invoice_id = %L', sep));
  PERFORM zz.check('6: or deleted', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  PERFORM zz.check('6: every payment and reversal wrote an audit entry with the administrator, the business and the reason', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing payment recorded' AND performed_by IS NOT NULL AND business_id = w1 AND length(details ->> 'reason') >= 5) = 4
    AND (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing payment reversed' AND performed_by IS NOT NULL AND business_id = w1 AND length(details ->> 'reason') >= 5) = 1,
    (SELECT string_agg(activity, ',') FROM public.audit_logs WHERE activity LIKE 'Billing payment%'));
  PERFORM zz.check('6: the books agree after all of that', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 7. Overdue --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE ph UUID := (SELECT good FROM zz.bx); jul UUID := zz.inv(ph, (SELECT m3 FROM zz.t)); aug UUID := zz.inv(ph, (SELECT m2 FROM zz.t)); w1 UUID := (SELECT w1 FROM zz.w); n INT; j JSONB;
BEGIN
  -- Let a month go by for the pharmacy's July invoice (the time machine: its dates are moved into the past, with the audit triggers off, as a test would).
  SET LOCAL session_replication_role = replica;
  UPDATE public.billing_invoices SET issued_at = now() - interval '30 days', due_at = now() - interval '16 days' WHERE id = jul;
  UPDATE public.billing_ledger_entries SET created_at = now() - interval '31 days' WHERE period_id = (zz.per(ph, (SELECT m3 FROM zz.t))).id;
  SET LOCAL session_replication_role = origin;
  PERFORM zz.check('7: before the run the late invoice is not yet marked', (SELECT status FROM public.billing_invoices WHERE id = jul) = 'issued');
  n := public.billing_mark_overdue(now());
  PERFORM zz.check('7: the daily check marks exactly that invoice overdue (and its period)', n = 1 AND zz.invs(jul) = 'overdue/0.00/50.00' AND (zz.per(ph, (SELECT m3 FROM zz.t))).status = 'overdue', n::text);
  PERFORM zz.check('7: running it again finds nothing more', public.billing_mark_overdue(now()) = 0);
  PERFORM zz.check('7: an invoice that is paid is never overdue', (SELECT status FROM public.billing_invoices WHERE id = zz.inv(w1, (SELECT m3 FROM zz.t))) = 'paid');
  PERFORM zz.check('7: invoices not yet due are not touched', (SELECT status FROM public.billing_invoices WHERE id = aug) = 'issued');
  j := zz.pay(jul, '20', 'mobile_money', 'MM-ph-1')::jsonb;
  PERFORM zz.check('7: a part payment on an overdue invoice leaves it overdue (it is still late) with 30.00 outstanding', j ->> 'invoice_status' = 'overdue' AND zz.invs(jul) = 'overdue/20.00/30.00', j::text);
  j := zz.pay(jul, '30', 'mobile_money', 'MM-ph-2')::jsonb;
  PERFORM zz.check('7: paying the rest settles it: paid, and so is the period', j ->> 'invoice_status' = 'paid' AND (zz.per(ph, (SELECT m3 FROM zz.t))).status = 'paid', j::text);
  PERFORM zz.check('7: the overdue check does not change when billing is off (it only ages invoices that exist)', public.billing_mark_overdue(now()) = 0);
  PERFORM zz.check('7: reconciliation is clean again', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 8. Invoice settings ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; w5 UUID; j JSONB; i RECORD; s public.billing_settings;
BEGIN
  PERFORM zz.check('8: only an administrator can change invoice settings', zz.val_as((SELECT w1_owner FROM zz.users), 'SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":"X Ltd"}''::jsonb, ''Not allowed to'')::text') LIKE 'ERR: Only platform administrators%'
    AND zz.anon('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":"X Ltd"}''::jsonb, ''Not allowed to'')::text') LIKE 'ERR: permission denied%');
  PERFORM zz.check('8: a reason is required', zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":"X Ltd"}''::jsonb, ''no'')::text') LIKE 'ERR: A reason of at least 5 characters%');
  PERFORM zz.check('8: payment terms must be 0 to 120 days and the delay 0 to 720 hours', zz.adm('SELECT public.admin_billing_set_invoice_settings(121, 24, ''{"name":"X Ltd"}''::jsonb, ''Out of range'')::text') LIKE 'ERR: Payment terms must be between 0 and 120 days%'
    AND zz.adm('SELECT public.admin_billing_set_invoice_settings(-1, 24, ''{"name":"X Ltd"}''::jsonb, ''Out of range'')::text') LIKE 'ERR: Payment terms%' AND zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 721, ''{"name":"X Ltd"}''::jsonb, ''Out of range'')::text') LIKE 'ERR: The invoice delay must be between 0 and 720 hours%');
  PERFORM zz.check('8: only known issuer details are accepted, as short text, and the issuer needs a name', zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":"X Ltd","bank":"1234"}''::jsonb, ''Unknown key'')::text') LIKE 'ERR: Unknown issuer detail: bank%'
    AND zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":12}''::jsonb, ''Not text now'')::text') LIKE 'ERR: The issuer detail name must be text%' AND zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"address":"Accra"}''::jsonb, ''No name given'')::text') LIKE 'ERR: The issuer needs a name%'
    AND zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''[]''::jsonb, ''Not an object'')::text') LIKE 'ERR: The issuer details must be an object%');
  SELECT * INTO s FROM public.billing_settings;
  PERFORM zz.check('8: the refused attempts changed nothing', s.payment_terms_days = 14 AND s.invoice_delay_hours = 24 AND s.issuer ->> 'name' = 'DrugXOne', s.issuer::text);
  j := zz.adm('SELECT public.admin_billing_set_invoice_settings(30, 24, ''{"name":"DrugXOne Ltd","address":"1 Ring Road, Accra","payment_instructions":"Pay by bank transfer or mobile money and quote the invoice number.","email":"billing@drugxone.example"}''::jsonb, ''Agreed terms for the launch'')::text')::jsonb;
  PERFORM zz.check('8: an administrator sets 30-day terms and the issuer details', (j ->> 'payment_terms_days')::int = 30 AND j -> 'issuer' ->> 'name' = 'DrugXOne Ltd', j::text);
  PERFORM zz.check('8: the change is audited with before, after and the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing invoice settings changed' AND performed_by IS NOT NULL AND details ->> 'reason' = 'Agreed terms for the launch'
    AND (details -> 'before' ->> 'payment_terms_days')::int = 14 AND (details -> 'after' ->> 'payment_terms_days')::int = 30));
  -- a new business whose two closed months are invoiced under the new terms
  w5 := zz.mkws('Inv W5');
  PERFORM zz.sub(w5, 'inv_cr', (SELECT m2 FROM zz.t));
  PERFORM public.billing_open_periods(now());
  PERFORM public.billing_issue_invoices(zz.run_at());
  SELECT * INTO i FROM public.billing_invoices WHERE business_id = w5 ORDER BY issued_at LIMIT 1;
  PERFORM zz.check('8: new invoices use the new terms (30 days) and carry the new issuer details', i.due_at = i.issued_at + interval '30 days' AND i.issuer ->> 'name' = 'DrugXOne Ltd' AND i.issuer ->> 'payment_instructions' LIKE 'Pay by bank transfer%', i.issuer::text);
  PERFORM zz.check('8: earlier invoices keep what they were issued with (14 days, DrugXOne)', (SELECT due_at = issued_at + interval '14 days' AND issuer ->> 'name' = 'DrugXOne' FROM public.billing_invoices WHERE id = zz.inv((SELECT w1 FROM zz.w), (SELECT m2 FROM zz.t))));
  -- put the defaults back for the rest of the suite
  PERFORM zz.adm('SELECT public.admin_billing_set_invoice_settings(14, 24, ''{"name":"DrugXOne"}''::jsonb, ''Back to the defaults'')::text');
  PERFORM zz.check('8: the defaults are back', (SELECT payment_terms_days = 14 AND issuer ->> 'name' = 'DrugXOne' FROM public.billing_settings));
END $$;

-- 9. Who can read invoices, and what they see ------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); u RECORD; r TEXT; j JSONB; jul UUID := zz.inv(w1, (SELECT m3 FROM zz.t)); sep UUID := zz.inv(w1, (SELECT m1 FROM zz.t)); ph UUID := (SELECT good FROM zz.bx); phinv UUID := zz.inv(ph, (SELECT m2 FROM zz.t));
BEGIN
  FOR u IN SELECT * FROM (VALUES ('its owner', (SELECT w1_owner FROM zz.users)), ('its manager', '30000000-0000-0000-0000-0000000000f1'::uuid), ('its finance user', '30000000-0000-0000-0000-0000000000f3'::uuid),
                                 ('its accountant', '30000000-0000-0000-0000-0000000000f4'::uuid)) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.billing_my_invoices(%L)::text', w1));
    PERFORM zz.check('9: ' || u.label || ' can see the invoice list', r NOT LIKE 'ERR:%', left(r, 120));
    r := zz.val_as(u.uid, format('SELECT public.billing_my_invoice(%L)::text', jul));
    PERFORM zz.check('9: ' || u.label || ' can open an invoice', r NOT LIKE 'ERR:%', left(r, 120));
  END LOOP;
  FOR u IN SELECT * FROM (VALUES ('its cashier', '30000000-0000-0000-0000-0000000000f2'::uuid), ('another wholesaler''s owner', (SELECT w2_owner FROM zz.users)), ('a pharmacy owner', (SELECT po FROM zz.users)),
                                 ('a platform administrator (they use the admin view)', (SELECT u_admin FROM zz.bx))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.billing_my_invoices(%L)::text', w1));
    PERFORM zz.check('9: ' || u.label || ' cannot see the invoice list', r LIKE 'ERR: You do not have permission to see this business%', left(r, 120));
    r := zz.val_as(u.uid, format('SELECT public.billing_my_invoice(%L)::text', jul));
    PERFORM zz.check('9: ' || u.label || ' cannot open the invoice (and it is not even confirmed to exist)', r = 'ERR: Invoice not found.', left(r, 120));
  END LOOP;
  PERFORM zz.check('9: someone not signed in cannot', zz.anon(format('SELECT public.billing_my_invoices(%L)::text', w1)) LIKE 'ERR: permission denied%' AND zz.anon(format('SELECT public.billing_my_invoice(%L)::text', jul)) LIKE 'ERR: permission denied%');
  j := zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_invoices(%L)::text', w1))::jsonb;
  PERFORM zz.check('9: Inv W1''s list: 3 invoices, 85.00 outstanding (August), 260.00 paid (July and September), nothing overdue', (j ->> 'count')::int = 3 AND (j ->> 'outstanding_total')::numeric = 85 AND (j ->> 'paid_total')::numeric = 260
    AND (j ->> 'overdue_total')::numeric = 0 AND jsonb_array_length(j -> 'invoices') = 3, left(j::text, 300));
  PERFORM zz.check('9: the newest invoice comes first', (j -> 'invoices' -> 0 ->> 'period_start')::timestamptz = (SELECT m1 FROM zz.t));
  PERFORM zz.check('9: the payment history shows every payment and the reversal (5 records)', jsonb_array_length(j -> 'payments') = 5 AND (SELECT count(*) FROM jsonb_array_elements(j -> 'payments') p WHERE p ->> 'kind' = 'reversal') = 1);
  PERFORM zz.check('9: it shows no credit left over for Inv W1', (j ->> 'credit_available')::numeric = 0);
  j := zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_invoices(%L, 2, 0)::text', w1))::jsonb;
  PERFORM zz.check('9: paging: 2 per page, the total stays 3', jsonb_array_length(j -> 'invoices') = 2 AND (j ->> 'count')::int = 3);
  j := zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_invoices(%L, 2, 2)::text', w1))::jsonb;
  PERFORM zz.check('9: the second page has the last invoice', jsonb_array_length(j -> 'invoices') = 1);
  j := zz.val_as((SELECT po FROM zz.users), format('SELECT public.billing_my_invoices(%L)::text', ph))::jsonb;
  PERFORM zz.check('9: the pharmacy sees its own 3 invoices', (j ->> 'count')::int = 3);
  PERFORM zz.check('9: a different pharmacy''s owner cannot see them', zz.val_as((SELECT px FROM zz.users), format('SELECT public.billing_my_invoices(%L)::text', ph)) LIKE 'ERR: You do not have permission%');
  j := zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_invoice(%L)::text', jul))::jsonb;
  PERFORM zz.check('9: the invoice shows its lines (2), its payments (2) and the 3 orders billed in the month', jsonb_array_length(j -> 'lines') = 2 AND jsonb_array_length(j -> 'payments') = 2 AND jsonb_array_length(j -> 'orders') = 3, left(j::text, 200));
  PERFORM zz.check('9: it shows who it is from and to, the amounts, and the status', j -> 'issuer' ->> 'name' = 'DrugXOne' AND j -> 'customer' ->> 'name' = 'Inv W1' AND (j ->> 'total_amount')::numeric = 120 AND j ->> 'status' = 'paid');
  PERFORM zz.check('9: the business does NOT see the administrator''s private note or who recorded a payment', NOT (j::text LIKE '%Received by bank%') AND NOT (j::text LIKE '%recorded_by_email%' AND j::text LIKE '%admin@%'));
  j := zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_invoice(%L)::text', sep))::jsonb;
  PERFORM zz.check('9: it does see a reversal and the reason it was reversed', EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'payments') p WHERE p ->> 'kind' = 'reversal' AND p ->> 'reason' = 'Cash was never handed over'));
  j := zz.val_as((SELECT po FROM zz.users), format('SELECT public.billing_my_invoice(%L)::text', phinv))::jsonb;
  PERFORM zz.check('9: a pharmacy''s invoice has no order list and no fee lines', jsonb_array_length(j -> 'orders') = 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'lines') l WHERE l ->> 'kind' = 'transaction_fees'));
  -- direct table reads
  PERFORM zz.check('9: reading the table directly: the owner sees only its own invoices, lines and payments', zz.val_as((SELECT w1_owner FROM zz.users), 'SELECT (SELECT count(*) FROM public.billing_invoices)::text || ''/'' || (SELECT count(*) FROM public.billing_payments) || ''/'' || (SELECT count(*) FROM public.billing_invoice_lines)')
    = (SELECT count(*)::text FROM public.billing_invoices WHERE business_id = w1) || '/' || (SELECT count(*) FROM public.billing_payments WHERE business_id = w1) || '/' || (SELECT count(*) FROM public.billing_invoice_lines l JOIN public.billing_invoices i ON i.id = l.invoice_id WHERE i.business_id = w1));
  PERFORM zz.check('9: a cashier sees nothing, nor does another business', zz.val_as('30000000-0000-0000-0000-0000000000f2'::uuid, 'SELECT (SELECT count(*) FROM public.billing_invoices)::text || (SELECT count(*) FROM public.billing_payments)') = '00'
    AND zz.val_as((SELECT px FROM zz.users), 'SELECT (SELECT count(*) FROM public.billing_invoices)::text') = '0');
  PERFORM zz.check('9: an administrator reads all of it', zz.adm('SELECT count(*)::text FROM public.billing_invoices') = (SELECT count(*)::text FROM public.billing_invoices));
  PERFORM zz.check('9: nobody can write to these tables directly, an administrator included',
    zz.adm('WITH x AS (UPDATE public.billing_invoices SET status = ''paid'' RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%'
    AND zz.adm('WITH x AS (INSERT INTO public.billing_payments(invoice_id, business_id, amount, method, received_at, idempotency_key) SELECT id, business_id, 1, ''cash'', now(), ''x-direct'' FROM public.billing_invoices LIMIT 1 RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%'
    AND zz.val_as((SELECT w1_owner FROM zz.users), 'WITH x AS (DELETE FROM public.billing_invoice_lines RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%');
END $$;

-- 10. The administrator's lists and numbers --------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; r JSONB; s JSONB; w1 UUID := (SELECT w1 FROM zz.w); d JSONB; ok BOOLEAN; lo TEXT := (SELECT (m3 - interval '1 day')::text FROM zz.t); hi TEXT := (SELECT (zz.run_at() + interval '60 days')::text);
BEGIN
  j := zz.adm('SELECT public.admin_billing_invoices()::text')::jsonb;
  PERFORM zz.check('10: the administrator''s list shows every invoice, with totals that agree with the records', (j ->> 'count')::int = (SELECT count(*) FROM public.billing_invoices) AND (j -> 'totals' ->> 'invoiced')::numeric = (SELECT sum(total_amount) FROM public.billing_invoices)
    AND (j -> 'totals' ->> 'paid')::numeric = (SELECT sum(amount_paid) FROM public.billing_invoices) AND (j -> 'totals' ->> 'outstanding')::numeric = (SELECT sum(outstanding_amount) FROM public.billing_invoices), left((j -> 'totals')::text, 200));
  PERFORM zz.check('10: it filters by status', (zz.adm('SELECT public.admin_billing_invoices(''paid'')::text')::jsonb ->> 'count')::int = (SELECT count(*) FROM public.billing_invoices WHERE status = 'paid')
    AND (zz.adm('SELECT public.admin_billing_invoices(''issued'')::text')::jsonb ->> 'count')::int = (SELECT count(*) FROM public.billing_invoices WHERE status = 'issued'));
  PERFORM zz.check('10: by business type', (zz.adm('SELECT public.admin_billing_invoices(NULL, ''pharmacy'')::text')::jsonb ->> 'count')::int = 3
    AND (zz.adm('SELECT public.admin_billing_invoices(NULL, ''wholesaler'')::text')::jsonb ->> 'count')::int = (SELECT count(*) FROM public.billing_invoices) - 3);
  PERFORM zz.check('10: by invoice number', (zz.adm('SELECT public.admin_billing_invoices(NULL, NULL, ''DXB-' || to_char(now(), 'YYYY') || '-000001'')::text')::jsonb ->> 'count')::int = 1);
  PERFORM zz.check('10: by business name (partial, any capitals)', (zz.adm('SELECT public.admin_billing_invoices(NULL, NULL, ''inv w3'')::text')::jsonb ->> 'count')::int = 2);
  PERFORM zz.check('10: by date issued', (zz.adm(format('SELECT public.admin_billing_invoices(NULL, NULL, NULL, %L, %L)::text', lo, hi))::jsonb ->> 'count')::int = (SELECT count(*) FROM public.billing_invoices)
    AND (zz.adm(format('SELECT public.admin_billing_invoices(NULL, NULL, NULL, %L, %L)::text', (SELECT (m3 - interval '60 days')::text FROM zz.t), lo))::jsonb ->> 'count')::int = 0);
  PERFORM zz.check('10: paging, and nothing beyond 100 at a time', jsonb_array_length(zz.adm('SELECT public.admin_billing_invoices(NULL, NULL, NULL, NULL, NULL, 5, 0)::text')::jsonb -> 'invoices') = 5
    AND jsonb_array_length(zz.adm('SELECT public.admin_billing_invoices(NULL, NULL, NULL, NULL, NULL, 5000, 0)::text')::jsonb -> 'invoices') <= 100);
  PERFORM zz.check('10: an unknown status or type is refused; so is anyone who is not an administrator', zz.adm('SELECT public.admin_billing_invoices(''bogus'')::text') LIKE 'ERR: Unknown invoice status%' AND zz.adm('SELECT public.admin_billing_invoices(NULL, ''bogus'')::text') LIKE 'ERR: Unknown business type%'
    AND zz.val_as((SELECT w1_owner FROM zz.users), 'SELECT public.admin_billing_invoices()::text') LIKE 'ERR: Only platform administrators%' AND zz.anon('SELECT public.admin_billing_invoices()::text') LIKE 'ERR: permission denied%');
  d := zz.adm(format('SELECT public.admin_billing_invoice_detail(%L)::text', zz.inv(w1, (SELECT m3 FROM zz.t))))::jsonb;
  PERFORM zz.check('10: the administrator''s invoice detail includes the private note and who recorded each payment', d::text LIKE '%Received by bank%' AND d::text LIKE '%admin@zz.test%', left(d::text, 200));
  PERFORM zz.check('10: but only an administrator can open it', zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.admin_billing_invoice_detail(%L)::text', zz.inv(w1, (SELECT m3 FROM zz.t)))) LIKE 'ERR: Only platform administrators%');
  PERFORM zz.check('10: an unknown invoice is refused', zz.adm(format('SELECT public.admin_billing_invoice_detail(%L)::text', gen_random_uuid())) LIKE 'ERR: Invoice not found%');
  -- the dashboard: four different money numbers
  j := zz.adm(format('SELECT public.admin_billing_overview(%L, %L)::text', lo, hi))::jsonb;
  r := j -> 'real'; s := j -> 'shadow';
  PERFORM zz.check('10: the dashboard keeps four things apart: invoiced equals the invoices issued', (r ->> 'invoiced')::numeric = (SELECT sum(total_amount) FROM public.billing_invoices), r::text);
  PERFORM zz.check('10: collected is the payments received less reversals (50 + 70 + 140 + 20 + 30 = 310)', (r ->> 'collected')::numeric = 310 AND (r ->> 'collected')::numeric = (SELECT sum(CASE WHEN kind = 'payment' THEN amount ELSE -amount END) FROM public.billing_payments), r::text);
  PERFORM zz.check('10: outstanding is what the invoices still owe, and overdue the part that is late', (r ->> 'outstanding')::numeric = (SELECT sum(outstanding_amount) FROM public.billing_invoices) AND (r ->> 'overdue')::numeric = (SELECT COALESCE(sum(outstanding_amount), 0) FROM public.billing_invoices WHERE status = 'overdue'), r::text);
  PERFORM zz.check('10: invoiced less collected equals outstanding (nothing is lost between them)', (r ->> 'invoiced')::numeric - (r ->> 'collected')::numeric = (r ->> 'outstanding')::numeric, r::text);
  PERFORM zz.check('10: what is accrued but not yet invoiced is shown on its own (the open periods)', (r ->> 'not_yet_invoiced')::numeric = (SELECT sum(amount_due) FROM public.billing_periods WHERE NOT shadow AND status = 'open' AND amount_due > 0), r::text);
  PERFORM zz.check('10: the shadow world has no invoices or payments, whatever the real world has', (s ->> 'invoiced')::numeric = 0 AND (s ->> 'collected')::numeric = 0 AND (s ->> 'outstanding')::numeric = 0 AND (s ->> 'overdue')::numeric = 0, s::text);
  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L)::text', w1))::jsonb;
  PERFORM zz.check('10: a business''s admin detail lists its invoices and payments and its unused credit', jsonb_array_length(d -> 'invoices') = 3 AND jsonb_array_length(d -> 'payments') = 5 AND (d ->> 'credit_available')::numeric = 0, left(d::text, 150));
  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L, ''shadow'')::text', w1))::jsonb;
  PERFORM zz.check('10: the shadow view of the same business has none', jsonb_array_length(d -> 'invoices') = 0 AND jsonb_array_length(d -> 'payments') = 0);
  PERFORM zz.check('10: the earlier reports still work (overview, organizations)', zz.adm('SELECT public.admin_billing_organizations()::text') NOT LIKE 'ERR:%' AND zz.val_as((SELECT w1_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', w1)) NOT LIKE 'ERR:%');
END $$;

-- 11. The reconciliation finds each inconsistency -------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); w3 UUID := (SELECT w3 FROM zz.w); found TEXT; sep UUID := zz.inv(w1, (SELECT m1 FROM zz.t)); aug UUID := zz.inv(w1, (SELECT m2 FROM zz.t)); augp UUID := (zz.per(w1, (SELECT m2 FROM zz.t))).id;
BEGIN
  PERFORM zz.check('11: the books are clean to start with', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
  PERFORM zz.check('11: the administrator''s view says healthy', (zz.adm('SELECT public.admin_billing_reconciliation()::text')::jsonb ->> 'healthy')::boolean);

  -- a line that does not add up
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_invoice_lines SET amount = amount + 1 WHERE invoice_id = aug AND line_no = 1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a line that no longer adds up to its invoice total is found', found LIKE '%invoice_lines_differ_from_total%', found);
  -- an invoice that differs from its period
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_invoices SET transaction_fees_amount = 5 WHERE id = aug;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: an invoice that differs from its period is found', found LIKE '%invoice_differs_from_its_period%', found);
  -- paid amount that the payments do not support
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_invoices SET amount_paid = 5 WHERE id = aug;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: an invoice marked as paid more than its payments is found (and its period too)', found LIKE '%invoice_paid_differs_from_payments%' AND found LIKE '%period_paid_or_status_differs_from_invoice%', found);
  -- period paid amount
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_periods SET amount_paid = 1 WHERE id = augp;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a period whose paid amount differs from its invoice is found', found LIKE '%period_paid_or_status_differs_from_invoice%', found);
  -- a payment bigger than the invoice
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_payments(invoice_id, business_id, amount, method, received_at, idempotency_key) VALUES (aug, w1, 500, 'cash', now(), 'inv-test-over');
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a payment larger than its invoice is found', found LIKE '%payment_exceeds_invoice_or_reversal_differs%', found);
  -- a reversal that does not match its payment
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_payments(invoice_id, business_id, kind, amount, method, received_at, reason, reverses_payment_id, idempotency_key)
    SELECT invoice_id, business_id, 'reversal', amount + 1, method, now(), 'A wrong reversal', id, 'inv-test-badrev' FROM public.billing_payments WHERE invoice_id = zz.inv(w1, (SELECT m3 FROM zz.t)) AND kind = 'payment' LIMIT 1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a reversal of a different amount is found', found LIKE '%payment_exceeds_invoice_or_reversal_differs%', found);
  -- an entry in an invoiced period, created after the invoice
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, charged_amount, reason, source, idempotency_key, created_at)
    SELECT w1, period_id, 'manual_debit', 1, 'Sneaked in', 'admin', 'inv-test-sneak', issued_at + interval '1 minute' FROM public.billing_invoices WHERE id = aug;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a ledger entry added to a period after it was invoiced is found', found LIKE '%entries_added_to_an_invoiced_period%', found);
  -- a gap in the numbers
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_settings SET last_invoice_number = last_invoice_number + 1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a missing invoice number is found', found LIKE '%invoice_numbers_have_a_gap%', found);
  -- more credit used than there was
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_periods SET credits_amount = credits_amount - 5 WHERE id = (zz.per(w3, (SELECT m3 FROM zz.t))).id;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: credit used beyond what was available is found', found LIKE '%credit_used_more_than_available%', found);
  -- an old period nobody invoiced
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_periods SET status = 'open' WHERE id = augp;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: a real period that ended long ago and was never invoiced is found (a warning that the scheduler is not running)', found LIKE '%period_not_invoiced_when_it_should_be%', found);
  -- an unpaid invoice past its due date that was not marked
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_invoices SET issued_at = now() - interval '40 days', due_at = now() - interval '10 days' WHERE id = aug;
    UPDATE public.billing_ledger_entries SET created_at = now() - interval '41 days' WHERE period_id = augp;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('11: an invoice that is past due and unpaid but not marked overdue is found', found LIKE '%invoice_overdue_but_not_marked%', found);
  PERFORM zz.check('11: and after all those undone mistakes the books are clean again', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 12. Who can call what ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY['billing_issue_invoices(timestamp with time zone)', 'billing_mark_overdue(timestamp with time zone)', '_billing_sync_invoice(uuid, timestamp with time zone)', '_billing_available_credit(uuid)',
                           '_billing_invoice_json(uuid, boolean)', '_billing_invoice_status(numeric, numeric, timestamp with time zone, timestamp with time zone)', '_billing_reconcile_invoices()', '_billing_reconcile_engine()', 'billing_reconcile()'] LOOP
    PERFORM zz.check('12: ' || f || ' cannot be called by a signed-in user or a visitor', NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE') AND NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'));
  END LOOP;
  FOREACH f IN ARRAY ARRAY['admin_billing_record_payment(uuid, numeric, text, text, timestamp with time zone, text, text, text)', 'admin_billing_reverse_payment(uuid, text)', 'admin_billing_set_invoice_settings(integer, integer, jsonb, text)',
                           'admin_billing_invoices(text, text, text, timestamp with time zone, timestamp with time zone, integer, integer)', 'admin_billing_invoice_detail(uuid)', 'billing_my_invoices(uuid, integer, integer)', 'billing_my_invoice(uuid)'] LOOP
    PERFORM zz.check('12: ' || f || ' is not open to visitors, and checks who is asking when signed in', NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE') AND has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'));
  END LOOP;
  PERFORM zz.check('12: the invoice tables are closed to visitors altogether', NOT has_table_privilege('anon', 'public.billing_invoices', 'SELECT') AND NOT has_table_privilege('anon', 'public.billing_payments', 'SELECT') AND NOT has_table_privilege('anon', 'public.billing_invoice_lines', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.billing_invoices', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.billing_payments', 'UPDATE') AND NOT has_table_privilege('authenticated', 'public.billing_invoice_lines', 'DELETE'));
  PERFORM zz.check('12: row security is on for all three', (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_invoices'::regclass, 'public.billing_payments'::regclass, 'public.billing_invoice_lines'::regclass)));
END $$;

-- 13. A problem with one period never stops the others -----------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w6 UUID; j JSONB; before_n INT; counter BIGINT;
BEGIN
  w6 := zz.mkws('Inv W6');
  PERFORM zz.sub(w6, 'inv_cr', (SELECT m2 FROM zz.t));
  PERFORM public.billing_open_periods(now());
  SELECT last_invoice_number INTO counter FROM public.billing_settings;
  SELECT count(*) INTO before_n FROM public.billing_invoices;
  -- Make the next invoice number collide with an existing one: the unique number refuses it.
  UPDATE public.billing_settings SET last_invoice_number = 0;
  j := public.billing_issue_invoices(zz.run_at());
  PERFORM zz.check('13: when an invoice cannot be created (here, a clashing number) that period fails alone: the others in the run are untouched and the failure is counted', (j ->> 'failed')::int >= 1, j::text);
  PERFORM zz.check('13: nothing half-made is left: no invoice, no lines, the period still open and the counter unchanged by the failed attempts', (SELECT count(*) FROM public.billing_invoices) = before_n
    AND (SELECT count(*) FROM public.billing_periods WHERE business_id = w6 AND NOT shadow AND status = 'open' AND period_end <= zz.run_at()) = 2
    AND NOT EXISTS (SELECT 1 FROM public.billing_invoice_lines l WHERE NOT EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.id = l.invoice_id))
    AND (SELECT last_invoice_number FROM public.billing_settings) = 0);
  UPDATE public.billing_settings SET last_invoice_number = counter;
  j := public.billing_issue_invoices(zz.run_at());
  PERFORM zz.check('13: with the counter right again, the next run issues them (nothing was lost)', (j ->> 'invoices_issued')::int = 2 AND (j ->> 'failed')::int = 0 AND (SELECT count(*) FROM public.billing_invoices) = before_n + 2, j::text);
  PERFORM zz.check('13: the numbers are still contiguous', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 14. The fee calculation itself did not move ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w1 UUID := (SELECT w1 FROM zz.w); o UUID; p public.billing_periods;
BEGIN
  o := zz.go(w1, 1000, 25, now());
  p := zz.per(w1, (SELECT m0 FROM zz.t));
  PERFORM zz.check('14: an order delivered now is billed in the current period as before (October already had a free order, so this one is charged 1% = 10.00)', zz.a(o) = 'chargeable/-/10.00' AND p.status = 'open', zz.a(o));
  PERFORM zz.check('14: with the whole month''s fees still under the cap', p.transaction_fees_amount <= 30, p::text);
  PERFORM zz.check('14: every real period either is open, or has an invoice, or was closed because it had nothing to pay', NOT EXISTS (SELECT 1 FROM public.billing_periods x WHERE NOT x.shadow AND x.status IN ('invoiced', 'paid', 'overdue', 'partially_paid') AND NOT EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.period_id = x.id)));
  PERFORM zz.check('14: the final books are clean', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;
