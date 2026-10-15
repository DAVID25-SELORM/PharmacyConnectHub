-- Read-only checks after applying 20261208100000_billing_shadow_review.sql. Nothing here writes.
-- Every row should say ok = true.
SELECT 'function exists' AS check_name,
       to_regprocedure('public.admin_billing_shadow_review(integer)') IS NOT NULL AS ok,
       'The Billing Setup page uses it for the independent recalculation of shadow fees.' AS note
UNION ALL
SELECT 'runs with the definer rights and a fixed search path',
       COALESCE((SELECT p.prosecdef AND p.proconfig::text LIKE '%search_path=public%'
                 FROM pg_proc p WHERE p.oid = to_regprocedure('public.admin_billing_shadow_review(integer)')), false),
       'Same as the other administrator billing functions.'
UNION ALL
SELECT 'read-only (STABLE)',
       COALESCE((SELECT p.provolatile = 's' FROM pg_proc p WHERE p.oid = to_regprocedure('public.admin_billing_shadow_review(integer)')), false),
       'It cannot write: the database refuses writes inside a STABLE function.'
UNION ALL
SELECT 'signed-out visitors cannot run it',
       NOT has_function_privilege('anon', 'public.admin_billing_shadow_review(integer)', 'EXECUTE'),
       'Only signed-in users can call it, and it then refuses anyone who is not a platform administrator.'
UNION ALL
SELECT 'signed-in users can call it (it checks for an administrator inside)',
       has_function_privilege('authenticated', 'public.admin_billing_shadow_review(integer)', 'EXECUTE'),
       'Same arrangement as the other admin_billing_* functions.'
UNION ALL
SELECT 'billing is not live',
       NOT EXISTS (SELECT 1 FROM public.billing_subscriptions WHERE activated_at IS NOT NULL),
       'Applying this changes no billing behaviour either way.';
