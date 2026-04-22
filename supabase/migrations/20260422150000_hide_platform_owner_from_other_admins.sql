-- Remove the platform owner entirely from the platform team roster for
-- non-owner admins. The owner should only be visible to themself.

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
    p.full_name,
    p.phone,
    u.email::TEXT AS user_email
  FROM public.platform_staff AS ps
  LEFT JOIN public.profiles AS p
    ON p.id = ps.user_id
  LEFT JOIN auth.users AS u
    ON u.id = ps.user_id
  WHERE viewer_is_platform_owner
    OR ps.role <> 'owner'
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
