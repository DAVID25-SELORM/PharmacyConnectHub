-- Read-only. Lists every version of the functions the Pay Now (P2) patches rewrite, so a duplicate (an older version left behind) can be seen.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). Changes nothing.
SELECT p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       length(pg_get_functiondef(p.oid)) AS definition_length,
       pg_get_functiondef(p.oid) LIKE '%_settlement_methods%' AS knows_settlement_methods,
       pg_get_functiondef(p.oid) LIKE '%credit_apply_due_terms%' AS has_credit_checks,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS callable_by_signed_in_users,
       has_function_privilege('service_role', p.oid, 'EXECUTE') AS callable_by_service_role
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('create_marketplace_orders', 'create_marketplace_orders_once', 'notify_new_order', 'notify_payment_status_changed',
                    'change_order_settlement_method', 'apply_payment_result')
ORDER BY p.proname, arguments;
