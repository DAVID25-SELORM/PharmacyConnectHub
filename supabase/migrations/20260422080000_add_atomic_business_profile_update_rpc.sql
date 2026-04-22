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
  ON CONFLICT (business_id) DO UPDATE
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
