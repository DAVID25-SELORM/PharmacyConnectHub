-- PRE-FLIGHT for 20261210100000_billing_pricing_controls.sql (pricing controls). READ-ONLY: nothing here writes.
-- Run it in the PRODUCTION SQL Editor (project PharmacyConnectHub, ywpntuioeqpreouauuir) BEFORE applying the migration.
-- Every row must say ok = true. If any row says false, do not apply: send me the result.
-- (Function fingerprints are md5 of the function body with carriage returns removed, so pasting from Windows does not change them.)
WITH expected(fn, md5_expected) AS (
  VALUES
    ('_billing_admin_reason',               'a471469f62b951e724bf6f47bb26efd0'),
    ('_billing_ensure_period',              '591afbfdb090b12829579f874986de62'),
    ('admin_billing_change_plan',           '38bb066c00b1b902c0967df918032935'),
    ('admin_billing_publish_plan_version',  'c7ce4e57f17984e0262465f88ffe56a6'),
    ('admin_billing_start_subscription',    '423de24ed18677462ac63666ec9b2c46'),
    ('billing_assess_order',                '5f81b19a048d30628d470df913f8e4cf'),
    ('billing_run_scheduled',               'b48cd9d5c9c1343e042ba84e815ef51c')
),
actual AS (
  SELECT p.proname AS fn, md5(replace(p.prosrc, chr(13), '')) AS md5_actual
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname IN (SELECT fn FROM expected)
)
SELECT '1 an active platform owner with the administrator role exists' AS check_name,
       EXISTS (SELECT 1 FROM public.platform_staff ps WHERE ps.role = 'owner' AND ps.status = 'active' AND public.has_role(ps.user_id, 'admin')) AS ok,
       'After this change only the platform owner can change billing. The migration refuses to apply without one. Owners found: '
         || (SELECT count(*) FROM public.platform_staff ps WHERE ps.role = 'owner' AND ps.status = 'active' AND public.has_role(ps.user_id, 'admin'))::text AS detail
UNION ALL
SELECT '2 billing is not live for anyone',
       NOT EXISTS (SELECT 1 FROM public.billing_subscriptions WHERE activated_at IS NOT NULL),
       'Platform mode: ' || COALESCE((SELECT mode FROM public.billing_settings LIMIT 1), 'unknown') || '. Applying this does not switch billing on, but the checks assume nothing is live yet.'
UNION ALL
SELECT '3 no plan version is dated in the future',
       NOT EXISTS (SELECT 1 FROM public.billing_plan_versions WHERE effective_from > now()),
       'Today a version dated in the future takes effect at once. After this change it would wait for its date, so any such version must be looked at first. Found: '
         || (SELECT count(*) FROM public.billing_plan_versions WHERE effective_from > now())::text
UNION ALL
SELECT '4 each plan newest version also has the latest start date',
       NOT EXISTS (
         SELECT 1 FROM public.billing_plan_versions a JOIN public.billing_plan_versions b ON a.plan_id = b.plan_id AND a.version < b.version AND a.effective_from > b.effective_from),
       'The new rule picks the version by start date. If a newer version had an older date, a different version could be chosen than today.'
UNION ALL
SELECT '5 every plan version has a status the new rule understands',
       NOT EXISTS (SELECT 1 FROM public.billing_plan_versions WHERE status NOT IN ('published', 'retired')),
       'Existing versions are all published or retired. Statuses seen: '
         || COALESCE((SELECT string_agg(DISTINCT status, ', ') FROM public.billing_plan_versions), 'none (no versions yet)')
UNION ALL
SELECT '6 the new objects are not already there',
       to_regclass('public.billing_scheduled_changes') IS NULL
         AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'billing_settings' AND column_name = 'commissions_enabled'),
       'If this is false the migration (or part of it) has already been applied.'
UNION ALL
SELECT '7 function ' || e.fn || ' is exactly the version the migration expects to replace',
       a.md5_actual = e.md5_expected,
       CASE WHEN a.md5_actual IS NULL THEN 'The function does not exist.' ELSE 'found ' || a.md5_actual || ', expected ' || e.md5_expected END
FROM expected e LEFT JOIN actual a ON a.fn = e.fn
ORDER BY 1;
