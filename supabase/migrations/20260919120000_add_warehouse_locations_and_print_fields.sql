-- Optional warehouse locations. Existing inventory remains valid without them.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS warehouse TEXT,
  ADD COLUMN IF NOT EXISTS zone TEXT,
  ADD COLUMN IF NOT EXISTS rack TEXT,
  ADD COLUMN IF NOT EXISTS shelf TEXT,
  ADD COLUMN IF NOT EXISTS bin TEXT;

CREATE OR REPLACE FUNCTION public.product_storage_location(p public.products)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
  SELECT NULLIF(array_to_string(ARRAY[p.warehouse, p.zone, p.rack, p.shelf, p.bin], '-'), '');
$$;

REVOKE ALL ON FUNCTION public.product_storage_location(public.products) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.product_storage_location(public.products) TO authenticated, service_role;
