DROP FUNCTION IF EXISTS public.get_user_business_context();

CREATE FUNCTION public.get_user_business_context()
RETURNS TABLE (
  id UUID,
  type public.business_type,
  name TEXT,
  license_number TEXT,
  owner_is_superintendent BOOLEAN,
  superintendent_name TEXT,
  city TEXT,
  region TEXT,
  verification_status public.verification_status,
  rejection_reason TEXT,
  staff_role public.staff_role
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    b.id,
    b.type,
    b.name,
    b.license_number,
    b.owner_is_superintendent,
    b.superintendent_name,
    b.city,
    b.region,
    b.verification_status,
    b.rejection_reason,
    bs.role AS staff_role
  FROM public.business_staff bs
  JOIN public.businesses b ON b.id = bs.business_id
  WHERE bs.user_id = auth.uid()
    AND bs.status = 'active'
  ORDER BY
    CASE bs.role
      WHEN 'owner' THEN 0
      WHEN 'manager' THEN 1
      WHEN 'cashier' THEN 2
      ELSE 3
    END,
    COALESCE(bs.joined_at, bs.created_at) DESC,
    b.created_at DESC
  LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.get_user_business_context() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_user_business_context() TO authenticated;
