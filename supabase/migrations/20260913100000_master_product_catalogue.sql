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
