-- Fix business editing ambiguity and additional-business owner contact fallback.
-- Additive function replacements; no existing business data is rewritten.

-- Update the public business profile and private verification contacts in one
-- transaction so admin edits cannot leave the two records out of sync.

CREATE OR REPLACE FUNCTION public.update_business_profile_with_contacts(
  _business_id UUID,
  _name TEXT,
  _license_number TEXT,
  _owner_is_superintendent BOOLEAN,
  _superintendent_name TEXT,
  _city TEXT,
  _region TEXT,
  _phone TEXT,
  _address TEXT,
  _public_email TEXT,
  _working_hours TEXT,
  _location_description TEXT,
  _owner_full_name TEXT,
  _owner_phone TEXT,
  _owner_email TEXT,
  _superintendent_phone TEXT,
  _superintendent_email TEXT
)
RETURNS TABLE (
  business_id UUID,
  owner_full_name TEXT,
  owner_phone TEXT,
  owner_email TEXT,
  superintendent_full_name TEXT,
  superintendent_phone TEXT,
  superintendent_email TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  related_business public.businesses%ROWTYPE;
  trimmed_business_name TEXT;
  normalized_public_email TEXT;
  effective_owner_is_superintendent BOOLEAN;
  effective_superintendent_name TEXT;
  effective_owner_email TEXT;
  effective_superintendent_email TEXT;
  effective_superintendent_phone TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to update business details.';
  END IF;

  SELECT b.*
  INTO related_business
  FROM public.businesses AS b
  WHERE b.id = _business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business % does not exist.', _business_id;
  END IF;

  IF NOT (
    public.has_role(auth.uid(), 'admin')
    OR related_business.owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to update this business.';
  END IF;

  trimmed_business_name := NULLIF(BTRIM(COALESCE(_name, '')), '');
  IF trimmed_business_name IS NULL THEN
    RAISE EXCEPTION 'Business name is required.';
  END IF;

  normalized_public_email := NULLIF(LOWER(BTRIM(COALESCE(_public_email, ''))), '');
  IF normalized_public_email IS NOT NULL
    AND normalized_public_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Public business email address is invalid.';
  END IF;

  effective_owner_is_superintendent := CASE
    WHEN related_business.type = 'pharmacy' THEN COALESCE(_owner_is_superintendent, true)
    ELSE true
  END;

  effective_superintendent_name := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN NULLIF(BTRIM(COALESCE(_owner_full_name, '')), '')
    ELSE NULLIF(BTRIM(COALESCE(_superintendent_name, '')), '')
  END;

  effective_owner_email := NULLIF(LOWER(BTRIM(COALESCE(_owner_email, ''))), '');
  effective_superintendent_email := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN effective_owner_email
    ELSE NULLIF(LOWER(BTRIM(COALESCE(_superintendent_email, ''))), '')
  END;

  effective_superintendent_phone := CASE
    WHEN related_business.type <> 'pharmacy' THEN NULL
    WHEN effective_owner_is_superintendent THEN _owner_phone
    ELSE _superintendent_phone
  END;

  UPDATE public.businesses
  SET
    name = trimmed_business_name,
    license_number = NULLIF(BTRIM(COALESCE(_license_number, '')), ''),
    owner_is_superintendent = effective_owner_is_superintendent,
    superintendent_name = CASE
      WHEN related_business.type = 'pharmacy' AND NOT effective_owner_is_superintendent
        THEN effective_superintendent_name
      ELSE NULL
    END,
    city = NULLIF(BTRIM(COALESCE(_city, '')), ''),
    region = NULLIF(BTRIM(COALESCE(_region, '')), ''),
    phone = public.normalize_ghana_phone(_phone),
    address = NULLIF(BTRIM(COALESCE(_address, '')), ''),
    public_email = normalized_public_email,
    working_hours = NULLIF(BTRIM(COALESCE(_working_hours, '')), ''),
    location_description = NULLIF(BTRIM(COALESCE(_location_description, '')), '')
  WHERE id = _business_id;

  RETURN QUERY
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
    _business_id,
    NULLIF(BTRIM(COALESCE(_owner_full_name, '')), ''),
    _owner_phone,
    effective_owner_email,
    effective_superintendent_name,
    effective_superintendent_phone,
    effective_superintendent_email
  )
  ON CONFLICT ON CONSTRAINT business_private_contacts_pkey DO UPDATE
  SET
    owner_full_name = EXCLUDED.owner_full_name,
    owner_phone = EXCLUDED.owner_phone,
    owner_email = EXCLUDED.owner_email,
    superintendent_full_name = EXCLUDED.superintendent_full_name,
    superintendent_phone = EXCLUDED.superintendent_phone,
    superintendent_email = EXCLUDED.superintendent_email
  RETURNING
    public.business_private_contacts.business_id,
    public.business_private_contacts.owner_full_name,
    public.business_private_contacts.owner_phone,
    public.business_private_contacts.owner_email,
    public.business_private_contacts.superintendent_full_name,
    public.business_private_contacts.superintendent_phone,
    public.business_private_contacts.superintendent_email;
END;
$$;

REVOKE ALL ON FUNCTION public.update_business_profile_with_contacts(
  UUID,
  TEXT,
  TEXT,
  BOOLEAN,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.update_business_profile_with_contacts(
  UUID,
  TEXT,
  TEXT,
  BOOLEAN,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT,
  TEXT
) TO authenticated;

-- Let a signed-in user register another business (pharmacy or wholesaler) under the same login.
-- The new business is always created as 'pending' and goes through the normal onboarding and
-- admin verification. Verification status can never be supplied by the caller.
--
-- Everything the signup trigger does for a business is repeated here: the businesses row (the
-- existing triggers then add the owner as staff and write the audit entry) and the private
-- contacts row. Owner name and phone come from the caller's profile or existing owned business
-- contacts; login email comes from auth via the private-contacts trigger, never from parameters.

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
  _superintendent_email TEXT DEFAULT NULL
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

  v_owner_is_superintendent := CASE WHEN v_is_pharmacy THEN COALESCE(_owner_is_superintendent, TRUE) ELSE TRUE END;

  INSERT INTO public.businesses (
    owner_id, type, name, license_number, city, region, phone, address, public_email,
    working_hours, location_description, owner_is_superintendent, superintendent_name
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
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_name, '')), '') END
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

REVOKE EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO authenticated;
