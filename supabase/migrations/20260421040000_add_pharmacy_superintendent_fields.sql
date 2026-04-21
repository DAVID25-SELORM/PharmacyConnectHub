-- Track whether a pharmacy owner is also the superintendent pharmacist.
-- This keeps signup, admin review, and later edits aligned without duplicating owner names.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS owner_is_superintendent BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS superintendent_name TEXT;

UPDATE public.businesses
SET
  owner_is_superintendent = COALESCE(owner_is_superintendent, true),
  superintendent_name = CASE
    WHEN type <> 'pharmacy' OR COALESCE(owner_is_superintendent, true) THEN NULL
    ELSE NULLIF(BTRIM(superintendent_name), '')
  END
WHERE type IN ('pharmacy', 'wholesaler');

CREATE OR REPLACE FUNCTION public.normalize_business_superintendent_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type <> 'pharmacy' THEN
    NEW.owner_is_superintendent := true;
    NEW.superintendent_name := NULL;
    RETURN NEW;
  END IF;

  NEW.owner_is_superintendent := COALESCE(NEW.owner_is_superintendent, true);
  NEW.superintendent_name := NULLIF(BTRIM(COALESCE(NEW.superintendent_name, '')), '');

  IF NEW.owner_is_superintendent THEN
    NEW.superintendent_name := NULL;
  ELSIF NEW.superintendent_name IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist name is required when the owner is not the superintendent.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_business_superintendent_fields ON public.businesses;
CREATE TRIGGER trg_normalize_business_superintendent_fields
  BEFORE INSERT OR UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_business_superintendent_fields();

ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_pharmacy_superintendent_chk;

ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_pharmacy_superintendent_chk
  CHECK (
    type <> 'pharmacy'
    OR owner_is_superintendent
    OR NULLIF(BTRIM(COALESCE(superintendent_name, '')), '') IS NOT NULL
  );

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  signup_role public.app_role;
  signup_business_name TEXT;
  signup_owner_is_superintendent BOOLEAN;
  signup_superintendent_name TEXT;
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
  signup_owner_is_superintendent := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      THEN COALESCE((NEW.raw_user_meta_data->>'owner_is_superintendent')::BOOLEAN, true)
    ELSE true
  END;
  signup_superintendent_name := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_name', '')),
    ''
  );

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
      phone,
      owner_is_superintendent,
      superintendent_name
    )
    VALUES (
      NEW.id,
      signup_role::TEXT::public.business_type,
      signup_business_name,
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'license_number', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'city', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'region', '')), ''),
      NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), ''),
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    );
  END IF;

  RETURN NEW;
END;
$$;
