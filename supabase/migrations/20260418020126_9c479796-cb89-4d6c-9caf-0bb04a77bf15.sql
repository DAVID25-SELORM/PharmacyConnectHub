
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
  user_count INT;
  signup_role public.app_role;
BEGIN
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', ''), COALESCE(NEW.raw_user_meta_data->>'phone', ''));

  signup_role := COALESCE((NEW.raw_user_meta_data->>'role')::public.app_role, 'pharmacy');
  INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, signup_role);

  SELECT COUNT(*) INTO user_count FROM auth.users;
  IF user_count = 1 THEN
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
