-- Platform billing, Phase 6: going live and the unpaid-invoice path. The activation checklist (readiness, confirmation, hold-back), going live one business at a time (real billing never looks back:
-- first real period at the go-live moment, trial restarts, shadow history kept, earlier orders never assessed), account status for overdue invoices (past due, grace, suspended, restored), the
-- optional order restriction, the notices (once per event, to the right people), the settings, monitoring, and who may do what. Run after setup.sql + migrations (through 20261206110000_platform_billing_rollout.sql).
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

-- Setup: a platform that has run in SHADOW for three months -------------------------------------------------------------------------------------------------------------------------------------
UPDATE public.billing_settings SET mode = 'shadow';
SELECT zz.mkplan('rl_trial', '{"subscription_amount":100,"free_trial_days":30,"onboarding_free_orders":2,"monthly_free_orders":1,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":50}'::jsonb);
SELECT zz.mkplan('rl_ws', '{"subscription_amount":100,"free_trial_days":0,"onboarding_free_orders":0,"monthly_free_orders":0,"transaction_fee_percentage":1}'::jsonb);
DO $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm('SELECT public.admin_billing_create_plan(''rl_pharm'', ''pharmacy'', ''Pharmacy plan'', NULL, ''standard'', ''Plan for tests'')::text')::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":50}''::jsonb, ''Terms for tests'')::text', pid));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Switch on for tests'')::text', pid));
END $$;
CREATE TABLE zz.w AS SELECT zz.mkws('Rl R1') r1, zz.mkws('Rl R2') r2, zz.mkws('Rl R3') r3, zz.mkws('Rl R4') r4, zz.mkws('Rl R5') r5;
SELECT zz.sub((SELECT r1 FROM zz.w), 'rl_trial', now() - interval '90 days');
SELECT zz.sub((SELECT r2 FROM zz.w), 'rl_ws', now() - interval '90 days');
SELECT zz.sub((SELECT r3 FROM zz.w), 'rl_ws', now() - interval '90 days');
SELECT zz.sub((SELECT r4 FROM zz.w), 'rl_ws', now() - interval '90 days');
SELECT zz.sub((SELECT r5 FROM zz.w), 'rl_ws', now() - interval '90 days');
SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rl_pharm'', %L, NULL, ''Start for tests'')::text', (SELECT good FROM zz.bx), now() - interval '90 days'));
CREATE TABLE zz.users AS SELECT zz.owner((SELECT r1 FROM zz.w)) r1_owner, zz.owner((SELECT r4 FROM zz.w)) r4_owner, (SELECT id FROM zz.u WHERE k = 'admin') adm;
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a1', 'rlmgr@zz.test', '{"full_name":"Rl Manager","phone":"+233241000071"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a2', 'rlcash@zz.test', '{"full_name":"Rl Cashier","phone":"+233241000072"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a3', 'rlfin@zz.test', '{"full_name":"Rl Finance","phone":"+233241000073"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT r4 FROM zz.w), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES ('30000000-0000-0000-0000-0000000000a1'::uuid, 'manager'), ('30000000-0000-0000-0000-0000000000a2'::uuid, 'cashier'), ('30000000-0000-0000-0000-0000000000a3'::uuid, 'finance')) v(uid, r);
CREATE TABLE zz.o (k TEXT PRIMARY KEY, id UUID);
-- three months of shadow history for R1 (orders delivered before anything goes live)
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); i INT; v UUID;
BEGIN
  FOR i IN 1..4 LOOP v := zz.go(r1, 1000, 25, now() - interval '60 days' + make_interval(days => i)); INSERT INTO zz.o VALUES ('r1_old' || i, v); END LOOP;
  PERFORM public.billing_open_periods(now());
END $$;

-- 1. Who may use the rollout controls ----------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); o UUID := (SELECT r1_owner FROM zz.users); f TEXT; calls TEXT[];
BEGIN
  calls := ARRAY[
    'SELECT public.admin_billing_readiness()::text', 'SELECT public.admin_billing_rollout_status()::text',
    'SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''Allowed to activate'')::text',
    format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Allowed to go live'')::text', r1),
    'SELECT public.admin_billing_set_grace_days(10, ''Allowed to set grace'')::text',
    'SELECT public.admin_billing_set_enforcement(''none'', ''Allowed to set policy'')::text',
    'SELECT public.admin_billing_set_notification_settings(''{"suspended": true}''::jsonb, ''Allowed to set notices'')::text',
    format('SELECT public.admin_billing_extend_grace(%L, now() + interval ''5 days'', ''Allowed to extend'')::text', r1)];
  FOREACH f IN ARRAY calls LOOP
    PERFORM zz.check('1: the business''s own owner cannot: ' || left(f, 55), zz.val_as(o, f) LIKE 'ERR: Only platform administrators%', left(zz.val_as(o, f), 100));
    PERFORM zz.check('1: a visitor cannot: ' || left(f, 55), zz.anon(f) LIKE 'ERR: permission denied%', left(zz.anon(f), 100));
  END LOOP;
  PERFORM zz.check('1: nothing changed by those refusals: billing is still in shadow, nobody is live', (SELECT mode FROM public.billing_settings) = 'shadow' AND (SELECT live_since IS NULL AND enforcement = 'none' AND grace_days = 7 FROM public.billing_settings)
    AND NOT EXISTS (SELECT 1 FROM public.billing_subscriptions WHERE activated_at IS NOT NULL));
END $$;

-- 2. The activation checklist -----------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; r TEXT;
BEGIN
  PERFORM zz.check('2: the plain mode switch refuses ACTIVE and points to the checklist', zz.adm('SELECT public.admin_billing_set_mode(''active'', ''Go live now'')') LIKE 'ERR: Active billing is switched on through the activation checklist%');
  j := zz.adm('SELECT public.admin_billing_readiness()::text')::jsonb;
  PERFORM zz.check('2: not ready yet: the scheduled run has never run and the invoices say nothing about how to pay', NOT (j ->> 'ready')::boolean
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'checks') c WHERE c ->> 'key' = 'scheduler' AND NOT (c ->> 'ok')::boolean AND (c ->> 'blocking')::boolean)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'checks') c WHERE c ->> 'key' = 'issuer' AND NOT (c ->> 'ok')::boolean), left(j::text, 300));
  r := zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''Trying too early'')::text');
  PERFORM zz.check('2: activating is refused while a blocking item fails, naming it', r LIKE 'ERR: Billing is not ready to go live:%scheduled billing run%' AND r LIKE '%how to pay%', r);
  PERFORM zz.check('2: nothing was switched on by the refusal', (SELECT mode FROM public.billing_settings) = 'shadow' AND (SELECT live_since IS NULL FROM public.billing_settings));
  PERFORM public.billing_run_scheduled(now());
  PERFORM zz.adm('SELECT public.admin_billing_set_invoice_settings(14, 24, ''{"name":"DrugXOne Ltd","payment_instructions":"Pay by bank transfer or mobile money and quote the invoice number."}''::jsonb, ''Launch payment details'')::text');
  j := zz.adm('SELECT public.admin_billing_readiness()::text')::jsonb;
  PERFORM zz.check('2: after a scheduled run and the invoice details, every blocking item passes', (j ->> 'ready')::boolean, left(j::text, 400));
  PERFORM zz.check('2: shadow history is shown: businesses, orders assessed, the estimated revenue, and the days it goes back; and the advice item (14 days) is only advice', (j -> 'shadow' ->> 'orders_assessed')::int = 4 AND (j -> 'shadow' ->> 'estimated_revenue')::numeric > 0
    AND (j -> 'shadow' ->> 'businesses')::int >= 1 AND EXISTS (SELECT 1 FROM jsonb_array_elements(j -> 'checks') c WHERE c ->> 'key' = 'shadow_history' AND NOT (c ->> 'blocking')::boolean), (j -> 'shadow')::text);
  PERFORM zz.check('2: the confirmation must be typed exactly', zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''activate billing'', ''Wrong case'')::text') LIKE 'ERR: Type ACTIVATE BILLING exactly%'
    AND zz.adm('SELECT public.admin_billing_activate_platform(TRUE, '''', ''No confirmation'')::text') LIKE 'ERR: Type ACTIVATE BILLING exactly%');
  PERFORM zz.check('2: and a reason is required', zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''no'')::text') LIKE 'ERR: A reason of at least 5 characters%');
  PERFORM zz.check('2: the checklist''s data is read-only: asking changes nothing', (SELECT mode FROM public.billing_settings) = 'shadow');
END $$;

-- 3. Switching real billing on, holding every business back ----------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; n_real_periods INT; n_real_assess INT; v UUID; r1 UUID := (SELECT r1 FROM zz.w);
BEGIN
  j := zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''Launch approved by management'')::text')::jsonb;
  PERFORM zz.check('3: the platform is active; all 6 subscribed businesses are held back in shadow and none is live', j ->> 'mode' = 'active' AND (j ->> 'held_back')::int = 6 AND (j ->> 'live')::int = 0
    AND (SELECT count(*) FROM public.billing_subscriptions WHERE billing_mode = 'shadow' AND activated_at IS NULL) = 6, j::text);
  PERFORM zz.check('3: the moment real billing was switched on is recorded, once', (SELECT live_since IS NOT NULL AND mode = 'active' FROM public.billing_settings));
  PERFORM zz.check('3: asking again is refused', zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''Twice over'')::text') LIKE 'ERR: Real billing is already switched on%');
  PERFORM zz.check('3: held back means each business is still in SHADOW (effective mode shadow)', public.billing_effective_mode(r1) = 'shadow' AND public.billing_effective_mode((SELECT r4 FROM zz.w)) = 'shadow');
  v := zz.go(r1, 1000, 25, clock_timestamp());
  INSERT INTO zz.o VALUES ('r1_held', v);
  PERFORM zz.check('3: an order delivered now is still assessed in the shadow world, and nothing real is created', EXISTS (SELECT 1 FROM public.order_billing_assessments WHERE order_id = v AND shadow) AND NOT EXISTS (SELECT 1 FROM public.order_billing_assessments WHERE order_id = v AND NOT shadow));
  PERFORM public.billing_run_scheduled(now());
  SELECT count(*) INTO n_real_periods FROM public.billing_periods WHERE NOT shadow;
  PERFORM zz.check('3: the scheduled run opens no real period and issues no invoice for any held-back business', n_real_periods = 0 AND (SELECT count(*) FROM public.billing_invoices) = 0);
  PERFORM zz.check('3: it is audited with the reason and what was held back', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing activated' AND performed_by IS NOT NULL AND details ->> 'reason' = 'Launch approved by management' AND (details ->> 'businesses_held_back')::int = 6));
END $$;

-- 4. Going live, one business ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); r2 UUID := (SELECT r2 FROM zz.w); r3 UUID := (SELECT r3 FROM zz.w); j JSONB; s public.billing_subscriptions; n_shadow_before INT; p public.billing_periods; v UUID;
BEGIN
  SELECT count(*) INTO n_shadow_before FROM public.billing_periods WHERE business_id = r1 AND shadow;
  PERFORM zz.check('4: R1 has three months of shadow periods and no real one', n_shadow_before >= 3 AND NOT EXISTS (SELECT 1 FROM public.billing_periods WHERE business_id = r1 AND NOT shadow), n_shadow_before::text);
  PERFORM zz.check('4: a start in the past is refused (no historical order is ever charged)', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, now() - interval ''3 days'', ''Back in time'')::text', r1)) LIKE 'ERR: Real billing cannot start in the past%');
  PERFORM zz.check('4: more than 90 days ahead is refused', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, now() + interval ''120 days'', ''Far ahead'')::text', r1)) LIKE 'ERR: Real billing cannot be scheduled more than 90 days ahead%');
  PERFORM zz.check('4: a reason is required', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''no'')::text', r1)) LIKE 'ERR: A reason of at least 5 characters%');
  j := zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Pilot group, first business'')::text', r1))::jsonb;
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = r1;
  PERFORM zz.check('4: R1 is live: activated now, following the platform, with the billing cycle re-anchored at that moment', s.activated_at IS NOT NULL AND s.billing_mode IS NULL AND s.period_anchor_at = s.activated_at AND (j ->> 're_anchored')::boolean, j::text);
  PERFORM zz.check('4: its free trial restarts: 30 days from the moment it went live, and it is trialing again', s.trial_start = s.activated_at AND s.trial_end = s.activated_at + interval '30 days' AND s.status = 'trialing', s::text);
  PERFORM zz.check('4: its original start date is untouched (history), and effective mode is now ACTIVE', s.billing_starts_at < now() - interval '80 days' AND public.billing_effective_mode(r1) = 'active');
  PERFORM zz.check('4: going live twice is refused', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Again'')::text', r1)) LIKE 'ERR: Real billing has already started for this business%');
  PERFORM public.billing_open_periods(now() + interval '1 hour');
  PERFORM zz.check('4: exactly ONE real period opens, starting at the moment it went live (not three months of back periods)', (SELECT count(*) FROM public.billing_periods WHERE business_id = r1 AND NOT shadow) = 1
    AND (SELECT period_start FROM public.billing_periods WHERE business_id = r1 AND NOT shadow) = s.activated_at);
  SELECT * INTO p FROM public.billing_periods WHERE business_id = r1 AND NOT shadow;
  PERFORM zz.check('4: the subscription is not charged while the restarted trial lasts', p.subscription_amount = 0, p::text);
  PERFORM zz.check('4: the shadow history is kept as it was', (SELECT count(*) FROM public.billing_periods WHERE business_id = r1 AND shadow) = n_shadow_before);
  PERFORM zz.check('4: the orders delivered in the shadow months are never assessed for real, now or by catching up', NOT EXISTS (SELECT 1 FROM public.order_billing_assessments WHERE business_id = r1 AND NOT shadow)
    AND NOT EXISTS (SELECT 1 FROM public._billing_unassessed_orders() u WHERE u.order_id IN (SELECT id FROM zz.o WHERE k LIKE 'r1_%')) AND (public.billing_catch_up(100) ->> 'done') = '0');
  v := zz.go(r1, 1000, 25, clock_timestamp());
  INSERT INTO zz.o VALUES ('r1_live1', v);
  PERFORM zz.check('4: an order delivered now is a REAL order: one of the 2 launch free orders (the shadow world used its own)', zz.a(v) = 'free_onboarding/onboarding1/0.00' AND NOT EXISTS (SELECT 1 FROM public.order_billing_assessments WHERE order_id = v AND shadow), zz.a(v));
  -- another business is scheduled to go live in two days
  j := zz.adm(format('SELECT public.admin_billing_go_live_business(%L, now() + interval ''2 days'', ''Second pilot business, in two days'')::text', r2))::jsonb;
  PERFORM public.billing_open_periods(now());
  v := zz.go(r2, 1000, 25, clock_timestamp());
  PERFORM zz.check('4: before its go-live moment R2 is "not started": no real period, and an order delivered now creates no real assessment at all', (zz.val_as(zz.owner(r2), format('SELECT public.billing_my_overview(%L)::text', r2))::jsonb ->> 'state') = 'not_started'
    AND NOT EXISTS (SELECT 1 FROM public.billing_periods WHERE business_id = r2 AND NOT shadow) AND NOT EXISTS (SELECT 1 FROM public.order_billing_assessments WHERE order_id = v AND NOT shadow), (zz.val_as(zz.owner(r2), format('SELECT public.billing_my_overview(%L)::text', r2))::jsonb ->> 'state'));
  UPDATE public.billing_subscriptions SET billing_mode = 'disabled' WHERE business_id = r3;
  PERFORM zz.check('4: a business whose billing is switched off cannot go live until it follows the platform', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Switched off'')::text', r3)) LIKE 'ERR: Billing is switched off for this business%');
  UPDATE public.billing_subscriptions SET billing_mode = 'shadow' WHERE business_id = r3;
  UPDATE public.billing_subscriptions SET status = 'cancelled', ended_at = now() - interval '1 day', cancelled_at = now() - interval '1 day' WHERE business_id = (SELECT r5 FROM zz.w);
  PERFORM zz.check('4: an ended subscription cannot go live', zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Ended already'')::text', (SELECT r5 FROM zz.w))) LIKE 'ERR: This subscription has ended%');
  PERFORM zz.check('4: going live is audited', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing business went live' AND business_id = r1 AND performed_by IS NOT NULL AND details ->> 'reason' = 'Pilot group, first business'));
END $$;

-- 4b. What the business sees (a fresh transaction, so "now" is after the go-live moment)
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); d JSONB;
BEGIN
  d := zz.val_as((SELECT r1_owner FROM zz.users), format('SELECT public.billing_my_overview(%L)::text', r1))::jsonb;
  PERFORM zz.check('4: the business sees itself as trialing, with its activation date and no restriction', d ->> 'state' = 'trialing' AND d -> 'subscription' ->> 'activated_at' IS NOT NULL AND d ->> 'restriction' = 'none', left(d::text, 200));
END $$;

-- 5. New subscriptions once billing is live, and the way back ---------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r6 UUID; r7 UUID; r3 UUID := (SELECT r3 FROM zz.w); r1 UUID := (SELECT r1 FROM zz.w); j JSONB; s public.billing_subscriptions;
BEGIN
  r6 := zz.mkws('Rl R6'); r7 := zz.mkws('Rl R7');
  PERFORM zz.check('5: a new subscription cannot start in the past once real billing is live', zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rl_ws'', now() - interval ''20 days'', NULL, ''A back-dated start'')::text', r6)) LIKE 'ERR: Real billing is running, so a subscription cannot start in the past%');
  PERFORM zz.check('5: but it can start in the past in shadow (held back), and then goes live like any other', zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rl_ws'', now() - interval ''20 days'', ''shadow'', ''Back-dated, held back'')::text', r6)) NOT LIKE 'ERR:%');
  j := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rl_ws'', NULL, NULL, ''Onboarded after launch'')::text', r7))::jsonb;
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = r7;
  PERFORM zz.check('5: a new subscription that follows the platform is live from its start (no waiting, no looking back)', s.activated_at IS NOT NULL AND s.activated_at = s.billing_starts_at AND public.billing_effective_mode(r7) = 'active', s::text);
  PERFORM zz.check('5: the platform cannot go back to shadow once a business is live', zz.adm('SELECT public.admin_billing_set_mode(''shadow'', ''Going back'')') LIKE 'ERR: Real billing has already started for some businesses%');
  PERFORM zz.check('5: nor can a live business', zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, ''shadow'', ''Going back'')::text', r1)) LIKE 'ERR: Real billing has already started for this business%');
  PERFORM zz.check('5: a business that is not live yet can still be held in shadow', zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, ''shadow'', ''Still held back'')::text', r3)) NOT LIKE 'ERR:%');
  PERFORM zz.adm('SELECT public.admin_billing_set_mode(''disabled'', ''Emergency stop for the test'')');
  PERFORM zz.check('5: the platform can be switched off: the scheduled run then does nothing', public.billing_run_scheduled(now()) ->> 'skipped' = 'disabled' AND public.billing_effective_mode(r1) = 'disabled');
  PERFORM zz.check('5: switching it back on is not possible except through the checklist', zz.adm('SELECT public.admin_billing_set_mode(''active'', ''Straight back on'')') LIKE 'ERR: Active billing is switched on through the activation checklist%');
  j := zz.adm('SELECT public.admin_billing_activate_platform(TRUE, ''ACTIVATE BILLING'', ''Switched back on after the stop'')::text')::jsonb;
  PERFORM zz.check('5: switching back on goes through the checklist; businesses already live stay live (R1, R2, R7) and the others stay held back', j ->> 'mode' = 'active' AND (j ->> 'live')::int = 0
    AND (SELECT count(*) FROM public.billing_subscriptions WHERE activated_at IS NOT NULL) = 3 AND public.billing_effective_mode(r1) = 'active', j::text);
END $$;

-- 6a. R4 goes live; it will get an invoice that is not paid -------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); j JSONB; per public.billing_periods; v UUID;
BEGIN
  PERFORM zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, NULL, ''Follow the platform'')::text', r4));
  j := zz.adm(format('SELECT public.admin_billing_go_live_business(%L, NULL, ''Second pilot: the unpaid-invoice test'')::text', r4))::jsonb;
  PERFORM zz.check('6: R4 goes live (a plan with no trial: active at once)', j ->> 'status' = 'active', j::text);
  v := zz.mkorder(r4, 800, 0, clock_timestamp());
  INSERT INTO zz.o VALUES ('r4_pending', v);
  PERFORM public.billing_open_periods(now() + interval '1 hour');
  SELECT * INTO per FROM public.billing_periods WHERE business_id = r4 AND NOT shadow;
  CREATE TABLE zz.tt AS SELECT per.period_end + interval '2 days' AS t0;
  PERFORM zz.check('6: its first real period holds the 100.00 subscription', per.subscription_amount = 100 AND per.amount_due = 100, per::text);
END $$;

-- 7b. Trial warnings, the last free order, and switching a notice off -----------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); r7 UUID := (SELECT id FROM public.businesses WHERE name = 'Rl R7'); o1 UUID := (SELECT r1_owner FROM zz.users); te TIMESTAMPTZ; v UUID; n INT; j JSONB; o7 UUID;
BEGIN
  SELECT trial_end INTO te FROM public.billing_subscriptions WHERE business_id = r1;
  PERFORM public.billing_send_notifications(te - interval '10 days');
  PERFORM zz.check('7: ten days before the trial ends nothing is sent (the first warning is at 7)', NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'trial_ending'));
  PERFORM public.billing_send_notifications(te - interval '5 days');
  PERFORM zz.check('7: five days before, the 7-day warning is sent', (SELECT count(*) FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'trial_ending') = 1);
  PERFORM public.billing_send_notifications(te - interval '4 days');
  PERFORM zz.check('7: the next day nothing more', (SELECT count(*) FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'trial_ending') = 1);
  PERFORM public.billing_send_notifications(te - interval '12 hours');
  PERFORM zz.check('7: the last day, the 1-day warning is sent', (SELECT count(*) FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'trial_ending') = 2);
  v := zz.go(r1, 1000, 25, clock_timestamp());
  PERFORM public.billing_send_notifications(now());
  PERFORM zz.check('7: after its last launch free order R1 is told they are used up', (SELECT count(*) FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'free_orders_low' AND title = 'Your free orders are used up') = 1);
  PERFORM zz.adm(format('SELECT public.admin_billing_extend_trial(%L, %L, ''Extended for the pilot group'')::text', r1, te + interval '40 days'));
  PERFORM public.billing_send_notifications(te + interval '40 days' - interval '5 days');
  PERFORM zz.check('7: an extended trial warns again (the warnings are tied to the end date)', (SELECT count(*) FROM public.notifications WHERE user_id = o1 AND metadata ->> 'billing_event' = 'trial_ending') = 3);
  -- switching a notice off: the event is recorded, nobody is told, and turning it back on does not send a backlog
  PERFORM zz.adm('SELECT public.admin_billing_set_notification_settings(''{"restored": false}''::jsonb, ''Pause the restored notice for the test'')::text');
  o7 := zz.owner(r7);
  UPDATE public.billing_subscriptions SET status = 'past_due', grace_until = now() + interval '3 days', past_due_since = now() WHERE business_id = r7;
  PERFORM public.billing_advance_enforcement(now() + interval '1 hour');
  PERFORM zz.check('7: a restored account is not announced while that notice is off, but the event is recorded', (SELECT status FROM public.billing_subscriptions WHERE business_id = r7) = 'active'
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = o7 AND metadata ->> 'billing_event' = 'restored') AND EXISTS (SELECT 1 FROM public.billing_notifications_sent WHERE business_id = r7 AND event_type = 'restored' AND recipients = 0));
  PERFORM zz.adm('SELECT public.admin_billing_set_notification_settings(''{"restored": true}''::jsonb, ''Turn it back on'')::text');
  PERFORM public.billing_send_notifications(now() + interval '1 hour');
  PERFORM zz.check('7: turning it back on sends no backlog', NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = o7 AND metadata ->> 'billing_event' = 'restored'));
END $$;
-- 6b. The invoice is issued, goes overdue, and the account becomes past due --------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); t0 TIMESTAMPTZ := (SELECT t0 FROM zz.tt); j JSONB; s public.billing_subscriptions; inv public.billing_invoices; own UUID := (SELECT r4_owner FROM zz.users);
BEGIN
  j := public.billing_issue_invoices(t0);
  SELECT * INTO inv FROM public.billing_invoices WHERE business_id = r4;
  PERFORM zz.check('6: the invoice is issued (100.00, due 14 days later)', inv.total_amount = 100 AND inv.due_at = t0 + interval '14 days', inv::text);
  PERFORM zz.check('6: before the due date the account is untouched by enforcement', public.billing_advance_enforcement(t0 + interval '10 days') ->> 'status_changes' = '0' AND (SELECT status FROM public.billing_subscriptions WHERE business_id = r4) = 'active');
  PERFORM public.billing_mark_overdue(t0 + interval '15 days');
  j := public.billing_advance_enforcement(t0 + interval '15 days');
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = r4;
  PERFORM zz.check('6: one day past the due date the account is past due; the clock started at the due date, with 7 days of grace', s.status = 'past_due' AND s.grace_until = inv.due_at + interval '7 days' AND s.past_due_since = inv.due_at, s::text);
  PERFORM zz.check('6: running it again changes nothing', public.billing_advance_enforcement(t0 + interval '15 days') ->> 'status_changes' = '0');
  PERFORM zz.check('6: policy "none" means no restriction at all, whatever the status', public.billing_restriction_level(r4) = 'none');
  PERFORM zz.check('6: the business sees "past due" and the date its grace ends; no restriction', (zz.val_as(own, format('SELECT public.billing_my_overview(%L)::text', r4))::jsonb ->> 'state') = 'past_due'
    AND (zz.val_as(own, format('SELECT public.billing_my_overview(%L)::text', r4))::jsonb -> 'subscription' ->> 'grace_until') IS NOT NULL AND (zz.val_as(own, format('SELECT public.billing_my_overview(%L)::text', r4))::jsonb ->> 'restriction') = 'none');
  PERFORM zz.check('6: the status change is audited (no person: it is automatic)', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing account past due' AND business_id = r4 AND performed_by IS NULL AND details ->> 'new' = 'past_due'));
END $$;

-- 7a. The first notices -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); r1 UUID := (SELECT r1 FROM zz.w); t0 TIMESTAMPTZ := (SELECT t0 FROM zz.tt); own UUID := (SELECT r4_owner FROM zz.users); j JSONB; n INT;
  mgr UUID := '30000000-0000-0000-0000-0000000000a1'; cash UUID := '30000000-0000-0000-0000-0000000000a2'; fin UUID := '30000000-0000-0000-0000-0000000000a3'; adm UUID := (SELECT adm FROM zz.users);
BEGIN
  j := public.billing_send_notifications(t0 + interval '15 days');
  PERFORM zz.check('7: notices went out', (j ->> 'notices_sent')::int > 0, j::text);
  PERFORM zz.check('7: R4''s owner, manager and finance user were told the invoice was ready and then that it is overdue', (SELECT count(*) FROM public.notifications WHERE user_id IN (own, mgr, fin) AND metadata ->> 'billing_event' = 'invoice_issued') = 3
    AND (SELECT count(*) FROM public.notifications WHERE user_id IN (own, mgr, fin) AND metadata ->> 'billing_event' = 'invoice_overdue') = 3);
  PERFORM zz.check('7: its cashier was told nothing', NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = cash AND type = 'billing'));
  PERFORM zz.check('7: the notice says what and how much, in plain words', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'invoice_issued' AND body LIKE 'Invoice DXB-%for GHS 100.00 is ready and due on %')
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'invoice_overdue' AND body LIKE '%GHS 100.00 still to pay%') AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'billing' AND body ~* 'ledger|assessment|shadow|rpc'));
  PERFORM zz.check('7: it links to the Billing tab', (SELECT link FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'invoice_overdue') = '/wholesaler?tab=billing');
  PERFORM zz.check('7: the administrators are told about the overdue invoice, once', (SELECT count(*) FROM public.notifications WHERE user_id = adm AND metadata ->> 'event_key' LIKE 'admin-overdue:%') >= 1 AND (SELECT link FROM public.notifications WHERE user_id = adm AND metadata ->> 'event_key' LIKE 'admin-overdue:%' LIMIT 1) = '/admin/billing');
  PERFORM zz.check('7: R1 (2 launch free orders, 1 used) is told it has one left', (SELECT count(*) FROM public.notifications WHERE user_id = (SELECT r1_owner FROM zz.users) AND metadata ->> 'billing_event' = 'free_orders_low' AND title = 'Your free orders are almost used up') = 1);
  n := (SELECT count(*) FROM public.notifications WHERE type = 'billing');
  j := public.billing_send_notifications(t0 + interval '15 days');
  PERFORM zz.check('7: sending again sends nothing new (each event once)', (j ->> 'notices_sent')::int = 0 AND (SELECT count(*) FROM public.notifications WHERE type = 'billing') = n, j::text);
  PERFORM zz.check('7: a business held back in shadow is told nothing', NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = zz.owner((SELECT r3 FROM zz.w)) AND type = 'billing'));
  j := public.billing_send_notifications(t0 + interval '19 days');
  PERFORM zz.check('7: three days before its grace ends (day 21) R4 is warned', (SELECT count(*) FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'grace_ending') = 1);
END $$;

-- 6c. An administrator grants more grace ----------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); t0 TIMESTAMPTZ := (SELECT t0 FROM zz.tt); j JSONB; s public.billing_subscriptions; r1 UUID := (SELECT r1 FROM zz.w);
BEGIN
  PERFORM zz.check('6: grace cannot be extended for a business with nothing overdue', zz.adm(format('SELECT public.admin_billing_extend_grace(%L, now() + interval ''5 days'', ''Nothing is overdue'')::text', r1)) LIKE 'ERR: This business has no overdue invoice%');
  PERFORM zz.check('6: nor to a date that has passed, nor beyond 90 days', zz.adm(format('SELECT public.admin_billing_extend_grace(%L, now() - interval ''1 day'', ''In the past'')::text', r4)) LIKE 'ERR: Choose a date that is still ahead%'
    AND zz.adm(format('SELECT public.admin_billing_extend_grace(%L, now() + interval ''120 days'', ''Far ahead'')::text', r4)) LIKE 'ERR: Grace cannot be extended more than 90 days ahead%');
  j := zz.adm(format('SELECT public.admin_billing_extend_grace(%L, %L, ''Owner promised to pay after the next collection'')::text', r4, t0 + interval '25 days'))::jsonb;
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = r4;
  PERFORM zz.check('6: extended: the account is in its grace period until the new date', s.status = 'grace_period' AND s.grace_until = t0 + interval '25 days' AND j ->> 'status' = 'grace_period', s::text);
  PERFORM public.billing_advance_enforcement(t0 + interval '22 days');
  PERFORM zz.check('6: past the automatic grace (day 21) but inside the extension it stays in its grace period', (SELECT status FROM public.billing_subscriptions WHERE business_id = r4) = 'grace_period');
  PERFORM zz.check('6: the extension is audited with the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing grace period extended' AND business_id = r4 AND performed_by IS NOT NULL AND details ->> 'reason' = 'Owner promised to pay after the next collection'));
END $$;

-- 6d. Grace runs out: suspended, and the optional restriction ------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); r3 UUID := (SELECT r3 FROM zz.w); good UUID := (SELECT good FROM zz.bx); t0 TIMESTAMPTZ := (SELECT t0 FROM zz.tt); own UUID := (SELECT r4_owner FROM zz.users); j JSONB; v UUID; r TEXT;
  pend UUID := (SELECT id FROM zz.o WHERE k = 'r4_pending');
BEGIN
  PERFORM public.billing_advance_enforcement(t0 + interval '26 days');
  PERFORM zz.check('6: after the extension the account is suspended', (SELECT status FROM public.billing_subscriptions WHERE business_id = r4) = 'suspended');
  j := public.billing_send_notifications(t0 + interval '26 days');
  PERFORM zz.check('7: the owner is told the account is suspended, and the administrators too', (SELECT count(*) FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'suspended') = 1
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT adm FROM zz.users) AND metadata ->> 'event_key' LIKE 'admin-suspended:%'));
  PERFORM zz.check('6: with the policy off, suspended restricts nothing: new orders to and from it are still accepted', public.billing_restriction_level(r4) = 'none' AND zz.mkorder(r4, 100, 0, clock_timestamp()) IS NOT NULL);
  PERFORM zz.check('6: an unknown policy is refused', zz.adm('SELECT public.admin_billing_set_enforcement(''lock_everything'', ''Too much'')::text') LIKE 'ERR: Choose warnings only%');
  PERFORM zz.adm('SELECT public.admin_billing_set_enforcement(''block_new_orders'', ''Turn the restriction on for the test'')::text');
  PERFORM zz.check('6: with the restriction on, the suspended business is restricted', public.billing_restriction_level(r4) = 'new_orders' AND public.billing_restriction_level(r3) = 'none');
  r := zz.try(format('SELECT zz.mkorder(%L, 100, 0, clock_timestamp())::text', r4));
  PERFORM zz.check('6: a NEW order to the suspended supplier is refused, in plain words', r LIKE 'ERR: This supplier is not accepting new orders right now.%', r);
  r := zz.try(format('SELECT zz.mkorder(%L, 100, 0, clock_timestamp())::text', r3));
  PERFORM zz.check('6: orders to other suppliers are unaffected', r NOT LIKE 'ERR:%', r);
  UPDATE public.billing_subscriptions SET activated_at = now() - interval '1 hour', billing_mode = NULL, status = 'suspended' WHERE business_id = good;
  r := zz.try(format('SELECT zz.mkorder(%L, 100, 0, clock_timestamp(), NULL, %L)::text', r3, good));
  PERFORM zz.check('6: a suspended buyer cannot place a new order either, and is told why', r LIKE 'ERR: Your DrugXOne subscription is suspended because an invoice is overdue%', r);
  r := COALESCE(zz.try(format('SELECT zz.advance(%L, ''accepted'')', pend)), '');
  PERFORM zz.check('6: but an order that already exists carries on (nothing in progress is touched)', r NOT LIKE 'ERR:%' AND (SELECT status::text FROM public.orders WHERE id = pend) = 'accepted', r);
  UPDATE public.billing_subscriptions SET activated_at = NULL, billing_mode = 'shadow', status = 'active' WHERE business_id = good;
  PERFORM zz.adm('SELECT public.admin_billing_set_enforcement(''none'', ''Turn the restriction back off'')::text');
  r := zz.try(format('SELECT zz.mkorder(%L, 100, 0, clock_timestamp())::text', r4));
  PERFORM zz.check('6: switched back to warnings only, new orders are accepted again', r NOT LIKE 'ERR:%', r);
  PERFORM zz.check('6: the policy changes are audited with the previous value and the reason', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing enforcement policy changed' AND performed_by IS NOT NULL AND length(details ->> 'reason') >= 5 AND details ->> 'previous' IS NOT NULL) = 2);
END $$;

-- 6e. The invoice is paid and the account is restored ----------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r4 UUID := (SELECT r4 FROM zz.w); t0 TIMESTAMPTZ := (SELECT t0 FROM zz.tt); own UUID := (SELECT r4_owner FROM zz.users); inv UUID; j JSONB; s public.billing_subscriptions; n INT;
BEGIN
  SELECT id INTO inv FROM public.billing_invoices WHERE business_id = r4;
  j := zz.adm(format('SELECT public.admin_billing_record_payment(%L, 100, ''bank_transfer'', ''GCB-RL-1'', now() - interval ''1 hour'', NULL, ''Transfer seen on the bank statement'', NULL)::text', inv))::jsonb;
  PERFORM zz.check('6: the invoice is paid in full', j ->> 'invoice_status' = 'paid', j::text);
  PERFORM public.billing_advance_enforcement(t0 + interval '27 days');
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = r4;
  PERFORM zz.check('6: with nothing overdue the account is restored to active and the grace dates are cleared', s.status = 'active' AND s.grace_until IS NULL AND s.past_due_since IS NULL AND s.grace_extended_until IS NULL, s::text);
  PERFORM public.billing_send_notifications(t0 + interval '27 days');
  PERFORM public.billing_send_notifications(now());
  PERFORM zz.check('7: the owner is told it is restored, and told about the payment', (SELECT count(*) FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'restored') = 1
    AND (SELECT count(*) FROM public.notifications WHERE user_id = own AND metadata ->> 'billing_event' = 'payment_received' AND body LIKE 'We recorded a payment of GHS 100.00 on invoice DXB-%') = 1);
  n := (SELECT count(*) FROM public.notifications WHERE type = 'billing');
  PERFORM public.billing_advance_enforcement(t0 + interval '27 days'); PERFORM public.billing_send_notifications(t0 + interval '27 days');
  PERFORM zz.check('6: nothing more happens on the next run', (SELECT count(*) FROM public.notifications WHERE type = 'billing') = n AND public.billing_advance_enforcement(t0 + interval '27 days') ->> 'status_changes' = '0');
  PERFORM zz.check('6: the restoration is audited', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing account restored' AND business_id = r4 AND performed_by IS NULL AND details ->> 'previous' = 'suspended' AND details ->> 'new' = 'active'));
END $$;


-- 8. The settings ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; before_cfg JSONB;
BEGIN
  PERFORM zz.check('8: the grace period must be 0 to 90 days', zz.adm('SELECT public.admin_billing_set_grace_days(-1, ''Negative days'')::text') LIKE 'ERR: The grace period must be between 0 and 90 days%'
    AND zz.adm('SELECT public.admin_billing_set_grace_days(91, ''Too many days'')::text') LIKE 'ERR: The grace period must be between 0 and 90 days%' AND zz.adm('SELECT public.admin_billing_set_grace_days(NULL, ''No days given'')::text') LIKE 'ERR: The grace period must be between 0 and 90 days%');
  PERFORM zz.check('8: a reason is required', zz.adm('SELECT public.admin_billing_set_grace_days(10, ''no'')::text') LIKE 'ERR: A reason of at least 5 characters%');
  PERFORM zz.adm('SELECT public.admin_billing_set_grace_days(14, ''Longer grace for the launch months'')::text');
  PERFORM zz.check('8: set to 14 days, audited with the previous value and the reason', (SELECT grace_days FROM public.billing_settings) = 14 AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing grace period changed' AND performed_by IS NOT NULL
    AND (details ->> 'previous')::int = 7 AND (details ->> 'new')::int = 14 AND details ->> 'reason' = 'Longer grace for the launch months'));
  PERFORM zz.adm('SELECT public.admin_billing_set_grace_days(7, ''Back to a week'')::text');
  PERFORM zz.check('8: unknown notice settings, a notice that is not on/off, and bad numbers are refused', zz.adm('SELECT public.admin_billing_set_notification_settings(''{"colour": true}''::jsonb, ''Unknown setting'')::text') LIKE 'ERR: Unknown notice setting%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"suspended": "yes"}''::jsonb, ''Not a boolean'')::text') LIKE 'ERR: The notice "suspended" is either on or off%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": []}''::jsonb, ''Empty list'')::text') LIKE 'ERR: Give 1 to 4 numbers of days%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": [1,2,3,4,5]}''::jsonb, ''Too many'')::text') LIKE 'ERR: Give 1 to 4 numbers of days%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": [0]}''::jsonb, ''Zero days'')::text') LIKE 'ERR: Days before the trial ends must be whole numbers from 1 to 60%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": [61]}''::jsonb, ''Too many days'')::text') LIKE 'ERR: Days before the trial ends must be whole numbers from 1 to 60%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"grace_days_before": 31}''::jsonb, ''Too early'')::text') LIKE 'ERR: Days before the grace period ends must be a whole number from 0 to 30%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{"free_orders_threshold": 101}''::jsonb, ''Too high'')::text') LIKE 'ERR: The free-orders warning level must be a whole number from 0 to 100%'
    AND zz.adm('SELECT public.admin_billing_set_notification_settings(''{}''::jsonb, ''Nothing'')::text') LIKE 'ERR: Say what to change%');
  SELECT notifications INTO before_cfg FROM public.billing_settings;
  j := zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": [3], "grace_days_before": 5}''::jsonb, ''Warn later about trials'')::text')::jsonb;
  PERFORM zz.check('8: only the given settings change; the rest are kept', j -> 'trial_days_before' = '[3]'::jsonb AND (j ->> 'grace_days_before')::int = 5 AND (j ->> 'invoice_issued')::boolean AND (j ->> 'free_orders_threshold')::int = 1, j::text);
  PERFORM zz.check('8: it is audited with before and after', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing notification settings changed' AND performed_by IS NOT NULL AND details -> 'previous' ->> 'grace_days_before' = '3' AND details -> 'new' ->> 'grace_days_before' = '5'));
  PERFORM zz.adm('SELECT public.admin_billing_set_notification_settings(''{"trial_days_before": [7, 1], "grace_days_before": 3}''::jsonb, ''Back to the defaults'')::text');
  PERFORM zz.check('8: the defaults are back', (SELECT notifications = before_cfg FROM public.billing_settings));
END $$;

-- 9. Monitoring -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; st JSONB; runs0 BIGINT;
BEGIN
  SELECT runs INTO runs0 FROM public.billing_run_status;
  j := public.billing_run_scheduled(now());
  PERFORM zz.check('9: the scheduled run now also reports account status changes and notices', j ? 'enforcement' AND j ? 'notices' AND j ? 'invoices', left(j::text, 300));
  PERFORM zz.check('9: and records that it ran', (SELECT runs = runs0 + 1 AND last_run_at > clock_timestamp() - interval '1 minute' AND last_result ? 'enforcement' FROM public.billing_run_status));
  st := zz.adm('SELECT public.admin_billing_rollout_status()::text')::jsonb;
  PERFORM zz.check('9: the administrator''s status shows the policy, the run, the counts and the latest notices', st -> 'platform' ->> 'mode' = 'active' AND st -> 'platform' ->> 'enforcement' = 'none' AND (st -> 'platform' ->> 'grace_days')::int = 7
    AND NOT (st -> 'run' ->> 'stale')::boolean AND (st -> 'run' ->> 'minutes_since')::int <= 1 AND jsonb_array_length(st -> 'recent_notices') > 0, left(st::text, 300));
  PERFORM zz.check('9: the counts add up: 4 live (R1, R2, R4, R7), the others held back, and the overdue invoice is counted', (st -> 'counts' ->> 'live')::int = 4 AND (st -> 'counts' ->> 'held_back')::int >= 3 AND (st -> 'counts' ->> 'overdue_invoices')::int >= 1
    AND (st -> 'counts' ->> 'subscriptions')::int = (SELECT count(*) FROM public.billing_subscriptions), (st -> 'counts')::text);
END $$;
DO $$
DECLARE r1 UUID := (SELECT r1 FROM zz.w); found TEXT; act TIMESTAMPTZ; n UUID;
BEGIN
  SELECT activated_at INTO act FROM public.billing_subscriptions WHERE business_id = r1;
  PERFORM zz.check('9: the books are clean to start with', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('period_not_invoiced_when_it_should_be', 'invoice_overdue_but_not_marked')),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_run_status SET last_run_at = now() - interval '3 hours';
    UPDATE public.billing_settings SET updated_at = now() - interval '3 hours';
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('9: a billing run that has stopped for 2 hours is found', found LIKE '%billing_scheduler_not_running%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    n := zz.mkws('Rl Rx');
    INSERT INTO public.billing_subscriptions(business_id, status, billing_mode, billing_starts_at, period_anchor_at) VALUES (n, 'active', NULL, now(), now());
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('9: a business that follows live billing but was never put live is found', found LIKE '%live_business_not_activated%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_periods(business_id, subscription_id, period_start, period_end, shadow) SELECT r1, id, act - interval '2 months', act - interval '1 month', FALSE FROM public.billing_subscriptions WHERE business_id = r1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('9: a real billing period that ended before the business went live is found', found LIKE '%real_period_before_activation%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.order_billing_assessments(business_id, order_id, retailer_business_id, kind, adjustment_seq, shadow, period_id, subscription_terms_id, plan_version_id, delivered_at, currency, billable_gmv, outcome, charged_amount, terms_snapshot, rule_version)
    SELECT business_id, order_id, retailer_business_id, 'adjustment', 99, FALSE, period_id, subscription_terms_id, plan_version_id, act - interval '1 day', currency, 0, 'excluded', 0, terms_snapshot, rule_version
    FROM public.order_billing_assessments WHERE business_id = r1 AND NOT shadow AND kind = 'primary' LIMIT 1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('9: a real assessment dated before the business went live is found', found LIKE '%real_assessment_before_activation%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_subscriptions SET status = 'past_due' WHERE business_id = r1;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('9: an account marked past due with no overdue invoice is found', found LIKE '%account_status_does_not_match_invoices%', found);
  PERFORM zz.check('9: and after those undone mistakes the books are clean again', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('period_not_invoiced_when_it_should_be', 'invoice_overdue_but_not_marked')),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 10. A step that fails never stops the run; the organization table; who can call what ---------------------------------------------------------------------------------------------------------
DO $$
DECLARE j JSONB; runs0 BIGINT; org JSONB; v_ok BOOLEAN := FALSE; v_runs BIGINT; v_msg TEXT;
BEGIN
  SELECT runs INTO runs0 FROM public.billing_run_status;
  BEGIN
    CREATE OR REPLACE FUNCTION public.billing_advance_enforcement(p_now TIMESTAMPTZ DEFAULT now()) RETURNS JSONB LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'enforcement broke'; END $f$;
    CREATE OR REPLACE FUNCTION public.billing_send_notifications(p_now TIMESTAMPTZ DEFAULT now()) RETURNS JSONB LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'notices broke'; END $f$;
    BEGIN
      j := public.billing_run_scheduled(now());
    EXCEPTION WHEN OTHERS THEN
      j := jsonb_build_object('run_failed', SQLERRM);
    END;
    SELECT runs INTO v_runs FROM public.billing_run_status;
    v_ok := j ? 'invoices' AND j -> 'enforcement' = '{}'::jsonb AND j -> 'notices' = '{}'::jsonb AND v_runs = runs0 + 1;
    v_msg := left(j::text, 200);
    RAISE EXCEPTION 'undo the broken functions';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('10: when the status step and the notices step both fail, the run still finishes (periods, invoices, retries are done) and is recorded', v_ok, v_msg);
  PERFORM zz.check('10: the real functions are back after the test', public.billing_advance_enforcement(now()) ? 'status_changes' AND public.billing_send_notifications(now()) ? 'notices_sent');
  org := zz.adm('SELECT public.admin_billing_organizations(''real'', NULL, NULL, NULL, NULL, 100, 0)::text')::jsonb;
  PERFORM zz.check('10: the organization table shows when each business went live and until when its grace runs', EXISTS (SELECT 1 FROM jsonb_array_elements(org -> 'rows') r WHERE r ->> 'name' = 'Rl R1' AND r ->> 'activated_at' IS NOT NULL)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(org -> 'rows') r WHERE r ->> 'name' = 'Rl R3' AND r ->> 'activated_at' IS NULL) AND EXISTS (SELECT 1 FROM jsonb_array_elements(org -> 'rows') r WHERE r ->> 'name' = 'Rl R7' AND r ? 'grace_until'));
END $$;
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY['admin_billing_readiness()', 'admin_billing_activate_platform(boolean, text, text)', 'admin_billing_go_live_business(uuid, timestamp with time zone, text)', 'admin_billing_set_grace_days(integer, text)',
    'admin_billing_set_enforcement(text, text)', 'admin_billing_set_notification_settings(jsonb, text)', 'admin_billing_extend_grace(uuid, timestamp with time zone, text)', 'admin_billing_rollout_status()'] LOOP
    PERFORM zz.check('11: ' || split_part(f, '(', 1) || ' is not open to visitors, and checks who is asking when signed in', NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE') AND has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'));
  END LOOP;
  FOREACH f IN ARRAY ARRAY['billing_restriction_level(uuid)', 'billing_block_new_orders()', '_billing_notify_once(uuid, text, text, text, text)', '_billing_notify_admins_once(text, text, text)', '_billing_enforce_one(public.billing_subscriptions, timestamp with time zone)',
    'billing_advance_enforcement(timestamp with time zone)', 'billing_send_notifications(timestamp with time zone)', '_billing_go_live(public.billing_subscriptions, timestamp with time zone)', '_billing_reconcile_rollout()'] LOOP
    PERFORM zz.check('11: the internal ' || split_part(f, '(', 1) || ' cannot be called by a signed-in user or a visitor', NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE') AND NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'));
  END LOOP;
  PERFORM zz.check('11: the two new tables are closed to visitors and have row security on; nobody writes to them directly', NOT has_table_privilege('anon', 'public.billing_notifications_sent', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.billing_run_status', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.billing_notifications_sent', 'INSERT') AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_notifications_sent'::regclass, 'public.billing_run_status'::regclass)));
  PERFORM zz.check('11: a notice record is never deleted or rewritten (only the count of people reached is filled in)', zz.try('DELETE FROM public.billing_notifications_sent') LIKE 'ERR: Billing records are never changed or deleted%' AND zz.try('UPDATE public.billing_notifications_sent SET event_key = event_key || ''x''') LIKE 'ERR: Billing records are never changed or deleted%');
  PERFORM zz.check('11: the books agree at the end', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('period_not_invoiced_when_it_should_be', 'invoice_overdue_but_not_marked')),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;
