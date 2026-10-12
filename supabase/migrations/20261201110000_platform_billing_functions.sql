-- Platform billing, Phase 1 part 2: the configuration FUNCTIONS and the seed. Still no charging: there is no engine, 'active' mode cannot be switched on yet, and nothing writes ledger entries.
--
--   Pure helpers (no data changed)
--     billing_period_bounds()      the rolling monthly period containing a moment, anchored on a business's own start date (no drift at month ends, leap years handled).
--     billing_onboarding_keys()    the licence and owner keys that make the launch free-order grant once-only.
--     billing_resolve_terms()      the terms a business is billed under at a moment: its pinned plan version with any explicit overrides applied.
--     billing_effective_mode()     disabled / shadow / active for one business: the platform setting, held back (never pushed ahead) by the business's own setting, pause or end.
--     billing_feature_enabled() / billing_limit()   plan entitlements for later wiring. They NEVER restrict anything unless billing is active for that business.
--   Administrator operations (each requires a platform administrator, a stated reason, and writes an audit entry with the previous and new values)
--     admin_billing_set_mode, admin_billing_create_plan, admin_billing_publish_plan_version, admin_billing_set_plan_availability,
--     admin_billing_start_subscription, admin_billing_set_subscription_mode.

-- ---------------------------------------------------------------------------
-- 1. Pure helpers
-- ---------------------------------------------------------------------------
-- The period [start, end) that contains p_at, for a business whose periods roll every p_interval_months from p_anchor. Each boundary is computed from the ANCHOR
-- (anchor + n intervals), never from the previous boundary, so an anchor on the 31st gives Feb 28/29, Mar 31, Apr 30 ... without drifting. Arithmetic is done in the billing timezone.
CREATE OR REPLACE FUNCTION public.billing_period_bounds(p_anchor TIMESTAMPTZ, p_interval_months INTEGER, p_at TIMESTAMPTZ, p_tz TEXT DEFAULT NULL)
RETURNS TABLE (period_index INTEGER, period_start TIMESTAMPTZ, period_end TIMESTAMPTZ)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_tz TEXT := COALESCE(p_tz, (SELECT s.timezone FROM public.billing_settings s WHERE s.id), 'UTC');
  v_a TIMESTAMP;
  v_x TIMESTAMP;
  v_k INTEGER;
BEGIN
  IF p_anchor IS NULL OR p_at IS NULL OR p_interval_months IS NULL OR p_interval_months < 1 THEN RAISE EXCEPTION 'An anchor date, a moment and a period length are required.'; END IF;
  IF p_at < p_anchor THEN RAISE EXCEPTION 'That moment is before billing starts.'; END IF;
  v_a := p_anchor AT TIME ZONE v_tz;
  v_x := p_at AT TIME ZONE v_tz;
  v_k := GREATEST(((EXTRACT(YEAR FROM v_x) - EXTRACT(YEAR FROM v_a)) * 12 + (EXTRACT(MONTH FROM v_x) - EXTRACT(MONTH FROM v_a)))::INTEGER / p_interval_months - 1, 0);
  WHILE v_a + make_interval(months => (v_k + 1) * p_interval_months) <= v_x LOOP v_k := v_k + 1; END LOOP;
  WHILE v_k > 0 AND v_a + make_interval(months => v_k * p_interval_months) > v_x LOOP v_k := v_k - 1; END LOOP;
  period_index := v_k;
  period_start := (v_a + make_interval(months => v_k * p_interval_months)) AT TIME ZONE v_tz;
  period_end := (v_a + make_interval(months => (v_k + 1) * p_interval_months)) AT TIME ZONE v_tz;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_period_bounds(TIMESTAMPTZ, INTEGER, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_period_bounds(TIMESTAMPTZ, INTEGER, TIMESTAMPTZ, TEXT) TO service_role;

-- The keys behind the once-only launch grant: the licence number (spaces and case ignored; none when blank) and the owner.
CREATE OR REPLACE FUNCTION public.billing_onboarding_keys(p_business_id UUID)
RETURNS TABLE (licence_key TEXT, owner_key UUID)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NULLIF(lower(regexp_replace(COALESCE(b.license_number, ''), '\s+', '', 'g')), ''), b.owner_id FROM public.businesses b WHERE b.id = p_business_id
$$;
REVOKE ALL ON FUNCTION public.billing_onboarding_keys(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_onboarding_keys(UUID) TO service_role;

-- The terms in force for a business at a moment (NULL when it has no subscription or none had started yet): the pinned plan version's values, then any overrides on top.
-- An override whose value is JSON null means "no limit" for the optional limits; a key that is absent means "as the plan says".
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
  RETURN v_base || v_terms.overrides;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_resolve_terms(UUID, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_resolve_terms(UUID, TIMESTAMPTZ) TO service_role;

-- disabled < shadow < active. The platform setting is the ceiling: a business can be held back below it (or follow it) but is never ahead of it. Paused or ended: disabled.
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
  SELECT s.billing_mode, s.billing_paused, s.ended_at INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND OR COALESCE(v_platform, 'disabled') = 'disabled' OR v_sub.billing_paused OR (v_sub.ended_at IS NOT NULL AND v_sub.ended_at <= now()) THEN RETURN 'disabled'; END IF;
  v_rank := CASE v_platform WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END;
  v_org_rank := CASE COALESCE(v_sub.billing_mode, v_platform) WHEN 'active' THEN 2 WHEN 'shadow' THEN 1 ELSE 0 END;
  RETURN CASE LEAST(v_rank, v_org_rank) WHEN 2 THEN 'active' WHEN 1 THEN 'shadow' ELSE 'disabled' END;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_effective_mode(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_effective_mode(UUID) TO service_role;

-- Entitlements for later wiring (Phase 6). Whoever can act for the business may ask. While billing is not ACTIVE for the business (disabled or shadow) nothing is restricted:
-- every feature is enabled and every limit is empty (unlimited), so wiring these in can never lock anyone out before billing is switched on.
CREATE OR REPLACE FUNCTION public._billing_may_ask(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND (public.has_role(auth.uid(), 'admin') OR EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id))
$$;
REVOKE ALL ON FUNCTION public._billing_may_ask(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.billing_feature_enabled(p_business_id UUID, p_key TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_terms JSONB;
BEGIN
  IF NOT public._billing_may_ask(p_business_id) THEN RAISE EXCEPTION 'You do not have permission to ask about this business.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.billing_feature_catalog c WHERE c.key = p_key AND c.value_type = 'boolean') THEN RAISE EXCEPTION 'Unknown plan feature "%".', p_key; END IF;
  IF public.billing_effective_mode(p_business_id) <> 'active' THEN RETURN TRUE; END IF;
  v_terms := public.billing_resolve_terms(p_business_id, now());
  IF v_terms IS NULL THEN RETURN TRUE; END IF;
  RETURN COALESCE((v_terms -> 'entitlements' ->> p_key)::BOOLEAN, FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_feature_enabled(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_feature_enabled(UUID, TEXT) TO authenticated, service_role;

-- A numeric limit from the plan ('max_users', 'max_branches', or an integer feature); NULL means unlimited (and is what is returned while billing is not active).
CREATE OR REPLACE FUNCTION public.billing_limit(p_business_id UUID, p_key TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_terms JSONB;
BEGIN
  IF NOT public._billing_may_ask(p_business_id) THEN RAISE EXCEPTION 'You do not have permission to ask about this business.'; END IF;
  IF p_key NOT IN ('max_users', 'max_branches') AND NOT EXISTS (SELECT 1 FROM public.billing_feature_catalog c WHERE c.key = p_key AND c.value_type = 'integer') THEN
    RAISE EXCEPTION 'Unknown plan limit "%".', p_key;
  END IF;
  IF public.billing_effective_mode(p_business_id) <> 'active' THEN RETURN NULL; END IF;
  v_terms := public.billing_resolve_terms(p_business_id, now());
  IF v_terms IS NULL THEN RETURN NULL; END IF;
  IF p_key IN ('max_users', 'max_branches') THEN RETURN (v_terms ->> p_key)::INTEGER; END IF;
  RETURN (v_terms -> 'entitlements' ->> p_key)::INTEGER;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_limit(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_limit(UUID, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Administrator operations
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_admin_reason(p_reason TEXT)
RETURNS TEXT
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  IF char_length(v_reason) < 5 THEN RAISE EXCEPTION 'A reason of at least 5 characters is required for every billing change.'; END IF;
  IF char_length(v_reason) > 500 THEN RAISE EXCEPTION 'The reason is too long (500 characters maximum).'; END IF;
  RETURN v_reason;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_admin_reason(TEXT) FROM PUBLIC, anon, authenticated;

-- The platform-wide mode. 'active' (real charging) is refused until the engine, invoicing and rollout controls exist (a later phase replaces this function).
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
  IF p_mode = 'active' THEN RAISE EXCEPTION 'Active billing cannot be switched on yet: the billing engine, invoicing and rollout controls are not released.'; END IF;
  SELECT s.mode INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  UPDATE public.billing_settings SET mode = p_mode, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing mode changed', 'DrugXOne', 'billing_settings', NULL, 'Billing mode', jsonb_build_object('previous', v_old, 'new', p_mode, 'reason', v_reason));
  RETURN p_mode;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_mode(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_mode(TEXT, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_create_plan(p_code TEXT, p_business_type TEXT, p_name TEXT, p_description TEXT, p_kind TEXT, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_id UUID;
BEGIN
  IF p_business_type NOT IN ('pharmacy', 'wholesaler') THEN RAISE EXCEPTION 'A plan is for pharmacies or wholesalers.'; END IF;
  IF COALESCE(p_kind, 'standard') NOT IN ('standard', 'custom') THEN RAISE EXCEPTION 'A plan is standard or custom.'; END IF;
  INSERT INTO public.billing_plans(code, business_type, kind, name, description, created_by)
  VALUES (p_code, p_business_type::public.business_type, COALESCE(p_kind, 'standard'), p_name, NULLIF(btrim(COALESCE(p_description, '')), ''), auth.uid())
  RETURNING id INTO v_id;
  PERFORM public.write_audit_log('Billing plan created', 'DrugXOne', 'billing_plan', v_id, p_code,
    jsonb_build_object('code', p_code, 'business_type', p_business_type, 'kind', COALESCE(p_kind, 'standard'), 'name', p_name, 'reason', v_reason));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_create_plan(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_create_plan(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated, service_role;

-- Publishes the next immutable version of a plan's commercial terms. Earlier versions are retired (no new subscription uses them) but stay exactly as they were for everyone
-- pinned to them. Only the parameters in p_params are changed from the defaults; unknown parameters are refused.
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
  v_params JSONB := COALESCE(p_params, '{}'::JSONB);
  v_key TEXT;
  v_next INTEGER;
  v_id UUID;
  v_new public.billing_plan_versions%ROWTYPE;
  v_has_limit BOOLEAN;
BEGIN
  IF jsonb_typeof(v_params) <> 'object' THEN RAISE EXCEPTION 'The plan terms must be an object.'; END IF;
  FOR v_key IN SELECT jsonb_object_keys(v_params) LOOP
    IF v_key NOT IN ('billing_interval_months', 'currency', 'subscription_amount', 'free_trial_days', 'onboarding_free_orders', 'monthly_free_orders', 'transaction_fee_percentage',
                     'transaction_fee_min', 'transaction_fee_max', 'transaction_fee_cycle_cap', 'min_billable_order_amount', 'max_users', 'max_branches', 'entitlements', 'metadata', 'effective_from') THEN
      RAISE EXCEPTION 'Unknown plan term "%".', v_key;
    END IF;
  END LOOP;
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = p_plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  SELECT COALESCE(max(version), 0) + 1 INTO v_next FROM public.billing_plan_versions WHERE plan_id = p_plan_id;
  SELECT * INTO v_prev FROM public.billing_plan_versions WHERE plan_id = p_plan_id AND status = 'published' ORDER BY version DESC LIMIT 1;
  INSERT INTO public.billing_plan_versions(plan_id, version, billing_interval_months, currency, subscription_amount, free_trial_days, onboarding_free_orders, monthly_free_orders,
    transaction_fee_percentage, transaction_fee_min, transaction_fee_max, transaction_fee_cycle_cap, min_billable_order_amount, max_users, max_branches, entitlements, metadata,
    effective_from, reason, created_by)
  VALUES (p_plan_id, v_next,
    COALESCE((v_params ->> 'billing_interval_months')::INTEGER, 1), COALESCE(v_params ->> 'currency', 'GHS'), COALESCE((v_params ->> 'subscription_amount')::NUMERIC, 0),
    COALESCE((v_params ->> 'free_trial_days')::INTEGER, 0), COALESCE((v_params ->> 'onboarding_free_orders')::INTEGER, 0), COALESCE((v_params ->> 'monthly_free_orders')::INTEGER, 0),
    COALESCE((v_params ->> 'transaction_fee_percentage')::NUMERIC, 0), (v_params ->> 'transaction_fee_min')::NUMERIC, (v_params ->> 'transaction_fee_max')::NUMERIC,
    (v_params ->> 'transaction_fee_cycle_cap')::NUMERIC, (v_params ->> 'min_billable_order_amount')::NUMERIC, (v_params ->> 'max_users')::INTEGER, (v_params ->> 'max_branches')::INTEGER,
    COALESCE(v_params -> 'entitlements', '{}'::JSONB), COALESCE(v_params -> 'metadata', '{}'::JSONB), COALESCE((v_params ->> 'effective_from')::TIMESTAMPTZ, now()), v_reason, auth.uid())
  RETURNING id INTO v_id;
  UPDATE public.billing_plan_versions SET status = 'retired', retired_at = now() WHERE plan_id = p_plan_id AND status = 'published' AND id <> v_id;
  SELECT * INTO v_new FROM public.billing_plan_versions WHERE id = v_id;
  PERFORM public.write_audit_log('Billing plan version published', 'DrugXOne', 'billing_plan', p_plan_id, v_plan.code,
    jsonb_build_object('version', v_next, 'reason', v_reason,
      'previous', CASE WHEN v_prev.id IS NULL THEN NULL ELSE to_jsonb(v_prev) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata' END,
      'new', to_jsonb(v_new) - 'id' - 'plan_id' - 'created_by' - 'created_at' - 'reason' - 'metadata'));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_publish_plan_version(UUID, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_publish_plan_version(UUID, JSONB, TEXT) TO authenticated, service_role;

-- Whether new subscriptions can start on a plan, and whether businesses see it. A plan needs a published version to be switched on.
CREATE OR REPLACE FUNCTION public.admin_billing_set_plan_availability(p_plan_id UUID, p_active BOOLEAN, p_publicly_visible BOOLEAN, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_plan public.billing_plans%ROWTYPE;
BEGIN
  SELECT * INTO v_plan FROM public.billing_plans WHERE id = p_plan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found.'; END IF;
  IF p_active IS NULL OR p_publicly_visible IS NULL THEN RAISE EXCEPTION 'Say whether the plan is active and whether it is visible.'; END IF;
  IF p_publicly_visible AND NOT p_active THEN RAISE EXCEPTION 'A plan that is switched off cannot be shown to businesses.'; END IF;
  IF p_active AND NOT EXISTS (SELECT 1 FROM public.billing_plan_versions v WHERE v.plan_id = p_plan_id AND v.status = 'published') THEN RAISE EXCEPTION 'Publish a version of the plan first.'; END IF;
  UPDATE public.billing_plans SET active = p_active, publicly_visible = p_publicly_visible WHERE id = p_plan_id;
  PERFORM public.write_audit_log('Billing plan availability changed', 'DrugXOne', 'billing_plan', p_plan_id, v_plan.code,
    jsonb_build_object('previous', jsonb_build_object('active', v_plan.active, 'publicly_visible', v_plan.publicly_visible),
                       'new', jsonb_build_object('active', p_active, 'publicly_visible', p_publicly_visible), 'reason', v_reason));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_plan_availability(UUID, BOOLEAN, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_plan_availability(UUID, BOOLEAN, BOOLEAN, TEXT) TO authenticated, service_role;

-- Puts an approved business on a plan from a start date (default now). Billing itself stays off until the modes say otherwise: this records the terms, the trial and the launch
-- free-order grant (once per licence number and once per owner; a second account for either gets none, and the answer says so).
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

  INSERT INTO public.billing_subscriptions(business_id, status, billing_mode, billing_starts_at, period_anchor_at, trial_start, trial_end, created_by)
  VALUES (p_business_id, CASE WHEN v_ver.free_trial_days > 0 THEN 'trialing' ELSE 'active' END, p_billing_mode, v_starts, v_starts,
          CASE WHEN v_ver.free_trial_days > 0 THEN v_starts END, CASE WHEN v_ver.free_trial_days > 0 THEN v_starts + make_interval(days => v_ver.free_trial_days) END, auth.uid())
  RETURNING id INTO v_sub_id;
  INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason, created_by)
  VALUES (v_sub_id, v_starts, v_ver.id, '{}'::JSONB, v_reason, auth.uid()) RETURNING id INTO v_terms_id;

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
REVOKE ALL ON FUNCTION public.admin_billing_start_subscription(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_start_subscription(UUID, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO authenticated, service_role;

-- Holds one business back (disabled or shadow) or lets it follow the platform setting (NULL). 'active' for one business is refused until real billing exists.
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
  SELECT name INTO v_name FROM public.businesses WHERE id = p_business_id;
  UPDATE public.billing_subscriptions SET billing_mode = p_mode WHERE id = v_sub.id;
  PERFORM public.write_audit_log('Billing mode changed for a business', v_name, 'billing_subscription', v_sub.id, 'Billing mode',
    jsonb_build_object('previous', v_sub.billing_mode, 'new', p_mode, 'reason', v_reason), _business_id => p_business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_subscription_mode(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_subscription_mode(UUID, TEXT, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Seed: the feature catalog, and two EXAMPLE plans that are switched off
-- ---------------------------------------------------------------------------
INSERT INTO public.billing_feature_catalog (key, label, description, value_type, business_type) VALUES
  ('rfq_access', 'Request for quotation', 'Create and answer RFQs.', 'boolean', NULL),
  ('advanced_analytics', 'Advanced analytics', 'Purchase and sales analytics beyond the basic reports.', 'boolean', NULL),
  ('accountant_access', 'Accountant access', 'Accountant staff access to accounting views.', 'boolean', NULL),
  ('supplier_comparison', 'Supplier comparison', 'Compare suppliers side by side.', 'boolean', 'pharmacy'),
  ('data_export', 'Data export', 'Export reports and data.', 'boolean', NULL),
  ('integrations', 'Integrations', 'Connect other systems.', 'boolean', NULL),
  ('export_row_limit', 'Export row limit', 'The most rows one export may contain.', 'integer', NULL)
ON CONFLICT (key) DO NOTHING;

-- Examples only: both are switched off and hidden, so nothing uses them until an administrator decides prices and switches them on. The wholesaler example mirrors the launch
-- configuration discussed (30-day trial, 5 launch free orders, 2 free orders a month, 0.75% after that, capped at GHS 1,500 a month). The retailer example is a free placeholder.
DO $$
DECLARE
  v_w UUID;
  v_r UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.billing_plans WHERE code = 'wholesaler_example') THEN
    INSERT INTO public.billing_plans(code, business_type, name, description, metadata)
    VALUES ('wholesaler_example', 'wholesaler', 'Wholesaler (example)', 'EXAMPLE launch terms. Not a commercial offer: set real prices by publishing a new version.', '{"example": true}'::JSONB) RETURNING id INTO v_w;
    INSERT INTO public.billing_plan_versions(plan_id, version, subscription_amount, free_trial_days, onboarding_free_orders, monthly_free_orders, transaction_fee_percentage,
      transaction_fee_cycle_cap, entitlements, metadata, reason)
    VALUES (v_w, 1, 100, 30, 5, 2, 0.75, 1500, '{"rfq_access": true, "advanced_analytics": true, "data_export": true}'::JSONB, '{"example": true}'::JSONB, 'Seed: example launch configuration');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.billing_plans WHERE code = 'retailer_example') THEN
    INSERT INTO public.billing_plans(code, business_type, name, description, metadata)
    VALUES ('retailer_example', 'pharmacy', 'Retailer (example)', 'EXAMPLE placeholder. Not a commercial offer: set real prices by publishing a new version.', '{"example": true}'::JSONB) RETURNING id INTO v_r;
    INSERT INTO public.billing_plan_versions(plan_id, version, subscription_amount, free_trial_days, transaction_fee_percentage, entitlements, metadata, reason)
    VALUES (v_r, 1, 0, 30, 0, '{"rfq_access": true, "supplier_comparison": true}'::JSONB, '{"example": true}'::JSONB, 'Seed: example placeholder');
  END IF;
END $$;
