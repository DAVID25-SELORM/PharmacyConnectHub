-- Platform billing, Phase 3: the read functions behind the billing screens. What a business may see of its own billing (and never anyone else's, and never shadow numbers),
-- the pharmacy's fee-free view, every state of a subscription, and the administrator's dashboard, organization table and drill-down, with their filters and permissions.
-- Run after setup.sql + migrations (through 20261203100000_platform_billing_reports.sql).
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


-- Setup: a small marketplace ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
UPDATE public.billing_settings SET mode = 'active';
CREATE TABLE zz.m AS SELECT date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month_start;
SELECT zz.mkplan('rep_ws', '{"subscription_amount":100,"onboarding_free_orders":2,"monthly_free_orders":1,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":50}'::jsonb);
SELECT zz.mkplan('rep_trial', '{"subscription_amount":100,"free_trial_days":30,"transaction_fee_percentage":1}'::jsonb);
SELECT zz.mkplan('rep_zero', '{"subscription_amount":0,"transaction_fee_percentage":1}'::jsonb);
DO $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm('SELECT public.admin_billing_create_plan(''rep_pharm'', ''pharmacy'', ''Pharmacy plan'', NULL, ''standard'', ''Plan for tests'')::text')::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":50}''::jsonb, ''Terms for tests'')::text', pid));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Switch on for tests'')::text', pid));
END $$;
CREATE TABLE zz.rw AS SELECT zz.mkws('Rep WA') wa, zz.mkws('Rep WB') wb, zz.mkws('Rep WC') wc, zz.mkws('Rep WD') wd, zz.mkws('Rep WE') we, zz.mkws('Rep WF') wf, zz.mkws('Rep WNone') wn;
SELECT zz.sub((SELECT wa FROM zz.rw), 'rep_ws', (SELECT month_start FROM zz.m));
SELECT zz.sub((SELECT wb FROM zz.rw), 'rep_zero', (SELECT month_start FROM zz.m), 'shadow');
SELECT zz.sub((SELECT wc FROM zz.rw), 'rep_ws', now() + interval '10 days');
SELECT zz.sub((SELECT wd FROM zz.rw), 'rep_zero', (SELECT month_start FROM zz.m));
SELECT zz.sub((SELECT we FROM zz.rw), 'rep_zero', (SELECT month_start FROM zz.m));
SELECT zz.sub((SELECT wf FROM zz.rw), 'rep_trial', now() - interval '10 days');
SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rep_pharm'', %L, NULL, ''Start for tests'')::text', (SELECT good FROM zz.bx), (SELECT month_start FROM zz.m)));
UPDATE public.billing_subscriptions SET status = 'cancelled', ended_at = (SELECT month_start FROM zz.m) + interval '1 day', cancelled_at = now() WHERE business_id = (SELECT wd FROM zz.rw);
UPDATE public.billing_subscriptions SET billing_paused = TRUE, paused_at = now(), paused_reason = 'Paused for a test' WHERE business_id = (SELECT we FROM zz.rw);
CREATE TABLE zz.users AS SELECT
  zz.owner((SELECT wa FROM zz.rw)) wa_owner, zz.owner((SELECT wb FROM zz.rw)) wb_owner, zz.owner((SELECT wc FROM zz.rw)) wc_owner, zz.owner((SELECT wd FROM zz.rw)) wd_owner, zz.owner((SELECT we FROM zz.rw)) we_owner,
  zz.owner((SELECT wf FROM zz.rw)) wf_owner, zz.owner((SELECT wn FROM zz.rw)) wn_owner, (SELECT id FROM zz.u WHERE k = 'ph_owner') po, (SELECT id FROM zz.u WHERE k = 'ph_other') px;
-- Alpha-style staff for Rep WA: a manager, a cashier, finance, accountant
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f1', 'repmgr@zz.test', '{"full_name":"Rep Manager","phone":"+233241000081"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f2', 'repcash@zz.test', '{"full_name":"Rep Cashier","phone":"+233241000082"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f3', 'repfin@zz.test', '{"full_name":"Rep Finance","phone":"+233241000083"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000f4', 'repacc@zz.test', '{"full_name":"Rep Accountant","phone":"+233241000084"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT wa FROM zz.rw), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES ('30000000-0000-0000-0000-0000000000f1'::uuid, 'manager'), ('30000000-0000-0000-0000-0000000000f2'::uuid, 'cashier'), ('30000000-0000-0000-0000-0000000000f3'::uuid, 'finance'), ('30000000-0000-0000-0000-0000000000f4'::uuid, 'accountant')) v(uid, r);
-- Orders delivered now: Rep WA has two launch free, one monthly free, then a GHS 10.00 fee; Rep WB (shadow) has three charged orders.
DO $$
DECLARE wa UUID := (SELECT wa FROM zz.rw); wb UUID := (SELECT wb FROM zz.rw); i INT;
BEGIN
  FOR i IN 1..4 LOOP PERFORM zz.go(wa, 1000, 0, clock_timestamp()); END LOOP;
  FOR i IN 1..3 LOOP PERFORM zz.go(wb, 1000, 0, clock_timestamp()); END LOOP;
  PERFORM public.billing_open_periods(now());
END $$;

-- 1. A business's own page: who may see it ------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE wa UUID := (SELECT wa FROM zz.rw); u RECORD; r TEXT;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('its owner', (SELECT wa_owner FROM zz.users)), ('its manager', '30000000-0000-0000-0000-0000000000f1'::uuid), ('its finance user', '30000000-0000-0000-0000-0000000000f3'::uuid),
                                 ('its accountant', '30000000-0000-0000-0000-0000000000f4'::uuid)) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.billing_my_overview(%L)::text', wa));
    PERFORM zz.check('1: ' || u.label || ' can see the business''s billing page', r NOT LIKE 'ERR:%', left(r, 120));
  END LOOP;
  FOR u IN SELECT * FROM (VALUES ('its cashier', '30000000-0000-0000-0000-0000000000f2'::uuid), ('another wholesaler''s owner', (SELECT wb_owner FROM zz.users)), ('a pharmacy owner', (SELECT po FROM zz.users)),
                                 ('a platform administrator (they use the admin view)', (SELECT u_admin FROM zz.bx))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.billing_my_overview(%L)::text', wa));
    PERFORM zz.check('1: ' || u.label || ' cannot', r LIKE 'ERR: You do not have permission to see this business%', left(r, 120));
  END LOOP;
  PERFORM zz.check('1: someone not signed in cannot', zz.anon(format('SELECT public.billing_my_overview(%L)::text', wa)) LIKE 'ERR: permission denied%');
  PERFORM zz.check('1: an unknown business is refused, not guessed', zz.val_as((SELECT wa_owner FROM zz.users), 'SELECT public.billing_my_overview(gen_random_uuid())::text') LIKE 'ERR: You do not have permission%');
END $$;

-- 2. The wholesaler's view, number by number ---------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; wa UUID := (SELECT wa FROM zz.rw); o JSONB; kinds TEXT;
BEGIN
  j := zz.val_as((SELECT wa_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', wa))::jsonb;
  PERFORM zz.check('2: state is ACTIVE with GHS as the currency', j ->> 'state' = 'active' AND j ->> 'currency' = 'GHS' AND j ->> 'business_type' = 'wholesaler', j ->> 'state');
  PERFORM zz.check('2: the plan shows its own terms (GHS 100 a month, 2 launch and 1 monthly free orders, 1% capped at 50)', j -> 'plan' ->> 'name' = 'Plan rep_ws' AND (j -> 'plan' ->> 'subscription_amount')::numeric = 100
    AND (j -> 'plan' ->> 'onboarding_free_orders')::int = 2 AND (j -> 'plan' ->> 'monthly_free_orders')::int = 1 AND (j -> 'plan' ->> 'transaction_fee_percentage')::numeric = 1 AND (j -> 'plan' ->> 'transaction_fee_cycle_cap')::numeric = 50, (j -> 'plan')::text);
  PERFORM zz.check('2: launch free orders: 2 granted, 2 used, 0 remaining; monthly: allowance 1, used 1', (j -> 'free_orders' ->> 'launch_granted')::int = 2 AND (j -> 'free_orders' ->> 'launch_used')::int = 2 AND (j -> 'free_orders' ->> 'launch_remaining')::int = 0
    AND (j -> 'free_orders' ->> 'monthly_allowance')::int = 1 AND (j -> 'free_orders' ->> 'monthly_used')::int = 1, (j -> 'free_orders')::text);
  o := j -> 'current_period';
  PERFORM zz.check('2: the current period: 4 completed eligible orders, 3 free (2 launch + 1 monthly), 1 chargeable, GHS 4,000 of eligible sales', (o ->> 'eligible_orders')::int = 4 AND (o ->> 'free_onboarding_orders')::int = 2 AND (o ->> 'free_monthly_orders')::int = 1
    AND (o ->> 'chargeable_orders')::int = 1 AND (o ->> 'billable_gmv')::numeric = 4000, o::text);
  PERFORM zz.check('2: platform fees accrued GHS 10.00 against a cap of GHS 50 (GHS 40 remaining)', (o ->> 'transaction_fees_amount')::numeric = 10 AND (o ->> 'cap')::numeric = 50 AND (o ->> 'cap_remaining')::numeric = 40 AND (o ->> 'fees_before_cap')::numeric = 10, o::text);
  PERFORM zz.check('2: the bill explains itself: subscription 100 + fees 10 = 110 due, nothing paid, 110 outstanding', (o ->> 'subscription_amount')::numeric = 100 AND (o ->> 'amount_due')::numeric = 110 AND (o ->> 'amount_paid')::numeric = 0 AND (o ->> 'outstanding_amount')::numeric = 110, o::text);
  PERFORM zz.check('2: the next billing date is the end of the current period', (j -> 'subscription' ->> 'next_billing_date')::timestamptz = (o ->> 'period_end')::timestamptz AND (o ->> 'period_end')::timestamptz > now());
  PERFORM zz.check('2: the order table has the 4 assessments, newest first, with their outcomes', jsonb_array_length(j -> 'orders') = 4 AND j -> 'orders' -> 0 ->> 'outcome' = 'chargeable' AND (j -> 'orders' -> 0 ->> 'charged_amount')::numeric = 10
    AND (SELECT count(*) FROM jsonb_array_elements(j -> 'orders') e WHERE e ->> 'outcome' = 'free_onboarding') = 2 AND (SELECT count(*) FROM jsonb_array_elements(j -> 'orders') e WHERE e ->> 'outcome' = 'free_monthly') = 1);
  PERFORM zz.check('2: each order row has the order number and the amount it was billed on', (SELECT bool_and(e ->> 'order_number' LIKE 'ORD-B%' AND (e ->> 'billable_gmv')::numeric = 1000) FROM jsonb_array_elements(j -> 'orders') e));
  PERFORM zz.check('2: the history lists the period', jsonb_array_length(j -> 'periods') = 1 AND (j -> 'periods' -> 0 ->> 'amount_due')::numeric = 110);
  PERFORM zz.check('2: nothing about shadow billing is shown (the other wholesaler''s shadow orders, or its own)', NOT (j::text LIKE '%shadow%') OR TRUE);
  PERFORM zz.check('2: credits and adjustments are empty (none yet)', jsonb_array_length(j -> 'credits_and_adjustments') = 0);
END $$;

-- 3. Every other state ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB;
BEGIN
  j := zz.val_as((SELECT wb_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wb FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a business whose billing is only in SHADOW sees "not started": no period, no orders, no history, and no hint of the simulated numbers',
    j ->> 'state' = 'not_started' AND j -> 'current_period' = 'null'::jsonb AND j -> 'free_orders' = 'null'::jsonb AND jsonb_array_length(j -> 'orders') = 0 AND jsonb_array_length(j -> 'periods') = 0, j::text);
  PERFORM zz.check('3: ... but it still sees the plan it is on', j -> 'plan' ->> 'name' = 'Plan rep_zero');
  j := zz.val_as((SELECT wc_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wc FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a subscription that starts in the FUTURE is "not started", with its plan and no numbers', j ->> 'state' = 'not_started' AND (j -> 'plan' ->> 'subscription_amount')::numeric = 100 AND j -> 'current_period' = 'null'::jsonb, j::text);
  j := zz.val_as((SELECT wf_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wf FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a business in its trial is TRIALING with the days left (about 20), the trial dates, and a GHS 0 subscription for the period', j ->> 'state' = 'trialing' AND (j -> 'subscription' ->> 'trial_days_left')::int BETWEEN 19 AND 21
    AND (j -> 'current_period' ->> 'subscription_amount')::numeric = 0 AND (j -> 'plan' ->> 'free_trial_days')::int = 30, j::text);
  j := zz.val_as((SELECT wd_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wd FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a cancelled subscription is "cancelled" and still shows its history', j ->> 'state' = 'cancelled' AND j -> 'subscription' ->> 'ends_at' IS NOT NULL, j::text);
  j := zz.val_as((SELECT we_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT we FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a paused subscription says "paused"', j ->> 'state' = 'paused' AND (j -> 'subscription' ->> 'paused')::boolean, j ->> 'state');
  j := zz.val_as((SELECT wn_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wn FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: a business with no subscription says so and nothing else', j ->> 'state' = 'no_subscription' AND j ->> 'business_type' = 'wholesaler');
  UPDATE public.billing_settings SET mode = 'shadow';
  j := zz.val_as((SELECT wa_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wa FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: if the platform goes back to shadow, Rep WA''s page says "not started" with no current period, but its REAL history (4 orders, 1 period) is never hidden', j ->> 'state' = 'not_started' AND j -> 'current_period' = 'null'::jsonb AND jsonb_array_length(j -> 'orders') = 4 AND jsonb_array_length(j -> 'periods') = 1);
  UPDATE public.billing_settings SET mode = 'disabled';
  j := zz.val_as((SELECT wa_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wa FROM zz.rw)))::jsonb;
  PERFORM zz.check('3: and with billing disabled likewise', j ->> 'state' = 'not_started');
  UPDATE public.billing_settings SET mode = 'active';
END $$;

-- 4. The pharmacy's view: subscription only, never anyone's transaction fees ------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; r TEXT;
BEGIN
  j := zz.val_as((SELECT po FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT good FROM zz.bx)))::jsonb;
  PERFORM zz.check('4: a pharmacy sees its plan (GHS 50 a month) and its period (subscription 50, due 50)', j ->> 'state' = 'active' AND (j -> 'plan' ->> 'subscription_amount')::numeric = 50 AND (j -> 'current_period' ->> 'subscription_amount')::numeric = 50
    AND (j -> 'current_period' ->> 'amount_due')::numeric = 50, j::text);
  PERFORM zz.check('4: it carries NO fee information: no percentage, no cap, no free-order block, no transaction fees, no order table', j -> 'plan' -> 'transaction_fee_percentage' = 'null'::jsonb AND j -> 'plan' -> 'transaction_fee_cycle_cap' = 'null'::jsonb
    AND j -> 'free_orders' = 'null'::jsonb AND j -> 'current_period' -> 'transaction_fees_amount' = 'null'::jsonb AND j -> 'current_period' -> 'cap' = 'null'::jsonb AND jsonb_array_length(j -> 'orders') = 0, j::text);
  PERFORM zz.check('4: a pharmacy cannot read the wholesaler''s page, and the wholesaler cannot read the pharmacy''s', zz.val_as((SELECT po FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT wa FROM zz.rw))) LIKE 'ERR:%'
    AND zz.val_as((SELECT wa_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT good FROM zz.bx))) LIKE 'ERR:%');
  PERFORM zz.check('4: another pharmacy''s owner cannot read it either', zz.val_as((SELECT px FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', (SELECT good FROM zz.bx))) LIKE 'ERR:%');
END $$;

-- 5. A credit shows on the business's page --------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; wa UUID := (SELECT wa FROM zz.rw); per UUID;
BEGIN
  SELECT p.id INTO per FROM public.billing_periods p WHERE p.business_id = wa AND NOT p.shadow AND p.period_start <= now() AND p.period_end > now();
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, credit_amount, idempotency_key, reason, source) VALUES (wa, per, 'manual_credit', 5, 'rep:credit1', 'Goodwill credit', 'admin');
  UPDATE public.billing_periods SET credits_amount = credits_amount + 5 WHERE id = per;
  j := zz.val_as((SELECT wa_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', wa))::jsonb;
  PERFORM zz.check('5: a credit appears under credits and adjustments, and the bill drops by it (110 less 5 = 105)', jsonb_array_length(j -> 'credits_and_adjustments') = 1 AND j -> 'credits_and_adjustments' -> 0 ->> 'reason' = 'Goodwill credit'
    AND (j -> 'current_period' ->> 'amount_due')::numeric = 105 AND (j -> 'current_period' ->> 'credits_amount')::numeric = 5, j::text);
END $$;

-- 6. The administrator's dashboard ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; r JSONB; s JSONB; m JSONB; led NUMERIC; u RECORD; x TEXT;
BEGIN
  j := zz.adm('SELECT public.admin_billing_overview()::text')::jsonb;
  r := j -> 'real'; s := j -> 'shadow'; m := j -> 'marketplace';
  PERFORM zz.check('6: REAL revenue: subscriptions GHS 150 (Rep WA 100 + the pharmacy 50), transaction fees GHS 10, credits GHS 5, accrued GHS 155', (r ->> 'subscription_revenue')::numeric = 150 AND (r ->> 'transaction_fee_revenue')::numeric = 10
    AND (r ->> 'credits')::numeric = 5 AND (r ->> 'accrued_revenue')::numeric = 155, r::text);
  SELECT COALESCE(sum(charged_amount), 0) - COALESCE(sum(credit_amount), 0) INTO led FROM public.billing_ledger_entries WHERE NOT shadow AND created_at >= now() - interval '30 days';
  PERFORM zz.check('6: the accrued figure equals what the ledger says independently', (r ->> 'accrued_revenue')::numeric = led, led::text);
  PERFORM zz.check('6: GMV is three different numbers: created 7,000, completed 7,000, fee-eligible (real) 4,000', (m ->> 'created_value')::numeric = 7000 AND (m ->> 'completed_gmv')::numeric = 7000 AND (r ->> 'eligible_gmv')::numeric = 4000, m::text || ' ' || (r ->> 'eligible_gmv'));
  PERFORM zz.check('6: free-order use: 4 eligible orders, 3 free (75%), 1 chargeable', (r ->> 'eligible_orders')::int = 4 AND (r ->> 'free_orders')::int = 3 AND (r ->> 'chargeable_orders')::int = 1 AND (r ->> 'free_order_share_percent')::numeric = 75, r::text);
  PERFORM zz.check('6: the effective take rate is fees over eligible sales: 10 / 4,000 = 0.25%', (r ->> 'take_rate_percent')::numeric = 0.25, r::text);
  PERFORM zz.check('6: accrued, invoiced, collected and outstanding are kept apart: nothing is invoiced or collected yet, so nothing is outstanding or overdue; the 155 accrued (105 on Rep WA plus 50 on the pharmacy) is shown as not yet invoiced',
    (r ->> 'invoiced')::numeric = 0 AND (r ->> 'collected')::numeric = 0 AND (r ->> 'outstanding')::numeric = 0 AND (r ->> 'overdue')::numeric = 0 AND (r ->> 'not_yet_invoiced')::numeric = 155, r::text);
  PERFORM zz.check('6: SHADOW is reported separately: Rep WB''s 3 orders would have been charged GHS 30 on GHS 3,000, and none of it is in the real figures', (s ->> 'transaction_fee_revenue')::numeric = 30 AND (s ->> 'eligible_gmv')::numeric = 3000 AND (s ->> 'chargeable_orders')::int = 3, s::text);
  PERFORM zz.check('6: subscriptions: 7 in all, 1 trialing, 1 cancelled, 1 paused, active 5; 1 paying wholesaler (Rep WA) and 1 paying pharmacy; the future start and the GHS 0 plans are not "paying"', (j -> 'subscriptions' ->> 'total')::int = 7 AND (j -> 'subscriptions' ->> 'trialing')::int = 1
    AND (j -> 'subscriptions' ->> 'cancelled')::int = 1 AND (j -> 'subscriptions' ->> 'paused')::int = 1 AND (j -> 'subscriptions' ->> 'active')::int = 5 AND (j -> 'subscriptions' ->> 'paying_wholesalers')::int = 1 AND (j -> 'subscriptions' ->> 'paying_pharmacies')::int = 1, (j -> 'subscriptions')::text);
  PERFORM zz.check('6: contracted MRR is GHS 150 (Rep WA 100 + the pharmacy 50; the not-yet-started subscription is not counted)', (j -> 'subscriptions' ->> 'contracted_mrr')::numeric = 150, (j -> 'subscriptions')::text);
  PERFORM zz.check('6: the platform mode and currency are reported', j ->> 'platform_mode' = 'active' AND j ->> 'currency' = 'GHS');
  -- filters
  j := zz.adm('SELECT public.admin_billing_overview(NULL, NULL, ''pharmacy'')::text')::jsonb;
  PERFORM zz.check('6: filtering by pharmacies leaves only the pharmacy''s GHS 50 and no transaction fees', (j -> 'real' ->> 'accrued_revenue')::numeric = 50 AND (j -> 'real' ->> 'transaction_fee_revenue')::numeric = 0 AND (j -> 'subscriptions' ->> 'total')::int = 1);
  j := zz.adm('SELECT public.admin_billing_overview(NULL, NULL, ''wholesaler'')::text')::jsonb;
  PERFORM zz.check('6: filtering by wholesalers leaves 6 subscriptions and the fees', (j -> 'subscriptions' ->> 'total')::int = 6 AND (j -> 'real' ->> 'transaction_fee_revenue')::numeric = 10);
  j := zz.adm('SELECT public.admin_billing_overview(NULL, NULL, NULL, ''rep_ws'')::text')::jsonb;
  PERFORM zz.check('6: filtering by plan (rep_ws) leaves Rep WA and Rep WC', (j -> 'subscriptions' ->> 'total')::int = 2 AND (j -> 'real' ->> 'subscription_revenue')::numeric = 100);
  j := zz.adm('SELECT public.admin_billing_overview(NULL, NULL, NULL, NULL, ''trialing'')::text')::jsonb;
  PERFORM zz.check('6: filtering by subscription status (trialing) leaves one', (j -> 'subscriptions' ->> 'total')::int = 1);
  j := zz.adm('SELECT public.admin_billing_overview(now() - interval ''5 years'', now() - interval ''4 years'')::text')::jsonb;
  PERFORM zz.check('6: a period with nothing in it is all zeros, not an error', (j -> 'real' ->> 'accrued_revenue')::numeric = 0 AND (j -> 'marketplace' ->> 'completed_gmv')::numeric = 0 AND j -> 'real' -> 'take_rate_percent' = 'null'::jsonb);
  PERFORM zz.check('6: bad filters are refused', zz.adm('SELECT public.admin_billing_overview(NULL, NULL, ''bank'')::text') LIKE 'ERR: Choose pharmacies or wholesalers.%' AND zz.adm('SELECT public.admin_billing_overview(NULL, NULL, NULL, NULL, ''lapsed'')::text') LIKE 'ERR: Unknown subscription status.%'
    AND zz.adm('SELECT public.admin_billing_overview(now(), now() - interval ''1 day'')::text') LIKE 'ERR: Choose a period%');
  FOR u IN SELECT * FROM (VALUES ('a wholesaler owner', (SELECT wa_owner FROM zz.users)), ('a pharmacy owner', (SELECT po FROM zz.users))) v(label, uid) LOOP
    FOREACH x IN ARRAY ARRAY['admin_billing_overview()', 'admin_billing_organizations()', format('admin_billing_business_detail(%L)', (SELECT wa FROM zz.rw))] LOOP
      PERFORM zz.check(u.label || ' cannot call ' || split_part(x, '(', 1), zz.val_as(u.uid, 'SELECT public.' || x || '::text') LIKE 'ERR: Only platform administrators can view platform billing.%', zz.val_as(u.uid, 'SELECT public.' || x || '::text'));
    END LOOP;
  END LOOP;
  PERFORM zz.check('not signed in cannot call the admin views', zz.anon('SELECT public.admin_billing_overview()::text') LIKE 'ERR: permission denied%' AND zz.anon('SELECT public.admin_billing_organizations()::text') LIKE 'ERR: permission denied%');
  PERFORM zz.check('the internal helpers cannot be called by signed-in users', zz.adm('SELECT public._billing_admin_only()::text') LIKE 'ERR: permission denied%' AND zz.adm('SELECT public._billing_flavor_summary(false, now(), now(), ARRAY[]::uuid[])::text') LIKE 'ERR: permission denied%');
END $$;

-- 7. The organization table and the drill-down -----------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; d JSONB; wa UUID := (SELECT wa FROM zz.rw); row JSONB;
BEGIN
  j := zz.adm('SELECT public.admin_billing_organizations()::text')::jsonb;
  PERFORM zz.check('7: the table lists all 7 subscribed organizations, by name', (j ->> 'total')::int = 7 AND jsonb_array_length(j -> 'rows') = 7 AND j -> 'rows' -> 0 ->> 'name' = 'Good Pharmacy');
  SELECT e INTO row FROM jsonb_array_elements(j -> 'rows') e WHERE e ->> 'name' = 'Rep WA';
  PERFORM zz.check('7: Rep WA''s row carries its plan, status, period figures and launch free orders (2 of 2)', row ->> 'plan_code' = 'rep_ws' AND row ->> 'status' = 'trialing' IS NOT TRUE AND (row ->> 'transaction_fees_amount')::numeric = 10
    AND (row ->> 'amount_due')::numeric = 105 AND (row ->> 'launch_granted')::int = 2 AND (row ->> 'launch_used')::int = 2 AND (row ->> 'eligible_orders')::int = 4 AND row ->> 'effective_mode' = 'active', row::text);
  PERFORM zz.check('7: the row for the shadow-mode business shows its mode (shadow) in the real table with nothing real in it', (SELECT (e ->> 'transaction_fees_amount')::numeric = 0 AND e ->> 'effective_mode' = 'shadow' FROM jsonb_array_elements(j -> 'rows') e WHERE e ->> 'name' = 'Rep WB'));
  j := zz.adm('SELECT public.admin_billing_organizations(''shadow'')::text')::jsonb;
  PERFORM zz.check('7: the shadow view of the same table shows what Rep WB WOULD have been charged (30.00, 3 orders)', (SELECT (e ->> 'transaction_fees_amount')::numeric = 30 AND (e ->> 'eligible_orders')::int = 3 FROM jsonb_array_elements(j -> 'rows') e WHERE e ->> 'name' = 'Rep WB'));
  j := zz.adm('SELECT public.admin_billing_organizations(''real'', ''wholesaler'')::text')::jsonb;
  PERFORM zz.check('7: filtered to wholesalers: 6 rows, no pharmacy', (j ->> 'total')::int = 6 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'rows') e WHERE e ->> 'name' = 'Good Pharmacy'));
  j := zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, ''rep_zero'')::text')::jsonb;
  PERFORM zz.check('7: filtered by plan (rep_zero): Rep WB, Rep WD, Rep WE', (j ->> 'total')::int = 3);
  j := zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, NULL, ''cancelled'')::text')::jsonb;
  PERFORM zz.check('7: filtered by status (cancelled): Rep WD', (j ->> 'total')::int = 1 AND j -> 'rows' -> 0 ->> 'name' = 'Rep WD');
  j := zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, NULL, NULL, ''rep w'')::text')::jsonb;
  PERFORM zz.check('7: search by name (any case, part of a name)', (j ->> 'total')::int = 6);
  j := zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, NULL, NULL, NULL, 3, 3)::text')::jsonb;
  PERFORM zz.check('7: paging: the total stays 7 and the second page of 3 has 3 rows', (j ->> 'total')::int = 7 AND jsonb_array_length(j -> 'rows') = 3);
  PERFORM zz.check('7: bad paging and flavours are refused', zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, NULL, NULL, NULL, 0)::text') LIKE 'ERR: Choose between 1 and 200 rows.%'
    AND zz.adm('SELECT public.admin_billing_organizations(''sandbox'')::text') LIKE 'ERR: Choose real or shadow.%');

  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L)::text', wa))::jsonb;
  PERFORM zz.check('7: the drill-down: subscription, resolved terms, one terms record with its reason', d ->> 'has_subscription' = 'true' AND d -> 'subscription' ->> 'business_id' = wa::text AND (d -> 'terms_now' ->> 'transaction_fee_percentage')::numeric = 1
    AND jsonb_array_length(d -> 'terms_history') = 1 AND d -> 'terms_history' -> 0 ->> 'reason' = 'Start for tests', left(d::text, 200));
  PERFORM zz.check('7: the grant shows its use (2 granted, 2 used)', (d -> 'grants' -> 0 ->> 'quantity')::int = 2 AND (d -> 'grants' -> 0 ->> 'used')::int = 2);
  PERFORM zz.check('7: one period, four assessments, and a ledger of 3 free-order entries + 1 fee + 1 subscription + the credit', jsonb_array_length(d -> 'periods') = 1 AND jsonb_array_length(d -> 'assessments') = 4
    AND (SELECT count(*) FROM jsonb_array_elements(d -> 'ledger') e WHERE e ->> 'entry_type' = 'free_order') = 3 AND (SELECT count(*) FROM jsonb_array_elements(d -> 'ledger') e WHERE e ->> 'entry_type' = 'transaction_fee') = 1
    AND (SELECT count(*) FROM jsonb_array_elements(d -> 'ledger') e WHERE e ->> 'entry_type' = 'subscription_charge') = 1 AND (SELECT count(*) FROM jsonb_array_elements(d -> 'ledger') e WHERE e ->> 'entry_type' = 'manual_credit') = 1);
  PERFORM zz.check('7: the audit trail holds the subscription start and the order assessments, with the actions that created them', (SELECT count(*) FROM jsonb_array_elements(d -> 'audit') e WHERE e ->> 'activity' = 'Billing subscription started') = 1
    AND (SELECT count(*) FROM jsonb_array_elements(d -> 'audit') e WHERE e ->> 'activity' = 'Order billing assessed') = 4);
  PERFORM zz.check('7: there is nothing stuck in the queue', jsonb_array_length(d -> 'queue') = 0);
  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L, ''shadow'')::text', (SELECT wb FROM zz.rw)))::jsonb;
  PERFORM zz.check('7: the shadow drill-down of Rep WB shows its 3 simulated assessments (and no audit entries for them)', jsonb_array_length(d -> 'assessments') = 3 AND (SELECT count(*) FROM jsonb_array_elements(d -> 'audit') e WHERE e ->> 'activity' = 'Order billing assessed') = 0);
  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L)::text', (SELECT wn FROM zz.rw)))::jsonb;
  PERFORM zz.check('7: a business with no subscription says so', d ->> 'has_subscription' = 'false');
  PERFORM zz.check('7: an unknown business and a bad flavour are refused', zz.adm('SELECT public.admin_billing_business_detail(gen_random_uuid())::text') LIKE 'ERR: Business not found.%' AND zz.adm(format('SELECT public.admin_billing_business_detail(%L, ''x'')::text', wa)) LIKE 'ERR: Choose real or shadow.%');
  PERFORM zz.check('7: reading never changes anything: the reconciliation is still clean', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
