-- Create the business record during auth signup so email-confirmation flows
-- still land in a usable workspace without relying on an immediate client insert.

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

  signup_role := COALESCE((NEW.raw_user_meta_data->>'role')::public.app_role, 'pharmacy');

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

INSERT INTO public.businesses (
  owner_id,
  type,
  name,
  license_number,
  city,
  region,
  phone
)
SELECT
  u.id,
  (u.raw_user_meta_data->>'role')::public.business_type,
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'business_name', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'license_number', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'city', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'region', '')), ''),
  NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'phone', '')), '')
FROM auth.users u
WHERE COALESCE(u.raw_user_meta_data->>'role', '') IN ('pharmacy', 'wholesaler')
  AND NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'business_name', '')), '') IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.businesses b
    WHERE b.owner_id = u.id
  );
