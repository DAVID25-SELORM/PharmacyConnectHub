-- Billing audit fixes. Forward-only definitions; no historical money rows are rewritten.
BEGIN;

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
  v_net_charged NUMERIC;
  v_waived NUMERIC;
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
  IF NOT v_shadow AND (v_sub.activated_at IS NULL OR v_sub.activated_at > now()) THEN RETURN jsonb_build_object('skipped', 'not_activated'); END IF;
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
      -- A cap discount was never paid: reducing a theoretical fee cannot refund it.
      -- Waivers also consume refundable fees. Preserve all prior assessment rows.
      SELECT COALESCE(sum(a.charged_amount), 0) INTO v_net_charged
      FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.shadow = v_shadow;
      SELECT COALESCE(sum(e.credit_amount), 0) INTO v_waived
      FROM public.billing_ledger_entries e WHERE e.order_id = p_order_id AND e.shadow = v_shadow AND e.entry_type = 'fee_waiver';
      v_charged := -LEAST(GREATEST(v_net_charged - v_total_fee, 0), GREATEST(v_net_charged - v_waived, 0));
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
  IF p_mode IS NULL AND v_sub.activated_at IS NULL AND (SELECT mode FROM public.billing_settings WHERE id) = 'active' THEN
    RAISE EXCEPTION 'Use Put this business live to start real billing; following the platform cannot activate a shadow business.';
  END IF;
  SELECT name INTO v_name FROM public.businesses WHERE id = p_business_id;
  UPDATE public.billing_subscriptions SET billing_mode = p_mode WHERE id = v_sub.id;
  PERFORM public.write_audit_log('Billing mode changed for a business', v_name, 'billing_subscription', v_sub.id, 'Billing mode',
    jsonb_build_object('previous', v_sub.billing_mode, 'new', p_mode, 'reason', v_reason), _business_id => p_business_id);
END;
$$;

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
      CONTINUE WHEN NOT v_shadow AND (v_sub.activated_at IS NULL OR v_sub.activated_at > p_now);
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
  v_waived := p_sub.billing_paused OR (p_sub.trial_end IS NOT NULL AND b.period_start < p_sub.trial_end);
  v_why := CASE WHEN p_sub.billing_paused THEN 'Billing is paused' WHEN v_waived THEN 'Free trial' END;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, shadow, currency, charged_amount, source, idempotency_key, reason, metadata)
  VALUES (p_sub.business_id, v_p.id, 'subscription_charge', p_shadow, v_terms ->> 'currency', CASE WHEN v_waived THEN 0 ELSE v_amount END, 'engine',
          'sub:' || v_p.id, v_why, jsonb_build_object('plan_amount', v_amount, 'waived', v_waived, 'plan_code', v_terms ->> 'plan_code', 'plan_version', v_terms -> 'plan_version'));
  UPDATE public.billing_periods SET subscription_amount = CASE WHEN v_waived THEN 0 ELSE v_amount END WHERE id = v_p.id RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

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
    AND COALESCE(o.delivered_at, o.updated_at) >= CASE WHEN public._billing_base_mode(s.billing_mode, bs.mode) = 'shadow' THEN s.billing_starts_at ELSE s.activated_at END
    AND (s.ended_at IS NULL OR COALESCE(o.delivered_at, o.updated_at) < s.ended_at)
    AND NOT EXISTS (SELECT 1 FROM public.order_billing_assessments a WHERE a.order_id = o.id AND a.kind = 'primary' AND a.shadow = (public._billing_base_mode(s.billing_mode, bs.mode) = 'shadow'))
  ORDER BY COALESCE(o.delivered_at, o.updated_at), o.id
$$;

CREATE OR REPLACE FUNCTION public.billing_effective_mode(p_business_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform TEXT;
  v_sub RECORD;
  v_rank INTEGER;
  v_org_rank INTEGER;
BEGIN
  SELECT s.mode INTO v_platform FROM public.billing_settings s WHERE s.id;
  SELECT s.billing_mode, s.billing_paused, s.ended_at, s.activated_at INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND OR COALESCE(v_platform, 'disabled') = 'disabled' OR v_sub.billing_paused OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RETURN 'disabled'; END IF;
  v_rank := CASE v_platform WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END;
  v_org_rank := CASE COALESCE(v_sub.billing_mode, v_platform) WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END;
  IF LEAST(v_rank, v_org_rank) = 2 AND (v_sub.activated_at IS NULL OR v_sub.activated_at > now()) THEN RETURN 'disabled'; END IF;
  RETURN CASE LEAST(v_rank, v_org_rank) WHEN 2 THEN 'active' WHEN 1 THEN 'shadow' ELSE 'disabled' END;
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
  IF public.billing_effective_mode(p_sub.business_id) <> 'active' OR p_sub.activated_at IS NULL OR p_sub.activated_at > now() THEN
    RAISE EXCEPTION 'Real billing is not running for this business yet, so there is no bill to put this on.';
  END IF;
  v_p := public._billing_ensure_period(p_sub, now(), FALSE);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.id = v_p.id FOR UPDATE;
  RETURN v_p;
END;
$$;

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
    || jsonb_build_object('key', 'zero_commission', 'label', 'Paystack platform commission is zero', 'blocking', TRUE, 'ok', COALESCE((SELECT platform_fee_bps = 0 FROM public.payments_settings WHERE id), FALSE), 'detail', 'Use platform billing only; set Paystack platform_fee_bps to zero before activation.')
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
  PERFORM pg_advisory_xact_lock(731921, 61207);
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
  PERFORM pg_advisory_xact_lock(731921, 61207);
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

-- Serialize BOTH configuration tables before any row locks or checks. This prevents
-- concurrent activation and commission changes from both seeing the other as off.
CREATE OR REPLACE FUNCTION public.billing_revenue_policy_lock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(731921, 61207);
  RETURN NULL;
END;
$$;
CREATE OR REPLACE FUNCTION public.billing_revenue_policy_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF TG_TABLE_NAME = 'billing_settings' THEN
    IF NEW.mode = 'active' AND NOT EXISTS (SELECT 1 FROM public.payments_settings WHERE id AND platform_fee_bps = 0) THEN
      RAISE EXCEPTION 'Set Paystack platform commission to zero before activating platform billing.';
    END IF;
  ELSE
    IF NEW.platform_fee_bps <> 0 AND EXISTS (SELECT 1 FROM public.billing_settings WHERE id AND mode = 'active') THEN
      RAISE EXCEPTION 'Paystack platform commission must stay zero while platform billing is active.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_revenue_policy_lock(), public.billing_revenue_policy_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER billing_revenue_policy_lock BEFORE INSERT OR UPDATE OF mode ON public.billing_settings FOR EACH STATEMENT EXECUTE FUNCTION public.billing_revenue_policy_lock();
CREATE TRIGGER billing_revenue_policy_lock BEFORE INSERT OR UPDATE OF platform_fee_bps ON public.payments_settings FOR EACH STATEMENT EXECUTE FUNCTION public.billing_revenue_policy_lock();
CREATE TRIGGER billing_revenue_policy_guard BEFORE INSERT OR UPDATE OF mode ON public.billing_settings FOR EACH ROW EXECUTE FUNCTION public.billing_revenue_policy_guard();
CREATE TRIGGER billing_revenue_policy_guard BEFORE INSERT OR UPDATE OF platform_fee_bps ON public.payments_settings FOR EACH ROW EXECUTE FUNCTION public.billing_revenue_policy_guard();
-- Existing settings are never silently changed. Refuse an inconsistent rollout.
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM public.billing_settings b CROSS JOIN public.payments_settings p WHERE b.id AND p.id AND b.mode='active' AND p.platform_fee_bps<>0) THEN
   RAISE EXCEPTION 'Existing billing/Paystack settings conflict: set platform commission to zero, then apply this migration.';
 END IF;
END $$;
COMMIT;
