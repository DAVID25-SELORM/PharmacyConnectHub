-- Admin two-step verification (migration 20261215100000).
-- Self-contained: makes its own two users, so it needs no setup.sql. Run with the migration
-- applied in the same transaction:
--   (echo 'BEGIN;'; cat <migration>; cat this-file; echo 'ROLLBACK;') | psql -v ON_ERROR_STOP=1
-- Everything is rolled back.

CREATE SCHEMA IF NOT EXISTS zz;
CREATE TABLE IF NOT EXISTS zz.results(seq SERIAL, name TEXT, ok BOOLEAN, detail TEXT);
CREATE OR REPLACE FUNCTION zz.check(p_name TEXT, p_ok BOOLEAN, p_detail TEXT DEFAULT '') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO zz.results(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
  RAISE NOTICE '% | %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;
GRANT USAGE ON SCHEMA zz TO authenticated;

CREATE OR REPLACE FUNCTION zz.as_aal(p_uid UUID, p_aal TEXT, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql;
    r := 'OK';
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

-- Evaluate a boolean expression as a signed-in user at a given assurance level.
CREATE OR REPLACE FUNCTION zz.bool_aal(p_uid UUID, p_aal TEXT, p_expr TEXT) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT ' || p_expr INTO v;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN v;
END $$;

DO $$
DECLARE
  u_admin UUID := '20000000-0000-0000-0000-0000000000a1';
  u_wo UUID := '20000000-0000-0000-0000-0000000000b1';
  r TEXT;
BEGIN
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  VALUES
    (u_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-admin2@zz.test',
      jsonb_build_object('role','pharmacy','business_name','TT Admin Pharmacy','license_number','AD-1','city','Accra','region','Greater Accra','full_name','Admin Two','phone','+233241000771','owner_is_superintendent', true), now(), now()),
    (u_wo, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-wo2@zz.test',
      jsonb_build_object('role','wholesaler','business_name','TT Wholesaler Two','license_number','WO-1','city','Accra','region','Greater Accra','full_name','Wholesale Two','phone','+233241000772','owner_is_superintendent', true), now(), now());
  INSERT INTO public.user_roles(user_id, role) VALUES (u_admin, 'admin') ON CONFLICT DO NOTHING;
  -- Other admins already in this database would block turning the rule on; none are enrolled.
  DELETE FROM public.user_roles WHERE role = 'admin' AND user_id <> u_admin;

  -- Off by default: nothing changes until an admin switches it on.
  PERFORM zz.check('the rule ships switched off', public.admin_mfa_required() = FALSE);
  PERFORM zz.check('off: an admin at aal1 still has the admin role',
    zz.bool_aal(u_admin, 'aal1', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
  PERFORM zz.check('off: a non-admin is still not an admin',
    NOT zz.bool_aal(u_wo, 'aal2', format($e$public.has_role(%L::uuid,'admin')$e$, u_wo)));
  PERFORM zz.check('off: payment_user_is_admin passes at aal1', public.payment_user_is_admin(u_admin, 'aal1'));

  -- Nobody reads or writes the switch directly.
  r := zz.as_aal(u_admin, 'aal2', 'SELECT * FROM public.platform_security_settings');
  PERFORM zz.check('even an admin cannot read the switch table directly', r LIKE 'ERR:%', r);
  r := zz.as_aal(u_wo, 'aal2', 'UPDATE public.platform_security_settings SET admin_mfa_required = TRUE');
  PERFORM zz.check('a non-admin cannot flip the switch directly', r LIKE 'ERR:%', r);
  PERFORM zz.check('switch is still off', public.admin_mfa_required() = FALSE);

  -- Turning it on has guards.
  r := zz.as_aal(u_wo, 'aal2', 'SELECT public.set_admin_mfa_required(TRUE)');
  PERFORM zz.check('non-admin cannot turn it on', r LIKE 'ERR: Only platform admins%', r);
  r := zz.as_aal(u_admin, 'aal1', 'SELECT public.set_admin_mfa_required(TRUE)');
  PERFORM zz.check('an admin who has not passed the code step cannot turn it on', r LIKE 'ERR: Verify with your authenticator%', r);
  r := zz.as_aal(u_admin, 'aal2', 'SELECT public.set_admin_mfa_required(TRUE)');
  PERFORM zz.check('refused while an admin has no authenticator app (no lock-out)', r LIKE 'ERR: These admins have not set up%', r);
  PERFORM zz.check('still off after the refusals', public.admin_mfa_required() = FALSE);

  r := zz.as_aal(u_admin, 'aal2', 'SELECT public.get_admin_mfa_status()');
  PERFORM zz.check('admin can read the status', r = 'OK', r);
  r := zz.as_aal(u_wo, 'aal2', 'SELECT public.get_admin_mfa_status()');
  PERFORM zz.check('non-admin cannot read the status', r LIKE 'ERR: Only platform admins%', r);

  -- The admin enrols an authenticator app (a verified TOTP factor).
  INSERT INTO auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at)
  VALUES (gen_random_uuid(), u_admin, 'totp', 'verified', now(), now());

  r := zz.as_aal(u_admin, 'aal2', 'SELECT public.set_admin_mfa_required(TRUE)');
  PERFORM zz.check('with every admin enrolled and aal2, it turns on', r = 'OK', r);
  PERFORM zz.check('the rule is now on', public.admin_mfa_required() = TRUE);
  PERFORM zz.check('turning it on was audited',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Admin two-step verification required' AND performed_by = u_admin));

  -- On: the database refuses admin powers below aal2.
  PERFORM zz.check('on: an admin at aal1 loses the admin role',
    NOT zz.bool_aal(u_admin, 'aal1', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
  PERFORM zz.check('on: an admin with no level in the token is treated as aal1',
    NOT zz.bool_aal(u_admin, '', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
  PERFORM zz.check('on: an admin at aal2 keeps the admin role',
    zz.bool_aal(u_admin, 'aal2', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
  PERFORM zz.check('on: other roles are unaffected at aal1',
    zz.bool_aal(u_wo, 'aal1', format($e$public.has_role(%L::uuid,'wholesaler')$e$, u_wo)));
  PERFORM zz.check('on: asking about another person is unaffected (no session of theirs to judge)',
    zz.bool_aal(u_wo, 'aal1', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
  PERFORM zz.check('on: server code with no session is unaffected', public.has_role(u_admin, 'admin'));

  r := zz.as_aal(u_admin, 'aal1', 'SELECT public.get_admin_mfa_status()');
  PERFORM zz.check('on: an admin RPC refuses an aal1 session', r LIKE 'ERR: Only platform admins%', r);
  r := zz.as_aal(u_admin, 'aal1', 'SELECT public.set_admin_mfa_required(FALSE)');
  PERFORM zz.check('on: an aal1 admin cannot turn it off', r LIKE 'ERR: Only platform admins%', r);

  -- Server-side callers (service role) pass the token's level.
  PERFORM zz.check('on: payment_user_is_admin refuses aal1', NOT public.payment_user_is_admin(u_admin, 'aal1'));
  PERFORM zz.check('on: payment_user_is_admin refuses a missing level', NOT public.payment_user_is_admin(u_admin, NULL));
  PERFORM zz.check('on: payment_user_is_admin accepts aal2', public.payment_user_is_admin(u_admin, 'aal2'));
  PERFORM zz.check('on: a one-argument call keeps working (default passes)', public.payment_user_is_admin(u_admin));
  PERFORM zz.check('admin_mfa_ok follows the rule', NOT public.admin_mfa_ok('aal1') AND public.admin_mfa_ok('aal2'));
  PERFORM zz.check('a non-admin is never an admin for payments', NOT public.payment_user_is_admin(u_wo, 'aal2'));
  r := zz.as_aal(u_admin, 'aal2', 'SELECT public.admin_mfa_ok(''aal2'')');
  PERFORM zz.check('browser sessions cannot call the server-side check', r LIKE 'ERR:%', r);

  -- Turning it off (recovery path for the owner).
  r := zz.as_aal(u_admin, 'aal2', 'SELECT public.set_admin_mfa_required(FALSE)');
  PERFORM zz.check('an aal2 admin can turn it off', r = 'OK', r);
  PERFORM zz.check('off again: aal1 admin works again',
    zz.bool_aal(u_admin, 'aal1', format($e$public.has_role(%L::uuid,'admin')$e$, u_admin)));
END $$;

SELECT name, ok, detail FROM zz.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
