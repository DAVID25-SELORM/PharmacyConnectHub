-- Two-step sign-in: ask for the code on a new device, and again after 7 days.
--
-- Until now the code was asked for at every sign-in, including after each automatic sign-out. Now, after entering the code, a person can have that device remembered. For the next
-- 7 days a sign-in on it needs only the password. The database checks this itself; it is not just a screen being skipped:
--
--   * A device can only be remembered by a session that passed the code step within the last 10 minutes. The 7 days are counted from the moment the code was entered and are never
--     extended by using the device.
--   * The device keeps a long random key. Only its fingerprint (SHA-256) is stored here, so what is in the database cannot be used to sign in.
--   * The key counts only for the person it was made for, and only together with their password: on its own it opens nothing.
--   * Every remembered device stops counting when the password or the authenticator app changes, when the person chooses to forget devices, or after 7 days.
--   * A new device, a new browser, a private window or cleared browser data has no key, so the code is asked for.
--
-- Changing the password or the two-step settings still needs a real code (the sign-in service insists), and so does resetting a forgotten password.
--
-- Safe to run again. Needs 20261215100000_admin_two_step_enforcement.sql. Run docs/security-remember-device/verify.sql afterwards.
-- To make everyone enter a code again at once:  UPDATE public.remembered_devices SET revoked_at = now() WHERE revoked_at IS NULL;
BEGIN;

CREATE TABLE IF NOT EXISTS public.remembered_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE CHECK (char_length(token_hash) = 64),
  -- Changes when the password or the authenticator apps change, which ends the remembering.
  credential_stamp TEXT NOT NULL CHECK (char_length(credential_stamp) = 64),
  label TEXT NOT NULL DEFAULT '' CHECK (char_length(label) <= 200),
  verified_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  CHECK (expires_at <= verified_at + interval '7 days')
);
CREATE INDEX IF NOT EXISTS remembered_devices_user_idx ON public.remembered_devices (user_id);

-- Which sign-in sessions were opened on a remembered device.
CREATE TABLE IF NOT EXISTS public.remembered_sessions (
  session_id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES public.remembered_devices(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS remembered_sessions_device_idx ON public.remembered_sessions (device_id);

-- No policies and no grants: only the functions below read or write these.
ALTER TABLE public.remembered_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.remembered_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.remembered_devices, public.remembered_sessions FROM PUBLIC, anon, authenticated;

-- A fingerprint of what protects the account. NULL when the person has no authenticator app, in which case nothing can be remembered.
CREATE OR REPLACE FUNCTION public._mfa_credential_stamp(p_user_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT encode(sha256(convert_to(COALESCE(u.encrypted_password, '') || '|' || f.ids, 'UTF8')), 'hex')
  FROM auth.users u
  JOIN LATERAL (SELECT string_agg(m.id::TEXT, ',' ORDER BY m.id) AS ids FROM auth.mfa_factors m WHERE m.user_id = u.id AND m.status = 'verified') f ON f.ids IS NOT NULL
  WHERE u.id = p_user_id
$$;
REVOKE ALL ON FUNCTION public._mfa_credential_stamp(UUID) FROM PUBLIC, anon, authenticated;

-- Was this session opened on a device that is still remembered? For the server, which has already verified the person's token.
CREATE OR REPLACE FUNCTION public.mfa_remembered_session_ok(p_user_id UUID, p_session_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.remembered_sessions s JOIN public.remembered_devices d ON d.id = s.device_id AND d.user_id = s.user_id
    WHERE s.session_id = p_session_id AND s.user_id = p_user_id AND d.revoked_at IS NULL AND d.expires_at > now()
      AND d.credential_stamp = public._mfa_credential_stamp(p_user_id)
  )
$$;
REVOKE ALL ON FUNCTION public.mfa_remembered_session_ok(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mfa_remembered_session_ok(UUID, UUID) TO service_role;

-- Has the CURRENT session satisfied two-step: the code itself, or a remembered device?
CREATE OR REPLACE FUNCTION public.mfa_session_ok()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      OR COALESCE(public.mfa_remembered_session_ok(auth.uid(), NULLIF(auth.jwt() ->> 'session_id', '')::UUID), FALSE)
$$;
REVOKE ALL ON FUNCTION public.mfa_session_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mfa_session_ok() TO authenticated, service_role;

-- Called right after a code was accepted. Returns the key the device keeps; it cannot be read again.
CREATE OR REPLACE FUNCTION public.remember_this_device(p_label TEXT DEFAULT '')
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_code_at TIMESTAMPTZ;
  v_stamp TEXT;
  v_token TEXT;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  -- When the authenticator code was last accepted in this session, as recorded in the signed token.
  SELECT to_timestamp(max((a ->> 'timestamp')::NUMERIC)) INTO v_code_at
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(auth.jwt() -> 'amr') = 'array' THEN auth.jwt() -> 'amr' ELSE '[]'::JSONB END) a
  WHERE a ->> 'method' = 'totp';
  IF COALESCE(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' OR v_code_at IS NULL OR v_code_at < now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'Enter your authenticator code again to remember this device.';
  END IF;
  v_stamp := public._mfa_credential_stamp(v_user);
  IF v_stamp IS NULL THEN RAISE EXCEPTION 'Set up two-step sign-in first.'; END IF;

  -- gen_random_uuid() draws from the database's cryptographically strong generator; two of them give a key that cannot be guessed.
  v_token := replace(gen_random_uuid()::TEXT || gen_random_uuid()::TEXT, '-', '');
  INSERT INTO public.remembered_devices(user_id, token_hash, credential_stamp, label, verified_at, expires_at)
  VALUES (v_user, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), v_stamp, left(COALESCE(p_label, ''), 200), LEAST(v_code_at, now()), LEAST(v_code_at, now()) + interval '7 days');

  -- Keep the ten newest, and drop what can no longer count.
  DELETE FROM public.remembered_devices d WHERE d.user_id = v_user AND (d.expires_at < now() - interval '1 day' OR d.revoked_at < now() - interval '1 day');
  UPDATE public.remembered_devices SET revoked_at = now()
  WHERE id IN (SELECT d.id FROM public.remembered_devices d WHERE d.user_id = v_user AND d.revoked_at IS NULL ORDER BY d.created_at DESC, d.verified_at DESC OFFSET 10);
  RETURN v_token;
END;
$$;
REVOKE ALL ON FUNCTION public.remember_this_device(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remember_this_device(TEXT) TO authenticated;

-- Called after the password, with the key the device kept. TRUE: this session does not need the code.
CREATE OR REPLACE FUNCTION public.use_remembered_device(p_token TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_session UUID := NULLIF(auth.jwt() ->> 'session_id', '')::UUID;
  v_device UUID;
BEGIN
  IF v_user IS NULL OR v_session IS NULL OR p_token IS NULL OR char_length(p_token) <> 64 THEN RETURN FALSE; END IF;
  SELECT d.id INTO v_device FROM public.remembered_devices d
  WHERE d.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') AND d.user_id = v_user AND d.revoked_at IS NULL AND d.expires_at > now()
    AND d.credential_stamp = public._mfa_credential_stamp(v_user);
  IF v_device IS NULL THEN RETURN FALSE; END IF;
  UPDATE public.remembered_devices SET last_used_at = now() WHERE id = v_device;
  INSERT INTO public.remembered_sessions(session_id, user_id, device_id) VALUES (v_session, v_user, v_device)
  ON CONFLICT (session_id) DO UPDATE SET device_id = EXCLUDED.device_id WHERE public.remembered_sessions.user_id = EXCLUDED.user_id;
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.use_remembered_device(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.use_remembered_device(TEXT) TO authenticated;

-- Forget this person's devices (all of them, or all but the one holding p_keep_token). Sessions opened with a forgotten device stop counting at once.
CREATE OR REPLACE FUNCTION public.forget_my_devices(p_keep_token TEXT DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_n INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  UPDATE public.remembered_devices SET revoked_at = now()
  WHERE user_id = auth.uid() AND revoked_at IS NULL
    AND (p_keep_token IS NULL OR token_hash <> encode(sha256(convert_to(p_keep_token, 'UTF8')), 'hex'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.forget_my_devices(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.forget_my_devices(TEXT) TO authenticated;

-- How many of this person's devices are remembered right now.
CREATE OR REPLACE FUNCTION public.my_remembered_device_count()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::INTEGER FROM public.remembered_devices d
  WHERE d.user_id = auth.uid() AND d.revoked_at IS NULL AND d.expires_at > now() AND d.credential_stamp = public._mfa_credential_stamp(auth.uid())
$$;
REVOKE ALL ON FUNCTION public.my_remembered_device_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_remembered_device_count() TO authenticated;

-- The admin rule: unchanged, except that a session on a remembered device has satisfied two-step.
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role public.app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role)
    AND NOT (
      _role = 'admin'
      AND auth.uid() IS NOT NULL
      AND _user_id = auth.uid()
      AND public.admin_mfa_required()
      AND NOT public.mfa_session_ok()
    )
$$;

COMMIT;
