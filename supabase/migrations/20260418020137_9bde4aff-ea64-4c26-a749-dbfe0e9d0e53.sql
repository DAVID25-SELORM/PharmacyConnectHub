
DROP INDEX IF EXISTS public.idx_products_name_trgm;
DROP EXTENSION IF EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE INDEX idx_products_name_trgm ON public.products USING gin (name extensions.gin_trgm_ops);
