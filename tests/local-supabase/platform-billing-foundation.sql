-- Platform billing, Phase 1: the schema and configuration functions. Plans and immutable versions, subscriptions and their terms, the once-only launch grant, rolling billing periods, modes,
-- entitlements, RLS across tenants, immutability of the ledger and assessments, and every administrator operation (permission, reason, audit). Run after setup.sql + migrations (through
-- 20261201110000_platform_billing_functions.sql) and pw.sql is not needed. Nothing in this phase charges anyone.
GRANT USAGE ON SCHEMA zz TO authenticated, anon;
GRANT SELECT ON zz.b, zz.u TO authenticated, anon;

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
-- Not signed in at all (the anon role).
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
-- As the superuser, catching an error as text (for what a trigger or constraint refuses).
CREATE FUNCTION zz.try(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  BEGIN
    IF p_sql ~* '^[[:space:]]*select' THEN EXECUTE p_sql INTO r; ELSE EXECUTE p_sql; END IF;
  EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  RETURN r;
END $$;

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000e1', 'bfin@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000071"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000e2', 'bacc@zz.test', '{"full_name":"Alpha Accountant","phone":"+233241000072"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES ('30000000-0000-0000-0000-0000000000e1'::uuid, 'finance'), ('30000000-0000-0000-0000-0000000000e2'::uuid, 'accountant')) v(uid, r);

CREATE TABLE zz.bx AS SELECT
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other,
  (SELECT id FROM zz.b WHERE name='Pending Wholesale') pending_w,
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Other Pharmacy') opharm,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  '30000000-0000-0000-0000-0000000000e1'::uuid u_wf,
  '30000000-0000-0000-0000-0000000000e2'::uuid u_wa;
CREATE FUNCTION zz.adm(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.val_as((SELECT u_admin FROM zz.bx), p_sql) $$;
CREATE FUNCTION zz.q(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$ DECLARE r TEXT; BEGIN EXECUTE p_sql INTO r; RETURN r; END $$;

-- 1. Defaults: off, and empty ----------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE s RECORD;
BEGIN
  SELECT * INTO s FROM public.billing_settings WHERE id;
  PERFORM zz.check('1: billing is DISABLED by default, in Africa/Accra, with a 7-day grace setting and GHS', s.mode = 'disabled' AND s.timezone = 'Africa/Accra' AND s.grace_days = 7 AND s.currency = 'GHS');
  PERFORM zz.check('1: there is exactly one settings row', (SELECT count(*) FROM public.billing_settings) = 1 AND zz.try('INSERT INTO public.billing_settings(id) VALUES (FALSE)') LIKE 'ERR:%');
  PERFORM zz.check('1: an unknown timezone is refused at once', zz.try('UPDATE public.billing_settings SET timezone = ''Mars/Olympus''') LIKE 'ERR:%');
  PERFORM zz.check('1: no business has a subscription, a period, an assessment or a ledger entry', (SELECT count(*) FROM public.billing_subscriptions) = 0 AND (SELECT count(*) FROM public.billing_periods) = 0
    AND (SELECT count(*) FROM public.order_billing_assessments) = 0 AND (SELECT count(*) FROM public.billing_ledger_entries) = 0);
  PERFORM zz.check('1: the feature catalog is seeded', (SELECT count(*) FROM public.billing_feature_catalog) >= 7);
END $$;

-- 2. Plans and immutable versions ---------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; w UUID; p UUID; v1 UUID; v2 UUID; a RECORD; n INT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bx), 'SELECT public.admin_billing_create_plan(''ws_try'', ''wholesaler'', ''Try'', NULL, ''standard'', ''A good reason'')::text');
  PERFORM zz.check('2: a wholesaler owner cannot create a plan', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.val_as((SELECT u_po FROM zz.bx), 'SELECT public.admin_billing_create_plan(''ws_try'', ''wholesaler'', ''Try'', NULL, ''standard'', ''A good reason'')::text');
  PERFORM zz.check('2: nor a pharmacy owner', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.anon('SELECT public.admin_billing_create_plan(''ws_try'', ''wholesaler'', ''Try'', NULL, ''standard'', ''A good reason'')::text');
  PERFORM zz.check('2: nor someone not signed in', r LIKE 'ERR: permission denied%', r);
  r := zz.adm('SELECT public.admin_billing_create_plan(''ws_test'', ''wholesaler'', ''Wholesaler test'', NULL, ''standard'', ''no'')::text');
  PERFORM zz.check('2: a reason of at least 5 characters is required', r LIKE 'ERR: A reason of at least 5%', r);
  r := zz.adm('SELECT public.admin_billing_create_plan(''Bad Code'', ''wholesaler'', ''Wholesaler test'', NULL, ''standard'', ''Create plan'')::text');
  PERFORM zz.check('2: a plan code must be lowercase letters, digits, - and _', r LIKE 'ERR:%', r);
  r := zz.adm('SELECT public.admin_billing_create_plan(''x_test'', ''bank'', ''Wholesaler test'', NULL, ''standard'', ''Create plan'')::text');
  PERFORM zz.check('2: a plan is for pharmacies or wholesalers only', r LIKE 'ERR: A plan is for pharmacies or wholesalers%', r);
  w := zz.adm('SELECT public.admin_billing_create_plan(''ws_test'', ''wholesaler'', ''Wholesaler test'', ''Test plan'', ''standard'', ''Create plan for tests'')::text')::uuid;
  p := zz.adm('SELECT public.admin_billing_create_plan(''rt_test'', ''pharmacy'', ''Retailer test'', NULL, ''standard'', ''Create plan for tests'')::text')::uuid;
  PERFORM zz.check('2: an administrator creates plans, switched OFF and hidden by default', (SELECT NOT active AND NOT publicly_visible FROM public.billing_plans WHERE id = w));
  PERFORM zz.check('2: a duplicate code is refused', zz.adm('SELECT public.admin_billing_create_plan(''ws_test'', ''wholesaler'', ''Again'', NULL, ''standard'', ''Create plan again'')::text') LIKE 'ERR:%duplicate%');
  PERFORM zz.check('2: creating a plan wrote an audit entry with the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing plan created' AND record_id = w AND details ->> 'reason' = 'Create plan for tests'));
  PERFORM zz.check('2: a plan cannot be switched on before a version is published', zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, FALSE, ''Switch on'')::text', w)) LIKE 'ERR: Publish a version of the plan first.%');

  v1 := zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Launch terms'')::text', w,
    '{"subscription_amount":100,"free_trial_days":30,"onboarding_free_orders":5,"monthly_free_orders":2,"transaction_fee_percentage":0.75,"transaction_fee_cycle_cap":1500,"entitlements":{"rfq_access":true,"export_row_limit":5000}}'))::uuid;
  SELECT * INTO a FROM public.billing_plan_versions WHERE id = v1;
  PERFORM zz.check('2: version 1 holds the terms exactly (GHS 100, 30 days, 5 + 2 free orders, 0.75%, cap 1500, no minimum or maximum per order)',
    a.version = 1 AND a.subscription_amount = 100 AND a.free_trial_days = 30 AND a.onboarding_free_orders = 5 AND a.monthly_free_orders = 2 AND a.transaction_fee_percentage = 0.75
    AND a.transaction_fee_cycle_cap = 1500 AND a.transaction_fee_min IS NULL AND a.transaction_fee_max IS NULL AND a.currency = 'GHS' AND a.billing_interval_months = 1 AND a.status = 'published');
  PERFORM zz.check('2: unknown plan terms are refused', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"transaction_fee":1}''::jsonb, ''Bad terms here'')::text', w)) LIKE 'ERR: Unknown plan term%');
  PERFORM zz.check('2: an unknown feature is refused', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"entitlements":{"time_travel":true}}''::jsonb, ''Bad feature'')::text', w)) LIKE 'ERR: Unknown plan feature%');
  PERFORM zz.check('2: a feature of the wrong kind of value is refused', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"entitlements":{"rfq_access":"yes"}}''::jsonb, ''Bad value'')::text', w)) LIKE 'ERR: The feature "rfq_access" must be true or false.%'
    AND zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"entitlements":{"export_row_limit":1.5}}''::jsonb, ''Bad value'')::text', w)) LIKE 'ERR: The feature "export_row_limit" must be a whole number.%');
  PERFORM zz.check('2: a retailer-only feature cannot be put on a wholesaler plan', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"entitlements":{"supplier_comparison":true}}''::jsonb, ''Wrong kind'')::text', w)) LIKE 'ERR: The feature "supplier_comparison" is not available%');
  PERFORM zz.check('2: a percentage above 100, a negative amount, a maximum below the minimum are all refused',
    zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"transaction_fee_percentage":101}''::jsonb, ''Bad percentage'')::text', w)) LIKE 'ERR:%'
    AND zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":-1}''::jsonb, ''Bad amount'')::text', w)) LIKE 'ERR:%'
    AND zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"transaction_fee_min":10,"transaction_fee_max":5}''::jsonb, ''Bad range'')::text', w)) LIKE 'ERR:%');
  SELECT count(*) INTO n FROM public.billing_plan_versions WHERE plan_id = w;
  PERFORM zz.check('2: none of the refused versions was recorded', n = 1);

  PERFORM zz.check('2: a published version''s terms can never be edited', zz.try(format('UPDATE public.billing_plan_versions SET transaction_fee_percentage = 1 WHERE id = %L', v1)) = 'ERR: The terms of a published plan version never change. Publish a new version instead.');
  PERFORM zz.check('2: nor its entitlements, nor its price', zz.try(format('UPDATE public.billing_plan_versions SET subscription_amount = 1 WHERE id = %L', v1)) LIKE 'ERR: The terms%' AND zz.try(format('UPDATE public.billing_plan_versions SET entitlements = ''{}'' WHERE id = %L', v1)) LIKE 'ERR: The terms%');
  PERFORM zz.check('2: nor can it be deleted', zz.try(format('DELETE FROM public.billing_plan_versions WHERE id = %L', v1)) LIKE 'ERR: A published plan version is never deleted%');

  v2 := zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":120,"free_trial_days":30,"onboarding_free_orders":5,"monthly_free_orders":2,"transaction_fee_percentage":1.0,"transaction_fee_cycle_cap":2000}''::jsonb, ''Raise the price'')::text', w))::uuid;
  PERFORM zz.check('2: a new version is number 2 and retires version 1', (SELECT version = 2 AND status = 'published' FROM public.billing_plan_versions WHERE id = v2) AND (SELECT status = 'retired' AND retired_at IS NOT NULL FROM public.billing_plan_versions WHERE id = v1));
  PERFORM zz.check('2: version 1 is exactly as it was (0.75%, GHS 100, cap 1500)', (SELECT transaction_fee_percentage = 0.75 AND subscription_amount = 100 AND transaction_fee_cycle_cap = 1500 FROM public.billing_plan_versions WHERE id = v1));
  PERFORM zz.check('2: a retired version cannot be published again', zz.try(format('UPDATE public.billing_plan_versions SET status = ''published'', retired_at = NULL WHERE id = %L', v1)) LIKE 'ERR:%');
  PERFORM zz.check('2: publishing wrote an audit entry with the previous and new terms and the reason',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing plan version published' AND record_id = w AND details ->> 'reason' = 'Raise the price'
            AND (details -> 'previous' ->> 'transaction_fee_percentage')::numeric = 0.75 AND (details -> 'new' ->> 'transaction_fee_percentage')::numeric = 1.0));

  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Open the plan'')::text', w));
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"free_trial_days":0}''::jsonb, ''Retailer terms'')::text', p));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, FALSE, ''Open the plan'')::text', p));
  PERFORM zz.check('2: an active plan is switched on and visible', (SELECT active AND publicly_visible FROM public.billing_plans WHERE id = w));
  PERFORM zz.check('2: a plan switched off cannot be shown', zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, FALSE, TRUE, ''Hide and show'')::text', w)) LIKE 'ERR: A plan that is switched off cannot be shown%');
  PERFORM zz.check('2: a plan''s code, type and kind never change and a plan is never deleted',
    zz.try(format('UPDATE public.billing_plans SET code = ''other'' WHERE id = %L', w)) LIKE 'ERR:%' AND zz.try(format('UPDATE public.billing_plans SET business_type = ''pharmacy'' WHERE id = %L', w)) LIKE 'ERR:%'
    AND zz.try(format('DELETE FROM public.billing_plans WHERE id = %L', w)) LIKE 'ERR: A plan is never deleted%');
END $$;

-- 3. Subscriptions, the trial and the once-only launch grant ------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; j JSONB; sub RECORD; alpha UUID := (SELECT alpha FROM zz.bx); t TIMESTAMPTZ := '2026-09-01 00:00:00+00'; owner_w UUID := (SELECT u_wo FROM zz.bx); extra UUID; lic UUID;
BEGIN
  r := zz.val_as(owner_w, format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Start billing'')::text', alpha, t));
  PERFORM zz.check('3: a business cannot put itself on a plan', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Start billing'')::text', (SELECT pending_w FROM zz.bx), t));
  PERFORM zz.check('3: only an APPROVED business can be put on a plan', r = 'ERR: Only an approved business can be put on a plan.', r);
  r := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''rt_test'', %L, NULL, ''Start billing'')::text', alpha, t));
  PERFORM zz.check('3: a retailer plan cannot go on a wholesaler', r = 'ERR: That plan is for a different kind of business.', r);
  r := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''nope'', %L, NULL, ''Start billing'')::text', alpha, t));
  PERFORM zz.check('3: an unknown plan is refused', r = 'ERR: Plan not found.', r);
  r := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, ''active'', ''Start billing'')::text', alpha, t));
  PERFORM zz.check('3: a business cannot be started in ACTIVE mode (real billing is not released)', r LIKE 'ERR: A business can start as disabled or shadow%', r);
  r := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Start billing'')::text', alpha, now() + interval '400 days'));
  PERFORM zz.check('3: billing cannot start more than a year ahead', r = 'ERR: Billing cannot start more than a year ahead.', r);

  j := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Start billing for Alpha'')::text', alpha, t))::jsonb;
  SELECT * INTO sub FROM public.billing_subscriptions WHERE business_id = alpha;
  PERFORM zz.check('3: Alpha is on version 2 of the plan, TRIALING for 30 days from its start, with no mode of its own', sub.status = 'trialing' AND sub.trial_start = t AND sub.trial_end = t + interval '30 days' AND sub.billing_mode IS NULL
    AND sub.billing_starts_at = t AND sub.period_anchor_at = t AND j ->> 'launch_grant' = 'granted'
    AND (SELECT plan_version = 2 FROM (SELECT (public.billing_resolve_terms(alpha, t + interval '1 day') ->> 'plan_version')::int AS plan_version) x), j::text);
  PERFORM zz.check('3: the launch grant is 5 free orders, recorded with its keys and source', (SELECT quantity = 5 AND source = 'plan' AND owner_key = owner_w AND kind = 'onboarding_free_orders' FROM public.billing_allowance_grants WHERE business_id = alpha));
  PERFORM zz.check('3: starting wrote an audit entry for the business, with the plan and the reason', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing subscription started' AND business_id = alpha AND details ->> 'plan' = 'ws_test' AND details ->> 'reason' = 'Start billing for Alpha'));
  PERFORM zz.check('3: a business can have only one subscription', zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Start billing again'')::text', alpha, t)) = 'ERR: This business already has a subscription.');

  -- the launch grant is once per owner and once per licence number
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (owner_w, 'wholesaler', 'Alpha Second Branch', 'LIC-OTHER-1', 'approved') RETURNING id INTO extra;
  j := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Second business same owner'')::text', extra, t))::jsonb;
  PERFORM zz.check('3: a SECOND business of the same owner gets the subscription but NO launch free orders', j ->> 'launch_grant' = 'declined_already_granted' AND (SELECT count(*) FROM public.billing_allowance_grants WHERE business_id = extra) = 0, j::text);
  UPDATE public.businesses SET license_number = 'LIC 7 7 7' WHERE id = (SELECT other FROM zz.bx);
  j := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, ''shadow'', ''Other wholesaler'')::text', (SELECT other FROM zz.bx), t))::jsonb;
  PERFORM zz.check('3: a different owner and licence gets the launch grant (and starts in shadow mode when asked)', j ->> 'launch_grant' = 'granted' AND (SELECT billing_mode = 'shadow' FROM public.billing_subscriptions WHERE business_id = (SELECT other FROM zz.bx)));
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  VALUES ('30000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lic@zz.test', '{}', '{"provider":"email"}', now(), now());
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES ('30000000-0000-0000-0000-0000000000e3', 'wholesaler', 'Licence Copy Ltd', ' lic777 ', 'approved') RETURNING id INTO lic;
  UPDATE public.businesses SET license_number = 'lic777' WHERE id = (SELECT other FROM zz.bx);
  j := zz.adm(format('SELECT public.admin_billing_start_subscription(%L, ''ws_test'', %L, NULL, ''Same licence, new owner'')::text', lic, t))::jsonb;
  PERFORM zz.check('3: a new owner with the SAME LICENCE NUMBER (spaces and case ignored) gets no launch grant either', j ->> 'launch_grant' = 'declined_already_granted', j::text);
  PERFORM zz.check('3: a grant can never be changed or deleted', zz.try('UPDATE public.billing_allowance_grants SET quantity = 500') LIKE 'ERR: Billing records are never changed or deleted%' AND zz.try('DELETE FROM public.billing_allowance_grants') LIKE 'ERR: Billing records are never changed or deleted%');

  PERFORM zz.check('3: a subscription''s business and start date never change, and it is never deleted',
    zz.try(format('UPDATE public.billing_subscriptions SET business_id = %L WHERE business_id = %L', (SELECT good FROM zz.bx), alpha)) LIKE 'ERR:%'
    AND zz.try(format('UPDATE public.billing_subscriptions SET billing_starts_at = now() WHERE business_id = %L', alpha)) LIKE 'ERR:%'
    AND zz.try('DELETE FROM public.billing_subscriptions') LIKE 'ERR: A subscription is never deleted%');
  PERFORM zz.check('3: a paused subscription needs its reason, and an exemption needs its reason', zz.try(format('UPDATE public.billing_subscriptions SET billing_paused = TRUE WHERE business_id = %L', alpha)) LIKE 'ERR:%'
    AND zz.try(format('UPDATE public.billing_subscriptions SET exempt_from_transaction_fees = TRUE WHERE business_id = %L', alpha)) LIKE 'ERR:%');
END $$;

-- 4. Terms: pinned versions, overrides, history -------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE alpha UUID := (SELECT alpha FROM zz.bx); sub UUID; t JSONB; r TEXT; t0 TIMESTAMPTZ := '2026-09-01 00:00:00+00'; v1 UUID; w UUID;
BEGIN
  SELECT id INTO sub FROM public.billing_subscriptions WHERE business_id = alpha;
  SELECT id INTO w FROM public.billing_plans WHERE code = 'ws_test';
  SELECT id INTO v1 FROM public.billing_plan_versions WHERE plan_id = w AND version = 1;
  -- a later version is published AFTER Alpha started: Alpha stays on its own pinned version
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":999,"transaction_fee_percentage":2.5}''::jsonb, ''A later price change'')::text', w));
  t := public.billing_resolve_terms(alpha, t0 + interval '5 days');
  PERFORM zz.check('4: a later plan version does not touch a subscriber: Alpha still resolves to version 2 (GHS 120, 1.0%, cap 2000)', (t ->> 'plan_version')::int = 2 AND (t ->> 'subscription_amount')::numeric = 120
    AND (t ->> 'transaction_fee_percentage')::numeric = 1.0 AND (t ->> 'transaction_fee_cycle_cap')::numeric = 2000, t::text);
  PERFORM zz.check('4: the resolved terms carry the allowances, the trial, the exemption flag and the identifiers the engine will snapshot',
    (t ->> 'onboarding_free_orders')::int = 5 AND (t ->> 'monthly_free_orders')::int = 2 AND (t ->> 'free_trial_days')::int = 30 AND (t ->> 'exempt_from_transaction_fees')::boolean = FALSE
    AND t ? 'terms_id' AND t ? 'plan_version_id' AND t ? 'subscription_id' AND t ->> 'currency' = 'GHS', t::text);
  PERFORM zz.check('4: before billing starts there are no terms in force', public.billing_resolve_terms(alpha, t0 - interval '1 day') IS NULL);
  PERFORM zz.check('4: a business with no subscription has no terms', public.billing_resolve_terms((SELECT good FROM zz.bx), now()) IS NULL);

  -- overrides: absent inherits; a value replaces; JSON null removes an optional limit
  INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason)
  VALUES (sub, t0 + interval '10 days', (SELECT id FROM public.billing_plan_versions WHERE plan_id = w AND version = 2), '{"transaction_fee_percentage": 0.5, "transaction_fee_cycle_cap": null, "monthly_free_orders": 4}', 'Negotiated custom terms');
  t := public.billing_resolve_terms(alpha, t0 + interval '11 days');
  PERFORM zz.check('4: an override replaces a value (0.5%), a null override removes the cap, a value not overridden is inherited (GHS 120)',
    (t ->> 'transaction_fee_percentage')::numeric = 0.5 AND t -> 'transaction_fee_cycle_cap' = 'null'::jsonb AND (t ->> 'monthly_free_orders')::int = 4 AND (t ->> 'subscription_amount')::numeric = 120, t::text);
  t := public.billing_resolve_terms(alpha, t0 + interval '9 days');
  PERFORM zz.check('4: moments before the override still resolve to the earlier terms (history is kept)', (t ->> 'transaction_fee_percentage')::numeric = 1.0 AND (t ->> 'transaction_fee_cycle_cap')::numeric = 2000, t::text);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{"colour": 1}'', ''Unknown key'')', sub, t0 + interval '20 days', v1));
  PERFORM zz.check('4: an unknown override is refused', r LIKE 'ERR: Unknown price override%', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{"subscription_amount": -5}'', ''Negative'')', sub, t0 + interval '20 days', v1));
  PERFORM zz.check('4: a negative override is refused', r LIKE 'ERR: The override "subscription_amount" must be a number%', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{"transaction_fee_percentage": null}'', ''Empty percentage'')', sub, t0 + interval '20 days', v1));
  PERFORM zz.check('4: the percentage and the price cannot be overridden to nothing', r LIKE 'ERR: The override "transaction_fee_percentage" cannot be empty.%', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{"monthly_free_orders": 1.5}'', ''Fractional orders'')', sub, t0 + interval '20 days', v1));
  PERFORM zz.check('4: free orders must be a whole number', r LIKE 'ERR: The override "monthly_free_orders" must be a whole number.%', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{}'', ''Going back in time'')', sub, t0 + interval '2 days', v1));
  PERFORM zz.check('4: new terms cannot start before terms that already exist', r = 'ERR: New terms cannot start before terms that already exist.', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{}'', ''ab'')', sub, t0 + interval '30 days', v1));
  PERFORM zz.check('4: terms need a reason', r LIKE 'ERR:%', r);
  r := zz.try(format('INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (%L, %L, %L, ''{}'', ''Wrong kind of plan'')', sub, t0 + interval '30 days', (SELECT v.id FROM public.billing_plan_versions v JOIN public.billing_plans p ON p.id = v.plan_id WHERE p.code = 'rt_test')));
  PERFORM zz.check('4: terms from a plan for the other kind of business are refused', r = 'ERR: This plan is for a different kind of business.', r);
  PERFORM zz.check('4: terms can never be edited or deleted', zz.try('UPDATE public.billing_subscription_terms SET reason = ''changed''') LIKE 'ERR: Billing records are never changed or deleted%' AND zz.try('DELETE FROM public.billing_subscription_terms') LIKE 'ERR: Billing records are never changed or deleted%');
END $$;

-- 5. Billing periods: rolling monthly, from the business's own anchor -------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE b RECORD; i INT; prev_end TIMESTAMPTZ; ok BOOLEAN := TRUE; anchor TIMESTAMPTZ; d TIMESTAMPTZ; bad TEXT := '';
BEGIN
  SELECT * INTO b FROM public.billing_period_bounds('2026-01-31 00:00:00+00', 1, '2026-02-15 12:00:00+00');
  PERFORM zz.check('5: anchored on the 31st, mid-February falls in [31 Jan, 28 Feb)', b.period_start = '2026-01-31 00:00+00' AND b.period_end = '2026-02-28 00:00+00' AND b.period_index = 0, b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2026-01-31 00:00:00+00', 1, '2026-02-28 00:00:00+00');
  PERFORM zz.check('5: a boundary belongs to the NEW period (start inclusive): 28 Feb is in [28 Feb, 31 Mar)', b.period_start = '2026-02-28 00:00+00' AND b.period_end = '2026-03-31 00:00+00' AND b.period_index = 1, b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2026-01-31 00:00:00+00', 1, '2026-02-27 23:59:59.999+00');
  PERFORM zz.check('5: the last instant before a boundary is still in the old period (end exclusive)', b.period_start = '2026-01-31 00:00+00' AND b.period_end = '2026-02-28 00:00+00', b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2026-01-31 00:00:00+00', 1, '2026-04-10 00:00:00+00');
  PERFORM zz.check('5: no drift after a short month: the next boundaries return to the 31st and then the 30th ([31 Mar, 30 Apr))', b.period_start = '2026-03-31 00:00+00' AND b.period_end = '2026-04-30 00:00+00', b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2028-01-31 00:00:00+00', 1, '2028-02-10 00:00:00+00');
  PERFORM zz.check('5: leap years: [31 Jan 2028, 29 Feb 2028)', b.period_end = '2028-02-29 00:00+00', b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2026-09-15 08:30:00+00', 1, '2026-09-15 08:30:00+00');
  PERFORM zz.check('5: the very first instant is the start of period 0', b.period_index = 0 AND b.period_start = '2026-09-15 08:30+00' AND b.period_end = '2026-10-15 08:30+00', b::text);
  SELECT * INTO b FROM public.billing_period_bounds('2026-01-15 00:00:00+00', 3, '2026-11-20 00:00:00+00');
  PERFORM zz.check('5: a 3-month interval: [15 Oct 2026, 15 Jan 2027)', b.period_start = '2026-10-15 00:00+00' AND b.period_end = '2027-01-15 00:00+00' AND b.period_index = 3, b::text);
  PERFORM zz.check('5: before billing starts there is no period', zz.try('SELECT * FROM public.billing_period_bounds(''2026-06-01+00'', 1, ''2026-05-31+00'')') LIKE 'ERR: That moment is before billing starts.%');
  PERFORM zz.check('5: a missing anchor or a zero-length period is refused', zz.try('SELECT * FROM public.billing_period_bounds(NULL, 1, now())') LIKE 'ERR:%' AND zz.try('SELECT * FROM public.billing_period_bounds(now(), 0, now())') LIKE 'ERR:%');
  FOREACH anchor IN ARRAY ARRAY['2026-01-29 00:00+00', '2026-01-30 00:00+00', '2026-01-31 00:00+00', '2024-02-29 12:00+00', '2026-12-31 23:59:59+00', '2026-03-01 00:00+00']::timestamptz[] LOOP
    prev_end := NULL;
    FOR i IN 0..47 LOOP
      d := anchor + make_interval(months => i) + interval '1 second';
      SELECT * INTO b FROM public.billing_period_bounds(anchor, 1, d);
      IF b.period_index <> i OR NOT (b.period_start <= d AND d < b.period_end) OR b.period_end <= b.period_start OR (prev_end IS NOT NULL AND b.period_start <> prev_end) THEN ok := FALSE; bad := bad || anchor::text || '#' || i || ' '; END IF;
      prev_end := b.period_end;
    END LOOP;
  END LOOP;
  PERFORM zz.check('5: for six awkward anchors over 48 months every period is contiguous with the last, contains its moment, has the right index and never overlaps', ok, bad);
  PERFORM zz.check('5: the period function is for the server only', zz.val_as((SELECT u_wo FROM zz.bx), 'SELECT * FROM public.billing_period_bounds(now(), 1, now())') LIKE 'ERR: permission denied%');
END $$;

-- 6. Modes ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; alpha UUID := (SELECT alpha FROM zz.bx); oth UUID := (SELECT other FROM zz.bx);
BEGIN
  PERFORM zz.check('6: with the platform DISABLED every business is disabled', public.billing_effective_mode(alpha) = 'disabled' AND public.billing_effective_mode(oth) = 'disabled');
  r := zz.val_as((SELECT u_wo FROM zz.bx), 'SELECT public.admin_billing_set_mode(''shadow'', ''Trying to switch'')');
  PERFORM zz.check('6: a business cannot change the platform mode', r LIKE 'ERR: Only platform administrators%', r);
  PERFORM zz.check('6: ACTIVE cannot be switched on here: it has its own checklist', zz.adm('SELECT public.admin_billing_set_mode(''active'', ''Go live now'')') LIKE 'ERR: Active billing is switched on through the activation checklist%');
  PERFORM zz.check('6: a mode must be one of the three', zz.adm('SELECT public.admin_billing_set_mode(''turbo'', ''Go faster'')') LIKE 'ERR: Choose disabled, shadow or active.%');
  PERFORM zz.check('6: a reason is required', zz.adm('SELECT public.admin_billing_set_mode(''shadow'', '''')') LIKE 'ERR: A reason of at least 5%');
  PERFORM zz.adm('SELECT public.admin_billing_set_mode(''shadow'', ''Start shadow billing'')');
  PERFORM zz.check('6: SHADOW is set, and recorded in the audit log with the previous and new mode and the reason', (SELECT mode = 'shadow' FROM public.billing_settings WHERE id)
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing mode changed' AND details ->> 'previous' = 'disabled' AND details ->> 'new' = 'shadow' AND details ->> 'reason' = 'Start shadow billing'));
  PERFORM zz.check('6: in shadow a business that follows the platform is shadow, and one set to shadow stays shadow', public.billing_effective_mode(alpha) = 'shadow' AND public.billing_effective_mode(oth) = 'shadow');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, ''disabled'', ''Hold this business back'')', alpha));
  PERFORM zz.check('6: one business can be held back to disabled', public.billing_effective_mode(alpha) = 'disabled' AND (SELECT billing_mode = 'disabled' FROM public.billing_subscriptions WHERE business_id = alpha));
  PERFORM zz.check('6: ... and the change is audited against that business', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing mode changed for a business' AND business_id = alpha AND details ->> 'new' = 'disabled' AND details ->> 'reason' = 'Hold this business back'));
  PERFORM zz.check('6: a business cannot be set to ACTIVE', zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, ''active'', ''Go live now'')', alpha)) LIKE 'ERR: Choose disabled, shadow, or follow%');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L, NULL, ''Follow the platform again'')', alpha));
  PERFORM zz.check('6: NULL means follow the platform again', public.billing_effective_mode(alpha) = 'shadow');
  PERFORM zz.check('6: a business without a subscription is disabled whatever the platform says', public.billing_effective_mode((SELECT good FROM zz.bx)) = 'disabled');
  PERFORM zz.check('6: only an administrator sets a business mode', zz.val_as((SELECT u_wo FROM zz.bx), format('SELECT public.admin_billing_set_subscription_mode(%L, ''disabled'', ''Hold this business back'')', alpha)) LIKE 'ERR: Only platform administrators%');
  -- a business can never be ahead of the platform; paused and ended businesses are disabled
  UPDATE public.billing_settings SET mode = 'active';
  UPDATE public.billing_subscriptions SET billing_mode = 'shadow' WHERE business_id = alpha;
  PERFORM zz.check('6: with the platform ACTIVE a business set to shadow is held at shadow', public.billing_effective_mode(alpha) = 'shadow' AND public.billing_effective_mode(oth) = 'shadow');
  UPDATE public.billing_subscriptions SET billing_mode = NULL WHERE business_id = alpha;
  PERFORM zz.check('6: and one that follows the platform is active', public.billing_effective_mode(alpha) = 'active');
  UPDATE public.billing_subscriptions SET billing_paused = TRUE, paused_at = now(), paused_reason = 'Paused for a test' WHERE business_id = alpha;
  PERFORM zz.check('6: a PAUSED business is disabled', public.billing_effective_mode(alpha) = 'disabled');
  UPDATE public.billing_subscriptions SET billing_paused = FALSE, paused_reason = NULL, ended_at = now() - interval '1 day' WHERE business_id = alpha;
  PERFORM zz.check('6: an ENDED subscription is disabled', public.billing_effective_mode(alpha) = 'disabled');
  UPDATE public.billing_subscriptions SET ended_at = NULL WHERE business_id = alpha;
END $$;

-- 7. Entitlements never restrict anything unless billing is active for that business -------------------------------------------------------------------------------------------------------------
DO $$
DECLARE alpha UUID := (SELECT alpha FROM zz.bx); oth UUID := (SELECT other FROM zz.bx); r TEXT; wo UUID := (SELECT u_wo FROM zz.bx);
BEGIN
  -- the platform is still ACTIVE from section 6 (set directly); Alpha follows it. Alpha is on version 2, whose entitlements are empty.
  PERFORM zz.check('7: with billing ACTIVE and the feature not in the plan, it is not enabled', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''advanced_analytics'')::text', alpha)) = 'false');
  UPDATE public.billing_settings SET mode = 'shadow';
  PERFORM zz.check('7: with billing in SHADOW nothing is restricted: every feature is enabled', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''advanced_analytics'')::text', alpha)) = 'true');
  UPDATE public.billing_settings SET mode = 'disabled';
  PERFORM zz.check('7: with billing DISABLED nothing is restricted either', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''advanced_analytics'')::text', alpha)) = 'true');
  PERFORM zz.check('7: limits are empty (unlimited) unless billing is active', zz.val_as(wo, format('SELECT coalesce(public.billing_limit(%L, ''max_users'')::text, ''unlimited'')', alpha)) = 'unlimited');
  UPDATE public.billing_settings SET mode = 'active';
  PERFORM zz.check('7: a business with no subscription is never restricted', zz.val_as((SELECT u_po FROM zz.bx), format('SELECT public.billing_feature_enabled(%L, ''rfq_access'')::text', (SELECT good FROM zz.bx))) = 'true');
  PERFORM zz.check('7: a person from another business cannot ask about this one', zz.val_as((SELECT u_wx FROM zz.bx), format('SELECT public.billing_feature_enabled(%L, ''rfq_access'')::text', alpha)) LIKE 'ERR: You do not have permission%');
  PERFORM zz.check('7: an unknown feature or limit is an error, not a silent yes', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''time_travel'')::text', alpha)) LIKE 'ERR: Unknown plan feature%' AND zz.val_as(wo, format('SELECT public.billing_limit(%L, ''time_travel'')::text', alpha)) LIKE 'ERR: Unknown plan limit%');
  PERFORM zz.check('7: an integer feature cannot be asked as a yes/no', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''export_row_limit'')::text', alpha)) LIKE 'ERR: Unknown plan feature%');
  PERFORM zz.check('7: not signed in cannot ask', zz.anon(format('SELECT public.billing_feature_enabled(%L, ''rfq_access'')::text', alpha)) LIKE 'ERR: permission denied%');
  -- a business on a plan that grants the feature, and limits
  INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason)
  SELECT s.id, '2026-09-20 00:00+00', (SELECT v.id FROM public.billing_plan_versions v JOIN public.billing_plans p ON p.id = v.plan_id WHERE p.code = 'ws_test' AND v.version = 1), '{}', 'Back to version 1 for the entitlement test'
  FROM public.billing_subscriptions s WHERE s.business_id = alpha;
  PERFORM zz.check('7: once those terms are in force the plan''s features apply: version 1 grants rfq_access while billing is active', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''rfq_access'')::text', alpha)) = 'true');
  PERFORM zz.check('7: ... but not a feature it does not grant', zz.val_as(wo, format('SELECT public.billing_feature_enabled(%L, ''integrations'')::text', alpha)) = 'false');
  PERFORM zz.check('7: the plan''s integer feature is a limit while active (export_row_limit 5000), and an unset plan limit is unlimited', zz.val_as(wo, format('SELECT public.billing_limit(%L, ''export_row_limit'')::text', alpha)) = '5000'
    AND zz.val_as(wo, format('SELECT coalesce(public.billing_limit(%L, ''max_users'')::text, ''unlimited'')', alpha)) = 'unlimited');
  PERFORM zz.check('7: the plan''s integer feature is a limit (5000 export rows) when asked at a moment the terms are in force',
    (public.billing_resolve_terms(alpha, '2026-09-21 00:00+00') -> 'entitlements' ->> 'export_row_limit')::int = 5000);
  UPDATE public.billing_settings SET mode = 'disabled';
END $$;

-- 8. RLS: nobody sees another business's billing, nobody writes directly -------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE alpha UUID := (SELECT alpha FROM zz.bx); oth UUID := (SELECT other FROM zz.bx); wo UUID := (SELECT u_wo FROM zz.bx); n TEXT; t TEXT; ord UUID; per UUID; per_s UUID; a UUID; r TEXT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, total_ghs) VALUES ((SELECT good FROM zz.bx), alpha, 1000) RETURNING id INTO ord;
  INSERT INTO public.billing_periods(business_id, subscription_id, period_start, period_end, shadow) SELECT alpha, s.id, '2026-11-01+00', '2026-12-01+00', FALSE FROM public.billing_subscriptions s WHERE s.business_id = alpha RETURNING id INTO per;
  INSERT INTO public.billing_periods(business_id, period_start, period_end, shadow) VALUES (alpha, '2026-10-01+00', '2026-11-01+00', TRUE) RETURNING id INTO per_s;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, charged_amount, idempotency_key, shadow) VALUES (alpha, per, 'subscription_charge', 100, 'sub:rls:real', FALSE);
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, charged_amount, idempotency_key, shadow) VALUES (alpha, per_s, 'subscription_charge', 100, 'sub:rls:shadow', TRUE);
  INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, shadow) VALUES (alpha, ord, per, 1000, 'excluded', FALSE);
  INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, shadow) VALUES (alpha, ord, per_s, 1000, 'excluded', TRUE);
  FOREACH t IN ARRAY ARRAY['billing_subscriptions', 'billing_subscription_terms', 'billing_allowance_grants'] LOOP
    PERFORM zz.check('8: Alpha''s owner sees Alpha''s rows in ' || t || ' and none of Other''s',
      zz.val_as(wo, format('SELECT count(*)::text FROM public.%I', t))::int > 0
      AND zz.val_as(wo, format('SELECT count(*)::text FROM public.%I x WHERE x.%s IN (SELECT id FROM public.businesses WHERE id = %L)', t, CASE t WHEN 'billing_subscription_terms' THEN 'subscription_id' ELSE 'business_id' END, oth)) IN ('0', 'ERR: column x.subscription_id does not exist'));
  END LOOP;
  PERFORM zz.check('8: each owner sees exactly the subscriptions of the businesses they own and no others', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_subscriptions')::int = (SELECT count(*) FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id WHERE b.owner_id = wo)
    AND zz.val_as((SELECT u_wx FROM zz.bx), 'SELECT count(*)::text FROM public.billing_subscriptions')::int = (SELECT count(*) FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id WHERE b.owner_id = (SELECT u_wx FROM zz.bx))
    AND zz.val_as(wo, format('SELECT count(*)::text FROM public.billing_subscriptions WHERE business_id = %L', oth)) = '0');
  PERFORM zz.check('8: the owner sees their real period and ledger entry, NOT the shadow ones', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_periods') = '1' AND zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_ledger_entries') = '1'
    AND zz.val_as(wo, 'SELECT count(*)::text FROM public.order_billing_assessments') = '1');
  PERFORM zz.check('8: an administrator sees everything, shadow included', zz.adm('SELECT count(*)::text FROM public.billing_periods') = '2' AND zz.adm('SELECT count(*)::text FROM public.billing_ledger_entries') = '2' AND zz.adm('SELECT count(*)::text FROM public.billing_subscriptions')::int >= 3);
  PERFORM zz.check('8: Other''s owner sees none of Alpha''s periods, ledger or assessments', zz.val_as((SELECT u_wx FROM zz.bx), 'SELECT count(*)::text FROM public.billing_periods') = '0'
    AND zz.val_as((SELECT u_wx FROM zz.bx), 'SELECT count(*)::text FROM public.billing_ledger_entries') = '0' AND zz.val_as((SELECT u_wx FROM zz.bx), 'SELECT count(*)::text FROM public.order_billing_assessments') = '0');
  PERFORM zz.check('8: the PHARMACY that bought the goods sees none of the wholesaler''s billing (no assessments, ledger or periods)', zz.val_as((SELECT u_po FROM zz.bx), 'SELECT count(*)::text FROM public.order_billing_assessments') = '0'
    AND zz.val_as((SELECT u_po FROM zz.bx), 'SELECT count(*)::text FROM public.billing_ledger_entries') = '0' AND zz.val_as((SELECT u_po FROM zz.bx), 'SELECT count(*)::text FROM public.billing_subscriptions') = '0');
  PERFORM zz.check('8: Alpha''s manager, finance and accounting staff see its billing; its cashier does not', zz.val_as((SELECT u_wm FROM zz.bx), 'SELECT count(*)::text FROM public.billing_periods') = '1'
    AND zz.val_as((SELECT u_wf FROM zz.bx), 'SELECT count(*)::text FROM public.billing_periods') = '1' AND zz.val_as((SELECT u_wa FROM zz.bx), 'SELECT count(*)::text FROM public.billing_periods') = '1'
    AND zz.val_as((SELECT u_wc FROM zz.bx), 'SELECT count(*)::text FROM public.billing_periods') = '0' AND zz.val_as((SELECT u_wc FROM zz.bx), 'SELECT count(*)::text FROM public.billing_subscriptions') = '0');
  PERFORM zz.check('8: someone not signed in sees nothing', zz.anon('SELECT count(*)::text FROM public.billing_subscriptions') LIKE 'ERR: permission denied%' AND zz.anon('SELECT count(*)::text FROM public.billing_ledger_entries') LIKE 'ERR: permission denied%');
  PERFORM zz.check('8: settings are for administrators only', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_settings') = '0' AND zz.adm('SELECT count(*)::text FROM public.billing_settings') = '1');
  PERFORM zz.check('8: plans that are not switched on and visible cannot be seen by a business; visible ones can', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_plans') = (SELECT count(*)::text FROM public.billing_plans WHERE active AND publicly_visible)
    AND zz.adm('SELECT count(*)::text FROM public.billing_plans')::int > zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_plans')::int);
  PERFORM zz.check('8: a business sees the published versions of visible plans only', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_plan_versions') = (SELECT count(*)::text FROM public.billing_plan_versions v JOIN public.billing_plans p ON p.id = v.plan_id WHERE p.active AND p.publicly_visible AND v.status = 'published'));
  PERFORM zz.check('8: any signed-in user can read the feature catalog', zz.val_as(wo, 'SELECT count(*)::text FROM public.billing_feature_catalog')::int >= 7);

  FOREACH t IN ARRAY ARRAY['billing_settings', 'billing_feature_catalog', 'billing_plans', 'billing_plan_versions', 'billing_subscriptions', 'billing_subscription_terms', 'billing_allowance_grants', 'billing_periods', 'order_billing_assessments', 'billing_ledger_entries'] LOOP
    r := zz.val_as((SELECT u_admin FROM zz.bx), format('UPDATE public.%I SET %s = %s', t, CASE t WHEN 'billing_feature_catalog' THEN 'key' ELSE 'id' END, CASE t WHEN 'billing_feature_catalog' THEN 'key' ELSE 'id' END));
    PERFORM zz.check('8: even an ADMINISTRATOR cannot write ' || t || ' directly (only the functions can)', r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(wo, format('DELETE FROM public.%I', t));
    PERFORM zz.check('8: a business cannot delete from ' || t, r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(wo, format('INSERT INTO public.%I DEFAULT VALUES', t));
    PERFORM zz.check('8: a business cannot insert into ' || t, r LIKE 'ERR: permission denied%', r);
  END LOOP;
  PERFORM zz.check('8: a business cannot raise its own free orders, change its percentage or exempt itself', zz.val_as(wo, format('UPDATE public.billing_subscriptions SET exempt_from_transaction_fees = TRUE, exempt_reason = ''x'' WHERE business_id = %L', alpha)) LIKE 'ERR: permission denied%'
    AND zz.val_as(wo, 'UPDATE public.billing_allowance_grants SET quantity = 99999') LIKE 'ERR: permission denied%');
END $$;

-- 9. Ledger, assessments and periods: integrity ---------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE alpha UUID := (SELECT alpha FROM zz.bx); ord UUID; per UUID; g UUID; r TEXT; e1 UUID; pp UUID; p2 UUID;
BEGIN
  SELECT id INTO ord FROM public.orders WHERE wholesaler_id = alpha ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO per FROM public.billing_periods WHERE business_id = alpha AND NOT shadow;
  SELECT id INTO g FROM public.billing_allowance_grants WHERE business_id = alpha;
  r := zz.try('UPDATE public.billing_ledger_entries SET charged_amount = 0');
  PERFORM zz.check('9: a ledger entry can never be changed', r LIKE 'ERR: Billing records are never changed or deleted%', r);
  PERFORM zz.check('9: nor deleted', zz.try('DELETE FROM public.billing_ledger_entries') LIKE 'ERR: Billing records are never changed or deleted%');
  PERFORM zz.check('9: an assessment can never be changed or deleted', zz.try('UPDATE public.order_billing_assessments SET billable_gmv = 1') LIKE 'ERR: Billing records are never changed or deleted%' AND zz.try('DELETE FROM public.order_billing_assessments') LIKE 'ERR: Billing records are never changed or deleted%');
  PERFORM zz.check('9: an entry is either a charge or a credit, never both', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, charged_amount, credit_amount, idempotency_key) VALUES (%L, ''transaction_fee'', 5, 5, ''k:both'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: neither amount can be negative', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, charged_amount, idempotency_key) VALUES (%L, ''transaction_fee'', -5, ''k:neg'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: a manual credit, a waiver, a refund and a promotional credit must say why', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key) VALUES (%L, ''manual_credit'', 5, ''k:why1'')', alpha)) LIKE 'ERR:%'
    AND zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key, reason) VALUES (%L, ''fee_waiver'', 5, ''k:why2'', ''ab'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: with a reason the same entry is accepted', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key, reason, source) VALUES (%L, ''manual_credit'', 5, ''k:why3'', ''Goodwill credit'', ''admin'')', alpha)) IS NULL);
  PERFORM zz.check('9: an unknown entry type is refused', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, idempotency_key) VALUES (%L, ''free_money'', ''k:type'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: the same idempotency key cannot be used twice', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, charged_amount, idempotency_key) VALUES (%L, ''subscription_charge'', 100, ''sub:rls:real'')', alpha)) LIKE 'ERR:%duplicate%');
  SELECT id INTO e1 FROM public.billing_ledger_entries WHERE idempotency_key = 'sub:rls:real';
  PERFORM zz.check('9: a reversal must name the entry it reverses', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key, reason) VALUES (%L, ''reversal'', 100, ''k:rev0'', ''Reverse it'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: a reversal is its own new entry, linked to the original, which is left untouched', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key, reason, reverses_entry_id) VALUES (%L, ''reversal'', 100, ''k:rev1'', ''Reverse it'', %L)', alpha, e1)) IS NULL
    AND (SELECT charged_amount = 100 FROM public.billing_ledger_entries WHERE id = e1));
  PERFORM zz.check('9: an entry can be reversed only once', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, credit_amount, idempotency_key, reason, reverses_entry_id) VALUES (%L, ''reversal'', 100, ''k:rev2'', ''Reverse it again'', %L)', alpha, e1)) LIKE 'ERR:%duplicate%');

  -- assessments: one primary per order (real, and separately shadow); consumption evidence is unique
  PERFORM zz.check('9: a second REAL primary assessment for the same order is refused (idempotency)', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome) VALUES (%L, %L, %L, 1000, ''excluded'')', alpha, ord, per)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('9: a second SHADOW primary for the same order is refused too', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome, shadow) VALUES (%L, %L, 1000, ''excluded'', TRUE)', alpha, ord)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('9: a primary assessment cannot carry an adjustment number, nor an adjustment number 0', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, kind, adjustment_seq, billable_gmv, outcome, shadow) VALUES (%L, %L, ''primary'', 2, 1, ''excluded'', FALSE)', alpha, ord)) LIKE 'ERR:%'
    AND zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, kind, adjustment_seq, billable_gmv, outcome, shadow) VALUES (%L, %L, ''adjustment'', 0, 1, ''excluded'', FALSE)', alpha, ord)) LIKE 'ERR:%');
  PERFORM zz.check('9: an adjustment (a later change in the order value) is accepted once per number', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, kind, adjustment_seq, billable_gmv, outcome) VALUES (%L, %L, ''adjustment'', 1, -50, ''excluded'')', alpha, ord)) IS NULL
    AND zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, kind, adjustment_seq, billable_gmv, outcome) VALUES (%L, %L, ''adjustment'', 1, -10, ''excluded'')', alpha, ord)) LIKE 'ERR:%duplicate%');
  -- free-order evidence
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, total_ghs, created_at) VALUES ((SELECT good FROM zz.bx), alpha, 100, clock_timestamp());
  PERFORM zz.check('9: an onboarding free order records the grant and its number', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq, grant_id) SELECT %L, id, %L, 100, ''free_onboarding'', ''onboarding'', 1, %L FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, g, alpha)) IS NULL);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, total_ghs, created_at) VALUES ((SELECT good FROM zz.bx), alpha, 100, clock_timestamp());
  PERFORM zz.check('9: the SAME onboarding number cannot be used by a second order', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq, grant_id) SELECT %L, id, %L, 100, ''free_onboarding'', ''onboarding'', 1, %L FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, g, alpha)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('9: the next number can', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq, grant_id) SELECT %L, id, %L, 100, ''free_onboarding'', ''onboarding'', 2, %L FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, g, alpha)) IS NULL);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, total_ghs, created_at) VALUES ((SELECT good FROM zz.bx), alpha, 100, clock_timestamp());
  PERFORM zz.check('9: an onboarding free order without its grant is refused', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq) SELECT %L, id, %L, 100, ''free_onboarding'', ''onboarding'', 3 FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: a free-order outcome must name its source, and a source needs its number', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome, free_source) SELECT %L, id, 100, ''free_monthly'', ''monthly'' FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, alpha)) LIKE 'ERR:%'
    AND zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome) SELECT %L, id, 100, ''free_monthly'' FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, alpha)) LIKE 'ERR:%');
  r := zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq) SELECT %L, id, %L, 100, ''free_monthly'', ''monthly'', 1 FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, alpha));
  PERFORM zz.check('9: a monthly free-order number is accepted once within a period', r IS NULL AND (SELECT count(*) FROM public.order_billing_assessments WHERE free_source = 'monthly') = 1, r);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, total_ghs, created_at) VALUES ((SELECT good FROM zz.bx), alpha, 100, clock_timestamp());
  PERFORM zz.check('9: ... so a second order cannot take monthly number 1 in the same period', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, period_id, billable_gmv, outcome, free_source, free_seq) SELECT %L, id, %L, 100, ''free_monthly'', ''monthly'', 1 FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, per, alpha)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('9: only a chargeable outcome can carry a charge', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome, charged_amount) SELECT %L, id, 100, ''excluded'', 5 FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: an unknown outcome is refused', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome) SELECT %L, id, 100, ''maybe'' FROM public.orders WHERE wholesaler_id = %L ORDER BY created_at DESC LIMIT 1', alpha, alpha)) LIKE 'ERR:%');

  -- periods
  PERFORM zz.check('9: overlapping real periods for one business are refused', zz.try(format('INSERT INTO public.billing_periods(business_id, period_start, period_end) VALUES (%L, ''2026-11-15+00'', ''2026-12-15+00'')', alpha)) = 'ERR: Billing periods for one business cannot overlap.');
  PERFORM zz.check('9: a period that ends at another''s start does not overlap (half-open)', zz.try(format('INSERT INTO public.billing_periods(business_id, period_start, period_end) VALUES (%L, ''2026-12-01+00'', ''2027-01-01+00'')', alpha)) IS NULL);
  PERFORM zz.check('9: a shadow period may sit over a real one (separate worlds)', zz.try(format('INSERT INTO public.billing_periods(business_id, period_start, period_end, shadow) VALUES (%L, ''2026-12-05+00'', ''2026-12-20+00'', TRUE)', alpha)) IS NULL);
  PERFORM zz.check('9: a period must end after it starts', zz.try(format('INSERT INTO public.billing_periods(business_id, period_start, period_end) VALUES (%L, ''2030-01-01+00'', ''2029-01-01+00'')', alpha)) LIKE 'ERR:%');
  PERFORM zz.check('9: a business''s period, its dates and its kind never change, and it is never deleted', zz.try(format('UPDATE public.billing_periods SET period_end = period_end + interval ''1 day'' WHERE id = %L', per)) LIKE 'ERR: A billing period''s business, dates and kind never change.%'
    AND zz.try(format('UPDATE public.billing_periods SET shadow = TRUE WHERE id = %L', per)) LIKE 'ERR:%' AND zz.try('DELETE FROM public.billing_periods') LIKE 'ERR: A billing period is never deleted.%');
  UPDATE public.billing_periods SET subscription_amount = 100, transaction_fees_amount = 37.50, debits_amount = 10, credits_amount = 25, amount_paid = 60, billable_gmv = 5000 WHERE id = per;
  PERFORM zz.check('9: the amount due and the outstanding balance are worked out by the database (100 + 37.50 + 10 - 25 = 122.50 due; 62.50 outstanding)', (SELECT amount_due = 122.50 AND outstanding_amount = 62.50 FROM public.billing_periods WHERE id = per));
  PERFORM zz.check('9: those two cannot be written directly', zz.try(format('UPDATE public.billing_periods SET amount_due = 1 WHERE id = %L', per)) LIKE 'ERR:%');
  PERFORM zz.check('9: a status outside the list is refused', zz.try(format('UPDATE public.billing_periods SET status = ''forgiven'' WHERE id = %L', per)) LIKE 'ERR:%');
  PERFORM zz.check('9: money columns use exact decimals, with no floating point anywhere', (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN ('billing_periods', 'billing_ledger_entries', 'order_billing_assessments', 'billing_plan_versions')
                                                                                                                 AND data_type IN ('real', 'double precision')) = 0);
END $$;

-- 10. Every administrator operation: permission, reason, audit ---------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE u RECORD; fn TEXT; r TEXT; alpha UUID := (SELECT alpha FROM zz.bx); plan UUID := (SELECT id FROM public.billing_plans WHERE code = 'ws_test');
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a wholesaler owner', (SELECT u_wo FROM zz.bx)), ('a wholesaler cashier', (SELECT u_wc FROM zz.bx)), ('a finance user', (SELECT u_wf FROM zz.bx)), ('a pharmacy owner', (SELECT u_po FROM zz.bx))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY[
      'admin_billing_set_mode(''shadow'', ''Valid reason'')',
      format('admin_billing_create_plan(''zz_%s'', ''wholesaler'', ''Name'', NULL, ''standard'', ''Valid reason'')', substr(md5(u.label), 1, 6)),
      format('admin_billing_publish_plan_version(%L, ''{}''::jsonb, ''Valid reason'')', plan),
      format('admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Valid reason'')', plan),
      format('admin_billing_start_subscription(%L, ''ws_test'', now(), NULL, ''Valid reason'')', (SELECT good FROM zz.bx)),
      format('admin_billing_set_subscription_mode(%L, ''disabled'', ''Valid reason'')', alpha)] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: Only platform administrators%', r);
    END LOOP;
  END LOOP;
  FOREACH fn IN ARRAY ARRAY['admin_billing_set_mode(''shadow'', ''Valid reason'')', format('admin_billing_set_plan_availability(%L, TRUE, TRUE, ''Valid reason'')', plan)] LOOP
    PERFORM zz.check('someone not signed in cannot call ' || split_part(fn, '(', 1), zz.anon('SELECT public.' || fn || '::text') LIKE 'ERR: permission denied%');
  END LOOP;
  FOREACH fn IN ARRAY ARRAY['_billing_admin_reason(''Valid reason'')', 'billing_resolve_terms(gen_random_uuid(), now())', 'billing_effective_mode(gen_random_uuid())', 'billing_onboarding_keys(gen_random_uuid())'] LOOP
    PERFORM zz.check('internal ' || split_part(fn, '(', 1) || ' is not callable by a signed-in user', zz.val_as((SELECT u_admin FROM zz.bx), 'SELECT public.' || fn || '::text') LIKE 'ERR: permission denied%');
  END LOOP;
  PERFORM zz.check('every administrator operation so far wrote an audit entry (mode, plan created, version, availability, subscription, business mode)',
    (SELECT count(DISTINCT activity) FROM public.audit_logs WHERE activity IN ('Billing mode changed', 'Billing plan created', 'Billing plan version published', 'Billing plan availability changed', 'Billing subscription started', 'Billing mode changed for a business')) = 6);
  PERFORM zz.check('every one of those audit entries carries the administrator and a reason', (SELECT bool_and(performed_by IS NOT NULL AND length(details ->> 'reason') >= 5) FROM public.audit_logs WHERE activity LIKE 'Billing%'));
  PERFORM zz.check('the seeded example plans are switched off and hidden (nothing can start on them by accident)', NOT EXISTS (SELECT 1 FROM public.billing_plans WHERE code IN ('wholesaler_example', 'retailer_example') AND (active OR publicly_visible)) OR NOT EXISTS (SELECT 1 FROM public.billing_plans WHERE code IN ('wholesaler_example', 'retailer_example')));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
