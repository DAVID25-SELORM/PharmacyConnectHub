-- Platform billing, Phase 2 part 2: the BILLING ENGINE. It calculates, in the database and atomically, what each delivered order is billed under the terms in force, following the rules in
-- docs/platform-billing.md section 5. It runs in SHADOW first: with billing 'disabled' (the default and the state in production) every function here returns at once and writes nothing.
--
--   billing_compute_fee()             the fee arithmetic, one place: percentage, then per-order minimum, then maximum, rounded half-up to 2 decimals once. (The monthly cap is applied by the engine.)
--   billing_assess_order()            when an order is delivered: eligibility, free-order consumption, fee, cap, snapshot, ledger, period totals. Idempotent (one primary assessment per order).
--   billing_assess_order_change()     later changes in an order's value (delivery credit, back-order shipment, returned goods) become numbered ADJUSTMENT assessments for the difference.
--   billing_open_periods()            opens each business's rolling periods (and their subscription charge, waived during the trial) even when it has no orders.
--   billing_advance_states()          trial ends, cancellations take effect.
--   billing_process_queue()/billing_catch_up()   retries of any delivery whose billing failed (a failure never blocks the delivery) and orders delivered before the engine saw them.
--   billing_run_scheduled()           the three above together; scheduled with pg_cron when it is available.
--   billing_reconcile()               checks for anything inconsistent (administrators read it with admin_billing_reconciliation()).
-- All of these are for the server only. Triggers call them when an order is delivered, when a delivered order's value changes and when a return is resolved.

-- ---------------------------------------------------------------------------
-- 1. Pure helpers
-- ---------------------------------------------------------------------------
-- The fee for an order of p_billable at p_pct percent: calculated_fee is the pure percentage rounded to 2 decimals; fee_after_limits applies the per-order minimum then maximum (when
-- set) to the unrounded value and rounds ONCE. A zero percentage or a zero-value order has no fee, whatever the minimum. NULL limits mean no limit.
CREATE OR REPLACE FUNCTION public.billing_compute_fee(p_billable NUMERIC, p_pct NUMERIC, p_min NUMERIC, p_max NUMERIC)
RETURNS TABLE (calculated_fee NUMERIC, fee_after_limits NUMERIC)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_raw NUMERIC;
  v NUMERIC;
BEGIN
  IF p_billable IS NULL OR p_pct IS NULL OR p_billable < 0 OR p_pct < 0 THEN RAISE EXCEPTION 'A fee needs a non-negative order value and percentage.'; END IF;
  v_raw := p_billable * p_pct / 100;
  calculated_fee := round(v_raw, 2);
  IF p_pct = 0 OR p_billable = 0 THEN
    fee_after_limits := 0.00;
  ELSE
    v := v_raw;
    IF p_min IS NOT NULL AND v < p_min THEN v := p_min; END IF;
    IF p_max IS NOT NULL AND v > p_max THEN v := p_max; END IF;
    fee_after_limits := round(v, 2);
  END IF;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_compute_fee(NUMERIC, NUMERIC, NUMERIC, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_compute_fee(NUMERIC, NUMERIC, NUMERIC, NUMERIC) TO service_role;

-- The mode a business is in ignoring a pause or an end (those are handled by the engine, which records the order as excluded rather than skipping it).
CREATE OR REPLACE FUNCTION public._billing_base_mode(p_org_mode TEXT, p_platform_mode TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE LEAST(CASE COALESCE(p_platform_mode, 'disabled') WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END,
                    CASE COALESCE(p_org_mode, p_platform_mode, 'disabled') WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END)
              WHEN 2 THEN 'active' WHEN 1 THEN 'shadow' ELSE 'disabled' END
$$;

-- What a delivered order is worth for billing: goods after discounts and accepted shortages (the effective total), without the delivery fee, less the value of goods returned and
-- credited or refunded. Never below zero.
CREATE OR REPLACE FUNCTION public._billing_billable(p_order_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(round(COALESCE(o.effective_total_ghs, o.total_ghs) - COALESCE(o.delivery_fee_ghs, 0)
                        - COALESCE((SELECT sum(r.resolved_amount_ghs) FROM public.order_returns r WHERE r.order_id = o.id AND r.status = 'resolved' AND r.resolution IN ('refund', 'credit')), 0), 2), 0)
  FROM public.orders o WHERE o.id = p_order_id
$$;
REVOKE ALL ON FUNCTION public._billing_billable(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_billable(UUID) TO service_role;

-- The period containing a moment for one business and kind (real or shadow), created if it does not exist (with its subscription charge, waived while the trial lasts or billing is
-- paused). The caller holds the subscription's row lock, so two callers never create it twice.
CREATE OR REPLACE FUNCTION public._billing_ensure_period(p_sub public.billing_subscriptions, p_at TIMESTAMPTZ, p_shadow BOOLEAN)
RETURNS public.billing_periods
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_interval INTEGER := COALESCE((public.billing_resolve_terms(p_sub.business_id, p_sub.billing_starts_at) ->> 'billing_interval_months')::INTEGER, 1);
  b RECORD;
  v_p public.billing_periods%ROWTYPE;
  v_terms JSONB;
  v_amount NUMERIC(12,2);
  v_waived BOOLEAN;
  v_why TEXT;
BEGIN
  SELECT * INTO b FROM public.billing_period_bounds(p_sub.period_anchor_at, v_interval, p_at);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.business_id = p_sub.business_id AND p.period_start = b.period_start AND p.shadow = p_shadow;
  IF FOUND THEN RETURN v_p; END IF;
  v_terms := public.billing_resolve_terms(p_sub.business_id, b.period_start);
  IF v_terms IS NULL THEN RAISE EXCEPTION 'No billing terms were in force at the start of this period.'; END IF;
  INSERT INTO public.billing_periods(business_id, subscription_id, period_start, period_end, shadow, currency)
  VALUES (p_sub.business_id, p_sub.id, b.period_start, b.period_end, p_shadow, v_terms ->> 'currency') RETURNING * INTO v_p;
  v_amount := COALESCE((v_terms ->> 'subscription_amount')::NUMERIC, 0);
  v_waived := p_sub.billing_paused OR (p_sub.trial_end IS NOT NULL AND b.period_start < p_sub.trial_end);
  v_why := CASE WHEN p_sub.billing_paused THEN 'Billing is paused' WHEN v_waived THEN 'Free trial' END;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, shadow, currency, charged_amount, source, idempotency_key, reason, metadata)
  VALUES (p_sub.business_id, v_p.id, 'subscription_charge', p_shadow, v_terms ->> 'currency', CASE WHEN v_waived THEN 0 ELSE v_amount END, 'engine',
          'sub:' || v_p.id, v_why, jsonb_build_object('plan_amount', v_amount, 'waived', v_waived, 'plan_code', v_terms ->> 'plan_code', 'plan_version', v_terms -> 'plan_version'));
  UPDATE public.billing_periods SET subscription_amount = CASE WHEN v_waived THEN 0 ELSE v_amount END WHERE id = v_p.id RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_ensure_period(public.billing_subscriptions, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The assessment of a delivered order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_assess_order(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_at := COALESCE(v_o.delivered_at, now());
  -- Shadow counts orders from the billing start; REAL billing only from the moment it was activated (orders delivered earlier are never charged).
  v_gate := CASE WHEN v_shadow THEN v_sub.billing_starts_at ELSE COALESCE(v_sub.activated_at, v_sub.billing_starts_at) END;
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
  IF v_sub.exempt_from_transaction_fees OR COALESCE((v_terms ->> 'exempt_from_transaction_fees')::BOOLEAN, FALSE) THEN
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
$$;
REVOKE ALL ON FUNCTION public.billing_assess_order(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_assess_order(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Later changes in an order's value
-- ---------------------------------------------------------------------------
-- Compares what the order is worth now with everything already assessed for it, and records the DIFFERENCE as the next numbered adjustment, priced under the order's own terms (its
-- percentage and per-order limits) and landing in the period that contains now. A drop becomes a credit; a rise is charged within the cap; an order that was free stays free; an adjustment
-- never consumes a free order. Repeating it with nothing changed records nothing.
CREATE OR REPLACE FUNCTION public.billing_assess_order_change(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_o RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_platform TEXT;
  v_mode TEXT;
  v_shadow BOOLEAN;
  v_prim public.order_billing_assessments%ROWTYPE;
  v_now_terms JSONB;
  v_period public.billing_periods%ROWTYPE;
  v_current NUMERIC(14,2);
  v_assessed NUMERIC(14,2);
  v_delta NUMERIC(14,2);
  v_seq INTEGER;
  v_outcome TEXT;
  v_total_fee NUMERIC(12,2);
  v_prior_fee NUMERIC(12,2);
  v_delta_fee NUMERIC(12,2) := 0;
  v_charged NUMERIC(12,2) := 0;
  v_cap_adj NUMERIC(12,2) := 0;
  v_cap NUMERIC;
  v_remaining NUMERIC;
  v_id UUID;
  v_key TEXT;
  v_name TEXT;
BEGIN
  SELECT o.id, o.order_number, o.wholesaler_id, o.status::TEXT AS status INTO v_o FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR v_o.status <> 'delivered' THEN RETURN jsonb_build_object('skipped', 'not_delivered'); END IF;
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = v_o.wholesaler_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('skipped', 'no_subscription'); END IF;
  SELECT s.mode INTO v_platform FROM public.billing_settings s WHERE s.id;
  v_mode := public._billing_base_mode(v_sub.billing_mode, v_platform);
  IF v_mode = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_shadow := v_mode = 'shadow';
  SELECT * INTO v_prim FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'primary' AND a.shadow = v_shadow;
  IF NOT FOUND THEN RETURN jsonb_build_object('skipped', 'not_assessed'); END IF;

  v_current := public._billing_billable(p_order_id);
  SELECT v_prim.billable_gmv + COALESCE(sum(a.billable_gmv), 0) INTO v_assessed FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'adjustment' AND a.shadow = v_shadow;
  v_delta := v_current - v_assessed;
  IF v_delta = 0 THEN RETURN jsonb_build_object('skipped', 'no_change'); END IF;
  SELECT COALESCE(max(a.adjustment_seq), 0) + 1 INTO v_seq FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'adjustment' AND a.shadow = v_shadow;

  v_now_terms := public.billing_resolve_terms(v_o.wholesaler_id, now());
  IF v_now_terms IS NULL THEN RETURN jsonb_build_object('skipped', 'no_terms'); END IF;
  v_period := public._billing_ensure_period(v_sub, now(), v_shadow);
  SELECT * INTO v_period FROM public.billing_periods p WHERE p.id = v_period.id FOR UPDATE;

  IF v_prim.outcome = 'chargeable' THEN
    v_outcome := 'chargeable';
    SELECT f.fee_after_limits INTO v_total_fee FROM public.billing_compute_fee(v_current, v_prim.percentage, (v_prim.terms_snapshot ->> 'transaction_fee_min')::NUMERIC, (v_prim.terms_snapshot ->> 'transaction_fee_max')::NUMERIC) f;
    SELECT v_prim.fee_after_limits + COALESCE(sum(a.fee_after_limits), 0) INTO v_prior_fee FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'adjustment' AND a.shadow = v_shadow;
    v_delta_fee := v_total_fee - v_prior_fee;
    IF v_delta_fee > 0 THEN
      v_cap := (v_now_terms ->> 'transaction_fee_cycle_cap')::NUMERIC;
      v_charged := CASE WHEN v_cap IS NULL THEN v_delta_fee ELSE LEAST(v_delta_fee, GREATEST(v_cap - v_period.transaction_fees_amount, 0)) END;
      v_cap_adj := v_delta_fee - v_charged;
    ELSE
      v_charged := v_delta_fee;
    END IF;
  ELSIF v_prim.outcome IN ('free_onboarding', 'free_monthly', 'free_adjustment') THEN
    v_outcome := 'free_adjustment';
  ELSE
    v_outcome := v_prim.outcome;
  END IF;

  INSERT INTO public.order_billing_assessments(business_id, order_id, retailer_business_id, kind, adjustment_seq, shadow, period_id, subscription_terms_id, plan_version_id, delivered_at, currency,
    billable_gmv, outcome, percentage, calculated_fee, fee_after_limits, cap_adjustment, charged_amount, terms_snapshot, rule_version)
  VALUES (v_o.wholesaler_id, p_order_id, v_prim.retailer_business_id, 'adjustment', v_seq, v_shadow, v_period.id, v_prim.subscription_terms_id, v_prim.plan_version_id, v_prim.delivered_at, v_prim.currency,
    v_delta, v_outcome, v_prim.percentage, NULL, CASE WHEN v_outcome = 'chargeable' THEN v_delta_fee END, v_cap_adj, v_charged,
    v_prim.terms_snapshot || jsonb_build_object('adjustment', jsonb_build_object('order_value_now', v_current, 'previously_assessed', v_assessed, 'delta', v_delta, 'cap_at_adjustment', (v_now_terms ->> 'transaction_fee_cycle_cap'))),
    'billing-engine-1')
  RETURNING id INTO v_id;

  v_key := p_order_id || ':adj' || v_seq || ':' || CASE WHEN v_shadow THEN 's' ELSE 'r' END;
  IF v_outcome = 'chargeable' AND v_charged > 0 THEN
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, percentage, calculated_fee, charged_amount, source, idempotency_key, reason, metadata)
    VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'transaction_fee', v_shadow, v_prim.currency, v_delta, v_prim.percentage, v_delta_fee, v_charged, 'engine', 'fee:' || v_key,
            'Order value rose after delivery', jsonb_build_object('adjustment', v_seq));
  ELSIF v_outcome = 'chargeable' AND v_charged < 0 THEN
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, percentage, calculated_fee, credit_amount, source, idempotency_key, reason, metadata)
    VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'refund', v_shadow, v_prim.currency, v_delta, v_prim.percentage, v_delta_fee, -v_charged, 'engine', 'fee:' || v_key,
            'Order value fell after delivery (delivery credit or returned goods)', jsonb_build_object('adjustment', v_seq));
  END IF;
  IF v_cap_adj > 0 THEN
    INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, gross_amount, calculated_fee, charged_amount, source, idempotency_key, reason, metadata)
    VALUES (v_o.wholesaler_id, v_period.id, p_order_id, v_id, 'fee_cap_adjustment', v_shadow, v_prim.currency, v_delta, v_cap_adj, 0, 'engine', 'cap:' || v_key,
            'Monthly fee cap reached: ' || v_cap_adj || ' of the calculated fee is not charged', jsonb_build_object('adjustment', v_seq));
  END IF;

  UPDATE public.billing_periods SET
    billable_gmv = billable_gmv + v_delta,
    fees_before_cap = fees_before_cap + CASE WHEN v_outcome = 'chargeable' AND v_delta_fee > 0 THEN v_delta_fee ELSE 0 END,
    transaction_fees_amount = transaction_fees_amount + CASE WHEN v_charged > 0 THEN v_charged ELSE 0 END,
    credits_amount = credits_amount + CASE WHEN v_charged < 0 THEN -v_charged ELSE 0 END
  WHERE id = v_period.id;

  IF NOT v_shadow THEN
    SELECT name INTO v_name FROM public.businesses WHERE id = v_o.wholesaler_id;
    PERFORM public.write_audit_log('Order billing adjusted', v_name, 'order_billing_assessment', v_id, v_o.order_number,
      jsonb_build_object('adjustment', v_seq, 'delta', v_delta, 'outcome', v_outcome, 'charged', v_charged, 'cap_adjustment', v_cap_adj),
      _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => v_o.wholesaler_id);
  END IF;
  RETURN jsonb_build_object('assessment_id', v_id, 'adjustment', v_seq, 'delta', v_delta, 'outcome', v_outcome, 'charged', v_charged, 'shadow', v_shadow);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_assess_order_change(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_assess_order_change(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Triggers: a failure in billing must NEVER stop a delivery, a value change or a return
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_queue_failure(p_order_id UUID, p_kind TEXT, p_error TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  INSERT INTO public.billing_engine_queue(order_id, kind, status, attempts, last_error, last_attempt_at)
  VALUES (p_order_id, p_kind, 'pending', 1, left(p_error, 500), now())
  ON CONFLICT (order_id, kind) DO UPDATE SET status = CASE WHEN public.billing_engine_queue.status = 'done' THEN 'pending' ELSE public.billing_engine_queue.status END,
    last_error = left(p_error, 500), last_attempt_at = now(), updated_at = now()
$$;
REVOKE ALL ON FUNCTION public._billing_queue_failure(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.orders_billing_on_delivered()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.billing_assess_order(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    PERFORM public._billing_queue_failure(NEW.id, 'assess', SQLERRM);
    RAISE WARNING 'billing could not assess order %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.orders_billing_on_delivered() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_orders_billing_delivered ON public.orders;
CREATE TRIGGER trg_orders_billing_delivered AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.orders_billing_on_delivered();

CREATE OR REPLACE FUNCTION public.orders_billing_on_value_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.billing_assess_order_change(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    PERFORM public._billing_queue_failure(NEW.id, 'change', SQLERRM);
    RAISE WARNING 'billing could not adjust order %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.orders_billing_on_value_change() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_orders_billing_value_change ON public.orders;
CREATE TRIGGER trg_orders_billing_value_change AFTER UPDATE OF effective_total_ghs ON public.orders
  FOR EACH ROW WHEN (NEW.status = 'delivered' AND NEW.effective_total_ghs IS DISTINCT FROM OLD.effective_total_ghs) EXECUTE FUNCTION public.orders_billing_on_value_change();

CREATE OR REPLACE FUNCTION public.order_returns_billing_on_resolved()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM public.billing_assess_order_change(NEW.order_id);
  EXCEPTION WHEN OTHERS THEN
    PERFORM public._billing_queue_failure(NEW.order_id, 'change', SQLERRM);
    RAISE WARNING 'billing could not adjust order % for a return: %', NEW.order_id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.order_returns_billing_on_resolved() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_order_returns_billing ON public.order_returns;
CREATE TRIGGER trg_order_returns_billing AFTER UPDATE OF status ON public.order_returns
  FOR EACH ROW WHEN (NEW.status = 'resolved' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.order_returns_billing_on_resolved();

-- ---------------------------------------------------------------------------
-- 5. Periods, trial and cancellation, retries and catch-up
-- ---------------------------------------------------------------------------
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
      SELECT max(p.period_end) INTO v_last FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow;
      v_at := COALESCE(v_last, v_sub.billing_starts_at);
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
REVOKE ALL ON FUNCTION public.billing_open_periods(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_open_periods(TIMESTAMPTZ) TO service_role;

-- A trial that has ended becomes an active subscription; a subscription set to cancel at the end of its period gets that end date and becomes cancelled when it arrives.
CREATE OR REPLACE FUNCTION public.billing_advance_states(p_now TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.billing_subscriptions%ROWTYPE;
  v_n INTEGER := 0;
  b RECORD;
  v_name TEXT;
  v_interval INTEGER;
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN 0; END IF;
  FOR v_sub IN SELECT * FROM public.billing_subscriptions s WHERE s.billing_starts_at <= p_now AND s.status IN ('trialing', 'active', 'past_due', 'grace_period') ORDER BY s.id FOR UPDATE LOOP
    SELECT name INTO v_name FROM public.businesses WHERE id = v_sub.business_id;
    IF v_sub.status = 'trialing' AND v_sub.trial_end IS NOT NULL AND v_sub.trial_end <= p_now THEN
      UPDATE public.billing_subscriptions SET status = 'active' WHERE id = v_sub.id;
      PERFORM public.write_audit_log('Billing trial ended', v_name, 'billing_subscription', v_sub.id, 'Trial', jsonb_build_object('trial_end', v_sub.trial_end),
        _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => v_sub.business_id);
      v_n := v_n + 1;
    END IF;
    IF v_sub.cancel_at_period_end AND v_sub.ended_at IS NULL THEN
      v_interval := COALESCE((public.billing_resolve_terms(v_sub.business_id, v_sub.billing_starts_at) ->> 'billing_interval_months')::INTEGER, 1);
      SELECT * INTO b FROM public.billing_period_bounds(v_sub.period_anchor_at, v_interval, GREATEST(p_now, v_sub.period_anchor_at));
      UPDATE public.billing_subscriptions SET ended_at = b.period_end, cancelled_at = COALESCE(cancelled_at, p_now) WHERE id = v_sub.id RETURNING * INTO v_sub;
    END IF;
    IF v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= p_now AND v_sub.status <> 'cancelled' THEN
      UPDATE public.billing_subscriptions SET status = 'cancelled' WHERE id = v_sub.id;
      PERFORM public.write_audit_log('Billing subscription ended', v_name, 'billing_subscription', v_sub.id, 'Cancellation', jsonb_build_object('ended_at', v_sub.ended_at),
        _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => v_sub.business_id);
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_advance_states(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_advance_states(TIMESTAMPTZ) TO service_role;

-- Retries every pending queue entry (up to 10 attempts, then it is marked failed and shows in reconciliation).
CREATE OR REPLACE FUNCTION public.billing_process_queue(p_limit INTEGER DEFAULT 50)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  q RECORD;
  v_done INTEGER := 0;
  v_failed INTEGER := 0;
  v_res JSONB;
BEGIN
  FOR q IN SELECT * FROM public.billing_engine_queue e WHERE e.status = 'pending' ORDER BY e.created_at, e.id LIMIT GREATEST(COALESCE(p_limit, 50), 1) FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      v_res := CASE q.kind WHEN 'assess' THEN public.billing_assess_order(q.order_id) ELSE public.billing_assess_order_change(q.order_id) END;
      UPDATE public.billing_engine_queue SET status = 'done', attempts = attempts + 1, last_attempt_at = now(), updated_at = now(), last_error = NULL WHERE id = q.id;
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.billing_engine_queue SET attempts = attempts + 1, last_attempt_at = now(), updated_at = now(), last_error = left(SQLERRM, 500),
        status = CASE WHEN attempts + 1 >= 10 THEN 'failed' ELSE 'pending' END WHERE id = q.id;
      v_failed := v_failed + 1;
    END;
  END LOOP;
  RETURN jsonb_build_object('done', v_done, 'failed', v_failed);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_process_queue(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_process_queue(INTEGER) TO service_role;

-- Delivered orders that the engine has not assessed (delivered before the business was in a billing mode, or the trigger failed and nothing queued it), oldest delivery first so free
-- orders are used in delivery order.
CREATE OR REPLACE FUNCTION public._billing_unassessed_orders()
RETURNS TABLE (order_id UUID, delivered_at TIMESTAMPTZ)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.id, COALESCE(o.delivered_at, o.updated_at)
  FROM public.orders o
  JOIN public.billing_subscriptions s ON s.business_id = o.wholesaler_id
  CROSS JOIN public.billing_settings bs
  WHERE o.status = 'delivered' AND bs.id AND public._billing_base_mode(s.billing_mode, bs.mode) <> 'disabled'
    AND COALESCE(o.delivered_at, o.updated_at) >= CASE WHEN public._billing_base_mode(s.billing_mode, bs.mode) = 'shadow' THEN s.billing_starts_at ELSE COALESCE(s.activated_at, s.billing_starts_at) END
    AND (s.ended_at IS NULL OR COALESCE(o.delivered_at, o.updated_at) < s.ended_at)
    AND NOT EXISTS (SELECT 1 FROM public.order_billing_assessments a WHERE a.order_id = o.id AND a.kind = 'primary' AND a.shadow = (public._billing_base_mode(s.billing_mode, bs.mode) = 'shadow'))
  ORDER BY COALESCE(o.delivered_at, o.updated_at), o.id
$$;
REVOKE ALL ON FUNCTION public._billing_unassessed_orders() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_unassessed_orders() TO service_role;

CREATE OR REPLACE FUNCTION public.billing_catch_up(p_limit INTEGER DEFAULT 200)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_done INTEGER := 0;
  v_failed INTEGER := 0;
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN jsonb_build_object('done', 0, 'failed', 0); END IF;
  FOR r IN SELECT u.order_id FROM public._billing_unassessed_orders() u LIMIT GREATEST(COALESCE(p_limit, 200), 1) LOOP
    BEGIN
      PERFORM public.billing_assess_order(r.order_id);
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      PERFORM public._billing_queue_failure(r.order_id, 'assess', SQLERRM);
      v_failed := v_failed + 1;
    END;
  END LOOP;
  RETURN jsonb_build_object('done', v_done, 'failed', v_failed);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_catch_up(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_catch_up(INTEGER) TO service_role;

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
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_states := public.billing_advance_states(p_now);
  v_periods := public.billing_open_periods(p_now);
  v_queue := public.billing_process_queue(100);
  v_catch := public.billing_catch_up(200);
  RETURN jsonb_build_object('states_advanced', v_states, 'periods_opened', v_periods, 'queue', v_queue, 'catch_up', v_catch);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_run_scheduled(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_run_scheduled(TIMESTAMPTZ) TO service_role;

-- An administrator can run the scheduled work now (with a reason; it is audited).
CREATE OR REPLACE FUNCTION public.admin_billing_run_now(p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_res JSONB;
BEGIN
  v_res := public.billing_run_scheduled(now());
  PERFORM public.write_audit_log('Billing run now', 'DrugXOne', 'billing_settings', NULL, 'Billing run', jsonb_build_object('reason', v_reason, 'result', v_res));
  RETURN v_res;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_run_now(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_run_now(TEXT) TO authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('drugxone-billing-run', '*/15 * * * *', 'SELECT public.billing_run_scheduled()');
  ELSE
    RAISE NOTICE 'pg_cron is not enabled: run billing with admin_billing_run_now() or schedule billing_run_scheduled() yourself.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Could not schedule the billing run: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Reconciliation: anything inconsistent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_reconcile()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 'delivered_order_not_assessed'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', x.order_id, 'delivered_at', x.delivered_at)) FILTER (WHERE x.rn <= 5), '[]'::JSONB)
  FROM (SELECT u.order_id, u.delivered_at, row_number() OVER () rn FROM public._billing_unassessed_orders() u) x;
  RETURN QUERY
  SELECT 'duplicate_primary_assessment'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', d.order_id, 'shadow', d.shadow, 'n', d.n)) FILTER (WHERE d.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.order_id, a.shadow, count(*) n, row_number() OVER () rn FROM public.order_billing_assessments a WHERE a.kind = 'primary' GROUP BY a.order_id, a.shadow HAVING count(*) > 1) d;
  RETURN QUERY
  SELECT 'assessment_business_differs_from_order'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('assessment_id', m.id, 'order_id', m.order_id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.id, a.order_id, row_number() OVER () rn FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id <> o.wholesaler_id) m;
  RETURN QUERY
  SELECT 'period_transaction_fees_differ_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.transaction_fees_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.transaction_fees_amount, COALESCE((SELECT sum(e.charged_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id AND e.entry_type = 'transaction_fee'), 0) l, row_number() OVER () rn
        FROM public.billing_periods p) m WHERE m.transaction_fees_amount <> m.l;
  RETURN QUERY
  SELECT 'period_credits_differ_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.credits_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.credits_amount, COALESCE((SELECT sum(e.credit_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id), 0) l, row_number() OVER () rn FROM public.billing_periods p) m WHERE m.credits_amount <> m.l;
  RETURN QUERY
  SELECT 'period_subscription_differs_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.subscription_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.subscription_amount, COALESCE((SELECT sum(e.charged_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id AND e.entry_type = 'subscription_charge'), 0) l, row_number() OVER () rn
        FROM public.billing_periods p) m WHERE m.subscription_amount <> m.l;
  RETURN QUERY
  SELECT 'period_counters_differ_from_assessments'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, row_number() OVER () rn FROM public.billing_periods p
        WHERE p.eligible_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome IN ('free_onboarding', 'free_monthly', 'chargeable'))
           OR p.free_onboarding_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'free_onboarding')
           OR p.free_monthly_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'free_monthly')
           OR p.chargeable_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'chargeable')) m;
  RETURN QUERY
  SELECT 'assessment_charge_differs_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('assessment_id', m.id, 'charged', m.charged_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.id, a.charged_amount,
               COALESCE((SELECT sum(e.charged_amount - e.credit_amount) FROM public.billing_ledger_entries e WHERE e.assessment_id = a.id AND e.entry_type IN ('transaction_fee', 'refund')), 0) l, row_number() OVER () rn
        FROM public.order_billing_assessments a) m WHERE m.charged_amount <> m.l;
  RETURN QUERY
  SELECT 'free_order_numbers_not_contiguous'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('scope', m.scope, 'shadow', m.shadow, 'used', m.n, 'highest', m.hi)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT COALESCE(a.grant_id::TEXT, a.period_id::TEXT) scope, a.shadow, count(*) n, max(a.free_seq) hi, row_number() OVER () rn FROM public.order_billing_assessments a
        WHERE a.free_source IS NOT NULL AND a.kind = 'primary' GROUP BY COALESCE(a.grant_id::TEXT, a.period_id::TEXT), a.shadow, a.free_source HAVING count(*) <> max(a.free_seq)) m;
  RETURN QUERY
  SELECT 'onboarding_grant_overused'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('grant_id', m.id, 'granted', m.quantity, 'used', m.n)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT g.id, g.quantity, row_number() OVER () rn, (SELECT max(c.n) FROM (SELECT count(*) n FROM public.order_billing_assessments a WHERE a.grant_id = g.id AND a.free_source = 'onboarding' GROUP BY a.shadow) c) n
        FROM public.billing_allowance_grants g) m WHERE m.n > m.quantity;
  RETURN QUERY
  SELECT 'period_fees_exceed_the_cap'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'fees', m.transaction_fees_amount, 'cap', m.cap)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.transaction_fees_amount, row_number() OVER () rn,
               (SELECT min((a.terms_snapshot ->> 'transaction_fee_cycle_cap')::NUMERIC) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND (a.terms_snapshot ->> 'transaction_fee_cycle_cap') IS NOT NULL) cap
        FROM public.billing_periods p) m WHERE m.cap IS NOT NULL AND m.transaction_fees_amount > m.cap;
  RETURN QUERY
  SELECT 'billing_queue_stuck'::TEXT, 'warning'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', m.order_id, 'kind', m.kind, 'status', m.status, 'attempts', m.attempts, 'error', m.last_error)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT q.order_id, q.kind, q.status, q.attempts, q.last_error, row_number() OVER () rn FROM public.billing_engine_queue q
        WHERE q.status = 'failed' OR (q.status = 'pending' AND q.created_at < now() - interval '1 hour')) m;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_reconcile() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_reconcile() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_reconciliation()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('check', r.check_name, 'severity', r.severity, 'count', r.finding_count, 'details', r.details) ORDER BY r.severity, r.check_name) INTO v_rows FROM public.billing_reconcile() r;
  RETURN jsonb_build_object('checked_at', now(), 'checks', v_rows,
    'healthy', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) c WHERE (c ->> 'count')::INTEGER > 0));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_reconciliation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_reconciliation() TO authenticated, service_role;
