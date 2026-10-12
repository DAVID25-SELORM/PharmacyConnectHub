-- Platform billing, Phase 1 (schema and configuration): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- It also reports that billing is OFF: mode disabled, no subscriptions, no ledger entries, no assessments, and the example plans switched off.
WITH
  tbl(name) AS (VALUES ('billing_settings'), ('billing_feature_catalog'), ('billing_plans'), ('billing_plan_versions'), ('billing_subscriptions'), ('billing_subscription_terms'),
                       ('billing_allowance_grants'), ('billing_periods'), ('order_billing_assessments'), ('billing_ledger_entries')),
  fns  AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  checks(item, ok) AS (VALUES
  ('all ten billing tables exist', (SELECT count(*) FROM tbl WHERE to_regclass('public.' || name) IS NOT NULL) = 10),
  ('row level security is on for every billing table', (SELECT count(*) FROM pg_class c JOIN tbl t ON t.name = c.relname WHERE c.relnamespace = 'public'::regnamespace AND c.relrowsecurity) = 10),
  ('no signed-in or anonymous user can insert, update or delete any billing table',
    NOT EXISTS (SELECT 1 FROM tbl t, unnest(ARRAY['authenticated', 'anon']) r, unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) p
                WHERE to_regclass('public.' || t.name) IS NOT NULL AND has_table_privilege(r, 'public.' || t.name, p))),
  ('anonymous visitors cannot read any billing table', NOT EXISTS (SELECT 1 FROM tbl t WHERE to_regclass('public.' || t.name) IS NOT NULL AND has_table_privilege('anon', 'public.' || t.name, 'SELECT'))),
  ('the ledger, assessments, grants and terms are append-only (triggers present)',
    EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_ledger_append_only') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_assessments_append_only')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_grants_append_only') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_terms_append_only')),
  ('plan versions, plans, subscriptions and periods are guarded',
    EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_plan_versions_guard') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_plans_guard')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_subscriptions_guard') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_periods_guard')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_subscription_terms_guard')),
  ('one primary assessment per order, and each free-order number used once (unique indexes present)',
    to_regclass('public.order_billing_primary_real_idx') IS NOT NULL AND to_regclass('public.order_billing_primary_shadow_idx') IS NOT NULL
    AND to_regclass('public.order_billing_onboarding_seq_idx') IS NOT NULL AND to_regclass('public.order_billing_monthly_seq_idx') IS NOT NULL AND to_regclass('public.billing_ledger_reverses_idx') IS NOT NULL),
  ('the launch free-order grant is once per licence and once per owner (unique indexes present)', to_regclass('public.billing_allowance_grants_plan_licence_idx') IS NOT NULL AND to_regclass('public.billing_allowance_grants_plan_owner_idx') IS NOT NULL),
  ('the idempotency key on the ledger is unique', EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'billing_ledger_entries' AND indexdef LIKE '%UNIQUE%' AND indexdef LIKE '%idempotency_key%')),
  ('the helper functions exist', EXISTS (SELECT 1 FROM fns WHERE name = 'billing_period_bounds') AND EXISTS (SELECT 1 FROM fns WHERE name = 'billing_resolve_terms') AND EXISTS (SELECT 1 FROM fns WHERE name = 'billing_effective_mode')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'billing_onboarding_keys') AND EXISTS (SELECT 1 FROM fns WHERE name = 'billing_feature_enabled') AND EXISTS (SELECT 1 FROM fns WHERE name = 'billing_limit')),
  ('the six administrator operations exist', (SELECT count(*) FROM fns WHERE name IN ('admin_billing_set_mode', 'admin_billing_create_plan', 'admin_billing_publish_plan_version',
     'admin_billing_set_plan_availability', 'admin_billing_start_subscription', 'admin_billing_set_subscription_mode')) = 6),
  ('the server-only helpers cannot be called by signed-in users',
    to_regprocedure('public.billing_period_bounds(timestamptz,integer,timestamptz,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.billing_period_bounds(timestamptz,integer,timestamptz,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.billing_resolve_terms(uuid,timestamptz)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public.billing_effective_mode(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public._billing_admin_reason(text)', 'EXECUTE')),
  ('the administrator operations cannot be called by anonymous visitors', NOT has_function_privilege('anon', 'public.admin_billing_set_mode(text,text)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.admin_billing_start_subscription(uuid,text,timestamptz,text,text)', 'EXECUTE')),
  ('no money column uses floating point', NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name IN (SELECT name FROM tbl) AND data_type IN ('real', 'double precision'))),
  ('the feature catalog is seeded', (SELECT count(*) FROM public.billing_feature_catalog) >= 7),
  ('billing is OFF: mode is disabled', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled'),
  ('nothing is billed: no subscriptions, periods, assessments or ledger entries yet',
    (SELECT count(*) FROM public.billing_subscriptions) + (SELECT count(*) FROM public.billing_periods) + (SELECT count(*) FROM public.order_billing_assessments) + (SELECT count(*) FROM public.billing_ledger_entries) = 0),
  ('the example plans (if present) are switched off and hidden', NOT EXISTS (SELECT 1 FROM public.billing_plans WHERE (metadata ->> 'example') = 'true' AND (active OR publicly_visible)))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode, (SELECT count(*) FROM public.billing_plans) AS plans
FROM checks;
