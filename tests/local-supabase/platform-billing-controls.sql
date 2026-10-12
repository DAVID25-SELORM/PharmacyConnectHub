-- Platform billing, Phase 5: the administrator's controls and promotions. Extending a trial, granting free orders, manual credits and charges, waiving an order's fee, exempting from fees, pausing,
-- cancelling, custom pricing, changing plan, temporary terms, promotions (create, switch, apply once per business, owner and licence, limits), the audit trail, who may use any of it,
-- and the reconciliation finding each deliberately introduced inconsistency. Run after setup.sql + migrations (through 20261205110000_platform_billing_controls.sql).
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

-- Setup -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
UPDATE public.billing_settings SET mode = 'active';
SELECT zz.mkplan('ctl_ws', '{"subscription_amount":100,"free_trial_days":0,"onboarding_free_orders":2,"monthly_free_orders":1,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":50}'::jsonb);
SELECT zz.mkplan('ctl_pro', '{"subscription_amount":200,"free_trial_days":0,"transaction_fee_percentage":0.5}'::jsonb);
SELECT zz.mkplan('ctl_trial', '{"subscription_amount":100,"free_trial_days":5,"transaction_fee_percentage":1}'::jsonb);
DO $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm('SELECT public.admin_billing_create_plan(''ctl_pharm'', ''pharmacy'', ''Pharmacy plan'', NULL, ''standard'', ''Plan for tests'')::text')::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":50}''::jsonb, ''Terms for tests'')::text', pid));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Switch on for tests'')::text', pid));
END $$;
CREATE TABLE zz.w AS SELECT zz.mkws('Ctl C1') c1, zz.mkws('Ctl C2') c2, zz.mkws('Ctl C3') c3, zz.mkws('Ctl C4') c4, zz.mkws('Ctl C5') c5, zz.mkws('Ctl C6') c6, zz.mkws('Ctl C7') c7, zz.mkws('Ctl C9') c9;
SELECT zz.sub((SELECT c1 FROM zz.w), 'ctl_ws', now() - interval '3 days');
SELECT zz.sub((SELECT c2 FROM zz.w), 'ctl_trial', now() - interval '40 days');
SELECT zz.sub((SELECT c3 FROM zz.w), 'ctl_ws', now() - interval '2 days');
SELECT zz.sub((SELECT c4 FROM zz.w), 'ctl_ws', now() - interval '2 days');
SELECT zz.sub((SELECT c5 FROM zz.w), 'ctl_ws', now() - interval '2 days');
SELECT zz.sub((SELECT c6 FROM zz.w), 'ctl_ws', now() - interval '2 days');
SELECT zz.sub((SELECT c7 FROM zz.w), 'ctl_ws', now() - interval '2 days');
SELECT zz.sub((SELECT c9 FROM zz.w), 'ctl_ws', now() - interval '2 days', 'shadow');
SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ctl_pharm'', %L, NULL, ''Start for tests'')::text', (SELECT good FROM zz.bx), now() - interval '2 days'));
CREATE TABLE zz.users AS SELECT zz.owner((SELECT c1 FROM zz.w)) c1_owner, (SELECT id FROM zz.u WHERE k = 'ph_owner') po;
SELECT public.billing_open_periods(now());
CREATE TABLE zz.o (k TEXT PRIMARY KEY, id UUID);

-- 1. Who may use the controls ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); o UUID := (SELECT c1_owner FROM zz.users); f TEXT; calls TEXT[];
BEGIN
  calls := ARRAY[
    format('SELECT public.admin_billing_extend_trial(%L, now() + interval ''60 days'', ''Allowed to extend'')::text', c1),
    format('SELECT public.admin_billing_grant_free_orders(%L, 1, NULL, ''Allowed to grant'', ''key-perm-1'')::text', c1),
    format('SELECT public.admin_billing_apply_credit(%L, 5, ''manual_credit'', ''Allowed to credit'', ''key-perm-2'')::text', c1),
    format('SELECT public.admin_billing_apply_charge(%L, 5, ''Allowed to charge'', ''key-perm-3'')::text', c1),
    format('SELECT public.admin_billing_waive_fee(%L, %L, ''Allowed to waive'')::text', c1, gen_random_uuid()),
    format('SELECT public.admin_billing_set_exemption(%L, TRUE, ''Allowed to exempt'')::text', c1),
    format('SELECT public.admin_billing_set_paused(%L, TRUE, ''Allowed to pause'')::text', c1),
    format('SELECT public.admin_billing_set_cancellation(%L, TRUE, ''Allowed to cancel'')::text', c1),
    format('SELECT public.admin_billing_set_custom_terms(%L, ''{}''::jsonb, NULL, ''Allowed to price'')::text', c1),
    format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', NULL, TRUE, ''Allowed to change'')::text', c1),
    format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.1}''::jsonb, now(), now() + interval ''1 day'', ''Allowed to add'')::text', c1),
    format('SELECT public.admin_billing_end_temporary_terms(%L, ''Allowed to end'')::text', gen_random_uuid()),
    'SELECT public.admin_billing_create_promotion(''PERM1'', ''Perm'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, NULL, NULL, NULL, ''Allowed to create'')::text',
    format('SELECT public.admin_billing_set_promotion_active(%L, FALSE, ''Allowed to switch'')::text', gen_random_uuid()),
    format('SELECT public.admin_billing_apply_promotion(%L, ''PERM1'', ''Allowed to apply'')::text', c1),
    'SELECT public.admin_billing_promotions()::text'];
  FOREACH f IN ARRAY calls LOOP
    PERFORM zz.check('1: the business''s own owner cannot: ' || left(f, 60), zz.val_as(o, f) LIKE 'ERR: Only platform administrators%', left(zz.val_as(o, f), 100));
    PERFORM zz.check('1: a visitor cannot: ' || left(f, 60), zz.anon(f) LIKE 'ERR: permission denied%', left(zz.anon(f), 100));
  END LOOP;
  PERFORM zz.check('1: nothing was changed by those refusals (no grants beyond the plan''s, no ledger entries from admins, no windows, no promotions)',
    (SELECT count(*) FROM public.billing_allowance_grants WHERE source = 'admin') = 0 AND (SELECT count(*) FROM public.billing_ledger_entries WHERE source = 'admin') = 0
    AND (SELECT count(*) FROM public.billing_term_windows) = 0 AND (SELECT count(*) FROM public.billing_promotions) = 0);
  PERFORM zz.check('1: every operation asks for a reason (at least 5 characters)', zz.adm(format('SELECT public.admin_billing_extend_trial(%L, now() + interval ''60 days'', ''no'')::text', c1)) LIKE 'ERR: A reason of at least 5 characters%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5, ''manual_credit'', ''abc'', ''key-perm-9'')::text', c1)) LIKE 'ERR: A reason of at least 5 characters%'
    AND zz.adm(format('SELECT public.admin_billing_set_exemption(%L, TRUE, '''')::text', c1)) LIKE 'ERR: A reason of at least 5 characters%');
  PERFORM zz.check('1: an unknown business has no subscription to change', zz.adm(format('SELECT public.admin_billing_set_paused(%L, TRUE, ''Unknown business'')::text', gen_random_uuid())) LIKE 'ERR: This business has no subscription%');
END $$;

-- 2. Extending a free trial ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c2 UUID := (SELECT c2 FROM zz.w); per public.billing_periods; j JSONB; n INT; before_end TIMESTAMPTZ; new_end TIMESTAMPTZ := now() + interval '20 days';
BEGIN
  PERFORM public.billing_advance_states(now());
  SELECT * INTO per FROM public.billing_periods WHERE business_id = c2 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('2: Inv-style setup: a 5-day trial that ended long ago, so the current period was charged the full 100.00 subscription', per.subscription_amount = 100 AND per.amount_due = 100
    AND (SELECT status FROM public.billing_subscriptions WHERE business_id = c2) = 'active', per::text);
  SELECT trial_end INTO before_end FROM public.billing_subscriptions WHERE business_id = c2;
  PERFORM zz.check('2: the trial cannot be moved to a moment that has already passed, nor to a date that is not later than the current end', zz.adm(format('SELECT public.admin_billing_extend_trial(%L, now() - interval ''1 day'', ''Wrong date'')::text', c2)) LIKE 'ERR: Choose a trial end date that is still ahead%'
    AND zz.adm(format('SELECT public.admin_billing_extend_trial(%L, %L, ''Not later'')::text', c2, before_end)) LIKE 'ERR: Choose a trial end date that is still ahead%');
  PERFORM zz.check('2: nor beyond 730 days from the billing start', zz.adm(format('SELECT public.admin_billing_extend_trial(%L, now() + interval ''800 days'', ''Too long'')::text', c2)) LIKE 'ERR: A trial cannot run more than 730 days%');
  j := zz.adm(format('SELECT public.admin_billing_extend_trial(%L, %L, ''Extended for the launch campaign'')::text', c2, new_end))::jsonb;
  PERFORM zz.check('2: extending to 20 days from now waives the subscription already charged to the open period (one period, 100.00)', (j ->> 'periods_waived')::int = 1 AND (j ->> 'waived_amount')::numeric = 100, j::text);
  SELECT * INTO per FROM public.billing_periods WHERE business_id = c2 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('2: that period now owes nothing: the charge is cancelled by a waiver credit with its reason, not by editing the charge', per.subscription_amount = 100 AND per.credits_amount = 100 AND per.amount_due = 0
    AND EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.period_id = per.id AND e.entry_type = 'fee_waiver' AND e.credit_amount = 100 AND e.reason = 'Free trial extended: subscription waived'), per::text);
  PERFORM zz.check('2: the subscription is trialing again, with the new end and a start date', (SELECT status = 'trialing' AND trial_end = new_end AND trial_start IS NOT NULL FROM public.billing_subscriptions WHERE business_id = c2));
  PERFORM zz.check('2: sending the same end date again is refused (nothing is waived twice)', zz.adm(format('SELECT public.admin_billing_extend_trial(%L, %L, ''Same again'')::text', c2, new_end)) LIKE 'ERR: The new end must be later%');
  j := zz.adm(format('SELECT public.admin_billing_extend_trial(%L, %L, ''Extended again a little'')::text', c2, new_end + interval '5 days'))::jsonb;
  PERFORM zz.check('2: extending a little more waives nothing more (the period was already waived)', (j ->> 'periods_waived')::int = 0 AND (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = c2 AND entry_type = 'fee_waiver') = 1, j::text);
  PERFORM zz.check('2: it is audited with the administrator, the business, the old and new end, the waived amount and the ledger entry', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing trial extended' AND business_id = c2 AND performed_by IS NOT NULL
    AND details ->> 'reason' = 'Extended for the launch campaign' AND (details ->> 'waived_amount')::numeric = 100 AND details -> 'ledger_entry_ids' ->> 0 IS NOT NULL AND details ->> 'previous_trial_end' IS NOT NULL));
  -- the next period opens already waived, because it starts inside the extended trial
  n := public.billing_open_periods(now() + interval '29 days');
  PERFORM zz.check('2: a period that opens later, inside the extended trial, is charged nothing', (SELECT subscription_amount FROM public.billing_periods WHERE business_id = c2 AND NOT shadow AND period_start > now() ORDER BY period_start LIMIT 1) = 0);
END $$;
DO $$
DECLARE c2 UUID := (SELECT c2 FROM zz.w);
BEGIN
  UPDATE public.billing_subscriptions SET status = 'suspended' WHERE business_id = c2;
  PERFORM zz.check('2: a suspended subscription''s trial cannot be extended', zz.adm(format('SELECT public.admin_billing_extend_trial(%L, now() + interval ''90 days'', ''Suspended one'')::text', c2)) LIKE 'ERR: A trial can only be extended for a subscription that is trialing or active%');
  UPDATE public.billing_subscriptions SET status = 'trialing' WHERE business_id = c2;
END $$;

-- 3. Free orders -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); j JSONB; v UUID; i INT; plan_g UUID; adm_g UUID; outs TEXT := '';
BEGIN
  PERFORM zz.check('3: a quantity from 1 to 10,000 only', zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 0, NULL, ''Zero is no grant'', ''key-g-0'')::text', c1)) LIKE 'ERR: Grant between 1 and 10,000%'
    AND zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 10001, NULL, ''Too many at once'', ''key-g-1'')::text', c1)) LIKE 'ERR: Grant between 1 and 10,000%');
  PERFORM zz.check('3: the expiry must be ahead, and a request key is required', zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 3, now() - interval ''1 day'', ''Expired already'', ''key-g-2'')::text', c1)) LIKE 'ERR: The expiry must be in the future%'
    AND zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 3, NULL, ''No key given'', ''x'')::text', c1)) LIKE 'ERR: A request key is required%');
  PERFORM zz.check('3: a pharmacy pays no transaction fee, so it gets no free orders', zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 3, NULL, ''Not for pharmacies'', ''key-g-3'')::text', ph)) LIKE 'ERR: Free orders are for wholesalers%');
  j := zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 3, NULL, ''Goodwill for the first month'', ''key-grant-1'')::text', c1))::jsonb;
  PERFORM zz.check('3: Ctl C1 (2 launch free orders with its plan) is granted 3 more', j ->> 'replayed' = 'false' AND (SELECT sum(quantity) FROM public.billing_allowance_grants WHERE business_id = c1) = 5, j::text);
  j := zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 3, NULL, ''Goodwill for the first month'', ''key-grant-1'')::text', c1))::jsonb;
  PERFORM zz.check('3: the same request sent again (a double click) grants nothing more', j ->> 'replayed' = 'true' AND (SELECT sum(quantity) FROM public.billing_allowance_grants WHERE business_id = c1) = 5, j::text);
  PERFORM zz.check('3: the same key for a different number is refused', zz.adm(format('SELECT public.admin_billing_grant_free_orders(%L, 4, NULL, ''Changed my mind'', ''key-grant-1'')::text', c1)) LIKE 'ERR: This request key was already used for a different grant%');
  FOR i IN 1..7 LOOP v := zz.go(c1, 1000, 25, clock_timestamp()); INSERT INTO zz.o VALUES ('c1_' || i, v); outs := outs || zz.a(v) || ' '; END LOOP;
  SELECT id INTO plan_g FROM public.billing_allowance_grants WHERE business_id = c1 AND source = 'plan';
  SELECT id INTO adm_g FROM public.billing_allowance_grants WHERE business_id = c1 AND source = 'admin';
  PERFORM zz.check('3: the plan''s 2 launch orders are used first (numbers 1 and 2), then the administrator''s 3 (numbers 1 to 3 of that grant)', zz.a((SELECT id FROM zz.o WHERE k = 'c1_1')) = 'free_onboarding/onboarding1/0.00' AND zz.a((SELECT id FROM zz.o WHERE k = 'c1_2')) = 'free_onboarding/onboarding2/0.00'
    AND (SELECT string_agg(free_seq::text, ',' ORDER BY free_seq) FROM public.order_billing_assessments WHERE grant_id = plan_g) = '1,2' AND (SELECT string_agg(free_seq::text, ',' ORDER BY free_seq) FROM public.order_billing_assessments WHERE grant_id = adm_g) = '1,2,3', outs);
  PERFORM zz.check('3: the 6th order uses the month''s own free order, the 7th pays 1% = GHS 10.00', zz.a((SELECT id FROM zz.o WHERE k = 'c1_6')) = 'free_monthly/monthly1/0.00' AND zz.a((SELECT id FROM zz.o WHERE k = 'c1_7')) = 'chargeable/-/10.00', outs);
  PERFORM zz.check('3: the grant is audited with the administrator, the number and the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing free orders granted' AND business_id = c1 AND performed_by IS NOT NULL AND (details ->> 'quantity')::int = 3 AND details ->> 'reason' = 'Goodwill for the first month'));
  PERFORM zz.check('3: the books agree', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 4. Credits and charges ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); c9 UUID := (SELECT c9 FROM zz.w); j JSONB; p public.billing_periods; due0 NUMERIC;
BEGIN
  SELECT * INTO p FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  due0 := p.amount_due;
  PERFORM zz.check('4: before anything: the period owes 100.00 (subscription) + 10.00 (the fee on the one charged order)', due0 = 110, p::text);
  PERFORM zz.check('4: an amount must be positive, with at most two decimals and not absurd', zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 0, ''manual_credit'', ''Zero amount'', ''key-c-zero0'')::text', c1)) LIKE 'ERR: Enter an amount of more than zero%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, -5, ''manual_credit'', ''Negative one'', ''key-c-neg00'')::text', c1)) LIKE 'ERR: Enter an amount of more than zero%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5.005, ''manual_credit'', ''Half a pesewa'', ''key-c-dec00'')::text', c1)) LIKE 'ERR: Enter an amount of more than zero%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 1000000.01, ''manual_credit'', ''Far too much'', ''key-c-big00'')::text', c1)) LIKE 'ERR: That amount is too large%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, NULL, ''manual_credit'', ''No amount given'', ''key-c-null0'')::text', c1)) LIKE 'ERR: Enter an amount of more than zero%');
  PERFORM zz.check('4: a credit is either manual or promotional; a request key is required', zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5, ''gift'', ''Unknown kind'', ''key-c-kind0'')::text', c1)) LIKE 'ERR: Choose a manual credit or a promotional credit%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5, ''manual_credit'', ''No request key'', '''')::text', c1)) LIKE 'ERR: A request key is required%');
  j := zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 20, ''manual_credit'', ''Goodwill after a late delivery'', ''key-credit-1'')::text', c1))::jsonb;
  SELECT * INTO p FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('4: a manual credit of 20.00 goes on the current bill: credits 20.00, the bill falls to 90.00', j ->> 'replayed' = 'false' AND p.credits_amount = 20 AND p.amount_due = due0 - 20, p::text);
  PERFORM zz.check('4: the ledger entry says what it is, who made it and why', EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.id = (j ->> 'ledger_entry_id')::uuid AND e.entry_type = 'manual_credit' AND e.credit_amount = 20 AND e.charged_amount = 0
    AND e.reason = 'Goodwill after a late delivery' AND e.source = 'admin' AND e.created_by IS NOT NULL AND e.period_id = p.id));
  j := zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 20, ''manual_credit'', ''Goodwill after a late delivery'', ''key-credit-1'')::text', c1))::jsonb;
  PERFORM zz.check('4: the same request sent again records nothing more', j ->> 'replayed' = 'true' AND (SELECT credits_amount FROM public.billing_periods WHERE id = p.id) = 20 AND (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = c1 AND entry_type = 'manual_credit') = 1);
  PERFORM zz.check('4: the same key for a different amount or kind is refused', zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 21, ''manual_credit'', ''Changed the amount'', ''key-credit-1'')::text', c1)) LIKE 'ERR: This request key was already used for a different entry%'
    AND zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 20, ''promotional_credit'', ''Changed the kind'', ''key-credit-1'')::text', c1)) LIKE 'ERR: This request key was already used for a different entry%');
  j := zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 10.50, ''promotional_credit'', ''Launch month promotional credit'', ''key-credit-2'')::text', c1))::jsonb;
  PERFORM zz.check('4: a promotional credit is its own kind of entry', EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.id = (j ->> 'ledger_entry_id')::uuid AND e.entry_type = 'promotional_credit' AND e.credit_amount = 10.50) AND (SELECT credits_amount FROM public.billing_periods WHERE id = p.id) = 30.50);
  j := zz.adm(format('SELECT public.admin_billing_apply_charge(%L, 15, ''Setup assistance agreed with the owner'', ''key-charge-1'')::text', c1))::jsonb;
  SELECT * INTO p FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('4: a manual charge of 15.00 goes on the current bill (debits 15.00): 110.00 - 30.50 + 15.00 = 94.50', p.debits_amount = 15 AND p.amount_due = 94.50 AND EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.id = (j ->> 'ledger_entry_id')::uuid
    AND e.entry_type = 'manual_debit' AND e.charged_amount = 15 AND e.credit_amount = 0 AND e.reason = 'Setup assistance agreed with the owner'), p::text);
  j := zz.adm(format('SELECT public.admin_billing_apply_charge(%L, 15, ''Setup assistance agreed with the owner'', ''key-charge-1'')::text', c1))::jsonb;
  PERFORM zz.check('4: a repeated charge request records nothing more', j ->> 'replayed' = 'true' AND (SELECT debits_amount FROM public.billing_periods WHERE id = p.id) = 15);
  PERFORM zz.check('4: neither touches the transaction-fee cap (fees stay 10.00 of the plan''s 50.00 cap) or the order counters', (SELECT transaction_fees_amount FROM public.billing_periods WHERE id = p.id) = 10);
  PERFORM zz.check('4: a business whose billing is only in SHADOW has no real bill to put a credit or a charge on', zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5, ''manual_credit'', ''Shadow business'', ''key-credit-9'')::text', c9)) LIKE 'ERR: Real billing is not running for this business yet%'
    AND zz.adm(format('SELECT public.admin_billing_apply_charge(%L, 5, ''Shadow business'', ''key-charge-9'')::text', c9)) LIKE 'ERR: Real billing is not running for this business yet%');
  UPDATE public.billing_settings SET mode = 'shadow';
  PERFORM zz.check('4: nor while the whole platform is only in shadow', zz.adm(format('SELECT public.admin_billing_apply_credit(%L, 5, ''manual_credit'', ''Platform in shadow'', ''key-credit-sh'')::text', c1)) LIKE 'ERR: Real billing is not running for this business yet%');
  UPDATE public.billing_settings SET mode = 'active';
  PERFORM zz.check('4: every credit and charge is audited with the administrator, the amount, the period and the ledger entry', (SELECT count(*) FROM public.audit_logs WHERE business_id = c1 AND performed_by IS NOT NULL AND activity IN ('Billing credit applied', 'Billing charge applied')
    AND details ->> 'ledger_entry_id' IS NOT NULL AND length(details ->> 'reason') >= 5) = 3);
END $$;

-- 5. Waiving the fee on one order -----------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); c4 UUID := (SELECT c4 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); o7 UUID := (SELECT id FROM zz.o WHERE k = 'c1_7'); o1 UUID := (SELECT id FROM zz.o WHERE k = 'c1_1');
  j JSONB; p public.billing_periods; pend UUID; o8 UUID;
BEGIN
  PERFORM zz.check('5: an order of another business is refused', zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Wrong business'')::text', c4, o7)) LIKE 'ERR: That order does not belong to this business%');
  PERFORM zz.check('5: a pharmacy is never charged a fee, so there is nothing to waive', zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''A pharmacy'')::text', ph, o7)) LIKE 'ERR: Only a wholesaler is charged a transaction fee%');
  PERFORM zz.check('5: a free order has no fee to waive', zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Already free'')::text', c1, o1)) LIKE 'ERR: There is no fee left to waive on this order%');
  pend := zz.mkorder(c1, 500, 0, clock_timestamp());
  PERFORM zz.check('5: an order that has not been billed (not delivered) has no assessment', zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Not delivered yet'')::text', c1, pend)) LIKE 'ERR: This order has no real billing assessment%');
  j := zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Fee waived after the customer complaint'')::text', c1, o7))::jsonb;
  PERFORM zz.check('5: waiving order 7''s fee credits exactly the GHS 10.00 charged', (j ->> 'amount')::numeric = 10 AND EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.id = (j ->> 'ledger_entry_id')::uuid AND e.entry_type = 'fee_waiver'
    AND e.credit_amount = 10 AND e.order_id = o7 AND e.assessment_id IS NOT NULL AND e.reason = 'Fee waived after the customer complaint'), j::text);
  SELECT * INTO p FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('5: the waiver is a credit on the bill; the fee total, and so the cap, are untouched (fees still 10.00)', p.transaction_fees_amount = 10 AND p.credits_amount = 40.50, p::text);
  PERFORM zz.check('5: waiving the same order again is refused (nothing left)', zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Again'')::text', c1, o7)) LIKE 'ERR: There is no fee left to waive on this order%');
  -- the order's value rises after delivery: GHS 2.50 more fee is charged, and only that remains to be waived
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 1275 WHERE id = o7;
  j := zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Waive the extra fee as well'')::text', c1, o7))::jsonb;
  PERFORM zz.check('5: after the order''s value rose, only the extra GHS 2.50 fee is left, and that is what is waived', (j ->> 'amount')::numeric = 2.5, j::text);
  PERFORM zz.check('5: everything charged on the order (12.50) is now waived (12.50)', (SELECT sum(charged_amount) FROM public.order_billing_assessments WHERE order_id = o7) = 12.5 AND (SELECT sum(credit_amount) FROM public.billing_ledger_entries WHERE order_id = o7 AND entry_type = 'fee_waiver') = 12.5);
  -- a fee that fell after a delivery credit: the remainder is what is waived
  o8 := zz.go(c1, 1000, 25, clock_timestamp());
  PERFORM zz.check('5: another charged order (fee 10.00)', zz.a(o8) = 'chargeable/-/10.00', zz.a(o8));
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 525 WHERE id = o8;
  j := zz.adm(format('SELECT public.admin_billing_waive_fee(%L, %L, ''Waive what is left'')::text', c1, o8))::jsonb;
  PERFORM zz.check('5: when its value fell by half (the fee fell to 5.00), the 5.00 left is waived, not 10.00', (j ->> 'amount')::numeric = 5, j::text);
  PERFORM zz.check('5: each waiver is audited with the order, the amount and the ledger entry', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing fee waived' AND business_id = c1 AND performed_by IS NOT NULL AND details ->> 'ledger_entry_id' IS NOT NULL AND length(details ->> 'reason') >= 5) = 3);
  PERFORM zz.check('5: the books agree (no waiver is larger than the fee, every admin entry has its audit record)', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 6. Exempting from transaction fees -------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c4 UUID := (SELECT c4 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); i INT; v UUID; outs TEXT := '';
BEGIN
  PERFORM zz.check('6: a pharmacy cannot be exempt (it pays no fee)', zz.adm(format('SELECT public.admin_billing_set_exemption(%L, TRUE, ''Not a wholesaler'')::text', ph)) LIKE 'ERR: Only a wholesaler is charged a transaction fee%');
  PERFORM zz.check('6: taking away an exemption that does not exist is refused', zz.adm(format('SELECT public.admin_billing_set_exemption(%L, FALSE, ''Never was exempt'')::text', c4)) LIKE 'ERR: This business is not exempt%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_exemption(%L, TRUE, ''Partner wholesaler agreement'')::text', c4));
  PERFORM zz.check('6: exempt, with the reason kept on the subscription', (SELECT exempt_from_transaction_fees AND exempt_reason = 'Partner wholesaler agreement' FROM public.billing_subscriptions WHERE business_id = c4));
  PERFORM zz.check('6: exempting twice is refused', zz.adm(format('SELECT public.admin_billing_set_exemption(%L, TRUE, ''Again'')::text', c4)) LIKE 'ERR: This business is already exempt%');
  FOR i IN 1..3 LOOP v := zz.go(c4, 1000, 25, clock_timestamp()); outs := outs || zz.a(v) || ' '; END LOOP;
  PERFORM zz.check('6: orders delivered while exempt are recorded as exempt, charged nothing, and use none of the free orders', outs = 'exempt/-/0.00 exempt/-/0.00 exempt/-/0.00 ' AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = c4 AND free_source IS NOT NULL) = 0, outs);
  PERFORM zz.adm(format('SELECT public.admin_billing_set_exemption(%L, FALSE, ''Agreement ended'')::text', c4));
  v := zz.go(c4, 1000, 25, clock_timestamp());
  PERFORM zz.check('6: once the exemption is removed, the next order is treated normally (the first launch free order is still available)', zz.a(v) = 'free_onboarding/onboarding1/0.00', zz.a(v));
  PERFORM zz.check('6: both changes are audited with the reason', (SELECT count(*) FROM public.audit_logs WHERE business_id = c4 AND performed_by IS NOT NULL AND activity IN ('Billing exemption enabled', 'Billing exemption removed') AND length(details ->> 'reason') >= 5) = 2);
END $$;

-- 7. Pausing, and ending a subscription ---------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c3 UUID := (SELECT c3 FROM zz.w); v UUID; per_end TIMESTAMPTZ; b RECORD;
BEGIN
  PERFORM zz.check('7: resuming billing that is not paused is refused', zz.adm(format('SELECT public.admin_billing_set_paused(%L, FALSE, ''Not paused'')::text', c3)) LIKE 'ERR: Billing is not paused for this business%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_paused(%L, TRUE, ''Disputed account under review'')::text', c3));
  PERFORM zz.check('7: paused: billing is off for the business, with the time and reason kept', public.billing_effective_mode(c3) = 'disabled' AND (SELECT billing_paused AND paused_at IS NOT NULL AND paused_reason = 'Disputed account under review' FROM public.billing_subscriptions WHERE business_id = c3));
  PERFORM zz.check('7: pausing twice is refused', zz.adm(format('SELECT public.admin_billing_set_paused(%L, TRUE, ''Again'')::text', c3)) LIKE 'ERR: Billing is already paused for this business%');
  v := zz.go(c3, 1000, 25, clock_timestamp());
  PERFORM zz.check('7: an order delivered while paused is recorded as excluded and is never billed later', zz.a(v) = 'excluded/-/0.00', zz.a(v));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_paused(%L, FALSE, ''Review finished'')::text', c3));
  PERFORM zz.check('7: resumed: billing is back, and catching up does not bill the order delivered during the pause', public.billing_effective_mode(c3) = 'active' AND (public.billing_catch_up(50) ->> 'done') = '0'
    AND (SELECT paused_reason IS NULL AND paused_at IS NULL FROM public.billing_subscriptions WHERE business_id = c3));
  PERFORM zz.check('7: pausing and resuming are audited with the reason', (SELECT count(*) FROM public.audit_logs WHERE business_id = c3 AND performed_by IS NOT NULL AND activity IN ('Billing paused', 'Billing resumed') AND length(details ->> 'reason') >= 5) = 2);
  -- cancellation at the end of the period
  PERFORM zz.check('7: withdrawing a cancellation that was never scheduled is refused', zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, FALSE, ''Not scheduled'')::text', c3)) LIKE 'ERR: This subscription is not set to end%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, TRUE, ''Customer asked to leave'')::text', c3));
  PERFORM zz.check('7: scheduled to end at the end of the period, and not twice', (SELECT cancel_at_period_end FROM public.billing_subscriptions WHERE business_id = c3) AND zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, TRUE, ''Again'')::text', c3)) LIKE 'ERR: This subscription is already set to end%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, FALSE, ''Customer changed their mind'')::text', c3));
  PERFORM zz.check('7: it can be withdrawn before it happens (the end date goes too)', (SELECT NOT cancel_at_period_end AND ended_at IS NULL AND cancelled_at IS NULL FROM public.billing_subscriptions WHERE business_id = c3));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, TRUE, ''Customer asked to leave again'')::text', c3));
  SELECT ended_at INTO per_end FROM public.billing_subscriptions WHERE business_id = c3;
  PERFORM zz.check('7: the end is fixed at once, at the end of the current billing period', per_end IS NOT NULL AND per_end > clock_timestamp() AND per_end = (SELECT max(period_end) FROM public.billing_periods WHERE business_id = c3 AND NOT shadow AND period_start <= clock_timestamp()), per_end::text);
  PERFORM zz.check('7: while it is only scheduled, the business is still billed normally', public.billing_effective_mode(c3) = 'active');
  PERFORM public.billing_advance_states(per_end + interval '1 hour');
  PERFORM zz.check('7: at the end of the period the subscription ends', (SELECT status = 'cancelled' AND ended_at = per_end FROM public.billing_subscriptions WHERE business_id = c3), (SELECT status || ' ' || COALESCE(ended_at::text, '-') FROM public.billing_subscriptions WHERE business_id = c3));
  PERFORM zz.check('7: once ended, nothing about it can be changed: pause, plan, terms, trial, promotions', zz.adm(format('SELECT public.admin_billing_set_paused(%L, TRUE, ''After the end'')::text', c3)) LIKE 'ERR: This subscription has ended%'
    AND zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', NULL, TRUE, ''After the end'')::text', c3)) LIKE 'ERR: This subscription has ended%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{}''::jsonb, NULL, ''After the end'')::text', c3)) LIKE 'ERR: This subscription has ended%'
    AND zz.adm(format('SELECT public.admin_billing_extend_trial(%L, now() + interval ''30 days'', ''After the end'')::text', c3)) LIKE 'ERR: A trial can only be extended%'
    AND zz.adm(format('SELECT public.admin_billing_set_cancellation(%L, FALSE, ''After the end'')::text', c3)) LIKE 'ERR: This subscription has already ended%');
END $$;

-- 8. Custom pricing --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c4 UUID := (SELECT c4 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); j JSONB; v UUID; a_free UUID; b_free UUID; c_fee UUID; t JSONB; n_terms INT; fut TIMESTAMPTZ := now() + interval '10 days';
BEGIN
  a_free := zz.go(c4, 1000, 25, clock_timestamp());
  PERFORM zz.check('8: before the change: Ctl C4''s second launch free order', zz.a(a_free) = 'free_onboarding/onboarding2/0.00', zz.a(a_free));
  PERFORM zz.check('8: unknown parameters, negative numbers, percentages over 100 and empty required values are refused', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"colour":1}''::jsonb, NULL, ''Unknown key'')::text', c4)) LIKE 'ERR: Unknown price override%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":-1}''::jsonb, NULL, ''Negative'')::text', c4)) LIKE 'ERR: The override "transaction_fee_percentage" must be a number%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":101}''::jsonb, NULL, ''Too high'')::text', c4)) LIKE 'ERR: A percentage cannot be more than 100%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"subscription_amount":null}''::jsonb, NULL, ''Empty'')::text', c4)) LIKE 'ERR: The override "subscription_amount" cannot be empty%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"exempt_from_transaction_fees":true}''::jsonb, NULL, ''Not permanent'')::text', c4)) LIKE 'ERR: Unknown price override%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''[]''::jsonb, NULL, ''Not an object'')::text', c4)) LIKE 'ERR: The price overrides must be an object%');
  PERFORM zz.check('8: a start in the past or more than a year ahead is refused', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2}''::jsonb, now() - interval ''2 days'', ''In the past'')::text', c4)) LIKE 'ERR: New terms cannot start in the past%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2}''::jsonb, now() + interval ''400 days'', ''Far ahead'')::text', c4)) LIKE 'ERR: New terms cannot start more than a year ahead%');
  PERFORM zz.check('8: a pharmacy can have only its subscription amount changed', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2}''::jsonb, NULL, ''A pharmacy fee'')::text', ph)) LIKE 'ERR: A pharmacy pays no transaction fee%'
    AND zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"subscription_amount":40}''::jsonb, NULL, ''Pharmacy subscription'')::text', ph)) NOT LIKE 'ERR:%');
  PERFORM zz.check('8: the pharmacy''s own subscription price is now 40.00', (public.billing_resolve_terms(ph, now() + interval '1 second') ->> 'subscription_amount')::numeric = 40);
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{}''::jsonb, NULL, ''Back to the plan'')::text', ph));
  j := zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2,"transaction_fee_cycle_cap":null,"subscription_amount":80}''::jsonb, NULL, ''Agreed enterprise pricing'')::text', c4))::jsonb;
  t := public.billing_resolve_terms(c4, clock_timestamp());
  PERFORM zz.check('8: custom pricing: 2% fee, no monthly cap, 80.00 subscription, from now', (t ->> 'transaction_fee_percentage')::numeric = 2 AND t -> 'transaction_fee_cycle_cap' = 'null'::jsonb AND (t ->> 'subscription_amount')::numeric = 80, t::text);
  PERFORM zz.check('8: asking for the same terms again is refused', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2,"transaction_fee_cycle_cap":null,"subscription_amount":80}''::jsonb, NULL, ''Same again'')::text', c4)) LIKE 'ERR: These are already the terms in force%');
  b_free := zz.go(c4, 1000, 25, clock_timestamp());
  c_fee := zz.go(c4, 1000, 25, clock_timestamp());
  PERFORM zz.check('8: the next orders are billed under the new terms: a monthly free order, then 2% = GHS 20.00 (the 1% launch terms are not applied)', zz.a(b_free) = 'free_monthly/monthly1/0.00' AND zz.a(c_fee) = 'chargeable/-/20.00', zz.a(b_free) || ' ' || zz.a(c_fee));
  PERFORM zz.check('8: an order assessed before the change keeps the terms it was assessed under (1%)', (SELECT (terms_snapshot ->> 'transaction_fee_percentage')::numeric FROM public.order_billing_assessments WHERE order_id = a_free AND kind = 'primary') = 1
    AND (SELECT (terms_snapshot ->> 'transaction_fee_percentage')::numeric FROM public.order_billing_assessments WHERE order_id = c_fee AND kind = 'primary') = 2);
  -- a future change
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":3}''::jsonb, %L, ''Higher fee from next month'')::text', c4, fut));
  PERFORM zz.check('8: terms that start later do not apply yet, and apply from their moment', (public.billing_resolve_terms(c4, clock_timestamp()) ->> 'transaction_fee_percentage')::numeric = 2 AND (public.billing_resolve_terms(c4, fut + interval '1 hour') ->> 'transaction_fee_percentage')::numeric = 3);
  PERFORM zz.check('8: new terms cannot start before terms that already exist', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":1.5}''::jsonb, NULL, ''Before the future one'')::text', c4)) LIKE 'ERR: New terms cannot start before terms that already exist%');
  PERFORM zz.check('8: the same moment twice is refused in plain words', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":3.5}''::jsonb, %L, ''Same moment'')::text', c4, fut)) LIKE 'ERR: Terms already start at that exact moment%');
  SELECT count(*) INTO n_terms FROM public.billing_subscription_terms WHERE subscription_id = (SELECT id FROM public.billing_subscriptions WHERE business_id = c4);
  PERFORM zz.check('8: the history is kept: the plan''s own terms and each change are separate rows', n_terms = 3, n_terms::text);
  PERFORM zz.check('8: the change is audited with the previous and new overrides and the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing custom pricing set' AND business_id = c4 AND performed_by IS NOT NULL AND details ->> 'reason' = 'Agreed enterprise pricing'
    AND details -> 'new_overrides' ->> 'subscription_amount' = '80' AND details ->> 'previous_overrides' = '{}'));
END $$;

-- 9. Changing plan ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c5 UUID := (SELECT c5 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); j JSONB; b RECORD; pend TIMESTAMPTZ; pid UUID; v UUID; c6 UUID; t JSONB;
BEGIN
  pid := zz.adm('SELECT public.admin_billing_create_plan(''ctl_off'', ''wholesaler'', ''Switched off'', NULL, ''standard'', ''Plan for tests'')::text')::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":10}''::jsonb, ''Terms for tests'')::text', pid));
  PERFORM zz.check('9: a plan that does not exist, is switched off, or is for another kind of business is refused', zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''nope'', NULL, TRUE, ''No such plan'')::text', c5)) LIKE 'ERR: Plan not found%'
    AND zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_off'', NULL, TRUE, ''Switched off'')::text', c5)) LIKE 'ERR: That plan is not switched on%'
    AND zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pharm'', NULL, TRUE, ''Wrong kind'')::text', c5)) LIKE 'ERR: That plan is for a different kind of business%');
  PERFORM zz.check('9: it cannot start in the past, and moving to the plan it is already on is refused', zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', now() - interval ''3 days'', TRUE, ''In the past'')::text', c5)) LIKE 'ERR: A plan change cannot start in the past%'
    AND zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_ws'', now(), TRUE, ''Already on it'')::text', c5)) LIKE 'ERR: The business is already on this plan version%');
  j := zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', NULL, TRUE, ''Upgrade agreed with the owner'')::text', c5))::jsonb;
  SELECT * INTO b FROM public.billing_period_bounds((SELECT period_anchor_at FROM public.billing_subscriptions WHERE business_id = c5), 1, now());
  PERFORM zz.check('9: by default the change starts with the NEXT billing period, so the bill already running is not re-priced', (j ->> 'effective_from')::timestamptz = b.period_end, j::text);
  PERFORM zz.check('9: until then the old plan applies (100.00, 1%), and afterwards the new one (200.00, 0.5%)', public.billing_resolve_terms(c5, now()) ->> 'plan_code' = 'ctl_ws' AND public.billing_resolve_terms(c5, b.period_end + interval '1 hour') ->> 'plan_code' = 'ctl_pro'
    AND (public.billing_resolve_terms(c5, b.period_end + interval '1 hour') ->> 'subscription_amount')::numeric = 200);
  -- immediate change, keeping and clearing custom pricing
  PERFORM zz.check('9: a custom price set now', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":3}''::jsonb, %L, ''Custom fee after the upgrade'')::text', c5, b.period_end + interval '2 hours')) NOT LIKE 'ERR:%');
  PERFORM zz.check('9: the custom price in force before the change that is already scheduled cannot be slipped in before it', zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":4}''::jsonb, NULL, ''Before the upgrade'')::text', c5)) LIKE 'ERR: New terms cannot start before terms that already exist%');
  PERFORM zz.check('9: the change is audited with the new plan, when it starts, and the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing plan changed' AND business_id = c5 AND performed_by IS NOT NULL AND details ->> 'new_plan' = 'ctl_pro' AND details ->> 'reason' = 'Upgrade agreed with the owner'));
  -- a separate business for the immediate changes
  c6 := (SELECT w.c6 FROM zz.w w);
  j := zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', clock_timestamp(), FALSE, ''Immediate upgrade'')::text', c6))::jsonb;
  PERFORM zz.check('9: moving a business with no scheduled terms to another plan right now takes effect at once', j ->> 'terms_id' IS NOT NULL AND public.billing_resolve_terms(c6, clock_timestamp()) ->> 'plan_code' = 'ctl_pro', j::text);
  PERFORM zz.check('9: the launch free orders granted earlier are not lost by changing plan: the next two are free, then 0.5% = GHS 5.00', (SELECT string_agg(zz.a(zz.go(c6, 1000, 25, clock_timestamp())), ' ') FROM generate_series(1, 3)) = 'free_onboarding/onboarding1/0.00 free_onboarding/onboarding2/0.00 chargeable/-/5.00');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2}''::jsonb, clock_timestamp(), ''Custom on the pro plan'')::text', c6));
  j := zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_ws'', clock_timestamp(), FALSE, ''Back to the standard plan'')::text', c6))::jsonb;
  t := public.billing_resolve_terms(c6, clock_timestamp());
  PERFORM zz.check('9: changing plan without keeping custom pricing clears it (back to the standard plan at 1%)', t ->> 'plan_code' = 'ctl_ws' AND (t ->> 'transaction_fee_percentage')::numeric = 1, t::text);
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"transaction_fee_percentage":2}''::jsonb, clock_timestamp(), ''Custom again'')::text', c6));
  j := zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''ctl_pro'', clock_timestamp(), TRUE, ''Upgrade keeping the custom fee'')::text', c6))::jsonb;
  t := public.billing_resolve_terms(c6, clock_timestamp());
  PERFORM zz.check('9: while keeping it carries custom pricing to the new plan (pro plan at 2%)', t ->> 'plan_code' = 'ctl_pro' AND (t ->> 'transaction_fee_percentage')::numeric = 2 AND (t ->> 'subscription_amount')::numeric = 200, t::text);
END $$;

-- 10. Temporary terms ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c6 UUID := (SELECT c6 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); j JSONB; w1 UUID; w2 UUID; v UUID; t JSONB; w RECORD; r TEXT;
BEGIN
  PERFORM zz.check('10: nothing to change, a bad parameter, a waiver that is not "true", or an end before the start are refused', zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{}''::jsonb, NULL, now() + interval ''1 day'', ''Empty'')::text', c6)) LIKE 'ERR: Say what changes%'
    AND zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"colour":1}''::jsonb, NULL, now() + interval ''1 day'', ''Unknown'')::text', c6)) LIKE 'ERR: Unknown price override%'
    AND zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"exempt_from_transaction_fees":false}''::jsonb, NULL, now() + interval ''1 day'', ''Not a waiver'')::text', c6)) LIKE 'ERR: A temporary fee waiver is exempt_from_transaction_fees set to true%'
    AND zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.5}''::jsonb, now() + interval ''2 days'', now() + interval ''1 day'', ''Backwards'')::text', c6)) LIKE 'ERR: The end must be after the start%'
    AND zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.5}''::jsonb, now() - interval ''2 days'', now() + interval ''1 day'', ''Started in the past'')::text', c6)) LIKE 'ERR: A temporary change cannot start in the past%'
    AND zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.5}''::jsonb, NULL, now() + interval ''4 years'', ''Far too long'')::text', c6)) LIKE 'ERR: A temporary change can last at most three years%');
  PERFORM zz.check('10: a pharmacy can have only its subscription amount changed for a while', zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.5}''::jsonb, NULL, now() + interval ''1 day'', ''A pharmacy fee'')::text', ph)) LIKE 'ERR: A pharmacy pays no transaction fee%');
  v := zz.go(c6, 1000, 25, clock_timestamp());
  PERFORM zz.check('10: Ctl C6 is on its custom 2%: an order pays GHS 20.00', zz.a(v) = 'chargeable/-/20.00', zz.a(v));
  j := zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.5}''::jsonb, NULL, now() + interval ''2 days'', ''Launch-week lower fee'')::text', c6))::jsonb;
  w1 := (j ->> 'window_id')::uuid;
  t := public.billing_resolve_terms(c6, clock_timestamp());
  PERFORM zz.check('10: for two days the fee is 0.5%, and the terms say which temporary change is running', (t ->> 'transaction_fee_percentage')::numeric = 0.5 AND jsonb_array_length(t -> 'active_windows') = 1 AND t -> 'active_windows' -> 0 ->> 'window_id' = w1::text, t::text);
  v := zz.go(c6, 1000, 25, clock_timestamp());
  PERFORM zz.check('10: an order in the window pays GHS 5.00, and its snapshot records the window', zz.a(v) = 'chargeable/-/5.00' AND (SELECT jsonb_array_length(terms_snapshot -> 'active_windows') FROM public.order_billing_assessments WHERE order_id = v AND kind = 'primary') = 1, zz.a(v));
  PERFORM zz.check('10: after the window the old terms come back by themselves (nothing was changed to put back)', (public.billing_resolve_terms(c6, now() + interval '2 days 1 hour') ->> 'transaction_fee_percentage')::numeric = 2
   );
  -- a later change on top: the one made later wins where they overlap
  w2 := (zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.25}''::jsonb, NULL, now() + interval ''3 days'', ''Second lower fee'')::text', c6))::jsonb ->> 'window_id')::uuid;
  PERFORM zz.check('10: where two overlap, the one made later wins (0.25%), and both are listed', (public.billing_resolve_terms(c6, clock_timestamp()) ->> 'transaction_fee_percentage')::numeric = 0.25 AND jsonb_array_length(public.billing_resolve_terms(c6, clock_timestamp()) -> 'active_windows') = 2);
  PERFORM zz.adm(format('SELECT public.admin_billing_end_temporary_terms(%L, ''Second one ended early'')::text', w2));
  PERFORM zz.check('10: ending one early leaves the other running (0.5% again)', (public.billing_resolve_terms(c6, clock_timestamp()) ->> 'transaction_fee_percentage')::numeric = 0.5 AND (SELECT ended_early_at IS NOT NULL AND ends_at <= now() + interval '1 second' FROM public.billing_term_windows WHERE id = w2));
  PERFORM zz.check('10: a change that has ended cannot be ended again; an unknown one is not found', zz.adm(format('SELECT public.admin_billing_end_temporary_terms(%L, ''Again'')::text', w2)) LIKE 'ERR: That temporary change has already ended%'
    AND zz.adm(format('SELECT public.admin_billing_end_temporary_terms(%L, ''Unknown'')::text', gen_random_uuid())) LIKE 'ERR: That temporary change was not found%');
  -- one that starts tomorrow does not apply today
  j := zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"transaction_fee_percentage":0.1}''::jsonb, now() + interval ''1 day'', now() + interval ''5 days'', ''Starts tomorrow'')::text', c6))::jsonb;
  PERFORM zz.check('10: a window that starts tomorrow does not apply today, and does tomorrow', (public.billing_resolve_terms(c6, clock_timestamp()) ->> 'transaction_fee_percentage')::numeric = 0.5 AND (public.billing_resolve_terms(c6, now() + interval '1 day 1 hour') ->> 'transaction_fee_percentage')::numeric = 0.1);
  PERFORM zz.adm(format('SELECT public.admin_billing_end_temporary_terms(%L, ''Cancel the one starting tomorrow'')::text', (j ->> 'window_id')::uuid));
  PERFORM zz.check('10: one that has not started can be cancelled, and then never applies', (public.billing_resolve_terms(c6, now() + interval '1 day 1 hour') ->> 'transaction_fee_percentage')::numeric = 0.5 AND (SELECT ends_at - starts_at < interval '1 second' FROM public.billing_term_windows WHERE id = (j ->> 'window_id')::uuid));
  -- a temporary fee waiver
  j := zz.adm(format('SELECT public.admin_billing_add_temporary_terms(%L, ''{"exempt_from_transaction_fees":true}''::jsonb, NULL, now() + interval ''1 day'', ''Fee-free day'')::text', c6))::jsonb;
  v := zz.go(c6, 1000, 25, clock_timestamp());
  PERFORM zz.check('10: during a temporary fee waiver an order is recorded as exempt', zz.a(v) = 'exempt/-/0.00', zz.a(v));
  PERFORM zz.adm(format('SELECT public.admin_billing_end_temporary_terms(%L, ''Fee-free day over'')::text', (j ->> 'window_id')::uuid));
  v := zz.go(c6, 1000, 25, clock_timestamp());
  PERFORM zz.check('10: after it ends the order is charged again (0.5% from the first window: GHS 5.00)', zz.a(v) = 'chargeable/-/5.00', zz.a(v));
  -- records are never edited or deleted
  r := zz.try(format('UPDATE public.billing_term_windows SET overrides = ''{"transaction_fee_percentage":0}''::jsonb WHERE id = %L', w1));
  PERFORM zz.check('10: a window''s terms cannot be edited', r LIKE 'ERR: A temporary window cannot be edited%', r);
  r := zz.try(format('UPDATE public.billing_term_windows SET ends_at = ends_at + interval ''1 day'', ended_early_at = now() WHERE id = %L', w1));
  PERFORM zz.check('10: nor made longer', r LIKE 'ERR: A window can only be ended earlier%', r);
  r := zz.try(format('DELETE FROM public.billing_term_windows WHERE id = %L', w1));
  PERFORM zz.check('10: nor deleted', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('INSERT INTO public.billing_term_windows(subscription_id, starts_at, ends_at, overrides, source, reason) SELECT id, now(), now() + interval ''1 day'', ''{"colour":1}''::jsonb, ''admin'', ''Direct insert'' FROM public.billing_subscriptions WHERE business_id = %L', c6));
  PERFORM zz.check('10: even a direct insert is checked for unknown parameters', r LIKE 'ERR: Unknown price override%', r);
  PERFORM zz.check('10: adding and ending are audited with the terms, the dates and the reason', (SELECT count(*) FROM public.audit_logs WHERE business_id = c6 AND performed_by IS NOT NULL AND activity = 'Billing temporary terms added' AND length(details ->> 'reason') >= 5) = 4
    AND (SELECT count(*) FROM public.audit_logs WHERE business_id = c6 AND performed_by IS NOT NULL AND activity = 'Billing temporary terms ended' AND length(details ->> 'reason') >= 5) = 3);
END $$;

-- 11. Promotions -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c7 UUID := (SELECT c7 FROM zz.w); c1 UUID := (SELECT c1 FROM zz.w); c4 UUID := (SELECT c4 FROM zz.w); ph UUID := (SELECT good FROM zz.bx); pid UUID; j JSONB; v UUID; t JSONB; r TEXT; owner7 UUID := (SELECT bz.owner_id FROM public.businesses bz WHERE bz.id = c7); c7b UUID; ca UUID; cb UUID; per public.billing_periods;
  full_benefits TEXT := '{"free_trial_days":10,"free_orders":3,"subscription_discount_percent":50,"discount_days":60,"fee_percentage":0.25,"fee_days":30,"fee_waiver_days":7}';
BEGIN
  PERFORM zz.check('11: a code of 3 to 40 letters, digits, dashes or underscores; unique', zz.adm('SELECT public.admin_billing_create_promotion(''A'', ''Bad code'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, NULL, NULL, NULL, ''Too short a code'')::text') LIKE 'ERR: The code must be 3 to 40%');
  PERFORM zz.check('11: the benefits come from a short fixed list, with sensible numbers', zz.adm('SELECT public.admin_billing_create_promotion(''BAD1'', ''Bad'', NULL, ''wholesaler'', ''{"free_cash":5}''::jsonb, NULL, NULL, NULL, ''Unknown benefit'')::text') LIKE 'ERR: Unknown promotion benefit%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD2'', ''Bad'', NULL, ''wholesaler'', ''{"free_orders":0}''::jsonb, NULL, NULL, NULL, ''Zero orders'')::text') LIKE 'ERR: The benefit "free_orders" must be a whole number%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD3'', ''Bad'', NULL, ''wholesaler'', ''{"free_trial_days":731}''::jsonb, NULL, NULL, NULL, ''Too many days'')::text') LIKE 'ERR: The benefit "free_trial_days" must be a whole number of days%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD4'', ''Bad'', NULL, ''wholesaler'', ''{"subscription_discount_percent":50}''::jsonb, NULL, NULL, NULL, ''Discount without days'')::text') LIKE 'ERR: A subscription discount needs both%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD5'', ''Bad'', NULL, ''wholesaler'', ''{"fee_days":30}''::jsonb, NULL, NULL, NULL, ''Days without a fee'')::text') LIKE 'ERR: A lower fee needs both%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD6'', ''Bad'', NULL, ''wholesaler'', ''{"subscription_discount_percent":101,"discount_days":10}''::jsonb, NULL, NULL, NULL, ''Over a hundred'')::text') LIKE 'ERR: A subscription discount must be more than 0%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD7'', ''Bad'', NULL, ''wholesaler'', ''{}''::jsonb, NULL, NULL, NULL, ''No benefits'')::text') LIKE 'ERR:%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD8'', ''Bad'', NULL, ''pharmacy'', ''{"free_orders":2}''::jsonb, NULL, NULL, NULL, ''Free orders for a pharmacy'')::text') LIKE 'ERR: A pharmacy pays no transaction fee%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BAD9'', ''Bad'', NULL, ''hospital'', ''{"free_orders":2}''::jsonb, NULL, NULL, NULL, ''Unknown type'')::text') LIKE 'ERR: Choose whether the promotion is for pharmacies or wholesalers%'
    AND zz.adm('SELECT public.admin_billing_create_promotion(''BADA'', ''Bad'', NULL, ''wholesaler'', ''{"free_orders":2}''::jsonb, now(), now() - interval ''1 day'', NULL, ''Ends before it starts'')::text') LIKE 'ERR:%');
  pid := zz.adm('SELECT public.admin_billing_create_promotion(''drugxone-launch'', ''Launch promotion'', ''30 days subscription free and the first orders free'', ''wholesaler'', ''' || full_benefits || '''::jsonb, NULL, NULL, NULL, ''Launch campaign approved by management'')::text')::uuid;
  PERFORM zz.check('11: a promotion is created (the code is upper-cased) and audited', (SELECT code = 'DRUGXONE-LAUNCH' AND active FROM public.billing_promotions WHERE id = pid) AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing promotion created' AND performed_by IS NOT NULL AND details ->> 'code' = 'DRUGXONE-LAUNCH' AND length(details ->> 'reason') >= 5));
  PERFORM zz.check('11: another with the same code is refused', zz.adm('SELECT public.admin_billing_create_promotion(''Drugxone-Launch'', ''Again'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, NULL, NULL, NULL, ''Same code twice'')::text') LIKE 'ERR: A promotion with this code already exists%');
  PERFORM zz.check('11: an unknown code, or a business with no subscription, is refused', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''NOPE'', ''Unknown code'')::text', c7)) LIKE 'ERR: No promotion has that code%'
    AND zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''DRUGXONE-LAUNCH'', ''No subscription'')::text', gen_random_uuid())) LIKE 'ERR: This business has no subscription%');
  SELECT * INTO per FROM public.billing_periods WHERE business_id = c7 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('11: before the promotion Ctl C7 owes its 100.00 subscription and is active (no trial)', per.amount_due = 100 AND (SELECT status FROM public.billing_subscriptions WHERE business_id = c7) = 'active');
  j := zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''drugxone-launch'', ''Selected launch wholesaler'')::text', c7))::jsonb;
  PERFORM zz.check('11: the promotion applies every benefit and says what it did', j -> 'applied' ? 'free_trial_days' AND j -> 'applied' ? 'free_orders' AND j -> 'applied' ? 'subscription_discount' AND j -> 'applied' ? 'lower_fee' AND j -> 'applied' ? 'fee_waiver', j::text);
  PERFORM zz.check('11: 10 free days of trial from now: the subscription is trialing and this period''s 100.00 is waived', (SELECT status = 'trialing' AND trial_end > now() + interval '9 days' FROM public.billing_subscriptions WHERE business_id = c7)
    AND (SELECT amount_due FROM public.billing_periods WHERE id = per.id) = 0 AND (j -> 'applied' -> 'free_trial_days' ->> 'periods_waived')::int = 1, j::text);
  PERFORM zz.check('11: 3 free orders granted as a promotion grant', (SELECT quantity FROM public.billing_allowance_grants WHERE business_id = c7 AND source = 'promotion' AND source_ref = 'DRUGXONE-LAUNCH') = 3);
  t := public.billing_resolve_terms(c7, clock_timestamp());
  PERFORM zz.check('11: for the period it lasts: subscription 50% off (50.00), fee 0.25%, and a fee waiver (three temporary changes on top of the plan)', (t ->> 'subscription_amount')::numeric = 50 AND (t ->> 'transaction_fee_percentage')::numeric = 0.25
    AND (t ->> 'exempt_from_transaction_fees')::boolean AND jsonb_array_length(t -> 'active_windows') = 3, t::text);
  PERFORM zz.check('11: the waiver ends in 7 days, the lower fee in 30, the discount in 60', (SELECT ends_at FROM public.billing_term_windows WHERE promotion_id = pid AND overrides ? 'exempt_from_transaction_fees') BETWEEN now() + interval '6 days 23 hours' AND now() + interval '7 days 1 hour'
    AND (SELECT ends_at FROM public.billing_term_windows WHERE promotion_id = pid AND overrides ? 'transaction_fee_percentage') BETWEEN now() + interval '29 days 23 hours' AND now() + interval '30 days 1 hour'
    AND (SELECT ends_at FROM public.billing_term_windows WHERE promotion_id = pid AND overrides ? 'subscription_amount') BETWEEN now() + interval '59 days 23 hours' AND now() + interval '60 days 1 hour');
  v := zz.go(c7, 1000, 25, clock_timestamp());
  PERFORM zz.check('11: an order during the fee waiver is exempt', zz.a(v) = 'exempt/-/0.00', zz.a(v));
  PERFORM zz.check('11: the redemption records what was done, who did it and why, and the promotion shows 1 redeemed', (SELECT applied ? 'free_orders' AND reason = 'Selected launch wholesaler' AND redeemed_by IS NOT NULL FROM public.billing_promotion_redemptions WHERE promotion_id = pid AND business_id = c7)
    AND (SELECT (e ->> 'redeemed')::int FROM jsonb_array_elements(zz.adm('SELECT public.admin_billing_promotions()::text')::jsonb) e WHERE e ->> 'code' = 'DRUGXONE-LAUNCH') = 1);
  PERFORM zz.check('11: applying it to the same business again is refused', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''DRUGXONE-LAUNCH'', ''Twice'')::text', c7)) LIKE 'ERR: This business has already received this promotion%');
  PERFORM zz.check('11: it is audited with what was applied', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing promotion applied' AND business_id = c7 AND performed_by IS NOT NULL AND details -> 'applied' ? 'lower_fee' AND details ->> 'code' = 'DRUGXONE-LAUNCH'));
  -- a second account of the same owner
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (owner7, 'wholesaler', 'Ctl C7 Branch', 'LIC-Ctl C7 Branch', 'approved') RETURNING id INTO c7b;
  PERFORM zz.sub(c7b, 'ctl_ws', now() - interval '1 day');
  PERFORM zz.check('11: another account of the same owner does not earn it again', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''DRUGXONE-LAUNCH'', ''Same owner'')::text', c7b)) LIKE 'ERR: Another account with the same licence number or owner has already received this promotion%');
  PERFORM zz.check('11: and nothing of it was applied (no promotion grant, no window)', NOT EXISTS (SELECT 1 FROM public.billing_allowance_grants WHERE business_id = c7b AND source = 'promotion') AND NOT EXISTS (SELECT 1 FROM public.billing_term_windows WHERE subscription_id = (SELECT id FROM public.billing_subscriptions WHERE business_id = c7b)));
  -- the same licence number under another owner, spaces and capitals ignored
  pid := zz.adm('SELECT public.admin_billing_create_promotion(''LIC-ONCE'', ''Licence test'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, NULL, NULL, NULL, ''Licence and limit tests'')::text')::uuid;
  ca := zz.mkws('Ctl CA'); cb := zz.mkws('Ctl CB');
  UPDATE public.businesses SET license_number = 'SHARED LIC 77' WHERE id = ca;
  UPDATE public.businesses SET license_number = ' shared lic  77 ' WHERE id = cb;
  PERFORM zz.sub(ca, 'ctl_ws', now() - interval '1 day'); PERFORM zz.sub(cb, 'ctl_ws', now() - interval '1 day');
  PERFORM zz.check('11: the first account with a licence number gets the promotion', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''lic-once'', ''First account'')::text', ca)) NOT LIKE 'ERR:%');
  PERFORM zz.check('11: another account with the same licence number (spaces and capitals ignored) does not', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''LIC-ONCE'', ''Same licence'')::text', cb)) LIKE 'ERR: Another account with the same licence number or owner%');
  -- a limit on how many may have it, and switching it off
  PERFORM zz.adm('SELECT public.admin_billing_create_promotion(''ONLY-ONE'', ''Limit test'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, NULL, NULL, 1, ''Limited to one business'')::text');
  PERFORM zz.check('11: a promotion limited to one business is given to the first', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''ONLY-ONE'', ''First come'')::text', c1)) NOT LIKE 'ERR:%');
  PERFORM zz.check('11: and is full for the second', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''ONLY-ONE'', ''Second come'')::text', c4)) LIKE 'ERR: This promotion has reached its limit of 1 businesses%');
  PERFORM zz.check('11: the list shows it as full', (SELECT e ->> 'status' FROM jsonb_array_elements(zz.adm('SELECT public.admin_billing_promotions()::text')::jsonb) e WHERE e ->> 'code' = 'ONLY-ONE') = 'full');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_promotion_active(%L, FALSE, ''Campaign paused'')::text', (SELECT id FROM public.billing_promotions WHERE code = 'LIC-ONCE')));
  PERFORM zz.check('11: a promotion that is switched off cannot be applied; switching off twice is refused', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''LIC-ONCE'', ''Switched off'')::text', c4)) LIKE 'ERR: This promotion is switched off%'
    AND zz.adm(format('SELECT public.admin_billing_set_promotion_active(%L, FALSE, ''Again'')::text', (SELECT id FROM public.billing_promotions WHERE code = 'LIC-ONCE'))) LIKE 'ERR: This promotion is already off%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_promotion_active(%L, TRUE, ''Campaign resumed'')::text', (SELECT id FROM public.billing_promotions WHERE code = 'LIC-ONCE')));
  -- not started, ended, and the wrong kind of business
  PERFORM zz.adm('SELECT public.admin_billing_create_promotion(''FUTURE-ONE'', ''Future'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, now() + interval ''2 days'', NULL, NULL, ''Starts later'')::text');
  PERFORM zz.adm('SELECT public.admin_billing_create_promotion(''PAST-ONE'', ''Past'', NULL, ''wholesaler'', ''{"free_orders":1}''::jsonb, now() - interval ''5 days'', now() - interval ''1 day'', NULL, ''Already over'')::text');
  PERFORM zz.adm('SELECT public.admin_billing_create_promotion(''PHARM-ONE'', ''Pharmacy'', NULL, ''pharmacy'', ''{"free_trial_days":5,"subscription_discount_percent":20,"discount_days":30}''::jsonb, NULL, NULL, NULL, ''For pharmacies'')::text');
  PERFORM zz.check('11: one that has not started, or has ended, is refused', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''FUTURE-ONE'', ''Too early'')::text', c4)) LIKE 'ERR: This promotion has not started yet%'
    AND zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''PAST-ONE'', ''Too late'')::text', c4)) LIKE 'ERR: This promotion has ended%');
  PERFORM zz.check('11: a wholesaler promotion cannot be given to a pharmacy, nor a pharmacy one to a wholesaler', zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''DRUGXONE-LAUNCH'', ''Wrong kind'')::text', ph)) LIKE 'ERR: This promotion is for wholesaler businesses only%'
    AND zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''PHARM-ONE'', ''Wrong kind'')::text', c4)) LIKE 'ERR: This promotion is for pharmacy businesses only%');
  j := zz.adm(format('SELECT public.admin_billing_apply_promotion(%L, ''PHARM-ONE'', ''Pharmacy launch'')::text', ph))::jsonb;
  PERFORM zz.check('11: a pharmacy promotion gives a 5-day trial extension and 20% off the subscription (40.00) for its period', j -> 'applied' ? 'free_trial_days' AND j -> 'applied' ? 'subscription_discount' AND (public.billing_resolve_terms(ph, clock_timestamp()) ->> 'subscription_amount')::numeric = 40, j::text);
  -- immutability
  r := zz.try(format('UPDATE public.billing_promotions SET benefits = ''{"free_orders":9999}''::jsonb WHERE code = ''ONLY-ONE'''));
  PERFORM zz.check('11: a promotion''s benefits can never be edited', r LIKE 'ERR: A promotion cannot be edited%', r);
  r := zz.try('DELETE FROM public.billing_promotions WHERE code = ''ONLY-ONE''');
  PERFORM zz.check('11: or the promotion deleted', r LIKE 'ERR: A promotion is never deleted%', r);
  r := zz.try('UPDATE public.billing_promotion_redemptions SET reason = ''changed later''');
  PERFORM zz.check('11: or a redemption changed or deleted', r LIKE 'ERR: Billing records are never changed or deleted%' AND zz.try('DELETE FROM public.billing_promotion_redemptions') LIKE 'ERR: Billing records are never changed or deleted%', r);
  PERFORM zz.check('11: switching a promotion on or off is audited', (SELECT count(*) FROM public.audit_logs WHERE activity IN ('Billing promotion switched on', 'Billing promotion switched off') AND performed_by IS NOT NULL AND length(details ->> 'reason') >= 5) = 2);
END $$;

-- 12. What the administrator and the business see ------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c7 UUID := (SELECT c7 FROM zz.w); d JSONB; j JSONB; adm_user UUID := (SELECT u_admin FROM zz.bx);
BEGIN
  d := zz.adm(format('SELECT public.admin_billing_business_detail(%L)::text', c7))::jsonb;
  PERFORM zz.check('12: the administrator''s detail lists the temporary terms (with the promotion each came from), the promotions received and the order id of each assessment', jsonb_array_length(d -> 'windows') = 3 AND d -> 'windows' -> 0 ->> 'promotion_code' = 'DRUGXONE-LAUNCH'
    AND (d -> 'windows' -> 0 ->> 'running')::boolean AND jsonb_array_length(d -> 'promotions') = 1 AND d -> 'promotions' -> 0 ->> 'code' = 'DRUGXONE-LAUNCH' AND d -> 'assessments' -> 0 ? 'order_id', left(d::text, 200));
  d := zz.val_as((SELECT owner_id FROM public.businesses WHERE id = c7), format('SELECT public.billing_my_overview(%L)::text', c7))::jsonb;
  PERFORM zz.check('12: the business sees the terms it is on now (fee 0.25%, subscription 50.00) and its free orders (3 from the promotion)', (d -> 'plan' ->> 'transaction_fee_percentage')::numeric = 0.25 AND (d -> 'plan' ->> 'subscription_amount')::numeric = 50
    AND (d -> 'free_orders' ->> 'launch_granted')::int = 5, left(d::text, 300));
  PERFORM zz.check('12: but not the administrator''s private tables: temporary terms, promotions and redemptions are unreadable to the business', zz.val_as((SELECT owner_id FROM public.businesses WHERE id = c7), 'SELECT (SELECT count(*) FROM public.billing_term_windows)::text || (SELECT count(*) FROM public.billing_promotions) || (SELECT count(*) FROM public.billing_promotion_redemptions)') = '000'
    AND zz.anon('SELECT count(*)::text FROM public.billing_promotions') LIKE 'ERR: permission denied%');
  PERFORM zz.check('12: the administrator reads them', zz.adm('SELECT (SELECT count(*) FROM public.billing_term_windows)::text') <> '0' AND zz.adm('SELECT (SELECT count(*) FROM public.billing_promotions)::text') <> '0');
  PERFORM zz.check('12: nobody can write to these tables directly, an administrator included', zz.adm('WITH x AS (INSERT INTO public.billing_promotions(code, name, business_type, benefits, reason) VALUES (''DIRECT'', ''Direct'', ''wholesaler'', ''{"free_orders":1}''::jsonb, ''Direct write'') RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%'
    AND zz.adm('WITH x AS (UPDATE public.billing_term_windows SET reason = ''Changed directly'' RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%'
    AND zz.adm('WITH x AS (DELETE FROM public.billing_promotion_redemptions RETURNING 1) SELECT count(*)::text FROM x') LIKE 'ERR: permission denied%');
  PERFORM zz.check('12: the earlier reports still work', zz.adm('SELECT public.admin_billing_overview()::text') NOT LIKE 'ERR:%' AND zz.adm('SELECT public.admin_billing_organizations()::text') NOT LIKE 'ERR:%' AND zz.adm('SELECT public.admin_billing_invoices()::text') NOT LIKE 'ERR:%');
END $$;

-- 13. The reconciliation finds each inconsistency --------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); found TEXT; o7 UUID := (SELECT id FROM zz.o WHERE k = 'c1_7'); pid UUID := (SELECT id FROM public.billing_promotions WHERE code = 'ONLY-ONE'); curp UUID; cb UUID := (SELECT c4 FROM zz.w);
BEGIN
  SELECT id INTO curp FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  PERFORM zz.check('13: the books are clean to start with', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
  BEGIN
    SET LOCAL session_replication_role = replica;
    UPDATE public.billing_periods SET debits_amount = debits_amount + 1 WHERE id = curp;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('13: a period whose charges differ from the ledger''s manual charges is found', found LIKE '%period_debits_differ_from_ledger%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, entry_type, credit_amount, reason, source, idempotency_key) VALUES (c1, curp, o7, 'fee_waiver', 99, 'Waived far too much', 'system', 'ctl-test-over');
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('13: a waiver larger than the fee that was charged is found', found LIKE '%fee_waived_more_than_charged%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_promotion_redemptions(promotion_id, business_id, applied, reason) VALUES (pid, cb, '{}'::jsonb, 'A second one over the limit');
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('13: a promotion given to more businesses than its limit is found', found LIKE '%promotion_redeemed_beyond_its_limit%', found);
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, credit_amount, reason, source, idempotency_key) VALUES (c1, curp, 'manual_credit', 3, 'Quietly given', 'admin', 'ctl-test-quiet');
    UPDATE public.billing_periods SET credits_amount = credits_amount + 3 WHERE id = curp;
    found := (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN OTHERS THEN NULL; END;
  PERFORM zz.check('13: a credit made by an administrator with no audit record is found', found LIKE '%admin_ledger_entry_without_audit%' AND found NOT LIKE '%period_credits_differ%', found);
  PERFORM zz.check('13: and after those undone mistakes the books are clean again', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- 14. Who can call what -----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE f TEXT;
BEGIN
  FOREACH f IN ARRAY ARRAY['admin_billing_extend_trial(uuid, timestamp with time zone, text)', 'admin_billing_grant_free_orders(uuid, integer, timestamp with time zone, text, text)', 'admin_billing_apply_credit(uuid, numeric, text, text, text)',
    'admin_billing_apply_charge(uuid, numeric, text, text)', 'admin_billing_waive_fee(uuid, uuid, text)', 'admin_billing_set_exemption(uuid, boolean, text)', 'admin_billing_set_paused(uuid, boolean, text)', 'admin_billing_set_cancellation(uuid, boolean, text)',
    'admin_billing_set_custom_terms(uuid, jsonb, timestamp with time zone, text)', 'admin_billing_change_plan(uuid, text, timestamp with time zone, boolean, text)', 'admin_billing_add_temporary_terms(uuid, jsonb, timestamp with time zone, timestamp with time zone, text)',
    'admin_billing_end_temporary_terms(uuid, text)', 'admin_billing_create_promotion(text, text, text, text, jsonb, timestamp with time zone, timestamp with time zone, integer, text)', 'admin_billing_set_promotion_active(uuid, boolean, text)',
    'admin_billing_apply_promotion(uuid, text, text)', 'admin_billing_promotions()'] LOOP
    PERFORM zz.check('14: ' || split_part(f, '(', 1) || ' is not open to visitors, and checks who is asking when signed in', NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE') AND has_function_privilege('authenticated', 'public.' || f, 'EXECUTE'));
  END LOOP;
  FOREACH f IN ARRAY ARRAY['_billing_money(numeric)', '_billing_lock_subscription(uuid)', '_billing_open_real_period(public.billing_subscriptions)', '_billing_post_credit(public.billing_periods, text, numeric, text, text, uuid, uuid, jsonb)',
    '_billing_do_extend_trial(public.billing_subscriptions, timestamp with time zone, text)', '_billing_do_grant_orders(uuid, integer, text, text, text, timestamp with time zone)', '_billing_do_window(uuid, timestamp with time zone, timestamp with time zone, jsonb, text, uuid, text)',
    'billing_validate_overrides(jsonb, boolean)', '_billing_reconcile_controls()'] LOOP
    PERFORM zz.check('14: the helper ' || split_part(f, '(', 1) || ' cannot be called by a signed-in user or a visitor', NOT has_function_privilege('authenticated', 'public.' || f, 'EXECUTE') AND NOT has_function_privilege('anon', 'public.' || f, 'EXECUTE'));
  END LOOP;
  PERFORM zz.check('14: the three new tables are closed to visitors and have row security on', NOT has_table_privilege('anon', 'public.billing_promotions', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.billing_promotions', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.billing_term_windows', 'UPDATE') AND NOT has_table_privilege('authenticated', 'public.billing_promotion_redemptions', 'DELETE')
    AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_promotions'::regclass, 'public.billing_term_windows'::regclass, 'public.billing_promotion_redemptions'::regclass)));
END $$;

-- 15. The bill carries all of it -----------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); j JSONB; i public.billing_invoices; l TEXT; p public.billing_periods; n INT;
BEGIN
  SELECT * INTO p FROM public.billing_periods WHERE business_id = c1 AND NOT shadow AND period_start <= now() AND period_end > now();
  j := public.billing_issue_invoices(p.period_end + interval '2 days');
  SELECT * INTO i FROM public.billing_invoices WHERE period_id = p.id;
  PERFORM zz.check('15: the current bill is invoiced with everything on it: the total equals the period''s amount due', i.id IS NOT NULL AND i.total_amount = (SELECT amount_due FROM public.billing_periods WHERE id = p.id) AND i.total_amount > 0, i::text);
  SELECT string_agg(kind || ':' || amount || ':' || description, ' | ' ORDER BY line_no) INTO l FROM public.billing_invoice_lines WHERE invoice_id = i.id;
  PERFORM zz.check('15: each credit, the charge and each waiver appears as its own line with its reason', l LIKE '%credit:-20.00:Goodwill after a late delivery%' AND l LIKE '%credit:-10.50:Launch month promotional credit%' AND l LIKE '%other_charge:15.00:Setup assistance agreed with the owner%'
    AND l LIKE '%credit:-10.00:Fee waived after the customer complaint%' AND l LIKE '%credit:-2.50:Waive the extra fee as well%' AND l LIKE '%credit:-5.00:Waive what is left%', l);
  PERFORM zz.check('15: the lines add up to the total, and the books agree', (SELECT sum(amount) FROM public.billing_invoice_lines WHERE invoice_id = i.id) = i.total_amount AND NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'period_not_invoiced_when_it_should_be'),
    (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
  -- Ctl C2's waived trial period
  SELECT count(*) INTO n FROM public.billing_invoices WHERE business_id = (SELECT c2 FROM zz.w) AND total_amount = 0;
  PERFORM zz.check('15: a period whose subscription was waived by a trial extension owes nothing, so it is closed with no invoice (no invoice of 0.00 is issued for it)', n = 0 AND NOT EXISTS (SELECT 1 FROM public.billing_invoices i2 JOIN public.billing_periods p2 ON p2.id = i2.period_id WHERE i2.business_id = (SELECT c2 FROM zz.w) AND p2.amount_due = 0));
END $$;

-- 16. Deleting an administrator's account -----------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE c1 UUID := (SELECT c1 FROM zz.w); u UUID := gen_random_uuid(); g UUID; r TEXT;
BEGIN
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at) VALUES (u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tmpdeleted@zz.test', '{}', '{"provider":"email"}', now(), now());
  INSERT INTO public.billing_allowance_grants(business_id, quantity, source, reason, created_by) VALUES (c1, 1, 'admin', 'Granted by someone who leaves', u) RETURNING id INTO g;
  INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, reason, source, idempotency_key, created_by) VALUES (c1, 'manual_credit', 1, 'Credited by someone who leaves', 'system', 'ctl-leaver-1', u);
  INSERT INTO public.billing_promotions(code, name, business_type, benefits, reason, created_by) VALUES ('LEAVER-ONE', 'Leaver', 'wholesaler', '{"free_orders":1}', 'Created by someone who leaves', u);
  r := zz.try(format('DELETE FROM auth.users WHERE id = %L', u));
  PERFORM zz.check('16: deleting the account of someone who made billing records succeeds', r IS NULL, r);
  PERFORM zz.check('16: the records stay, with only the link to the person cleared', (SELECT created_by IS NULL AND quantity = 1 AND reason = 'Granted by someone who leaves' FROM public.billing_allowance_grants WHERE id = g)
    AND (SELECT created_by IS NULL FROM public.billing_ledger_entries WHERE idempotency_key = 'ctl-leaver-1') AND (SELECT created_by IS NULL FROM public.billing_promotions WHERE code = 'LEAVER-ONE'));
  r := zz.try(format('UPDATE public.billing_allowance_grants SET quantity = 99 WHERE id = %L', g));
  PERFORM zz.check('16: but a record still cannot be edited', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('UPDATE public.billing_allowance_grants SET created_by = %L WHERE id = %L', (SELECT u_admin FROM zz.bx), g));
  PERFORM zz.check('16: nor given a different creator', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('UPDATE public.billing_allowance_grants SET created_by = NULL, quantity = 98 WHERE id = %L', g));
  PERFORM zz.check('16: nor changed at the same time as the link is cleared', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  r := zz.try(format('DELETE FROM public.billing_allowance_grants WHERE id = %L', g));
  PERFORM zz.check('16: nor deleted', r LIKE 'ERR: Billing records are never changed or deleted%', r);
END $$;
