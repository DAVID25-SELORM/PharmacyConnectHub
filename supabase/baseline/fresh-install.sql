-- GENERATED FRESH DATABASE ONLY. Never use on an existing installation.
BEGIN;
DO $$ BEGIN IF to_regclass('public.businesses') IS NOT NULL THEN RAISE EXCEPTION 'Fresh baseline requires an empty application schema.'; END IF; END $$;
-- Source: 20260418020126_9c479796-cb89-4d6c-9caf-0bb04a77bf15.sql

-- Enable extensions FIRST
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ===== ENUMS =====
CREATE TYPE public.app_role AS ENUM ('admin', 'pharmacy', 'wholesaler');
CREATE TYPE public.business_type AS ENUM ('pharmacy', 'wholesaler');
CREATE TYPE public.verification_status AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE public.order_status AS ENUM ('pending', 'accepted', 'packed', 'dispatched', 'delivered', 'cancelled');

-- ===== TIMESTAMP TRIGGER =====
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql SET search_path = public;

-- ===== PROFILES =====
CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT,
  phone TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own profile" ON public.profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users insert own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ===== USER ROLES =====
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
$$;

CREATE POLICY "Users view own roles" ON public.user_roles FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admins view all roles" ON public.user_roles FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins manage roles" ON public.user_roles FOR ALL USING (public.has_role(auth.uid(), 'admin'));

-- ===== BUSINESSES =====
CREATE TABLE public.businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type public.business_type NOT NULL,
  name TEXT NOT NULL,
  license_number TEXT,
  city TEXT,
  region TEXT,
  address TEXT,
  phone TEXT,
  verification_status public.verification_status NOT NULL DEFAULT 'pending',
  rejection_reason TEXT,
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_businesses_owner ON public.businesses(owner_id);
CREATE INDEX idx_businesses_type ON public.businesses(type);
CREATE INDEX idx_businesses_verification ON public.businesses(verification_status);

CREATE POLICY "Anyone authed sees approved businesses" ON public.businesses FOR SELECT
  TO authenticated USING (verification_status = 'approved' OR owner_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Owners insert own business" ON public.businesses FOR INSERT WITH CHECK (auth.uid() = owner_id);
CREATE POLICY "Owners update own business" ON public.businesses FOR UPDATE USING (auth.uid() = owner_id);
CREATE POLICY "Admins update any business" ON public.businesses FOR UPDATE USING (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER trg_businesses_updated BEFORE UPDATE ON public.businesses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ===== LICENSE DOCUMENTS =====
CREATE TABLE public.license_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  doc_type TEXT NOT NULL,
  storage_path TEXT NOT NULL,
  uploaded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.license_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Owners see own docs" ON public.license_documents FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = business_id AND b.owner_id = auth.uid())
);
CREATE POLICY "Owners upload own docs" ON public.license_documents FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = business_id AND b.owner_id = auth.uid())
);
CREATE POLICY "Admins see all docs" ON public.license_documents FOR SELECT USING (public.has_role(auth.uid(), 'admin'));

-- ===== PRODUCTS =====
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  brand TEXT,
  category TEXT,
  form TEXT,
  pack_size TEXT,
  price_ghs NUMERIC(10,2) NOT NULL CHECK (price_ghs >= 0),
  stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
  image_hue INTEGER DEFAULT 200,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_products_wholesaler ON public.products(wholesaler_id);
CREATE INDEX idx_products_category ON public.products(category);
CREATE INDEX idx_products_name_trgm ON public.products USING gin (name gin_trgm_ops);

CREATE POLICY "Authed view active approved products" ON public.products FOR SELECT
  TO authenticated USING (
    (active = true AND EXISTS (
      SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.verification_status = 'approved'
    ))
    OR EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.owner_id = auth.uid())
    OR public.has_role(auth.uid(), 'admin')
  );
CREATE POLICY "Wholesalers manage own products" ON public.products FOR ALL USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.owner_id = auth.uid())
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.owner_id = auth.uid())
);
CREATE TRIGGER trg_products_updated BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ===== ORDERS =====
CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number TEXT NOT NULL UNIQUE DEFAULT ('ORD-' || lpad((floor(random()*900000)+100000)::text, 6, '0')),
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  status public.order_status NOT NULL DEFAULT 'pending',
  total_ghs NUMERIC(10,2) NOT NULL DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_orders_pharmacy ON public.orders(pharmacy_id);
CREATE INDEX idx_orders_wholesaler ON public.orders(wholesaler_id);
CREATE INDEX idx_orders_status ON public.orders(status);

CREATE POLICY "Buyers see own orders" ON public.orders FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = pharmacy_id AND b.owner_id = auth.uid())
);
CREATE POLICY "Sellers see own orders" ON public.orders FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.owner_id = auth.uid())
);
CREATE POLICY "Admins see all orders" ON public.orders FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Pharmacies create own orders" ON public.orders FOR INSERT WITH CHECK (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = pharmacy_id AND b.owner_id = auth.uid() AND b.verification_status = 'approved')
);
CREATE POLICY "Wholesalers update their orders" ON public.orders FOR UPDATE USING (
  EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.owner_id = auth.uid())
);
CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ===== ORDER ITEMS =====
CREATE TABLE public.order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name TEXT NOT NULL,
  unit_price_ghs NUMERIC(10,2) NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0)
);
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
CREATE INDEX idx_order_items_order ON public.order_items(order_id);

CREATE POLICY "View items if can view parent order" ON public.order_items FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.businesses b ON b.id IN (o.pharmacy_id, o.wholesaler_id)
    WHERE o.id = order_id AND (b.owner_id = auth.uid() OR public.has_role(auth.uid(), 'admin'))
  )
);
CREATE POLICY "Insert items for own order" ON public.order_items FOR INSERT WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.businesses b ON b.id = o.pharmacy_id
    WHERE o.id = order_id AND b.owner_id = auth.uid()
  )
);

-- ===== AUTO PROFILE + FIRST-USER-AS-ADMIN =====
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  signup_role public.app_role;
BEGIN
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''), COALESCE(NEW.raw_user_meta_data->>'phone', ''));

  signup_role := COALESCE((NEW.raw_user_meta_data->>'role')::public.app_role, 'pharmacy');
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, signup_role);

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin') ON CONFLICT DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ===== STORAGE BUCKET FOR LICENSES =====
INSERT INTO storage.buckets (id, name, public) VALUES ('licenses', 'licenses', false);

CREATE POLICY "Users upload own license docs" ON storage.objects FOR INSERT WITH CHECK (
  bucket_id = 'licenses' AND auth.uid()::text = (storage.foldername(name))[1]
);
CREATE POLICY "Users read own license docs" ON storage.objects FOR SELECT USING (
  bucket_id = 'licenses' AND auth.uid()::text = (storage.foldername(name))[1]
);
CREATE POLICY "Admins read all license docs" ON storage.objects FOR SELECT USING (
  bucket_id = 'licenses' AND public.has_role(auth.uid(), 'admin')
);

-- Source: 20260418020137_9bde4aff-ea64-4c26-a749-dbfe0e9d0e53.sql

DROP INDEX IF EXISTS public.idx_products_name_trgm;
DROP EXTENSION IF EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE INDEX idx_products_name_trgm ON public.products USING gin (name extensions.gin_trgm_ops);

-- Source: 20260418021718_2cdc1fd4-5ee9-4953-8ad4-6e1a83e54eb9.sql
-- Add payment + lifecycle columns to orders
DO $$ BEGIN
  CREATE TYPE public.payment_method AS ENUM ('cod', 'paystack');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.payment_status AS ENUM ('unpaid', 'paid', 'refunded', 'failed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS payment_method public.payment_method NOT NULL DEFAULT 'cod',
  ADD COLUMN IF NOT EXISTS payment_status public.payment_status NOT NULL DEFAULT 'unpaid',
  ADD COLUMN IF NOT EXISTS paystack_reference text,
  ADD COLUMN IF NOT EXISTS paystack_access_code text,
  ADD COLUMN IF NOT EXISTS paid_at timestamptz,
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz,
  ADD COLUMN IF NOT EXISTS packed_at timestamptz,
  ADD COLUMN IF NOT EXISTS dispatched_at timestamptz,
  ADD COLUMN IF NOT EXISTS delivered_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancellation_reason text;

CREATE UNIQUE INDEX IF NOT EXISTS orders_paystack_reference_uniq
  ON public.orders(paystack_reference) WHERE paystack_reference IS NOT NULL;

-- Audit trail
CREATE TABLE IF NOT EXISTS public.order_status_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  from_status public.order_status,
  to_status public.order_status NOT NULL,
  changed_by uuid,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS order_status_history_order_id_idx
  ON public.order_status_history(order_id, created_at DESC);

ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View history if can view order"
  ON public.order_status_history FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.businesses b ON (b.id = o.pharmacy_id OR b.id = o.wholesaler_id)
    WHERE o.id = order_status_history.order_id
      AND (b.owner_id = auth.uid() OR public.has_role(auth.uid(), 'admin'::public.app_role))
  ));

CREATE POLICY "Wholesalers insert history"
  ON public.order_status_history FOR INSERT
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.orders o
    JOIN public.businesses b ON b.id = o.wholesaler_id
    WHERE o.id = order_status_history.order_id AND b.owner_id = auth.uid()
  ));

-- Trigger: auto-record status changes + stamp lifecycle timestamps
CREATE OR REPLACE FUNCTION public.handle_order_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    -- Stamp lifecycle timestamps
    IF NEW.status = 'accepted' AND NEW.accepted_at IS NULL THEN NEW.accepted_at := now(); END IF;
    IF NEW.status = 'packed' AND NEW.packed_at IS NULL THEN NEW.packed_at := now(); END IF;
    IF NEW.status = 'dispatched' AND NEW.dispatched_at IS NULL THEN NEW.dispatched_at := now(); END IF;
    IF NEW.status = 'delivered' AND NEW.delivered_at IS NULL THEN NEW.delivered_at := now(); END IF;
    IF NEW.status = 'cancelled' AND NEW.cancelled_at IS NULL THEN NEW.cancelled_at := now(); END IF;

    INSERT INTO public.order_status_history(order_id, from_status, to_status, changed_by)
    VALUES (NEW.id, OLD.status, NEW.status, auth.uid());
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS orders_status_change ON public.orders;
CREATE TRIGGER orders_status_change
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.handle_order_status_change();

-- Trigger: record initial 'pending' on insert
CREATE OR REPLACE FUNCTION public.handle_order_insert_history()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.order_status_history(order_id, from_status, to_status, changed_by)
  VALUES (NEW.id, NULL, NEW.status, auth.uid());
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS orders_insert_history ON public.orders;
CREATE TRIGGER orders_insert_history
  AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.handle_order_insert_history();
-- Source: 20260418030000_add_business_staff.sql
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

-- Source: 20260418043000_harden_verification_controls.sql
-- Harden verification enforcement so approval state cannot be bypassed by direct client writes.

CREATE OR REPLACE FUNCTION public.enforce_business_verification_controls()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Service-role operations (auth.uid() IS NULL) bypass RLS but still fire triggers.
  -- Allow them through unconditionally; RLS is what restricts regular users.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF NOT public.has_role(auth.uid(), 'admin') THEN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status
      OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason
      OR NEW.verified_at IS DISTINCT FROM OLD.verified_at THEN
      RAISE EXCEPTION 'Only admins can change verification status.';
    END IF;
  END IF;

  IF NEW.verification_status = 'approved' THEN
    NEW.rejection_reason := NULL;
    NEW.verified_at := COALESCE(NEW.verified_at, OLD.verified_at, now());
  ELSIF NEW.verification_status = 'rejected' THEN
    NEW.verified_at := NULL;
  ELSE
    NEW.rejection_reason := NULL;
    NEW.verified_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_business_verification_controls ON public.businesses;
CREATE TRIGGER trg_enforce_business_verification_controls
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_business_verification_controls();

DROP POLICY IF EXISTS "Wholesalers manage own products" ON public.products;
CREATE POLICY "Wholesalers manage own products"
  ON public.products
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Managers manage own products" ON public.products;
CREATE POLICY "Managers manage own products"
  ON public.products
  FOR ALL
  USING (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  );

DROP POLICY IF EXISTS "Wholesalers update their orders" ON public.orders;
CREATE POLICY "Wholesalers update their orders"
  ON public.orders
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.owner_id = auth.uid()
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
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
    )
  )
  WITH CHECK (
    public.get_staff_role(auth.uid(), wholesaler_id) IN (
      'owner'::public.staff_role,
      'manager'::public.staff_role,
      'cashier'::public.staff_role
    )
    AND EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND b.verification_status = 'approved'
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
      JOIN public.businesses b ON b.id = o.pharmacy_id
      WHERE o.id = order_id
        AND b.verification_status = 'approved'
        AND public.get_staff_role(auth.uid(), o.pharmacy_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
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
      JOIN public.businesses b ON b.id = o.wholesaler_id
      WHERE o.id = order_status_history.order_id
        AND b.verification_status = 'approved'
        AND public.get_staff_role(auth.uid(), o.wholesaler_id) IN (
          'owner'::public.staff_role,
          'manager'::public.staff_role,
          'cashier'::public.staff_role
        )
    )
  );
-- Source: 20260419000000_add_notifications.sql
-- In-app notifications for verification status changes, new orders, and order status updates.

CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  read BOOLEAN NOT NULL DEFAULT false,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user
  ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
  ON public.notifications(user_id) WHERE NOT read;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users see own notifications"
  ON public.notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users update own notifications"
  ON public.notifications FOR UPDATE
  USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- Trigger: business verification status changed -> notify business owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_business_verification_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.verification_status IS NOT DISTINCT FROM OLD.verification_status THEN
    RETURN NEW;
  END IF;

  IF NEW.verification_status = 'approved' THEN
    INSERT INTO public.notifications(user_id, type, title, body, metadata)
    VALUES (
      NEW.owner_id,
      'business_approved',
      'Application approved',
      'Your business "' || NEW.name || '" has been verified. You now have full access to the marketplace.',
      jsonb_build_object('business_id', NEW.id, 'business_name', NEW.name)
    );
  ELSIF NEW.verification_status = 'rejected' THEN
    INSERT INTO public.notifications(user_id, type, title, body, metadata)
    VALUES (
      NEW.owner_id,
      'business_rejected',
      'Application not approved',
      CASE
        WHEN NEW.rejection_reason IS NOT NULL AND NEW.rejection_reason <> ''
        THEN 'Your application for "' || NEW.name || '" was not approved. Reason: ' || NEW.rejection_reason
        ELSE 'Your application for "' || NEW.name || '" was not approved. Please contact support.'
      END,
      jsonb_build_object('business_id', NEW.id, 'business_name', NEW.name)
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_business_verification ON public.businesses;
CREATE TRIGGER trg_notify_business_verification
  AFTER UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_business_verification_changed();

-- ---------------------------------------------------------------------------
-- Trigger: new order placed -> notify wholesaler owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    w.owner_id,
    'new_order',
    'New order received',
    'Order #' || NEW.order_number || ' from ' || COALESCE(ph.name, 'a pharmacy') ||
      ' - GHS ' || to_char(NEW.total_ghs, 'FM999,999.00'),
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number)
  FROM public.businesses w
  LEFT JOIN public.businesses ph ON ph.id = NEW.pharmacy_id
  WHERE w.id = NEW.wholesaler_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_new_order ON public.orders;
CREATE TRIGGER trg_notify_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_new_order();

-- ---------------------------------------------------------------------------
-- Trigger: order status changed -> notify pharmacy owner
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_order_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    ph.owner_id,
    'order_status',
    'Order update',
    'Your order #' || NEW.order_number || ' from ' || COALESCE(w.name, 'your wholesaler') ||
      ' is now ' || CASE NEW.status
        WHEN 'accepted'   THEN 'accepted'
        WHEN 'packed'     THEN 'packed and ready'
        WHEN 'dispatched' THEN 'out for delivery'
        WHEN 'delivered'  THEN 'delivered'
        WHEN 'cancelled'  THEN 'cancelled'
        ELSE NEW.status::TEXT
      END || '.',
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number, 'status', NEW.status)
  FROM public.businesses ph
  LEFT JOIN public.businesses w ON w.id = NEW.wholesaler_id
  WHERE ph.id = NEW.pharmacy_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_order_status ON public.orders;
CREATE TRIGGER trg_notify_order_status
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_order_status_changed();

-- Source: 20260419000100_fix_notification_triggers.sql
-- Fix notify_new_order and notify_order_status_changed to avoid DECLARE/SELECT INTO
-- which can be misinterpreted by the Supabase SQL editor.
-- Rewritten to use INSERT ... SELECT with direct joins, no intermediate variables.

CREATE OR REPLACE FUNCTION public.notify_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    w.owner_id,
    'new_order',
    'New order received',
    'Order #' || NEW.order_number || ' from ' || COALESCE(ph.name, 'a pharmacy') ||
      ' — GHS ' || to_char(NEW.total_ghs, 'FM999,999.00'),
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number)
  FROM public.businesses w
  LEFT JOIN public.businesses ph ON ph.id = NEW.pharmacy_id
  WHERE w.id = NEW.wholesaler_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_new_order ON public.orders;
CREATE TRIGGER trg_notify_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_new_order();

CREATE OR REPLACE FUNCTION public.notify_order_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.notifications(user_id, type, title, body, metadata)
  SELECT
    ph.owner_id,
    'order_status',
    'Order update',
    'Your order #' || NEW.order_number || ' from ' || COALESCE(w.name, 'your wholesaler') ||
      ' is now ' || CASE NEW.status
        WHEN 'accepted'   THEN 'accepted'
        WHEN 'packed'     THEN 'packed and ready'
        WHEN 'dispatched' THEN 'out for delivery'
        WHEN 'delivered'  THEN 'delivered'
        WHEN 'cancelled'  THEN 'cancelled'
        ELSE NEW.status::TEXT
      END || '.',
    jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number, 'status', NEW.status)
  FROM public.businesses ph
  LEFT JOIN public.businesses w ON w.id = NEW.wholesaler_id
  WHERE ph.id = NEW.pharmacy_id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_order_status ON public.orders;
CREATE TRIGGER trg_notify_order_status
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_order_status_changed();

-- Source: 20260419000200_bootstrap_business_on_signup.sql
-- Create the business record during auth signup so email-confirmation flows
-- still land in a usable workspace without relying on an immediate client insert.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
BEGIN
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), ''),
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  signup_role := COALESCE((NEW.raw_user_meta_data->>'role')::public.app_role, 'pharmacy');

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  END IF;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
    );
  END IF;

  RETURN NEW;
END;
$$;

INSERT INTO public.businesses (
  owner_id,
  type,
  name,
  license_number,
  city,
  region,
  phone
)
SELECT
  u.id,
  (u.raw_user_meta_data->>'role')::public.business_type,
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'business_name', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'license_number', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'city', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'region', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'phone', '')), '')
FROM auth.users u
WHERE COALESCE(u.raw_user_meta_data->>'role', '') IN ('pharmacy', 'wholesaler')
  AND NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'business_name', '')), '') IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.owner_id = u.id
  );

-- Source: 20260420000000_staff_invite_guard.sql
-- Guard handle_new_user() so staff invites skip role + business creation.
-- When admin.inviteUserByEmail sets is_staff_invite = true in metadata,
-- we only create the profile row and return early.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
BEGIN
  -- Always create / update the profile row
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), ''),
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  -- Staff invites: skip role assignment and business creation
  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('admin', 'pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  END IF;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Efficient email-to-user-id lookup for the staff invite API.
-- SECURITY DEFINER so it can read auth.users; only granted to service_role.
CREATE OR REPLACE FUNCTION public.lookup_user_id_by_email(_email TEXT)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM auth.users WHERE lower(email) = lower(trim(_email)) LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_user_id_by_email(TEXT) TO service_role;

-- Allow users to read their own business_staff rows (needed for pending-invite UX).
DROP POLICY IF EXISTS "Users view own staff memberships" ON public.business_staff;
CREATE POLICY "Users view own staff memberships"
  ON public.business_staff
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- Source: 20260421020000_add_platform_staff.sql
-- Separate platform admin staff from business workspace staff.
-- Platform staff drive /admin access; business staff stay tied to business workspaces.

DO $$
BEGIN
  CREATE TYPE public.platform_staff_role AS ENUM ('owner', 'admin');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.platform_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  role public.platform_staff_role NOT NULL DEFAULT 'admin',
  status public.staff_status NOT NULL DEFAULT 'pending',
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  invited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_platform_staff_user ON public.platform_staff(user_id);
CREATE INDEX IF NOT EXISTS idx_platform_staff_status ON public.platform_staff(status);

ALTER TABLE public.platform_staff ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_platform_staff(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.platform_staff
    WHERE user_id = _user_id
      AND status = 'active'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_platform_owner(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.platform_staff
    WHERE user_id = _user_id
      AND role = 'owner'
      AND status = 'active'
  )
$$;

DROP POLICY IF EXISTS "View platform staff" ON public.platform_staff;
CREATE POLICY "View platform staff"
  ON public.platform_staff
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_platform_staff(auth.uid())
    OR public.has_role(auth.uid(), 'admin')
  );

DROP POLICY IF EXISTS "Owners add platform staff" ON public.platform_staff;
CREATE POLICY "Owners add platform staff"
  ON public.platform_staff
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_platform_owner(auth.uid()));

DROP POLICY IF EXISTS "Owners manage platform staff" ON public.platform_staff;
CREATE POLICY "Owners manage platform staff"
  ON public.platform_staff
  FOR UPDATE
  TO authenticated
  USING (public.is_platform_owner(auth.uid()))
  WITH CHECK (public.is_platform_owner(auth.uid()));

DROP POLICY IF EXISTS "Owners remove platform staff" ON public.platform_staff;
CREATE POLICY "Owners remove platform staff"
  ON public.platform_staff
  FOR DELETE
  TO authenticated
  USING (public.is_platform_owner(auth.uid()));

DROP TRIGGER IF EXISTS trg_platform_staff_updated ON public.platform_staff;
CREATE TRIGGER trg_platform_staff_updated
  BEFORE UPDATE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.sync_platform_staff_admin_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.user_roles
    WHERE user_id = OLD.user_id
      AND role = 'admin'
      AND NOT EXISTS (
        SELECT 1
        FROM public.platform_staff ps
        WHERE ps.user_id = OLD.user_id
          AND ps.status = 'active'
      );

    RETURN OLD;
  END IF;

  IF NEW.status = 'active' THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.user_id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    DELETE FROM public.user_roles
    WHERE user_id = NEW.user_id
      AND role = 'admin'
      AND NOT EXISTS (
        SELECT 1
        FROM public.platform_staff ps
        WHERE ps.user_id = NEW.user_id
          AND ps.id <> NEW.id
          AND ps.status = 'active'
      );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_platform_staff_admin_role ON public.platform_staff;
CREATE TRIGGER trg_sync_platform_staff_admin_role
  AFTER INSERT OR UPDATE OR DELETE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_platform_staff_admin_role();

-- Fresh baseline provisions no platform owner. Use a controlled reviewed bootstrap.

CREATE OR REPLACE FUNCTION public.list_platform_staff()
RETURNS TABLE (
  id UUID,
  user_id UUID,
  role public.platform_staff_role,
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
    public.is_platform_staff(auth.uid())
    OR public.has_role(auth.uid(), 'admin')
  ) THEN
    RAISE EXCEPTION 'Not authorized to view the platform team.';
  END IF;

  RETURN QUERY
  SELECT
    ps.id,
    ps.user_id,
    ps.role,
    ps.status,
    ps.invited_at,
    ps.joined_at,
    p.full_name,
    p.phone,
    u.email::TEXT AS user_email
  FROM public.platform_staff ps
  LEFT JOIN public.profiles p ON p.id = ps.user_id
  LEFT JOIN auth.users u ON u.id = ps.user_id
  ORDER BY
    CASE ps.role
      WHEN 'owner' THEN 0
      ELSE 1
    END,
    COALESCE(ps.joined_at, ps.invited_at) DESC,
    ps.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.is_platform_staff(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_platform_owner(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_platform_staff() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_platform_staff(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_platform_owner(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_platform_staff() TO authenticated;

-- Source: 20260421030000_reserve_stock_for_marketplace_orders.sql
-- Reserve wholesaler stock atomically when marketplace orders are created.
-- This prevents partial orders and reduces overselling between pharmacy and wholesaler flows.

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    FOR UPDATE OF p
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    UPDATE public.products
    SET stock = stock - v_product.quantity
    WHERE id = v_product.id;

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN v_order_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.products p
  SET stock = p.stock + oi.quantity
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id
    AND oi.product_id = p.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restore_stock_on_order_cancel ON public.orders;
CREATE TRIGGER trg_restore_stock_on_order_cancel
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.restore_stock_for_cancelled_order();

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_stock_for_cancelled_order() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) TO service_role;

-- Source: 20260421040000_add_pharmacy_superintendent_fields.sql
-- Track whether a pharmacy owner is also the superintendent pharmacist.
-- This keeps signup, admin review, and later edits aligned without duplicating owner names.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS owner_is_superintendent BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS superintendent_name TEXT;

UPDATE public.businesses
SET
  owner_is_superintendent = COALESCE(owner_is_superintendent, true),
  superintendent_name = CASE
    WHEN type <> 'pharmacy' OR COALESCE(owner_is_superintendent, true) THEN NULL
    ELSE NULLIF(BTRIM(superintendent_name), '')
  END
WHERE type IN ('pharmacy', 'wholesaler');

CREATE OR REPLACE FUNCTION public.normalize_business_superintendent_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type <> 'pharmacy' THEN
    NEW.owner_is_superintendent := true;
    NEW.superintendent_name := NULL;
    RETURN NEW;
  END IF;

  NEW.owner_is_superintendent := COALESCE(NEW.owner_is_superintendent, true);
  NEW.superintendent_name := NULLIF(BTRIM(COALESCE(NEW.superintendent_name, '')), '');

  IF NEW.owner_is_superintendent THEN
    NEW.superintendent_name := NULL;
  ELSIF NEW.superintendent_name IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist name is required when the owner is not the superintendent.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_business_superintendent_fields ON public.businesses;
CREATE TRIGGER trg_normalize_business_superintendent_fields
  BEFORE INSERT OR UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_business_superintendent_fields();

ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_pharmacy_superintendent_chk;

ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_pharmacy_superintendent_chk
  CHECK (
    type <> 'pharmacy'
    OR owner_is_superintendent
    OR NULLIF(BTRIM(COALESCE(superintendent_name, '')), '') IS NOT NULL
  );

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
  signup_owner_is_superintendent BOOLEAN;
  signup_superintendent_name TEXT;
BEGIN
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), ''),
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('admin', 'pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  END IF;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');
  signup_owner_is_superintendent := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      THEN COALESCE((NEW.raw_user_meta_data->>'owner_is_superintendent')::BOOLEAN, true)
    ELSE true
  END;
  signup_superintendent_name := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_name', '')),
    ''
  );

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone,
      owner_is_superintendent,
      superintendent_name
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), ''),
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Source: 20260421041000_update_business_context_superintendent_fields.sql
DROP FUNCTION IF EXISTS public.get_user_business_context();

CREATE FUNCTION public.get_user_business_context()
RETURNS TABLE (
  id UUID,
  type public.business_type,
  name TEXT,
  license_number TEXT,
  owner_is_superintendent BOOLEAN,
  superintendent_name TEXT,
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
    b.owner_is_superintendent,
    b.superintendent_name,
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

REVOKE ALL ON FUNCTION public.get_user_business_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_business_context() TO authenticated;

-- Source: 20260421050000_add_order_receipt_tracking.sql
-- Track wholesaler payment confirmation and pharmacy receipt delivery for orders.
-- Receipt emails are sent only after the seller confirms money has been received.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS payment_confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS payment_confirmed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS receipt_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS receipt_sent_to TEXT;

CREATE INDEX IF NOT EXISTS idx_orders_payment_confirmed_by
  ON public.orders(payment_confirmed_by)
  WHERE payment_confirmed_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_orders_receipt_sent_at
  ON public.orders(receipt_sent_at)
  WHERE receipt_sent_at IS NOT NULL;

-- Source: 20260422070000_expand_signup_business_profile.sql
-- Capture richer signup details without exposing internal verification contacts
-- through the marketplace-facing businesses table.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS public_email TEXT,
  ADD COLUMN IF NOT EXISTS working_hours TEXT,
  ADD COLUMN IF NOT EXISTS location_description TEXT;

UPDATE public.businesses AS b
SET
  public_email = COALESCE(
    b.public_email,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'public_email', '')), '')
  ),
  address = COALESCE(
    b.address,
    NULLIF(
      BTRIM(
        COALESCE(
          u.raw_user_meta_data->>'gps_address',
          u.raw_user_meta_data->>'address',
          ''
        )
      ),
      ''
    )
  ),
  working_hours = COALESCE(
    b.working_hours,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'working_hours', '')), '')
  ),
  location_description = COALESCE(
    b.location_description,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'location_description', '')), '')
  )
FROM auth.users AS u
WHERE u.id = b.owner_id;

CREATE TABLE IF NOT EXISTS public.business_private_contacts (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  owner_full_name TEXT,
  owner_phone TEXT,
  owner_email TEXT,
  superintendent_full_name TEXT,
  superintendent_phone TEXT,
  superintendent_email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.business_private_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners view own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners view own private business contacts"
  ON public.business_private_contacts
  FOR SELECT
  USING (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owners insert own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners insert own private business contacts"
  ON public.business_private_contacts
  FOR INSERT
  WITH CHECK (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owners update own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners update own private business contacts"
  ON public.business_private_contacts
  FOR UPDATE
  USING (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP TRIGGER IF EXISTS trg_business_private_contacts_updated ON public.business_private_contacts;
CREATE TRIGGER trg_business_private_contacts_updated
  BEFORE UPDATE ON public.business_private_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

INSERT INTO public.business_private_contacts (
  business_id,
  owner_full_name,
  owner_phone,
  owner_email,
  superintendent_full_name,
  superintendent_phone,
  superintendent_email
)
SELECT
  b.id,
  p.full_name,
  p.phone,
  u.email,
  CASE
    WHEN b.type <> 'pharmacy' THEN NULL
    WHEN b.owner_is_superintendent THEN p.full_name
    ELSE b.superintendent_name
  END,
  CASE
    WHEN b.type = 'pharmacy' AND b.owner_is_superintendent THEN p.phone
    ELSE NULL
  END,
  CASE
    WHEN b.type = 'pharmacy' AND b.owner_is_superintendent THEN u.email
    ELSE NULL
  END
FROM public.businesses AS b
JOIN auth.users AS u
  ON u.id = b.owner_id
LEFT JOIN public.profiles AS p
  ON p.id = b.owner_id
ON CONFLICT (business_id) DO UPDATE
SET
  owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
  owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
  owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
  superintendent_full_name = COALESCE(
    EXCLUDED.superintendent_full_name,
    public.business_private_contacts.superintendent_full_name
  ),
  superintendent_phone = COALESCE(
    EXCLUDED.superintendent_phone,
    public.business_private_contacts.superintendent_phone
  ),
  superintendent_email = COALESCE(
    EXCLUDED.superintendent_email,
    public.business_private_contacts.superintendent_email
  ),
  updated_at = now();

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
  signup_owner_is_superintendent BOOLEAN;
  signup_superintendent_name TEXT;
  signup_owner_full_name TEXT;
  signup_owner_phone TEXT;
  signup_public_phone TEXT;
  signup_public_email TEXT;
  signup_gps_address TEXT;
  signup_location_description TEXT;
  signup_working_hours TEXT;
  signup_superintendent_phone TEXT;
  signup_superintendent_email TEXT;
  created_business_id UUID;
BEGIN
  signup_owner_full_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), '');
  signup_owner_phone := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '');

  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    signup_owner_full_name,
    signup_owner_phone
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('admin', 'pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  END IF;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');
  signup_owner_is_superintendent := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      THEN COALESCE((NEW.raw_user_meta_data->>'owner_is_superintendent')::BOOLEAN, true)
    ELSE true
  END;
  signup_superintendent_name := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_name', '')),
    ''
  );
  signup_public_phone := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'public_phone',
        NEW.raw_user_meta_data->>'phone',
        ''
      )
    ),
    ''
  );
  signup_public_email := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'public_email', '')), '');
  signup_gps_address := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'gps_address',
        NEW.raw_user_meta_data->>'address',
        ''
      )
    ),
    ''
  );
  signup_location_description := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'location_description', '')),
    ''
  );
  signup_working_hours := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'working_hours', '')), '');
  signup_superintendent_phone := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_phone', '')),
    ''
  );
  signup_superintendent_email := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_email', '')),
    ''
  );

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone,
      address,
      public_email,
      working_hours,
      location_description,
      owner_is_superintendent,
      superintendent_name
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      signup_public_phone,
      signup_gps_address,
      signup_public_email,
      signup_working_hours,
      signup_location_description,
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    )
    RETURNING id INTO created_business_id;

    INSERT INTO public.business_private_contacts (
      business_id,
      owner_full_name,
      owner_phone,
      owner_email,
      superintendent_full_name,
      superintendent_phone,
      superintendent_email
    )
    VALUES (
      created_business_id,
      signup_owner_full_name,
      signup_owner_phone,
      NULLIF(BTRIM(COALESCE(NEW.email, '')), ''),
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_full_name
        ELSE signup_superintendent_name
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_phone
        ELSE signup_superintendent_phone
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(NEW.email, '')), '')
        ELSE signup_superintendent_email
      END
    )
    ON CONFLICT (business_id) DO UPDATE
      SET owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
          owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
          owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
          superintendent_full_name = COALESCE(
            EXCLUDED.superintendent_full_name,
            public.business_private_contacts.superintendent_full_name
          ),
          superintendent_phone = COALESCE(
            EXCLUDED.superintendent_phone,
            public.business_private_contacts.superintendent_phone
          ),
          superintendent_email = COALESCE(
            EXCLUDED.superintendent_email,
            public.business_private_contacts.superintendent_email
          ),
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;

-- Source: 20260422073000_enforce_business_private_contacts.sql
-- Enforce normalization and completeness for private business contacts.
-- Existing incomplete pharmacy rows can still be corrected in the admin UI,
-- but all new and updated records should remain valid.

CREATE OR REPLACE FUNCTION public.normalize_ghana_phone(raw_phone TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  sanitized TEXT;
  national_number TEXT;
BEGIN
  sanitized := regexp_replace(COALESCE(raw_phone, ''), '\s+', '', 'g');
  sanitized := regexp_replace(sanitized, '[^0-9+]', '', 'g');

  IF sanitized = '' THEN
    RETURN NULL;
  END IF;

  IF sanitized LIKE '+233%' THEN
    national_number := regexp_replace(substr(sanitized, 5), '\D', '', 'g');
  ELSIF sanitized LIKE '233%' THEN
    national_number := regexp_replace(substr(sanitized, 4), '\D', '', 'g');
  ELSIF sanitized LIKE '0%' THEN
    national_number := regexp_replace(substr(sanitized, 2), '\D', '', 'g');
  ELSE
    national_number := regexp_replace(sanitized, '\D', '', 'g');
  END IF;

  IF length(national_number) = 10 AND left(national_number, 1) = '0' THEN
    national_number := substr(national_number, 2);
  END IF;

  IF length(national_number) <> 9 THEN
    RAISE EXCEPTION 'Enter a valid Ghana phone number.';
  END IF;

  RETURN '+233' || national_number;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_business_private_contacts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  related_business public.businesses%ROWTYPE;
  fallback_owner_name TEXT;
  fallback_owner_phone_raw TEXT;
  fallback_owner_phone TEXT;
  fallback_owner_email TEXT;
BEGIN
  SELECT b.*
  INTO related_business
  FROM public.businesses AS b
  WHERE b.id = NEW.business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business % does not exist.', NEW.business_id;
  END IF;

  SELECT
    NULLIF(BTRIM(COALESCE(p.full_name, '')), ''),
    NULLIF(BTRIM(COALESCE(p.phone, '')), ''),
    NULLIF(LOWER(BTRIM(COALESCE(u.email, ''))), '')
  INTO
    fallback_owner_name,
    fallback_owner_phone_raw,
    fallback_owner_email
  FROM auth.users AS u
  LEFT JOIN public.profiles AS p
    ON p.id = u.id
  WHERE u.id = related_business.owner_id;

  BEGIN
    fallback_owner_phone := public.normalize_ghana_phone(fallback_owner_phone_raw);
  EXCEPTION
    WHEN OTHERS THEN
      fallback_owner_phone := NULL;
  END;

  NEW.owner_full_name := COALESCE(
    NULLIF(BTRIM(COALESCE(NEW.owner_full_name, '')), ''),
    fallback_owner_name
  );
  NEW.owner_phone := COALESCE(
    public.normalize_ghana_phone(NEW.owner_phone),
    fallback_owner_phone
  );
  NEW.owner_email := COALESCE(
    NULLIF(LOWER(BTRIM(COALESCE(NEW.owner_email, ''))), ''),
    fallback_owner_email
  );
  NEW.superintendent_full_name := NULLIF(BTRIM(COALESCE(NEW.superintendent_full_name, '')), '');
  NEW.superintendent_phone := public.normalize_ghana_phone(NEW.superintendent_phone);
  NEW.superintendent_email := NULLIF(
    LOWER(BTRIM(COALESCE(NEW.superintendent_email, ''))),
    ''
  );

  IF NEW.owner_full_name IS NULL THEN
    RAISE EXCEPTION 'Owner full name is required.';
  END IF;

  IF NEW.owner_phone IS NULL THEN
    RAISE EXCEPTION 'Owner phone number is required.';
  END IF;

  IF NEW.owner_email IS NULL THEN
    RAISE EXCEPTION 'Owner email address is required.';
  END IF;

  IF NEW.owner_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Owner email address is invalid.';
  END IF;

  IF related_business.type <> 'pharmacy' THEN
    NEW.superintendent_full_name := NULL;
    NEW.superintendent_phone := NULL;
    NEW.superintendent_email := NULL;
    RETURN NEW;
  END IF;

  IF related_business.owner_is_superintendent THEN
    NEW.superintendent_full_name := NEW.owner_full_name;
    NEW.superintendent_phone := NEW.owner_phone;
    NEW.superintendent_email := NEW.owner_email;
    RETURN NEW;
  END IF;

  IF NEW.superintendent_full_name IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist full name is required.';
  END IF;

  IF NEW.superintendent_phone IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist phone number is required.';
  END IF;

  IF NEW.superintendent_email IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist email address is required.';
  END IF;

  IF NEW.superintendent_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Superintendent pharmacist email address is invalid.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_business_private_contacts ON public.business_private_contacts;
CREATE TRIGGER trg_normalize_business_private_contacts
  BEFORE INSERT OR UPDATE ON public.business_private_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_business_private_contacts();

UPDATE public.business_private_contacts AS c
SET
  owner_full_name = c.owner_full_name,
  owner_phone = c.owner_phone,
  owner_email = c.owner_email,
  superintendent_full_name = COALESCE(c.superintendent_full_name, c.owner_full_name),
  superintendent_phone = COALESCE(c.superintendent_phone, c.owner_phone),
  superintendent_email = COALESCE(c.superintendent_email, c.owner_email)
FROM public.businesses AS b
WHERE b.id = c.business_id
  AND (b.type <> 'pharmacy' OR b.owner_is_superintendent);

-- Source: 20260422080000_add_atomic_business_profile_update_rpc.sql
-- Update the public business profile and private verification contacts in one
-- transaction so admin edits cannot leave the two records out of sync.

CREATE OR REPLACE FUNCTION public.update_business_profile_with_contacts(
  _business_id UUID,
  _name TEXT,
  _license_number TEXT,
  _owner_is_superintendent BOOLEAN,
  _superintendent_name TEXT,
  _city TEXT,
  _region TEXT,
  _phone TEXT,
  _address TEXT,
  _public_email TEXT,
  _working_hours TEXT,
  _location_description TEXT,
  _owner_full_name TEXT,
  _owner_phone TEXT,
  _owner_email TEXT,
  _superintendent_phone TEXT,
  _superintendent_email TEXT
)
RETURNS TABLE (
  business_id UUID,
  owner_full_name TEXT,
  owner_phone TEXT,
  owner_email TEXT,
  superintendent_full_name TEXT,
  superintendent_phone TEXT,
  superintendent_email TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  related_business public.businesses%ROWTYPE;
  trimmed_business_name TEXT;
  normalized_public_email TEXT;
  effective_owner_is_superintendent BOOLEAN;
  effective_superintendent_name TEXT;
  effective_owner_email TEXT;
  effective_superintendent_email TEXT;
  effective_superintendent_phone TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to update business details.';
  END IF;

  SELECT b.*
  INTO related_business
  FROM public.businesses AS b
  WHERE b.id = _business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business % does not exist.', _business_id;
  END IF;

  IF NOT (
    public.has_role(auth.uid(), 'admin')
    OR related_business.owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to update this business.';
  END IF;

  trimmed_business_name := NULLIF(BTRIM(COALESCE(_name, '')), '');
  IF trimmed_business_name IS NULL THEN
    RAISE EXCEPTION 'Business name is required.';
  END IF;

  normalized_public_email := NULLIF(LOWER(BTRIM(COALESCE(_public_email, ''))), '');
  IF normalized_public_email IS NOT NULL
    AND normalized_public_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Public business email address is invalid.';
  END IF;

  effective_owner_is_superintendent := CASE
    WHEN related_business.type = 'pharmacy' THEN COALESCE(_owner_is_superintendent, true)
    ELSE true
  END;

  effective_superintendent_name := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(_owner_full_name, '')), '')
    ELSE NULLIF(BTRIM(COALESCE(_superintendent_name, '')), '')
  END;

  effective_owner_email := NULLIF(LOWER(BTRIM(COALESCE(_owner_email, ''))), '');
  effective_superintendent_email := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN effective_owner_email
    ELSE NULLIF(LOWER(BTRIM(COALESCE(_superintendent_email, ''))), '')
  END;

  effective_superintendent_phone := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN _owner_phone
    ELSE _superintendent_phone
  END;

  UPDATE public.businesses
  SET
    name = trimmed_business_name,
    license_number = NULLIF(BTRIM(COALESCE(_license_number, '')), ''),
    owner_is_superintendent = effective_owner_is_superintendent,
    superintendent_name = CASE
      WHEN related_business.type = 'pharmacy' AND NOT effective_owner_is_superintendent
        THEN effective_superintendent_name
      ELSE NULL
    END,
    city = NULLIF(BTRIM(COALESCE(_city, '')), ''),
    region = NULLIF(BTRIM(COALESCE(_region, '')), ''),
    phone = public.normalize_ghana_phone(_phone),
    address = NULLIF(BTRIM(COALESCE(_address, '')), ''),
    public_email = normalized_public_email,
    working_hours = NULLIF(BTRIM(COALESCE(_working_hours, '')), ''),
    location_description = NULLIF(BTRIM(COALESCE(_location_description, '')), '')
  WHERE id = _business_id;

  RETURN QUERY
  INSERT INTO public.business_private_contacts (
    business_id,
    owner_full_name,
    owner_phone,
    owner_email,
    superintendent_full_name,
    superintendent_phone,
    superintendent_email
  )
  VALUES (
    _business_id,
    NULLIF(BTRIM(COALESCE(_owner_full_name, '')), ''),
    _owner_phone,
    effective_owner_email,
    effective_superintendent_name,
    effective_superintendent_phone,
    effective_superintendent_email
  )
  ON CONFLICT (business_id) DO UPDATE
  SET
    owner_full_name = EXCLUDED.owner_full_name,
    owner_phone = EXCLUDED.owner_phone,
    owner_email = EXCLUDED.owner_email,
    superintendent_full_name = EXCLUDED.superintendent_full_name,
    superintendent_phone = EXCLUDED.superintendent_phone,
    superintendent_email = EXCLUDED.superintendent_email
  RETURNING
    public.business_private_contacts.business_id,
    public.business_private_contacts.owner_full_name,
    public.business_private_contacts.owner_phone,
    public.business_private_contacts.owner_email,
    public.business_private_contacts.superintendent_full_name,
    public.business_private_contacts.superintendent_phone,
    public.business_private_contacts.superintendent_email;
END;
$$;

REVOKE ALL ON FUNCTION public.update_business_profile_with_contacts(
  UUID,
  TEXT,
  TEXT,
  BOOLEAN,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.update_business_profile_with_contacts(
  UUID,
  TEXT,
  TEXT,
  BOOLEAN,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) TO authenticated;

-- Source: 20260422083000_expand_get_user_business_context.sql
-- Keep get_user_business_context() aligned with the richer business profile
-- shape so any RPC consumers receive the same fields as direct table queries.

DROP FUNCTION IF EXISTS public.get_user_business_context();

CREATE FUNCTION public.get_user_business_context()
RETURNS TABLE (
  id UUID,
  type public.business_type,
  name TEXT,
  license_number TEXT,
  owner_is_superintendent BOOLEAN,
  superintendent_name TEXT,
  city TEXT,
  region TEXT,
  phone TEXT,
  address TEXT,
  public_email TEXT,
  working_hours TEXT,
  location_description TEXT,
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
    b.owner_is_superintendent,
    b.superintendent_name,
    b.city,
    b.region,
    b.phone,
    b.address,
    b.public_email,
    b.working_hours,
    b.location_description,
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

REVOKE ALL ON FUNCTION public.get_user_business_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_business_context() TO authenticated;

-- Source: 20260422143000_protect_platform_owner_details.sql
-- Keep the platform owner visible in the roster while preventing other
-- platform admins from reading the owner's personal contact details.

CREATE OR REPLACE FUNCTION public.list_platform_staff()
RETURNS TABLE (
  id UUID,
  user_id UUID,
  role public.platform_staff_role,
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
DECLARE
  viewer_is_platform_owner BOOLEAN;
BEGIN
  IF NOT public.is_platform_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to view the platform team.';
  END IF;

  viewer_is_platform_owner := public.is_platform_owner(auth.uid());

  RETURN QUERY
  SELECT
    ps.id,
    ps.user_id,
    ps.role,
    ps.status,
    ps.invited_at,
    ps.joined_at,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE p.full_name
    END AS full_name,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE p.phone
    END AS phone,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE u.email::TEXT
    END AS user_email
  FROM public.platform_staff AS ps
  LEFT JOIN public.profiles AS p
    ON p.id = ps.user_id
  LEFT JOIN auth.users AS u
    ON u.id = ps.user_id
  ORDER BY
    CASE ps.role
      WHEN 'owner' THEN 0
      ELSE 1
    END,
    COALESCE(ps.joined_at, ps.invited_at) DESC,
    ps.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_platform_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_platform_staff() TO authenticated;

-- Source: 20260422150000_hide_platform_owner_from_other_admins.sql
-- Remove the platform owner entirely from the platform team roster for
-- non-owner admins. The owner should only be visible to themself.

CREATE OR REPLACE FUNCTION public.list_platform_staff()
RETURNS TABLE (
  id UUID,
  user_id UUID,
  role public.platform_staff_role,
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
DECLARE
  viewer_is_platform_owner BOOLEAN;
BEGIN
  IF NOT public.is_platform_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to view the platform team.';
  END IF;

  viewer_is_platform_owner := public.is_platform_owner(auth.uid());

  RETURN QUERY
  SELECT
    ps.id,
    ps.user_id,
    ps.role,
    ps.status,
    ps.invited_at,
    ps.joined_at,
    p.full_name,
    p.phone,
    u.email::TEXT AS user_email
  FROM public.platform_staff AS ps
  LEFT JOIN public.profiles AS p
    ON p.id = ps.user_id
  LEFT JOIN auth.users AS u
    ON u.id = ps.user_id
  WHERE viewer_is_platform_owner
    OR ps.role <> 'owner'
  ORDER BY
    CASE ps.role
      WHEN 'owner' THEN 0
      ELSE 1
    END,
    COALESCE(ps.joined_at, ps.invited_at) DESC,
    ps.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_platform_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_platform_staff() TO authenticated;

-- Source: 20260422170000_enforce_license_document_replacement.sql
CREATE UNIQUE INDEX IF NOT EXISTS license_documents_business_doc_type_uniq
  ON public.license_documents (business_id, doc_type);

DROP POLICY IF EXISTS "Owners update own docs" ON public.license_documents;
CREATE POLICY "Owners update own docs"
  ON public.license_documents
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.businesses AS b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.businesses AS b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Users delete own license docs" ON storage.objects;
CREATE POLICY "Users delete own license docs"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'licenses'
    AND auth.uid()::TEXT = (storage.foldername(name))[1]
  );

-- Source: 20260422171000_add_import_wholesaler_products_rpc.sql
CREATE UNIQUE INDEX IF NOT EXISTS products_wholesaler_identity_uniq
  ON public.products (
    wholesaler_id,
    lower(BTRIM(name)),
    COALESCE(lower(BTRIM(brand)), ''),
    COALESCE(lower(BTRIM(form)), ''),
    COALESCE(lower(BTRIM(pack_size)), '')
  );

CREATE OR REPLACE FUNCTION public.import_wholesaler_products(
  _business_id UUID,
  _products JSONB
)
RETURNS TABLE (
  inserted_count INTEGER,
  updated_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  related_business public.businesses%ROWTYPE;
  caller_staff_role public.staff_role;
  inserted_total INTEGER := 0;
  updated_total INTEGER := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to import products.';
  END IF;

  IF jsonb_typeof(COALESCE(_products, '[]'::JSONB)) <> 'array' THEN
    RAISE EXCEPTION 'Products payload must be a JSON array.';
  END IF;

  SELECT b.*
  INTO related_business
  FROM public.businesses AS b
  WHERE b.id = _business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business % does not exist.', _business_id;
  END IF;

  IF related_business.type <> 'wholesaler' THEN
    RAISE EXCEPTION 'Only wholesaler businesses can import products.';
  END IF;

  IF related_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your wholesaler account must be approved before importing products.';
  END IF;

  caller_staff_role := public.get_staff_role(auth.uid(), _business_id);

  IF NOT (
    related_business.owner_id = auth.uid()
    OR caller_staff_role IN ('owner'::public.staff_role, 'manager'::public.staff_role)
  ) THEN
    RAISE EXCEPTION 'Not authorized to import products for this wholesaler.';
  END IF;

  IF jsonb_array_length(COALESCE(_products, '[]'::JSONB)) = 0 THEN
    RETURN QUERY SELECT 0, 0;
    RETURN;
  END IF;

  CREATE TEMP TABLE tmp_import_products (
    ord BIGINT NOT NULL,
    name TEXT NOT NULL,
    brand TEXT,
    category TEXT NOT NULL,
    form TEXT NOT NULL,
    pack_size TEXT,
    price_ghs NUMERIC(10,2) NOT NULL,
    stock INTEGER NOT NULL,
    image_hue INTEGER NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO tmp_import_products (
    ord,
    name,
    brand,
    category,
    form,
    pack_size,
    price_ghs,
    stock,
    image_hue
  )
  SELECT
    imported.ord,
    NULLIF(BTRIM(COALESCE(imported.value->>'name', '')), '') AS name,
    NULLIF(BTRIM(COALESCE(imported.value->>'brand', '')), '') AS brand,
    COALESCE(NULLIF(BTRIM(COALESCE(imported.value->>'category', '')), ''), 'Other') AS category,
    COALESCE(NULLIF(BTRIM(COALESCE(imported.value->>'form', '')), ''), 'Tablet') AS form,
    NULLIF(BTRIM(COALESCE(imported.value->>'pack_size', '')), '') AS pack_size,
    NULLIF(BTRIM(COALESCE(imported.value->>'price_ghs', '')), '')::NUMERIC(10,2) AS price_ghs,
    COALESCE(NULLIF(BTRIM(COALESCE(imported.value->>'stock', '')), '')::INTEGER, 0) AS stock,
    COALESCE(NULLIF(BTRIM(COALESCE(imported.value->>'image_hue', '')), '')::INTEGER, 200) AS image_hue
  FROM jsonb_array_elements(COALESCE(_products, '[]'::JSONB)) WITH ORDINALITY AS imported(value, ord);

  IF EXISTS (
    SELECT 1
    FROM tmp_import_products
    WHERE name IS NULL
      OR price_ghs IS NULL
      OR price_ghs <= 0
      OR stock < 0
  ) THEN
    RAISE EXCEPTION 'Every imported product needs a name, a positive price, and non-negative stock.';
  END IF;

  DELETE FROM tmp_import_products AS earlier
  USING tmp_import_products AS later
  WHERE earlier.ord < later.ord
    AND lower(BTRIM(earlier.name)) = lower(BTRIM(later.name))
    AND COALESCE(lower(BTRIM(earlier.brand)), '') = COALESCE(lower(BTRIM(later.brand)), '')
    AND COALESCE(lower(BTRIM(earlier.form)), '') = COALESCE(lower(BTRIM(later.form)), '')
    AND COALESCE(lower(BTRIM(earlier.pack_size)), '') = COALESCE(lower(BTRIM(later.pack_size)), '');

  UPDATE public.products AS p
  SET
    name = imported.name,
    brand = imported.brand,
    category = imported.category,
    form = imported.form,
    pack_size = imported.pack_size,
    price_ghs = imported.price_ghs,
    stock = imported.stock,
    image_hue = imported.image_hue,
    active = TRUE
  FROM tmp_import_products AS imported
  WHERE p.wholesaler_id = _business_id
    AND lower(BTRIM(p.name)) = lower(BTRIM(imported.name))
    AND COALESCE(lower(BTRIM(p.brand)), '') = COALESCE(lower(BTRIM(imported.brand)), '')
    AND COALESCE(lower(BTRIM(p.form)), '') = COALESCE(lower(BTRIM(imported.form)), '')
    AND COALESCE(lower(BTRIM(p.pack_size)), '') = COALESCE(lower(BTRIM(imported.pack_size)), '');

  GET DIAGNOSTICS updated_total = ROW_COUNT;

  INSERT INTO public.products (
    wholesaler_id,
    name,
    brand,
    category,
    form,
    pack_size,
    price_ghs,
    stock,
    image_hue,
    active
  )
  SELECT
    _business_id,
    imported.name,
    imported.brand,
    imported.category,
    imported.form,
    imported.pack_size,
    imported.price_ghs,
    imported.stock,
    imported.image_hue,
    TRUE
  FROM tmp_import_products AS imported
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.products AS p
    WHERE p.wholesaler_id = _business_id
      AND lower(BTRIM(p.name)) = lower(BTRIM(imported.name))
      AND COALESCE(lower(BTRIM(p.brand)), '') = COALESCE(lower(BTRIM(imported.brand)), '')
      AND COALESCE(lower(BTRIM(p.form)), '') = COALESCE(lower(BTRIM(imported.form)), '')
      AND COALESCE(lower(BTRIM(p.pack_size)), '') = COALESCE(lower(BTRIM(imported.pack_size)), '')
  );

  GET DIAGNOSTICS inserted_total = ROW_COUNT;

  RETURN QUERY SELECT inserted_total, updated_total;
END;
$$;

REVOKE ALL ON FUNCTION public.import_wholesaler_products(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.import_wholesaler_products(UUID, JSONB) TO authenticated;

-- Source: 20260505090000_add_audit_logs.sql
-- Platform audit log for admin activity visibility.
-- Captures actor and request IP where Supabase request context is available.

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  activity TEXT NOT NULL,
  organization TEXT,
  performed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  performed_by_email TEXT,
  record_type TEXT NOT NULL,
  record_id UUID,
  record_label TEXT,
  ip_address TEXT,
  details JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at
  ON public.audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_record
  ON public.audit_logs(record_type, record_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_performed_by
  ON public.audit_logs(performed_by, created_at DESC)
  WHERE performed_by IS NOT NULL;

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins see audit logs" ON public.audit_logs;
CREATE POLICY "Admins see audit logs"
  ON public.audit_logs
  FOR SELECT
  USING (public.has_role(auth.uid(), 'admin'));

REVOKE ALL ON public.audit_logs FROM PUBLIC;
GRANT SELECT ON public.audit_logs TO authenticated;
GRANT INSERT ON public.audit_logs TO service_role;

CREATE OR REPLACE FUNCTION public.current_request_ip_address()
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  request_headers JSONB;
  forwarded_for TEXT;
BEGIN
  request_headers := COALESCE(NULLIF(current_setting('request.headers', true), '')::JSONB, '{}'::JSONB);
  forwarded_for := NULLIF(BTRIM(request_headers->>'x-forwarded-for'), '');

  IF forwarded_for IS NOT NULL THEN
    RETURN NULLIF(BTRIM(split_part(forwarded_for, ',', 1)), '');
  END IF;

  RETURN COALESCE(
    NULLIF(BTRIM(request_headers->>'cf-connecting-ip'), ''),
    NULLIF(BTRIM(request_headers->>'x-real-ip'), '')
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.current_actor_email()
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT email
  FROM auth.users
  WHERE id = auth.uid()
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.write_audit_log(
  _activity TEXT,
  _organization TEXT,
  _record_type TEXT,
  _record_id UUID,
  _record_label TEXT,
  _details JSONB DEFAULT '{}'::JSONB,
  _performed_by UUID DEFAULT auth.uid(),
  _performed_by_email TEXT DEFAULT public.current_actor_email(),
  _ip_address TEXT DEFAULT public.current_request_ip_address()
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.audit_logs (
    activity,
    organization,
    performed_by,
    performed_by_email,
    record_type,
    record_id,
    record_label,
    ip_address,
    details
  )
  VALUES (
    _activity,
    _organization,
    _performed_by,
    _performed_by_email,
    _record_type,
    _record_id,
    _record_label,
    _ip_address,
    COALESCE(_details, '{}'::JSONB)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.audit_business_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      CASE WHEN NEW.type = 'pharmacy' THEN 'Pharmacy submitted' ELSE 'Wholesaler submitted' END,
      NEW.name,
      'business',
      NEW.id,
      COALESCE(NEW.license_number, NEW.id::TEXT),
      jsonb_build_object(
        'business_type', NEW.type,
        'city', NEW.city,
        'region', NEW.region,
        'verification_status', NEW.verification_status
      ),
      NEW.owner_id,
      NULL,
      public.current_request_ip_address()
    );
    RETURN NEW;
  END IF;

  IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
    PERFORM public.write_audit_log(
      CASE
        WHEN NEW.verification_status = 'approved' THEN 'Business approved'
        WHEN NEW.verification_status = 'rejected' THEN 'Business rejected'
        ELSE 'Business verification updated'
      END,
      NEW.name,
      'business',
      NEW.id,
      COALESCE(NEW.license_number, NEW.id::TEXT),
      jsonb_build_object(
        'from_status', OLD.verification_status,
        'to_status', NEW.verification_status,
        'rejection_reason', NEW.rejection_reason
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_business_changes ON public.businesses;
CREATE TRIGGER trg_audit_business_changes
  AFTER INSERT OR UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_business_changes();

CREATE OR REPLACE FUNCTION public.audit_order_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  pharmacy_name TEXT;
  wholesaler_name TEXT;
BEGIN
  SELECT name INTO pharmacy_name FROM public.businesses WHERE id = NEW.pharmacy_id;
  SELECT name INTO wholesaler_name FROM public.businesses WHERE id = NEW.wholesaler_id;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Order placed',
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'status', NEW.status,
        'payment_status', NEW.payment_status,
        'payment_method', NEW.payment_method,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name
      )
    );
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Order ' || NEW.status::TEXT,
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'from_status', OLD.status,
        'to_status', NEW.status,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name,
        'cancellation_reason', NEW.cancellation_reason
      )
    );
  END IF;

  IF NEW.payment_status IS DISTINCT FROM OLD.payment_status THEN
    PERFORM public.write_audit_log(
      'Payment ' || NEW.payment_status::TEXT,
      COALESCE(pharmacy_name, 'Pharmacy'),
      'order',
      NEW.id,
      NEW.order_number,
      jsonb_build_object(
        'from_payment_status', OLD.payment_status,
        'to_payment_status', NEW.payment_status,
        'total_ghs', NEW.total_ghs,
        'wholesaler', wholesaler_name
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_order_changes ON public.orders;
CREATE TRIGGER trg_audit_order_changes
  AFTER INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_order_changes();

CREATE OR REPLACE FUNCTION public.audit_business_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  business_name TEXT;
  staff_email TEXT;
BEGIN
  SELECT name INTO business_name FROM public.businesses WHERE id = COALESCE(NEW.business_id, OLD.business_id);
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Business staff invited',
      business_name,
      'business_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Business staff updated',
      business_name,
      'business_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_business_staff_changes ON public.business_staff;
CREATE TRIGGER trg_audit_business_staff_changes
  AFTER INSERT OR UPDATE ON public.business_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_business_staff_changes();

CREATE OR REPLACE FUNCTION public.audit_platform_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  staff_email TEXT;
BEGIN
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Platform staff invited',
      'PharmaHub GH',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Platform staff updated',
      'PharmaHub GH',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_platform_staff_changes ON public.platform_staff;
CREATE TRIGGER trg_audit_platform_staff_changes
  AFTER INSERT OR UPDATE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.audit_platform_staff_changes();

-- Source: 20260913090000_safe_wholesaler_import.sql
-- Additive safe-import workflow. Existing products and order references are retained.
-- Old clients must upgrade: the previous RPC bypassed preview and confirmation.
DROP FUNCTION IF EXISTS public.import_wholesaler_products(UUID, JSONB);

CREATE OR REPLACE FUNCTION public.product_import_identity(name TEXT, brand TEXT, form TEXT, pack_size TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE SET search_path = public AS $$
  SELECT jsonb_build_array(
    regexp_replace(lower(coalesce(name, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(brand, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(form, '')), '[^a-z0-9./+%]', '', 'g'),
    regexp_replace(lower(coalesce(pack_size, '')), '[^a-z0-9./+%]', '', 'g')
  )::TEXT
$$;
-- Decimal points remain significant: 2.5 mg must never match 25 mg.
CREATE INDEX products_import_identity_idx ON public.products
  (wholesaler_id, public.product_import_identity(name, brand, form, pack_size));

CREATE TABLE public.product_import_runs (
  id UUID PRIMARY KEY,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  created_by UUID NOT NULL REFERENCES auth.users(id),
  payload_hash TEXT NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.product_import_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_import_runs FROM PUBLIC, authenticated;

CREATE OR REPLACE FUNCTION public.preview_wholesaler_import(
  _business_id UUID, _products JSONB, _mode TEXT,
  _confirm_token TEXT DEFAULT NULL, _request_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_product public.products%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_price NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.product_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = _business_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'wholesaler' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved wholesaler account is required.';
  END IF;
  IF NOT (biz.owner_id = auth.uid() OR COALESCE(public.get_staff_role(auth.uid(), _business_id)::TEXT IN ('owner', 'manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only owners and managers can import products.';
  END IF;
  IF _mode NOT IN ('replace', 'add', 'details') OR _mode IS NULL THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(_products) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected a product array.'; END IF;
  IF jsonb_array_length(_products) = 0 OR jsonb_array_length(_products) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 products at a time.';
  END IF;
  payload_hash := md5(_products::TEXT || _mode || _business_id::TEXT);
  IF _confirm_token IS NOT NULL THEN
    IF _request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    -- Serialize commits against imports, manual edits, and order stock updates.
    -- This short transaction lock also protects missing rows (new products).
    LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.product_import_runs WHERE id = _request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.wholesaler_id <> _business_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(_products) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR nullif(btrim(item->>'name'), '') IS NULL
      OR coalesce(item->>'price_ghs', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      OR (item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$') THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Invalid name, price or stock.'));
      CONTINUE;
    END IF;
    input_price := (item->>'price_ghs')::NUMERIC;
    IF input_price <= 0 OR input_price > 99999999.99 OR COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Price or stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    identity_key := public.product_import_identity(item->>'name', item->>'brand', coalesce(nullif(item->>'form', ''), 'Tablet'), item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated product identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);
    SELECT count(*) INTO matches FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing products match. Resolve the catalogue collision first.'));
      CONTINUE;
    END IF;
    SELECT * INTO old_product FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    new_stock := CASE
      WHEN _mode = 'details' THEN coalesce(old_product.stock, 0)
      WHEN input_stock IS NULL THEN coalesce(old_product.stock, 0)
      WHEN _mode = 'add' THEN coalesce(old_product.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;
    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_product.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_product.id IS NULL THEN 'new' ELSE 'existing' END,
      'before', CASE WHEN old_product.id IS NULL THEN NULL ELSE to_jsonb(old_product) END,
      'price_before', old_product.price_ghs, 'price_after', input_price,
      'stock_before', old_product.stock, 'stock_after', new_stock,
      'product', item
    ));
  END LOOP;
  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', _mode);
  IF _confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF _confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.products (wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, image_hue, active)
      VALUES (_business_id, item->>'name', nullif(btrim(item#>>'{product,brand}'), ''),
        coalesce(nullif(item#>>'{product,category}', ''), 'Other'), coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        nullif(btrim(item#>>'{product,pack_size}'), ''), (item->>'price_after')::NUMERIC, (item->>'stock_after')::INTEGER,
        coalesce((item#>>'{product,image_hue}')::INTEGER, 200), TRUE) RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.products SET name = item->>'name', brand = nullif(btrim(item#>>'{product,brand}'), ''),
        category = coalesce(nullif(item#>>'{product,category}', ''), 'Other'), form = coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        pack_size = nullif(btrim(item#>>'{product,pack_size}'), ''), price_ghs = (item->>'price_after')::NUMERIC,
        stock = (item->>'stock_after')::INTEGER, image_hue = coalesce((item#>>'{product,image_hue}')::INTEGER, 200)
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;
    PERFORM public.write_audit_log('Inventory imported', biz.name, 'product', saved_id, item->>'name',
      jsonb_build_object('request_id', _request_id, 'mode', _mode, 'before', item->'before',
        'after', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = saved_id)));
  END LOOP;
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

-- Source: 20260913100000_master_product_catalogue.sql
-- Phase 2: additive catalogue bridge. Legacy products remain the inventory/order
-- source of truth until the batch/reservation migration is validated separately.
CREATE TABLE public.product_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE public.master_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  identity_key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  generic_name TEXT,
  brand_name TEXT,
  strength TEXT,
  dosage_form TEXT,
  pack_size TEXT,
  category_id UUID REFERENCES public.product_categories(id),
  manufacturer TEXT,
  product_code TEXT UNIQUE,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.wholesaler_products (
  id UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  product_id UUID NOT NULL REFERENCES public.master_products(id),
  selling_price NUMERIC(10,2) NOT NULL,
  minimum_order_quantity INTEGER NOT NULL DEFAULT 1 CHECK (minimum_order_quantity > 0),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  lead_time_days INTEGER CHECK (lead_time_days >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX wholesaler_products_master_idx ON public.wholesaler_products(product_id, wholesaler_id);
-- Do not merge ambiguous legacy rows or infer missing strengths/generics.
CREATE OR REPLACE FUNCTION public.sync_legacy_product_offer()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE category_uuid UUID; master_uuid UUID;
BEGIN
  INSERT INTO public.product_categories(name) VALUES (coalesce(nullif(btrim(NEW.category), ''), 'Other'))
    ON CONFLICT(name) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO category_uuid;
  INSERT INTO public.master_products(identity_key, name, brand_name, dosage_form, pack_size, category_id)
    VALUES (public.product_import_identity(NEW.name, NEW.brand, NEW.form, NEW.pack_size),
      NEW.name, NEW.brand, NEW.form, NEW.pack_size, category_uuid)
    ON CONFLICT(identity_key) DO UPDATE SET identity_key = EXCLUDED.identity_key RETURNING id INTO master_uuid;
  INSERT INTO public.wholesaler_products(id, wholesaler_id, product_id, selling_price, active)
    VALUES (NEW.id, NEW.wholesaler_id, master_uuid, NEW.price_ghs, NEW.active)
    ON CONFLICT(id) DO UPDATE SET wholesaler_id = EXCLUDED.wholesaler_id,
      product_id = EXCLUDED.product_id, selling_price = EXCLUDED.selling_price,
      active = EXCLUDED.active, updated_at = now();
  RETURN NEW;
END;
$$;
CREATE TRIGGER sync_legacy_product_offer AFTER INSERT OR UPDATE OF name, brand, form, pack_size, category, price_ghs, active
  ON public.products FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_product_offer();
-- Deterministic backfill using the lowest legacy UUID for each normalized identity.
INSERT INTO public.product_categories(name)
  SELECT DISTINCT coalesce(nullif(btrim(category), ''), 'Other') FROM public.products ON CONFLICT DO NOTHING;
INSERT INTO public.master_products(identity_key, name, brand_name, dosage_form, pack_size, category_id)
  SELECT DISTINCT ON (public.product_import_identity(p.name, p.brand, p.form, p.pack_size))
    public.product_import_identity(p.name, p.brand, p.form, p.pack_size), p.name, p.brand, p.form, p.pack_size, c.id
  FROM public.products p JOIN public.product_categories c ON c.name = coalesce(nullif(btrim(p.category), ''), 'Other')
  ORDER BY public.product_import_identity(p.name, p.brand, p.form, p.pack_size), p.id;
INSERT INTO public.wholesaler_products(id, wholesaler_id, product_id, selling_price, active)
  SELECT p.id, p.wholesaler_id, m.id, p.price_ghs, p.active FROM public.products p
  JOIN public.master_products m ON m.identity_key = public.product_import_identity(p.name, p.brand, p.form, p.pack_size);
DO $$ BEGIN
  IF (SELECT count(*) FROM public.products) <> (SELECT count(*) FROM public.wholesaler_products) THEN
    RAISE EXCEPTION 'Offer backfill count does not match legacy products.';
  END IF;
END $$;
ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wholesaler_products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read categories" ON public.product_categories FOR SELECT TO authenticated USING (TRUE);
CREATE POLICY "Read active master catalogue" ON public.master_products FOR SELECT TO authenticated USING (active OR public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Read accessible offers" ON public.wholesaler_products FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = wholesaler_products.id));
-- All offer writes go through legacy products during the bridge period.
REVOKE ALL ON public.product_categories, public.master_products, public.wholesaler_products FROM PUBLIC, authenticated;
GRANT SELECT ON public.product_categories, public.master_products, public.wholesaler_products TO authenticated;
GRANT ALL ON public.product_categories, public.master_products, public.wholesaler_products TO service_role;
REVOKE ALL ON FUNCTION public.sync_legacy_product_offer() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.list_marketplace_catalogue()
RETURNS JSONB LANGUAGE SQL STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(entry ORDER BY entry->>'name'), '[]'::JSONB) FROM (
    SELECT jsonb_build_object('id', m.id, 'name', m.name, 'generic_name', m.generic_name,
      'strength', m.strength, 'brand_name', m.brand_name, 'dosage_form', m.dosage_form,
      'pack_size', m.pack_size, 'category', c.name, 'offers', (
        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          'minimum_order_quantity', w.minimum_order_quantity, 'lead_time_days', w.lead_time_days,
          'wholesaler', jsonb_build_object('id', b.id, 'name', b.name, 'city', b.city, 'region', b.region, 'verification_status', b.verification_status)) ORDER BY p.price_ghs, p.id)
        FROM public.wholesaler_products w JOIN public.products p ON p.id = w.id
        JOIN public.businesses b ON b.id = w.wholesaler_id
        WHERE w.product_id = m.id AND w.active AND p.active AND b.verification_status = 'approved'
      )) entry
    FROM public.master_products m LEFT JOIN public.product_categories c ON c.id = m.category_id
    WHERE m.active AND auth.uid() IS NOT NULL
  ) catalogue WHERE entry->'offers' IS NOT NULL AND entry->'offers' <> 'null'::JSONB
$$;
REVOKE ALL ON FUNCTION public.list_marketplace_catalogue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_marketplace_catalogue() TO authenticated;

-- Source: 20260914090000_phase0_production_blockers.sql
-- Phase 0 only. Run the read-only preflight before applying. No historical rows are repaired.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
  signup_owner_is_superintendent BOOLEAN;
  signup_superintendent_name TEXT;
  signup_owner_full_name TEXT;
  signup_owner_phone TEXT;
  signup_public_phone TEXT;
  signup_public_email TEXT;
  signup_gps_address TEXT;
  signup_location_description TEXT;
  signup_working_hours TEXT;
  signup_superintendent_phone TEXT;
  signup_superintendent_email TEXT;
  created_business_id UUID;
BEGIN
  signup_owner_full_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), '');
  signup_owner_phone := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '');

  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    signup_owner_full_name,
    signup_owner_phone
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');
  signup_owner_is_superintendent := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      THEN COALESCE((NEW.raw_user_meta_data->>'owner_is_superintendent')::BOOLEAN, true)
    ELSE true
  END;
  signup_superintendent_name := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_name', '')),
    ''
  );
  signup_public_phone := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'public_phone',
        NEW.raw_user_meta_data->>'phone',
        ''
      )
    ),
    ''
  );
  signup_public_email := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'public_email', '')), '');
  signup_gps_address := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'gps_address',
        NEW.raw_user_meta_data->>'address',
        ''
      )
    ),
    ''
  );
  signup_location_description := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'location_description', '')),
    ''
  );
  signup_working_hours := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'working_hours', '')), '');
  signup_superintendent_phone := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_phone', '')),
    ''
  );
  signup_superintendent_email := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_email', '')),
    ''
  );

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone,
      address,
      public_email,
      working_hours,
      location_description,
      owner_is_superintendent,
      superintendent_name
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      signup_public_phone,
      signup_gps_address,
      signup_public_email,
      signup_working_hours,
      signup_location_description,
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    )
    RETURNING id INTO created_business_id;

    INSERT INTO public.business_private_contacts (
      business_id,
      owner_full_name,
      owner_phone,
      owner_email,
      superintendent_full_name,
      superintendent_phone,
      superintendent_email
    )
    VALUES (
      created_business_id,
      signup_owner_full_name,
      signup_owner_phone,
      NULLIF(BTRIM(COALESCE(NEW.email, '')), ''),
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_full_name
        ELSE signup_superintendent_name
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_phone
        ELSE signup_superintendent_phone
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(NEW.email, '')), '')
        ELSE signup_superintendent_email
      END
    )
    ON CONFLICT (business_id) DO UPDATE
      SET owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
          owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
          owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
          superintendent_full_name = COALESCE(
            EXCLUDED.superintendent_full_name,
            public.business_private_contacts.superintendent_full_name
          ),
          superintendent_phone = COALESCE(
            EXCLUDED.superintendent_phone,
            public.business_private_contacts.superintendent_phone
          ),
          superintendent_email = COALESCE(
            EXCLUDED.superintendent_email,
            public.business_private_contacts.superintendent_email
          ),
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;

-- Reserve wholesaler stock atomically when marketplace orders are created.
-- This prevents partial orders and reduces overselling between pharmacy and wholesaler flows.

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(_items) = 'array' THEN _items ELSE '[]'::jsonb END) x
    WHERE jsonb_typeof(x) <> 'object' OR coalesce(x->>'quantity', '') !~ '^[1-9][0-9]*$'
      OR nullif(x->>'productId', '') IS NULL) THEN
    RAISE EXCEPTION 'Invalid checkout item.';
  END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id FOR SHARE;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      b.type AS wholesaler_type,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    ORDER BY p.id
    FOR UPDATE OF p FOR SHARE OF b
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' OR v_product.wholesaler_type <> 'wholesaler' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    UPDATE public.products
    SET stock = stock - v_product.quantity
    WHERE id = v_product.id;

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.order_stock_deductions(order_id, product_id, wholesaler_id, quantity)
    SELECT v_order_id, product_id, wholesaler_id, quantity FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN v_order_count;
END;
$$;

-- Private evidence populated only by canonical checkout, never inferred from legacy orders.
CREATE TABLE public.order_stock_deductions (
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  restored_at TIMESTAMPTZ,
  PRIMARY KEY(order_id, product_id)
);
ALTER TABLE public.order_stock_deductions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_stock_deductions FROM PUBLIC, anon, authenticated, service_role;

-- Remove all client mutation policies, including permissive historical alternatives.
DO $$ DECLARE pol RECORD; col RECORD; BEGIN
  FOR pol IN SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'public'
    AND tablename IN ('orders','order_items','order_status_history','business_staff')
    AND cmd <> 'SELECT'
  LOOP EXECUTE format('DROP POLICY %I ON public.%I', pol.policyname, pol.tablename); END LOOP;
  -- Clear column-level grants as well as table grants.
  FOR col IN SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name IN ('orders','order_items','order_status_history','business_staff')
  LOOP EXECUTE format('REVOKE INSERT (%I), UPDATE (%I), REFERENCES (%I) ON public.%I FROM PUBLIC, anon, authenticated',
    col.column_name, col.column_name, col.column_name, col.table_name); END LOOP;
END $$;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.orders, public.order_items,
  public.order_status_history, public.business_staff FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.orders, public.order_items, public.order_status_history FROM service_role;
GRANT UPDATE(receipt_sent_at, receipt_sent_to) ON public.orders TO service_role;
REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB) TO service_role;
REVOKE ALL ON FUNCTION public.add_business_staff_by_email(UUID,TEXT,public.staff_role) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.write_audit_log(TEXT,TEXT,TEXT,UUID,TEXT,JSONB,UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_business_verification_controls()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE trusted BOOLEAN := coalesce(public.has_role(auth.uid(), 'admin'), false) OR coalesce(auth.role() = 'service_role', false);
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Even administrator-created businesses must be approved in a separate review operation.
    NEW.verification_status := 'pending'; NEW.verified_at := NULL; NEW.rejection_reason := NULL;
    RETURN NEW;
  END IF;
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id OR NEW.type IS DISTINCT FROM OLD.type THEN
    RAISE EXCEPTION 'Business ownership and type cannot be changed through profile editing.';
  END IF;
  -- Nested evidence triggers may only invalidate approval, never grant it.
  IF pg_trigger_depth() > 1 AND NEW.verification_status = 'pending'
    AND NEW.verified_at IS NULL AND NEW.rejection_reason IS NULL THEN RETURN NEW; END IF;
  IF NOT trusted AND (NEW.verification_status IS DISTINCT FROM OLD.verification_status
    OR NEW.verified_at IS DISTINCT FROM OLD.verified_at OR NEW.rejection_reason IS DISTINCT FROM OLD.rejection_reason) THEN
    RAISE EXCEPTION 'Only administrators may change verification fields.';
  END IF;
  IF ROW(NEW.name, NEW.license_number, NEW.address, NEW.city, NEW.region,
      NEW.owner_is_superintendent, NEW.superintendent_name)
    IS DISTINCT FROM ROW(OLD.name, OLD.license_number, OLD.address, OLD.city, OLD.region,
      OLD.owner_is_superintendent, OLD.superintendent_name) THEN
    NEW.verification_status := 'pending';
  END IF;
  IF NEW.verification_status = 'approved' THEN
    NEW.verified_at := coalesce(OLD.verified_at, now()); NEW.rejection_reason := NULL;
  ELSE
    NEW.verified_at := NULL;
    IF NEW.verification_status = 'pending' THEN NEW.rejection_reason := NULL; END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER trg_enforce_business_verification_controls ON public.businesses;
CREATE TRIGGER trg_enforce_business_verification_controls BEFORE INSERT OR UPDATE ON public.businesses
FOR EACH ROW EXECUTE FUNCTION public.enforce_business_verification_controls();

-- Restrictive policy intersects every existing permissive write policy.
CREATE POLICY phase0_wholesaler_product_insert ON public.products AS RESTRICTIVE FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));
CREATE POLICY phase0_wholesaler_product_update ON public.products AS RESTRICTIVE FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'))
WITH CHECK (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));
CREATE POLICY phase0_wholesaler_product_delete ON public.products AS RESTRICTIVE FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = wholesaler_id AND b.type = 'wholesaler' AND b.verification_status = 'approved'));

CREATE FUNCTION public.phase0_product_supplier_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF NEW.wholesaler_id IS DISTINCT FROM OLD.wholesaler_id THEN
    RAISE EXCEPTION 'Product supplier is immutable.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase0_product_supplier BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase0_product_supplier_immutable();

CREATE FUNCTION public.phase0_order_item_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Historical order items are immutable.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.orders o JOIN public.products p ON p.wholesaler_id = o.wholesaler_id
    WHERE o.id = NEW.order_id AND p.id = NEW.product_id AND o.status = 'pending') THEN
    RAISE EXCEPTION 'Order product must belong to its wholesaler and a pending order.';
  END IF;
  IF NEW.unit_price_ghs < 0 THEN RAISE EXCEPTION 'Invalid historical price.'; END IF;
  IF EXISTS (SELECT 1 FROM public.order_items WHERE order_id = NEW.order_id AND product_id = NEW.product_id) THEN
    RAISE EXCEPTION 'Duplicate order product.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase0_item_integrity BEFORE INSERT OR UPDATE OR DELETE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.phase0_order_item_integrity();

CREATE FUNCTION public.phase0_order_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF ROW(NEW.id,NEW.pharmacy_id,NEW.wholesaler_id,NEW.order_number,NEW.total_ghs,NEW.payment_method,NEW.created_at)
    IS DISTINCT FROM ROW(OLD.id,OLD.pharmacy_id,OLD.wholesaler_id,OLD.order_number,OLD.total_ghs,OLD.payment_method,OLD.created_at) THEN
    RAISE EXCEPTION 'Order parties and historical financial fields are immutable.';
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status AND NOT (
    (OLD.status = 'pending' AND NEW.status IN ('accepted','cancelled')) OR
    (OLD.status = 'accepted' AND NEW.status IN ('packed','cancelled')) OR
    (OLD.status = 'packed' AND NEW.status = 'dispatched') OR
    (OLD.status = 'dispatched' AND NEW.status = 'delivered')) THEN
    RAISE EXCEPTION 'Invalid order transition: % -> %', OLD.status, NEW.status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER aa_phase0_order_integrity BEFORE UPDATE ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.phase0_order_integrity();

CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE deduction RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.order_stock_deductions WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'Legacy order has no verified stock deduction. Manual reconciliation is required.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_stock_deductions d FULL JOIN
      (SELECT product_id, sum(quantity) quantity FROM public.order_items WHERE order_id = NEW.id GROUP BY product_id) i
      ON d.product_id = i.product_id AND d.order_id = NEW.id
    WHERE (d.order_id = NEW.id OR d.order_id IS NULL)
      AND (d.product_id IS NULL OR i.product_id IS NULL OR d.quantity <> i.quantity OR d.wholesaler_id <> NEW.wholesaler_id)
  ) THEN RAISE EXCEPTION 'Order deduction evidence does not match order items.'; END IF;
  FOR deduction IN SELECT * FROM public.order_stock_deductions WHERE order_id = NEW.id ORDER BY product_id FOR UPDATE LOOP
    IF deduction.restored_at IS NOT NULL THEN RAISE EXCEPTION 'Stock was already restored.'; END IF;
    UPDATE public.products SET stock = stock + deduction.quantity WHERE id = deduction.product_id AND wholesaler_id = deduction.wholesaler_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Deducted product supplier mismatch.'; END IF;
    UPDATE public.order_stock_deductions SET restored_at = now() WHERE order_id = deduction.order_id AND product_id = deduction.product_id;
  END LOOP;
  RETURN NEW;
END $$;

CREATE FUNCTION public.transition_order(_order_id UUID, _status public.order_status, _reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = o.wholesaler_id
    AND b.type = 'wholesaler' AND b.verification_status = 'approved'
    AND (b.owner_id = auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN
    RAISE EXCEPTION 'Order access denied.';
  END IF;
  IF _status IS NULL THEN RAISE EXCEPTION 'Status is required.'; END IF;
  IF o.status = _status THEN RETURN; END IF;
  UPDATE public.orders SET status = _status,
    cancellation_reason = CASE WHEN _status = 'cancelled' THEN nullif(btrim(_reason),'') ELSE cancellation_reason END
  WHERE id = _order_id;
END $$;
REVOKE ALL ON FUNCTION public.transition_order(UUID,public.order_status,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_order(UUID,public.order_status,TEXT) TO authenticated;

CREATE FUNCTION public.confirm_order_payment(_order_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id = _order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = o.wholesaler_id
    AND b.type = 'wholesaler' AND b.verification_status = 'approved'
    AND (b.owner_id = auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN
    RAISE EXCEPTION 'Order access denied.';
  END IF;
  IF o.status <> 'delivered' OR o.payment_status <> 'unpaid' OR o.payment_method <> 'cod' THEN
    RAISE EXCEPTION 'Only delivered unpaid COD orders can be confirmed.';
  END IF;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = auth.uid()
    WHERE id = _order_id;
  RETURN _order_id;
END $$;
REVOKE ALL ON FUNCTION public.confirm_order_payment(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_order_payment(UUID) TO authenticated;

-- Pending membership activation belongs to the invited account, not its tenant administrator.
CREATE FUNCTION public.phase0_staff_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF ROW(NEW.id,NEW.business_id,NEW.user_id) IS DISTINCT FROM ROW(OLD.id,OLD.business_id,OLD.user_id) THEN
      RAISE EXCEPTION 'Membership identity is immutable.';
    END IF;
    IF NEW.status = 'active' AND OLD.status <> 'active' AND (OLD.status = 'pending' OR OLD.joined_at IS NULL) AND auth.uid() IS DISTINCT FROM NEW.user_id THEN
      RAISE EXCEPTION 'The invited account must accept its membership.';
    END IF;
  END IF;
  IF NEW.role = 'owner' AND NOT EXISTS (SELECT 1 FROM public.businesses WHERE id = NEW.business_id AND owner_id = NEW.user_id) THEN
    RAISE EXCEPTION 'Owner role is reserved for the business owner.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase0_staff_integrity BEFORE INSERT OR UPDATE ON public.business_staff
FOR EACH ROW EXECUTE FUNCTION public.phase0_staff_integrity();

CREATE FUNCTION public.accept_business_invitations()
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE accepted INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = auth.uid() AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'A verified signed-in account is required.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_staff WHERE user_id = auth.uid() AND status = 'pending' AND role <> 'owner') THEN RETURN 0; END IF;
  IF EXISTS (SELECT 1 FROM public.platform_staff WHERE user_id = auth.uid() AND status IN ('active','pending')) THEN
    RAISE EXCEPTION 'Platform accounts cannot accept business memberships.';
  END IF;
  UPDATE public.business_staff SET status = 'active', joined_at = now()
    WHERE user_id = auth.uid() AND status = 'pending' AND role <> 'owner';
  GET DIAGNOSTICS accepted = ROW_COUNT;
  RETURN accepted;
END $$;
REVOKE ALL ON FUNCTION public.accept_business_invitations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_business_invitations() TO authenticated;

CREATE FUNCTION public.phase0_invalidate_business_evidence()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'updated_at' - 'uploaded_at') = (to_jsonb(OLD) - 'updated_at' - 'uploaded_at') THEN RETURN NEW; END IF;
  IF TG_OP <> 'INSERT' THEN
    UPDATE public.businesses SET verification_status = 'pending', verified_at = NULL, rejection_reason = NULL
      WHERE id = OLD.business_id AND verification_status <> 'pending';
  END IF;
  IF TG_OP <> 'DELETE' THEN
    UPDATE public.businesses SET verification_status = 'pending', verified_at = NULL, rejection_reason = NULL
      WHERE id = NEW.business_id AND verification_status <> 'pending';
    RETURN NEW;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER phase0_contacts_invalidate AFTER INSERT OR UPDATE OR DELETE ON public.business_private_contacts
FOR EACH ROW EXECUTE FUNCTION public.phase0_invalidate_business_evidence();
CREATE TRIGGER phase0_documents_invalidate AFTER INSERT OR UPDATE OR DELETE ON public.license_documents
FOR EACH ROW EXECUTE FUNCTION public.phase0_invalidate_business_evidence();
REVOKE ALL ON FUNCTION public.phase0_invalidate_business_evidence() FROM PUBLIC, anon, authenticated;


-- Source: 20260914100000_private_order_print.sql
-- Read-only print projection. No public endpoint and no stock/lifecycle mutation.

-- Additive snapshot for NEW order items only; never backfill historical facts from today's catalogue.
ALTER TABLE public.order_items ADD COLUMN product_details JSONB;
CREATE FUNCTION public.snapshot_order_print_details()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  SELECT jsonb_build_object('brand',p.brand,'generic_name',m.generic_name,'strength',m.strength,
    'dosage_form',p.form,'pack_size',p.pack_size) INTO NEW.product_details
  FROM public.products p LEFT JOIN public.wholesaler_products w ON w.id=p.id
    LEFT JOIN public.master_products m ON m.id=w.product_id
  WHERE p.id=NEW.product_id;
  RETURN NEW;
END $$;
CREATE TRIGGER print_snapshot_details BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_print_details();
REVOKE ALL ON FUNCTION public.snapshot_order_print_details() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_order_print(_business_id UUID, _order_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE context public.businesses%ROWTYPE; purchase public.orders%ROWTYPE; result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501'; END IF;
  SELECT * INTO context FROM public.businesses WHERE id = _business_id;
  IF NOT FOUND OR NOT (context.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), context.id)) THEN
    RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO purchase FROM public.orders WHERE id = _order_id;
  IF NOT FOUND OR NOT ((context.type = 'pharmacy' AND purchase.pharmacy_id = context.id)
    OR (context.type = 'wholesaler' AND purchase.wholesaler_id = context.id)) THEN
    RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501';
  END IF;
  -- Explicit projection excludes account credentials, private verification contacts, IDs and internal metadata.
  -- Names, prices and available details come only from historical order-item values.
  -- Older unsnapshotted details remain absent; no present-day catalogue fallback.
  SELECT jsonb_build_object(
    'order_number',purchase.order_number,'created_at',purchase.created_at,'status',purchase.status,
    'payment_status',purchase.payment_status,'payment_method',purchase.payment_method,
    'total_ghs',purchase.total_ghs::TEXT,'notes',purchase.notes,
    'buyer',jsonb_build_object('name',buyer.name,'phone',buyer.phone,'email',buyer.public_email,
      'address',buyer.address,'city',buyer.city,'region',buyer.region,'location_description',buyer.location_description),
    'seller',jsonb_build_object('name',seller.name,'phone',seller.phone,'email',seller.public_email,
      'address',seller.address,'city',seller.city,'region',seller.region,'location_description',seller.location_description),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object('product_name',i.product_name,
      'quantity',i.quantity,'unit_price_ghs',i.unit_price_ghs::TEXT,
      'brand',i.product_details->>'brand','generic_name',i.product_details->>'generic_name',
      'strength',i.product_details->>'strength','dosage_form',i.product_details->>'dosage_form','pack_size',i.product_details->>'pack_size',
      'line_subtotal_ghs',(i.quantity*i.unit_price_ghs)::TEXT) ORDER BY i.id)
      FROM public.order_items i WHERE i.order_id=purchase.id),'[]'::JSONB)
  ) INTO result FROM public.businesses buyer CROSS JOIN public.businesses seller
    WHERE buyer.id=purchase.pharmacy_id AND seller.id=purchase.wholesaler_id;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_order_print(UUID,UUID) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_order_print(UUID,UUID) TO authenticated;

-- Correct future platform-audit labels without rewriting historical events or migrations.
CREATE OR REPLACE FUNCTION public.audit_platform_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  staff_email TEXT;
BEGIN
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Platform staff invited',
      'DrugXone',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Platform staff updated',
      'DrugXone',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Source: 20260914110000_phase1_inventory_integrity.sql
-- Phase 1. Run phase1_read_only_review.sql before applying. No historical repairs.

LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.products WHERE stock IS NULL OR stock < 0) THEN
    RAISE EXCEPTION 'Invalid legacy stock: review and reconcile explicitly before migrating.';
  END IF;
END $$;

CREATE TABLE public.inventory_opening_balances (
  product_id UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  quantity INTEGER NOT NULL CHECK(quantity >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.inventory_opening_balances(product_id,wholesaler_id,quantity)
SELECT id,wholesaler_id,stock FROM public.products;

-- Private transaction context. Unlike custom GUCs, clients cannot forge this context.
CREATE TABLE public.inventory_operation_context (
  transaction_id BIGINT PRIMARY KEY,
  actor_id UUID,
  movement_type TEXT NOT NULL,
  order_id UUID,
  import_run_id UUID,
  request_id UUID,
  reason TEXT
);
CREATE TABLE public.inventory_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
  actor_id UUID,
  order_id UUID REFERENCES public.orders(id),
  import_run_id UUID REFERENCES public.product_import_runs(id) DEFERRABLE INITIALLY DEFERRED,
  request_id UUID,
  movement_type TEXT NOT NULL CHECK(movement_type IN
    ('product_created','manual_add','manual_remove','manual_reconciliation','checkout_deduction',
     'order_cancellation_restore','import_add','import_replace','admin_adjustment')),
  quantity_delta BIGINT NOT NULL,
  quantity_before INTEGER NOT NULL CHECK(quantity_before >= 0),
  quantity_after INTEGER NOT NULL CHECK(quantity_after >= 0),
  reason TEXT,
  source_operation TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CHECK(quantity_after::BIGINT - quantity_before = quantity_delta)
);
CREATE INDEX inventory_movements_tenant_product ON public.inventory_movements(wholesaler_id,product_id,created_at);
CREATE UNIQUE INDEX inventory_order_movement_once ON public.inventory_movements(order_id,product_id,movement_type)
WHERE movement_type IN ('checkout_deduction','order_cancellation_restore');
CREATE TABLE public.stock_adjustment_requests (
  id UUID PRIMARY KEY, actor_id UUID NOT NULL, product_id UUID NOT NULL,
  payload JSONB NOT NULL, result INTEGER
);
CREATE TABLE public.checkout_requests (
  id UUID PRIMARY KEY, actor_id UUID NOT NULL, pharmacy_id UUID NOT NULL,
  payload JSONB NOT NULL, order_count INTEGER,
  order_ids UUID[], created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DO $$ DECLARE tbl TEXT; BEGIN
  FOREACH tbl IN ARRAY ARRAY['inventory_opening_balances','inventory_operation_context','inventory_movements',
    'stock_adjustment_requests','checkout_requests'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',tbl);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated,service_role',tbl);
  END LOOP;
END $$;
GRANT SELECT ON public.inventory_movements,public.inventory_opening_balances TO authenticated;
CREATE POLICY inventory_history_tenant ON public.inventory_movements FOR SELECT TO authenticated USING (
  EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=wholesaler_id AND b.type='wholesaler'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IS NOT NULL)));
CREATE POLICY inventory_opening_tenant ON public.inventory_opening_balances FOR SELECT TO authenticated USING (
  EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=wholesaler_id AND b.type='wholesaler'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IS NOT NULL)));

CREATE FUNCTION public.phase1_inventory_history_immutable() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Inventory history is immutable; record a corrective operation.'; END $$;
CREATE TRIGGER inventory_history_immutable BEFORE UPDATE OR DELETE ON public.inventory_movements
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
CREATE TRIGGER inventory_opening_immutable BEFORE UPDATE OR DELETE ON public.inventory_opening_balances
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();

CREATE FUNCTION public.phase1_record_inventory() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE ctx public.inventory_operation_context%ROWTYPE; previous INTEGER;
BEGIN
  previous := CASE WHEN TG_OP='INSERT' THEN 0 ELSE OLD.stock END;
  IF TG_OP='UPDATE' AND NEW.stock=OLD.stock THEN RETURN NEW; END IF;
  SELECT * INTO ctx FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  -- New zero-stock products have a real creation baseline, not a fabricated past movement.
  IF TG_OP='INSERT' THEN
    INSERT INTO public.inventory_opening_balances(product_id,wholesaler_id,quantity) VALUES(NEW.id,NEW.wholesaler_id,0);
  END IF;
  IF NEW.stock=previous THEN RETURN NEW; END IF;
  INSERT INTO public.inventory_movements(product_id,wholesaler_id,actor_id,order_id,import_run_id,request_id,
    movement_type,quantity_delta,quantity_before,quantity_after,reason,source_operation)
  VALUES(NEW.id,NEW.wholesaler_id,coalesce(ctx.actor_id,auth.uid()),ctx.order_id,ctx.import_run_id,ctx.request_id,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_created' ELSE 'admin_adjustment' END),
    NEW.stock::BIGINT-previous,previous,NEW.stock,ctx.reason,
    coalesce(ctx.movement_type,CASE WHEN TG_OP='INSERT' THEN 'product_insert' ELSE 'database_maintenance' END));
  RETURN NEW;
END $$;
CREATE TRIGGER phase1_inventory_movement AFTER INSERT OR UPDATE OF stock ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase1_record_inventory();
REVOKE ALL ON FUNCTION public.phase1_record_inventory(),public.phase1_inventory_history_immutable() FROM PUBLIC,anon,authenticated,service_role;

-- Clear all UPDATE grants including columns; grant only known metadata. Existing RLS stays active.
REVOKE UPDATE,DELETE,TRUNCATE ON public.products FROM PUBLIC,anon,authenticated,service_role;
DO $$ DECLARE c RECORD; BEGIN
  FOR c IN SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='products' LOOP
    EXECUTE format('REVOKE UPDATE(%I) ON public.products FROM PUBLIC,anon,authenticated,service_role',c.column_name);
  END LOOP;
END $$;
GRANT UPDATE(name,brand,category,form,pack_size,price_ghs,image_hue,active) ON public.products TO authenticated;

CREATE FUNCTION public.adjust_product_stock(_product_id UUID,_operation TEXT,_quantity INTEGER,
  _request_id UUID,_expected_stock INTEGER DEFAULT NULL,_reason TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.products%ROWTYPE; prior public.stock_adjustment_requests%ROWTYPE; payload JSONB; v_result INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  IF _request_id IS NULL OR _quantity IS NULL OR _quantity<0 OR _operation IS NULL
    OR _operation NOT IN ('add','remove','reconcile') OR (_operation<>'reconcile' AND _quantity=0) THEN
    RAISE EXCEPTION 'A request ID and valid nonblank stock quantity are required.';
  END IF;
  SELECT * INTO p FROM public.products WHERE id=_product_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Inventory access denied.'; END IF;
  PERFORM 1 FROM public.businesses WHERE id=p.wholesaler_id FOR SHARE;
  IF NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p.wholesaler_id
    AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager'))) THEN
    RAISE EXCEPTION 'Inventory access denied.';
  END IF;
  payload:=jsonb_build_array(_product_id,_operation,_quantity,_expected_stock,nullif(btrim(_reason),''));
  INSERT INTO public.stock_adjustment_requests(id,actor_id,product_id,payload)
    VALUES(_request_id,auth.uid(),_product_id,payload) ON CONFLICT DO NOTHING;
  SELECT * INTO prior FROM public.stock_adjustment_requests WHERE id=_request_id FOR UPDATE;
  IF prior.actor_id<>auth.uid() OR prior.payload<>payload THEN RAISE EXCEPTION 'Stock request ID already used for different data.'; END IF;
  IF prior.result IS NOT NULL THEN RETURN prior.result; END IF;
  SELECT * INTO p FROM public.products WHERE id=_product_id FOR UPDATE;
  IF _operation='reconcile' AND (_expected_stock IS NULL OR p.stock<>_expected_stock) THEN
    RAISE EXCEPTION 'Stock changed since count preview. Refresh and confirm a new reconciliation.';
  END IF;
  v_result:=CASE _operation WHEN 'add' THEN p.stock+_quantity WHEN 'remove' THEN p.stock-_quantity ELSE _quantity END;
  IF v_result<0 THEN RAISE EXCEPTION 'Cannot remove more than available stock.'; END IF;
  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,request_id,reason)
    VALUES(txid_current(),auth.uid(),CASE _operation WHEN 'add' THEN 'manual_add' WHEN 'remove' THEN 'manual_remove' ELSE 'manual_reconciliation' END,_request_id,nullif(btrim(_reason),''));
  UPDATE public.products SET stock=v_result WHERE id=_product_id;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  UPDATE public.stock_adjustment_requests SET result=v_result WHERE id=_request_id;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.adjust_product_stock(UUID,TEXT,INTEGER,UUID,INTEGER,TEXT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.adjust_product_stock(UUID,TEXT,INTEGER,UUID,INTEGER,TEXT) TO authenticated;

-- Retire the keyless entry point; existing clients must supply a durable key.
DROP FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB);
CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _request_id UUID
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
  v_request public.checkout_requests%ROWTYPE;
  v_payload JSONB;
  v_ids UUID[] := ARRAY[]::UUID[];
  v_line RECORD;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(_items) = 'array' THEN _items ELSE '[]'::jsonb END) x
    WHERE jsonb_typeof(x) <> 'object' OR coalesce(x->>'quantity', '') !~ '^[1-9][0-9]*$'
      OR nullif(x->>'productId', '') IS NULL) THEN
    RAISE EXCEPTION 'Invalid checkout item.';
  END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id FOR SHARE;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  IF _request_id IS NULL THEN RAISE EXCEPTION 'Checkout request ID is required.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('productId',product_id,'quantity',quantity) ORDER BY product_id)
    INTO v_payload FROM (SELECT (x->>'productId')::UUID product_id,sum((x->>'quantity')::BIGINT) quantity
    FROM jsonb_array_elements(_items) x GROUP BY (x->>'productId')::UUID) normalized;
  INSERT INTO public.checkout_requests(id,actor_id,pharmacy_id,payload)
    VALUES(_request_id,_caller_id,_pharmacy_id,v_payload) ON CONFLICT DO NOTHING;
  SELECT * INTO v_request FROM public.checkout_requests WHERE id=_request_id FOR UPDATE;
  IF v_request.actor_id<>_caller_id OR v_request.pharmacy_id<>_pharmacy_id OR v_request.payload<>v_payload THEN
    RAISE EXCEPTION 'Checkout request ID already used for different data or account.';
  END IF;
  IF v_request.order_count IS NOT NULL THEN RETURN v_request.order_count; END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      b.type AS wholesaler_type,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    ORDER BY p.id
    FOR UPDATE OF p FOR SHARE OF b
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' OR v_product.wholesaler_type <> 'wholesaler' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    -- All product rows stay locked; deductions follow order insertion below.

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.order_stock_deductions(order_id, product_id, wholesaler_id, quantity)
    SELECT v_order_id, product_id, wholesaler_id, quantity FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,order_id,request_id)
      VALUES(txid_current(),_caller_id,'checkout_deduction',v_order_id,_request_id);
    FOR v_line IN SELECT * FROM tmp_locked_products WHERE wholesaler_id=v_wholesaler.wholesaler_id ORDER BY product_id LOOP
      UPDATE public.products SET stock=stock-v_line.quantity WHERE id=v_line.product_id;
    END LOOP;
    DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
    v_ids:=array_append(v_ids,v_order_id);
    v_order_count := v_order_count + 1;
  END LOOP;

  UPDATE public.checkout_requests SET order_count=v_order_count,order_ids=v_ids WHERE id=_request_id;
  DROP TABLE tmp_requested_items,tmp_locked_products;
  RETURN v_order_count;
END;
$$;


REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID,UUID,JSONB,UUID) TO service_role;
CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE deduction RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.order_stock_deductions WHERE order_id = NEW.id) THEN
    RAISE EXCEPTION 'Legacy order has no verified stock deduction. Manual reconciliation is required.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_stock_deductions d FULL JOIN
      (SELECT product_id, sum(quantity) quantity FROM public.order_items WHERE order_id = NEW.id GROUP BY product_id) i
      ON d.product_id = i.product_id AND d.order_id = NEW.id
    WHERE (d.order_id = NEW.id OR d.order_id IS NULL)
      AND (d.product_id IS NULL OR i.product_id IS NULL OR d.quantity <> i.quantity OR d.wholesaler_id <> NEW.wholesaler_id)
  ) THEN RAISE EXCEPTION 'Order deduction evidence does not match order items.'; END IF;
  FOR deduction IN SELECT * FROM public.order_stock_deductions WHERE order_id = NEW.id ORDER BY product_id FOR UPDATE LOOP
    IF deduction.restored_at IS NOT NULL THEN RAISE EXCEPTION 'Stock was already restored.'; END IF;
    INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,order_id,reason)
      VALUES(txid_current(),auth.uid(),'order_cancellation_restore',NEW.id,NEW.cancellation_reason);
    UPDATE public.products SET stock = stock + deduction.quantity WHERE id = deduction.product_id AND wholesaler_id = deduction.wholesaler_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Deducted product supplier mismatch.'; END IF;
    DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
    UPDATE public.order_stock_deductions SET restored_at = now() WHERE order_id = deduction.order_id AND product_id = deduction.product_id;
  END LOOP;
  RETURN NEW;
END $$;


CREATE OR REPLACE FUNCTION public.preview_wholesaler_import(
  _business_id UUID, _products JSONB, _mode TEXT,
  _confirm_token TEXT DEFAULT NULL, _request_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_product public.products%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_price NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.product_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = _business_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'wholesaler' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved wholesaler account is required.';
  END IF;
  IF NOT (biz.owner_id = auth.uid() OR COALESCE(public.get_staff_role(auth.uid(), _business_id)::TEXT IN ('owner', 'manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only owners and managers can import products.';
  END IF;
  IF _mode NOT IN ('replace', 'add', 'details') OR _mode IS NULL THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(_products) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected a product array.'; END IF;
  IF jsonb_array_length(_products) = 0 OR jsonb_array_length(_products) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 products at a time.';
  END IF;
  payload_hash := md5(_products::TEXT || _mode || _business_id::TEXT);
  IF _confirm_token IS NOT NULL THEN
    IF _request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    -- Serialize commits against imports, manual edits, and order stock updates.
    -- This short transaction lock also protects missing rows (new products).
    LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.product_import_runs WHERE id = _request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.wholesaler_id <> _business_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(_products) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR nullif(btrim(item->>'name'), '') IS NULL
      OR coalesce(item->>'price_ghs', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      OR (item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$') THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Invalid name, price or stock.'));
      CONTINUE;
    END IF;
    input_price := (item->>'price_ghs')::NUMERIC;
    IF input_price <= 0 OR input_price > 99999999.99 OR COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Price or stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    identity_key := public.product_import_identity(item->>'name', item->>'brand', coalesce(nullif(item->>'form', ''), 'Tablet'), item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated product identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);
    SELECT count(*) INTO matches FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing products match. Resolve the catalogue collision first.'));
      CONTINUE;
    END IF;
    SELECT * INTO old_product FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    new_stock := CASE
      WHEN _mode = 'details' THEN coalesce(old_product.stock, 0)
      WHEN input_stock IS NULL THEN coalesce(old_product.stock, 0)
      WHEN _mode = 'add' THEN coalesce(old_product.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;
    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_product.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_product.id IS NULL THEN 'new' ELSE 'existing' END,
      'before', CASE WHEN old_product.id IS NULL THEN NULL ELSE to_jsonb(old_product) END,
      'price_before', old_product.price_ghs, 'price_after', input_price,
      'stock_before', old_product.stock, 'stock_after', new_stock,
      'product', item
    ));
  END LOOP;
  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', _mode);
  IF _confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF _confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,import_run_id,request_id)
    VALUES(txid_current(),auth.uid(),CASE WHEN _mode='add' THEN 'import_add' ELSE 'import_replace' END,_request_id,_request_id);
  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.products (wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, image_hue, active)
      VALUES (_business_id, item->>'name', nullif(btrim(item#>>'{product,brand}'), ''),
        coalesce(nullif(item#>>'{product,category}', ''), 'Other'), coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        nullif(btrim(item#>>'{product,pack_size}'), ''), (item->>'price_after')::NUMERIC, (item->>'stock_after')::INTEGER,
        coalesce((item#>>'{product,image_hue}')::INTEGER, 200), TRUE) RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.products SET name = item->>'name', brand = nullif(btrim(item#>>'{product,brand}'), ''),
        category = coalesce(nullif(item#>>'{product,category}', ''), 'Other'), form = coalesce(nullif(item#>>'{product,form}', ''), 'Tablet'),
        pack_size = nullif(btrim(item#>>'{product,pack_size}'), ''), price_ghs = (item->>'price_after')::NUMERIC,
        stock = (item->>'stock_after')::INTEGER, image_hue = coalesce((item#>>'{product,image_hue}')::INTEGER, 200)
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;
    PERFORM public.write_audit_log('Inventory imported', biz.name, 'product', saved_id, item->>'name',
      jsonb_build_object('request_id', _request_id, 'mode', _mode, 'before', item->'before',
        'after', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = saved_id)));
  END LOOP;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;


-- Source: 20260914120000_phase2_production_readiness.sql
-- Forward-only Phase 2. Review phase2_read_only_review.sql before a future authorized rollout.

-- Platform membership is authoritative. Preserve legacy records for manual review.
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID,_role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT CASE WHEN _role='admin' THEN EXISTS(SELECT 1 FROM public.platform_staff WHERE user_id=_user_id AND status='active')
    ELSE EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=_user_id AND role=_role) END
$$;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON public.platform_staff,public.user_roles FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.phase2_platform_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Deactivate administrators through the controlled operation; owners cannot be removed.'; END IF;
  IF TG_OP='UPDATE' THEN
    IF ROW(NEW.id,NEW.user_id) IS DISTINCT FROM ROW(OLD.id,OLD.user_id) OR NEW.role<>OLD.role THEN
      RAISE EXCEPTION 'Platform membership identity and owner role are immutable.';
    END IF;
    IF OLD.role='owner' AND NEW.status<>'active' THEN RAISE EXCEPTION 'Protected owner must remain active.'; END IF;
    IF NEW.status='active' AND OLD.joined_at IS NULL AND OLD.role<>'owner' AND auth.uid() IS DISTINCT FROM NEW.user_id THEN
      RAISE EXCEPTION 'The invited account must accept platform membership.';
    END IF;
  END IF;
  IF NEW.status<>'inactive' AND (EXISTS(SELECT 1 FROM public.businesses WHERE owner_id=NEW.user_id)
    OR EXISTS(SELECT 1 FROM public.business_staff WHERE user_id=NEW.user_id AND status IN ('active','pending'))) THEN
    RAISE EXCEPTION 'Tenant and platform memberships must remain separate.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_platform_guard BEFORE INSERT OR UPDATE OR DELETE ON public.platform_staff
FOR EACH ROW EXECUTE FUNCTION public.phase2_platform_guard();
CREATE FUNCTION public.manage_platform_member(_user_id UUID,_status TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.platform_staff%ROWTYPE; v_id UUID;
BEGIN
  IF NOT coalesce(public.is_platform_owner(auth.uid()),false) THEN RAISE EXCEPTION 'Only the platform owner can manage platform membership.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('platform-membership',0));
  SELECT * INTO p FROM public.platform_staff WHERE user_id=_user_id FOR UPDATE;
  IF FOUND THEN
    IF p.role='owner' THEN RAISE EXCEPTION 'Protected owner cannot be changed by invitations or role management.'; END IF;
    IF _status NOT IN ('active','inactive') OR _status IS NULL OR (p.joined_at IS NULL AND _status='active') THEN
      RAISE EXCEPTION 'Pending members must accept their invitation.';
    END IF;
    UPDATE public.platform_staff SET status=_status::public.staff_status WHERE id=p.id;
    RETURN p.id;
  END IF;
  IF _status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'New platform membership must be pending.'; END IF;
  INSERT INTO public.platform_staff(user_id,role,status,invited_by) VALUES(_user_id,'admin','pending',auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END $$;
CREATE FUNCTION public.accept_platform_invitation() RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'Verified account required.'; END IF;
  UPDATE public.platform_staff SET status='active',joined_at=now() WHERE user_id=auth.uid() AND status='pending' AND role='admin';
END $$;
REVOKE ALL ON FUNCTION public.manage_platform_member(UUID,TEXT),public.accept_platform_invitation(),public.phase2_platform_guard() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.manage_platform_member(UUID,TEXT),public.accept_platform_invitation() TO authenticated;

-- Privileged audit insertion stays internal. Caller-supplied actor/email arguments are ignored.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON public.audit_logs FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.write_audit_log(_activity TEXT,_organization TEXT,_record_type TEXT,_record_id UUID,_record_label TEXT,
  _details JSONB DEFAULT '{}',_performed_by UUID DEFAULT auth.uid(),_performed_by_email TEXT DEFAULT public.current_actor_email(),
  _ip_address TEXT DEFAULT public.current_request_ip_address()) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE actor UUID;
BEGIN
  actor:=auth.uid();
  IF actor IS NULL THEN SELECT actor_id INTO actor FROM public.inventory_operation_context WHERE transaction_id=txid_current(); END IF;
  IF actor IS NULL THEN SELECT actor_id INTO actor FROM public.server_audit_context WHERE transaction_id=txid_current(); END IF;
  INSERT INTO public.audit_logs(activity,organization,performed_by,performed_by_email,record_type,record_id,record_label,details,ip_address)
  VALUES(_activity,_organization,actor,(SELECT email FROM auth.users WHERE id=actor),_record_type,_record_id,_record_label,coalesce(_details,'{}'),public.current_request_ip_address());
END $$;
REVOKE ALL ON FUNCTION public.write_audit_log(TEXT,TEXT,TEXT,UUID,TEXT,JSONB,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER phase2_audit_immutable BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
CREATE FUNCTION public.phase2_inventory_audit() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  INSERT INTO public.audit_logs(activity,organization,performed_by,performed_by_email,record_type,record_id,details)
  VALUES(NEW.movement_type,NEW.wholesaler_id::TEXT,NEW.actor_id,(SELECT email FROM auth.users WHERE id=NEW.actor_id),
    'inventory_movement',NEW.id,jsonb_build_object('order_id',NEW.order_id,'product_id',NEW.product_id,'delta',NEW.quantity_delta));
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_inventory_audit AFTER INSERT ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.phase2_inventory_audit();

-- Conservative identity v2: preserve punctuation, strength and all meaningful text.
DROP INDEX public.products_import_identity_idx;
CREATE OR REPLACE FUNCTION public.product_import_identity(name TEXT,brand TEXT,form TEXT,pack_size TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE SET search_path=public AS $$
  SELECT 'v2:'||jsonb_build_array(
    regexp_replace(lower(btrim(coalesce(name,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(brand,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(form,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(pack_size,''))), '\s+', ' ', 'g'))::TEXT
$$;
CREATE INDEX products_import_identity_idx ON public.products(wholesaler_id,public.product_import_identity(name,brand,form,pack_size));
CREATE FUNCTION public.phase2_identity_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
DECLARE identity TEXT;
BEGIN
  identity:=public.product_import_identity(NEW.name,NEW.brand,NEW.form,NEW.pack_size);
  IF TG_OP='UPDATE' AND identity=public.product_import_identity(OLD.name,OLD.brand,OLD.form,OLD.pack_size) THEN RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.wholesaler_id::TEXT||identity,0));
  IF EXISTS(SELECT 1 FROM public.products p WHERE p.wholesaler_id=NEW.wholesaler_id AND p.id<>NEW.id
    AND public.product_import_identity(p.name,p.brand,p.form,p.pack_size)=identity) THEN
    RAISE EXCEPTION 'Product identity already exists or is ambiguous. Review existing products instead of creating a duplicate.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_identity_guard BEFORE INSERT OR UPDATE OF name,brand,form,pack_size ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase2_identity_guard();
CREATE FUNCTION public.phase2_offer_supplier_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=NEW.id AND p.wholesaler_id=NEW.wholesaler_id) THEN
    RAISE EXCEPTION 'Offer supplier must equal product supplier.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_offer_supplier_guard BEFORE INSERT OR UPDATE ON public.wholesaler_products
FOR EACH ROW EXECUTE FUNCTION public.phase2_offer_supplier_guard();
REVOKE INSERT,UPDATE,DELETE ON public.wholesaler_products,public.master_products FROM service_role;

-- Private immutable document versions. Existing versions are explicitly unreviewed.
ALTER TABLE public.license_documents ADD COLUMN version_id UUID NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN reviewed_by UUID, ADD COLUMN reviewed_at TIMESTAMPTZ, ADD COLUMN review_status TEXT NOT NULL DEFAULT 'pending';
CREATE TABLE public.license_document_versions (
  version_id UUID PRIMARY KEY, document_id UUID NOT NULL, business_id UUID NOT NULL,
  doc_type TEXT NOT NULL, storage_path TEXT NOT NULL, uploaded_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID, reviewed_at TIMESTAMPTZ, review_status TEXT NOT NULL
);
INSERT INTO public.license_document_versions SELECT version_id,id,business_id,doc_type,storage_path,uploaded_at,reviewed_by,reviewed_at,review_status FROM public.license_documents;
ALTER TABLE public.license_document_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.license_document_versions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.license_document_versions TO authenticated;
CREATE POLICY version_reader ON public.license_document_versions FOR SELECT TO authenticated USING
  (public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=business_id AND b.owner_id=auth.uid()));
CREATE TRIGGER phase2_document_history_immutable BEFORE UPDATE OR DELETE ON public.license_document_versions
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
UPDATE storage.buckets SET public=false,file_size_limit=10485760,allowed_mime_types=ARRAY['application/pdf','image/jpeg','image/png'] WHERE id='licenses';
-- No overwrite/delete policies: each upload is a unique object; old evidence is retained.
DO $$ DECLARE p RECORD; BEGIN
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='storage' AND tablename='objects' LOOP
    IF p.policyname IN ('Users upload own license docs','Users read own license docs','Admins read all license docs','Users delete own license docs') THEN
      EXECUTE format('DROP POLICY %I ON storage.objects',p.policyname);
    END IF;
  END LOOP;
END $$;
CREATE POLICY phase2_license_boundary ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
USING(bucket_id<>'licenses' OR public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b
  WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid() AND auth.uid()::TEXT=(storage.foldername(objects.name))[1]))
WITH CHECK(bucket_id<>'licenses' OR (auth.uid()::TEXT=(storage.foldername(objects.name))[1] AND EXISTS(SELECT 1 FROM public.businesses b
  WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())));
CREATE POLICY phase2_license_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='licenses' AND
  (public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())));
CREATE POLICY phase2_license_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='licenses'
  AND auth.uid()::TEXT=(storage.foldername(objects.name))[1] AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())
  AND name ~ '\.(pdf|png|jpg|jpeg)$');
CREATE POLICY phase2_license_no_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated USING(bucket_id<>'licenses');
CREATE POLICY phase2_license_no_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated USING(bucket_id<>'licenses');
REVOKE UPDATE ON public.license_documents FROM PUBLIC,anon,authenticated,service_role;
GRANT UPDATE(storage_path) ON public.license_documents TO authenticated;
CREATE FUNCTION public.phase2_document_guard() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF TG_OP='UPDATE' AND NEW.storage_path=OLD.storage_path THEN RETURN NEW; END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='licenses' AND o.name=NEW.storage_path
    AND (storage.foldername(o.name))[2]=NEW.business_id::TEXT) THEN RAISE EXCEPTION 'Document metadata requires an existing object in this business folder.'; END IF;
  NEW.version_id:=gen_random_uuid();NEW.uploaded_at:=now();NEW.reviewed_by:=NULL;NEW.reviewed_at:=NULL;NEW.review_status:='pending';
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_document_guard BEFORE INSERT OR UPDATE ON public.license_documents FOR EACH ROW EXECUTE FUNCTION public.phase2_document_guard();
CREATE FUNCTION public.phase2_document_audit() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  INSERT INTO public.license_document_versions VALUES(NEW.version_id,NEW.id,NEW.business_id,NEW.doc_type,NEW.storage_path,NEW.uploaded_at,NEW.reviewed_by,NEW.reviewed_at,NEW.review_status) ON CONFLICT DO NOTHING;
  PERFORM public.write_audit_log('Verification evidence changed',NEW.business_id::TEXT,'license_document',NEW.id,NEW.doc_type,
    jsonb_build_object('version_id',NEW.version_id,'review_status',NEW.review_status,'reviewer',NEW.reviewed_by,'reviewed_at',NEW.reviewed_at,'storage_path',NEW.storage_path));
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_document_audit AFTER INSERT OR UPDATE ON public.license_documents FOR EACH ROW EXECUTE FUNCTION public.phase2_document_audit();

-- Payment transition and durable receipt scheduling share one transaction.
CREATE TABLE public.receipt_outbox (
  order_id UUID PRIMARY KEY REFERENCES public.orders(id), status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending','sending','sent','failed','uncertain')),
  requested_by UUID NOT NULL, payload JSONB, attempts INTEGER NOT NULL DEFAULT 0,
  first_attempt_at TIMESTAMPTZ, lease_until TIMESTAMPTZ, claim_id UUID, sent_at TIMESTAMPTZ,
  provider_id TEXT, last_error TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.receipt_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.receipt_outbox FROM PUBLIC,anon,authenticated,service_role;
REVOKE UPDATE(receipt_sent_at,receipt_sent_to) ON public.orders FROM service_role;
CREATE OR REPLACE FUNCTION public.confirm_order_payment(_order_id UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id=_order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=o.wholesaler_id AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN RAISE EXCEPTION 'Order access denied.'; END IF;
  IF o.status<>'delivered' OR o.payment_method<>'cod' OR o.payment_status NOT IN ('unpaid','paid') THEN
    RAISE EXCEPTION 'Only delivered unpaid COD orders can be confirmed.';
  END IF;
  IF o.payment_status='unpaid' THEN
    UPDATE public.orders SET payment_status='paid',paid_at=now(),payment_confirmed_at=now(),payment_confirmed_by=auth.uid() WHERE id=_order_id;
  END IF;
  INSERT INTO public.receipt_outbox(order_id,requested_by,status,sent_at)
    VALUES(_order_id,auth.uid(),CASE WHEN o.receipt_sent_at IS NULL THEN 'pending' ELSE 'sent' END,o.receipt_sent_at) ON CONFLICT DO NOTHING;
  RETURN _order_id;
END $$;
CREATE FUNCTION public.claim_order_receipt(_order_id UUID,_caller_id UUID,_payload JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders%ROWTYPE; job public.receipt_outbox%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id=_order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=o.wholesaler_id AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=_caller_id OR public.get_staff_role(_caller_id,b.id) IN ('owner','manager','cashier'))) THEN RAISE EXCEPTION 'Receipt access denied.'; END IF;
  IF o.status<>'delivered' OR o.payment_status<>'paid' THEN RAISE EXCEPTION 'Receipt requires delivered paid order.'; END IF;
  INSERT INTO public.receipt_outbox(order_id,requested_by,status,sent_at) VALUES(o.id,_caller_id,
    CASE WHEN o.receipt_sent_at IS NULL THEN 'pending' ELSE 'sent' END,o.receipt_sent_at) ON CONFLICT DO NOTHING;
  SELECT * INTO job FROM public.receipt_outbox WHERE order_id=o.id FOR UPDATE;
  IF job.status='sent' THEN RETURN jsonb_build_object('status','sent'); END IF;
  IF job.lease_until>now() THEN RETURN jsonb_build_object('status','sending'); END IF;
  -- Provider keys expire after 24h. Unknown outcomes must not automatically resend outside that window.
  IF job.first_attempt_at<now()-interval '23 hours' THEN
    UPDATE public.receipt_outbox SET status='uncertain' WHERE order_id=o.id;
    RETURN jsonb_build_object('status','uncertain');
  END IF;
  UPDATE public.receipt_outbox SET status='sending',payload=coalesce(payload,_payload),attempts=attempts+1,
    first_attempt_at=coalesce(first_attempt_at,now()),lease_until=now()+interval '2 minutes',claim_id=gen_random_uuid()
    WHERE order_id=o.id RETURNING * INTO job;
  RETURN jsonb_build_object('status','claimed','claim_id',job.claim_id,'payload',job.payload);
END $$;
CREATE FUNCTION public.finish_order_receipt(_order_id UUID,_claim_id UUID,_provider_id TEXT,_error TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE job public.receipt_outbox%ROWTYPE;
BEGIN
  SELECT * INTO job FROM public.receipt_outbox WHERE order_id=_order_id FOR UPDATE;
  IF NOT FOUND OR job.claim_id IS DISTINCT FROM _claim_id OR job.status<>'sending' THEN RAISE EXCEPTION 'Receipt lease no longer owned.'; END IF;
  UPDATE public.receipt_outbox SET status=CASE WHEN _error IS NULL THEN 'sent' ELSE 'failed' END,
    sent_at=CASE WHEN _error IS NULL THEN now() END,provider_id=_provider_id,last_error=_error,lease_until=NULL WHERE order_id=_order_id;
  IF _error IS NULL THEN UPDATE public.orders SET receipt_sent_at=now(),receipt_sent_to=job.payload->>'toEmail' WHERE id=_order_id; END IF;
  INSERT INTO public.audit_logs(activity,performed_by,record_type,record_id,details)
    VALUES(CASE WHEN _error IS NULL THEN 'Receipt sent' ELSE 'Receipt retry required' END,job.requested_by,'order',_order_id,jsonb_build_object('provider_id',_provider_id));
END $$;
REVOKE ALL ON FUNCTION public.claim_order_receipt(UUID,UUID,JSONB),public.finish_order_receipt(UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_order_receipt(UUID,UUID,JSONB),public.finish_order_receipt(UUID,UUID,TEXT,TEXT) TO service_role;

-- Version-bound review; client must supply the evidence versions shown to the reviewer.
CREATE FUNCTION public.review_business_evidence(_business_id UUID,_status public.verification_status,_versions UUID[],_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE actual UUID[];
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Administrator required.'; END IF;
  PERFORM 1 FROM public.businesses WHERE id=_business_id FOR UPDATE;
  PERFORM 1 FROM public.license_documents WHERE business_id=_business_id FOR UPDATE;
  SELECT coalesce(array_agg(version_id ORDER BY version_id),'{}') INTO actual FROM public.license_documents WHERE business_id=_business_id;
  IF actual IS DISTINCT FROM ARRAY(SELECT unnest(coalesce(_versions,'{}'::UUID[])) ORDER BY 1) THEN RAISE EXCEPTION 'Evidence changed. Reload and review the current documents.'; END IF;
  IF _status NOT IN ('approved','rejected') OR (_status='rejected' AND nullif(btrim(_reason),'') IS NULL) THEN RAISE EXCEPTION 'Review decision and rejection reason required.'; END IF;
  IF EXISTS(SELECT 1 FROM public.license_documents d WHERE d.business_id=_business_id AND NOT EXISTS
    (SELECT 1 FROM storage.objects o WHERE o.bucket_id='licenses' AND o.name=d.storage_path)) THEN RAISE EXCEPTION 'Review blocked: evidence object is missing.'; END IF;
  UPDATE public.license_documents SET reviewed_by=auth.uid(),reviewed_at=now(),review_status=_status::TEXT WHERE business_id=_business_id;
  UPDATE public.businesses SET verification_status=_status,rejection_reason=CASE WHEN _status='rejected' THEN _reason ELSE NULL END WHERE id=_business_id;
END $$;
CREATE FUNCTION public.phase2_review_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF NEW.verification_status='approved' AND OLD.verification_status<>'approved' AND EXISTS
    (SELECT 1 FROM public.license_documents d WHERE d.business_id=NEW.id AND (d.review_status<>'approved' OR d.reviewed_by IS NULL OR d.reviewed_at IS NULL)) THEN
    RAISE EXCEPTION 'Current evidence must be reviewed before approval.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_review_guard BEFORE UPDATE ON public.businesses FOR EACH ROW EXECUTE FUNCTION public.phase2_review_guard();
REVOKE ALL ON FUNCTION public.review_business_evidence(UUID,public.verification_status,UUID[],TEXT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.review_business_evidence(UUID,public.verification_status,UUID[],TEXT) TO authenticated;

CREATE TABLE public.server_audit_context(transaction_id BIGINT PRIMARY KEY,actor_id UUID NOT NULL);
ALTER TABLE public.server_audit_context ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.server_audit_context FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.change_business_staff(_caller_id UUID,_business_id UUID,_user_id UUID,_role public.staff_role,_status public.staff_status,_invite BOOLEAN DEFAULT FALSE)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE member public.business_staff%ROWTYPE;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=_business_id AND
    (b.owner_id=_caller_id OR public.get_staff_role(_caller_id,b.id) IN ('owner','manager'))) THEN RAISE EXCEPTION 'Staff access denied.'; END IF;
  IF _role='owner' THEN RAISE EXCEPTION 'Owner membership is protected.'; END IF;
  IF _status<>'inactive' AND EXISTS(SELECT 1 FROM public.platform_staff WHERE user_id=_user_id AND status IN ('pending','active')) THEN RAISE EXCEPTION 'Platform and tenant membership conflict.'; END IF;
  INSERT INTO public.server_audit_context VALUES(txid_current(),_caller_id);
  SELECT * INTO member FROM public.business_staff WHERE business_id=_business_id AND user_id=_user_id FOR UPDATE;
  IF _invite THEN
    IF FOUND OR _status<>'pending' THEN RAISE EXCEPTION 'Invitation cannot overwrite existing membership.'; END IF;
    INSERT INTO public.business_staff(business_id,user_id,role,status,invited_by) VALUES(_business_id,_user_id,_role,'pending',_caller_id);
  ELSE
    IF NOT FOUND OR member.role='owner' THEN RAISE EXCEPTION 'Membership unavailable or protected.'; END IF;
    UPDATE public.business_staff SET role=_role,status=_status WHERE id=member.id;
  END IF;
  DELETE FROM public.server_audit_context WHERE transaction_id=txid_current();
END $$;
REVOKE ALL ON FUNCTION public.change_business_staff(UUID,UUID,UUID,public.staff_role,public.staff_status,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.change_business_staff(UUID,UUID,UUID,public.staff_role,public.staff_status,BOOLEAN) TO service_role;
-- Harden execution on all internal trigger helpers introduced here.
REVOKE ALL ON FUNCTION public.phase2_inventory_audit(),public.phase2_identity_guard(),public.phase2_offer_supplier_guard(),
  public.phase2_document_guard(),public.phase2_document_audit(),public.phase2_review_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.list_marketplace_catalogue()
RETURNS JSONB LANGUAGE SQL STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(entry ORDER BY entry->>'name'), '[]'::JSONB) FROM (
    SELECT jsonb_build_object('id', m.id, 'name', m.name, 'generic_name', m.generic_name,
      'strength', m.strength, 'brand_name', m.brand_name, 'dosage_form', m.dosage_form,
      'pack_size', m.pack_size, 'category', c.name, 'offers', (
        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          'minimum_order_quantity', w.minimum_order_quantity, 'lead_time_days', w.lead_time_days,
          'wholesaler', jsonb_build_object('id', b.id, 'name', b.name, 'city', b.city, 'region', b.region, 'verification_status', b.verification_status)) ORDER BY p.price_ghs, p.id)
        FROM public.wholesaler_products w JOIN public.products p ON p.id = w.id
        JOIN public.businesses b ON b.id = w.wholesaler_id
        WHERE w.product_id = m.id AND w.wholesaler_id=p.wholesaler_id AND public.product_import_identity(m.name,m.brand_name,m.dosage_form,m.pack_size)=public.product_import_identity(p.name,p.brand,p.form,p.pack_size) AND w.active AND p.active AND b.verification_status = 'approved'
      )) entry
    FROM public.master_products m LEFT JOIN public.product_categories c ON c.id = m.category_id
    WHERE m.active AND auth.uid() IS NOT NULL
  ) catalogue WHERE entry->'offers' IS NOT NULL AND entry->'offers' <> 'null'::JSONB
$$;
REVOKE ALL ON FUNCTION public.list_marketplace_catalogue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_marketplace_catalogue() TO authenticated;

CREATE OR REPLACE FUNCTION public.preview_wholesaler_import(
  _business_id UUID, _products JSONB, _mode TEXT,
  _confirm_token TEXT DEFAULT NULL, _request_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_product public.products%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_price NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.product_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = _business_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'wholesaler' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved wholesaler account is required.';
  END IF;
  IF NOT (biz.owner_id = auth.uid() OR COALESCE(public.get_staff_role(auth.uid(), _business_id)::TEXT IN ('owner', 'manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only owners and managers can import products.';
  END IF;
  IF _mode NOT IN ('replace', 'add', 'details') OR _mode IS NULL THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(_products) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected a product array.'; END IF;
  IF jsonb_array_length(_products) = 0 OR jsonb_array_length(_products) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 products at a time.';
  END IF;
  payload_hash := md5(_products::TEXT || _mode || _business_id::TEXT);
  IF _confirm_token IS NOT NULL THEN
    IF _request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    -- Serialize commits against imports, manual edits, and order stock updates.
    -- This short transaction lock also protects missing rows (new products).
    LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.product_import_runs WHERE id = _request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.wholesaler_id <> _business_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(_products) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR nullif(btrim(item->>'name'), '') IS NULL
      OR coalesce(item->>'price_ghs', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      OR (item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$') THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Invalid name, price or stock.'));
      CONTINUE;
    END IF;
    input_price := (item->>'price_ghs')::NUMERIC;
    IF input_price <= 0 OR input_price > 99999999.99 OR COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Price or stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    identity_key := public.product_import_identity(item->>'name', item->>'brand', coalesce(nullif(item->>'form', ''), ''), item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated product identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);
    SELECT count(*) INTO matches FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing products match. Resolve the catalogue collision first.'));
      CONTINUE;
    END IF;
    SELECT * INTO old_product FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    new_stock := CASE
      WHEN _mode = 'details' THEN coalesce(old_product.stock, 0)
      WHEN input_stock IS NULL THEN coalesce(old_product.stock, 0)
      WHEN _mode = 'add' THEN coalesce(old_product.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;
    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_product.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_product.id IS NULL THEN 'new' ELSE 'existing' END,
      'before', CASE WHEN old_product.id IS NULL THEN NULL ELSE to_jsonb(old_product) END,
      'price_before', old_product.price_ghs, 'price_after', input_price,
      'stock_before', old_product.stock, 'stock_after', new_stock,
      'product', item
    ));
  END LOOP;
  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', _mode);
  IF _confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF _confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,import_run_id,request_id)
    VALUES(txid_current(),auth.uid(),CASE WHEN _mode='add' THEN 'import_add' ELSE 'import_replace' END,_request_id,_request_id);
  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.products (wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, image_hue, active)
      VALUES (_business_id, item->>'name', nullif(btrim(item#>>'{product,brand}'), ''),
        coalesce(nullif(item#>>'{product,category}', ''), 'Other'), coalesce(nullif(item#>>'{product,form}', ''), ''),
        nullif(btrim(item#>>'{product,pack_size}'), ''), (item->>'price_after')::NUMERIC, (item->>'stock_after')::INTEGER,
        coalesce((item#>>'{product,image_hue}')::INTEGER, 200), TRUE) RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.products SET name = item->>'name', brand = nullif(btrim(item#>>'{product,brand}'), ''),
        category = coalesce(nullif(item#>>'{product,category}', ''), 'Other'), form = coalesce(nullif(item#>>'{product,form}', ''), ''),
        pack_size = nullif(btrim(item#>>'{product,pack_size}'), ''), price_ghs = (item->>'price_after')::NUMERIC,
        stock = (item->>'stock_after')::INTEGER, image_hue = coalesce((item#>>'{product,image_hue}')::INTEGER, 200)
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;
    PERFORM public.write_audit_log('Inventory imported', biz.name, 'product', saved_id, item->>'name',
      jsonb_build_object('request_id', _request_id, 'mode', _mode, 'before', item->'before',
        'after', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = saved_id)));
  END LOOP;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;


-- Source: 20260914130000_checkout_audit_actor.sql
-- Forward correction: attribute generic checkout audit events using the already validated
-- service-only checkout caller. No new caller-controlled RPC parameters or grants.

DO $migration$
DECLARE definition TEXT; marker TEXT := '    INSERT INTO public.orders (';
BEGIN
  SELECT pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid)'::regprocedure) INTO definition;
  IF position(marker IN definition)=0 OR position('    RETURNING id INTO v_order_id;' IN definition)=0 THEN
    RAISE EXCEPTION 'Unexpected checkout definition; review before applying audit correction.';
  END IF;
  definition := replace(definition, marker,
    '    INSERT INTO public.server_audit_context(transaction_id,actor_id) VALUES(txid_current(),_caller_id);' || chr(10) || marker);
  definition := replace(definition, '    RETURNING id INTO v_order_id;',
    '    RETURNING id INTO v_order_id;' || chr(10) || '    DELETE FROM public.server_audit_context WHERE transaction_id=txid_current();');
  EXECUTE definition;
END $migration$;

COMMIT;
