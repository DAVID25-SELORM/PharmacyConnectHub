-- Enforce normalization and completeness for private business contacts.
-- Existing incomplete pharmacy rows can still be corrected in the admin UI,
-- but all new and updated records should remain valid.

CREATE OR REPLACE FUNCTION public.normalize_ghana_phone(raw_phone TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  sanitized TEXT;
  national_number TEXT;
BEGIN
  sanitized := regexp_replace(COALESCE(raw_phone, ''), '\s+', '', 'g');
  sanitized := regexp_replace(sanitized, '[^0-9+]', '', 'g');

  IF sanitized = '' THEN
    RETURN NULL;
  END IF;

  IF sanitized LIKE '+233%' THEN
    national_number := regexp_replace(substr(sanitized, 5), '\D', '', 'g');
  ELSIF sanitized LIKE '233%' THEN
    national_number := regexp_replace(substr(sanitized, 4), '\D', '', 'g');
  ELSIF sanitized LIKE '0%' THEN
    national_number := regexp_replace(substr(sanitized, 2), '\D', '', 'g');
  ELSE
    national_number := regexp_replace(sanitized, '\D', '', 'g');
  END IF;

  IF length(national_number) = 10 AND left(national_number, 1) = '0' THEN
    national_number := substr(national_number, 2);
  END IF;

  IF length(national_number) <> 9 THEN
    RAISE EXCEPTION 'Enter a valid Ghana phone number.';
  END IF;

  RETURN '+233' || national_number;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_business_private_contacts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  related_business public.businesses%ROWTYPE;
  fallback_owner_name TEXT;
  fallback_owner_phone_raw TEXT;
  fallback_owner_phone TEXT;
  fallback_owner_email TEXT;
BEGIN
  SELECT b.*
  INTO related_business
  FROM public.businesses AS b
  WHERE b.id = NEW.business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business % does not exist.', NEW.business_id;
  END IF;

  SELECT
    NULLIF(BTRIM(COALESCE(p.full_name, '')), ''),
    NULLIF(BTRIM(COALESCE(p.phone, '')), ''),
    NULLIF(LOWER(BTRIM(COALESCE(u.email, ''))), '')
  INTO
    fallback_owner_name,
    fallback_owner_phone_raw,
    fallback_owner_email
  FROM auth.users AS u
  LEFT JOIN public.profiles AS p
    ON p.id = u.id
  WHERE u.id = related_business.owner_id;

  BEGIN
    fallback_owner_phone := public.normalize_ghana_phone(fallback_owner_phone_raw);
  EXCEPTION
    WHEN OTHERS THEN
      fallback_owner_phone := NULL;
  END;

  NEW.owner_full_name := COALESCE(
    NULLIF(BTRIM(COALESCE(NEW.owner_full_name, '')), ''),
    fallback_owner_name
  );
  NEW.owner_phone := COALESCE(
    public.normalize_ghana_phone(NEW.owner_phone),
    fallback_owner_phone
  );
  NEW.owner_email := COALESCE(
    NULLIF(LOWER(BTRIM(COALESCE(NEW.owner_email, ''))), ''),
    fallback_owner_email
  );
  NEW.superintendent_full_name := NULLIF(BTRIM(COALESCE(NEW.superintendent_full_name, '')), '');
  NEW.superintendent_phone := public.normalize_ghana_phone(NEW.superintendent_phone);
  NEW.superintendent_email := NULLIF(
    LOWER(BTRIM(COALESCE(NEW.superintendent_email, ''))),
    ''
  );

  IF NEW.owner_full_name IS NULL THEN
    RAISE EXCEPTION 'Owner full name is required.';
  END IF;

  IF NEW.owner_phone IS NULL THEN
    RAISE EXCEPTION 'Owner phone number is required.';
  END IF;

  IF NEW.owner_email IS NULL THEN
    RAISE EXCEPTION 'Owner email address is required.';
  END IF;

  IF NEW.owner_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Owner email address is invalid.';
  END IF;

  IF related_business.type <> 'pharmacy' THEN
    NEW.superintendent_full_name := NULL;
    NEW.superintendent_phone := NULL;
    NEW.superintendent_email := NULL;
    RETURN NEW;
  END IF;

  IF related_business.owner_is_superintendent THEN
    NEW.superintendent_full_name := NEW.owner_full_name;
    NEW.superintendent_phone := NEW.owner_phone;
    NEW.superintendent_email := NEW.owner_email;
    RETURN NEW;
  END IF;

  IF NEW.superintendent_full_name IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist full name is required.';
  END IF;

  IF NEW.superintendent_phone IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist phone number is required.';
  END IF;

  IF NEW.superintendent_email IS NULL THEN
    RAISE EXCEPTION 'Superintendent pharmacist email address is required.';
  END IF;

  IF NEW.superintendent_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Superintendent pharmacist email address is invalid.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_normalize_business_private_contacts ON public.business_private_contacts;
CREATE TRIGGER trg_normalize_business_private_contacts
  BEFORE INSERT OR UPDATE ON public.business_private_contacts
  FOR EACH ROW
  EXECUTE FUNCTION public.normalize_business_private_contacts();

UPDATE public.business_private_contacts AS c
SET
  owner_full_name = c.owner_full_name,
  owner_phone = c.owner_phone,
  owner_email = c.owner_email,
  superintendent_full_name = COALESCE(c.superintendent_full_name, c.owner_full_name),
  superintendent_phone = COALESCE(c.superintendent_phone, c.owner_phone),
  superintendent_email = COALESCE(c.superintendent_email, c.owner_email)
FROM public.businesses AS b
WHERE b.id = c.business_id
  AND (b.type <> 'pharmacy' OR b.owner_is_superintendent);
