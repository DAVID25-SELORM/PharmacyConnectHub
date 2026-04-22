-- Capture richer signup details without exposing internal verification contacts
-- through the marketplace-facing businesses table.

ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS public_email TEXT,
  ADD COLUMN IF NOT EXISTS working_hours TEXT,
  ADD COLUMN IF NOT EXISTS location_description TEXT;

UPDATE public.businesses AS b
SET
  public_email = COALESCE(
    b.public_email,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'public_email', '')), '')
  ),
  address = COALESCE(
    b.address,
    NULLIF(
      BTRIM(
        COALESCE(
          u.raw_user_meta_data->>'gps_address',
          u.raw_user_meta_data->>'address',
          ''
        )
      ),
      ''
    )
  ),
  working_hours = COALESCE(
    b.working_hours,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'working_hours', '')), '')
  ),
  location_description = COALESCE(
    b.location_description,
    NULLIF(BTRIM(COALESCE(u.raw_user_meta_data->>'location_description', '')), '')
  )
FROM auth.users AS u
WHERE u.id = b.owner_id;

CREATE TABLE IF NOT EXISTS public.business_private_contacts (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  owner_full_name TEXT,
  owner_phone TEXT,
  owner_email TEXT,
  superintendent_full_name TEXT,
  superintendent_phone TEXT,
  superintendent_email TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.business_private_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Owners view own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners view own private business contacts"
  ON public.business_private_contacts
  FOR SELECT
  USING (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owners insert own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners insert own private business contacts"
  ON public.business_private_contacts
  FOR INSERT
  WITH CHECK (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Owners update own private business contacts" ON public.business_private_contacts;
CREATE POLICY "Owners update own private business contacts"
  ON public.business_private_contacts
  FOR UPDATE
  USING (
    public.has_role(auth.uid(), 'admin')
    OR EXISTS (
      SELECT 1
      FROM public.businesses b
      WHERE b.id = business_id
        AND b.owner_id = auth.uid()
    )
  );

DROP TRIGGER IF EXISTS trg_business_private_contacts_updated ON public.business_private_contacts;
CREATE TRIGGER trg_business_private_contacts_updated
  BEFORE UPDATE ON public.business_private_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

INSERT INTO public.business_private_contacts (
  business_id,
  owner_full_name,
  owner_phone,
  owner_email,
  superintendent_full_name,
  superintendent_phone,
  superintendent_email
)
SELECT
  b.id,
  p.full_name,
  p.phone,
  u.email,
  CASE
    WHEN b.type <> 'pharmacy' THEN NULL
    WHEN b.owner_is_superintendent THEN p.full_name
    ELSE b.superintendent_name
  END,
  CASE
    WHEN b.type = 'pharmacy' AND b.owner_is_superintendent THEN p.phone
    ELSE NULL
  END,
  CASE
    WHEN b.type = 'pharmacy' AND b.owner_is_superintendent THEN u.email
    ELSE NULL
  END
FROM public.businesses AS b
JOIN auth.users AS u
  ON u.id = b.owner_id
LEFT JOIN public.profiles AS p
  ON p.id = b.owner_id
ON CONFLICT (business_id) DO UPDATE
SET
  owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
  owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
  owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
  superintendent_full_name = COALESCE(
    EXCLUDED.superintendent_full_name,
    public.business_private_contacts.superintendent_full_name
  ),
  superintendent_phone = COALESCE(
    EXCLUDED.superintendent_phone,
    public.business_private_contacts.superintendent_phone
  ),
  superintendent_email = COALESCE(
    EXCLUDED.superintendent_email,
    public.business_private_contacts.superintendent_email
  ),
  updated_at = now();

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
  signup_owner_full_name TEXT;
  signup_owner_phone TEXT;
  signup_public_phone TEXT;
  signup_public_email TEXT;
  signup_gps_address TEXT;
  signup_location_description TEXT;
  signup_working_hours TEXT;
  signup_superintendent_phone TEXT;
  signup_superintendent_email TEXT;
  created_business_id UUID;
BEGIN
  signup_owner_full_name := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'full_name', '')), '');
  signup_owner_phone := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'phone', '')), '');

  INSERT INTO public.profiles (id, full_name, phone)
  VALUES (
    NEW.id,
    signup_owner_full_name,
    signup_owner_phone
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
  signup_public_phone := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'public_phone',
        NEW.raw_user_meta_data->>'phone',
        ''
      )
    ),
    ''
  );
  signup_public_email := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'public_email', '')), '');
  signup_gps_address := NULLIF(
    BTRIM(
      COALESCE(
        NEW.raw_user_meta_data->>'gps_address',
        NEW.raw_user_meta_data->>'address',
        ''
      )
    ),
    ''
  );
  signup_location_description := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'location_description', '')),
    ''
  );
  signup_working_hours := NULLIF(BTRIM(COALESCE(NEW.raw_user_meta_data->>'working_hours', '')), '');
  signup_superintendent_phone := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_phone', '')),
    ''
  );
  signup_superintendent_email := NULLIF(
    BTRIM(COALESCE(NEW.raw_user_meta_data->>'superintendent_email', '')),
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
      address,
      public_email,
      working_hours,
      location_description,
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
      signup_public_phone,
      signup_gps_address,
      signup_public_email,
      signup_working_hours,
      signup_location_description,
      signup_owner_is_superintendent,
      CASE
        WHEN signup_role = 'pharmacy'::public.app_role AND NOT signup_owner_is_superintendent
          THEN signup_superintendent_name
        ELSE NULL
      END
    )
    RETURNING id INTO created_business_id;

    INSERT INTO public.business_private_contacts (
      business_id,
      owner_full_name,
      owner_phone,
      owner_email,
      superintendent_full_name,
      superintendent_phone,
      superintendent_email
    )
    VALUES (
      created_business_id,
      signup_owner_full_name,
      signup_owner_phone,
      NULLIF(BTRIM(COALESCE(NEW.email, '')), ''),
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_full_name
        ELSE signup_superintendent_name
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN signup_owner_phone
        ELSE signup_superintendent_phone
      END,
      CASE
        WHEN signup_role <> 'pharmacy'::public.app_role THEN NULL
        WHEN signup_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(NEW.email, '')), '')
        ELSE signup_superintendent_email
      END
    )
    ON CONFLICT (business_id) DO UPDATE
      SET owner_full_name = COALESCE(EXCLUDED.owner_full_name, public.business_private_contacts.owner_full_name),
          owner_phone = COALESCE(EXCLUDED.owner_phone, public.business_private_contacts.owner_phone),
          owner_email = COALESCE(EXCLUDED.owner_email, public.business_private_contacts.owner_email),
          superintendent_full_name = COALESCE(
            EXCLUDED.superintendent_full_name,
            public.business_private_contacts.superintendent_full_name
          ),
          superintendent_phone = COALESCE(
            EXCLUDED.superintendent_phone,
            public.business_private_contacts.superintendent_phone
          ),
          superintendent_email = COALESCE(
            EXCLUDED.superintendent_email,
            public.business_private_contacts.superintendent_email
          ),
          updated_at = now();
  END IF;

  RETURN NEW;
END;
$$;
