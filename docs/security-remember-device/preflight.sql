-- Remember this device: run BEFORE applying 20261217100000_remembered_devices.sql. READ-ONLY. Every row must say true.
SELECT * FROM (VALUES
  (1, 'admin two-step is installed', to_regclass('public.platform_security_settings') IS NOT NULL),
  (2, 'remember-this-device is not applied yet', to_regclass('public.remembered_devices') IS NULL),
  (3, 'unchanged: has_role (the rule this change replaces)', EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'has_role'
        AND md5(regexp_replace(p.prosrc, '\s+', '', 'g')) = 'b0cec7cc1b0f54572a284388b5731cdc')),
  (4, 'the sign-in tables it reads exist', to_regclass('auth.mfa_factors') IS NOT NULL AND to_regclass('auth.users') IS NOT NULL)
) t(n, check_name, ok) ORDER BY n;
