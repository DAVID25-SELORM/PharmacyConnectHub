-- Keep the platform owner visible in the roster while preventing other
-- platform admins from reading the owner's personal contact details.

CREATE OR REPLACE FUNCTION public.list_platform_staff()
RETURNS TABLE (
  id UUID,
  user_id UUID,
  role public.platform_staff_role,
  status public.staff_status,
  invited_at TIMESTAMPTZ,
  joined_at TIMESTAMPTZ,
  full_name TEXT,
  phone TEXT,
  user_email TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  viewer_is_platform_owner BOOLEAN;
BEGIN
  IF NOT public.is_platform_staff(auth.uid()) THEN
    RAISE EXCEPTION 'Not authorized to view the platform team.';
  END IF;

  viewer_is_platform_owner := public.is_platform_owner(auth.uid());

  RETURN QUERY
  SELECT
    ps.id,
    ps.user_id,
    ps.role,
    ps.status,
    ps.invited_at,
    ps.joined_at,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE p.full_name
    END AS full_name,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE p.phone
    END AS phone,
    CASE
      WHEN ps.role = 'owner' AND NOT viewer_is_platform_owner AND ps.user_id <> auth.uid()
        THEN NULL
      ELSE u.email::TEXT
    END AS user_email
  FROM public.platform_staff AS ps
  LEFT JOIN public.profiles AS p
    ON p.id = ps.user_id
  LEFT JOIN auth.users AS u
    ON u.id = ps.user_id
  ORDER BY
    CASE ps.role
      WHEN 'owner' THEN 0
      ELSE 1
    END,
    COALESCE(ps.joined_at, ps.invited_at) DESC,
    ps.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.list_platform_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_platform_staff() TO authenticated;
