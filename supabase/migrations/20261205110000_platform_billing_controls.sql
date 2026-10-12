-- Platform billing, Phase 5 (part 2): the administrator's controls and promotions.
-- Needs 20261205100000_platform_billing_controls_schema.sql. Every operation needs a platform administrator and a reason of at least five characters, and writes an audit entry (with the
-- business) saying what changed. Nothing here runs by itself and nothing is sent to a business: with billing DISABLED or in SHADOW these only record configuration; the operations that
-- put money on a bill (credits, charges, fee waivers) refuse until real billing is running for the business, because there is no real bill to put it on.
--
--   extend trial . grant free orders . apply credit . apply charge . waive an order's fee . exempt from fees . pause billing . schedule cancellation . custom pricing . change plan
--   temporary terms (add / end early) . promotions (create / switch on or off / apply to a business / list)
--
-- One existing function changes: billing_resolve_terms now lays any running temporary terms on top of the permanent ones.

-- ---------------------------------------------------------------------------
-- 1. The terms in force now include any temporary terms that are running
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_resolve_terms(p_business_id UUID, p_at TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.billing_subscriptions%ROWTYPE;
  v_terms public.billing_subscription_terms%ROWTYPE;
  v_ver public.billing_plan_versions%ROWTYPE;
  v_plan public.billing_plans%ROWTYPE;
  v_base JSONB;
  w RECORD;
  v_active JSONB := '[]'::JSONB;
BEGIN
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_terms FROM public.billing_subscription_terms t WHERE t.subscription_id = v_sub.id AND t.effective_from <= p_at ORDER BY t.effective_from DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO v_ver FROM public.billing_plan_versions v WHERE v.id = v_terms.plan_version_id;
  SELECT * INTO v_plan FROM public.billing_plans p WHERE p.id = v_ver.plan_id;
  v_base := jsonb_build_object(
    'subscription_id', v_sub.id, 'terms_id', v_terms.id, 'plan_id', v_plan.id, 'plan_code', v_plan.code, 'plan_version_id', v_ver.id, 'plan_version', v_ver.version,
    'currency', v_ver.currency, 'billing_interval_months', v_ver.billing_interval_months, 'subscription_amount', v_ver.subscription_amount,
    'onboarding_free_orders', v_ver.onboarding_free_orders, 'monthly_free_orders', v_ver.monthly_free_orders,
    'transaction_fee_percentage', v_ver.transaction_fee_percentage, 'transaction_fee_min', v_ver.transaction_fee_min, 'transaction_fee_max', v_ver.transaction_fee_max,
    'transaction_fee_cycle_cap', v_ver.transaction_fee_cycle_cap, 'min_billable_order_amount', v_ver.min_billable_order_amount,
    'max_users', v_ver.max_users, 'max_branches', v_ver.max_branches, 'entitlements', v_ver.entitlements,
    'free_trial_days', v_ver.free_trial_days, 'trial_start', v_sub.trial_start, 'trial_end', v_sub.trial_end,
    'exempt_from_transaction_fees', v_sub.exempt_from_transaction_fees, 'billing_paused', v_sub.billing_paused,
    'billing_starts_at', v_sub.billing_starts_at, 'period_anchor_at', v_sub.period_anchor_at, 'status', v_sub.status);
  v_base := v_base || v_terms.overrides;
  -- Temporary changes that are running at that moment sit on top, in the order they were made; when one ends it simply stops applying.
  FOR w IN SELECT x.id, x.overrides, x.source, x.ends_at FROM public.billing_term_windows x WHERE x.subscription_id = v_sub.id AND x.starts_at <= p_at AND p_at < x.ends_at ORDER BY x.created_at, x.id LOOP
    v_base := v_base || w.overrides;
    v_active := v_active || jsonb_build_object('window_id', w.id, 'source', w.source, 'ends_at', w.ends_at);
  END LOOP;
  RETURN v_base || jsonb_build_object('active_windows', v_active);
END;
$$;

-- ---------------------------------------------------------------------------
-- 1b. Deleting a user account no longer blocks on the billing records they made
-- ---------------------------------------------------------------------------
-- Deleting a user account makes the database clear "who created / recorded / redeemed this" on the billing records that person made. The append-only protection refused that, so an
-- administrator's account could not be deleted once they had touched billing. It now allows exactly that one change (clearing that link) and nothing else.
CREATE OR REPLACE FUNCTION public.billing_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  k TEXT;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    FOREACH k IN ARRAY ARRAY['created_by', 'recorded_by', 'redeemed_by'] LOOP
      IF to_jsonb(OLD) ? k AND to_jsonb(OLD) -> k <> 'null'::JSONB AND to_jsonb(NEW) -> k = 'null'::JSONB AND (to_jsonb(NEW) - k) = (to_jsonb(OLD) - k) THEN
        RETURN NEW;
      END IF;
    END LOOP;
  END IF;
  RAISE EXCEPTION 'Billing records are never changed or deleted (%). Record a correction instead.', TG_TABLE_NAME;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Helpers (internal: nobody signed in can call them)
-- ---------------------------------------------------------------------------
-- An amount of money typed by an administrator: positive, at most two decimals, and not absurd.
CREATE OR REPLACE FUNCTION public._billing_money(p_amount NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'Enter an amount of more than zero, with at most two decimals.'; END IF;
  IF p_amount > 1000000 THEN RAISE EXCEPTION 'That amount is too large (the most that can be entered at once is 1,000,000).'; END IF;
  RETURN p_amount;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_money(NUMERIC) FROM PUBLIC, anon, authenticated;

-- The business's subscription, locked (the same first lock the engine takes), with the business beside it.
CREATE OR REPLACE FUNCTION public._billing_lock_subscription(p_business_id UUID)
RETURNS public.billing_subscriptions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sub public.billing_subscriptions%ROWTYPE;
BEGIN
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This business has no subscription.'; END IF;
  RETURN v_sub;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_lock_subscription(UUID) FROM PUBLIC, anon, authenticated;

-- The open period that contains now, for a credit, a charge or a waiver: only while billing is REAL and live for the business (there is no bill to put it on otherwise). Locked.
CREATE OR REPLACE FUNCTION public._billing_open_real_period(p_sub public.billing_subscriptions)
RETURNS public.billing_periods
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_p public.billing_periods%ROWTYPE;
BEGIN
  IF public.billing_effective_mode(p_sub.business_id) <> 'active' OR p_sub.billing_starts_at > now() THEN
    RAISE EXCEPTION 'Real billing is not running for this business yet, so there is no bill to put this on.';
  END IF;
  v_p := public._billing_ensure_period(p_sub, now(), FALSE);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.id = v_p.id FOR UPDATE;
  RETURN v_p;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_open_real_period(public.billing_subscriptions) FROM PUBLIC, anon, authenticated;

-- A credit (money off the bill) in an open real period: the ledger entry and the period's credit total together.
CREATE OR REPLACE FUNCTION public._billing_post_credit(
  p_period public.billing_periods, p_type TEXT, p_amount NUMERIC, p_reason TEXT, p_key TEXT, p_order UUID, p_assessment UUID, p_meta JSONB)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.billing_ledger_entries(business_id, period_id, order_id, assessment_id, entry_type, shadow, currency, credit_amount, reason, source, idempotency_key, metadata, created_by)
  VALUES (p_period.business_id, p_period.id, p_order, p_assessment, p_type, p_period.shadow, p_period.currency, p_amount, p_reason, 'admin', p_key, p_meta, auth.uid()) RETURNING id INTO v_id;
  UPDATE public.billing_periods SET credits_amount = credits_amount + p_amount WHERE id = p_period.id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_post_credit(public.billing_periods, TEXT, NUMERIC, TEXT, TEXT, UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;

-- Moves a trial's end later. Subscription charges already posted to periods that are still open and start before the new end are waived with a credit (once per period); periods not yet
-- created are waived as they open. Periods already invoiced are final and are not touched.
CREATE OR REPLACE FUNCTION public._billing_do_extend_trial(p_sub public.billing_subscriptions, p_new_end TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_p RECORD;
  v_ids UUID[] := ARRAY[]::UUID[];
  v_total NUMERIC(12,2) := 0;
  v_id UUID;
BEGIN
  UPDATE public.billing_subscriptions SET trial_start = COALESCE(trial_start, billing_starts_at), trial_end = p_new_end, status = CASE WHEN status = 'active' THEN 'trialing' ELSE status END WHERE id = p_sub.id;
  FOR v_p IN SELECT * FROM public.billing_periods p WHERE p.business_id = p_sub.business_id AND p.status = 'open' AND p.period_start < p_new_end AND p.subscription_amount > 0 ORDER BY p.period_start, p.shadow LOOP
    IF EXISTS (SELECT 1 FROM public.billing_ledger_entries e WHERE e.idempotency_key = 'trialwaive:' || v_p.id) THEN CONTINUE; END IF;
    PERFORM 1 FROM public.billing_periods x WHERE x.id = v_p.id FOR UPDATE;
    v_id := public._billing_post_credit((SELECT x FROM public.billing_periods x WHERE x.id = v_p.id), 'fee_waiver', v_p.subscription_amount, 'Free trial extended: subscription waived', 'trialwaive:' || v_p.id,
                                        NULL, NULL, jsonb_build_object('new_trial_end', p_new_end, 'why', p_reason));
    v_ids := v_ids || v_id;
    v_total := v_total + v_p.subscription_amount;
  END LOOP;
  RETURN jsonb_build_object('new_trial_end', p_new_end, 'periods_waived', COALESCE(array_length(v_ids, 1), 0), 'waived_amount', v_total, 'ledger_entry_ids', to_jsonb(v_ids));
END;
$$;
REVOKE ALL ON FUNCTION public._billing_do_extend_trial(public.billing_subscriptions, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._billing_do_grant_orders(p_business_id UUID, p_quantity INTEGER, p_source TEXT, p_ref TEXT, p_reason TEXT, p_expires TIMESTAMPTZ)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.billing_allowance_grants(business_id, kind, quantity, source, source_ref, reason, expires_at, created_by)
  VALUES (p_business_id, 'onboarding_free_orders', p_quantity, p_source, p_ref, p_reason, p_expires, auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_do_grant_orders(UUID, INTEGER, TEXT, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._billing_do_window(p_sub_id UUID, p_starts TIMESTAMPTZ, p_ends TIMESTAMPTZ, p_overrides JSONB, p_source TEXT, p_promotion UUID, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.billing_term_windows(subscription_id, starts_at, ends_at, overrides, source, promotion_id, reason, created_by)
  VALUES (p_sub_id, p_starts, p_ends, p_overrides, p_source, p_promotion, p_reason, auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_do_window(UUID, TIMESTAMPTZ, TIMESTAMPTZ, JSONB, TEXT, UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Administrator controls. Each needs a platform administrator and a reason, and writes an audit entry (with the business) saying what changed.
-- ---------------------------------------------------------------------------
-- Extend a free trial to a later moment (an absolute date, so sending it twice does the same thing).
CREATE OR REPLACE FUNCTION public.admin_billing_extend_trial(p_business_id UUID, p_new_trial_end TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_old TIMESTAMPTZ;
  v_res JSONB;
BEGIN
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status NOT IN ('trialing', 'active') OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'A trial can only be extended for a subscription that is trialing or active.'; END IF;
  IF p_new_trial_end IS NULL OR p_new_trial_end <= now() THEN RAISE EXCEPTION 'Choose a trial end date that is still ahead.'; END IF;
  v_old := v_sub.trial_end;
  IF p_new_trial_end <= COALESCE(v_old, v_sub.billing_starts_at) THEN RAISE EXCEPTION 'The new end must be later than the current trial end (%).', COALESCE(v_old, v_sub.billing_starts_at); END IF;
  IF p_new_trial_end > v_sub.billing_starts_at + interval '730 days' THEN RAISE EXCEPTION 'A trial cannot run more than 730 days from the billing start.'; END IF;
  v_res := public._billing_do_extend_trial(v_sub, p_new_trial_end, v_reason);
  PERFORM public.write_audit_log('Billing trial extended', v_biz.name, 'billing_subscription', v_sub.id, 'Trial',
    jsonb_build_object('previous_trial_end', v_old, 'new_trial_end', p_new_trial_end, 'periods_waived', v_res -> 'periods_waived', 'waived_amount', v_res -> 'waived_amount',
                       'ledger_entry_ids', v_res -> 'ledger_entry_ids', 'reason', v_reason), _business_id => p_business_id);
  RETURN v_res || jsonb_build_object('previous_trial_end', v_old);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_extend_trial(UUID, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_extend_trial(UUID, TIMESTAMPTZ, TEXT) TO authenticated, service_role;

-- Add launch-style free orders for a wholesaler (used before any monthly allowance, in the order granted, never two for one order).
CREATE OR REPLACE FUNCTION public.admin_billing_grant_free_orders(p_business_id UUID, p_quantity INTEGER, p_expires_at TIMESTAMPTZ, p_reason TEXT, p_request_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_key TEXT := btrim(COALESCE(p_request_key, ''));
  v_old public.billing_allowance_grants%ROWTYPE;
  v_id UUID;
BEGIN
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_biz.type::TEXT <> 'wholesaler' THEN RAISE EXCEPTION 'Free orders are for wholesalers: a pharmacy pays no transaction fee.'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 10000 THEN RAISE EXCEPTION 'Grant between 1 and 10,000 free orders at a time.'; END IF;
  IF p_expires_at IS NOT NULL AND p_expires_at <= now() THEN RAISE EXCEPTION 'The expiry must be in the future.'; END IF;
  IF char_length(v_key) < 3 THEN RAISE EXCEPTION 'A request key is required, so that sending the same grant twice records it once.'; END IF;
  SELECT * INTO v_old FROM public.billing_allowance_grants g WHERE g.business_id = p_business_id AND g.source = 'admin' AND g.source_ref = v_key;
  IF FOUND THEN
    IF v_old.quantity <> p_quantity THEN RAISE EXCEPTION 'This request key was already used for a different grant.'; END IF;
    RETURN jsonb_build_object('grant_id', v_old.id, 'replayed', TRUE);
  END IF;
  v_id := public._billing_do_grant_orders(p_business_id, p_quantity, 'admin', v_key, v_reason, p_expires_at);
  PERFORM public.write_audit_log('Billing free orders granted', v_biz.name, 'billing_allowance_grant', v_id, p_quantity || ' free orders',
    jsonb_build_object('quantity', p_quantity, 'expires_at', p_expires_at, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('grant_id', v_id, 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_grant_free_orders(UUID, INTEGER, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_grant_free_orders(UUID, INTEGER, TIMESTAMPTZ, TEXT, TEXT) TO authenticated, service_role;

-- A manual credit (money off the current bill) or a promotional credit. If it is larger than the bill, the surplus carries forward to the next invoice.
CREATE OR REPLACE FUNCTION public.admin_billing_apply_credit(p_business_id UUID, p_amount NUMERIC, p_kind TEXT, p_reason TEXT, p_request_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_p public.billing_periods%ROWTYPE;
  v_amount NUMERIC := public._billing_money(p_amount);
  v_key TEXT := 'admin:' || btrim(COALESCE(p_request_key, ''));
  v_old public.billing_ledger_entries%ROWTYPE;
  v_id UUID;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('manual_credit', 'promotional_credit') THEN RAISE EXCEPTION 'Choose a manual credit or a promotional credit.'; END IF;
  IF char_length(v_key) < 8 THEN RAISE EXCEPTION 'A request key is required, so that sending the same credit twice records it once.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  SELECT * INTO v_old FROM public.billing_ledger_entries e WHERE e.idempotency_key = v_key;
  IF FOUND THEN
    IF v_old.business_id <> p_business_id OR v_old.credit_amount <> v_amount OR v_old.entry_type <> p_kind THEN RAISE EXCEPTION 'This request key was already used for a different entry.'; END IF;
    RETURN jsonb_build_object('ledger_entry_id', v_old.id, 'replayed', TRUE);
  END IF;
  v_p := public._billing_open_real_period(v_sub);
  v_id := public._billing_post_credit(v_p, p_kind, v_amount, v_reason, v_key, NULL, NULL, jsonb_build_object('period_start', v_p.period_start));
  PERFORM public.write_audit_log('Billing credit applied', v_biz.name, 'billing_ledger_entry', v_id, CASE p_kind WHEN 'manual_credit' THEN 'Manual credit' ELSE 'Promotional credit' END,
    jsonb_build_object('amount', v_amount, 'kind', p_kind, 'period_start', v_p.period_start, 'ledger_entry_id', v_id, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('ledger_entry_id', v_id, 'replayed', FALSE, 'period_start', v_p.period_start);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_apply_credit(UUID, NUMERIC, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_apply_credit(UUID, NUMERIC, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- A manual charge on the current bill (for example to correct an invoice that was too low).
CREATE OR REPLACE FUNCTION public.admin_billing_apply_charge(p_business_id UUID, p_amount NUMERIC, p_reason TEXT, p_request_key TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_p public.billing_periods%ROWTYPE;
  v_amount NUMERIC := public._billing_money(p_amount);
  v_key TEXT := 'admin:' || btrim(COALESCE(p_request_key, ''));
  v_old public.billing_ledger_entries%ROWTYPE;
  v_id UUID;
BEGIN
  IF char_length(v_key) < 8 THEN RAISE EXCEPTION 'A request key is required, so that sending the same charge twice records it once.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  SELECT * INTO v_old FROM public.billing_ledger_entries e WHERE e.idempotency_key = v_key;
  IF FOUND THEN
    IF v_old.business_id <> p_business_id OR v_old.charged_amount <> v_amount OR v_old.entry_type <> 'manual_debit' THEN RAISE EXCEPTION 'This request key was already used for a different entry.'; END IF;
    RETURN jsonb_build_object('ledger_entry_id', v_old.id, 'replayed', TRUE);
  END IF;
  v_p := public._billing_open_real_period(v_sub);
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, shadow, currency, charged_amount, reason, source, idempotency_key, metadata, created_by)
  VALUES (p_business_id, v_p.id, 'manual_debit', FALSE, v_p.currency, v_amount, v_reason, 'admin', v_key, jsonb_build_object('period_start', v_p.period_start), auth.uid()) RETURNING id INTO v_id;
  UPDATE public.billing_periods SET debits_amount = debits_amount + v_amount WHERE id = v_p.id;
  PERFORM public.write_audit_log('Billing charge applied', v_biz.name, 'billing_ledger_entry', v_id, 'Manual charge',
    jsonb_build_object('amount', v_amount, 'period_start', v_p.period_start, 'ledger_entry_id', v_id, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('ledger_entry_id', v_id, 'replayed', FALSE, 'period_start', v_p.period_start);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_apply_charge(UUID, NUMERIC, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_apply_charge(UUID, NUMERIC, TEXT, TEXT) TO authenticated, service_role;

-- Waive the transaction fee charged on ONE order: credits whatever is still charged for it (its primary fee and any later adjustments, less anything already waived).
CREATE OR REPLACE FUNCTION public.admin_billing_waive_fee(p_business_id UUID, p_order_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_p public.billing_periods%ROWTYPE;
  v_charged NUMERIC(12,2);
  v_waived NUMERIC(12,2);
  v_left NUMERIC(12,2);
  v_prim UUID;
  v_n INTEGER;
  v_id UUID;
  v_num TEXT;
BEGIN
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_biz.type::TEXT <> 'wholesaler' THEN RAISE EXCEPTION 'Only a wholesaler is charged a transaction fee.'; END IF;
  SELECT o.order_number INTO v_num FROM public.orders o WHERE o.id = p_order_id AND o.wholesaler_id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That order does not belong to this business.'; END IF;
  SELECT a.id INTO v_prim FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND a.kind = 'primary' AND NOT a.shadow;
  IF NOT FOUND THEN RAISE EXCEPTION 'This order has no real billing assessment, so no fee was charged for it.'; END IF;
  SELECT COALESCE(sum(a.charged_amount), 0) INTO v_charged FROM public.order_billing_assessments a WHERE a.order_id = p_order_id AND NOT a.shadow;
  SELECT COALESCE(sum(e.credit_amount), 0), count(*) INTO v_waived, v_n FROM public.billing_ledger_entries e WHERE e.order_id = p_order_id AND e.entry_type = 'fee_waiver' AND NOT e.shadow;
  v_left := v_charged - v_waived;
  IF v_left <= 0 THEN RAISE EXCEPTION 'There is no fee left to waive on this order.'; END IF;
  v_p := public._billing_open_real_period(v_sub);
  v_id := public._billing_post_credit(v_p, 'fee_waiver', v_left, v_reason, 'waive:' || p_order_id || ':' || (v_n + 1), p_order_id, v_prim, jsonb_build_object('order_number', v_num, 'fee_charged', v_charged, 'already_waived', v_waived));
  PERFORM public.write_audit_log('Billing fee waived', v_biz.name, 'billing_ledger_entry', v_id, v_num,
    jsonb_build_object('order_id', p_order_id, 'order_number', v_num, 'amount', v_left, 'period_start', v_p.period_start, 'ledger_entry_id', v_id, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('ledger_entry_id', v_id, 'amount', v_left, 'order_number', v_num);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_waive_fee(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_waive_fee(UUID, UUID, TEXT) TO authenticated, service_role;

-- Exempt a wholesaler from transaction fees from now on (or take the exemption away). Orders delivered while exempt are recorded as exempt.
CREATE OR REPLACE FUNCTION public.admin_billing_set_exemption(p_business_id UUID, p_exempt BOOLEAN, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
BEGIN
  IF p_exempt IS NULL THEN RAISE EXCEPTION 'Choose whether the business is exempt.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_biz.type::TEXT <> 'wholesaler' THEN RAISE EXCEPTION 'Only a wholesaler is charged a transaction fee, so only a wholesaler can be exempt.'; END IF;
  IF v_sub.exempt_from_transaction_fees = p_exempt THEN RAISE EXCEPTION '%', CASE WHEN p_exempt THEN 'This business is already exempt.' ELSE 'This business is not exempt.' END; END IF;
  UPDATE public.billing_subscriptions SET exempt_from_transaction_fees = p_exempt, exempt_reason = CASE WHEN p_exempt THEN v_reason END WHERE id = v_sub.id;
  PERFORM public.write_audit_log(CASE WHEN p_exempt THEN 'Billing exemption enabled' ELSE 'Billing exemption removed' END, v_biz.name, 'billing_subscription', v_sub.id, 'Fee exemption',
    jsonb_build_object('exempt', p_exempt, 'previous_reason', v_sub.exempt_reason, 'reason', v_reason), _business_id => p_business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_exemption(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_exemption(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

-- Pause billing for a business (no assessments, and the subscription charge is waived for periods that open meanwhile) or resume it.
CREATE OR REPLACE FUNCTION public.admin_billing_set_paused(p_business_id UUID, p_paused BOOLEAN, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
BEGIN
  IF p_paused IS NULL THEN RAISE EXCEPTION 'Choose whether billing is paused.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  IF v_sub.billing_paused = p_paused THEN RAISE EXCEPTION '%', CASE WHEN p_paused THEN 'Billing is already paused for this business.' ELSE 'Billing is not paused for this business.' END; END IF;
  UPDATE public.billing_subscriptions SET billing_paused = p_paused, paused_at = CASE WHEN p_paused THEN now() END, paused_reason = CASE WHEN p_paused THEN v_reason END WHERE id = v_sub.id;
  PERFORM public.write_audit_log(CASE WHEN p_paused THEN 'Billing paused' ELSE 'Billing resumed' END, v_biz.name, 'billing_subscription', v_sub.id, 'Billing pause',
    jsonb_build_object('paused', p_paused, 'reason', v_reason), _business_id => p_business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_paused(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_paused(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.admin_billing_set_cancellation(UUID, BOOLEAN, TEXT);
-- End the subscription at the end of the current billing period (the end is fixed at once, so it does not depend on when the scheduled run next looks), or take that back before it happens.
CREATE OR REPLACE FUNCTION public.admin_billing_set_cancellation(p_business_id UUID, p_cancel BOOLEAN, p_reason TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  b RECORD;
  v_end TIMESTAMPTZ;
BEGIN
  IF p_cancel IS NULL THEN RAISE EXCEPTION 'Choose whether to cancel.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= clock_timestamp()) THEN RAISE EXCEPTION 'This subscription has already ended.'; END IF;
  IF v_sub.cancel_at_period_end = p_cancel THEN RAISE EXCEPTION '%', CASE WHEN p_cancel THEN 'This subscription is already set to end at the end of the period.' ELSE 'This subscription is not set to end.' END; END IF;
  IF p_cancel THEN
    SELECT * INTO b FROM public.billing_period_bounds(v_sub.period_anchor_at, COALESCE((public.billing_resolve_terms(p_business_id, GREATEST(clock_timestamp(), v_sub.billing_starts_at)) ->> 'billing_interval_months')::INTEGER, 1), GREATEST(clock_timestamp(), v_sub.period_anchor_at));
    v_end := b.period_end;
    UPDATE public.billing_subscriptions SET cancel_at_period_end = TRUE, ended_at = v_end, cancelled_at = clock_timestamp() WHERE id = v_sub.id;
  ELSE
    UPDATE public.billing_subscriptions SET cancel_at_period_end = FALSE, ended_at = NULL, cancelled_at = NULL WHERE id = v_sub.id;
  END IF;
  PERFORM public.write_audit_log(CASE WHEN p_cancel THEN 'Billing cancellation scheduled' ELSE 'Billing cancellation withdrawn' END, v_biz.name, 'billing_subscription', v_sub.id, 'Cancellation',
    jsonb_build_object('cancel_at_period_end', p_cancel, 'ends_at', v_end, 'reason', v_reason), _business_id => p_business_id);
  RETURN v_end;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_cancellation(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_cancellation(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

-- Custom pricing: the FULL set of overrides on top of the plan, from a moment (now, or later). History is kept: orders already assessed keep the terms they were assessed under.
CREATE OR REPLACE FUNCTION public.admin_billing_set_custom_terms(p_business_id UUID, p_overrides JSONB, p_effective_from TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_from TIMESTAMPTZ := COALESCE(p_effective_from, clock_timestamp());
  v_cur public.billing_subscription_terms%ROWTYPE;
  v_id UUID;
BEGIN
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'object' THEN RAISE EXCEPTION 'The price overrides must be an object (empty to go back to the plan).'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  IF v_from < now() - interval '1 minute' THEN RAISE EXCEPTION 'New terms cannot start in the past: orders already assessed keep the terms they were assessed under.'; END IF;
  IF v_from > now() + interval '365 days' THEN RAISE EXCEPTION 'New terms cannot start more than a year ahead.'; END IF;
  PERFORM public.billing_validate_overrides(p_overrides, FALSE);
  IF v_biz.type::TEXT = 'pharmacy' AND EXISTS (SELECT 1 FROM jsonb_object_keys(p_overrides) k WHERE k <> 'subscription_amount') THEN RAISE EXCEPTION 'A pharmacy pays no transaction fee: only its subscription amount can be overridden.'; END IF;
  SELECT * INTO v_cur FROM public.billing_subscription_terms t WHERE t.subscription_id = v_sub.id AND t.effective_from <= v_from ORDER BY t.effective_from DESC LIMIT 1;
  IF v_cur.overrides = p_overrides AND v_cur.effective_from <= clock_timestamp() THEN RAISE EXCEPTION 'These are already the terms in force.'; END IF;
  BEGIN
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason, created_by)
    VALUES (v_sub.id, v_from, v_cur.plan_version_id, p_overrides, v_reason, auth.uid()) RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Terms already start at that exact moment. Choose another moment.';
  END;
  PERFORM public.write_audit_log('Billing custom pricing set', v_biz.name, 'billing_subscription_terms', v_id, 'Custom pricing',
    jsonb_build_object('effective_from', v_from, 'previous_overrides', v_cur.overrides, 'new_overrides', p_overrides, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('terms_id', v_id, 'effective_from', v_from);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_custom_terms(UUID, JSONB, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_custom_terms(UUID, JSONB, TIMESTAMPTZ, TEXT) TO authenticated, service_role;

-- Move a business to another plan (or to the newest version of its own plan). By default from the start of its next billing period, so a bill already running is not re-priced.
CREATE OR REPLACE FUNCTION public.admin_billing_change_plan(p_business_id UUID, p_plan_code TEXT, p_effective_from TIMESTAMPTZ, p_keep_overrides BOOLEAN, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  SELECT * INTO v_ver FROM public.billing_plan_versions WHERE plan_id = v_plan.id AND status = 'published' ORDER BY version DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'That plan has no published version.'; END IF;
  IF p_effective_from IS NULL THEN
    SELECT * INTO b FROM public.billing_period_bounds(v_sub.period_anchor_at, COALESCE((public.billing_resolve_terms(p_business_id, GREATEST(now(), v_sub.billing_starts_at)) ->> 'billing_interval_months')::INTEGER, 1), GREATEST(now(), v_sub.period_anchor_at));
    v_from := b.period_end;
  ELSE
    v_from := p_effective_from;
  END IF;
  IF v_from < now() - interval '1 minute' THEN RAISE EXCEPTION 'A plan change cannot start in the past.'; END IF;
  IF v_from > now() + interval '365 days' THEN RAISE EXCEPTION 'A plan change cannot start more than a year ahead.'; END IF;
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
$$;
REVOKE ALL ON FUNCTION public.admin_billing_change_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_change_plan(UUID, TEXT, TIMESTAMPTZ, BOOLEAN, TEXT) TO authenticated, service_role;

-- A temporary change to the terms: it applies between two moments and then simply stops (a discount, a lower fee, a fee waiver for a while).
CREATE OR REPLACE FUNCTION public.admin_billing_add_temporary_terms(p_business_id UUID, p_overrides JSONB, p_starts_at TIMESTAMPTZ, p_ends_at TIMESTAMPTZ, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_from TIMESTAMPTZ := COALESCE(p_starts_at, clock_timestamp());
  v_id UUID;
BEGIN
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'object' OR p_overrides = '{}'::JSONB THEN RAISE EXCEPTION 'Say what changes for the period (for example a lower fee percentage).'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  IF p_ends_at IS NULL OR p_ends_at <= v_from THEN RAISE EXCEPTION 'The end must be after the start.'; END IF;
  IF v_from < now() - interval '1 minute' THEN RAISE EXCEPTION 'A temporary change cannot start in the past: orders already assessed keep the terms they were assessed under.'; END IF;
  IF p_ends_at > v_from + interval '3 years' THEN RAISE EXCEPTION 'A temporary change can last at most three years.'; END IF;
  PERFORM public.billing_validate_overrides(p_overrides, TRUE);
  IF v_biz.type::TEXT = 'pharmacy' AND EXISTS (SELECT 1 FROM jsonb_object_keys(p_overrides) k WHERE k <> 'subscription_amount') THEN RAISE EXCEPTION 'A pharmacy pays no transaction fee: only its subscription amount can be changed.'; END IF;
  v_id := public._billing_do_window(v_sub.id, v_from, p_ends_at, p_overrides, 'admin', NULL, v_reason);
  PERFORM public.write_audit_log('Billing temporary terms added', v_biz.name, 'billing_term_window', v_id, 'Temporary terms',
    jsonb_build_object('overrides', p_overrides, 'starts_at', v_from, 'ends_at', p_ends_at, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('window_id', v_id, 'starts_at', v_from, 'ends_at', p_ends_at);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_add_temporary_terms(UUID, JSONB, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_add_temporary_terms(UUID, JSONB, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_end_temporary_terms(p_window_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_w public.billing_term_windows%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_sub public.billing_subscriptions%ROWTYPE;
BEGIN
  SELECT * INTO v_w FROM public.billing_term_windows w WHERE w.id = p_window_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'That temporary change was not found.'; END IF;
  SELECT s.* INTO v_sub FROM public.billing_subscriptions s WHERE s.id = v_w.subscription_id;
  v_sub := public._billing_lock_subscription(v_sub.business_id);
  SELECT * INTO v_w FROM public.billing_term_windows w WHERE w.id = p_window_id;
  IF v_w.ends_at <= now() OR v_w.ended_early_at IS NOT NULL THEN RAISE EXCEPTION 'That temporary change has already ended.'; END IF;
  SELECT * INTO v_biz FROM public.businesses WHERE id = v_sub.business_id;
  UPDATE public.billing_term_windows SET ends_at = GREATEST(clock_timestamp(), starts_at + interval '1 millisecond'), ended_early_at = clock_timestamp() WHERE id = p_window_id;
  PERFORM public.write_audit_log('Billing temporary terms ended', v_biz.name, 'billing_term_window', p_window_id, 'Temporary terms',
    jsonb_build_object('overrides', v_w.overrides, 'was_ending', v_w.ends_at, 'reason', v_reason), _business_id => v_sub.business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_end_temporary_terms(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_end_temporary_terms(UUID, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Promotions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_create_promotion(
  p_code TEXT, p_name TEXT, p_description TEXT, p_business_type TEXT, p_benefits JSONB, p_valid_from TIMESTAMPTZ, p_valid_until TIMESTAMPTZ, p_max_redemptions INTEGER, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_code TEXT := upper(btrim(COALESCE(p_code, '')));
  v_id UUID;
BEGIN
  IF p_business_type IS NULL OR p_business_type NOT IN ('pharmacy', 'wholesaler') THEN RAISE EXCEPTION 'Choose whether the promotion is for pharmacies or wholesalers.'; END IF;
  IF p_benefits IS NULL OR jsonb_typeof(p_benefits) <> 'object' THEN RAISE EXCEPTION 'The benefits must be an object.'; END IF;
  IF v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,39}$' THEN RAISE EXCEPTION 'The code must be 3 to 40 letters, digits, dashes or underscores.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_promotions WHERE code = v_code) THEN RAISE EXCEPTION 'A promotion with this code already exists.'; END IF;
  INSERT INTO public.billing_promotions(code, name, description, business_type, benefits, valid_from, valid_until, max_redemptions, reason, created_by)
  VALUES (v_code, btrim(COALESCE(p_name, '')), NULLIF(btrim(COALESCE(p_description, '')), ''), p_business_type::public.business_type, p_benefits, COALESCE(p_valid_from, now()), p_valid_until, p_max_redemptions, v_reason, auth.uid())
  RETURNING id INTO v_id;
  PERFORM public.write_audit_log('Billing promotion created', 'DrugXOne', 'billing_promotion', v_id, v_code,
    jsonb_build_object('code', v_code, 'business_type', p_business_type, 'benefits', p_benefits, 'valid_until', p_valid_until, 'max_redemptions', p_max_redemptions, 'reason', v_reason));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_create_promotion(TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_create_promotion(TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_set_promotion_active(p_promotion_id UUID, p_active BOOLEAN, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_p public.billing_promotions%ROWTYPE;
BEGIN
  IF p_active IS NULL THEN RAISE EXCEPTION 'Choose whether the promotion is on.'; END IF;
  SELECT * INTO v_p FROM public.billing_promotions WHERE id = p_promotion_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Promotion not found.'; END IF;
  IF v_p.active = p_active THEN RAISE EXCEPTION '%', CASE WHEN p_active THEN 'This promotion is already on.' ELSE 'This promotion is already off.' END; END IF;
  UPDATE public.billing_promotions SET active = p_active WHERE id = p_promotion_id;
  PERFORM public.write_audit_log(CASE WHEN p_active THEN 'Billing promotion switched on' ELSE 'Billing promotion switched off' END, 'DrugXOne', 'billing_promotion', p_promotion_id, v_p.code,
    jsonb_build_object('code', v_p.code, 'active', p_active, 'reason', v_reason));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_promotion_active(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_promotion_active(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

-- Gives a business a promotion's benefits, once. The promotion's row is locked first, so the last place under a limit cannot be taken twice at the same moment.
CREATE OR REPLACE FUNCTION public.admin_billing_apply_promotion(p_business_id UUID, p_code TEXT, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_promo public.billing_promotions%ROWTYPE;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_biz public.businesses%ROWTYPE;
  v_keys RECORD;
  v_ben JSONB;
  v_applied JSONB := '{}'::JSONB;
  v_end TIMESTAMPTZ;
  v_amount NUMERIC;
  v_disc NUMERIC;
  v_trial JSONB;
  v_id UUID;
  v_win UUID;
  v_red UUID;
BEGIN
  SELECT * INTO v_promo FROM public.billing_promotions WHERE code = upper(btrim(COALESCE(p_code, ''))) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No promotion has that code.'; END IF;
  v_sub := public._billing_lock_subscription(p_business_id);
  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF NOT v_promo.active THEN RAISE EXCEPTION 'This promotion is switched off.'; END IF;
  IF v_promo.valid_from > now() THEN RAISE EXCEPTION 'This promotion has not started yet.'; END IF;
  IF v_promo.valid_until IS NOT NULL AND v_promo.valid_until <= now() THEN RAISE EXCEPTION 'This promotion has ended.'; END IF;
  IF v_promo.business_type <> v_biz.type THEN RAISE EXCEPTION 'This promotion is for % businesses only.', v_promo.business_type; END IF;
  IF v_sub.status = 'cancelled' OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RAISE EXCEPTION 'This subscription has ended.'; END IF;
  SELECT * INTO v_keys FROM public.billing_onboarding_keys(p_business_id);
  IF EXISTS (SELECT 1 FROM public.billing_promotion_redemptions r WHERE r.promotion_id = v_promo.id AND r.business_id = p_business_id) THEN RAISE EXCEPTION 'This business has already received this promotion.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_promotion_redemptions r WHERE r.promotion_id = v_promo.id AND ((v_keys.licence_key IS NOT NULL AND r.licence_key = v_keys.licence_key) OR r.owner_key = v_keys.owner_key)) THEN
    RAISE EXCEPTION 'Another account with the same licence number or owner has already received this promotion.';
  END IF;
  IF v_promo.max_redemptions IS NOT NULL AND (SELECT count(*) FROM public.billing_promotion_redemptions r WHERE r.promotion_id = v_promo.id) >= v_promo.max_redemptions THEN
    RAISE EXCEPTION 'This promotion has reached its limit of % businesses.', v_promo.max_redemptions;
  END IF;
  v_ben := v_promo.benefits;

  IF v_ben ? 'free_trial_days' THEN
    v_end := GREATEST(COALESCE(v_sub.trial_end, v_sub.billing_starts_at), now()) + make_interval(days => (v_ben ->> 'free_trial_days')::INTEGER);
    IF v_sub.status NOT IN ('trialing', 'active') THEN RAISE EXCEPTION 'A trial can only be extended for a subscription that is trialing or active.'; END IF;
    v_trial := public._billing_do_extend_trial(v_sub, v_end, 'Promotion ' || v_promo.code);
    v_applied := v_applied || jsonb_build_object('free_trial_days', jsonb_build_object('days', (v_ben ->> 'free_trial_days')::INTEGER, 'new_trial_end', v_end, 'periods_waived', v_trial -> 'periods_waived', 'waived_amount', v_trial -> 'waived_amount', 'ledger_entry_ids', v_trial -> 'ledger_entry_ids'));
  END IF;
  IF v_ben ? 'free_orders' THEN
    v_id := public._billing_do_grant_orders(p_business_id, (v_ben ->> 'free_orders')::INTEGER, 'promotion', v_promo.code, 'Promotion ' || v_promo.code, NULL);
    v_applied := v_applied || jsonb_build_object('free_orders', jsonb_build_object('quantity', (v_ben ->> 'free_orders')::INTEGER, 'grant_id', v_id));
  END IF;
  IF v_ben ? 'subscription_discount_percent' THEN
    v_amount := (public.billing_resolve_terms(p_business_id, GREATEST(now(), v_sub.billing_starts_at)) ->> 'subscription_amount')::NUMERIC;
    v_disc := round(v_amount * (1 - (v_ben ->> 'subscription_discount_percent')::NUMERIC / 100), 2);
    v_win := public._billing_do_window(v_sub.id, clock_timestamp(), now() + make_interval(days => (v_ben ->> 'discount_days')::INTEGER), jsonb_build_object('subscription_amount', v_disc), 'promotion', v_promo.id, 'Promotion ' || v_promo.code);
    v_applied := v_applied || jsonb_build_object('subscription_discount', jsonb_build_object('percent', (v_ben ->> 'subscription_discount_percent')::NUMERIC, 'days', (v_ben ->> 'discount_days')::INTEGER, 'from_amount', v_amount, 'to_amount', v_disc, 'window_id', v_win));
  END IF;
  IF v_ben ? 'fee_percentage' THEN
    v_win := public._billing_do_window(v_sub.id, clock_timestamp(), now() + make_interval(days => (v_ben ->> 'fee_days')::INTEGER), jsonb_build_object('transaction_fee_percentage', (v_ben ->> 'fee_percentage')::NUMERIC), 'promotion', v_promo.id, 'Promotion ' || v_promo.code);
    v_applied := v_applied || jsonb_build_object('lower_fee', jsonb_build_object('percentage', (v_ben ->> 'fee_percentage')::NUMERIC, 'days', (v_ben ->> 'fee_days')::INTEGER, 'window_id', v_win));
  END IF;
  IF v_ben ? 'fee_waiver_days' THEN
    v_win := public._billing_do_window(v_sub.id, clock_timestamp(), now() + make_interval(days => (v_ben ->> 'fee_waiver_days')::INTEGER), jsonb_build_object('exempt_from_transaction_fees', TRUE), 'promotion', v_promo.id, 'Promotion ' || v_promo.code);
    v_applied := v_applied || jsonb_build_object('fee_waiver', jsonb_build_object('days', (v_ben ->> 'fee_waiver_days')::INTEGER, 'window_id', v_win));
  END IF;

  INSERT INTO public.billing_promotion_redemptions(promotion_id, business_id, applied, reason, licence_key, owner_key, redeemed_by)
  VALUES (v_promo.id, p_business_id, v_applied, v_reason, v_keys.licence_key, v_keys.owner_key, auth.uid()) RETURNING id INTO v_red;
  PERFORM public.write_audit_log('Billing promotion applied', v_biz.name, 'billing_promotion', v_promo.id, v_promo.code,
    jsonb_build_object('code', v_promo.code, 'applied', v_applied, 'redemption_id', v_red, 'reason', v_reason), _business_id => p_business_id);
  RETURN jsonb_build_object('redemption_id', v_red, 'applied', v_applied);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_apply_promotion(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_apply_promotion(UUID, TEXT, TEXT) TO authenticated, service_role;

-- The promotions with how many businesses have had each (for the administrator's list).
CREATE OR REPLACE FUNCTION public.admin_billing_promotions()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._billing_admin_only();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'name', p.name, 'description', p.description, 'business_type', p.business_type, 'benefits', p.benefits, 'valid_from', p.valid_from,
            'valid_until', p.valid_until, 'max_redemptions', p.max_redemptions, 'active', p.active, 'created_at', p.created_at, 'reason', p.reason,
            'redeemed', (SELECT count(*) FROM public.billing_promotion_redemptions r WHERE r.promotion_id = p.id),
            'status', CASE WHEN NOT p.active THEN 'off' WHEN p.valid_from > now() THEN 'not_started' WHEN p.valid_until IS NOT NULL AND p.valid_until <= now() THEN 'ended'
                           WHEN p.max_redemptions IS NOT NULL AND (SELECT count(*) FROM public.billing_promotion_redemptions r WHERE r.promotion_id = p.id) >= p.max_redemptions THEN 'full' ELSE 'running' END)
            ORDER BY p.created_at DESC) FROM public.billing_promotions p), '[]'::JSONB);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_promotions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_promotions() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Reconciliation of the controls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_reconcile_controls()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 'period_debits_differ_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.debits_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.debits_amount, COALESCE((SELECT sum(e.charged_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id AND e.entry_type = 'manual_debit'), 0) l, row_number() OVER () rn
        FROM public.billing_periods p) m WHERE m.debits_amount <> m.l;
  RETURN QUERY
  SELECT 'fee_waived_more_than_charged'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', m.order_id, 'charged', m.charged, 'waived', m.waived)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT w.order_id, w.waived, COALESCE((SELECT sum(a.charged_amount) FROM public.order_billing_assessments a WHERE a.order_id = w.order_id AND NOT a.shadow), 0) charged, row_number() OVER () rn
        FROM (SELECT e.order_id, sum(e.credit_amount) waived FROM public.billing_ledger_entries e WHERE e.entry_type = 'fee_waiver' AND e.order_id IS NOT NULL AND NOT e.shadow GROUP BY e.order_id) w) m
  WHERE m.waived > m.charged;
  RETURN QUERY
  SELECT 'promotion_redeemed_beyond_its_limit'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('code', m.code, 'limit', m.max_redemptions, 'redeemed', m.n)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.code, p.max_redemptions, (SELECT count(*) FROM public.billing_promotion_redemptions r WHERE r.promotion_id = p.id) n, row_number() OVER () rn FROM public.billing_promotions p WHERE p.max_redemptions IS NOT NULL) m
  WHERE m.n > m.max_redemptions;
  RETURN QUERY
  SELECT 'admin_ledger_entry_without_audit'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('entry_id', m.id, 'entry_type', m.entry_type)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT e.id, e.entry_type, row_number() OVER () rn FROM public.billing_ledger_entries e
        WHERE e.source = 'admin' AND NOT EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.business_id = e.business_id AND a.activity LIKE 'Billing%' AND a.details::TEXT LIKE '%' || e.id::TEXT || '%')) m;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_reconcile_controls() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_reconcile_controls() TO service_role;

CREATE OR REPLACE FUNCTION public.billing_reconcile()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public._billing_reconcile_engine() UNION ALL SELECT * FROM public._billing_reconcile_invoices() UNION ALL SELECT * FROM public._billing_reconcile_controls()
$$;

-- ---------------------------------------------------------------------------
-- 6. The administrator's detail now shows temporary terms, promotions and the order of each assessment
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
    'assessments', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.assessed_at DESC) FROM (SELECT o.order_number, a.order_id, a.assessed_at, a.delivered_at, a.kind, a.adjustment_seq, a.billable_gmv, a.outcome, a.free_source, a.free_seq,
                          a.percentage, a.calculated_fee, a.fee_after_limits, a.cap_adjustment, a.charged_amount, a.rule_version
                          FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id = p_business_id AND a.shadow = v_shadow ORDER BY a.assessed_at DESC LIMIT 50) x), '[]'::JSONB),
    'ledger', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT e.created_at, e.entry_type, e.gross_amount, e.percentage, e.calculated_fee, e.charged_amount, e.credit_amount, e.reason, e.source
                          FROM public.billing_ledger_entries e WHERE e.business_id = p_business_id AND e.shadow = v_shadow ORDER BY e.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'audit', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT l.created_at, l.activity, l.performed_by_email, l.details
                          FROM public.audit_logs l WHERE l.business_id = p_business_id AND (l.activity LIKE 'Billing%' OR l.activity LIKE 'Order billing%') ORDER BY l.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'invoices', CASE WHEN v_shadow THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.issued_at DESC) FROM (
                          SELECT i.id, i.invoice_number, i.period_start, i.period_end, i.issued_at, i.due_at, i.total_amount, i.amount_paid, i.outstanding_amount, i.status
                          FROM public.billing_invoices i WHERE i.business_id = p_business_id ORDER BY i.issued_at DESC LIMIT 24) x), '[]'::JSONB) END,
    'payments', CASE WHEN v_shadow THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.recorded_at DESC) FROM (
                          SELECT y.id, i.invoice_number, y.kind, y.amount, y.method, y.reference, y.received_at, y.recorded_at, y.reason
                          FROM public.billing_payments y JOIN public.billing_invoices i ON i.id = y.invoice_id WHERE y.business_id = p_business_id ORDER BY y.recorded_at DESC LIMIT 50) x), '[]'::JSONB) END,
    'credit_available', GREATEST(public._billing_available_credit(p_business_id), 0),
    'windows', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', w.id, 'starts_at', w.starts_at, 'ends_at', w.ends_at, 'overrides', w.overrides, 'source', w.source, 'promotion_code', pr.code, 'reason', w.reason,
                          'ended_early_at', w.ended_early_at, 'running', w.starts_at <= now() AND now() < w.ends_at) ORDER BY w.starts_at DESC)
                        FROM public.billing_term_windows w LEFT JOIN public.billing_promotions pr ON pr.id = w.promotion_id WHERE w.subscription_id = v_sub.id), '[]'::JSONB),
    'promotions', COALESCE((SELECT jsonb_agg(jsonb_build_object('code', pr.code, 'name', pr.name, 'redeemed_at', r.redeemed_at, 'applied', r.applied, 'reason', r.reason) ORDER BY r.redeemed_at DESC)
                            FROM public.billing_promotion_redemptions r JOIN public.billing_promotions pr ON pr.id = r.promotion_id WHERE r.business_id = p_business_id), '[]'::JSONB),
    'queue', COALESCE((SELECT jsonb_agg(jsonb_build_object('order_id', q.order_id, 'kind', q.kind, 'status', q.status, 'attempts', q.attempts, 'error', q.last_error))
                       FROM public.billing_engine_queue q JOIN public.orders o ON o.id = q.order_id WHERE o.wholesaler_id = p_business_id AND q.status <> 'done'), '[]'::JSONB));
END;
$$;
