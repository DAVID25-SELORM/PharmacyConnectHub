-- Platform billing, Phase 6 (part 2): going live, account status for unpaid invoices, notices, and monitoring.
-- Needs 20261206100000_platform_billing_rollout_schema.sql. NOTHING here switches real billing on by itself: billing stays DISABLED until an administrator passes the readiness checks
-- and types the confirmation (admin_billing_activate_platform), and even then every business is held back in shadow unless the administrator chooses otherwise.
--
--   * Real billing never looks back. A business goes live at a moment (activated_at): orders delivered before it are never assessed, its first real period starts at it, its free trial
--     restarts from it. A subscription started while real billing is running is live from its start and cannot start in the past.
--   * An unpaid invoice moves the account through past_due, grace_period (an extension an administrator granted) and suspended, and back to active once everything is paid. That is STATUS only.
--     What suspended means in practice is one policy setting, 'none' (warnings only) by default; 'block_new_orders' makes a suspended buyer or seller unable to start NEW orders.
--   * Notices (in the app, once per event): invoice issued, payment received, invoice overdue, trial ending, free orders almost used up, grace ending, suspended, restored.
--   * The scheduled run records that it ran; reconciliation flags a run that has stopped, and any real billing dated before a business went live.

-- ---------------------------------------------------------------------------
-- 1. Existing functions that learn about going live
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_start_subscription(p_business_id UUID, p_plan_code TEXT, p_billing_starts_at TIMESTAMPTZ, p_billing_mode TEXT, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  SELECT * INTO v_ver FROM public.billing_plan_versions WHERE plan_id = v_plan.id AND status = 'published' ORDER BY version DESC LIMIT 1;
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
$$;

CREATE OR REPLACE FUNCTION public.admin_billing_set_subscription_mode(p_business_id UUID, p_mode TEXT, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_name TEXT;
BEGIN
  IF p_mode IS NOT NULL AND p_mode NOT IN ('disabled', 'shadow') THEN RAISE EXCEPTION 'Choose disabled, shadow, or follow the platform setting. Active billing is not released yet.'; END IF;
  SELECT * INTO v_sub FROM public.billing_subscriptions WHERE business_id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This business has no subscription.'; END IF;
  IF p_mode = 'shadow' AND v_sub.activated_at IS NOT NULL THEN
    RAISE EXCEPTION 'Real billing has already started for this business, so it cannot go back to shadow. Switch its billing off (disabled) instead.';
  END IF;
  SELECT name INTO v_name FROM public.businesses WHERE id = p_business_id;
  UPDATE public.billing_subscriptions SET billing_mode = p_mode WHERE id = v_sub.id;
  PERFORM public.write_audit_log('Billing mode changed for a business', v_name, 'billing_subscription', v_sub.id, 'Billing mode',
    jsonb_build_object('previous', v_sub.billing_mode, 'new', p_mode, 'reason', v_reason), _business_id => p_business_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.billing_open_periods(p_now TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform TEXT;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_id UUID;
  v_mode TEXT;
  v_shadow BOOLEAN;
  v_at TIMESTAMPTZ;
  v_last TIMESTAMPTZ;
  v_first TIMESTAMPTZ;
  v_origin TIMESTAMPTZ;
  v_p public.billing_periods%ROWTYPE;
  v_before INTEGER;
  v_created INTEGER := 0;
  n INTEGER;
BEGIN
  SELECT s.mode INTO v_platform FROM public.billing_settings s WHERE s.id;
  IF COALESCE(v_platform, 'disabled') = 'disabled' THEN RETURN 0; END IF;
  FOR v_id IN SELECT s.id FROM public.billing_subscriptions s WHERE s.billing_starts_at <= p_now ORDER BY s.id LOOP
    BEGIN
      SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.id = v_id FOR UPDATE;
      v_mode := public._billing_base_mode(v_sub.billing_mode, v_platform);
      CONTINUE WHEN v_mode = 'disabled';
      v_shadow := v_mode = 'shadow';
      -- Start from the first month that has no period yet (a month can be skipped when a later month's order was assessed before the run reached it), so every month gets its subscription charge.
      SELECT min(p.period_start) INTO v_first FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow;
      -- Real billing never looks back: its first period starts when it went live (the shadow months were never charged).
      v_origin := CASE WHEN v_shadow THEN v_sub.billing_starts_at ELSE GREATEST(v_sub.billing_starts_at, COALESCE(v_sub.activated_at, v_sub.billing_starts_at)) END;
      IF v_first IS NULL OR v_first > v_origin THEN
        v_at := v_origin;
      ELSE
        SELECT min(p.period_end) INTO v_at FROM public.billing_periods p
        WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow
          AND NOT EXISTS (SELECT 1 FROM public.billing_periods n WHERE n.business_id = p.business_id AND n.shadow = p.shadow AND n.period_start = p.period_end);
      END IF;
      n := 0;
      WHILE v_at <= p_now AND n < 36 AND (v_sub.ended_at IS NULL OR v_at < v_sub.ended_at) LOOP
        SELECT count(*) INTO v_before FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow;
        v_p := public._billing_ensure_period(v_sub, v_at, v_shadow);
        IF (SELECT count(*) FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow) > v_before THEN v_created := v_created + 1; END IF;
        v_at := v_p.period_end;
        n := n + 1;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'billing could not open periods for subscription %: %', v_id, SQLERRM;
    END;
  END LOOP;
  RETURN v_created;
END;
$$;

CREATE OR REPLACE FUNCTION public._billing_open_real_period(p_sub public.billing_subscriptions)
RETURNS public.billing_periods
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_p public.billing_periods%ROWTYPE;
BEGIN
  IF public.billing_effective_mode(p_sub.business_id) <> 'active' OR COALESCE(p_sub.activated_at, p_sub.billing_starts_at) > now() THEN
    RAISE EXCEPTION 'Real billing is not running for this business yet, so there is no bill to put this on.';
  END IF;
  v_p := public._billing_ensure_period(p_sub, now(), FALSE);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.id = v_p.id FOR UPDATE;
  RETURN v_p;
END;
$$;

CREATE OR REPLACE FUNCTION public.billing_my_overview(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_b RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_terms JSONB;
  v_mode TEXT;
  v_per public.billing_periods%ROWTYPE;
  v_is_ws BOOLEAN;
  v_state TEXT;
  v_granted INTEGER := 0;
  v_used INTEGER := 0;
  v_cap NUMERIC;
  v_next TIMESTAMPTZ;
  v_interval INTEGER;
  b RECORD;
  v_active BOOLEAN;
  v_plan_name TEXT;
BEGIN
  IF NOT public.billing_user_can_view(p_business_id) THEN RAISE EXCEPTION 'You do not have permission to see this business''s billing.'; END IF;
  SELECT bz.id, bz.name, bz.type::TEXT AS type INTO v_b FROM public.businesses bz WHERE bz.id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.'; END IF;
  v_is_ws := v_b.type = 'wholesaler';
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('business_type', v_b.type, 'state', 'no_subscription'); END IF;

  v_terms := COALESCE(public.billing_resolve_terms(p_business_id, now()), public.billing_resolve_terms(p_business_id, v_sub.billing_starts_at));
  v_mode := public.billing_effective_mode(p_business_id);
  v_active := v_mode = 'active' AND COALESCE(v_sub.activated_at, v_sub.billing_starts_at) <= now();
  v_state := CASE WHEN v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN 'cancelled'
                  WHEN v_sub.billing_paused THEN 'paused'
                  WHEN NOT v_active THEN 'not_started'
                  WHEN v_sub.status = 'trialing' THEN 'trialing'
                  WHEN v_sub.status IN ('past_due', 'grace_period', 'suspended') THEN v_sub.status
                  ELSE 'active' END;
  SELECT pl.name INTO v_plan_name FROM public.billing_plans pl WHERE pl.id = (v_terms ->> 'plan_id')::UUID;

  v_interval := COALESCE((v_terms ->> 'billing_interval_months')::INTEGER, 1);
  IF v_active THEN
    SELECT * INTO v_per FROM public.billing_periods p WHERE p.business_id = p_business_id AND NOT p.shadow AND p.period_start <= now() AND p.period_end > now();
    IF v_per.id IS NULL THEN
      SELECT * INTO b FROM public.billing_period_bounds(v_sub.period_anchor_at, v_interval, GREATEST(now(), v_sub.period_anchor_at));
      v_next := b.period_end;
    ELSE
      v_next := v_per.period_end;
    END IF;
    IF v_is_ws THEN
      SELECT COALESCE(sum(g.quantity), 0) INTO v_granted FROM public.billing_allowance_grants g WHERE g.business_id = p_business_id AND (g.expires_at IS NULL OR g.expires_at > now());
      SELECT count(*) INTO v_used FROM public.order_billing_assessments a WHERE a.business_id = p_business_id AND NOT a.shadow AND a.free_source = 'onboarding';
    END IF;
  END IF;
  v_cap := (v_terms ->> 'transaction_fee_cycle_cap')::NUMERIC;

  RETURN jsonb_build_object(
    'business_type', v_b.type, 'business_name', v_b.name, 'state', v_state, 'restriction', public.billing_restriction_level(p_business_id), 'currency', COALESCE(v_terms ->> 'currency', 'GHS'),
    'plan', CASE WHEN v_terms IS NULL THEN NULL ELSE jsonb_build_object(
      'name', v_plan_name, 'code', v_terms ->> 'plan_code', 'subscription_amount', (v_terms ->> 'subscription_amount')::NUMERIC, 'billing_interval_months', v_interval,
      'free_trial_days', (v_terms ->> 'free_trial_days')::INTEGER,
      'onboarding_free_orders', CASE WHEN v_is_ws THEN (v_terms ->> 'onboarding_free_orders')::INTEGER END,
      'monthly_free_orders', CASE WHEN v_is_ws THEN (v_terms ->> 'monthly_free_orders')::INTEGER END,
      'transaction_fee_percentage', CASE WHEN v_is_ws THEN (v_terms ->> 'transaction_fee_percentage')::NUMERIC END,
      'transaction_fee_min', CASE WHEN v_is_ws THEN (v_terms ->> 'transaction_fee_min')::NUMERIC END,
      'transaction_fee_max', CASE WHEN v_is_ws THEN (v_terms ->> 'transaction_fee_max')::NUMERIC END,
      'transaction_fee_cycle_cap', CASE WHEN v_is_ws THEN v_cap END) END,
    'subscription', jsonb_build_object(
      'status', v_sub.status, 'billing_starts_at', v_sub.billing_starts_at, 'trial_start', v_sub.trial_start, 'trial_end', v_sub.trial_end,
      'trial_days_left', CASE WHEN v_sub.trial_end IS NOT NULL AND v_sub.trial_end > now() THEN ceil(extract(epoch FROM (v_sub.trial_end - now())) / 86400)::INTEGER END,
      'next_billing_date', v_next, 'grace_until', v_sub.grace_until, 'past_due_since', v_sub.past_due_since, 'activated_at', v_sub.activated_at, 'cancel_at_period_end', v_sub.cancel_at_period_end, 'ends_at', v_sub.ended_at, 'paused', v_sub.billing_paused,
      'exempt_from_transaction_fees', CASE WHEN v_is_ws THEN v_sub.exempt_from_transaction_fees END),
    'free_orders', CASE WHEN v_is_ws AND v_active THEN jsonb_build_object(
      'launch_granted', v_granted, 'launch_used', v_used, 'launch_remaining', GREATEST(v_granted - v_used, 0),
      'monthly_allowance', COALESCE((v_terms ->> 'monthly_free_orders')::INTEGER, 0), 'monthly_used', COALESCE(v_per.free_monthly_orders, 0)) END,
    'current_period', CASE WHEN v_per.id IS NULL THEN NULL ELSE jsonb_build_object(
      'period_start', v_per.period_start, 'period_end', v_per.period_end, 'status', v_per.status, 'subscription_amount', v_per.subscription_amount,
      'transaction_fees_amount', CASE WHEN v_is_ws THEN v_per.transaction_fees_amount END, 'debits_amount', v_per.debits_amount, 'credits_amount', v_per.credits_amount,
      'amount_due', v_per.amount_due, 'amount_paid', v_per.amount_paid, 'outstanding_amount', v_per.outstanding_amount,
      'billable_gmv', CASE WHEN v_is_ws THEN v_per.billable_gmv END, 'eligible_orders', CASE WHEN v_is_ws THEN v_per.eligible_orders END,
      'free_onboarding_orders', CASE WHEN v_is_ws THEN v_per.free_onboarding_orders END, 'free_monthly_orders', CASE WHEN v_is_ws THEN v_per.free_monthly_orders END,
      'chargeable_orders', CASE WHEN v_is_ws THEN v_per.chargeable_orders END, 'fees_before_cap', CASE WHEN v_is_ws THEN v_per.fees_before_cap END,
      'cap', CASE WHEN v_is_ws THEN v_cap END, 'cap_remaining', CASE WHEN v_is_ws AND v_cap IS NOT NULL THEN GREATEST(v_cap - v_per.transaction_fees_amount, 0) END) END,
    'periods', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.period_start DESC) FROM (
      SELECT p.period_start, p.period_end, p.status, p.subscription_amount, CASE WHEN v_is_ws THEN p.transaction_fees_amount END AS transaction_fees_amount, p.debits_amount, p.credits_amount,
             p.amount_due, p.amount_paid, p.outstanding_amount, CASE WHEN v_is_ws THEN p.eligible_orders END AS eligible_orders, CASE WHEN v_is_ws THEN p.chargeable_orders END AS chargeable_orders
      FROM public.billing_periods p WHERE p.business_id = p_business_id AND NOT p.shadow ORDER BY p.period_start DESC LIMIT 12) x), '[]'::JSONB),
    'orders', CASE WHEN NOT v_is_ws THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.assessed_at DESC) FROM (
      SELECT o.order_number, a.delivered_at, a.assessed_at, a.kind, a.adjustment_seq, a.billable_gmv, a.outcome, a.free_source, a.free_seq, a.percentage, a.fee_after_limits, a.cap_adjustment, a.charged_amount
      FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id = p_business_id AND NOT a.shadow ORDER BY a.assessed_at DESC LIMIT 50) x), '[]'::JSONB) END,
    'credits_and_adjustments', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
      SELECT e.created_at, e.entry_type, e.charged_amount, e.credit_amount, e.reason FROM public.billing_ledger_entries e
      WHERE e.business_id = p_business_id AND NOT e.shadow AND e.entry_type IN ('manual_credit', 'manual_debit', 'promotional_credit', 'fee_waiver', 'refund', 'reversal') ORDER BY e.created_at DESC LIMIT 30) x), '[]'::JSONB));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_billing_organizations(
  p_flavor TEXT DEFAULT 'real', p_business_type TEXT DEFAULT NULL, p_plan_code TEXT DEFAULT NULL, p_status TEXT DEFAULT NULL, p_search TEXT DEFAULT NULL, p_limit INTEGER DEFAULT 25, p_offset INTEGER DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shadow BOOLEAN;
  v_total INTEGER;
  v_rows JSONB;
  v_search TEXT := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  PERFORM public._billing_admin_only();
  IF p_flavor NOT IN ('real', 'shadow') THEN RAISE EXCEPTION 'Choose real or shadow.'; END IF;
  v_shadow := p_flavor = 'shadow';
  IF p_business_type IS NOT NULL AND p_business_type NOT IN ('pharmacy', 'wholesaler') THEN RAISE EXCEPTION 'Choose pharmacies or wholesalers.'; END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 OR p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Choose between 1 and 200 rows.'; END IF;

  WITH base AS (
    SELECT s.*, b.name, b.type::TEXT AS btype, x.t AS terms
    FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id
    CROSS JOIN LATERAL (SELECT public.billing_resolve_terms(s.business_id, GREATEST(now(), s.billing_starts_at)) AS t) x
    WHERE (p_business_type IS NULL OR b.type::TEXT = p_business_type) AND (p_plan_code IS NULL OR x.t ->> 'plan_code' = p_plan_code) AND (p_status IS NULL OR s.status = p_status)
      AND (v_search IS NULL OR b.name ILIKE '%' || v_search || '%'))
  SELECT count(*) INTO v_total FROM base;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.name), '[]'::JSONB) INTO v_rows FROM (
    SELECT s.business_id, b.name, b.type::TEXT AS type, x.t ->> 'plan_code' AS plan_code, pl.name AS plan_name, s.status, s.billing_mode, public.billing_effective_mode(s.business_id) AS effective_mode,
           s.billing_starts_at, s.activated_at, s.grace_until, s.trial_end, s.exempt_from_transaction_fees AS exempt, s.billing_paused AS paused,
           per.period_start, per.period_end, COALESCE(per.subscription_amount, 0) AS subscription_amount, COALESCE(per.transaction_fees_amount, 0) AS transaction_fees_amount,
           COALESCE(per.eligible_orders, 0) AS eligible_orders, COALESCE(per.free_onboarding_orders, 0) AS free_onboarding_orders, COALESCE(per.free_monthly_orders, 0) AS free_monthly_orders,
           COALESCE(per.chargeable_orders, 0) AS chargeable_orders, COALESCE(per.amount_due, 0) AS amount_due, COALESCE(per.outstanding_amount, 0) AS outstanding_amount,
           COALESCE((SELECT sum(g.quantity) FROM public.billing_allowance_grants g WHERE g.business_id = s.business_id), 0) AS launch_granted,
           (SELECT count(*) FROM public.order_billing_assessments a WHERE a.business_id = s.business_id AND a.shadow = v_shadow AND a.free_source = 'onboarding') AS launch_used,
           (SELECT max(a.assessed_at) FROM public.order_billing_assessments a WHERE a.business_id = s.business_id AND a.shadow = v_shadow) AS last_assessed_at
    FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id
    CROSS JOIN LATERAL (SELECT public.billing_resolve_terms(s.business_id, GREATEST(now(), s.billing_starts_at)) AS t) x
    LEFT JOIN public.billing_plans pl ON pl.id = (x.t ->> 'plan_id')::UUID
    LEFT JOIN LATERAL (SELECT p.* FROM public.billing_periods p WHERE p.business_id = s.business_id AND p.shadow = v_shadow ORDER BY (p.period_start <= now() AND p.period_end > now()) DESC, p.period_start DESC LIMIT 1) per ON TRUE
    WHERE (p_business_type IS NULL OR b.type::TEXT = p_business_type) AND (p_plan_code IS NULL OR x.t ->> 'plan_code' = p_plan_code) AND (p_status IS NULL OR s.status = p_status)
      AND (v_search IS NULL OR b.name ILIKE '%' || v_search || '%')
    ORDER BY b.name LIMIT p_limit OFFSET p_offset) r;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows, 'flavor', p_flavor);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_billing_overview(
  p_from TIMESTAMPTZ DEFAULT NULL, p_to TIMESTAMPTZ DEFAULT NULL, p_business_type TEXT DEFAULT NULL, p_plan_code TEXT DEFAULT NULL, p_subscription_status TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ := COALESCE(p_from, now() - interval '30 days');
  v_to TIMESTAMPTZ := COALESCE(p_to, now() + interval '1 day');
  v_ids UUID[];
  v_subs JSONB;
  v_real JSONB;
  v_shadow JSONB;
  v_paying INTEGER;
  v_mkt JSONB;
BEGIN
  PERFORM public._billing_admin_only();
  IF v_to <= v_from THEN RAISE EXCEPTION 'Choose a period that ends after it starts.'; END IF;
  IF p_business_type IS NOT NULL AND p_business_type NOT IN ('pharmacy', 'wholesaler') THEN RAISE EXCEPTION 'Choose pharmacies or wholesalers.'; END IF;
  IF p_subscription_status IS NOT NULL AND p_subscription_status NOT IN ('trialing', 'active', 'past_due', 'grace_period', 'suspended', 'cancelled') THEN RAISE EXCEPTION 'Unknown subscription status.'; END IF;

  WITH subs AS (
    SELECT s.business_id, b.type::TEXT AS type, s.status, s.billing_paused AS paused, s.exempt_from_transaction_fees AS exempt, (x.t ->> 'subscription_amount')::NUMERIC AS amount,
           COALESCE((x.t ->> 'billing_interval_months')::INTEGER, 1) AS interval_months, COALESCE(s.activated_at, s.billing_starts_at) AS starts_at
    FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id
    CROSS JOIN LATERAL (SELECT public.billing_resolve_terms(s.business_id, GREATEST(now(), s.billing_starts_at)) AS t) x
    WHERE (p_business_type IS NULL OR b.type::TEXT = p_business_type) AND (p_plan_code IS NULL OR x.t ->> 'plan_code' = p_plan_code) AND (p_subscription_status IS NULL OR s.status = p_subscription_status))
  SELECT COALESCE(array_agg(business_id), ARRAY[]::UUID[]),
    jsonb_build_object(
      'total', count(*), 'trialing', count(*) FILTER (WHERE status = 'trialing'), 'active', count(*) FILTER (WHERE status = 'active'),
      'past_due', count(*) FILTER (WHERE status IN ('past_due', 'grace_period')), 'suspended', count(*) FILTER (WHERE status = 'suspended'), 'cancelled', count(*) FILTER (WHERE status = 'cancelled'),
      'paused', count(*) FILTER (WHERE paused), 'exempt', count(*) FILTER (WHERE exempt),
      'paying_pharmacies', count(*) FILTER (WHERE type = 'pharmacy' AND status = 'active' AND NOT paused AND amount > 0 AND starts_at <= now()),
      'paying_wholesalers', count(*) FILTER (WHERE type = 'wholesaler' AND status = 'active' AND NOT paused AND amount > 0 AND starts_at <= now()),
      'contracted_mrr', COALESCE(round(sum(amount / interval_months) FILTER (WHERE status = 'active' AND NOT paused AND starts_at <= now()), 2), 0))
  INTO v_ids, v_subs FROM subs;

  v_real := public._billing_flavor_summary(FALSE, v_from, v_to, v_ids);
  v_shadow := public._billing_flavor_summary(TRUE, v_from, v_to, v_ids);
  SELECT count(DISTINCT e.business_id) INTO v_paying FROM public.billing_ledger_entries e WHERE NOT e.shadow AND e.business_id = ANY (v_ids) AND e.created_at >= v_from AND e.created_at < v_to AND e.charged_amount > 0;

  SELECT jsonb_build_object(
    'created_orders', count(*) FILTER (WHERE o.created_at >= v_from AND o.created_at < v_to),
    'created_value', COALESCE(sum(o.total_ghs) FILTER (WHERE o.created_at >= v_from AND o.created_at < v_to), 0),
    'cancelled_value', COALESCE(sum(o.total_ghs) FILTER (WHERE o.created_at >= v_from AND o.created_at < v_to AND o.status = 'cancelled'), 0),
    'completed_orders', count(*) FILTER (WHERE o.status = 'delivered' AND o.delivered_at >= v_from AND o.delivered_at < v_to),
    'completed_gmv', COALESCE(round(sum(COALESCE(o.effective_total_ghs, o.total_ghs) - COALESCE(o.delivery_fee_ghs, 0)) FILTER (WHERE o.status = 'delivered' AND o.delivered_at >= v_from AND o.delivered_at < v_to), 2), 0))
  INTO v_mkt FROM public.orders o WHERE (o.created_at >= v_from AND o.created_at < v_to) OR (o.delivered_at >= v_from AND o.delivered_at < v_to);

  RETURN jsonb_build_object('from', v_from, 'to', v_to, 'platform_mode', (SELECT s.mode FROM public.billing_settings s WHERE s.id), 'currency', (SELECT s.currency FROM public.billing_settings s WHERE s.id),
    'marketplace', v_mkt, 'real', v_real, 'shadow', v_shadow, 'subscriptions', v_subs,
    'revenue_per_paying_organization', CASE WHEN v_paying > 0 THEN round(((v_real ->> 'accrued_revenue')::NUMERIC) / v_paying, 2) END, 'paying_organizations_in_period', v_paying);
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Restriction: separate from billing. What a suspended business may still do is decided by one policy setting, off by default.
-- ---------------------------------------------------------------------------
-- 'none' unless the policy is block_new_orders AND the business is suspended for an unpaid invoice while real billing is running for it.
CREATE OR REPLACE FUNCTION public.billing_restriction_level(p_business_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_policy TEXT;
  v_status TEXT;
BEGIN
  SELECT s.enforcement INTO v_policy FROM public.billing_settings s WHERE s.id;
  IF v_policy IS DISTINCT FROM 'block_new_orders' THEN RETURN 'none'; END IF;
  SELECT s.status INTO v_status FROM public.billing_subscriptions s WHERE s.business_id = p_business_id AND s.activated_at IS NOT NULL AND s.activated_at <= now();
  IF v_status = 'suspended' AND public.billing_effective_mode(p_business_id) = 'active' THEN RETURN 'new_orders'; END IF;
  RETURN 'none';
END;
$$;
REVOKE ALL ON FUNCTION public.billing_restriction_level(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_restriction_level(UUID) TO service_role;

-- The only place a billing state can stop anything: a NEW order is refused when the buyer or the seller is restricted. Everything already in progress (accepted, dispatched, delivered,
-- returns, payments) is untouched. If the check itself ever fails, the order goes through: billing never blocks trade by accident.
CREATE OR REPLACE FUNCTION public.billing_block_new_orders()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_buyer TEXT := 'none';
  v_seller TEXT := 'none';
BEGIN
  IF (SELECT s.enforcement FROM public.billing_settings s WHERE s.id) IS DISTINCT FROM 'block_new_orders' THEN RETURN NEW; END IF;
  BEGIN
    v_buyer := public.billing_restriction_level(NEW.pharmacy_id);
    v_seller := public.billing_restriction_level(NEW.wholesaler_id);
  EXCEPTION WHEN OTHERS THEN
    RETURN NEW;
  END;
  IF v_buyer <> 'none' THEN RAISE EXCEPTION 'Your DrugXOne subscription is suspended because an invoice is overdue, so new orders cannot be placed. Please pay the overdue invoice or contact DrugXOne.'; END IF;
  IF v_seller <> 'none' THEN RAISE EXCEPTION 'This supplier is not accepting new orders right now.'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_block_new_orders() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_orders_billing_block_new ON public.orders;
CREATE TRIGGER trg_orders_billing_block_new BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.billing_block_new_orders();

-- ---------------------------------------------------------------------------
-- 3. Notices (in the app's notification bell; once per event; never to the person who caused it)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_notify_once(p_business_id UUID, p_key TEXT, p_event TEXT, p_title TEXT, p_body TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_enabled BOOLEAN;
  v_type TEXT;
  v_id UUID;
  v_n INTEGER := 0;
BEGIN
  SELECT COALESCE((s.notifications ->> p_event)::BOOLEAN, TRUE) INTO v_enabled FROM public.billing_settings s WHERE s.id;
  INSERT INTO public.billing_notifications_sent(business_id, event_key, event_type) VALUES (p_business_id, p_key, p_event) ON CONFLICT (event_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL OR NOT v_enabled THEN RETURN 0; END IF;
  SELECT b.type::TEXT INTO v_type FROM public.businesses b WHERE b.id = p_business_id;
  v_n := public.notify_business(p_business_id, ARRAY['manager', 'finance', 'accountant'], 'billing', p_title, p_body, CASE WHEN v_type = 'wholesaler' THEN '/wholesaler?tab=billing' ELSE '/pharmacy?tab=billing' END,
                                jsonb_build_object('billing_event', p_event, 'event_key', p_key));
  UPDATE public.billing_notifications_sent SET recipients = v_n WHERE id = v_id;
  RETURN v_n;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'billing notice % failed: %', p_key, SQLERRM;
  RETURN 0;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_notify_once(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._billing_notify_admins_once(p_key TEXT, p_title TEXT, p_body TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_n INTEGER := 0;
BEGIN
  INSERT INTO public.billing_notifications_sent(business_id, event_key, event_type) VALUES (NULL, p_key, 'admin') ON CONFLICT (event_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN 0; END IF;
  INSERT INTO public.notifications(user_id, type, title, body, link, metadata)
  SELECT DISTINCT ur.user_id, 'billing', p_title, p_body, '/admin/billing', jsonb_build_object('billing_event', 'admin', 'event_key', p_key) FROM public.user_roles ur WHERE ur.role::TEXT = 'admin';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE public.billing_notifications_sent SET recipients = v_n WHERE id = v_id;
  RETURN v_n;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'billing admin notice % failed: %', p_key, SQLERRM;
  RETURN 0;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_notify_admins_once(TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Overdue invoices to account status (past due, grace, suspended, and back)
-- ---------------------------------------------------------------------------
-- One subscription, its lock held by the caller. The oldest overdue invoice starts the clock: the automatic grace ends grace_days after its due date, or later if an administrator
-- granted more. Within it the business is past_due (or grace_period when extended); after it, suspended; once nothing is overdue it is restored. Status only: what suspended means
-- in practice is the enforcement policy, which is off unless an administrator turns it on.
CREATE OR REPLACE FUNCTION public._billing_enforce_one(p_sub public.billing_subscriptions, p_now TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_oldest TIMESTAMPTZ;
  v_days INTEGER := (SELECT s.grace_days FROM public.billing_settings s WHERE s.id);
  v_auto TIMESTAMPTZ;
  v_deadline TIMESTAMPTZ;
  v_new TEXT;
  v_name TEXT;
BEGIN
  SELECT min(i.due_at) INTO v_oldest FROM public.billing_invoices i WHERE i.business_id = p_sub.business_id AND i.status = 'overdue' AND i.outstanding_amount > 0;
  SELECT name INTO v_name FROM public.businesses WHERE id = p_sub.business_id;
  IF v_oldest IS NULL THEN
    IF p_sub.status IN ('past_due', 'grace_period', 'suspended') THEN
      v_new := CASE WHEN p_sub.trial_end IS NOT NULL AND p_sub.trial_end > p_now THEN 'trialing' ELSE 'active' END;
      UPDATE public.billing_subscriptions SET status = v_new, grace_until = NULL, past_due_since = NULL, grace_extended_until = NULL WHERE id = p_sub.id;
      PERFORM public.write_audit_log('Billing account restored', v_name, 'billing_subscription', p_sub.id, 'Account status', jsonb_build_object('previous', p_sub.status, 'new', v_new),
        _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => p_sub.business_id);
      PERFORM public._billing_notify_once(p_sub.business_id, 'restored:' || p_sub.id || ':' || p_now::TEXT, 'restored', 'Your billing is up to date',
        'Thank you: your overdue invoice has been paid and your DrugXOne account is in good standing again.');
      RETURN v_new;
    END IF;
    RETURN NULL;
  END IF;
  v_auto := v_oldest + make_interval(days => v_days);
  v_deadline := GREATEST(v_auto, COALESCE(p_sub.grace_extended_until, v_auto));
  v_new := CASE WHEN p_now > v_deadline THEN 'suspended' WHEN v_deadline > v_auto THEN 'grace_period' ELSE 'past_due' END;
  IF p_sub.status IS DISTINCT FROM v_new OR p_sub.grace_until IS DISTINCT FROM v_deadline OR p_sub.past_due_since IS NULL THEN
    UPDATE public.billing_subscriptions SET status = v_new, grace_until = v_deadline, past_due_since = COALESCE(past_due_since, v_oldest) WHERE id = p_sub.id;
    IF p_sub.status IS DISTINCT FROM v_new THEN
      PERFORM public.write_audit_log(CASE v_new WHEN 'suspended' THEN 'Billing account suspended' WHEN 'grace_period' THEN 'Billing grace extended' ELSE 'Billing account past due' END, v_name, 'billing_subscription', p_sub.id, 'Account status',
        jsonb_build_object('previous', p_sub.status, 'new', v_new, 'grace_until', v_deadline, 'oldest_overdue_due_at', v_oldest),
        _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => p_sub.business_id);
    END IF;
    RETURN v_new;
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_enforce_one(public.billing_subscriptions, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.billing_advance_enforcement(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_new TEXT;
  v_changed INTEGER := 0;
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') <> 'active' THEN RETURN jsonb_build_object('skipped', 'not_active'); END IF;
  FOR v_id IN SELECT s.id FROM public.billing_subscriptions s
              WHERE s.activated_at IS NOT NULL AND s.activated_at <= p_now AND s.status IN ('trialing', 'active', 'past_due', 'grace_period', 'suspended') ORDER BY s.id LOOP
    BEGIN
      SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.id = v_id FOR UPDATE;
      CONTINUE WHEN public.billing_effective_mode(v_sub.business_id) <> 'active';
      v_new := public._billing_enforce_one(v_sub, p_now);
      IF v_new IS NOT NULL THEN v_changed := v_changed + 1; END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'billing could not update the account status of subscription %: %', v_id, SQLERRM;
    END;
  END LOOP;
  RETURN jsonb_build_object('status_changes', v_changed);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_advance_enforcement(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_advance_enforcement(TIMESTAMPTZ) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. The notices themselves
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_send_notifications(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cfg JSONB;
  r RECORD;
  v_n INTEGER := 0;
  v_days INTEGER[];
  d INTEGER;
  v_pick INTEGER;
  v_thr INTEGER;
  v_gb INTEGER;
  v_granted INTEGER;
  v_used INTEGER;
  v_remaining INTEGER;
  v_fmt TEXT := 'FMDD Mon YYYY';
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') <> 'active' THEN RETURN jsonb_build_object('skipped', 'not_active'); END IF;
  SELECT s.notifications INTO cfg FROM public.billing_settings s WHERE s.id;
  SELECT COALESCE(array_agg((x)::INTEGER ORDER BY (x)::INTEGER), ARRAY[7, 1]) INTO v_days FROM jsonb_array_elements_text(COALESCE(cfg -> 'trial_days_before', '[7, 1]'::JSONB)) x;
  v_thr := COALESCE((cfg ->> 'free_orders_threshold')::INTEGER, 1);
  v_gb := COALESCE((cfg ->> 'grace_days_before')::INTEGER, 3);

  -- an invoice was issued
  FOR r IN SELECT i.id, i.invoice_number, i.business_id, i.total_amount, i.due_at FROM public.billing_invoices i JOIN public.billing_subscriptions s ON s.business_id = i.business_id
           WHERE i.issued_at > p_now - interval '30 days' AND i.total_amount > 0 AND s.activated_at IS NOT NULL AND s.activated_at <= p_now
             AND NOT EXISTS (SELECT 1 FROM public.billing_notifications_sent n WHERE n.event_key = 'invoice:' || i.id) ORDER BY i.issued_at LIMIT 500 LOOP
    v_n := v_n + public._billing_notify_once(r.business_id, 'invoice:' || r.id, 'invoice_issued', 'Your DrugXOne invoice is ready',
      'Invoice ' || r.invoice_number || ' for GHS ' || to_char(r.total_amount, 'FM999,999,990.00') || ' is ready and due on ' || to_char(r.due_at AT TIME ZONE 'UTC', v_fmt) || '. You can see it under Billing.');
  END LOOP;
  -- a payment was recorded
  FOR r IN SELECT y.id, y.business_id, y.amount, i.invoice_number FROM public.billing_payments y JOIN public.billing_invoices i ON i.id = y.invoice_id
           WHERE y.kind = 'payment' AND y.recorded_at > p_now - interval '30 days' AND NOT EXISTS (SELECT 1 FROM public.billing_notifications_sent n WHERE n.event_key = 'payment:' || y.id) ORDER BY y.recorded_at LIMIT 500 LOOP
    v_n := v_n + public._billing_notify_once(r.business_id, 'payment:' || r.id, 'payment_received', 'We received your payment',
      'We recorded a payment of GHS ' || to_char(r.amount, 'FM999,999,990.00') || ' on invoice ' || r.invoice_number || '. Thank you.');
  END LOOP;
  -- an invoice became overdue (the business, and the administrators)
  FOR r IN SELECT i.id, i.invoice_number, i.business_id, i.outstanding_amount, i.due_at, b.name FROM public.billing_invoices i JOIN public.businesses b ON b.id = i.business_id
           WHERE i.status = 'overdue' AND i.outstanding_amount > 0 AND i.due_at > p_now - interval '60 days' AND NOT EXISTS (SELECT 1 FROM public.billing_notifications_sent n WHERE n.event_key = 'overdue:' || i.id) ORDER BY i.due_at LIMIT 500 LOOP
    v_n := v_n + public._billing_notify_once(r.business_id, 'overdue:' || r.id, 'invoice_overdue', 'An invoice is overdue',
      'Invoice ' || r.invoice_number || ' (GHS ' || to_char(r.outstanding_amount, 'FM999,999,990.00') || ' still to pay) was due on ' || to_char(r.due_at AT TIME ZONE 'UTC', v_fmt) || '. Please pay it to keep your account in good standing.');
    v_n := v_n + public._billing_notify_admins_once('admin-overdue:' || r.id, 'A billing invoice is overdue', r.name || ': invoice ' || r.invoice_number || ', GHS ' || to_char(r.outstanding_amount, 'FM999,999,990.00') || ' unpaid since ' || to_char(r.due_at AT TIME ZONE 'UTC', v_fmt) || '.');
  END LOOP;
  -- a free trial is about to end: the nearest of the configured warnings only
  FOR r IN SELECT s.id, s.business_id, s.trial_end FROM public.billing_subscriptions s
           WHERE s.status = 'trialing' AND s.activated_at IS NOT NULL AND s.activated_at <= p_now AND s.trial_end > p_now AND s.trial_end <= p_now + make_interval(days => COALESCE(v_days[array_upper(v_days, 1)], 7)) LOOP
    v_pick := NULL;
    FOREACH d IN ARRAY v_days LOOP
      IF r.trial_end <= p_now + make_interval(days => d) THEN v_pick := d; EXIT; END IF;
    END LOOP;
    IF v_pick IS NOT NULL THEN
      v_n := v_n + public._billing_notify_once(r.business_id, 'trial:' || r.id || ':' || v_pick || ':' || r.trial_end::TEXT, 'trial_ending', 'Your free trial is ending',
        'Your free trial ends on ' || to_char(r.trial_end AT TIME ZONE 'UTC', v_fmt) || '. After that your plan''s subscription applies.');
    END IF;
  END LOOP;
  -- a wholesaler's free orders are almost used up, or used up
  FOR r IN SELECT s.business_id FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id
           WHERE b.type = 'wholesaler' AND s.activated_at IS NOT NULL AND s.activated_at <= p_now AND s.status IN ('trialing', 'active', 'past_due', 'grace_period') LOOP
    SELECT COALESCE(sum(g.quantity), 0) INTO v_granted FROM public.billing_allowance_grants g WHERE g.business_id = r.business_id AND (g.expires_at IS NULL OR g.expires_at > p_now);
    CONTINUE WHEN v_granted = 0;
    SELECT count(*) INTO v_used FROM public.order_billing_assessments a WHERE a.business_id = r.business_id AND NOT a.shadow AND a.free_source = 'onboarding';
    v_remaining := GREATEST(v_granted - v_used, 0);
    IF v_remaining = 0 THEN
      v_n := v_n + public._billing_notify_once(r.business_id, 'freeout:' || r.business_id || ':' || v_granted, 'free_orders_low', 'Your free orders are used up',
        'You have used all ' || v_granted || ' launch free orders. From now on your monthly free orders (if your plan has them) are used first, then the platform fee applies.');
    ELSIF v_remaining <= v_thr THEN
      v_n := v_n + public._billing_notify_once(r.business_id, 'freelow:' || r.business_id || ':' || v_granted, 'free_orders_low', 'Your free orders are almost used up',
        'You have ' || v_remaining || ' launch free ' || CASE WHEN v_remaining = 1 THEN 'order' ELSE 'orders' END || ' left. After that the platform fee applies to new orders.');
    END IF;
  END LOOP;
  -- the grace period is about to end
  FOR r IN SELECT s.id, s.business_id, s.grace_until FROM public.billing_subscriptions s
           WHERE s.status IN ('past_due', 'grace_period') AND s.grace_until > p_now AND s.grace_until <= p_now + make_interval(days => v_gb) LOOP
    v_n := v_n + public._billing_notify_once(r.business_id, 'grace:' || r.id || ':' || r.grace_until::TEXT, 'grace_ending', 'Your grace period is ending',
      'Your account has an overdue invoice. The grace period ends on ' || to_char(r.grace_until AT TIME ZONE 'UTC', v_fmt) || '. Please pay before then to avoid suspension.');
  END LOOP;
  -- suspended (the business, and the administrators)
  FOR r IN SELECT s.id, s.business_id, s.grace_until, b.name FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id WHERE s.status = 'suspended' AND s.grace_until IS NOT NULL LOOP
    v_n := v_n + public._billing_notify_once(r.business_id, 'suspended:' || r.id || ':' || r.grace_until::TEXT, 'suspended', 'Your account is suspended for an unpaid invoice',
      'The grace period for your overdue invoice has ended. Please pay the invoice under Billing, or contact DrugXOne, to restore your account.');
    v_n := v_n + public._billing_notify_admins_once('admin-suspended:' || r.id || ':' || r.grace_until::TEXT, 'A business is suspended for an unpaid invoice', r.name || ' has passed its grace period.');
  END LOOP;
  RETURN jsonb_build_object('notices_sent', v_n);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_send_notifications(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_send_notifications(TIMESTAMPTZ) TO service_role;

-- The scheduled run now also updates account status, sends notices, and records that it ran (so a run that stops is noticed).
CREATE OR REPLACE FUNCTION public.billing_run_scheduled(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_states := public.billing_advance_states(p_now);
  v_periods := public.billing_open_periods(p_now);
  v_queue := public.billing_process_queue(100);
  v_catch := public.billing_catch_up(200);
  v_inv := public.billing_issue_invoices(p_now);
  v_over := public.billing_mark_overdue(p_now);
  BEGIN v_enf := public.billing_advance_enforcement(p_now); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'billing enforcement step failed: %', SQLERRM; END;
  BEGIN v_notes := public.billing_send_notifications(p_now); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'billing notices step failed: %', SQLERRM; END;
  v_res := jsonb_build_object('states_advanced', v_states, 'periods_opened', v_periods, 'queue', v_queue, 'catch_up', v_catch, 'invoices', v_inv, 'marked_overdue', v_over, 'enforcement', v_enf, 'notices', v_notes);
  UPDATE public.billing_run_status SET last_run_at = clock_timestamp(), runs = runs + 1, last_result = v_res WHERE id;
  RETURN v_res;
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Going live
-- ---------------------------------------------------------------------------
-- Makes real billing start for one business at a moment. Real billing never looks back: orders delivered before the moment are never assessed, the first real period starts at the moment
-- (the billing cycle is re-anchored if the business has no real period yet), and the free trial restarts from it (an extension that runs longer is kept). Launch free orders are untouched.
CREATE OR REPLACE FUNCTION public._billing_go_live(p_sub public.billing_subscriptions, p_at TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_terms JSONB := public.billing_resolve_terms(p_sub.business_id, GREATEST(p_at, p_sub.billing_starts_at));
  v_trial_days INTEGER := COALESCE((v_terms ->> 'free_trial_days')::INTEGER, 0);
  v_has_real BOOLEAN := EXISTS (SELECT 1 FROM public.billing_periods p WHERE p.business_id = p_sub.business_id AND NOT p.shadow);
  v_end TIMESTAMPTZ;
  v_start TIMESTAMPTZ;
  v_status TEXT;
BEGIN
  v_start := CASE WHEN v_trial_days > 0 THEN p_at ELSE p_sub.trial_start END;
  v_end := CASE WHEN v_trial_days > 0 THEN GREATEST(COALESCE(p_sub.trial_end, p_at), p_at + make_interval(days => v_trial_days)) ELSE p_sub.trial_end END;
  v_status := CASE WHEN v_end IS NOT NULL AND v_end > p_at THEN 'trialing' ELSE 'active' END;
  UPDATE public.billing_subscriptions SET activated_at = p_at, period_anchor_at = CASE WHEN v_has_real THEN period_anchor_at ELSE p_at END, billing_mode = NULL,
         trial_start = v_start, trial_end = v_end, status = v_status WHERE id = p_sub.id;
  RETURN jsonb_build_object('activated_at', p_at, 'trial_end', v_end, 'status', v_status, 're_anchored', NOT v_has_real);
END;
$$;
REVOKE ALL ON FUNCTION public._billing_go_live(public.billing_subscriptions, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- What must be true before real billing is switched on, and what shadow billing has shown. Blocking items stop the activation; the rest are advice.
CREATE OR REPLACE FUNCTION public.admin_billing_readiness()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  st public.billing_settings%ROWTYPE;
  rs public.billing_run_status%ROWTYPE;
  v_crit INTEGER;
  v_warn INTEGER;
  v_checks JSONB := '[]'::JSONB;
  v_since TIMESTAMPTZ;
  v_days INTEGER;
  v_ready BOOLEAN;
  v_pharm_subs INTEGER;
  c JSONB;
BEGIN
  PERFORM public._billing_admin_only();
  SELECT * INTO st FROM public.billing_settings s WHERE s.id;
  SELECT * INTO rs FROM public.billing_run_status s WHERE s.id;
  SELECT count(*) FILTER (WHERE finding_count > 0 AND severity = 'critical'), count(*) FILTER (WHERE finding_count > 0 AND severity <> 'critical') INTO v_crit, v_warn FROM public.billing_reconcile();
  SELECT min(e.created_at) INTO v_since FROM public.billing_ledger_entries e WHERE e.shadow;
  v_days := CASE WHEN v_since IS NULL THEN 0 ELSE floor(extract(epoch FROM (now() - v_since)) / 86400)::INTEGER END;
  SELECT count(*) INTO v_pharm_subs FROM public.billing_subscriptions s JOIN public.businesses b ON b.id = s.business_id WHERE b.type = 'pharmacy';
  v_checks := v_checks
    || jsonb_build_object('key', 'subscriptions', 'label', 'At least one business has a subscription', 'blocking', TRUE, 'ok', EXISTS (SELECT 1 FROM public.billing_subscriptions), 'detail', (SELECT count(*) || ' subscriptions' FROM public.billing_subscriptions))
    || jsonb_build_object('key', 'reconciliation', 'label', 'The billing books agree (reconciliation finds nothing wrong)', 'blocking', TRUE, 'ok', v_crit = 0, 'detail', v_crit || ' critical findings, ' || v_warn || ' warnings')
    || jsonb_build_object('key', 'scheduler', 'label', 'The scheduled billing run is running (it ran in the last 2 hours)', 'blocking', TRUE, 'ok', rs.last_run_at IS NOT NULL AND rs.last_run_at > now() - interval '2 hours',
                          'detail', CASE WHEN rs.last_run_at IS NULL THEN 'It has never run. Switch billing to shadow first and let it run.' ELSE 'Last ran ' || to_char(rs.last_run_at, 'YYYY-MM-DD HH24:MI') || ' UTC' END)
    || jsonb_build_object('key', 'issuer', 'label', 'Invoices say who they are from and how to pay', 'blocking', TRUE, 'ok', char_length(btrim(COALESCE(st.issuer ->> 'name', ''))) >= 2 AND char_length(btrim(COALESCE(st.issuer ->> 'payment_instructions', ''))) >= 10,
                          'detail', 'Set the issuer name and the "how to pay" text under Invoices → Invoice settings.')
    || jsonb_build_object('key', 'plans', 'label', 'There is a switched-on plan with a published version for wholesalers' || CASE WHEN v_pharm_subs > 0 THEN ' and for pharmacies' ELSE '' END, 'blocking', TRUE,
                          'ok', EXISTS (SELECT 1 FROM public.billing_plans p WHERE p.active AND p.business_type = 'wholesaler' AND EXISTS (SELECT 1 FROM public.billing_plan_versions v WHERE v.plan_id = p.id AND v.status = 'published'))
                                AND (v_pharm_subs = 0 OR EXISTS (SELECT 1 FROM public.billing_plans p WHERE p.active AND p.business_type = 'pharmacy' AND EXISTS (SELECT 1 FROM public.billing_plan_versions v WHERE v.plan_id = p.id AND v.status = 'published'))),
                          'detail', '')
    || jsonb_build_object('key', 'shadow_history', 'label', 'Shadow billing has run for at least 14 days', 'blocking', FALSE, 'ok', v_days >= 14,
                          'detail', CASE WHEN v_since IS NULL THEN 'No shadow billing data yet.' ELSE 'Shadow data goes back ' || v_days || ' days.' END)
    || jsonb_build_object('key', 'terms', 'label', 'Payment terms and grace period are what you intend', 'blocking', FALSE, 'ok', TRUE, 'detail', st.payment_terms_days || ' days to pay, ' || st.grace_days || ' days of grace, enforcement: ' || st.enforcement);
  v_ready := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) k WHERE (k ->> 'blocking')::BOOLEAN AND NOT (k ->> 'ok')::BOOLEAN);
  RETURN jsonb_build_object('platform_mode', st.mode, 'ready', v_ready, 'checks', v_checks,
    'shadow', jsonb_build_object('since', v_since, 'days', v_days,
      'businesses', (SELECT count(DISTINCT a.business_id) FROM public.order_billing_assessments a WHERE a.shadow),
      'orders_assessed', (SELECT count(*) FROM public.order_billing_assessments a WHERE a.shadow AND a.kind = 'primary'),
      'estimated_revenue', COALESCE((SELECT sum(e.charged_amount) - sum(e.credit_amount) FROM public.billing_ledger_entries e WHERE e.shadow), 0)),
    'live', jsonb_build_object('live', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.activated_at IS NOT NULL),
      'held_back', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.activated_at IS NULL AND s.billing_mode = 'shadow'),
      'disabled', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.billing_mode = 'disabled'),
      'waiting', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.activated_at IS NULL AND s.billing_mode IS NULL)));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_readiness() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_readiness() TO authenticated, service_role;

-- Switches real billing on for the platform, once the readiness checks pass and the administrator has typed the confirmation. By default every business is held back in shadow, and goes live
-- one by one (a pilot group first). Without the hold-back every subscribed business goes live from this moment.
CREATE OR REPLACE FUNCTION public.admin_billing_activate_platform(p_hold_back BOOLEAN, p_confirmation TEXT, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  st public.billing_settings%ROWTYPE;
  v_ready JSONB;
  v_missing TEXT;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_held INTEGER := 0;
  v_live INTEGER := 0;
BEGIN
  IF btrim(COALESCE(p_confirmation, '')) <> 'ACTIVATE BILLING' THEN RAISE EXCEPTION 'Type ACTIVATE BILLING exactly to confirm.'; END IF;
  SELECT * INTO st FROM public.billing_settings s WHERE s.id FOR UPDATE;
  IF st.mode = 'active' THEN RAISE EXCEPTION 'Real billing is already switched on.'; END IF;
  v_ready := public.admin_billing_readiness();
  IF NOT (v_ready ->> 'ready')::BOOLEAN THEN
    SELECT string_agg(k ->> 'label', '; ') INTO v_missing FROM jsonb_array_elements(v_ready -> 'checks') k WHERE (k ->> 'blocking')::BOOLEAN AND NOT (k ->> 'ok')::BOOLEAN;
    RAISE EXCEPTION 'Billing is not ready to go live: %.', v_missing;
  END IF;
  UPDATE public.billing_settings SET mode = 'active', live_since = COALESCE(live_since, clock_timestamp()), updated_by = auth.uid()::TEXT WHERE id;
  FOR v_sub IN SELECT * FROM public.billing_subscriptions s WHERE s.status <> 'cancelled' AND (s.ended_at IS NULL OR s.ended_at > now()) AND s.activated_at IS NULL AND s.billing_mode IS DISTINCT FROM 'disabled' ORDER BY s.id FOR UPDATE LOOP
    IF COALESCE(p_hold_back, TRUE) THEN
      UPDATE public.billing_subscriptions SET billing_mode = 'shadow' WHERE id = v_sub.id;
      v_held := v_held + 1;
    ELSE
      PERFORM public._billing_go_live(v_sub, clock_timestamp());
      v_live := v_live + 1;
    END IF;
  END LOOP;
  PERFORM public.write_audit_log('Billing activated', 'DrugXOne', 'billing_settings', NULL, 'Billing mode',
    jsonb_build_object('previous', st.mode, 'new', 'active', 'held_back', COALESCE(p_hold_back, TRUE), 'businesses_held_back', v_held, 'businesses_live', v_live, 'reason', v_reason));
  RETURN jsonb_build_object('mode', 'active', 'held_back', v_held, 'live', v_live);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_activate_platform(BOOLEAN, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_activate_platform(BOOLEAN, TEXT, TEXT) TO authenticated, service_role;

-- Puts one business live (a business held back in shadow, or a new one) at a moment: now, or up to 90 days ahead.
CREATE OR REPLACE FUNCTION public.admin_billing_go_live_business(p_business_id UUID, p_activate_at TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_at TIMESTAMPTZ := COALESCE(p_activate_at, clock_timestamp());
  v_res JSONB;
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') <> 'active' THEN RAISE EXCEPTION 'Real billing is not switched on for the platform yet. Use the activation checklist first.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  IF v_sub.activated_at IS NOT NULL THEN RAISE EXCEPTION 'Real billing has already started for this business.'; END IF;
  IF v_sub.billing_mode = 'disabled' THEN RAISE EXCEPTION 'Billing is switched off for this business. Set it to follow the platform first.'; END IF;
  IF v_at < now() - interval '1 minute' THEN RAISE EXCEPTION 'Real billing cannot start in the past: no historical order is ever charged.'; END IF;
  IF v_at > now() + interval '90 days' THEN RAISE EXCEPTION 'Real billing cannot be scheduled more than 90 days ahead.'; END IF;
  v_res := public._billing_go_live(v_sub, v_at);
  PERFORM public.write_audit_log('Billing business went live', v_biz.name, 'billing_subscription', v_sub.id, 'Go live',
    jsonb_build_object('activate_at', v_at, 'trial_end', v_res -> 'trial_end', 'status', v_res -> 'status', 'reason', v_reason), _business_id => p_business_id);
  RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_go_live_business(UUID, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_go_live_business(UUID, TIMESTAMPTZ, TEXT) TO authenticated, service_role;

-- The platform-wide switch. 'active' is refused here: it has its own checklist. Once real billing has started for any business the platform cannot go back to shadow (shadow periods
-- would overlap the real ones); it can be switched off, and catches up when switched on again through the checklist.
CREATE OR REPLACE FUNCTION public.admin_billing_set_mode(p_mode TEXT, p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old TEXT;
BEGIN
  IF p_mode IS NULL OR p_mode NOT IN ('disabled', 'shadow', 'active') THEN RAISE EXCEPTION 'Choose disabled, shadow or active.'; END IF;
  IF p_mode = 'active' THEN RAISE EXCEPTION 'Active billing is switched on through the activation checklist, which checks that everything is ready.'; END IF;
  SELECT s.mode INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  IF p_mode = 'shadow' AND EXISTS (SELECT 1 FROM public.billing_subscriptions s WHERE s.activated_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Real billing has already started for some businesses, so the platform cannot go back to shadow. Switch billing off (disabled) instead: it catches up when switched on again.';
  END IF;
  UPDATE public.billing_settings SET mode = p_mode, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing mode changed', 'DrugXOne', 'billing_settings', NULL, 'Billing mode', jsonb_build_object('previous', v_old, 'new', p_mode, 'reason', v_reason));
  RETURN p_mode;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_mode(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_mode(TEXT, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Policy settings and a grace extension
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_set_grace_days(p_days INTEGER, p_reason TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old INTEGER;
BEGIN
  IF p_days IS NULL OR p_days NOT BETWEEN 0 AND 90 THEN RAISE EXCEPTION 'The grace period must be between 0 and 90 days.'; END IF;
  SELECT s.grace_days INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  UPDATE public.billing_settings SET grace_days = p_days, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing grace period changed', 'DrugXOne', 'billing_settings', NULL, 'Grace period', jsonb_build_object('previous', v_old, 'new', p_days, 'reason', v_reason));
  RETURN p_days;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_grace_days(INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_grace_days(INTEGER, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_set_enforcement(p_policy TEXT, p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old TEXT;
BEGIN
  IF p_policy IS NULL OR p_policy NOT IN ('none', 'block_new_orders') THEN RAISE EXCEPTION 'Choose warnings only (none) or block new orders after the grace period.'; END IF;
  SELECT s.enforcement INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  UPDATE public.billing_settings SET enforcement = p_policy, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing enforcement policy changed', 'DrugXOne', 'billing_settings', NULL, 'Enforcement', jsonb_build_object('previous', v_old, 'new', p_policy, 'reason', v_reason));
  RETURN p_policy;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_enforcement(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_enforcement(TEXT, TEXT) TO authenticated, service_role;

-- Which notices are sent and how early. Only the keys given change; the others stay as they were.
CREATE OR REPLACE FUNCTION public.admin_billing_set_notification_settings(p_config JSONB, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old JSONB;
  v_new JSONB;
  k TEXT;
  v JSONB;
  e JSONB;
BEGIN
  IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' OR p_config = '{}'::JSONB THEN RAISE EXCEPTION 'Say what to change.'; END IF;
  FOR k, v IN SELECT * FROM jsonb_each(p_config) LOOP
    IF k IN ('invoice_issued', 'payment_received', 'invoice_overdue', 'trial_ending', 'free_orders_low', 'grace_ending', 'suspended', 'restored') THEN
      IF jsonb_typeof(v) <> 'boolean' THEN RAISE EXCEPTION 'The notice "%" is either on or off.', k; END IF;
    ELSIF k = 'trial_days_before' THEN
      IF jsonb_typeof(v) <> 'array' OR jsonb_array_length(v) NOT BETWEEN 1 AND 4 THEN RAISE EXCEPTION 'Give 1 to 4 numbers of days before the trial ends.'; END IF;
      FOR e IN SELECT * FROM jsonb_array_elements(v) LOOP
        IF jsonb_typeof(e) <> 'number' OR (e #>> '{}') !~ '^[0-9]+$' OR (e #>> '{}')::INTEGER NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'Days before the trial ends must be whole numbers from 1 to 60.'; END IF;
      END LOOP;
    ELSIF k = 'grace_days_before' THEN
      IF jsonb_typeof(v) <> 'number' OR (v #>> '{}') !~ '^[0-9]+$' OR (v #>> '{}')::INTEGER NOT BETWEEN 0 AND 30 THEN RAISE EXCEPTION 'Days before the grace period ends must be a whole number from 0 to 30.'; END IF;
    ELSIF k = 'free_orders_threshold' THEN
      IF jsonb_typeof(v) <> 'number' OR (v #>> '{}') !~ '^[0-9]+$' OR (v #>> '{}')::INTEGER NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'The free-orders warning level must be a whole number from 0 to 100.'; END IF;
    ELSE
      RAISE EXCEPTION 'Unknown notice setting "%".', k;
    END IF;
  END LOOP;
  SELECT s.notifications INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  v_new := v_old || p_config;
  UPDATE public.billing_settings SET notifications = v_new, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing notification settings changed', 'DrugXOne', 'billing_settings', NULL, 'Notifications', jsonb_build_object('previous', v_old, 'new', v_new, 'reason', v_reason));
  RETURN v_new;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_notification_settings(JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_notification_settings(JSONB, TEXT) TO authenticated, service_role;

-- More grace for a business that is already overdue (a promise to pay): the account becomes "grace period" until that date, then suspended if still unpaid.
CREATE OR REPLACE FUNCTION public.admin_billing_extend_grace(p_business_id UUID, p_until TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_new TEXT;
BEGIN
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status NOT IN ('past_due', 'grace_period', 'suspended') THEN RAISE EXCEPTION 'This business has no overdue invoice, so there is no grace period to extend.'; END IF;
  IF p_until IS NULL OR p_until <= now() THEN RAISE EXCEPTION 'Choose a date that is still ahead.'; END IF;
  IF p_until > now() + interval '90 days' THEN RAISE EXCEPTION 'Grace cannot be extended more than 90 days ahead.'; END IF;
  IF v_sub.grace_until IS NOT NULL AND p_until <= v_sub.grace_until AND v_sub.status <> 'suspended' THEN RAISE EXCEPTION 'The business already has grace until % or later.', v_sub.grace_until; END IF;
  UPDATE public.billing_subscriptions SET grace_extended_until = p_until WHERE id = v_sub.id RETURNING * INTO v_sub;
  v_new := public._billing_enforce_one(v_sub, now());
  PERFORM public.write_audit_log('Billing grace period extended', v_biz.name, 'billing_subscription', v_sub.id, 'Grace period',
    jsonb_build_object('until', p_until, 'status', COALESCE(v_new, v_sub.status), 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('until', p_until, 'status', (SELECT status FROM public.billing_subscriptions WHERE id = v_sub.id));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_extend_grace(UUID, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_extend_grace(UUID, TIMESTAMPTZ, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Monitoring
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_rollout_status()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  st public.billing_settings%ROWTYPE;
  rs public.billing_run_status%ROWTYPE;
BEGIN
  PERFORM public._billing_admin_only();
  SELECT * INTO st FROM public.billing_settings s WHERE s.id;
  SELECT * INTO rs FROM public.billing_run_status s WHERE s.id;
  RETURN jsonb_build_object(
    'platform', jsonb_build_object('mode', st.mode, 'enforcement', st.enforcement, 'grace_days', st.grace_days, 'payment_terms_days', st.payment_terms_days, 'notifications', st.notifications, 'updated_at', st.updated_at),
    'run', jsonb_build_object('last_run_at', rs.last_run_at, 'runs', rs.runs, 'minutes_since', CASE WHEN rs.last_run_at IS NULL THEN NULL ELSE floor(extract(epoch FROM (now() - rs.last_run_at)) / 60)::INTEGER END,
                              'stale', st.mode <> 'disabled' AND (rs.last_run_at IS NULL OR rs.last_run_at < now() - interval '2 hours'), 'last_result', rs.last_result),
    'counts', jsonb_build_object(
      'subscriptions', (SELECT count(*) FROM public.billing_subscriptions),
      'live', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.activated_at IS NOT NULL AND s.status <> 'cancelled'),
      'held_back', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.activated_at IS NULL AND s.billing_mode = 'shadow'),
      'disabled', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.billing_mode = 'disabled'),
      'past_due', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.status = 'past_due'),
      'grace_period', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.status = 'grace_period'),
      'suspended', (SELECT count(*) FROM public.billing_subscriptions s WHERE s.status = 'suspended'),
      'overdue_invoices', (SELECT count(*) FROM public.billing_invoices i WHERE i.status = 'overdue'),
      'overdue_amount', COALESCE((SELECT sum(i.outstanding_amount) FROM public.billing_invoices i WHERE i.status = 'overdue'), 0)),
    'recent_notices', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.sent_at DESC) FROM (
        SELECT n.event_type, n.sent_at, n.recipients, b.name AS business_name FROM public.billing_notifications_sent n LEFT JOIN public.businesses b ON b.id = n.business_id ORDER BY n.sent_at DESC LIMIT 20) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_rollout_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_rollout_status() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._billing_reconcile_rollout()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 'billing_scheduler_not_running'::TEXT, 'warning'::TEXT, (CASE WHEN st.mode <> 'disabled' AND st.updated_at < now() - interval '2 hours' AND (rs.last_run_at IS NULL OR rs.last_run_at < now() - interval '2 hours') THEN 1 ELSE 0 END)::INTEGER,
         jsonb_build_object('last_run_at', rs.last_run_at, 'mode', st.mode)
  FROM public.billing_settings st, public.billing_run_status rs WHERE st.id AND rs.id;
  RETURN QUERY
  SELECT 'live_business_not_activated'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('business_id', m.business_id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT s.business_id, row_number() OVER () rn FROM public.billing_subscriptions s, public.billing_settings st
        WHERE st.id AND st.live_since IS NOT NULL AND st.mode = 'active' AND s.billing_mode IS NULL AND s.activated_at IS NULL AND s.status <> 'cancelled' AND (s.ended_at IS NULL OR s.ended_at > now())) m;
  RETURN QUERY
  SELECT 'real_period_before_activation'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, row_number() OVER () rn FROM public.billing_periods p JOIN public.billing_subscriptions s ON s.business_id = p.business_id WHERE NOT p.shadow AND s.activated_at IS NOT NULL AND p.period_end <= s.activated_at AND (SELECT st.live_since IS NOT NULL FROM public.billing_settings st WHERE st.id)) m;
  RETURN QUERY
  SELECT 'real_assessment_before_activation'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('assessment_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.id, row_number() OVER () rn FROM public.order_billing_assessments a JOIN public.billing_subscriptions s ON s.business_id = a.business_id WHERE NOT a.shadow AND s.activated_at IS NOT NULL AND a.delivered_at < s.activated_at) m;
  RETURN QUERY
  SELECT 'account_status_does_not_match_invoices'::TEXT, 'warning'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('business_id', m.business_id, 'status', m.status)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT s.business_id, s.status, row_number() OVER () rn FROM public.billing_subscriptions s
        WHERE s.activated_at IS NOT NULL AND s.status NOT IN ('cancelled', 'suspended', 'past_due', 'grace_period')
          AND EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.business_id = s.business_id AND i.status = 'overdue' AND i.outstanding_amount > 0 AND i.due_at < now() - interval '1 hour' - make_interval(days => 0))
          AND (SELECT rs.last_run_at FROM public.billing_run_status rs WHERE rs.id) > now() - interval '2 hours'
       UNION ALL
        SELECT s.business_id, s.status, row_number() OVER () rn FROM public.billing_subscriptions s
        WHERE s.status IN ('past_due', 'grace_period', 'suspended') AND NOT EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.business_id = s.business_id AND i.status = 'overdue' AND i.outstanding_amount > 0)
          AND (SELECT rs.last_run_at FROM public.billing_run_status rs WHERE rs.id) > now() - interval '2 hours') m;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_reconcile_rollout() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_reconcile_rollout() TO service_role;

CREATE OR REPLACE FUNCTION public.billing_reconcile()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public._billing_reconcile_engine() UNION ALL SELECT * FROM public._billing_reconcile_invoices() UNION ALL SELECT * FROM public._billing_reconcile_controls() UNION ALL SELECT * FROM public._billing_reconcile_rollout()
$$;
