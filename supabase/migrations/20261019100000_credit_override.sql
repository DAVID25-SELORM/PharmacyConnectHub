-- One-time credit limit override.
--
-- A wholesaler owner or manager can approve ONE credit order above a pharmacy's limit: up to a
-- stated maximum order value, within a short window (1-30 days), with a recorded reason. It is
-- deliberately narrow:
--   * one active override per wholesaler/pharmacy pair; it is consumed by the first order that needs
--     it and cannot be used twice, even by two simultaneous orders (it is locked under the same
--     credit-line lock as the limit check);
--   * it never overrides a suspended / blocked / closed line, only the amount;
--   * the limit itself is not changed, so exposure above it is visible and the NEXT order is checked
--     against the real limit again;
--   * granting, revoking and using it are each audited (who, role, reason, limit, available credit
--     before, order amount, override amount, resulting exposure).
-- Permission: wholesaler owner / manager (the repo has no permission table yet; this is the
-- `credit.override_limit` permission in the brief).
--
-- The checkout function is PATCHED, not replaced: the deployed function carries production-only
-- safeguards (see 20261017110000_production_checkout_compatibility.sql) that a full replacement
-- would silently remove. Each fragment must match exactly once, otherwise the migration fails
-- closed and changes nothing.

CREATE TABLE public.credit_overrides (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  max_order_ghs NUMERIC(12,2) NOT NULL CHECK (max_order_ghs > 0 AND max_order_ghs <= 10000000),
  reason TEXT NOT NULL CHECK (char_length(reason) BETWEEN 5 AND 500),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'used', 'expired', 'revoked')),
  limit_at_grant NUMERIC(12,2) NOT NULL,
  exposure_at_grant NUMERIC(12,2) NOT NULL,
  granted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  used_order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  used_at TIMESTAMPTZ,
  revoked_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  revoked_at TIMESTAMPTZ,
  revoke_reason TEXT
);
CREATE UNIQUE INDEX credit_overrides_one_active ON public.credit_overrides (wholesaler_id, pharmacy_id) WHERE status = 'active';
CREATE INDEX credit_overrides_pharmacy ON public.credit_overrides (pharmacy_id, wholesaler_id, granted_at DESC);
ALTER TABLE public.credit_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit overrides" ON public.credit_overrides FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.credit_overrides FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.credit_overrides TO authenticated;

-- ---------------------------------------------------------------------------
-- Grant
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.grant_credit_override(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_max_order_ghs NUMERIC,
  p_valid_days INTEGER,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_line RECORD;
  v_exposure NUMERIC;
  v_available NUMERIC;
  v_id UUID;
  v_org TEXT;
  v_pharmacy TEXT;
  v_role TEXT;
  v_actor_email TEXT;
  v_expires TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  IF p_max_order_ghs IS NULL OR p_max_order_ghs <= 0 OR p_max_order_ghs > 10000000 THEN
    RAISE EXCEPTION 'The override amount must be above 0 and at most 10,000,000.';
  END IF;
  IF p_valid_days IS NULL OR p_valid_days < 1 OR p_valid_days > 30 THEN
    RAISE EXCEPTION 'An override can be valid for 1 to 30 days.';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason of 5 to 500 characters is required to grant a credit override.';
  END IF;

  -- Same lock the checkout takes, so a grant can't interleave with an order using this line.
  SELECT * INTO v_line FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  IF NOT FOUND OR NOT v_line.active THEN RAISE EXCEPTION 'No active credit line for this pharmacy.'; END IF;
  IF v_line.status <> 'active' THEN
    RAISE EXCEPTION 'Credit is % for this pharmacy. Reactivate it before granting an override.', v_line.status;
  END IF;

  v_exposure := public.credit_exposure(p_wholesaler_id, p_pharmacy_id);
  v_available := GREATEST(v_line.credit_limit_ghs - v_exposure, 0);
  IF p_max_order_ghs <= v_available THEN
    RAISE EXCEPTION 'No override is needed: this pharmacy already has GHS % of credit available.',
      to_char(v_available, 'FM999,999,990.00');
  END IF;

  UPDATE public.credit_overrides SET status = 'expired'
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND status = 'active' AND expires_at <= now();
  IF EXISTS (SELECT 1 FROM public.credit_overrides WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND status = 'active') THEN
    RAISE EXCEPTION 'An override is already active for this pharmacy. Revoke it before granting another.';
  END IF;

  v_expires := now() + make_interval(days => p_valid_days);
  INSERT INTO public.credit_overrides (wholesaler_id, pharmacy_id, max_order_ghs, reason, limit_at_grant, exposure_at_grant, granted_by, expires_at)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_max_order_ghs, v_reason, v_line.credit_limit_ghs, v_exposure, auth.uid(), v_expires)
  RETURNING id INTO v_id;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    'Credit override granted', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object(
      'override_id', v_id, 'max_order_ghs', p_max_order_ghs, 'valid_days', p_valid_days, 'expires_at', v_expires,
      'reason', v_reason, 'actor_role', v_role, 'limit_ghs', v_line.credit_limit_ghs,
      'exposure_ghs', v_exposure, 'available_ghs', v_available),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);

  BEGIN
    PERFORM public.notify_business(p_pharmacy_id, ARRAY['owner', 'manager', 'accountant'], 'credit_override',
      'One-time credit override approved',
      v_org || ' approved one credit order of up to GHS ' || to_char(p_max_order_ghs, 'FM999,999,990.00')
        || ' above your limit, valid until ' || to_char(v_expires, 'DD Mon YYYY') || '.',
      '/pharmacy', jsonb_build_object('wholesaler_id', p_wholesaler_id, 'override_id', v_id));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'grant_credit_override notification failed: %', SQLERRM;
  END;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.grant_credit_override(UUID, UUID, NUMERIC, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.grant_credit_override(UUID, UUID, NUMERIC, INTEGER, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Revoke an unused override
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.revoke_credit_override(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_override RECORD;
  v_org TEXT;
  v_pharmacy TEXT;
  v_role TEXT;
  v_actor_email TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason of 5 to 500 characters is required to revoke a credit override.';
  END IF;
  -- Take the credit-line lock first (same order as checkout) so a revoke can't race an order using it.
  PERFORM 1 FROM public.wholesaler_credit_terms WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  SELECT * INTO v_override FROM public.credit_overrides
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND status = 'active' AND expires_at > now() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no active override to revoke for this pharmacy.'; END IF;

  UPDATE public.credit_overrides
  SET status = 'revoked', revoked_by = auth.uid(), revoked_at = now(), revoke_reason = v_reason
  WHERE id = v_override.id;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    'Credit override revoked', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object('override_id', v_override.id, 'max_order_ghs', v_override.max_order_ghs,
      'reason', v_reason, 'actor_role', v_role, 'granted_reason', v_override.reason),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_credit_override(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_credit_override(UUID, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Checkout: patch the deployed function in place (fail closed if it isn't exactly as expected).
-- ---------------------------------------------------------------------------
DO $migration$
DECLARE
  definition TEXT;
  fragment TEXT;
  hits INTEGER;
  a1_old TEXT := E'  v_credit_audit JSONB;\n';
  a1_new TEXT := E'  v_credit_audit JSONB;\n  v_override_id UUID;\n  v_override_excess NUMERIC;\n';
  a2_old TEXT := E'    v_credit_audit := NULL;\n';
  a2_new TEXT := E'    v_credit_audit := NULL;\n    v_override_id := NULL;\n';
  a3_old TEXT := $old$      IF v_credit_outstanding + v_goods + v_fee > v_credit.credit_limit_ghs THEN
        RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
          v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_goods + v_fee, 'FM999,999,990.00');
      END IF;
$old$;
  a3_new TEXT := $new$      IF v_credit_outstanding + v_goods + v_fee > v_credit.credit_limit_ghs THEN
        -- A one-time override approved by the wholesaler may cover this order. It is locked here,
        -- under the same credit-line lock as the limit check, so exactly one order can consume it.
        SELECT ov.id INTO v_override_id FROM public.credit_overrides ov
        WHERE ov.wholesaler_id = v_wholesaler.wholesaler_id AND ov.pharmacy_id = _pharmacy_id
          AND ov.status = 'active' AND ov.expires_at > now() AND ov.max_order_ghs >= v_goods + v_fee
        FOR UPDATE;
        IF v_override_id IS NULL THEN
          RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
            v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_goods + v_fee, 'FM999,999,990.00');
        END IF;
        v_override_excess := v_credit_outstanding + v_goods + v_fee - v_credit.credit_limit_ghs;
      END IF;
$new$;
  a4_old TEXT := $old$      VALUES (v_wholesaler.wholesaler_id, _pharmacy_id, v_order_id, 'invoice', 'debit', v_goods + v_fee, _caller_id);
$old$;
  a4_new TEXT := $new$      VALUES (v_wholesaler.wholesaler_id, _pharmacy_id, v_order_id, 'invoice', 'debit', v_goods + v_fee, _caller_id);
      IF v_override_id IS NOT NULL THEN
        UPDATE public.credit_overrides SET status = 'used', used_order_id = v_order_id, used_at = now() WHERE id = v_override_id;
        PERFORM public.write_audit_log(
          'Credit override used', v_business.name, 'order', v_order_id, v_order_number,
          jsonb_build_object(
            'override_id', v_override_id,
            'limit_ghs', v_credit.credit_limit_ghs,
            'available_before_ghs', GREATEST(v_credit.credit_limit_ghs - v_credit_outstanding, 0),
            'order_ghs', v_goods + v_fee,
            'override_amount_ghs', v_override_excess,
            'resulting_exposure_ghs', v_credit_outstanding + v_goods + v_fee),
          _caller_id, v_actor_email, NULL, v_wholesaler.wholesaler_id);
      END IF;
$new$;
BEGIN
  definition := replace(pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure), E'\r', '');
  IF strpos(definition, 'credit_overrides') > 0 THEN RETURN; END IF; -- already patched

  FOREACH fragment IN ARRAY ARRAY[a1_old, a2_old, a3_old, a4_old] LOOP
    hits := (length(definition) - length(replace(definition, fragment, ''))) / length(fragment);
    IF hits <> 1 THEN
      RAISE EXCEPTION 'Unexpected checkout body (a fragment matched % times, expected 1); inspect before patching the override. Fragment starts: %',
        hits, left(fragment, 80);
    END IF;
  END LOOP;

  definition := replace(definition, a1_old, a1_new);
  definition := replace(definition, a2_old, a2_new);
  definition := replace(definition, a3_old, a3_new);
  definition := replace(definition, a4_old, a4_new);
  EXECUTE definition;
END;
$migration$;
REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- Readers: add the active override (if any). Return types change, so drop and recreate.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_wholesaler_credit_terms(UUID);
CREATE FUNCTION public.list_wholesaler_credit_terms(p_wholesaler_id UUID)
RETURNS TABLE(
  pharmacy_id UUID, pharmacy_name TEXT, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, internal_note TEXT, updated_at TIMESTAMPTZ,
  status TEXT, status_reason TEXT, status_changed_at TIMESTAMPTZ,
  override_max_order_ghs NUMERIC, override_expires_at TIMESTAMPTZ, override_reason TEXT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may view credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.pharmacy_id, ph.name, c.credit_limit_ghs, c.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(c.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    c.internal_note, c.updated_at, c.status, c.status_reason, c.status_changed_at,
    ov.max_order_ghs, ov.expires_at, ov.reason
  FROM public.wholesaler_credit_terms c
  JOIN public.businesses ph ON ph.id = c.pharmacy_id
  LEFT JOIN public.credit_overrides ov ON ov.wholesaler_id = c.wholesaler_id AND ov.pharmacy_id = c.pharmacy_id
    AND ov.status = 'active' AND ov.expires_at > now()
  WHERE c.wholesaler_id = p_wholesaler_id AND c.active
  ORDER BY ph.name;
END;
$$;
REVOKE ALL ON FUNCTION public.list_wholesaler_credit_terms(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_credit_terms(UUID) TO authenticated;

DROP FUNCTION IF EXISTS public.get_my_credit_terms(UUID, UUID);
CREATE FUNCTION public.get_my_credit_terms(p_pharmacy_id UUID, p_wholesaler_id UUID DEFAULT NULL)
RETURNS TABLE(
  wholesaler_id UUID, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, status TEXT,
  override_max_order_ghs NUMERIC, override_expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.wholesaler_id, c.credit_limit_ghs, c.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(c.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    c.status, ov.max_order_ghs, ov.expires_at
  FROM public.wholesaler_credit_terms c
  LEFT JOIN public.credit_overrides ov ON ov.wholesaler_id = c.wholesaler_id AND ov.pharmacy_id = c.pharmacy_id
    AND ov.status = 'active' AND ov.expires_at > now()
  WHERE c.pharmacy_id = p_pharmacy_id AND c.active
    AND (p_wholesaler_id IS NULL OR c.wholesaler_id = p_wholesaler_id);
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_credit_terms(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_terms(UUID, UUID) TO authenticated;
