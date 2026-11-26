-- Remember this device: run AFTER applying 20261217100000_remembered_devices.sql. READ-ONLY. Every row must say true.
WITH people(fn) AS (
  VALUES ('public.remember_this_device(text)'), ('public.use_remembered_device(text)'), ('public.forget_my_devices(text)'), ('public.my_remembered_device_count()'), ('public.mfa_session_ok()')
)
SELECT * FROM (VALUES
  (1, 'the two new tables exist with row security', (SELECT count(*) = 2 AND bool_and(relrowsecurity) FROM pg_class WHERE oid IN (to_regclass('public.remembered_devices'), to_regclass('public.remembered_sessions')))),
  (2, 'nobody signed in, and no visitor, can read or write them', NOT has_table_privilege('authenticated', 'public.remembered_devices', 'SELECT, INSERT, UPDATE, DELETE')
        AND NOT has_table_privilege('authenticated', 'public.remembered_sessions', 'SELECT, INSERT, UPDATE, DELETE')
        AND NOT has_table_privilege('anon', 'public.remembered_devices', 'SELECT, INSERT, UPDATE, DELETE') AND NOT has_table_privilege('anon', 'public.remembered_sessions', 'SELECT, INSERT, UPDATE, DELETE')),
  (3, 'signed-in people can call their own functions', (SELECT bool_and(has_function_privilege('authenticated', fn, 'EXECUTE')) FROM people)),
  (4, 'visitors cannot call any of them', (SELECT NOT bool_or(has_function_privilege('anon', fn, 'EXECUTE')) FROM people) AND NOT has_function_privilege('anon', 'public.mfa_remembered_session_ok(uuid,uuid)', 'EXECUTE')),
  (5, 'only the server can ask about another person''s session', NOT has_function_privilege('authenticated', 'public.mfa_remembered_session_ok(uuid,uuid)', 'EXECUTE')
        AND has_function_privilege('service_role', 'public.mfa_remembered_session_ok(uuid,uuid)', 'EXECUTE')),
  (6, 'the account fingerprint function is closed to people', NOT has_function_privilege('authenticated', 'public._mfa_credential_stamp(uuid)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public._mfa_credential_stamp(uuid)', 'EXECUTE')),
  (7, 'the admin rule accepts a remembered device', (SELECT prosrc LIKE '%mfa_session_ok()%' AND prosrc LIKE '%admin_mfa_required()%' FROM pg_proc WHERE oid = 'public.has_role(uuid,public.app_role)'::regprocedure)),
  (8, 'no device can be given more than 7 days', EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.remembered_devices'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%7 days%'))
) t(n, check_name, ok) ORDER BY n;
