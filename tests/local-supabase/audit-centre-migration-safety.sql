-- Run with psql after setup.sql and the migrations through 20261010.
-- Also supports a local database where Audit Centre is already installed.
-- All schema/fixture changes are rolled back.
\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.reject_history_changes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Inventory history is immutable; record a corrective operation.';
END;
$$;
CREATE TRIGGER test_audit_history_immutable BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_history_changes();
CREATE TEMP TABLE audit_before AS SELECT to_jsonb(a) AS row FROM public.audit_logs a;

-- Exercise a deployed implementation that differs from the repository's old template.
DO $$
DECLARE definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.preview_wholesaler_import(uuid,jsonb,text,text,uuid)'::regprocedure)
    INTO definition;
  definition := regexp_replace(definition, ',[[:space:]]*_business_id[[:space:]]*=>[[:space:]]*_business_id', '', 'g');
  definition := replace(definition, '''Tablet''', '''''');
  EXECUTE definition;
END;
$$;
CREATE TEMP TABLE import_before AS
SELECT pg_get_functiondef('public.preview_wholesaler_import(uuid,jsonb,text,text,uuid)'::regprocedure) AS definition;

\ir ../../supabase/migrations/20261011100000_audit_centre_schema.sql
\ir ../../supabase/migrations/20261011110000_audit_centre_logic.sql
\ir ../../supabase/migrations/20261011120000_audit_centre_logic_part2.sql
-- A retry after a failed SQL-editor run must be safe too.
\ir ../../supabase/migrations/20261011100000_audit_centre_schema.sql
\ir ../../supabase/migrations/20261011110000_audit_centre_logic.sql
\ir ../../supabase/migrations/20261011120000_audit_centre_logic_part2.sql

DO $$
DECLARE definition TEXT; writer REGPROCEDURE;
BEGIN
  IF EXISTS (
    (SELECT row - 'business_id' FROM audit_before EXCEPT SELECT to_jsonb(a) - 'business_id' FROM public.audit_logs a)
    UNION ALL
    (SELECT to_jsonb(a) - 'business_id' FROM public.audit_logs a EXCEPT SELECT row - 'business_id' FROM audit_before)
  ) THEN RAISE EXCEPTION 'Migration changed historical audit records'; END IF;

  SELECT pg_get_functiondef('public.preview_wholesaler_import(uuid,jsonb,text,text,uuid)'::regprocedure)
    INTO definition;
  IF definition NOT LIKE '%_business_id => _business_id%' THEN
    RAISE EXCEPTION 'Import attribution missing';
  END IF;
  IF regexp_replace(definition, ',[[:space:]]*_business_id[[:space:]]*=>[[:space:]]*_business_id', '', 'g')
      IS DISTINCT FROM (SELECT import_before.definition FROM import_before) THEN
    RAISE EXCEPTION 'Migration overwrote deployed import behavior';
  END IF;

  writer := 'public.write_audit_log(text,text,text,uuid,text,jsonb,uuid,text,text,uuid)'::regprocedure;
  IF has_function_privilege('anon', writer, 'EXECUTE')
     OR has_function_privilege('authenticated', writer, 'EXECUTE') THEN
    RAISE EXCEPTION 'Clients can forge audit records';
  END IF;
  IF NOT has_function_privilege('service_role', writer, 'EXECUTE') THEN
    RAISE EXCEPTION 'Trusted audit writer access missing';
  END IF;
  IF to_regprocedure('public.write_audit_log(text,text,text,uuid,text,jsonb,uuid,text,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'Ambiguous legacy audit writer still exists';
  END IF;
  RAISE NOTICE 'PASS: immutable history, deployed import preservation, reruns, and writer permissions';
END;
$$;
ROLLBACK;
