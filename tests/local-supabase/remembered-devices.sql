-- "Ask for the code on a new device, and again after 7 days": who can have a device remembered, when a remembered device counts, and every way it stops counting.
-- Run in an isolated local database after setup.sql and migrations through 20261217100000_remembered_devices.sql. Everything is rolled back.
BEGIN;
CREATE FUNCTION pg_temp.ok(label text, ok boolean, detail text DEFAULT '') RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL: % %', label, detail; END IF; RAISE NOTICE 'PASS: %', label; END $$;

-- Runs SQL as a signed-in person with exactly these token claims.
CREATE FUNCTION pg_temp.as_session(p_uid UUID, p_session UUID, p_aal TEXT, p_code_minutes_ago NUMERIC, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; amr JSONB := jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', floor(extract(epoch FROM now()))));
BEGIN
  IF p_code_minutes_ago IS NOT NULL THEN
    amr := amr || jsonb_build_object('method', 'totp', 'timestamp', floor(extract(epoch FROM now()) - p_code_minutes_ago * 60));
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'session_id', p_session, 'aal', p_aal, 'amr', amr)::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.factor(p_uid UUID) RETURNS UUID LANGUAGE sql AS $$
  INSERT INTO auth.mfa_factors(id, user_id, friendly_name, factor_type, status, created_at, updated_at, secret)
  VALUES (gen_random_uuid(), p_uid, 'Test app ' || gen_random_uuid(), 'totp', 'verified', now(), now(), 'not-a-real-secret') RETURNING id $$;
-- Signs in with the password only (a new session, no code) and offers the device's key.
CREATE FUNCTION pg_temp.offer(p_uid UUID, p_token TEXT, p_session UUID DEFAULT gen_random_uuid()) RETURNS TEXT LANGUAGE sql AS $$
  SELECT pg_temp.as_session(p_uid, p_session, 'aal1', NULL, format('SELECT public.use_remembered_device(%L)::text', p_token)) $$;
CREATE FUNCTION pg_temp.session_ok(p_uid UUID, p_session UUID) RETURNS TEXT LANGUAGE sql AS $$
  SELECT pg_temp.as_session(p_uid, p_session, 'aal1', NULL, 'SELECT public.mfa_session_ok()::text') $$;
CREATE FUNCTION pg_temp.is_admin(p_uid UUID, p_session UUID, p_aal TEXT DEFAULT 'aal1') RETURNS TEXT LANGUAGE sql AS $$
  SELECT pg_temp.as_session(p_uid, p_session, p_aal, NULL, format('SELECT public.has_role(%L, ''admin'')::text', p_uid)) $$;
CREATE FUNCTION pg_temp.remember(p_uid UUID, p_label TEXT DEFAULT 'Test browser') RETURNS TEXT LANGUAGE sql AS $$
  SELECT pg_temp.as_session(p_uid, gen_random_uuid(), 'aal2', 0, format('SELECT public.remember_this_device(%L)', p_label)) $$;

DO $$
DECLARE
  adm UUID := (SELECT id FROM zz.u WHERE k = 'admin');
  usr UUID := (SELECT id FROM zz.u WHERE k = 'w_owner');
  s1 UUID := gen_random_uuid();
  s2 UUID := gen_random_uuid();
  fresh UUID := gen_random_uuid();
  f_adm UUID;
  token TEXT;
  token2 TEXT;
  other TEXT;
  r TEXT;
  v_expires TIMESTAMPTZ;
BEGIN
  -- 1. Who can have a device remembered ------------------------------------------------------------------------------------------------------------------------------
  r := pg_temp.remember(adm);
  PERFORM pg_temp.ok('without an authenticator app there is nothing to remember', r = 'ERR: Set up two-step sign-in first.', r);
  f_adm := pg_temp.factor(adm);
  PERFORM pg_temp.factor(usr);
  r := pg_temp.as_session(adm, s1, 'aal1', NULL, 'SELECT public.remember_this_device(''x'')');
  PERFORM pg_temp.ok('a password-only session cannot remember a device', r LIKE 'ERR: Enter your authenticator code again%', r);
  r := pg_temp.as_session(adm, s1, 'aal1', 0, 'SELECT public.remember_this_device(''x'')');
  PERFORM pg_temp.ok('nor can one that only claims a code without the code level', r LIKE 'ERR: Enter your authenticator code again%', r);
  r := pg_temp.as_session(adm, s1, 'aal2', NULL, 'SELECT public.remember_this_device(''x'')');
  PERFORM pg_temp.ok('the code level without a record of when the code was entered is refused', r LIKE 'ERR: Enter your authenticator code again%', r);
  r := pg_temp.as_session(adm, s1, 'aal2', 11, 'SELECT public.remember_this_device(''x'')');
  PERFORM pg_temp.ok('a code entered more than 10 minutes ago cannot start a new 7 days', r LIKE 'ERR: Enter your authenticator code again%', r);
  token := pg_temp.as_session(adm, s1, 'aal2', 5, 'SELECT public.remember_this_device(''Office computer'')');
  PERFORM pg_temp.ok('just after the code, a device can be remembered', token ~ '^[0-9a-f]{64}$', token);
  PERFORM pg_temp.ok('only a fingerprint of the key is stored', NOT EXISTS (SELECT 1 FROM public.remembered_devices WHERE token_hash = token) AND EXISTS (SELECT 1 FROM public.remembered_devices WHERE token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')));
  PERFORM pg_temp.ok('the 7 days run from when the code was entered, not from later', (SELECT abs(extract(epoch FROM (expires_at - (now() - interval '5 minutes' + interval '7 days')))) < 2 FROM public.remembered_devices WHERE user_id = adm));

  -- 2. A remembered device -------------------------------------------------------------------------------------------------------------------------------------------
  UPDATE public.platform_security_settings SET admin_mfa_required = TRUE WHERE id;
  PERFORM pg_temp.ok('a new device (a password and no key) has not passed two-step', pg_temp.session_ok(adm, fresh) = 'false');
  PERFORM pg_temp.ok('and gets no admin powers from the database while two-step is required', pg_temp.is_admin(adm, fresh) = 'false');
  PERFORM pg_temp.ok('on the remembered device, the key is accepted after the password', pg_temp.offer(adm, token, s2) = 'true');
  PERFORM pg_temp.ok('that session has now passed two-step', pg_temp.session_ok(adm, s2) = 'true');
  PERFORM pg_temp.ok('and has its admin powers', pg_temp.is_admin(adm, s2) = 'true');
  PERFORM pg_temp.ok('without helping any other session', pg_temp.session_ok(adm, fresh) = 'false' AND pg_temp.is_admin(adm, fresh) = 'false');
  PERFORM pg_temp.ok('a session that entered the code still passes', pg_temp.is_admin(adm, fresh, 'aal2') = 'true');
  v_expires := (SELECT expires_at FROM public.remembered_devices WHERE user_id = adm);
  PERFORM pg_temp.offer(adm, token);
  PERFORM pg_temp.ok('using the device never extends the 7 days', (SELECT expires_at = v_expires AND last_used_at IS NOT NULL FROM public.remembered_devices WHERE user_id = adm));
  PERFORM pg_temp.ok('the server is told the same thing', public.mfa_remembered_session_ok(adm, s2) AND NOT public.mfa_remembered_session_ok(adm, fresh) AND NOT public.mfa_remembered_session_ok(usr, s2));
  PERFORM pg_temp.ok('a wrong key, an empty one and none at all are refused', pg_temp.offer(adm, repeat('0', 64)) = 'false' AND pg_temp.offer(adm, '') = 'false'
    AND pg_temp.as_session(adm, fresh, 'aal1', NULL, 'SELECT public.use_remembered_device(NULL)::text') = 'false');
  PERFORM pg_temp.ok('one person''s key does nothing for another person', pg_temp.offer(usr, token, fresh) = 'false' AND pg_temp.session_ok(usr, fresh) = 'false');
  other := pg_temp.remember(usr);
  PERFORM pg_temp.offer(usr, other, s2);
  PERFORM pg_temp.ok('and cannot take over a session already recorded for someone else', pg_temp.session_ok(adm, s2) = 'true' AND pg_temp.session_ok(usr, s2) = 'false');

  -- 3. After 7 days --------------------------------------------------------------------------------------------------------------------------------------------------
  UPDATE public.remembered_devices SET verified_at = now() - interval '7 days 1 minute', expires_at = now() - interval '1 minute' WHERE user_id = adm;
  PERFORM pg_temp.ok('after 7 days the key is refused, so the code is asked for', pg_temp.offer(adm, token) = 'false');
  PERFORM pg_temp.ok('and a session opened with it stops counting', pg_temp.session_ok(adm, s2) = 'false' AND pg_temp.is_admin(adm, s2) = 'false' AND NOT public.mfa_remembered_session_ok(adm, s2));
  BEGIN
    UPDATE public.remembered_devices SET expires_at = verified_at + interval '8 days' WHERE user_id = adm;
    PERFORM pg_temp.ok('no device can be given more than 7 days', FALSE);
  EXCEPTION WHEN check_violation THEN
    PERFORM pg_temp.ok('no device can be given more than 7 days', TRUE);
  END;

  -- 4. Everything else that ends it ------------------------------------------------------------------------------------------------------------------------------------
  token := pg_temp.remember(adm);
  PERFORM pg_temp.offer(adm, token, s2);
  UPDATE auth.users SET encrypted_password = 'a-different-password-hash' WHERE id = adm;
  PERFORM pg_temp.ok('changing the password ends it, for the key and for open sessions', pg_temp.offer(adm, token) = 'false' AND pg_temp.session_ok(adm, s2) = 'false');
  token := pg_temp.remember(adm);
  PERFORM pg_temp.offer(adm, token, s2);
  PERFORM pg_temp.factor(adm);
  PERFORM pg_temp.ok('adding an authenticator app ends it', pg_temp.offer(adm, token) = 'false' AND pg_temp.session_ok(adm, s2) = 'false');
  token := pg_temp.remember(adm);
  DELETE FROM auth.mfa_factors WHERE user_id = adm;
  PERFORM pg_temp.ok('removing the authenticator app (a lost phone) ends it', pg_temp.offer(adm, token) = 'false' AND (SELECT public._mfa_credential_stamp(adm)) IS NULL);

  f_adm := pg_temp.factor(adm);
  token := pg_temp.remember(adm, 'Laptop');
  token2 := pg_temp.remember(adm, 'Phone');
  PERFORM pg_temp.offer(adm, token, s1);
  PERFORM pg_temp.offer(adm, token2, s2);
  PERFORM pg_temp.ok('two devices can be remembered', pg_temp.as_session(adm, s2, 'aal1', NULL, 'SELECT public.my_remembered_device_count()::text') = '2');
  r := pg_temp.as_session(adm, s2, 'aal1', NULL, format('SELECT public.forget_my_devices(%L)::text', token2));
  PERFORM pg_temp.ok('"other devices" forgets the rest and keeps this one', r ~ '^[1-9]' AND pg_temp.session_ok(adm, s1) = 'false' AND pg_temp.offer(adm, token) = 'false' AND pg_temp.session_ok(adm, s2) = 'true'
    AND (SELECT count(*) = 1 FROM public.remembered_devices WHERE user_id = adm AND revoked_at IS NULL), r);
  r := pg_temp.as_session(adm, s2, 'aal1', NULL, 'SELECT public.forget_my_devices()::text');
  PERFORM pg_temp.ok('"everywhere" forgets them all', r = '1' AND pg_temp.session_ok(adm, s2) = 'false' AND pg_temp.offer(adm, token2) = 'false', r);
  PERFORM pg_temp.ok('and it touches nobody else''s devices', pg_temp.offer(usr, other) = 'true');

  FOR i IN 1..12 LOOP PERFORM pg_temp.remember(adm, 'Device ' || i); END LOOP;
  PERFORM pg_temp.ok('no more than ten devices are remembered for one person', (SELECT count(*) = 10 FROM public.remembered_devices WHERE user_id = adm AND revoked_at IS NULL));

  -- 5. The rest of the admin rule is unchanged --------------------------------------------------------------------------------------------------------------------------
  UPDATE public.platform_security_settings SET admin_mfa_required = FALSE WHERE id;
  PERFORM pg_temp.ok('with the admin requirement off, an admin has admin powers as before', pg_temp.is_admin(adm, fresh) = 'true');
  UPDATE public.platform_security_settings SET admin_mfa_required = TRUE WHERE id;
  PERFORM pg_temp.ok('a remembered device never makes anyone an admin', pg_temp.as_session(usr, s2, 'aal2', 0, format('SELECT public.has_role(%L, ''admin'')::text', usr)) = 'false');
  PERFORM pg_temp.ok('the server''s own check is unchanged', public.admin_mfa_ok('aal2') AND NOT public.admin_mfa_ok('aal1'));
  r := pg_temp.as_session(adm, fresh, 'aal1', NULL, 'SELECT public.set_admin_mfa_required(FALSE)::text');
  PERFORM pg_temp.ok('a password-only session on a new device cannot switch the requirement off', r LIKE 'ERR: Only platform admins%', r);

  -- 6. Nobody reaches the records directly -----------------------------------------------------------------------------------------------------------------------------
  PERFORM pg_temp.ok('signed-in people and visitors cannot read or write the records', NOT has_table_privilege('authenticated', 'public.remembered_devices', 'SELECT, INSERT, UPDATE, DELETE')
    AND NOT has_table_privilege('authenticated', 'public.remembered_sessions', 'SELECT, INSERT, UPDATE, DELETE') AND NOT has_table_privilege('anon', 'public.remembered_devices', 'SELECT')
    AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.remembered_devices'::regclass, 'public.remembered_sessions'::regclass)));
  PERFORM pg_temp.ok('the helper functions are not callable by people', NOT has_function_privilege('authenticated', 'public.mfa_remembered_session_ok(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public._mfa_credential_stamp(uuid)', 'EXECUTE'));
  PERFORM pg_temp.ok('visitors cannot call any of it', NOT EXISTS (SELECT 1 FROM unnest(ARRAY['public.remember_this_device(text)', 'public.use_remembered_device(text)', 'public.forget_my_devices(text)',
    'public.my_remembered_device_count()', 'public.mfa_session_ok()', 'public.mfa_remembered_session_ok(uuid,uuid)']) f WHERE has_function_privilege('anon', f, 'EXECUTE')));
END $$;
ROLLBACK;
