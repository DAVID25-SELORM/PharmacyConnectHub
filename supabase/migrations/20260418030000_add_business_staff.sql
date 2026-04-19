-- Business staff management
-- Allows businesses to have multiple staff members with role-based access.

DO $$
BEGIN
  CREATE TYPE public.staff_role AS ENUM ('owner', 'manager', 'cashier', 'assistant');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE TYPE public.staff_status AS ENUM ('active', 'inactive', 'pending');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.business_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.staff_role NOT NULL DEFAULT 'assistant',
  status public.staff_status NOT NULL DEFAULT 'pending',
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  invited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (business_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_business_staff_business ON public.business_staff(business_id);
CREATE INDEX IF NOT EXISTS idx_business_staff_user ON public.business_staff(user_id);
CREATE INDEX IF NOT EXISTS idx_business_staff_status ON public.business_staff(status);
CREATE INDEX IF NOT EXISTS idx_business_staff_business_status ON public.business_staff(business_id, status);
CREATE INDEX IF NOT EXISTS idx_business_staff_user_status ON public.business_staff(user_id, status);

ALTER TABLE public.business_staff ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_business_staff(_user_id UUID, _business_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.business_staff
    WHERE user_id = _user_id
      AND business_id = _business_id
      AND status = 'active'
  )
$$;

CREATE OR REPLACE FUNCTION public.get_staff_role(_user_id UUID, _business_id UUID)
RETURNS public.staff_role
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role
  FROM public.business_staff
  WHERE user_id = _user_id
    AND business_id = _business_id
    AND status = 'active'
  LIMIT 1
$$;

DROP POLICY IF EXISTS "View staff of own business" ON public.business_staff;
CREATE POLICY "View staff of own business"
  ON public.business_staff
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
    OR public.is_business_staff(auth.uid(), business_id)
    OR public.has_role(auth.uid(), 'admin')
  );

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
    )
    OR public.has_role(auth.uid(), 'admin')
  );

DROP POLICY IF EXISTS "Owners manage staff" ON public.business_staff;
CREATE POLICY "Owners manage staff"
  ON public.business_staff
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'admin')
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'admin')
  );

DROP POLICY IF EXISTS "Owners remove staff" ON public.business_staff;
CREATE POLICY "Owners remove staff"
  ON public.business_staff
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
    OR public.has_role(auth.uid(), 'admin')
  );

DROP TRIGGER IF EXISTS trg_business_staff_updated ON public.business_staff;
CREATE TRIGGER trg_business_staff_updated
  BEFORE UPDATE ON public.business_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.add_owner_as_staff()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.business_staff (business_id, user_id, role, status, invited_by, joined_at)
  VALUES (NEW.id, NEW.owner_id, 'owner', 'active', NEW.owner_id, now())
  ON CONFLICT (business_id, user_id) DO UPDATE
    SET role = 'owner',
        status = 'active',
        invited_by = EXCLUDED.invited_by,
        joined_at = COALESCE(public.business_staff.joined_at, EXCLUDED.joined_at),
        updated_at = now();

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_add_owner_as_staff ON public.businesses;
CREATE TRIGGER trg_add_owner_as_staff
  AFTER INSERT ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.add_owner_as_staff();

INSERT INTO public.business_staff (business_id, user_id, role, status, invited_by, joined_at)
SELECT b.id, b.owner_id, 'owner', 'active', b.owner_id, b.created_at
FROM public.businesses b
ON CONFLICT (business_id, user_id) DO UPDATE
  SET role = 'owner',
      status = 'active',
      invited_by = EXCLUDED.invited_by,
      joined_at = COALESCE(public.business_staff.joined_at, EXCLUDED.joined_at),
      updated_at = now();

CREATE OR REPLACE FUNCTION public.get_user_business_context()
RETURNS TABLE (
  id UUID,
  type public.business_type,
  name TEXT,
  license_number TEXT,
  city TEXT,
  region TEXT,
  verification_status public.verification_status,
  rejection_reason TEXT,
  staff_role public.staff_role
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    b.id,
    b.type,
    b.name,
    b.license_number,
    b.city,
    b.region,
    b.verification_status,
    b.rejection_reason,
    bs.role AS staff_role
  FROM public.business_staff bs
  JOIN public.businesses b ON b.id = bs.business_id
  WHERE bs.user_id = auth.uid()
    AND bs.status = 'active'
  ORDER BY
    CASE bs.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'cashier' THEN 2
      ELSE 3
    END,
    COALESCE(bs.joined_at, bs.created_at) DESC,
    b.created_at DESC
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.list_business_staff(_business_id UUID)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  role public.staff_role,
  status public.staff_status,
  invited_at TIMESTAMPTZ,
  joined_at TIMESTAMPTZ,
  full_name TEXT,
  phone TEXT,
  user_email TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = _business_id
        AND b.owner_id = auth.uid()
    )
    OR public.is_business_staff(auth.uid(), _business_id)
    OR public.has_role(auth.uid(), 'admin')
  ) THEN
    RAISE EXCEPTION 'Not authorized to view this team.';
  END IF;

  RETURN QUERY
  SELECT
    bs.id,
    bs.user_id,
    bs.role,
    bs.status,
    bs.invited_at,
    bs.joined_at,
    p.full_name,
    p.phone,
    u.email::TEXT AS user_email
  FROM public.business_staff bs
  LEFT JOIN public.profiles p ON p.id = bs.user_id
  LEFT JOIN auth.users u ON u.id = bs.user_id
  WHERE bs.business_id = _business_id
  ORDER BY
    CASE bs.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'cashier' THEN 2
      ELSE 3
    END,
    COALESCE(bs.joined_at, bs.invited_at) DESC,
    bs.created_at DESC;
END;
$$;

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

REVOKE ALL ON FUNCTION public.get_user_business_context() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_business_staff(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_business_staff_by_email(UUID, TEXT, public.staff_role) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_user_business_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_business_staff(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_business_staff_by_email(UUID, TEXT, public.staff_role) TO authenticated;

DROP POLICY IF EXISTS "Active staff see own business" ON public.businesses;
CREATE POLICY "Active staff see own business"
  ON public.businesses
  FOR SELECT
  USING (public.is_business_staff(auth.uid(), id));

DROP POLICY IF EXISTS "Staff see own products" ON public.products;
CREATE POLICY "Staff see own products"
  ON public.products
  FOR SELECT
  USING (public.is_business_staff(auth.uid(), wholesaler_id));

DROP POLICY IF EXISTS "Managers manage own products" ON public.products;
CREATE POLICY "Managers manage own products"
  ON public.products
  FOR ALL
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role
    )
  )
  WITH CHECK (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role
    )
  );

DROP POLICY IF EXISTS "Active pharmacy staff see own orders" ON public.orders;
CREATE POLICY "Active pharmacy staff see own orders"
  ON public.orders
  FOR SELECT
  USING (public.is_business_staff(auth.uid(), pharmacy_id));

DROP POLICY IF EXISTS "Active wholesaler staff see own orders" ON public.orders;
CREATE POLICY "Active wholesaler staff see own orders"
  ON public.orders
  FOR SELECT
  USING (public.is_business_staff(auth.uid(), wholesaler_id));

DROP POLICY IF EXISTS "Pharmacy staff create own orders" ON public.orders;
CREATE POLICY "Pharmacy staff create own orders"
  ON public.orders
  FOR INSERT
  WITH CHECK (
    public.get_staff_role(auth.uid(), pharmacy_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = pharmacy_id
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Wholesaler staff update own orders" ON public.orders;
CREATE POLICY "Wholesaler staff update own orders"
  ON public.orders
  FOR UPDATE
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role
    )
  )
  WITH CHECK (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role
    )
  );

DROP POLICY IF EXISTS "Staff view items if can view parent order" ON public.order_items;
CREATE POLICY "Staff view items if can view parent order"
  ON public.order_items
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_id
        AND (
          public.is_business_staff(auth.uid(), o.pharmacy_id)
          OR public.is_business_staff(auth.uid(), o.wholesaler_id)
        )
    )
  );

DROP POLICY IF EXISTS "Pharmacy staff insert items for own order" ON public.order_items;
CREATE POLICY "Pharmacy staff insert items for own order"
  ON public.order_items
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_id
        AND public.get_staff_role(auth.uid(), o.pharmacy_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
        )
    )
  );

DROP POLICY IF EXISTS "Staff view history if can view order" ON public.order_status_history;
CREATE POLICY "Staff view history if can view order"
  ON public.order_status_history
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_status_history.order_id
        AND (
          public.is_business_staff(auth.uid(), o.pharmacy_id)
          OR public.is_business_staff(auth.uid(), o.wholesaler_id)
        )
    )
  );

DROP POLICY IF EXISTS "Wholesaler staff insert history" ON public.order_status_history;
CREATE POLICY "Wholesaler staff insert history"
  ON public.order_status_history
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = order_status_history.order_id
        AND public.get_staff_role(auth.uid(), o.wholesaler_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
        )
    )
  );
