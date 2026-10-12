-- Platform billing, Phase 3 (the read functions behind the billing screens): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- Phase 3 changes no data: it also confirms billing is still off and nothing has been assessed.
WITH
  fns AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  checks(item, ok) AS (VALUES
  ('the four read functions exist (my overview, administrator overview, organizations table, business detail)',
    (SELECT count(*) FROM fns WHERE name IN ('billing_my_overview', 'admin_billing_overview', 'admin_billing_organizations', 'admin_billing_business_detail')) = 4),
  ('the two internal helpers exist', (SELECT count(*) FROM fns WHERE name IN ('_billing_admin_only', '_billing_flavor_summary')) = 2),
  ('visitors who are not signed in cannot call any of the four read functions', NOT has_function_privilege('anon', 'public.billing_my_overview(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_overview(timestamp with time zone, timestamp with time zone, text, text, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_organizations(text, text, text, text, text, integer, integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_business_detail(uuid, text)', 'EXECUTE')),
  ('signed-in users can call them (each one checks who is asking)', has_function_privilege('authenticated', 'public.billing_my_overview(uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.admin_billing_overview(timestamp with time zone, timestamp with time zone, text, text, text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.admin_billing_organizations(text, text, text, text, text, integer, integer)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.admin_billing_business_detail(uuid, text)', 'EXECUTE')),
  ('the internal helpers cannot be called by signed-in users or visitors', NOT has_function_privilege('authenticated', 'public._billing_admin_only()', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public._billing_admin_only()', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public._billing_flavor_summary(boolean, timestamp with time zone, timestamp with time zone, uuid[])', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public._billing_flavor_summary(boolean, timestamp with time zone, timestamp with time zone, uuid[])', 'EXECUTE')),
  ('all four read functions only read (none is volatile)', (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('billing_my_overview', 'admin_billing_overview', 'admin_billing_organizations', 'admin_billing_business_detail') AND provolatile = 'v') = 0),
  ('the read functions run with the owner''s rights and a fixed search path (they check the caller themselves)', (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
    AND proname IN ('billing_my_overview', 'admin_billing_overview', 'admin_billing_organizations', 'admin_billing_business_detail') AND prosecdef AND proconfig IS NOT NULL
    AND EXISTS (SELECT 1 FROM unnest(proconfig) c WHERE c LIKE 'search_path=%')) = 4),
  ('the business function checks the caller's role and business before reading anything', pg_get_functiondef('public.billing_my_overview(uuid)'::regprocedure) LIKE '%billing_user_can_view%'),
  ('the administrator functions check for an administrator', pg_get_functiondef('public.admin_billing_overview(timestamp with time zone, timestamp with time zone, text, text, text)'::regprocedure) LIKE '%_billing_admin_only%'
    AND pg_get_functiondef('public.admin_billing_organizations(text, text, text, text, text, integer, integer)'::regprocedure) LIKE '%_billing_admin_only%'
    AND pg_get_functiondef('public.admin_billing_business_detail(uuid, text)'::regprocedure) LIKE '%_billing_admin_only%'),
  ('billing is still OFF: mode is disabled', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled'),
  ('nothing is assessed, no period or ledger entry exists, and nothing is queued', (SELECT count(*) FROM public.order_billing_assessments) + (SELECT count(*) FROM public.billing_periods)
    + (SELECT count(*) FROM public.billing_ledger_entries) + (SELECT count(*) FROM public.billing_engine_queue) = 0),
  ('the reconciliation still finds nothing wrong', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode
FROM checks;
