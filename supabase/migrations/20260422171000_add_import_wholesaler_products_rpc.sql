-- Keep wholesaler bulk uploads idempotent by updating existing catalog rows
-- instead of duplicating them on re-import.

WITH ranked_products AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY
        wholesaler_id,
        lower(BTRIM(name)),
        COALESCE(lower(BTRIM(brand)), ''),
        COALESCE(lower(BTRIM(form)), ''),
        COALESCE(lower(BTRIM(pack_size)), '')
      ORDER BY updated_at DESC, created_at DESC, id DESC
    ) AS row_rank
  FROM public.products
)
DELETE FROM public.products AS p
USING ranked_products
WHERE p.id = ranked_products.id
  AND ranked_products.row_rank > 1;

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
