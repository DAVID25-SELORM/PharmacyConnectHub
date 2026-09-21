-- Let a signed-in user register another business (pharmacy or wholesaler) under the same login.
-- The new business is always created as 'pending' and goes through the normal onboarding and
-- admin verification. Verification status can never be supplied by the caller.
--
-- Everything the signup trigger does for a business is repeated here: the businesses row (the
-- existing triggers then add the owner as staff and write the audit entry) and the private
-- contacts row. Owner name, phone and email are taken from the caller's own profile and auth
-- record by the existing normalize_business_private_contacts() trigger, never from parameters.

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
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'You must be signed in to add a business.';
  END IF;

  IF _type NOT IN ('pharmacy', 'wholesaler') THEN
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

  -- Owner details come from the caller's profile/auth record (fallback in the private-contacts
  -- trigger); superintendent details are only used for a pharmacy whose owner is not the
  -- superintendent, and that trigger validates them.
  INSERT INTO public.business_private_contacts (
    business_id, superintendent_full_name, superintendent_phone, superintendent_email
  )
  VALUES (
    v_business_id,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_name, '')), '') END,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_phone, '')), '') END,
    CASE WHEN v_is_pharmacy AND NOT v_owner_is_superintendent THEN NULLIF(btrim(COALESCE(_superintendent_email, '')), '') END
  );

  RETURN v_business_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_additional_business(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO authenticated;
