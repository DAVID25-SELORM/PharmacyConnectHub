-- Pricing controls: Super Admin only, scheduled price changes, separate subscription and commission switches.
--
-- WHAT THIS CHANGES, in one place:
--  1. Only the platform OWNER (Super Admin) can change anything in billing: every billing write already goes through _billing_admin_reason, which now also requires the owner role.
--     Other platform administrators keep read access (the read functions use _billing_admin_only, unchanged).
--  2. Price changes can be SCHEDULED. A plan version is 'scheduled' until its start moment, then 'published'; a cancelled one is 'cancelled'. The database refuses a published version that
--     starts in the future (the old "effective_from" was stored but never honoured, so a future-dated publish took effect at once). New subscribers get the version in force on THEIR start
--     date. Existing subscribers stay on their terms; if the change was scheduled for existing subscribers too, each moves at the start of their own next billing cycle, never in the past.
--  3. Preview, list, cancel and history functions for the Pricing & Plans screen.
--  4. Two platform switches: charge subscriptions, charge commissions. Switching one off affects only what is assessed from then on.
-- Nothing here activates real billing, charges anyone, or edits an issued invoice, a ledger entry or an assessment (those stay append-only).
-- Billing functions are replaced whole (they were created by this repository's migrations, unlike checkout, which production has changed).
BEGIN;

-- 0. Refuse to apply when nobody could change billing afterwards.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.platform_staff ps WHERE ps.role = 'owner' AND ps.status = 'active' AND public.has_role(ps.user_id, 'admin')) THEN
    RAISE EXCEPTION 'No active platform owner with the administrator role exists. Billing changes are limited to the platform owner, so one must exist before this is applied.';
  END IF;
END $$;

-- 1. The two switches.
ALTER TABLE public.billing_settings ADD COLUMN IF NOT EXISTS subscriptions_enabled BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE public.billing_settings ADD COLUMN IF NOT EXISTS commissions_enabled BOOLEAN NOT NULL DEFAULT TRUE;

-- 2. Plan version states.
ALTER TABLE public.billing_plan_versions ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;
ALTER TABLE public.billing_plan_versions DROP CONSTRAINT IF EXISTS billing_plan_versions_status_check;
ALTER TABLE public.billing_plan_versions ADD CONSTRAINT billing_plan_versions_status_check CHECK (status IN ('published', 'scheduled', 'retired', 'cancelled'));
ALTER TABLE public.billing_plan_versions DROP CONSTRAINT IF EXISTS billing_plan_versions_cancelled_check;
ALTER TABLE public.billing_plan_versions ADD CONSTRAINT billing_plan_versions_cancelled_check CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL));

-- 3. The scheduled changes themselves.
CREATE TABLE IF NOT EXISTS public.billing_scheduled_changes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID NOT NULL REFERENCES public.billing_plans(id) ON DELETE RESTRICT,
  version_id UUID NOT NULL UNIQUE REFERENCES public.billing_plan_versions(id) ON DELETE RESTRICT,
  audience TEXT NOT NULL CHECK (audience IN ('new_only', 'new_and_existing')),
  keep_overrides BOOLEAN NOT NULL DEFAULT TRUE,
  expected_affected INTEGER,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied', 'cancelled')),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) >= 5),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  applied_at TIMESTAMPTZ,
  applied_result JSONB,
  cancelled_at TIMESTAMPTZ,
  cancelled_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  cancel_reason TEXT,
  CHECK ((status = 'applied') = (applied_at IS NOT NULL)),
  CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS billing_scheduled_changes_plan_idx ON public.billing_scheduled_changes (plan_id, created_at DESC);
ALTER TABLE public.billing_scheduled_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read scheduled price changes" ON public.billing_scheduled_changes;
CREATE POLICY "Admins read scheduled price changes" ON public.billing_scheduled_changes FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.billing_scheduled_changes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_scheduled_changes TO authenticated;

-- A scheduled change is never deleted, and only moves from pending to applied or cancelled.
CREATE OR REPLACE FUNCTION public.billing_scheduled_changes_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A scheduled price change is never deleted. Cancel it instead.'; END IF;
  IF NEW.plan_id <> OLD.plan_id OR NEW.version_id <> OLD.version_id OR NEW.audience <> OLD.audience OR NEW.keep_overrides <> OLD.keep_overrides
     OR NEW.expected_affected IS DISTINCT FROM OLD.expected_affected OR NEW.reason <> OLD.reason OR NEW.created_by IS DISTINCT FROM OLD.created_by OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'A scheduled price change cannot be edited. Cancel it and schedule another.';
  END IF;
  IF OLD.status <> 'pending' AND NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'A scheduled price change that has been applied or cancelled is final.'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_scheduled_changes_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_billing_scheduled_changes_guard ON public.billing_scheduled_changes;
CREATE TRIGGER trg_billing_scheduled_changes_guard BEFORE UPDATE OR DELETE ON public.billing_scheduled_changes FOR EACH ROW EXECUTE FUNCTION public.billing_scheduled_changes_guard();

-- 4. The plan version guard: terms never change; a published version cannot start in the future; a scheduled one must, and must come after every other version of the plan.
CREATE OR REPLACE FUNCTION public.billing_plan_versions_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_key TEXT;
  v_val JSONB;
  v_type TEXT;
  v_plan_type public.business_type;
  v_feature_type public.business_type;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A published plan version is never deleted. Retire it instead.'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.plan_id <> OLD.plan_id OR NEW.version <> OLD.version OR NEW.billing_interval_months <> OLD.billing_interval_months OR NEW.currency <> OLD.currency
       OR NEW.subscription_amount <> OLD.subscription_amount OR NEW.free_trial_days <> OLD.free_trial_days OR NEW.onboarding_free_orders <> OLD.onboarding_free_orders
       OR NEW.monthly_free_orders <> OLD.monthly_free_orders OR NEW.transaction_fee_percentage <> OLD.transaction_fee_percentage
       OR NEW.transaction_fee_min IS DISTINCT FROM OLD.transaction_fee_min OR NEW.transaction_fee_max IS DISTINCT FROM OLD.transaction_fee_max
       OR NEW.transaction_fee_cycle_cap IS DISTINCT FROM OLD.transaction_fee_cycle_cap OR NEW.min_billable_order_amount IS DISTINCT FROM OLD.min_billable_order_amount
       OR NEW.max_users IS DISTINCT FROM OLD.max_users OR NEW.max_branches IS DISTINCT FROM OLD.max_branches OR NEW.entitlements <> OLD.entitlements
       OR NEW.metadata <> OLD.metadata OR NEW.effective_from <> OLD.effective_from OR NEW.reason <> OLD.reason OR NEW.created_at <> OLD.created_at THEN
      RAISE EXCEPTION 'The terms of a published plan version never change. Publish a new version instead.';
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF OLD.status IN ('retired', 'cancelled') THEN RAISE EXCEPTION 'A % plan version cannot be brought back.', OLD.status; END IF;
      IF OLD.status = 'published' AND NEW.status <> 'retired' THEN RAISE EXCEPTION 'A published plan version can only be retired.'; END IF;
      IF OLD.status = 'scheduled' AND NEW.status = 'published' AND now() < OLD.effective_from - interval '1 minute' THEN
        RAISE EXCEPTION 'A scheduled plan version cannot take effect before its start moment.';
      END IF;
      IF OLD.status = 'scheduled' AND NEW.status = 'cancelled' AND now() >= OLD.effective_from THEN
        RAISE EXCEPTION 'A scheduled plan version that has reached its start moment can no longer be cancelled.';
      END IF;
      IF OLD.status = 'scheduled' AND NEW.status = 'retired' THEN RAISE EXCEPTION 'A scheduled plan version is published or cancelled, never retired directly.'; END IF;
    END IF;
    RETURN NEW;
  END IF;
  -- INSERT
  IF NEW.status NOT IN ('published', 'scheduled') THEN RAISE EXCEPTION 'A new plan version is published or scheduled.'; END IF;
  IF NEW.status = 'published' AND NEW.effective_from > now() + interval '1 minute' THEN
    RAISE EXCEPTION 'A price that starts in the future must be scheduled, not published: a published version takes effect at once.';
  END IF;
  IF NEW.status = 'scheduled' THEN
    IF NEW.effective_from <= now() + interval '1 minute' THEN RAISE EXCEPTION 'A scheduled price change must start in the future.'; END IF;
    IF NEW.effective_from > now() + interval '365 days' THEN RAISE EXCEPTION 'A price change cannot be scheduled more than a year ahead.'; END IF;
    IF EXISTS (SELECT 1 FROM public.billing_plan_versions v WHERE v.plan_id = NEW.plan_id AND v.status <> 'cancelled' AND v.effective_from >= NEW.effective_from) THEN
      RAISE EXCEPTION 'A scheduled change must start after every other version of the plan. Cancel the later one first, or choose a later date.';
    END IF;
  END IF;
  SELECT p.business_type INTO v_plan_type FROM public.billing_plans p WHERE p.id = NEW.plan_id;
  FOR v_key, v_val IN SELECT * FROM jsonb_each(NEW.entitlements) LOOP
    SELECT c.value_type, c.business_type INTO v_type, v_feature_type FROM public.billing_feature_catalog c WHERE c.key = v_key AND c.active;
    IF v_type IS NULL THEN RAISE EXCEPTION 'Unknown plan feature "%". Add it to the feature catalog first.', v_key; END IF;
    IF v_feature_type IS NOT NULL AND v_feature_type <> v_plan_type THEN RAISE EXCEPTION 'The feature "%" is not available to this kind of business.', v_key; END IF;
    IF v_type = 'boolean' AND jsonb_typeof(v_val) <> 'boolean' THEN RAISE EXCEPTION 'The feature "%" must be true or false.', v_key; END IF;
    IF v_type = 'integer' AND NOT (jsonb_typeof(v_val) = 'number' AND (v_val #>> '{}') ~ '^[0-9]+$') THEN RAISE EXCEPTION 'The feature "%" must be a whole number.', v_key; END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

-- 5. Helpers.
-- The version of a plan in force at a moment: the latest that has started and was not cancelled. It does not depend on the scheduler having run.
CREATE OR REPLACE FUNCTION public._billing_plan_version_at(p_plan_id UUID, p_at TIMESTAMPTZ)
RETURNS SETOF public.billing_plan_versions
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT v.* FROM public.billing_plan_versions v
  WHERE v.plan_id = p_plan_id AND v.status <> 'cancelled' AND v.effective_from <= p_at
  ORDER BY v.effective_from DESC, v.version DESC LIMIT 1
$$;
REVOKE ALL ON FUNCTION public._billing_plan_version_at(UUID, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- The start of the billing cycle after a moment (never earlier than the moment, never before billing starts).
CREATE OR REPLACE FUNCTION public._billing_next_cycle_start(p_sub public.billing_subscriptions, p_at TIMESTAMPTZ)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_at TIMESTAMPTZ := GREATEST(p_at, p_sub.billing_starts_at, p_sub.period_anchor_at);
  v_interval INTEGER := COALESCE((public.billing_resolve_terms(p_sub.business_id, v_at) ->> 'billing_interval_months')::INTEGER, 1);
  b RECORD;
BEGIN
  SELECT * INTO b FROM public.billing_period_bounds(p_sub.period_anchor_at, v_interval, v_at);
  RETURN b.period_end;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_next_cycle_start(public.billing_subscriptions, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- Every business whose terms in force today belong to a plan, with when a change effective at p_from would reach it (the start of its next cycle) and why it would not.
CREATE OR REPLACE FUNCTION public._billing_price_change_targets(p_plan_id UUID, p_from TIMESTAMPTZ)
RETURNS TABLE (business_id UUID, business_name TEXT, subscription_id UUID, current_version INTEGER, current_amount NUMERIC, current_fee_pct NUMERIC,
               has_overrides BOOLEAN, in_trial BOOLEAN, change_from TIMESTAMPTZ, skip_reason TEXT)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH cur AS (
    SELECT s.id AS sub_id, s, b.name AS bname, v.version AS ver, v.subscription_amount AS amt, v.transaction_fee_percentage AS pct, t.overrides AS ov
    FROM public.billing_subscriptions s
    JOIN public.businesses b ON b.id = s.business_id
    JOIN LATERAL (SELECT x.* FROM public.billing_subscription_terms x WHERE x.subscription_id = s.id AND x.effective_from <= now() ORDER BY x.effective_from DESC LIMIT 1) t ON TRUE
    JOIN public.billing_plan_versions v ON v.id = t.plan_version_id
    WHERE v.plan_id = p_plan_id
  )
  SELECT (c.s).business_id, c.bname, c.sub_id, c.ver, c.amt, c.pct, c.ov <> '{}'::JSONB,
         (c.s).trial_end IS NOT NULL AND (c.s).trial_end > now(),
         public._billing_next_cycle_start(c.s, GREATEST(p_from, now())),
         CASE WHEN (c.s).status = 'cancelled' OR ((c.s).ended_at IS NOT NULL AND (c.s).ended_at <= now()) THEN 'The subscription has ended'
              WHEN EXISTS (SELECT 1 FROM public.billing_subscription_terms y WHERE y.subscription_id = c.sub_id AND y.effective_from >= public._billing_next_cycle_start(c.s, GREATEST(p_from, now()))) THEN 'It already has later terms'
         END
  FROM cur c;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_price_change_targets(UUID, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- Validates plan terms and returns them in full (defaults filled in). Used by publish, schedule and preview, so they can never disagree.
CREATE OR REPLACE FUNCTION public._billing_plan_terms_from_params(p_params JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_params JSONB := COALESCE(p_params, '{}'::JSONB);
  v_key TEXT;
BEGIN
  IF jsonb_typeof(v_params) <> 'object' THEN RAISE EXCEPTION 'The plan terms must be an object.'; END IF;
  IF v_params ? 'effective_from' THEN RAISE EXCEPTION 'Choose when a price starts with the schedule option, not inside the terms.'; END IF;
  FOR v_key IN SELECT jsonb_object_keys(v_params) LOOP
    IF v_key NOT IN ('billing_interval_months', 'currency', 'subscription_amount', 'free_trial_days', 'onboarding_free_orders', 'monthly_free_orders', 'transaction_fee_percentage',
                     'transaction_fee_min', 'transaction_fee_max', 'transaction_fee_cycle_cap', 'min_billable_order_amount', 'max_users', 'max_branches', 'entitlements', 'metadata') THEN
      RAISE EXCEPTION 'Unknown plan term "%".', v_key;
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'billing_interval_months', COALESCE((v_params ->> 'billing_interval_months')::INTEGER, 1),
    'currency', COALESCE(v_params ->> 'currency', 'GHS'),
    'subscription_amount', COALESCE((v_params ->> 'subscription_amount')::NUMERIC, 0),
    'free_trial_days', COALESCE((v_params ->> 'free_trial_days')::INTEGER, 0),
    'onboarding_free_orders', COALESCE((v_params ->> 'onboarding_free_orders')::INTEGER, 0),
    'monthly_free_orders', COALESCE((v_params ->> 'monthly_free_orders')::INTEGER, 0),
    'transaction_fee_percentage', COALESCE((v_params ->> 'transaction_fee_percentage')::NUMERIC, 0),
    'transaction_fee_min', (v_params ->> 'transaction_fee_min')::NUMERIC,
    'transaction_fee_max', (v_params ->> 'transaction_fee_max')::NUMERIC,
    'transaction_fee_cycle_cap', (v_params ->> 'transaction_fee_cycle_cap')::NUMERIC,
    'min_billable_order_amount', (v_params ->> 'min_billable_order_amount')::NUMERIC,
    'max_users', (v_params ->> 'max_users')::INTEGER,
    'max_branches', (v_params ->> 'max_branches')::INTEGER,
    'entitlements', COALESCE(v_params -> 'entitlements', '{}'::JSONB),
    'metadata', COALESCE(v_params -> 'metadata', '{}'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public._billing_plan_terms_from_params(JSONB) FROM PUBLIC, anon, authenticated;

-- Creates the next version of a plan with the given status and start moment (the guard trigger enforces what is allowed).
CREATE OR REPLACE FUNCTION public._billing_new_plan_version(p_plan_id UUID, p_params JSONB, p_status TEXT, p_effective_from TIMESTAMPTZ, p_reason TEXT)
RETURNS public.billing_plan_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_t JSONB := public._billing_plan_terms_from_params(p_params);
  v_next INTEGER;
  v_new public.billing_plan_versions%ROWTYPE;
BEGIN
  SELECT COALESCE(max(version), 0) + 1 INTO v_next FROM public.billing_plan_versions WHERE plan_id = p_plan_id;
  INSERT INTO public.billing_plan_versions(plan_id, version, status, billing_interval_months, currency, subscription_amount, free_trial_days, onboarding_free_orders, monthly_free_orders,
    transaction_fee_percentage, transaction_fee_min, transaction_fee_max, transaction_fee_cycle_cap, min_billable_order_amount, max_users, max_branches, entitlements, metadata,
    effective_from, reason, created_by)
  VALUES (p_plan_id, v_next, p_status, (v_t ->> 'billing_interval_months')::INTEGER, v_t ->> 'currency', (v_t ->> 'subscription_amount')::NUMERIC, (v_t ->> 'free_trial_days')::INTEGER,
    (v_t ->> 'onboarding_free_orders')::INTEGER, (v_t ->> 'monthly_free_orders')::INTEGER, (v_t ->> 'transaction_fee_percentage')::NUMERIC, (v_t ->> 'transaction_fee_min')::NUMERIC,
    (v_t ->> 'transaction_fee_max')::NUMERIC, (v_t ->> 'transaction_fee_cycle_cap')::NUMERIC, (v_t ->> 'min_billable_order_amount')::NUMERIC, (v_t ->> 'max_users')::INTEGER,
    (v_t ->> 'max_branches')::INTEGER, v_t -> 'entitlements', v_t -> 'metadata', p_effective_from, p_reason, auth.uid())
  RETURNING * INTO v_new;
  RETURN v_new;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_new_plan_version(UUID, JSONB, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon, authenticated;

-- 6. Publishing now: the new version is in force at once for NEW subscribers; existing subscribers stay on their terms until moved.
CREATE OR REPLACE FUNCTION public.admin_billing_publish_plan_version(p_plan_id UUID, p_params JSONB, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_plan public.billing_plans%ROWTYPE;
  v_prev public.billing_plan_versions%ROWTYPE;
  v_new public.billing_plan_versions%ROWTYPE;
BEGIN
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = p_plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_plan_versions WHERE plan_id = p_plan_id AND status = 'scheduled') THEN
    RAISE EXCEPTION 'This plan has a price change scheduled. Cancel it, or wait for it, before publishing a new version now.';
  END IF;
  SELECT * INTO v_prev FROM public.billing_plan_versions WHERE plan_id = p_plan_id AND status = 'published' ORDER BY version DESC LIMIT 1;
  v_new := public._billing_new_plan_version(p_plan_id, p_params, 'published', now(), v_reason);
  UPDATE public.billing_plan_versions SET status = 'retired', retired_at = now() WHERE plan_id = p_plan_id AND status = 'published' AND id <> v_new.id;
  SELECT * INTO v_new FROM public.billing_plan_versions WHERE id = v_new.id;
  PERFORM public.write_audit_log('Billing plan version published', 'DrugXOne', 'billing_plan', p_plan_id, v_plan.code,
    jsonb_build_object('version', v_new.version, 'reason', v_reason,
      'previous', CASE WHEN v_prev.id IS NULL THEN NULL ELSE to_jsonb(v_prev) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata' END,
      'new', to_jsonb(v_new) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata'));
  RETURN v_new.id;
END;
$$;

-- 13. Every billing write passes through this function, so the owner-only rule is enforced here, once.
CREATE OR REPLACE FUNCTION public._billing_admin_reason(p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  IF NOT public.is_platform_owner(auth.uid()) THEN RAISE EXCEPTION 'Only the platform owner (Super Admin) can change billing. Other administrators can view it.'; END IF;
  IF char_length(v_reason) < 5 THEN RAISE EXCEPTION 'A reason of at least 5 characters is required for every billing change.'; END IF;
  IF char_length(v_reason) > 500 THEN RAISE EXCEPTION 'The reason is too long (500 characters maximum).'; END IF;
  RETURN v_reason;
END;
$function$;

-- 14. A new subscription gets the plan version in force on its own start date (never an earlier one than today's: a start date in the past uses the version in force now).
CREATE OR REPLACE FUNCTION public.admin_billing_start_subscription(p_business_id uuid, p_plan_code text, p_billing_starts_at timestamp with time zone, p_billing_mode text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_biz public.businesses%ROWTYPE;
  v_plan public.billing_plans%ROWTYPE;
  v_ver public.billing_plan_versions%ROWTYPE;
  v_starts TIMESTAMPTZ := COALESCE(p_billing_starts_at, now());
  v_sub_id UUID;
  v_terms_id UUID;
  v_keys RECORD;
  v_grant_id UUID;
  v_grant TEXT := 'none';
BEGIN
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.'; END IF;
  IF v_biz.verification_status::TEXT <> 'approved' THEN RAISE EXCEPTION 'Only an approved business can be put on a plan.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_subscriptions s WHERE s.business_id = p_business_id) THEN RAISE EXCEPTION 'This business already has a subscription.'; END IF;
  SELECT * INTO v_plan FROM public.billing_plans WHERE code = p_plan_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  IF NOT v_plan.active THEN RAISE EXCEPTION 'That plan is not switched on.'; END IF;
  IF v_plan.business_type <> v_biz.type THEN RAISE EXCEPTION 'That plan is for a different kind of business.'; END IF;
  SELECT * INTO v_ver FROM public._billing_plan_version_at(v_plan.id, GREATEST(v_starts, now()));
  IF NOT FOUND THEN RAISE EXCEPTION 'That plan has no published version.'; END IF;
  IF p_billing_mode IS NOT NULL AND p_billing_mode NOT IN ('disabled', 'shadow') THEN RAISE EXCEPTION 'A business can start as disabled or shadow (or follow the platform setting).'; END IF;
  IF v_starts > now() + interval '365 days' THEN RAISE EXCEPTION 'Billing cannot start more than a year ahead.'; END IF;
  IF (SELECT s.live_since IS NOT NULL FROM public.billing_settings s WHERE s.id) AND p_billing_mode IS NULL AND v_starts < now() - interval '1 minute' THEN
    RAISE EXCEPTION 'Real billing is running, so a subscription cannot start in the past: no historical order is ever charged. Start it now or later, or start it in shadow.';
  END IF;

  INSERT INTO public.billing_subscriptions(business_id, status, billing_mode, billing_starts_at, period_anchor_at, trial_start, trial_end, created_by)
  VALUES (p_business_id, CASE WHEN v_ver.free_trial_days > 0 THEN 'trialing' ELSE 'active' END, p_billing_mode, v_starts, v_starts,
          CASE WHEN v_ver.free_trial_days > 0 THEN v_starts END, CASE WHEN v_ver.free_trial_days > 0 THEN v_starts + make_interval(days => v_ver.free_trial_days) END, auth.uid())
  RETURNING id INTO v_sub_id;
  INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason, created_by)
  VALUES (v_sub_id, v_starts, v_ver.id, '{}'::JSONB, v_reason, auth.uid()) RETURNING id INTO v_terms_id;
  -- Once real billing is running, a new subscription that follows the platform is live from its start (real billing never looks back).
  IF (SELECT s.live_since IS NOT NULL FROM public.billing_settings s WHERE s.id) AND p_billing_mode IS NULL THEN
    UPDATE public.billing_subscriptions SET activated_at = v_starts WHERE id = v_sub_id;
  END IF;

  IF v_ver.onboarding_free_orders > 0 THEN
    SELECT * INTO v_keys FROM public.billing_onboarding_keys(p_business_id);
    INSERT INTO public.billing_allowance_grants(business_id, kind, quantity, source, source_ref, reason, licence_key, owner_key, created_by)
    VALUES (p_business_id, 'onboarding_free_orders', v_ver.onboarding_free_orders, 'plan', v_plan.code || ' v' || v_ver.version, 'Launch free orders with the plan', v_keys.licence_key, v_keys.owner_key, auth.uid())
    ON CONFLICT DO NOTHING RETURNING id INTO v_grant_id;
    v_grant := CASE WHEN v_grant_id IS NULL THEN 'declined_already_granted' ELSE 'granted' END;
  END IF;
  PERFORM public.write_audit_log('Billing subscription started', v_biz.name, 'billing_subscription', v_sub_id, v_plan.code,
    jsonb_build_object('plan', v_plan.code, 'plan_version', v_ver.version, 'billing_starts_at', v_starts, 'billing_mode', p_billing_mode, 'launch_free_orders', v_grant, 'reason', v_reason),
    _business_id => p_business_id);
  RETURN jsonb_build_object('subscription_id', v_sub_id, 'terms_id', v_terms_id, 'plan_version_id', v_ver.id, 'launch_grant', v_grant);
END;
$function$;

-- 15. Moving a business to a plan uses the version in force when the change starts.
CREATE OR REPLACE FUNCTION public.admin_billing_change_plan(p_business_id uuid, p_plan_code text, p_effective_from timestamp with time zone, p_keep_overrides boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_plan public.billing_plans%ROWTYPE;
  v_ver public.billing_plan_versions%ROWTYPE;
  v_cur public.billing_subscription_terms%ROWTYPE;
  v_from TIMESTAMPTZ;
  b RECORD;
  v_id UUID;
BEGIN
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  SELECT * INTO v_plan FROM public.billing_plans WHERE code = p_plan_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  IF NOT v_plan.active THEN RAISE EXCEPTION 'That plan is not switched on.'; END IF;
  IF v_plan.business_type <> v_biz.type THEN RAISE EXCEPTION 'That plan is for a different kind of business.'; END IF;
  IF p_effective_from IS NULL THEN
    SELECT * INTO b FROM public.billing_period_bounds(v_sub.period_anchor_at, COALESCE((public.billing_resolve_terms(p_business_id, GREATEST(now(), v_sub.billing_starts_at)) ->> 'billing_interval_months')::INTEGER, 1), GREATEST(now(), v_sub.period_anchor_at));
    v_from := b.period_end;
  ELSE
    v_from := p_effective_from;
  END IF;
  IF v_from < now() - interval '1 minute' THEN RAISE EXCEPTION 'A plan change cannot start in the past.'; END IF;
  IF v_from > now() + interval '365 days' THEN RAISE EXCEPTION 'A plan change cannot start more than a year ahead.'; END IF;
  SELECT * INTO v_ver FROM public._billing_plan_version_at(v_plan.id, GREATEST(v_from, now()));
  IF NOT FOUND THEN RAISE EXCEPTION 'That plan has no published version.'; END IF;
  SELECT * INTO v_cur FROM public.billing_subscription_terms t WHERE t.subscription_id = v_sub.id AND t.effective_from <= v_from ORDER BY t.effective_from DESC LIMIT 1;
  IF v_cur.plan_version_id = v_ver.id AND (COALESCE(p_keep_overrides, TRUE) OR v_cur.overrides = '{}'::JSONB) THEN RAISE EXCEPTION 'The business is already on this plan version from then.'; END IF;
  BEGIN
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason, created_by)
    VALUES (v_sub.id, v_from, v_ver.id, CASE WHEN COALESCE(p_keep_overrides, TRUE) THEN v_cur.overrides ELSE '{}'::JSONB END, v_reason, auth.uid()) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Terms already start at that exact moment. Choose another moment.';
  END;
  PERFORM public.write_audit_log('Billing plan changed', v_biz.name, 'billing_subscription_terms', v_id, v_plan.code,
    jsonb_build_object('new_plan', v_plan.code, 'new_version', v_ver.version, 'effective_from', v_from, 'kept_overrides', COALESCE(p_keep_overrides, TRUE), 'previous_overrides', v_cur.overrides, 'reason', v_reason),
    _business_id => p_business_id);
  RETURN jsonb_build_object('terms_id', v_id, 'effective_from', v_from, 'plan_version', v_ver.version);
END;
$function$;

-- 16. The scheduled run first activates any price change that has reached its start moment.
CREATE OR REPLACE FUNCTION public.billing_run_scheduled(p_now timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_states INTEGER;
  v_periods INTEGER;
  v_queue JSONB;
  v_catch JSONB;
  v_inv JSONB;
  v_over INTEGER;
  v_enf JSONB := '{}'::JSONB;
  v_notes JSONB := '{}'::JSONB;
  v_res JSONB;
  v_changes JSONB;
BEGIN
  v_changes := public.billing_apply_due_price_changes(p_now);
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_states := public.billing_advance_states(p_now);
  v_periods := public.billing_open_periods(p_now);
  v_queue := public.billing_process_queue(100);
  v_catch := public.billing_catch_up(200);
  v_inv := public.billing_issue_invoices(p_now);
  v_over := public.billing_mark_overdue(p_now);
  BEGIN v_enf := public.billing_advance_enforcement(p_now); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'billing enforcement step failed: %', SQLERRM; END;
  BEGIN v_notes := public.billing_send_notifications(p_now); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'billing notices step failed: %', SQLERRM; END;
  v_res := jsonb_build_object('states_advanced', v_states, 'periods_opened', v_periods, 'queue', v_queue, 'catch_up', v_catch, 'invoices', v_inv, 'marked_overdue', v_over, 'enforcement', v_enf, 'notices', v_notes, 'price_changes', v_changes);
  UPDATE public.billing_run_status SET last_run_at = clock_timestamp(), runs = runs + 1, last_result = v_res WHERE id;
  RETURN v_res;
END;
$function$;

-- 17. With commissions switched off, an order is recorded as exempt (nothing charged, no free order used).
CREATE OR REPLACE FUNCTION public.billing_assess_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_o RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_platform TEXT;
  v_mode TEXT;
  v_shadow BOOLEAN;
  v_at TIMESTAMPTZ;
  v_gate TIMESTAMPTZ;
  v_terms JSONB;
  v_period public.billing_periods%ROWTYPE;
  v_billable NUMERIC(14,2);
  v_outcome TEXT;
  v_reason TEXT;
  v_source TEXT;
  v_seq INTEGER;
  v_grant UUID;
  v_g RECORD;
  v_used INTEGER;
  v_allow INTEGER;
  v_pct NUMERIC;
  v_calc NUMERIC(12,2);
  v_after NUMERIC(12,2);
  v_cap NUMERIC;
  v_remaining NUMERIC;
  v_charged NUMERIC(12,2) := 0;
  v_cap_adj NUMERIC(12,2) := 0;
  v_existing UUID;
  v_id UUID;
  v_key TEXT;
  v_eligible BOOLEAN;
  v_name TEXT;
BEGIN
  SELECT o.id, o.order_number, o.wholesaler_id, o.pharmacy_id, o.status::TEXT AS status, o.delivered_at INTO v_o FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('skipped', 'order_not_found'); END IF;
  IF v_o.status <> 'delivered' THEN RETURN jsonb_build_object('skipped', 'not_delivered'); END IF;
  -- One lock per business serialises everything that spends its allowances or its cap.
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = v_o.wholesaler_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('skipped', 'no_subscription'); END IF;
  SELECT s.mode INTO v_platform FROM public.billing_settings s WHERE s.id;
  v_mode := public._billing_base_mode(v_sub.billing_mode, v_platform);
  IF v_mode = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_shadow := v_mode = 'shadow';
  IF NOT v_shadow AND v_sub.activated_at IS NULL THEN RETURN jsonb_build_object('skipped', 'not_activated'); END IF;
  v_at := COALESCE(v_o.delivered_at, now());
  -- Shadow counts orders from the billing start; REAL billing only from the moment it was activated (orders delivered earlier are never charged).
  v_gate := CASE WHEN v_shadow THEN v_sub.billing_starts_at ELSE v_sub.activated_at END;
  IF v_at < v_gate THEN RETURN jsonb_build_object('skipped', 'before_billing_starts'); END IF;
  IF v_sub.ended_at IS NOT NULL AND v_at >= v_sub.ended_at THEN RETURN jsonb_build_object('skipped', 'subscription_ended'); END IF;
  SELECT a.id INTO v_existing FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'primary' AND a.shadow = v_shadow;
  IF FOUND THEN RETURN jsonb_build_object('skipped', 'already_assessed', 'assessment_id', v_existing); END IF;
  v_terms := public.billing_resolve_terms(v_o.wholesaler_id, v_at);
  IF v_terms IS NULL THEN RETURN jsonb_build_object('skipped', 'no_terms'); END IF;

  v_period := public._billing_ensure_period(v_sub, v_at, v_shadow);
  SELECT * INTO v_period FROM public.billing_periods p WHERE p.id = v_period.id FOR UPDATE;
  v_billable := public._billing_billable(p_order_id);
  v_pct := (v_terms ->> 'transaction_fee_percentage')::NUMERIC;

  -- The deterministic order of decisions: exempt, excluded, below the minimum, onboarding free, monthly free, chargeable. An order uses at most one allowance.
  IF NOT COALESCE((SELECT st.commissions_enabled FROM public.billing_settings st WHERE st.id), TRUE) THEN
    v_outcome := 'exempt'; v_reason := 'Commissions are switched off';
  ELSIF v_sub.exempt_from_transaction_fees OR COALESCE((v_terms ->> 'exempt_from_transaction_fees')::BOOLEAN, FALSE) THEN
    v_outcome := 'exempt'; v_reason := 'The business is exempt from transaction fees';
  ELSIF v_sub.billing_paused THEN
    v_outcome := 'excluded'; v_reason := 'Billing is paused';
  ELSIF EXISTS (SELECT 1 FROM public.businesses ph JOIN public.businesses w ON w.owner_id = ph.owner_id WHERE ph.id = v_o.pharmacy_id AND w.id = v_o.wholesaler_id) THEN
    v_outcome := 'excluded'; v_reason := 'The buyer and the seller have the same owner';
  ELSIF v_billable = 0 THEN
    v_outcome := 'excluded'; v_reason := 'The order has no billable value';
  ELSIF (v_terms ->> 'min_billable_order_amount') IS NOT NULL AND v_billable < (v_terms ->> 'min_billable_order_amount')::NUMERIC THEN
    v_outcome := 'below_minimum'; v_reason := 'Below the minimum billable order value';
  ELSE
    -- onboarding allowance: the first grant with numbers left
    FOR v_g IN SELECT g.id, g.quantity FROM public.billing_allowance_grants g
               WHERE g.business_id = v_o.wholesaler_id AND g.kind = 'onboarding_free_orders' AND (g.expires_at IS NULL OR g.expires_at > v_at) ORDER BY g.created_at, g.id LOOP
      SELECT count(*) INTO v_used FROM public.order_billing_assessments a WHERE a.grant_id = v_g.id AND a.free_source = 'onboarding' AND a.shadow = v_shadow;
      IF v_used < v_g.quantity THEN v_grant := v_g.id; v_seq := v_used + 1; v_source := 'onboarding'; EXIT; END IF;
    END LOOP;
    IF v_source IS NOT NULL THEN
      v_outcome := 'free_onboarding';
    ELSE
      v_allow := COALESCE((v_terms ->> 'monthly_free_orders')::INTEGER, 0);
      SELECT count(*) INTO v_used FROM public.order_billing_assessments a WHERE a.period_id = v_period.id AND a.free_source = 'monthly' AND a.shadow = v_shadow;
      IF v_used < v_allow THEN v_outcome := 'free_monthly'; v_source := 'monthly'; v_seq := v_used + 1; ELSE v_outcome := 'chargeable'; END IF;
    END IF;
  END IF;

  IF v_outcome = 'chargeable' THEN
    SELECT f.calculated_fee, f.fee_after_limits INTO v_calc, v_after FROM public.billing_compute_fee(v_billable, v_pct, (v_terms ->> 'transaction_fee_min')::NUMERIC, (v_terms ->> 'transaction_fee_max')::NUMERIC) f;
    v_cap := (v_terms ->> 'transaction_fee_cycle_cap')::NUMERIC;
    IF v_cap IS NULL THEN
      v_charged := v_after;
    ELSE
      v_remaining := GREATEST(v_cap - v_period.transaction_fees_amount, 0);
      v_charged := LEAST(v_after, v_remaining);
    END IF;
    v_cap_adj := v_after - v_charged;
  END IF;

  INSERT INTO public.order_billing_assessments(business_id, order_id, retailer_business_id, kind, adjustment_seq, shadow, period_id, subscription_terms_id, plan_version_id, delivered_at, currency,
    billable_gmv, outcome, free_source, free_seq, grant_id, percentage, calculated_fee, fee_after_limits, cap_adjustment, charged_amount, terms_snapshot, rule_version)
  VALUES (v_o.wholesaler_id, p_order_id, v_o.pharmacy_id, 'primary', 0, v_shadow, v_period.id, (v_terms ->> 'terms_id')::UUID, (v_terms ->> 'plan_version_id')::UUID, v_at, v_terms ->> 'currency',
    v_billable, v_outcome, v_source, v_seq, v_grant, CASE WHEN v_outcome = 'chargeable' THEN v_pct END, v_calc, v_after, v_cap_adj, v_charged,
    v_terms || jsonb_build_object('decision', jsonb_build_object('outcome', v_outcome, 'reason', v_reason, 'mode', v_mode)), 'billing-engine-1')
  RETURNING id INTO v_id;

  v_key := p_order_id || ':primary:' || CASE WHEN v_shadow THEN 's' ELSE 'r' END;
  IF v_outcome IN ('free_onboarding', 'free_monthly') THEN
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, charged_amount, source, idempotency_key, reason, metadata)
    VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'free_order', v_shadow, v_terms ->> 'currency', v_billable, 0, 'engine', 'free:' || v_key,
            CASE v_source WHEN 'onboarding' THEN 'Launch free order ' ELSE 'Monthly free order ' END || v_seq, jsonb_build_object('source', v_source, 'number', v_seq, 'grant_id', v_grant));
  ELSIF v_outcome = 'chargeable' THEN
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, percentage, calculated_fee, charged_amount, source, idempotency_key, metadata)
    VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'transaction_fee', v_shadow, v_terms ->> 'currency', v_billable, v_pct, v_after, v_charged, 'engine', 'fee:' || v_key,
            jsonb_build_object('percentage_fee', v_calc, 'fee_after_limits', v_after, 'cap', v_cap));
    IF v_cap_adj > 0 THEN
      INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, calculated_fee, charged_amount, source, idempotency_key, reason, metadata)
      VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'fee_cap_adjustment', v_shadow, v_terms ->> 'currency', v_billable, v_cap_adj, 0, 'engine', 'cap:' || v_key,
              'Monthly fee cap reached: ' || v_cap_adj || ' of the calculated fee is not charged', jsonb_build_object('cap', v_cap, 'fees_before', v_period.transaction_fees_amount, 'calculated', v_after, 'charged', v_charged));
    END IF;
  END IF;

  v_eligible := v_outcome IN ('free_onboarding', 'free_monthly', 'chargeable');
  UPDATE public.billing_periods SET
    billable_gmv = billable_gmv + CASE WHEN v_eligible THEN v_billable ELSE 0 END,
    eligible_orders = eligible_orders + CASE WHEN v_eligible THEN 1 ELSE 0 END,
    free_onboarding_orders = free_onboarding_orders + CASE WHEN v_outcome = 'free_onboarding' THEN 1 ELSE 0 END,
    free_monthly_orders = free_monthly_orders + CASE WHEN v_outcome = 'free_monthly' THEN 1 ELSE 0 END,
    chargeable_orders = chargeable_orders + CASE WHEN v_outcome = 'chargeable' THEN 1 ELSE 0 END,
    fees_before_cap = fees_before_cap + CASE WHEN v_outcome = 'chargeable' THEN v_after ELSE 0 END,
    transaction_fees_amount = transaction_fees_amount + v_charged
  WHERE id = v_period.id;

  IF NOT v_shadow THEN
    SELECT name INTO v_name FROM public.businesses WHERE id = v_o.wholesaler_id;
    PERFORM public.write_audit_log('Order billing assessed', v_name, 'order_billing_assessment', v_id, v_o.order_number,
      jsonb_build_object('outcome', v_outcome, 'billable', v_billable, 'charged', v_charged, 'free_source', v_source, 'free_number', v_seq, 'cap_adjustment', v_cap_adj),
      _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => v_o.wholesaler_id);
  END IF;
  RETURN jsonb_build_object('assessment_id', v_id, 'outcome', v_outcome, 'charged', v_charged, 'shadow', v_shadow, 'free_source', v_source, 'free_number', v_seq, 'period_id', v_period.id, 'billable', v_billable);
END;
$function$;

-- 18. With subscriptions switched off, a new period carries no subscription charge.
CREATE OR REPLACE FUNCTION public._billing_ensure_period(p_sub billing_subscriptions, p_at timestamp with time zone, p_shadow boolean)
 RETURNS billing_periods
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_interval INTEGER := COALESCE((public.billing_resolve_terms(p_sub.business_id, p_sub.billing_starts_at) ->> 'billing_interval_months')::INTEGER, 1);
  b RECORD;
  v_p public.billing_periods%ROWTYPE;
  v_terms JSONB;
  v_amount NUMERIC(12,2);
  v_waived BOOLEAN;
  v_why TEXT;
  v_off BOOLEAN := NOT COALESCE((SELECT st.subscriptions_enabled FROM public.billing_settings st WHERE st.id), TRUE);
BEGIN
  IF NOT p_shadow AND (p_sub.activated_at IS NULL OR p_at < p_sub.activated_at) THEN
    RAISE EXCEPTION 'A real billing period requires an explicit go-live date and cannot predate it.';
  END IF;
  SELECT * INTO b FROM public.billing_period_bounds(p_sub.period_anchor_at, v_interval, p_at);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.business_id = p_sub.business_id AND p.period_start = b.period_start AND p.shadow = p_shadow;
  IF FOUND THEN
    -- A real period that has been invoiced (or closed) is final: a late entry for it lands in the period that contains now.
    IF NOT p_shadow AND v_p.status <> 'open' AND p_at < now() THEN RETURN public._billing_ensure_period(p_sub, now(), p_shadow); END IF;
    RETURN v_p;
  END IF;
  v_terms := public.billing_resolve_terms(p_sub.business_id, b.period_start);
  IF v_terms IS NULL THEN RAISE EXCEPTION 'No billing terms were in force at the start of this period.'; END IF;
  INSERT INTO public.billing_periods(business_id, subscription_id, period_start, period_end, shadow, currency)
  VALUES (p_sub.business_id, p_sub.id, b.period_start, b.period_end, p_shadow, v_terms ->> 'currency') RETURNING * INTO v_p;
  v_amount := COALESCE((v_terms ->> 'subscription_amount')::NUMERIC, 0);
  v_waived := p_sub.billing_paused OR v_off OR (p_sub.trial_end IS NOT NULL AND b.period_start < p_sub.trial_end);
  v_why := CASE WHEN p_sub.billing_paused THEN 'Billing is paused' WHEN v_off THEN 'Subscriptions are switched off' WHEN v_waived THEN 'Free trial' END;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, shadow, currency, charged_amount, source, idempotency_key, reason, metadata)
  VALUES (p_sub.business_id, v_p.id, 'subscription_charge', p_shadow, v_terms ->> 'currency', CASE WHEN v_waived THEN 0 ELSE v_amount END, 'engine',
          'sub:' || v_p.id, v_why, jsonb_build_object('plan_amount', v_amount, 'waived', v_waived, 'plan_code', v_terms ->> 'plan_code', 'plan_version', v_terms -> 'plan_version'));
  UPDATE public.billing_periods SET subscription_amount = CASE WHEN v_waived THEN 0 ELSE v_amount END WHERE id = v_p.id RETURNING * INTO v_p;
  RETURN v_p;
END;
$function$;

-- 7. Preview: what a price change would do, before anyone approves it. Read-only; works from the same helpers the real change uses.
CREATE OR REPLACE FUNCTION public.admin_billing_preview_price_change(p_plan_id UUID, p_params JSONB, p_effective_from TIMESTAMPTZ DEFAULT NULL, p_audience TEXT DEFAULT 'new_only', p_keep_overrides BOOLEAN DEFAULT TRUE)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan public.billing_plans%ROWTYPE;
  v_cur public.billing_plan_versions%ROWTYPE;
  v_t JSONB;
  v_cur_t JSONB;
  v_key TEXT;
  v_changes JSONB := '[]'::JSONB;
  v_warn JSONB := '[]'::JSONB;
  v_rows JSONB;
  v_total INTEGER;
  v_affected INTEGER;
  v_trial INTEGER;
  v_over INTEGER;
  v_from TIMESTAMPTZ := COALESCE(p_effective_from, now());
  v_labels JSONB := '{"subscription_amount":"Subscription","billing_interval_months":"Billing period (months)","free_trial_days":"Free trial (days)","onboarding_free_orders":"Launch free orders",
    "monthly_free_orders":"Free orders each period","transaction_fee_percentage":"Commission (%)","transaction_fee_min":"Smallest commission per order","transaction_fee_max":"Largest commission per order",
    "transaction_fee_cycle_cap":"Most in commission per period","min_billable_order_amount":"Orders below this are not charged","max_users":"Most users","max_branches":"Most branches","currency":"Currency"}';
BEGIN
  PERFORM public._billing_admin_only();
  IF p_audience IS NULL OR p_audience NOT IN ('new_only', 'new_and_existing') THEN RAISE EXCEPTION 'Choose new subscribers only, or new and existing subscribers.'; END IF;
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = p_plan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  SELECT * INTO v_cur FROM public._billing_plan_version_at(p_plan_id, now());
  v_t := public._billing_plan_terms_from_params(p_params);
  v_cur_t := to_jsonb(v_cur);
  FOR v_key IN SELECT jsonb_object_keys(v_labels) LOOP
    IF v_cur.id IS NULL OR (v_cur_t -> v_key) IS DISTINCT FROM (v_t -> v_key) THEN
      v_changes := v_changes || jsonb_build_object('field', v_key, 'label', v_labels ->> v_key, 'from', CASE WHEN v_cur.id IS NULL THEN NULL ELSE v_cur_t -> v_key END, 'to', v_t -> v_key);
    END IF;
  END LOOP;

  SELECT count(*), count(*) FILTER (WHERE skip_reason IS NULL), count(*) FILTER (WHERE skip_reason IS NULL AND in_trial), count(*) FILTER (WHERE skip_reason IS NULL AND has_overrides)
  INTO v_total, v_affected, v_trial, v_over FROM public._billing_price_change_targets(p_plan_id, v_from);
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.business_name), '[]'::JSONB) INTO v_rows FROM (
    SELECT t.business_id, t.business_name, t.current_version, t.current_amount, t.current_fee_pct, t.has_overrides, t.in_trial, t.change_from, t.skip_reason
    FROM public._billing_price_change_targets(p_plan_id, v_from) t ORDER BY t.business_name LIMIT 100) r;

  IF p_audience = 'new_and_existing' THEN
    IF v_affected > 0 THEN v_warn := v_warn || to_jsonb(format('%s existing business(es) move to the new terms at the start of their next billing cycle, never earlier.', v_affected)); END IF;
    IF v_trial > 0 THEN v_warn := v_warn || to_jsonb(format('%s of them are still in their free trial; the new subscription price applies to the periods after it.', v_trial)); END IF;
    IF v_over > 0 THEN v_warn := v_warn || to_jsonb(CASE WHEN COALESCE(p_keep_overrides, TRUE) THEN format('%s have custom pricing, which is kept on top of the new terms.', v_over) ELSE format('%s have custom pricing, which is REMOVED so they pay the plan''s new terms.', v_over) END); END IF;
    IF v_total > v_affected THEN v_warn := v_warn || to_jsonb(format('%s business(es) are not moved (see the list).', v_total - v_affected)); END IF;
  ELSIF v_total > 0 THEN
    v_warn := v_warn || to_jsonb(format('%s existing business(es) stay on their current terms until you move them.', v_total));
  END IF;
  IF jsonb_array_length(v_changes) = 0 THEN v_warn := v_warn || to_jsonb('These terms are the same as the version in force: nothing would change.'::TEXT); END IF;

  RETURN jsonb_build_object(
    'plan', jsonb_build_object('id', v_plan.id, 'code', v_plan.code, 'name', v_plan.name, 'business_type', v_plan.business_type),
    'current_version', v_cur.version, 'current_terms', CASE WHEN v_cur.id IS NULL THEN NULL ELSE v_cur_t END, 'proposed_terms', v_t,
    'effective_from', p_effective_from, 'audience', p_audience, 'keep_overrides', COALESCE(p_keep_overrides, TRUE),
    'changes', v_changes, 'warnings', v_warn,
    'existing', jsonb_build_object('total', v_total, 'affected', v_affected, 'skipped', v_total - v_affected, 'businesses', v_rows, 'truncated', v_total > 100));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_preview_price_change(UUID, JSONB, TIMESTAMPTZ, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_preview_price_change(UUID, JSONB, TIMESTAMPTZ, TEXT, BOOLEAN) TO authenticated;

-- 8. Schedule a price change. The preview's affected count is sent back, so a stale preview is refused.
CREATE OR REPLACE FUNCTION public.admin_billing_schedule_price_change(p_plan_id UUID, p_params JSONB, p_effective_from TIMESTAMPTZ, p_audience TEXT, p_keep_overrides BOOLEAN, p_expected_affected INTEGER, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_plan public.billing_plans%ROWTYPE;
  v_cur public.billing_plan_versions%ROWTYPE;
  v_new public.billing_plan_versions%ROWTYPE;
  v_affected INTEGER := 0;
  v_id UUID;
BEGIN
  IF p_audience IS NULL OR p_audience NOT IN ('new_only', 'new_and_existing') THEN RAISE EXCEPTION 'Choose new subscribers only, or new and existing subscribers.'; END IF;
  IF p_effective_from IS NULL THEN RAISE EXCEPTION 'Choose when the new price starts.'; END IF;
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = p_plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  SELECT * INTO v_cur FROM public._billing_plan_version_at(p_plan_id, now());
  IF v_cur.id IS NULL THEN RAISE EXCEPTION 'Publish the plan''s first version before scheduling a change to it.'; END IF;
  IF p_audience = 'new_and_existing' THEN
    SELECT count(*) INTO v_affected FROM public._billing_price_change_targets(p_plan_id, p_effective_from) WHERE skip_reason IS NULL;
    IF p_expected_affected IS DISTINCT FROM v_affected THEN
      RAISE EXCEPTION 'The number of businesses this would move is now %, not %. Review the preview again.', v_affected, COALESCE(p_expected_affected::TEXT, 'the number you saw');
    END IF;
  END IF;
  v_new := public._billing_new_plan_version(p_plan_id, p_params, 'scheduled', p_effective_from, v_reason);
  INSERT INTO public.billing_scheduled_changes(plan_id, version_id, audience, keep_overrides, expected_affected, reason, created_by)
  VALUES (p_plan_id, v_new.id, p_audience, COALESCE(p_keep_overrides, TRUE), CASE WHEN p_audience = 'new_and_existing' THEN v_affected END, v_reason, auth.uid()) RETURNING id INTO v_id;
  PERFORM public.write_audit_log('Price change scheduled', 'DrugXOne', 'billing_plan', p_plan_id, v_plan.code,
    jsonb_build_object('change_id', v_id, 'new_version', v_new.version, 'current_version', v_cur.version, 'effective_from', p_effective_from, 'audience', p_audience,
      'keep_overrides', COALESCE(p_keep_overrides, TRUE), 'businesses_to_move', v_affected, 'reason', v_reason,
      'previous', to_jsonb(v_cur) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata',
      'new', to_jsonb(v_new) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata'));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_schedule_price_change(UUID, JSONB, TIMESTAMPTZ, TEXT, BOOLEAN, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_schedule_price_change(UUID, JSONB, TIMESTAMPTZ, TEXT, BOOLEAN, INTEGER, TEXT) TO authenticated;

-- 9. Cancel a scheduled change, only before it starts. The record stays (who, when, why).
CREATE OR REPLACE FUNCTION public.admin_billing_cancel_scheduled_change(p_change_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_c public.billing_scheduled_changes%ROWTYPE;
  v_v public.billing_plan_versions%ROWTYPE;
  v_plan public.billing_plans%ROWTYPE;
BEGIN
  SELECT * INTO v_c FROM public.billing_scheduled_changes WHERE id = p_change_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Scheduled change not found.'; END IF;
  IF v_c.status <> 'pending' THEN RAISE EXCEPTION 'This change is already %, so it cannot be cancelled.', v_c.status; END IF;
  SELECT * INTO v_v FROM public.billing_plan_versions WHERE id = v_c.version_id FOR UPDATE;
  IF now() >= v_v.effective_from THEN RAISE EXCEPTION 'This change has reached its start moment and can no longer be cancelled. Schedule a new price change to reverse it.'; END IF;
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = v_c.plan_id;
  UPDATE public.billing_plan_versions SET status = 'cancelled', cancelled_at = now() WHERE id = v_v.id;
  UPDATE public.billing_scheduled_changes SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason WHERE id = v_c.id;
  PERFORM public.write_audit_log('Scheduled price change cancelled', 'DrugXOne', 'billing_plan', v_c.plan_id, v_plan.code,
    jsonb_build_object('change_id', v_c.id, 'version', v_v.version, 'was_to_start', v_v.effective_from, 'audience', v_c.audience, 'reason', v_reason, 'scheduled_reason', v_c.reason));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_cancel_scheduled_change(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_cancel_scheduled_change(UUID, TEXT) TO authenticated;

-- 10. Activation, run by the scheduler. A scheduled version becomes the published one; when the change was for existing subscribers too, each is given terms at the start of
-- their next billing cycle on or after the start moment (never in the past), keeping or clearing their custom pricing as chosen. Safe to run again.
CREATE OR REPLACE FUNCTION public.billing_apply_due_price_changes(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c public.billing_scheduled_changes%ROWTYPE;
  v_v public.billing_plan_versions%ROWTYPE;
  v_plan public.billing_plans%ROWTYPE;
  t RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_cur public.billing_subscription_terms%ROWTYPE;
  v_applied INTEGER;
  v_skipped INTEGER;
  v_already INTEGER;
  v_skips JSONB;
  v_done INTEGER := 0;
  v_name TEXT;
BEGIN
  FOR c IN SELECT x.* FROM public.billing_scheduled_changes x JOIN public.billing_plan_versions v ON v.id = x.version_id
           WHERE x.status = 'pending' AND v.status = 'scheduled' AND v.effective_from <= p_now ORDER BY v.effective_from, x.created_at FOR UPDATE OF x SKIP LOCKED LOOP
    SELECT * INTO v_v FROM public.billing_plan_versions WHERE id = c.version_id FOR UPDATE;
    SELECT * INTO v_plan FROM public.billing_plans WHERE id = c.plan_id;
    UPDATE public.billing_plan_versions SET status = 'retired', retired_at = p_now WHERE plan_id = c.plan_id AND status = 'published' AND id <> c.version_id;
    UPDATE public.billing_plan_versions SET status = 'published' WHERE id = c.version_id;
    v_applied := 0; v_skipped := 0; v_already := 0; v_skips := '[]'::JSONB;
    IF c.audience = 'new_and_existing' THEN
      FOR t IN SELECT * FROM public._billing_price_change_targets(c.plan_id, GREATEST(v_v.effective_from, p_now)) LOOP
        IF t.skip_reason IS NOT NULL THEN
          v_skipped := v_skipped + 1; v_skips := v_skips || jsonb_build_object('business', t.business_name, 'why', t.skip_reason);
          CONTINUE;
        END IF;
        -- a business that subscribed after the start moment is already on this version
        IF t.current_version >= v_v.version THEN v_already := v_already + 1; CONTINUE; END IF;
        SELECT * INTO v_sub FROM public._billing_lock_subscription(t.business_id);
        SELECT * INTO v_cur FROM public.billing_subscription_terms x WHERE x.subscription_id = v_sub.id AND x.effective_from <= p_now ORDER BY x.effective_from DESC LIMIT 1;
        BEGIN
          INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason, created_by)
          VALUES (v_sub.id, t.change_from, c.version_id, CASE WHEN c.keep_overrides THEN COALESCE(v_cur.overrides, '{}'::JSONB) ELSE '{}'::JSONB END,
                  'Scheduled price change: ' || c.reason, c.created_by);
          v_applied := v_applied + 1;
          SELECT b.name INTO v_name FROM public.businesses b WHERE b.id = t.business_id;
          PERFORM public.write_audit_log('Billing plan changed', v_name, 'billing_subscription_terms', v_sub.id, v_plan.code,
            jsonb_build_object('new_plan', v_plan.code, 'new_version', v_v.version, 'effective_from', t.change_from, 'kept_overrides', c.keep_overrides, 'scheduled_change', c.id, 'reason', c.reason),
            _business_id => t.business_id);
        EXCEPTION WHEN unique_violation OR raise_exception THEN
          v_skipped := v_skipped + 1; v_skips := v_skips || jsonb_build_object('business', t.business_name, 'why', left(SQLERRM, 120));
        END;
      END LOOP;
    END IF;
    UPDATE public.billing_scheduled_changes SET status = 'applied', applied_at = p_now,
      applied_result = jsonb_build_object('moved', v_applied, 'skipped', v_skipped, 'already_on_it', v_already, 'skipped_businesses', v_skips) WHERE id = c.id;
    PERFORM public.write_audit_log('Scheduled price change applied', 'DrugXOne', 'billing_plan', c.plan_id, v_plan.code,
      jsonb_build_object('change_id', c.id, 'version', v_v.version, 'audience', c.audience, 'moved', v_applied, 'skipped', v_skipped, 'reason', c.reason));
    v_done := v_done + 1;
  END LOOP;
  RETURN jsonb_build_object('applied', v_done);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_apply_due_price_changes(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_apply_due_price_changes(TIMESTAMPTZ) TO service_role;

-- 11. The review screens: pending and past changes, and the history of a plan.
CREATE OR REPLACE FUNCTION public.admin_billing_scheduled_changes(p_limit INTEGER DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  PERFORM public._billing_admin_only();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY (r.status = 'pending') DESC, r.effective_from DESC) FROM (
    SELECT c.id, p.id AS plan_id, p.code AS plan_code, p.name AS plan_name, v.version, v.effective_from, c.status, c.audience, c.keep_overrides, c.reason, c.created_at,
           (SELECT u.email FROM auth.users u WHERE u.id = c.created_by) AS created_by, c.applied_at, c.applied_result, c.cancelled_at, c.cancel_reason,
           (SELECT u.email FROM auth.users u WHERE u.id = c.cancelled_by) AS cancelled_by, c.expected_affected,
           v.subscription_amount, v.free_trial_days, v.onboarding_free_orders, v.monthly_free_orders, v.transaction_fee_percentage, v.transaction_fee_min, v.transaction_fee_max, v.transaction_fee_cycle_cap
    FROM public.billing_scheduled_changes c JOIN public.billing_plan_versions v ON v.id = c.version_id JOIN public.billing_plans p ON p.id = c.plan_id
    ORDER BY (c.status = 'pending') DESC, v.effective_from DESC LIMIT v_limit) r), '[]'::JSONB);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_scheduled_changes(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_scheduled_changes(INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_billing_plan_history(p_plan_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._billing_admin_only();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.version DESC) FROM (
    SELECT v.id, v.version, v.status, v.effective_from, v.created_at, (SELECT u.email FROM auth.users u WHERE u.id = v.created_by) AS created_by, v.reason, v.retired_at, v.cancelled_at,
           v.subscription_amount, v.billing_interval_months, v.free_trial_days, v.onboarding_free_orders, v.monthly_free_orders, v.transaction_fee_percentage, v.transaction_fee_min,
           v.transaction_fee_max, v.transaction_fee_cycle_cap, v.min_billable_order_amount,
           (SELECT count(*) FROM public.billing_subscriptions s JOIN LATERAL (SELECT x.plan_version_id FROM public.billing_subscription_terms x WHERE x.subscription_id = s.id AND x.effective_from <= now() ORDER BY x.effective_from DESC LIMIT 1) t ON TRUE
             WHERE t.plan_version_id = v.id) AS businesses_on_it,
           c.audience, c.status AS change_status, c.keep_overrides
    FROM public.billing_plan_versions v LEFT JOIN public.billing_scheduled_changes c ON c.version_id = v.id WHERE v.plan_id = p_plan_id) r), '[]'::JSONB);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_plan_history(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_plan_history(UUID) TO authenticated;

-- 12. The two switches. They change what is assessed FROM THEN ON; periods and orders already assessed keep what was recorded.
CREATE OR REPLACE FUNCTION public.admin_billing_set_charging(p_subscriptions BOOLEAN, p_commissions BOOLEAN, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old public.billing_settings%ROWTYPE;
BEGIN
  IF p_subscriptions IS NULL OR p_commissions IS NULL THEN RAISE EXCEPTION 'Say whether subscriptions and commissions are charged.'; END IF;
  SELECT * INTO v_old FROM public.billing_settings WHERE id FOR UPDATE;
  IF v_old.subscriptions_enabled = p_subscriptions AND v_old.commissions_enabled = p_commissions THEN RAISE EXCEPTION 'Those are already the settings.'; END IF;
  UPDATE public.billing_settings SET subscriptions_enabled = p_subscriptions, commissions_enabled = p_commissions, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing charging switches changed', 'DrugXOne', 'billing_settings', NULL, 'Charging switches',
    jsonb_build_object('previous', jsonb_build_object('subscriptions', v_old.subscriptions_enabled, 'commissions', v_old.commissions_enabled),
                       'new', jsonb_build_object('subscriptions', p_subscriptions, 'commissions', p_commissions), 'reason', v_reason));
  RETURN jsonb_build_object('subscriptions', p_subscriptions, 'commissions', p_commissions);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_charging(BOOLEAN, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_charging(BOOLEAN, BOOLEAN, TEXT) TO authenticated;

COMMIT;
