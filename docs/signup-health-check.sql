-- SIGNUP HEALTH CHECK. READ-ONLY: nothing here writes. Run in the PRODUCTION SQL Editor (PharmacyConnectHub, ywpntuioeqpreouauuir).
-- Part A: should return zero rows. Any row is a user who signed up but has no business (the signup trigger failed to build the workspace).
SELECT 'A: signed up without a business' AS check_name, u.id, u.email, u.created_at, u.email_confirmed_at,
       u.raw_user_meta_data->>'role' AS role, u.raw_user_meta_data->>'business_name' AS business_name
FROM auth.users u
WHERE COALESCE(u.raw_user_meta_data->>'is_staff_invite', '') <> 'true'
  AND NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.owner_id = u.id)
  AND NOT EXISTS (SELECT 1 FROM public.user_roles r WHERE r.user_id = u.id AND r.role = 'admin')
  AND NOT EXISTS (SELECT 1 FROM public.platform_staff ps WHERE ps.user_id = u.id)
  AND NOT EXISTS (SELECT 1 FROM public.business_staff m WHERE m.user_id = u.id)
ORDER BY u.created_at DESC;

-- Part B: the last 15 signups and what became of them.
SELECT 'B: recent signups' AS check_name, u.email, u.created_at, u.email_confirmed_at IS NOT NULL AS email_confirmed,
       u.last_sign_in_at IS NOT NULL AS has_signed_in, b.name AS business, b.type, b.verification_status
FROM auth.users u LEFT JOIN public.businesses b ON b.owner_id = u.id
ORDER BY u.created_at DESC LIMIT 15;

-- Part C: every trigger that runs when someone signs up (a failing one here blocks signup for everybody).
SELECT 'C: signup triggers' AS check_name, c.relname AS on_table, t.tgname AS trigger_name, p.proname AS function_name
FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_proc p ON p.oid = t.tgfoid
WHERE NOT t.tgisinternal AND ((n.nspname = 'auth' AND c.relname = 'users')
   OR (n.nspname = 'public' AND c.relname IN ('profiles', 'user_roles', 'businesses', 'business_private_contacts')))
ORDER BY 2, 3;
