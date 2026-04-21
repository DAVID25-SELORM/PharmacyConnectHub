-- Guard handle_new_user() so staff invites skip role + business creation.
-- When admin.inviteUserByEmail sets is_staff_invite = true in metadata,
-- we only create the profile row and return early.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
BEGIN
  -- Always create / update the profile row
  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), ''),
    NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
  )
  ON CONFLICT (id) DO UPDATE
    SET full_name = COALESCE(EXCLUDED.full_name, public.profiles.full_name),
        phone = COALESCE(EXCLUDED.phone, public.profiles.phone),
        updated_at = now();

  -- Staff invites: skip role assignment and business creation
  IF COALESCE(NEW.raw_user_meta_data->>'is_staff_invite', '') = 'true' THEN
    RETURN NEW;
  END IF;

  signup_role := CASE
    WHEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy') IN ('admin', 'pharmacy', 'wholesaler')
      THEN COALESCE(NULLIF(BTRIM(NEW.raw_user_meta_data->>'role'), ''), 'pharmacy')::public.app_role
    ELSE 'pharmacy'::public.app_role
  END;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (NEW.id, signup_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  IF (SELECT COUNT(*) FROM auth.users) = 1 THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  END IF;

  signup_business_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'business_name', '')), '');

  IF signup_role IN ('pharmacy'::public.app_role, 'wholesaler'::public.app_role)
    AND signup_business_name IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.owner_id = NEW.id
    ) THEN
    INSERT INTO public.businesses (
      owner_id,
      type,
      name,
      license_number,
      city,
      region,
      phone
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '')
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Efficient email-to-user-id lookup for the staff invite API.
-- SECURITY DEFINER so it can read auth.users; only granted to service_role.
CREATE OR REPLACE FUNCTION public.lookup_user_id_by_email(_email TEXT)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM auth.users WHERE lower(email) = lower(trim(_email)) LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.lookup_user_id_by_email(TEXT) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_user_id_by_email(TEXT) TO service_role;

-- Allow users to read their own business_staff rows (needed for pending-invite UX).
DROP POLICY IF EXISTS "Users view own staff memberships" ON public.business_staff;
CREATE POLICY "Users view own staff memberships"
  ON public.business_staff
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());
