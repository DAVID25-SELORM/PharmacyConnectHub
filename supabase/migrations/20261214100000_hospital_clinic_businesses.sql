-- Hospitals and clinics.
--
-- A hospital or clinic buys medicines, sends RFQs and orders from wholesalers exactly like a
-- pharmacy, so it keeps businesses.type = 'pharmacy' and every existing check keeps working.
-- A new facility_kind column marks it: NULL for an ordinary pharmacy or wholesaler,
-- 'hospital_clinic' for a hospital or clinic. Only a business of type 'pharmacy' can carry it.

ALTER TABLE public.businesses ADD COLUMN IF NOT EXISTS facility_kind TEXT;

ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS businesses_facility_kind_check;
ALTER TABLE public.businesses ADD CONSTRAINT businesses_facility_kind_check
  CHECK (facility_kind IS NULL OR (facility_kind = 'hospital_clinic' AND type = 'pharmacy'));

-- Keeps facility_kind consistent and stops anyone but an admin from changing it.
-- A switch to wholesaler (admin_change_business_type) clears it automatically.
CREATE OR REPLACE FUNCTION public.guard_business_facility_kind()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type <> 'pharmacy' THEN
    NEW.facility_kind := NULL;
  END IF;

  IF TG_OP = 'UPDATE'
    AND NEW.facility_kind IS DISTINCT FROM OLD.facility_kind
    AND auth.uid() IS NOT NULL
    AND NOT public.has_role(auth.uid(), 'admin')
    AND NOT (NEW.type <> 'pharmacy' AND OLD.type = 'pharmacy' AND NEW.facility_kind IS NULL) THEN
    RAISE EXCEPTION 'Only admins can change whether a business is a hospital or clinic.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_business_facility_kind ON public.businesses;
CREATE TRIGGER trg_guard_business_facility_kind
  BEFORE INSERT OR UPDATE ON public.businesses
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_business_facility_kind();

-- Admin: mark a pharmacy-type business as a hospital/clinic, or clear it. A label only, so it is
-- allowed on a business that already has data.
CREATE OR REPLACE FUNCTION public.admin_set_facility_kind(p_business_id UUID, p_kind TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_biz public.businesses%ROWTYPE;
  v_kind TEXT := NULLIF(btrim(COALESCE(p_kind, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can change this.';
  END IF;

  IF v_kind IS NOT NULL AND v_kind <> 'hospital_clinic' THEN
    RAISE EXCEPTION 'Unknown facility kind.';
  END IF;

  SELECT * INTO v_biz FROM public.businesses WHERE id = p_business_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.';
  END IF;

  IF v_kind IS NOT NULL AND v_biz.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Only a pharmacy-type business can be a hospital or clinic. Change its type first.';
  END IF;

  IF v_biz.facility_kind IS NOT DISTINCT FROM v_kind THEN
    RETURN jsonb_build_object('business_id', v_biz.id, 'facility_kind', v_kind);
  END IF;

  UPDATE public.businesses SET facility_kind = v_kind WHERE id = p_business_id;

  PERFORM public.write_audit_log(
    'Facility kind changed',
    v_biz.name,
    'business',
    v_biz.id,
    COALESCE(v_biz.license_number, v_biz.id::TEXT),
    jsonb_build_object('from_kind', v_biz.facility_kind, 'to_kind', v_kind)
  );

  RETURN jsonb_build_object('business_id', v_biz.id, 'facility_kind', v_kind);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_facility_kind(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_facility_kind(UUID, TEXT) TO authenticated;

-- Signup: a new account can register as a hospital/clinic (role stays 'pharmacy').
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
  signup_facility_kind TEXT;
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
  signup_facility_kind := CASE
    WHEN signup_role = 'pharmacy'::public.app_role
      AND BTRIM(COALESCE(NEW.raw_user_meta_data->>'facility_kind', '')) = 'hospital_clinic'
      THEN 'hospital_clinic'
    ELSE NULL
  END;
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
      superintendent_name,
      facility_kind
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
      END,
      signup_facility_kind
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

-- Adding another business under the same login: new optional _facility_kind argument.
DROP FUNCTION IF EXISTS public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.create_additional_business(
  _type TEXT,
  _name TEXT,
  _license_number TEXT,
  _city TEXT,
  _region TEXT,
  _phone TEXT,
  _public_email TEXT,
  _address TEXT DEFAULT NULL,
  _working_hours TEXT DEFAULT NULL,
  _location_description TEXT DEFAULT NULL,
  _owner_is_superintendent BOOLEAN DEFAULT TRUE,
  _superintendent_name TEXT DEFAULT NULL,
  _superintendent_phone TEXT DEFAULT NULL,
  _superintendent_email TEXT DEFAULT NULL,
  _facility_kind TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_type public.business_type;
  v_is_pharmacy BOOLEAN;
  v_owner_is_superintendent BOOLEAN;
  v_business_id UUID;
  v_owner_name TEXT;
  v_owner_phone TEXT;
  v_facility_kind TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to add a business.';
  END IF;

  IF _type IS NULL OR _type NOT IN ('pharmacy', 'wholesaler') THEN
    RAISE EXCEPTION 'Choose Pharmacy or Wholesaler.';
  END IF;
  v_type := _type::public.business_type;
  v_is_pharmacy := (_type = 'pharmacy');

  IF length(btrim(COALESCE(_name, ''))) < 2 THEN RAISE EXCEPTION 'Business name is required.'; END IF;
  IF length(btrim(COALESCE(_license_number, ''))) < 3 THEN RAISE EXCEPTION 'License number is required.'; END IF;
  IF length(btrim(COALESCE(_city, ''))) < 2 THEN RAISE EXCEPTION 'City is required.'; END IF;
  IF length(btrim(COALESCE(_region, ''))) < 2 THEN RAISE EXCEPTION 'Region is required.'; END IF;
  IF length(btrim(COALESCE(_phone, ''))) < 7 THEN RAISE EXCEPTION 'Business phone is required.'; END IF;
  IF COALESCE(_public_email, '') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Enter a valid public business email.';
  END IF;

  -- Guard against runaway creation from a single login.
  IF (SELECT COUNT(*) FROM public.businesses b WHERE b.owner_id = v_uid) >= 10 THEN
    RAISE EXCEPTION 'This account already owns the maximum number of businesses.';
  END IF;

  -- Older accounts may have complete business contacts but an incomplete login profile.
  -- Reuse only contacts of a business owned by this caller; auth email still comes from auth.users.
  SELECT NULLIF(btrim(p.full_name), ''), NULLIF(btrim(p.phone), '')
  INTO v_owner_name, v_owner_phone FROM public.profiles p WHERE p.id = v_uid;
  SELECT COALESCE(v_owner_name, c.owner_full_name), COALESCE(v_owner_phone, c.owner_phone)
  INTO v_owner_name, v_owner_phone
  FROM (SELECT 1) seed
  LEFT JOIN LATERAL (
    SELECT pc.owner_full_name, pc.owner_phone
    FROM public.business_private_contacts pc JOIN public.businesses b ON b.id = pc.business_id
    WHERE b.owner_id = v_uid
    ORDER BY pc.updated_at DESC, pc.business_id LIMIT 1
  ) c ON true;
  IF NULLIF(btrim(v_owner_name), '') IS NULL OR NULLIF(btrim(v_owner_phone), '') IS NULL THEN
    RAISE EXCEPTION 'Your owner name and phone are incomplete. Ask an administrator to update your existing business owner details before adding another business.';
  END IF;

  v_facility_kind := CASE WHEN v_is_pharmacy AND btrim(COALESCE(_facility_kind, '')) = 'hospital_clinic' THEN 'hospital_clinic' END;
  v_owner_is_superintendent := CASE WHEN v_is_pharmacy THEN COALESCE(_owner_is_superintendent, TRUE) ELSE TRUE END;

  INSERT INTO public.businesses (
    owner_id, type, name, license_number, city, region, phone, address, public_email,
    working_hours, location_description, owner_is_superintendent, superintendent_name, facility_kind
  )
  VALUES (
    v_uid,
    v_type,
    btrim(_name),
    btrim(_license_number),
    btrim(_city),
    btrim(_region),
    btrim(_phone),
    NULLIF(btrim(COALESCE(_address, '')), ''),
    lower(btrim(_public_email)),
    NULLIF(btrim(COALESCE(_working_hours, '')), ''),
    NULLIF(btrim(COALESCE(_location_description, '')), ''),
    v_owner_is_superintendent,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_name, '')), '') END,
    v_facility_kind
  )
  RETURNING id INTO v_business_id;

  -- Owner details were resolved from the caller's profile/owned contacts above.
  -- Superintendent details are only used for a pharmacy whose owner is not the
  -- superintendent, and that trigger validates them.
  INSERT INTO public.business_private_contacts (
    business_id, owner_full_name, owner_phone, superintendent_full_name, superintendent_phone, superintendent_email
  )
  VALUES (
    v_business_id, v_owner_name, v_owner_phone,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_name, '')), '') END,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_phone, '')), '') END,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_email, '')), '') END
  );

  RETURN v_business_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT, TEXT) TO authenticated;
