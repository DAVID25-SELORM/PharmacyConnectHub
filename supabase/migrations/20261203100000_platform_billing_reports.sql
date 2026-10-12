-- Platform billing, Phase 3: the READ functions behind the billing screens. Read-only: nothing here writes, charges or changes any setting.
--
--   billing_my_overview(business)             what a business sees on its own Billing & Subscription page: plan, trial, next billing date, free orders left, the current period's bill with a full
--                                              breakdown, history, and (wholesalers only) how each order was billed. REAL billing only: shadow numbers are never shown to a business, and
--                                              before billing has started the answer is "not started" with the plan's terms. A pharmacy never sees fee information about anyone else.
--   admin_billing_overview(...)                the platform's billing dashboard: accrued revenue (subscriptions, transaction fees, credits), contracted MRR, marketplace GMV (created,
--                                              completed, and fee-eligible are three different numbers), subscription counts, what is outstanding, free-order use, take rate. Real and shadow side by side.
--   admin_billing_organizations(...)           the per-organization table, filterable, paged.
--   admin_billing_business_detail(business)    one organization's whole billing story, including its audit trail.
-- Accrued revenue, invoiced, paid and outstanding are kept apart: nothing is invoiced or collected until Phase 4, so "collected" is honestly zero.

CREATE OR REPLACE FUNCTION public._billing_admin_only()
RETURNS VOID
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view platform billing.'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_admin_only() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. A business's own billing page
-- ---------------------------------------------------------------------------
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
  v_active := v_mode = 'active' AND v_sub.billing_starts_at <= now();
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
    'business_type', v_b.type, 'business_name', v_b.name, 'state', v_state, 'currency', COALESCE(v_terms ->> 'currency', 'GHS'),
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
      'next_billing_date', v_next, 'cancel_at_period_end', v_sub.cancel_at_period_end, 'ends_at', v_sub.ended_at, 'paused', v_sub.billing_paused,
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
REVOKE ALL ON FUNCTION public.billing_my_overview(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_my_overview(UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The administrator's dashboard
-- ---------------------------------------------------------------------------
-- Money and counts for one world (real or shadow) over a period, for a set of businesses. Revenue is by the date it was posted to the ledger.
CREATE OR REPLACE FUNCTION public._billing_flavor_summary(p_shadow BOOLEAN, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_ids UUID[])
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH l AS (SELECT e.entry_type, e.charged_amount, e.credit_amount FROM public.billing_ledger_entries e WHERE e.shadow = p_shadow AND e.business_id = ANY (p_ids) AND e.created_at >= p_from AND e.created_at < p_to),
       a AS (SELECT x.kind, x.outcome, x.billable_gmv FROM public.order_billing_assessments x WHERE x.shadow = p_shadow AND x.business_id = ANY (p_ids) AND x.assessed_at >= p_from AND x.assessed_at < p_to),
       p AS (SELECT q.status, q.outstanding_amount, q.amount_paid FROM public.billing_periods q WHERE q.shadow = p_shadow AND q.business_id = ANY (p_ids)),
       t AS (SELECT
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'subscription_charge'), 0) AS subs,
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'transaction_fee'), 0) AS fees,
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'manual_debit'), 0) AS debits,
               COALESCE((SELECT sum(credit_amount) FROM l), 0) AS credits,
               COALESCE((SELECT sum(billable_gmv) FROM a WHERE outcome IN ('free_onboarding', 'free_monthly', 'chargeable', 'free_adjustment')), 0) AS gmv,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome IN ('free_onboarding', 'free_monthly', 'chargeable')) AS eligible,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome IN ('free_onboarding', 'free_monthly')) AS free_orders,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome = 'chargeable') AS chargeable)
  SELECT jsonb_build_object(
    'subscription_revenue', t.subs, 'transaction_fee_revenue', t.fees, 'other_debits', t.debits, 'credits', t.credits, 'accrued_revenue', t.subs + t.fees + t.debits - t.credits,
    'eligible_gmv', t.gmv, 'eligible_orders', t.eligible, 'free_orders', t.free_orders, 'chargeable_orders', t.chargeable,
    'free_order_share_percent', CASE WHEN t.eligible > 0 THEN round(t.free_orders * 100.0 / t.eligible, 2) END,
    'take_rate_percent', CASE WHEN t.gmv > 0 THEN round(t.fees * 100 / t.gmv, 4) END,
    'invoiced', 0, 'collected', COALESCE((SELECT sum(amount_paid) FROM p), 0),
    'outstanding', COALESCE((SELECT sum(outstanding_amount) FROM p WHERE status NOT IN ('paid', 'closed') AND outstanding_amount > 0), 0),
    'overdue', COALESCE((SELECT sum(outstanding_amount) FROM p WHERE status = 'overdue' AND outstanding_amount > 0), 0))
  FROM t
$$;
REVOKE ALL ON FUNCTION public._billing_flavor_summary(BOOLEAN, TIMESTAMPTZ, TIMESTAMPTZ, UUID[]) FROM PUBLIC, anon, authenticated;

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
           COALESCE((x.t ->> 'billing_interval_months')::INTEGER, 1) AS interval_months, s.billing_starts_at AS starts_at
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
REVOKE ALL ON FUNCTION public.admin_billing_overview(TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_overview(TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The per-organization table
-- ---------------------------------------------------------------------------
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
           s.billing_starts_at, s.trial_end, s.exempt_from_transaction_fees AS exempt, s.billing_paused AS paused,
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
REVOKE ALL ON FUNCTION public.admin_billing_organizations(TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_organizations(TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER, INTEGER) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. One organization, in full
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_business_detail(p_business_id UUID, p_flavor TEXT DEFAULT 'real')
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shadow BOOLEAN;
  v_b RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
BEGIN
  PERFORM public._billing_admin_only();
  IF p_flavor NOT IN ('real', 'shadow') THEN RAISE EXCEPTION 'Choose real or shadow.'; END IF;
  v_shadow := p_flavor = 'shadow';
  SELECT bz.id, bz.name, bz.type::TEXT AS type, bz.license_number INTO v_b FROM public.businesses bz WHERE bz.id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.'; END IF;
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('business', to_jsonb(v_b), 'has_subscription', FALSE); END IF;
  RETURN jsonb_build_object(
    'business', to_jsonb(v_b), 'has_subscription', TRUE, 'flavor', p_flavor, 'effective_mode', public.billing_effective_mode(p_business_id),
    'subscription', to_jsonb(v_sub), 'terms_now', public.billing_resolve_terms(p_business_id, GREATEST(now(), v_sub.billing_starts_at)),
    'terms_history', COALESCE((SELECT jsonb_agg(jsonb_build_object('effective_from', t.effective_from, 'plan_code', pl.code, 'plan_version', v.version, 'overrides', t.overrides, 'reason', t.reason) ORDER BY t.effective_from DESC)
                               FROM public.billing_subscription_terms t JOIN public.billing_plan_versions v ON v.id = t.plan_version_id JOIN public.billing_plans pl ON pl.id = v.plan_id WHERE t.subscription_id = v_sub.id), '[]'::JSONB),
    'grants', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', g.id, 'quantity', g.quantity, 'source', g.source, 'reason', g.reason, 'created_at', g.created_at, 'expires_at', g.expires_at,
                          'used', (SELECT count(*) FROM public.order_billing_assessments a WHERE a.grant_id = g.id AND a.shadow = v_shadow)) ORDER BY g.created_at)
                        FROM public.billing_allowance_grants g WHERE g.business_id = p_business_id), '[]'::JSONB),
    'periods', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.period_start DESC) FROM (SELECT p.id, p.period_start, p.period_end, p.status, p.subscription_amount, p.transaction_fees_amount, p.debits_amount, p.credits_amount,
                          p.amount_due, p.amount_paid, p.outstanding_amount, p.billable_gmv, p.eligible_orders, p.free_onboarding_orders, p.free_monthly_orders, p.chargeable_orders, p.fees_before_cap
                          FROM public.billing_periods p WHERE p.business_id = p_business_id AND p.shadow = v_shadow ORDER BY p.period_start DESC LIMIT 24) x), '[]'::JSONB),
    'assessments', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.assessed_at DESC) FROM (SELECT o.order_number, a.assessed_at, a.delivered_at, a.kind, a.adjustment_seq, a.billable_gmv, a.outcome, a.free_source, a.free_seq,
                          a.percentage, a.calculated_fee, a.fee_after_limits, a.cap_adjustment, a.charged_amount, a.rule_version
                          FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id = p_business_id AND a.shadow = v_shadow ORDER BY a.assessed_at DESC LIMIT 50) x), '[]'::JSONB),
    'ledger', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT e.created_at, e.entry_type, e.gross_amount, e.percentage, e.calculated_fee, e.charged_amount, e.credit_amount, e.reason, e.source
                          FROM public.billing_ledger_entries e WHERE e.business_id = p_business_id AND e.shadow = v_shadow ORDER BY e.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'audit', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT l.created_at, l.activity, l.performed_by_email, l.details
                          FROM public.audit_logs l WHERE l.business_id = p_business_id AND (l.activity LIKE 'Billing%' OR l.activity LIKE 'Order billing%') ORDER BY l.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'queue', COALESCE((SELECT jsonb_agg(jsonb_build_object('order_id', q.order_id, 'kind', q.kind, 'status', q.status, 'attempts', q.attempts, 'error', q.last_error))
                       FROM public.billing_engine_queue q JOIN public.orders o ON o.id = q.order_id WHERE o.wholesaler_id = p_business_id AND q.status <> 'done'), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_business_detail(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_business_detail(UUID, TEXT) TO authenticated, service_role;
