-- Require an approved business (businesses.verification_status = 'approved') for
-- customer-discount management and staff creation. Pending and rejected businesses
-- may only use onboarding. Platform admins are unaffected: none of the discount
-- functions ever permitted them, and staff creation keeps its admin exemption.

-- ---------------------------------------------------------------------------
-- Customer discounts: RLS (the direct-table path bypassed the RPCs)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Wholesaler owners and managers manage discounts" ON public.customer_discounts;
CREATE POLICY "Wholesaler owners and managers manage discounts"
  ON public.customer_discounts FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
        AND (b.owner_id = auth.uid()
          OR (public.is_business_staff(auth.uid(), b.id)
            AND public.get_staff_role(auth.uid(), b.id) IN ('owner', 'manager')))
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
        AND (b.owner_id = auth.uid()
          OR (public.is_business_staff(auth.uid(), b.id)
            AND public.get_staff_role(auth.uid(), b.id) IN ('owner', 'manager')))
    )
  );

-- ---------------------------------------------------------------------------
-- Customer discounts: RPCs (signatures, grants, SECURITY DEFINER and search_path preserved)
--
-- SECURITY FIX: the original upsert_customer_discount() wrote
--   IF NOT (owner OR get_staff_role(...) IN ('owner','manager'))
-- get_staff_role() returns NULL for non-members, so the condition became NULL (not TRUE) and the
-- exception was skipped: any signed-in user could create discounts for any wholesaler.
-- The role test is now NULL-safe via COALESCE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_wholesaler_customer_discounts(p_wholesaler_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_result JSONB;
BEGIN
  IF NOT (btrim(COALESCE(public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT, '')) IN ('owner','manager')
    OR EXISTS (SELECT 1 FROM public.businesses wb WHERE wb.id = p_wholesaler_id AND wb.owner_id = auth.uid())) THEN
    RETURN '[]'::JSONB;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.businesses wb
    WHERE wb.id = p_wholesaler_id AND wb.type = 'wholesaler' AND wb.verification_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Your wholesaler account must be verified before managing customer discounts.';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(d) - 'internal_note' ORDER BY b.name), '[]'::JSONB)
  INTO v_result
  FROM public.customer_discounts d
  JOIN public.businesses b ON b.id = d.pharmacy_id
  WHERE d.wholesaler_id = p_wholesaler_id;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_customer_discount(
  p_wholesaler_id UUID, p_pharmacy_id UUID, p_discount_type TEXT,
  p_discount_percent NUMERIC DEFAULT NULL, p_discount_amount NUMERIC DEFAULT NULL,
  p_minimum_order_value NUMERIC DEFAULT 0, p_starts_at TIMESTAMPTZ DEFAULT now(),
  p_ends_at TIMESTAMPTZ DEFAULT NULL, p_internal_note TEXT DEFAULT NULL
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid())
    OR COALESCE(public.get_staff_role(auth.uid(), p_wholesaler_id) IN ('owner','manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage discounts.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.businesses b
    WHERE b.id = p_wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Your wholesaler account must be verified before managing customer discounts.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type = 'pharmacy') THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;
  UPDATE public.customer_discounts SET active = false, updated_at = now(), updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND active;
  INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent, discount_amount,
    minimum_order_value, starts_at, ends_at, internal_note, created_by, updated_by)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_discount_type, p_discount_percent, p_discount_amount,
    p_minimum_order_value, p_starts_at, p_ends_at, p_internal_note, auth.uid(), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_customer_discount(p_discount_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wholesaler_id UUID;
BEGIN
  SELECT d.wholesaler_id INTO v_wholesaler_id FROM public.customer_discounts d WHERE d.id = p_discount_id;
  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  -- Callers without rights over this wholesaler keep getting FALSE (no information leak).
  IF NOT (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_wholesaler_id AND b.owner_id = auth.uid())
    OR COALESCE(public.get_staff_role(auth.uid(), v_wholesaler_id) IN ('owner','manager'), FALSE)) THEN
    RETURN FALSE;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.businesses b
    WHERE b.id = v_wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Your wholesaler account must be verified before managing customer discounts.';
  END IF;

  UPDATE public.customer_discounts d SET active = false, updated_at = now(), updated_by = auth.uid()
  WHERE d.id = p_discount_id;
  RETURN FOUND;
END;
$$;

-- ---------------------------------------------------------------------------
-- Pharmacy-side discount lookup: a pending or rejected pharmacy must not receive negotiated
-- commercial terms (a wholesaler can create a discount for any pharmacy row). Same signature,
-- SECURITY DEFINER, search_path and grants as 20260920100000_customer_discounts_foundation.sql.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_customer_discount(p_wholesaler_id UUID)
RETURNS TABLE (
  id UUID,
  wholesaler_id UUID,
  pharmacy_id UUID,
  discount_type TEXT,
  discount_percent NUMERIC,
  discount_amount NUMERIC,
  minimum_order_value NUMERIC,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  active BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT d.id, d.wholesaler_id, d.pharmacy_id, d.discount_type,
    d.discount_percent, d.discount_amount, d.minimum_order_value,
    d.starts_at, d.ends_at, d.active
  FROM public.customer_discounts d
  WHERE d.wholesaler_id = p_wholesaler_id
    AND d.active
    AND EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = d.pharmacy_id AND b.owner_id = auth.uid() AND b.type = 'pharmacy'
        AND b.verification_status = 'approved'
    );
$$;

-- ---------------------------------------------------------------------------
-- Staff creation: RPC and direct-insert RLS path
-- (the /api/staff/invite service-role endpoint is fixed in application code)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.add_business_staff_by_email(
  _business_id UUID,
  _email TEXT,
  _role public.staff_role
)
RETURNS public.business_staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID;
  v_is_owner BOOLEAN;
  v_effective_role public.staff_role;
  v_staff public.business_staff;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to add staff.';
  END IF;

  IF NOT (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = _business_id
        AND b.owner_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'admin')
  ) THEN
    RAISE EXCEPTION 'Only the business owner can add staff.';
  END IF;

  IF NOT public.has_role(auth.uid(), 'admin') AND NOT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = _business_id
      AND b.verification_status = 'approved'
  ) THEN
    RAISE EXCEPTION 'Your business must be verified before you can add staff.';
  END IF;

  v_user_id := (
    SELECT u.id
    FROM auth.users u
    WHERE lower(u.email) = lower(trim(_email))
    LIMIT 1
  );

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No user found for that email. Ask them to create an account first.';
  END IF;

  v_is_owner := EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.id = _business_id
      AND b.owner_id = v_user_id
  );

  IF _role = 'owner' AND NOT v_is_owner THEN
    RAISE EXCEPTION 'Owner role is reserved for the business owner.';
  END IF;

  v_effective_role := CASE WHEN v_is_owner THEN 'owner'::public.staff_role ELSE _role END;

  FOR v_staff IN
    INSERT INTO public.business_staff (
      business_id,
      user_id,
      role,
      status,
      invited_by,
      joined_at
    )
    VALUES (
      _business_id,
      v_user_id,
      v_effective_role,
      'active',
      auth.uid(),
      now()
    )
    ON CONFLICT (business_id, user_id) DO UPDATE
      SET role = EXCLUDED.role,
          status = 'active',
          invited_by = EXCLUDED.invited_by,
          joined_at = COALESCE(public.business_staff.joined_at, EXCLUDED.joined_at),
          updated_at = now()
    RETURNING *
  LOOP
    RETURN v_staff;
  END LOOP;

  RAISE EXCEPTION 'Unable to add or update staff membership.';
END;
$$;

-- The owner's own staff row is created by the SECURITY DEFINER trigger add_owner_as_staff(),
-- which bypasses RLS, so requiring approval here does not affect signup.
DROP POLICY IF EXISTS "Owners add staff" ON public.business_staff;
CREATE POLICY "Owners add staff"
  ON public.business_staff
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
    OR public.has_role(auth.uid(), 'admin')
  );
