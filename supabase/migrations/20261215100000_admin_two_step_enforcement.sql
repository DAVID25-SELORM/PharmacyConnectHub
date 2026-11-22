-- Two-step verification for platform admins, enforced in the database.
--
-- The app already asks anyone with an authenticator app for a code after their password.
-- That is a screen, though: someone holding a stolen admin password could skip the screen
-- and call the data API directly. This migration lets the database itself refuse admin
-- powers to a session that has not passed the code step (assurance level "aal2").
--
-- It ships SWITCHED OFF, so applying it changes nothing. A platform admin turns it on from
-- the Account security page once every admin has set up an authenticator app. The switch
-- refuses to turn on while any admin is still without one, so nobody can be locked out.
--
-- Run docs/security-to-apply/verify-admin-two-step.sql afterwards.

-- 1. The switch --------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.platform_security_settings (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  admin_mfa_required BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID
);

INSERT INTO public.platform_security_settings (id) VALUES (TRUE) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.platform_security_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_security_settings FROM PUBLIC, anon, authenticated;
-- No policies: nobody reads or writes the row directly. The functions below are the only way in.

CREATE OR REPLACE FUNCTION public.admin_mfa_required()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT admin_mfa_required FROM public.platform_security_settings WHERE id), FALSE)
$$;

REVOKE ALL ON FUNCTION public.admin_mfa_required() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_mfa_required() TO authenticated, service_role;

-- 2. has_role: an admin session must be aal2 once the switch is on ------------------------
-- Same signature and behaviour as before for every role except 'admin' on the caller's own
-- session. Server-side jobs (no auth.uid()) and other people's ids are unaffected.
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
      AND COALESCE(auth.jwt() ->> 'aal', 'aal1') <> 'aal2'
    )
$$;

-- 3. For server code that acts for an admin with the service role ---------------------------
-- The Vercel API handlers authenticate the caller's token themselves and then use the
-- service role, so the database cannot see the session. They pass the token's level here.
CREATE OR REPLACE FUNCTION public.admin_mfa_ok(p_aal TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT public.admin_mfa_required() OR COALESCE(p_aal, 'aal1') = 'aal2'
$$;

REVOKE ALL ON FUNCTION public.admin_mfa_ok(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mfa_ok(TEXT) TO service_role;

-- 4. Admin screen: who has an authenticator app, and the switch itself ----------------------
CREATE OR REPLACE FUNCTION public.get_admin_mfa_status()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can see this.';
  END IF;

  RETURN jsonb_build_object(
    'required', public.admin_mfa_required(),
    'admins', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', ur.user_id,
          'email', u.email,
          'enrolled', EXISTS (
            SELECT 1 FROM auth.mfa_factors f
            WHERE f.user_id = ur.user_id AND f.status = 'verified'
          )
        ) ORDER BY u.email
      )
      FROM public.user_roles ur
      JOIN auth.users u ON u.id = ur.user_id
      WHERE ur.role = 'admin'
    ), '[]'::JSONB)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_mfa_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admin_mfa_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.set_admin_mfa_required(p_required BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_missing TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can change this.';
  END IF;

  IF p_required IS NULL THEN
    RAISE EXCEPTION 'Choose on or off.';
  END IF;

  IF p_required THEN
    -- The person turning it on must have passed the code step themselves.
    IF COALESCE(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' THEN
      RAISE EXCEPTION 'Verify with your authenticator app first, then turn this on.';
    END IF;

    SELECT string_agg(u.email, ', ' ORDER BY u.email) INTO v_missing
    FROM public.user_roles ur
    JOIN auth.users u ON u.id = ur.user_id
    WHERE ur.role = 'admin'
      AND NOT EXISTS (
        SELECT 1 FROM auth.mfa_factors f
        WHERE f.user_id = ur.user_id AND f.status = 'verified'
      );

    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'These admins have not set up an authenticator app yet: %', v_missing;
    END IF;
  END IF;

  UPDATE public.platform_security_settings
  SET admin_mfa_required = p_required, updated_at = now(), updated_by = auth.uid()
  WHERE id;

  PERFORM public.write_audit_log(
    CASE WHEN p_required THEN 'Admin two-step verification required' ELSE 'Admin two-step verification no longer required' END,
    'Platform',
    'platform_setting',
    NULL::UUID,
    'admin_mfa_required',
    jsonb_build_object('required', p_required)
  );

  RETURN jsonb_build_object('required', p_required);
END;
$$;

REVOKE ALL ON FUNCTION public.set_admin_mfa_required(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_admin_mfa_required(BOOLEAN) TO authenticated;

-- 5. Payments: the admin check used by the refund, payout and re-verify handlers ------------
-- Those handlers act with the service role, so they now pass the caller's assurance level.
-- Anything that still calls it with one argument keeps working (the default is "passed").
DROP FUNCTION IF EXISTS public.payment_user_is_admin(UUID);

CREATE OR REPLACE FUNCTION public.payment_user_is_admin(p_user_id UUID, p_aal TEXT DEFAULT 'aal2')
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user_id IS NOT NULL
    AND public.has_role(p_user_id, 'admin')
    AND public.admin_mfa_ok(p_aal)
$$;

REVOKE ALL ON FUNCTION public.payment_user_is_admin(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_user_is_admin(UUID, TEXT) TO service_role;
