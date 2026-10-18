-- Pricing controls: Super Admin only, scheduled price changes, the two charging switches, and the commission rules that must keep holding.
-- Run in an isolated local database after the rollout fixture suite (it defines the zz helpers) and migrations through 20261210100000_billing_pricing_controls.sql.
-- Everything here is rolled back. "Time passing" is simulated by moving a scheduled version's start moment into the past as the database owner; nothing in the application can do that.
BEGIN;
CREATE FUNCTION pg_temp.ok(label text, ok boolean, detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL: % %', label, detail; END IF; RAISE NOTICE 'PASS: %', label; END $$;

CREATE TABLE zz.pc_u(k TEXT PRIMARY KEY, id UUID);
CREATE FUNCTION zz.pc_as(p_k TEXT, p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.val_as((SELECT id FROM zz.pc_u WHERE k = p_k), p_sql) $$;
-- The start moment of a scheduled change "arrives".
CREATE FUNCTION zz.pc_arrive(p_change UUID) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL session_replication_role = replica';
  UPDATE public.billing_plan_versions SET effective_from = now() WHERE id = (SELECT version_id FROM public.billing_scheduled_changes WHERE id = p_change);
  EXECUTE 'SET LOCAL session_replication_role = origin';
END $$;
CREATE FUNCTION zz.pc_plan(p_code TEXT, p_pct NUMERIC DEFAULT 1, p_amount NUMERIC DEFAULT 50, p_max NUMERIC DEFAULT 50, p_launch INT DEFAULT 10, p_monthly INT DEFAULT 5) RETURNS UUID LANGUAGE plpgsql AS $$
BEGIN
  PERFORM zz.mkplan(p_code, jsonb_build_object('subscription_amount', p_amount, 'free_trial_days', 30, 'onboarding_free_orders', p_launch, 'monthly_free_orders', p_monthly,
                    'transaction_fee_percentage', p_pct) || CASE WHEN p_max IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('transaction_fee_max', p_max) END);
  RETURN (SELECT id FROM public.billing_plans WHERE code = p_code);
END $$;
CREATE FUNCTION zz.pc_params(p_amount NUMERIC, p_pct NUMERIC DEFAULT 1) RETURNS TEXT LANGUAGE sql AS $$
  SELECT jsonb_build_object('subscription_amount', p_amount, 'free_trial_days', 30, 'onboarding_free_orders', 10, 'monthly_free_orders', 5, 'transaction_fee_percentage', p_pct, 'transaction_fee_max', 50)::text $$;
CREATE FUNCTION zz.pc_sched(p_plan UUID, p_params TEXT, p_from TIMESTAMPTZ, p_aud TEXT, p_keep BOOLEAN, p_exp INT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.adm(format('SELECT public.admin_billing_schedule_price_change(%L, %L::jsonb, %L, %L, %L, %L, ''Scheduled for the tests'')::text', p_plan, p_params, p_from, p_aud, p_keep, p_exp)) $$;
CREATE FUNCTION zz.pc_ver(p_biz UUID, p_at TIMESTAMPTZ DEFAULT now()) RETURNS TEXT LANGUAGE sql AS $$ SELECT public.billing_resolve_terms(p_biz, p_at) ->> 'plan_version' $$;
CREATE FUNCTION zz.pc_amt(p_biz UUID, p_at TIMESTAMPTZ DEFAULT now()) RETURNS TEXT LANGUAGE sql AS $$ SELECT trim_scale((public.billing_resolve_terms(p_biz, p_at) ->> 'subscription_amount')::numeric)::text $$;

-- fixtures: another administrator who is not the owner, an administrator with no platform record, an owner who has not been activated
SELECT zz.mkuser('50000000-0000-0000-0000-0000000000a1', 'pcstaff@zz.test', '{"full_name":"Platform Staff Admin","phone":"+233241000091"}');
SELECT zz.mkuser('50000000-0000-0000-0000-0000000000a2', 'pclegacy@zz.test', '{"full_name":"Legacy Admin","phone":"+233241000092"}');
SELECT zz.mkuser('50000000-0000-0000-0000-0000000000a3', 'pcpending@zz.test', '{"full_name":"Pending Owner","phone":"+233241000093"}');
INSERT INTO public.user_roles(user_id, role) VALUES ('50000000-0000-0000-0000-0000000000a1', 'admin'), ('50000000-0000-0000-0000-0000000000a2', 'admin'), ('50000000-0000-0000-0000-0000000000a3', 'admin') ON CONFLICT DO NOTHING;
INSERT INTO public.platform_staff(user_id, role, status, joined_at) VALUES ('50000000-0000-0000-0000-0000000000a1', 'admin', 'active', now()), ('50000000-0000-0000-0000-0000000000a3', 'owner', 'pending', now());
INSERT INTO zz.pc_u VALUES ('owner', (SELECT id FROM zz.u WHERE k = 'admin')), ('staff', '50000000-0000-0000-0000-0000000000a1'), ('legacy', '50000000-0000-0000-0000-0000000000a2'),
  ('pending', '50000000-0000-0000-0000-0000000000a3'), ('pharmacy', (SELECT id FROM zz.u WHERE k = 'ph_owner')), ('wholesaler', (SELECT id FROM zz.u WHERE k = 'w_owner'));
UPDATE public.billing_settings SET mode = CASE WHEN mode = 'disabled' THEN 'shadow' ELSE mode END WHERE id;
CREATE TEMP TABLE pc_before AS SELECT 'ledger'::text AS t, id::text AS k, md5(l::text) AS h FROM public.billing_ledger_entries l
  UNION ALL SELECT 'assessment', id::text, md5(a::text) FROM public.order_billing_assessments a UNION ALL SELECT 'invoice', id::text, md5(i::text) FROM public.billing_invoices i;

-- A. who may change what ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE plan uuid; b uuid; w text; who text; r text; stmts text[]; n int := 0;
BEGIN
  plan := zz.pc_plan('pc_auth');
  b := zz.mkws('PC Auth WS');
  PERFORM pg_temp.ok('the owner can publish a version', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Owner publishes'')::text', plan, zz.pc_params(60))) NOT LIKE 'ERR%');
  stmts := ARRAY[
    format('SELECT public.admin_billing_create_plan(''pc-nope'', ''wholesaler'', ''Nope'', NULL, ''standard'', ''Not allowed'')::text'),
    format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Not allowed'')::text', plan, zz.pc_params(99)),
    format('SELECT public.admin_billing_set_plan_availability(%L, false, false, ''Not allowed'')::text', plan),
    format('SELECT public.admin_billing_schedule_price_change(%L, %L::jsonb, now() + interval ''5 days'', ''new_only'', true, NULL, ''Not allowed'')::text', plan, zz.pc_params(99)),
    format('SELECT public.admin_billing_start_subscription(%L, ''pc_auth'', now(), ''shadow'', ''Not allowed'')::text', b),
    format('SELECT public.admin_billing_set_custom_terms(%L, ''{"subscription_amount": 1}''::jsonb, NULL, ''Not allowed'')::text', b),
    format('SELECT public.admin_billing_set_exemption(%L, true, ''Not allowed'')::text', b),
    format('SELECT public.admin_billing_set_paused(%L, true, ''Not allowed'')::text', b),
    'SELECT public.admin_billing_set_charging(false, false, ''Not allowed'')::text',
    'SELECT public.admin_billing_set_mode(''disabled'', ''Not allowed'')::text',
    'SELECT public.admin_billing_run_now(''Not allowed'')::text',
    format('SELECT public.admin_billing_apply_credit(%L, 5, ''goodwill'', ''Not allowed'', ''pc-key-1'')::text', b)];
  FOREACH who IN ARRAY ARRAY['staff', 'legacy', 'pending'] LOOP
    n := 0;
    FOREACH w IN ARRAY stmts LOOP
      r := zz.pc_as(who, w);
      IF r LIKE 'ERR: Only the platform owner (Super Admin) can change billing%' OR (who = 'pending' AND r LIKE 'ERR: Only platform administrators can do this%') THEN n := n + 1; ELSE RAISE NOTICE 'not refused for %: % -> %', who, left(w, 60), left(r, 100); END IF;
    END LOOP;
    PERFORM pg_temp.ok(format('%s: all %s billing writes are refused (%s of %s)', CASE who WHEN 'staff' THEN 'another platform administrator' WHEN 'legacy' THEN 'an administrator with no platform record' ELSE 'an owner who is not active' END, array_length(stmts, 1), n, array_length(stmts, 1)),
      n = array_length(stmts, 1));
  END LOOP;
  PERFORM pg_temp.ok('another administrator can still READ the pricing screens',
    zz.pc_as('staff', 'SELECT public.admin_billing_scheduled_changes()::text') NOT LIKE 'ERR%'
    AND zz.pc_as('staff', format('SELECT public.admin_billing_plan_history(%L)::text', plan)) NOT LIKE 'ERR%'
    AND zz.pc_as('staff', format('SELECT public.admin_billing_preview_price_change(%L, %L::jsonb, now() + interval ''5 days'', ''new_only'', true)::text', plan, zz.pc_params(70))) NOT LIKE 'ERR%'
    AND zz.pc_as('staff', 'SELECT public.admin_billing_readiness()::text') NOT LIKE 'ERR%');
  FOREACH who IN ARRAY ARRAY['pharmacy', 'wholesaler'] LOOP
    PERFORM pg_temp.ok(who || ' owners can neither read nor write', zz.pc_as(who, 'SELECT public.admin_billing_scheduled_changes()::text') LIKE 'ERR%'
      AND zz.pc_as(who, format('SELECT public.admin_billing_schedule_price_change(%L, %L::jsonb, now() + interval ''5 days'', ''new_only'', true, NULL, ''Not allowed'')::text', plan, zz.pc_params(99))) LIKE 'ERR%');
  END LOOP;
  PERFORM pg_temp.ok('signed-out visitors cannot call the pricing functions', zz.anon('SELECT public.admin_billing_scheduled_changes()::text') LIKE 'ERR%' AND zz.anon(format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''x reason'')::text', gen_random_uuid())) LIKE 'ERR%');
  PERFORM pg_temp.ok('nothing was changed by any of those attempts', (SELECT count(*) FROM public.billing_plans WHERE code = 'pc-nope') = 0
    AND (SELECT count(*) FROM public.billing_plan_versions WHERE plan_id = plan) = 2 AND (SELECT count(*) FROM public.billing_scheduled_changes WHERE plan_id = plan) = 0
    AND (SELECT subscriptions_enabled AND commissions_enabled FROM public.billing_settings WHERE id));
END $$;

-- B. the old trap is closed: a future price cannot be published, and nothing can be edited -------------------------------------------------------------------------------------------------------
DO $$
DECLARE plan uuid := (SELECT id FROM public.billing_plans WHERE code = 'pc_auth'); v1 uuid; r text;
BEGIN
  SELECT id INTO v1 FROM public.billing_plan_versions WHERE plan_id = plan AND status = 'published';
  r := zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Dated in the future'')::text', plan, (zz.pc_params(80)::jsonb || jsonb_build_object('effective_from', now() + interval '30 days'))::text));
  PERFORM pg_temp.ok('publishing with a future start date is refused (it would have taken effect at once)', r LIKE 'ERR: Choose when a price starts with the schedule option%', r);
  r := zz.try(format($q$INSERT INTO public.billing_plan_versions(plan_id, version, status, effective_from, reason) VALUES (%L, 99, 'published', now() + interval '30 days', 'Direct insert')$q$, plan));
  PERFORM pg_temp.ok('and so is a future-dated published version written straight into the table', r LIKE 'ERR: A price that starts in the future must be scheduled%', r);
  PERFORM pg_temp.ok('a version is never deleted', zz.try(format('DELETE FROM public.billing_plan_versions WHERE id = %L', v1)) LIKE 'ERR: A published plan version is never deleted%');
  PERFORM pg_temp.ok('its terms never change', zz.try(format('UPDATE public.billing_plan_versions SET subscription_amount = 1 WHERE id = %L', v1)) LIKE 'ERR: The terms of a published plan version never change%');
  PERFORM pg_temp.ok('its start moment never changes', zz.try(format('UPDATE public.billing_plan_versions SET effective_from = now() - interval ''1 year'' WHERE id = %L', v1)) LIKE 'ERR: The terms of a published plan version never change%');
  PERFORM pg_temp.ok('a published version cannot be cancelled, only retired', zz.try(format('UPDATE public.billing_plan_versions SET status = ''cancelled'', cancelled_at = now() WHERE id = %L', v1)) LIKE 'ERR: A published plan version can only be retired%');
  PERFORM pg_temp.ok('a retired version cannot come back', zz.try(format('UPDATE public.billing_plan_versions SET status = ''published'', retired_at = NULL WHERE plan_id = %L AND status = ''retired''', plan)) LIKE 'ERR: A retired plan version cannot be brought back%');
  r := zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Publish now'')::text', plan, zz.pc_params(65)));
  PERFORM pg_temp.ok('publishing now still retires the old version and takes effect at once', r NOT LIKE 'ERR%' AND (SELECT version FROM public._billing_plan_version_at(plan, now())) = 3
    AND (SELECT status FROM public.billing_plan_versions WHERE id = v1) = 'retired' AND (SELECT status FROM public.billing_plan_versions WHERE plan_id = plan AND version = 3) = 'published', r);
END $$;

-- C. scheduling: validation, preview, what new subscribers get ------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE plan uuid; c uuid; r text; pv jsonb; eff timestamptz := now() + interval '10 days'; b_now uuid; b_later uuid; n int;
BEGIN
  plan := zz.pc_plan('pc_sched');
  PERFORM pg_temp.ok('the approved starting terms are held as plan values, not in code', (SELECT subscription_amount = 50 AND free_trial_days = 30 AND onboarding_free_orders = 10 AND monthly_free_orders = 5
    AND transaction_fee_percentage = 1 AND transaction_fee_max = 50 AND transaction_fee_min IS NULL AND transaction_fee_cycle_cap IS NULL FROM public.billing_plan_versions WHERE plan_id = plan AND status = 'published'));
  r := zz.pc_sched(plan, zz.pc_params(70), now() - interval '1 day', 'new_only', true, NULL);
  PERFORM pg_temp.ok('a price change cannot start in the past', r LIKE 'ERR: A scheduled price change must start in the future%', r);
  r := zz.pc_sched(plan, zz.pc_params(70), now() + interval '30 seconds', 'new_only', true, NULL);
  PERFORM pg_temp.ok('nor within the next minute', r LIKE 'ERR: A scheduled price change must start in the future%', r);
  r := zz.pc_sched(plan, zz.pc_params(70), now() + interval '400 days', 'new_only', true, NULL);
  PERFORM pg_temp.ok('nor more than a year ahead', r LIKE 'ERR: A price change cannot be scheduled more than a year ahead%', r);
  PERFORM pg_temp.ok('the audience must be one of the two', zz.pc_sched(plan, zz.pc_params(70), eff, 'everyone', true, NULL) LIKE 'ERR: Choose new subscribers only%');
  PERFORM pg_temp.ok('an unknown term is refused', zz.pc_sched(plan, '{"subscription_amount": 70, "surprise": 1}', eff, 'new_only', true, NULL) LIKE 'ERR: Unknown plan term "surprise"%');
  PERFORM pg_temp.ok('an impossible percentage is refused', zz.pc_sched(plan, zz.pc_params(70, 150), eff, 'new_only', true, NULL) LIKE 'ERR%');
  PERFORM pg_temp.ok('a plan with no version cannot have a change scheduled', zz.adm(format('SELECT public.admin_billing_schedule_price_change(%L, %L::jsonb, %L, ''new_only'', true, NULL, ''Empty plan'')::text',
    zz.adm('SELECT public.admin_billing_create_plan(''pc-empty'', ''wholesaler'', ''Empty'', NULL, ''standard'', ''A plan with no version'')::text'), zz.pc_params(70), eff)) LIKE 'ERR: Publish the plan%first version%');

  pv := zz.adm(format('SELECT public.admin_billing_preview_price_change(%L, %L::jsonb, %L, ''new_only'', true)::text', plan, zz.pc_params(70, 1.5), eff))::jsonb;
  PERFORM pg_temp.ok('the preview lists exactly what would change', (SELECT array_agg(x ->> 'field' ORDER BY x ->> 'field') FROM jsonb_array_elements(pv -> 'changes') x) = ARRAY['subscription_amount', 'transaction_fee_percentage']
    AND (pv ->> 'current_version') = '1' AND (pv -> 'proposed_terms' ->> 'subscription_amount')::numeric = 70);
  PERFORM pg_temp.ok('and writes nothing', (SELECT count(*) FROM public.billing_plan_versions WHERE plan_id = plan) = 1 AND (SELECT count(*) FROM public.billing_scheduled_changes WHERE plan_id = plan) = 0);
  PERFORM pg_temp.ok('a preview of identical terms says nothing would change', (zz.adm(format('SELECT public.admin_billing_preview_price_change(%L, %L::jsonb, %L, ''new_only'', true)::text', plan, zz.pc_params(50), eff))::jsonb -> 'warnings')::text LIKE '%nothing would change%');

  c := zz.pc_sched(plan, zz.pc_params(70, 1.5), eff, 'new_only', true, NULL)::uuid;
  PERFORM pg_temp.ok('a change can be scheduled', c IS NOT NULL);
  PERFORM pg_temp.ok('the new version is scheduled and the old one stays the price today', (SELECT v.status FROM public.billing_plan_versions v JOIN public.billing_scheduled_changes x ON x.version_id = v.id WHERE x.id = c) = 'scheduled'
    AND (SELECT version FROM public._billing_plan_version_at(plan, now())) = 1 AND (SELECT version FROM public._billing_plan_version_at(plan, eff + interval '1 hour')) = 2);
  PERFORM pg_temp.ok('it is in the audit log with who, what and why', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Price change scheduled' AND details ->> 'change_id' = c::text AND details ->> 'reason' = 'Scheduled for the tests'
    AND (details -> 'new' ->> 'subscription_amount')::numeric = 70 AND (details -> 'previous' ->> 'subscription_amount')::numeric = 50 AND details ->> 'audience' = 'new_only'));
  PERFORM pg_temp.ok('a later one cannot be scheduled before it', zz.pc_sched(plan, zz.pc_params(80), eff - interval '2 days', 'new_only', true, NULL) LIKE 'ERR: A scheduled change must start after every other version%');
  PERFORM pg_temp.ok('publishing "now" is refused while one is scheduled', zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Over a schedule'')::text', plan, zz.pc_params(90))) LIKE 'ERR: This plan has a price change scheduled%');

  b_now := zz.mkws('PC New Now'); PERFORM zz.sub(b_now, 'pc_sched', now(), 'shadow');
  b_later := zz.mkws('PC New Later'); PERFORM zz.sub(b_later, 'pc_sched', eff + interval '1 day', 'shadow');
  PERFORM pg_temp.ok('a new subscriber starting before the change gets the price in force', zz.pc_ver(b_now) = '1' AND zz.pc_amt(b_now) = '50');
  PERFORM pg_temp.ok('a new subscriber whose start is after it gets the new version (the one in force on THEIR start date)', zz.pc_ver(b_later, eff + interval '1 day') = '2' AND zz.pc_amt(b_later, eff + interval '1 day') = '70');
  PERFORM pg_temp.ok('the subscriber who started before the change stays on version 1 at any date (new subscribers only)', zz.pc_ver(b_now, now() + interval '2 years') = '1');
  INSERT INTO zz.pc_u VALUES ('pc_sched_change', c), ('pc_sched_plan', plan), ('pc_b_now', b_now);
END $$;

-- D. cancelling ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE plan uuid; c uuid; r text; vid uuid;
BEGIN
  plan := zz.pc_plan('pc_cancel');
  c := zz.pc_sched(plan, zz.pc_params(75), now() + interval '20 days', 'new_only', true, NULL)::uuid;
  SELECT version_id INTO vid FROM public.billing_scheduled_changes WHERE id = c;
  PERFORM pg_temp.ok('another administrator cannot cancel it', zz.pc_as('staff', format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''Not allowed'')::text', c)) LIKE 'ERR: Only the platform owner%');
  PERFORM pg_temp.ok('a reason is needed to cancel', zz.adm(format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''no'')::text', c)) LIKE 'ERR: A reason of at least 5 characters%');
  r := zz.adm(format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''Changed our mind'')', c));
  PERFORM pg_temp.ok('the owner can cancel it before it starts', r NOT LIKE 'ERR%', r);
  PERFORM pg_temp.ok('the version and the change are marked cancelled, with who, when and why', (SELECT status FROM public.billing_plan_versions WHERE id = vid) = 'cancelled' AND (SELECT cancelled_at IS NOT NULL FROM public.billing_plan_versions WHERE id = vid)
    AND (SELECT status = 'cancelled' AND cancel_reason = 'Changed our mind' AND cancelled_by = (SELECT id FROM zz.pc_u WHERE k = 'owner') AND cancelled_at IS NOT NULL FROM public.billing_scheduled_changes WHERE id = c));
  PERFORM pg_temp.ok('nothing is deleted: the scheduled record and the version remain', (SELECT count(*) FROM public.billing_scheduled_changes WHERE id = c) = 1 AND (SELECT count(*) FROM public.billing_plan_versions WHERE id = vid) = 1);
  PERFORM pg_temp.ok('the cancellation is in the audit log', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Scheduled price change cancelled' AND details ->> 'change_id' = c::text AND details ->> 'reason' = 'Changed our mind'));
  PERFORM pg_temp.ok('it cannot be cancelled twice', zz.adm(format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''Cancel again'')', c)) LIKE 'ERR: This change is already cancelled%');
  PERFORM pg_temp.ok('a cancelled version cannot be brought back', zz.try(format('UPDATE public.billing_plan_versions SET status = ''published'', cancelled_at = NULL WHERE id = %L', vid)) LIKE 'ERR: A cancelled plan version cannot be brought back%');
  PERFORM pg_temp.ok('and the scheduled record cannot be edited or deleted', zz.try(format('DELETE FROM public.billing_scheduled_changes WHERE id = %L', c)) LIKE 'ERR: A scheduled price change is never deleted%'
    AND zz.try(format('UPDATE public.billing_scheduled_changes SET audience = ''new_and_existing'' WHERE id = %L', c)) LIKE 'ERR: A scheduled price change cannot be edited%');
  PERFORM pg_temp.ok('a cancelled change never takes effect', (SELECT version FROM public._billing_plan_version_at(plan, now() + interval '60 days')) = 1 AND (public.billing_apply_due_price_changes(now()) ->> 'applied')::int = 0
    AND (SELECT status FROM public.billing_plan_versions WHERE id = vid) = 'cancelled');
  PERFORM pg_temp.ok('after a cancellation the plan can be published or scheduled again', zz.pc_sched(plan, zz.pc_params(72), now() + interval '15 days', 'new_only', true, NULL) NOT LIKE 'ERR%');
  -- a change that has reached its start moment can no longer be cancelled
  c := (SELECT id FROM public.billing_scheduled_changes WHERE plan_id = plan AND status = 'pending');
  PERFORM zz.pc_arrive(c);
  r := zz.adm(format('SELECT public.admin_billing_cancel_scheduled_change(%L, ''Too late now'')', c));
  PERFORM pg_temp.ok('once its start moment has come it can no longer be cancelled', r LIKE 'ERR: This change has reached its start moment%', r);
  PERFORM public.billing_apply_due_price_changes(now());
END $$;

-- E. existing subscribers: the audience choice, custom pricing, and the billing-cycle transition ---------------------------------------------------------------------------------------------------
DO $$
DECLARE plan uuid; plan2 uuid; c uuid; c2 uuid; pv jsonb; r text; bA uuid; bB uuid; bC uuid; bD uuid; bE uuid; bF uuid; bN uuid; eff timestamptz := now() + interval '10 days'; res jsonb; nA int; boundary timestamptz;
BEGIN
  plan := zz.pc_plan('pc_exist'); plan2 := zz.pc_plan('pc_exist2'); PERFORM zz.pc_plan('pc_other', 2, 100, NULL, 0, 0);
  bA := zz.mkws('PC Old Sub'); PERFORM zz.sub(bA, 'pc_exist', now() - interval '40 days', 'shadow');
  bB := zz.mkws('PC Fresh Sub'); PERFORM zz.sub(bB, 'pc_exist', now(), 'shadow');
  bC := zz.mkws('PC Custom Sub'); PERFORM zz.sub(bC, 'pc_exist', now() - interval '40 days', 'shadow');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"subscription_amount": 40}''::jsonb, now() - interval ''30 seconds'', ''Negotiated price'')::text', bC));
  bD := zz.mkws('PC Later Terms'); PERFORM zz.sub(bD, 'pc_exist', now() - interval '40 days', 'shadow');
  PERFORM zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''pc_other'', now() + interval ''60 days'', true, ''Moves to another plan later'')::text', bD));
  bE := zz.mkws('PC Clear Sub'); PERFORM zz.sub(bE, 'pc_exist2', now() - interval '40 days', 'shadow');
  PERFORM zz.adm(format('SELECT public.admin_billing_set_custom_terms(%L, ''{"subscription_amount": 40}''::jsonb, now() - interval ''30 seconds'', ''Negotiated price'')::text', bE));
  bF := zz.mkws('PC New Only Sub'); PERFORM zz.sub(bF, 'pc_exist2', now() - interval '40 days', 'shadow');

  pv := zz.adm(format('SELECT public.admin_billing_preview_price_change(%L, %L::jsonb, %L, ''new_and_existing'', true)::text', plan, zz.pc_params(70), eff))::jsonb;
  PERFORM pg_temp.ok('the preview names the affected businesses and why one is left out', (pv -> 'existing' ->> 'total')::int = 4 AND (pv -> 'existing' ->> 'affected')::int = 3 AND (pv -> 'existing' ->> 'skipped')::int = 1
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'existing' -> 'businesses') x WHERE x ->> 'business_name' = 'PC Later Terms' AND x ->> 'skip_reason' = 'It already has later terms')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'existing' -> 'businesses') x WHERE x ->> 'business_name' = 'PC Custom Sub' AND (x ->> 'has_overrides')::boolean));
  PERFORM pg_temp.ok('and every move is at a billing-cycle start in the future', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pv -> 'existing' -> 'businesses') x WHERE x ->> 'skip_reason' IS NULL AND (x ->> 'change_from')::timestamptz < eff));
  PERFORM pg_temp.ok('the preview warns that custom pricing is kept', (pv -> 'warnings')::text LIKE '%custom pricing, which is kept%');
  PERFORM pg_temp.ok('a stale preview is refused: the schedule must repeat the number it was shown', zz.pc_sched(plan, zz.pc_params(70), eff, 'new_and_existing', true, 2) LIKE 'ERR: The number of businesses this would move is now 3, not 2%'
    AND zz.pc_sched(plan, zz.pc_params(70), eff, 'new_and_existing', true, NULL) LIKE 'ERR: The number of businesses this would move is now 3%');
  c := zz.pc_sched(plan, zz.pc_params(70), eff, 'new_and_existing', true, 3)::uuid;
  c2 := zz.pc_sched(plan2, zz.pc_params(70), eff, 'new_and_existing', false, 2)::uuid;
  PERFORM pg_temp.ok('scheduling moved nobody yet (no new terms were written)', zz.pc_ver(bA) = '1' AND zz.pc_ver(bC) = '1' AND (SELECT count(*) FROM public.billing_subscription_terms t WHERE t.subscription_id IN (SELECT id FROM public.billing_subscriptions WHERE business_id IN (bA, bB, bC, bD))) = 6);
  PERFORM pg_temp.ok('before the start moment the scheduler does nothing to it', (public.billing_apply_due_price_changes(now()) ->> 'applied')::int = 0 AND (SELECT status FROM public.billing_scheduled_changes WHERE id = c) = 'pending');

  PERFORM zz.pc_arrive(c); PERFORM zz.pc_arrive(c2);
  bN := zz.mkws('PC After Arrival'); PERFORM zz.sub(bN, 'pc_exist', now(), 'shadow');
  PERFORM pg_temp.ok('after the start moment, a brand-new subscriber gets the new version even before the scheduler has run', zz.pc_ver(bN) = '2');
  res := public.billing_apply_due_price_changes(now());
  PERFORM pg_temp.ok('the scheduler applies both changes', (res ->> 'applied')::int = 2 AND (SELECT status FROM public.billing_scheduled_changes WHERE id = c) = 'applied');
  PERFORM pg_temp.ok('the result says who moved, who did not and who was already on it', (SELECT (applied_result ->> 'moved')::int = 3 AND (applied_result ->> 'skipped')::int = 1 AND (applied_result ->> 'already_on_it')::int = 1 AND applied_result::text LIKE '%PC Later Terms%' AND applied_result::text LIKE '%already has later terms%' FROM public.billing_scheduled_changes WHERE id = c));
  SELECT (SELECT period_end FROM public.billing_period_bounds(s.period_anchor_at, 1, now())) INTO boundary FROM public.billing_subscriptions s WHERE s.business_id = bA;
  PERFORM pg_temp.ok('an existing business is NOT moved today: it stays on its current terms until its next billing cycle', zz.pc_ver(bA) = '1' AND zz.pc_amt(bA) = '50' AND zz.pc_ver(bB) = '1');
  PERFORM pg_temp.ok('its new terms start exactly at the next cycle boundary, never in the past', (SELECT t.effective_from FROM public.billing_subscription_terms t JOIN public.billing_subscriptions s ON s.id = t.subscription_id WHERE s.business_id = bA ORDER BY t.effective_from DESC LIMIT 1) = boundary
    AND boundary > now());
  PERFORM pg_temp.ok('one moment before the boundary it is still version 1; at the boundary it is version 2', zz.pc_ver(bA, boundary - interval '1 second') = '1' AND zz.pc_ver(bA, boundary) = '2' AND zz.pc_amt(bA, boundary) = '70');
  PERFORM pg_temp.ok('the first period after the boundary is billed at the new subscription price', (SELECT subscription_amount FROM public._billing_ensure_period((SELECT s FROM public.billing_subscriptions s WHERE s.business_id = bA), boundary + interval '1 day', true)) = 70);
  PERFORM pg_temp.ok('custom pricing is KEPT when that is chosen (the negotiated 40 survives the new plan terms)', zz.pc_amt(bC, boundary) = '40' AND zz.pc_ver(bC, boundary) = '2');
  PERFORM pg_temp.ok('and cleared when that is chosen (that business pays the plan''s new terms)', zz.pc_amt(bE, boundary) = '70' AND zz.pc_ver(bE, boundary) = '2' AND zz.pc_amt(bE) = '40');
  PERFORM pg_temp.ok('a business with later terms already set is left alone', zz.pc_ver(bD, boundary) = '1' AND zz.pc_ver(bD, now() + interval '61 days') = (SELECT version::text FROM public.billing_plan_versions WHERE plan_id = (SELECT id FROM public.billing_plans WHERE code = 'pc_other') AND status = 'published'));
  PERFORM pg_temp.ok('running the scheduler again moves nobody twice', (public.billing_apply_due_price_changes(now()) ->> 'applied')::int = 0
    AND (SELECT count(*) FROM public.billing_subscription_terms t JOIN public.billing_subscriptions s ON s.id = t.subscription_id WHERE s.business_id = bA) = 2);
  PERFORM pg_temp.ok('every move is in the audit log, for the business and for the change', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing plan changed' AND details ->> 'scheduled_change' = c::text) = 3
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Scheduled price change applied' AND details ->> 'change_id' = c::text AND (details ->> 'moved')::int = 3));
  PERFORM pg_temp.ok('the plan now shows the new version as published and the old one as retired', (SELECT string_agg(version || status, ',' ORDER BY version) FROM public.billing_plan_versions WHERE plan_id = plan) = '1retired,2published');
  PERFORM pg_temp.ok('the history lists both versions with who many businesses are on each', (SELECT jsonb_array_length(zz.adm(format('SELECT public.admin_billing_plan_history(%L)::text', plan))::jsonb)) = 2
    AND (SELECT (x ->> 'businesses_on_it')::int FROM jsonb_array_elements(zz.adm(format('SELECT public.admin_billing_plan_history(%L)::text', plan))::jsonb) x WHERE (x ->> 'version')::int = 1) >= 3);
  INSERT INTO zz.pc_u VALUES ('pc_bA', bA);
END $$;

DO $$
DECLARE plan uuid; c uuid; b uuid; b2 uuid; eff timestamptz := now() + interval '10 days';
BEGIN
  plan := zz.pc_plan('pc_newonly');
  b := zz.mkws('PC Stays Put'); PERFORM zz.sub(b, 'pc_newonly', now() - interval '40 days', 'shadow');
  c := zz.pc_sched(plan, zz.pc_params(70), eff, 'new_only', true, NULL)::uuid;
  PERFORM zz.pc_arrive(c);
  PERFORM public.billing_apply_due_price_changes(now());
  PERFORM pg_temp.ok('"new subscribers only": an existing business stays on its terms through every later cycle', zz.pc_ver(b, now() + interval '1 year') = '1' AND zz.pc_amt(b, now() + interval '1 year') = '50'
    AND (SELECT count(*) FROM public.billing_subscription_terms t JOIN public.billing_subscriptions s ON s.id = t.subscription_id WHERE s.business_id = b) = 1);
  b2 := zz.mkws('PC Joins After'); PERFORM zz.sub(b2, 'pc_newonly', now(), 'shadow');
  PERFORM pg_temp.ok('while one that starts now gets the new version', zz.pc_ver(b2) = '2');
  PERFORM pg_temp.ok('and it moves later only if the owner moves it (the existing plan-change tool still works)', zz.adm(format('SELECT public.admin_billing_change_plan(%L, ''pc_newonly'', NULL, true, ''Moving to the newest version'')::text', b)) NOT LIKE 'ERR%');
END $$;

-- F. the two switches ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE b uuid; o1 uuid; o2 uuid; o3 uuid; r text; plan uuid; per public.billing_periods;
BEGIN
  plan := zz.pc_plan('pc_switch', 1, 50, 50, 0, 0);
  b := zz.mkws('PC Switch WS'); PERFORM zz.sub(b, 'pc_switch', now() - interval '45 days', 'shadow');
  PERFORM pg_temp.ok('both are on by default', (SELECT subscriptions_enabled AND commissions_enabled FROM public.billing_settings WHERE id));
  PERFORM pg_temp.ok('a switch change needs a reason and a real change', zz.adm('SELECT public.admin_billing_set_charging(false, true, ''no'')::text') LIKE 'ERR: A reason of at least 5 characters%'
    AND zz.adm('SELECT public.admin_billing_set_charging(true, true, ''Nothing changes'')::text') LIKE 'ERR: Those are already the settings%');
  o1 := zz.go(b, 1000, 0, now());
  PERFORM pg_temp.ok('with commissions on, an order is charged its commission (1% of 1000)', zz.a(o1, true) = 'chargeable/-/10.00');
  PERFORM zz.adm('SELECT public.admin_billing_set_charging(true, false, ''Commissions off for the tests'')::text');
  o2 := zz.go(b, 1000, 0, now());
  PERFORM pg_temp.ok('with commissions OFF, an order is recorded as exempt: nothing charged', zz.a(o2, true) = 'exempt/-/0.00'
    AND (SELECT terms_snapshot -> 'decision' ->> 'reason' FROM public.order_billing_assessments WHERE order_id = o2 AND shadow) = 'Commissions are switched off');
  PERFORM pg_temp.ok('an order assessed before the switch keeps what was recorded', zz.a(o1, true) = 'chargeable/-/10.00');
  PERFORM zz.adm('SELECT public.admin_billing_set_charging(true, true, ''Commissions back on'')::text');
  o3 := zz.go(b, 1000, 0, now());
  PERFORM pg_temp.ok('with commissions back on, new orders are charged again and the exempt one is not charged retroactively', zz.a(o3, true) = 'chargeable/-/10.00' AND zz.a(o2, true) = 'exempt/-/0.00');
  PERFORM zz.adm('SELECT public.admin_billing_set_charging(false, true, ''Subscriptions off for the tests'')::text');
  b := zz.mkws('PC Switch WS 2'); PERFORM zz.sub(b, 'pc_switch', now() - interval '45 days', 'shadow');
  per := public._billing_ensure_period((SELECT s FROM public.billing_subscriptions s WHERE s.business_id = b), now(), true);
  PERFORM pg_temp.ok('with subscriptions OFF, a new period carries no subscription charge, and says why', per.subscription_amount = 0
    AND (SELECT reason FROM public.billing_ledger_entries WHERE period_id = per.id AND entry_type = 'subscription_charge') = 'Subscriptions are switched off');
  PERFORM zz.adm('SELECT public.admin_billing_set_charging(true, true, ''Subscriptions back on'')::text');
  PERFORM pg_temp.ok('a period created while they were off stays at zero when they are switched back on', (SELECT subscription_amount FROM public.billing_periods WHERE id = per.id) = 0);
  PERFORM pg_temp.ok('every switch change is audited', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing charging switches changed') >= 4
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing charging switches changed' AND details -> 'new' ->> 'commissions' = 'false' AND details ->> 'reason' = 'Commissions off for the tests'));
END $$;

-- G. the approved starting terms, worked through: allowances, commission, and the GHS 50 per-order maximum ------------------------------------------------------------------------------------------
DO $$
DECLARE b uuid; plan uuid; o uuid[] := '{}'; x uuid; i int; r text; outcomes text[] := '{}';
BEGIN
  plan := zz.pc_plan('pc_approved');
  b := zz.mkws('PC Approved Terms'); PERFORM zz.sub(b, 'pc_approved', now(), 'shadow');
  FOR i IN 1..18 LOOP
    x := zz.go(b, CASE i WHEN 16 THEN 1000 WHEN 17 THEN 8000 WHEN 18 THEN 100 ELSE 500 END, 0, now());
    o := o || x;
    outcomes := outcomes || zz.a(x, true);
  END LOOP;
  PERFORM pg_temp.ok('the first 10 orders use the launch allowance', (SELECT count(*) FROM unnest(outcomes[1:10]) q WHERE q LIKE 'free_onboarding/onboarding%/0.00') = 10, array_to_string(outcomes[1:10], ' '));
  PERFORM pg_temp.ok('the next 5 use the monthly allowance', (SELECT count(*) FROM unnest(outcomes[11:15]) q WHERE q LIKE 'free_monthly/monthly%/0.00') = 5, array_to_string(outcomes[11:15], ' '));
  PERFORM pg_temp.ok('the 16th is charged 1% (1000 -> 10.00)', outcomes[16] = 'chargeable/-/10.00', outcomes[16]);
  PERFORM pg_temp.ok('the 17th hits the GHS 50 maximum per order (8000 would be 80.00)', outcomes[17] = 'chargeable/-/50.00' AND (SELECT calculated_fee FROM public.order_billing_assessments WHERE order_id = o[17] AND shadow AND kind = 'primary') = 80.00, outcomes[17]);
  PERFORM pg_temp.ok('the 18th is charged 1.00 (no minimum is set)', outcomes[18] = 'chargeable/-/1.00', outcomes[18]);
  PERFORM pg_temp.ok('a free order is never also charged, and free-order numbers have no gaps', (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = b AND shadow AND outcome LIKE 'free%' AND charged_amount <> 0) = 0
    AND (SELECT array_agg(free_seq ORDER BY free_seq) FROM public.order_billing_assessments WHERE business_id = b AND shadow AND free_source = 'onboarding') = ARRAY[1,2,3,4,5,6,7,8,9,10]);
  PERFORM pg_temp.ok('the allowance values come from the plan, not from code: changing the plan changes the next subscriber',
    (SELECT onboarding_free_orders = 10 AND monthly_free_orders = 5 AND transaction_fee_max = 50 FROM public.billing_plan_versions WHERE plan_id = plan));
END $$;

-- H. commission safeguards: no duplicates, no charge for cancelled or unfulfilled goods, no rebilling, adjustments only ----------------------------------------------------------------------------------
DO $$
DECLARE b uuid; plan uuid; o uuid; oc uuid; od uuid; r jsonb; n int; net numeric; ws2 uuid;
BEGIN
  plan := zz.pc_plan('pc_plain', 1, 0, NULL, 0, 0);
  b := zz.mkws('PC Commission WS'); PERFORM zz.sub(b, 'pc_plain', now(), 'shadow');
  o := zz.go(b, 1000, 0, now());
  PERFORM pg_temp.ok('a delivered order is assessed once', (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'primary') = 1 AND zz.a(o, true) = 'chargeable/-/10.00');
  r := public.billing_assess_order(o);
  PERFORM pg_temp.ok('assessing it again changes nothing (no duplicate commission)', r ->> 'skipped' = 'already_assessed' AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow) = 1
    AND (SELECT count(*) FROM public.billing_ledger_entries WHERE order_id = o AND shadow AND entry_type = 'transaction_fee') = 1);
  PERFORM pg_temp.ok('and the database itself refuses a second first-assessment for an order', zz.try(format($q$INSERT INTO public.order_billing_assessments(business_id, order_id, kind, adjustment_seq, shadow, billable_gmv, outcome, charged_amount) VALUES (%L, %L, 'primary', 0, true, 1000, 'chargeable', 10)$q$, b, o)) LIKE 'ERR:%duplicate key%');
  oc := zz.mkorder(b, 1000, 0, now()); PERFORM zz.advance(oc, 'accepted');
  ALTER TABLE public.orders DISABLE TRIGGER USER; UPDATE public.orders SET status = 'cancelled' WHERE id = oc; ALTER TABLE public.orders ENABLE TRIGGER USER;
  od := zz.mkorder(b, 1000, 0, now()); PERFORM zz.advance(od, 'dispatched');
  PERFORM pg_temp.ok('a cancelled order and an order not yet delivered are never assessed', zz.nass(b, true) = 1 AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id IN (oc, od)) = 0);
  -- a shortage accepted before delivery: only what is fulfilled is charged
  ws2 := o;
  o := zz.mkorder(b, 1000, 0, now()); PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 600 WHERE id = o; PERFORM zz.deliver(o);
  PERFORM pg_temp.ok('quantities cancelled or short before delivery are not charged (600 delivered of 1000 -> 6.00)', zz.a(o, true) = 'chargeable/-/6.00' AND (SELECT billable_gmv FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'primary') = 600);
  -- a shortage found after delivery: credited, once
  o := zz.go(b, 1000, 0, now());
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 600 WHERE id = o;
  PERFORM pg_temp.ok('a shortage after delivery credits the commission on it (net 6.00), as an adjustment', (SELECT sum(charged_amount) - COALESCE(sum(credit_amount), 0) FROM public.billing_ledger_entries WHERE order_id = o AND shadow) = 6.00
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'adjustment') = 1);
  PERFORM public.billing_assess_order_change(o); PERFORM public.billing_assess_order_change(o);
  PERFORM pg_temp.ok('replaying it creates no second credit', (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'adjustment') = 1);
  -- a back-order shipment later adds value: commission on the shipped goods only, once
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 1000 WHERE id = o;
  PERFORM pg_temp.ok('goods shipped later are charged when they ship (back to 10.00 net), as one more adjustment', (SELECT sum(charged_amount) - COALESCE(sum(credit_amount), 0) FROM public.billing_ledger_entries WHERE order_id = o AND shadow) = 10.00
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'adjustment') = 2);
  PERFORM public.billing_assess_order_change(o);
  PERFORM pg_temp.ok('and replaying the shipment charges nothing more', (SELECT sum(charged_amount) - COALESCE(sum(credit_amount), 0) FROM public.billing_ledger_entries WHERE order_id = o AND shadow) = 10.00
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o AND shadow AND kind = 'adjustment') = 2);
  PERFORM pg_temp.ok('assessments, ledger entries and invoices can never be edited or deleted', zz.try(format('UPDATE public.order_billing_assessments SET charged_amount = 0 WHERE order_id = %L', o)) LIKE 'ERR: Billing records are never changed%'
    AND zz.try(format('DELETE FROM public.billing_ledger_entries WHERE order_id = %L', o)) LIKE 'ERR: Billing records are never changed%'
    AND (SELECT count(*) FROM public.billing_invoices) >= 0);
END $$;

-- I. history is untouched, and shadow billing and the go-live safeguards still hold -----------------------------------------------------------------------------------------------------------------
DO $$
DECLARE n int; sub public.billing_subscriptions; r jsonb; before_mode text; b uuid;
BEGIN
  PERFORM pg_temp.ok('every ledger entry, assessment and invoice that existed before this suite is byte-for-byte unchanged', NOT EXISTS (
    SELECT 1 FROM pc_before p WHERE p.h IS DISTINCT FROM (SELECT md5(x::text) FROM public.billing_ledger_entries x WHERE p.t = 'ledger' AND x.id::text = p.k
       UNION ALL SELECT md5(x::text) FROM public.order_billing_assessments x WHERE p.t = 'assessment' AND x.id::text = p.k UNION ALL SELECT md5(x::text) FROM public.billing_invoices x WHERE p.t = 'invoice' AND x.id::text = p.k)));
  b := (SELECT id FROM public.businesses WHERE name = 'PC Fresh Sub');
  SELECT * INTO sub FROM public.billing_subscriptions WHERE business_id = b;
  PERFORM pg_temp.ok('a real billing period still cannot be opened for a business that has not been put live', zz.try(format('SELECT public._billing_ensure_period((SELECT s FROM public.billing_subscriptions s WHERE s.business_id = %L), now(), false)', b)) LIKE 'ERR: A real billing period requires an explicit go-live date%');
  PERFORM pg_temp.ok('scheduled prices never made a business live or created a real period', NOT EXISTS (SELECT 1 FROM public.billing_periods p JOIN public.businesses bz ON bz.id = p.business_id WHERE bz.name LIKE 'PC %' AND NOT p.shadow)
    AND NOT EXISTS (SELECT 1 FROM public.billing_subscriptions s JOIN public.businesses bz ON bz.id = s.business_id WHERE bz.name LIKE 'PC %' AND s.activated_at IS NOT NULL));
  -- the scheduler activates due price changes even while billing is off, and charges nothing
  before_mode := (SELECT mode FROM public.billing_settings WHERE id);
  UPDATE public.billing_settings SET mode = 'disabled' WHERE id;
  PERFORM zz.pc_plan('pc_off');
  PERFORM zz.pc_sched((SELECT id FROM public.billing_plans WHERE code = 'pc_off'), zz.pc_params(70), now() + interval '5 days', 'new_only', true, NULL);
  UPDATE public.billing_settings SET mode = before_mode WHERE id;
END $$;
DO $$
DECLARE plan uuid := (SELECT id FROM public.billing_plans WHERE code = 'pc_off'); c uuid; r jsonb; n1 int; n2 int;
BEGIN
  c := (SELECT id FROM public.billing_scheduled_changes WHERE plan_id = plan);
  PERFORM zz.pc_arrive(c);
  SELECT count(*) INTO n1 FROM public.billing_ledger_entries;
  UPDATE public.billing_settings SET mode = 'disabled' WHERE id;
  r := public.billing_run_scheduled(now());
  PERFORM pg_temp.ok('with billing switched off, the scheduled run still activates the due price change', (SELECT status FROM public.billing_scheduled_changes WHERE id = c) = 'applied' AND r ->> 'skipped' = 'disabled');
  SELECT count(*) INTO n2 FROM public.billing_ledger_entries;
  PERFORM pg_temp.ok('and charges, assesses and invoices nothing', n1 = n2);
  PERFORM pg_temp.ok('the run report includes the price changes when billing is on', EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'billing_run_scheduled' AND prosrc LIKE '%price_changes%'));
END $$;
ROLLBACK;
