-- Separate platform admin staff from business workspace staff.
-- Platform staff drive /admin access; business staff stay tied to business workspaces.

DO $$
BEGIN
  CREATE TYPE public.platform_staff_role AS ENUM ('owner', 'admin');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.platform_staff (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  role public.platform_staff_role NOT NULL DEFAULT 'admin',
  status public.staff_status NOT NULL DEFAULT 'pending',
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  invited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_platform_staff_user ON public.platform_staff(user_id);
CREATE INDEX IF NOT EXISTS idx_platform_staff_status ON public.platform_staff(status);

ALTER TABLE public.platform_staff ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_platform_staff(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.platform_staff
    WHERE user_id = _user_id
      AND status = 'active'
  )
$$;

CREATE OR REPLACE FUNCTION public.is_platform_owner(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.platform_staff
    WHERE user_id = _user_id
      AND role = 'owner'
      AND status = 'active'
  )
$$;

DROP POLICY IF EXISTS "View platform staff" ON public.platform_staff;
CREATE POLICY "View platform staff"
  ON public.platform_staff
  FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_platform_staff(auth.uid())
    OR public.has_role(auth.uid(), 'admin')
  );

DROP POLICY IF EXISTS "Owners add platform staff" ON public.platform_staff;
CREATE POLICY "Owners add platform staff"
  ON public.platform_staff
  FOR INSERT
  TO authenticated
  WITH CHECK (public.is_platform_owner(auth.uid()));

DROP POLICY IF EXISTS "Owners manage platform staff" ON public.platform_staff;
CREATE POLICY "Owners manage platform staff"
  ON public.platform_staff
  FOR UPDATE
  TO authenticated
  USING (public.is_platform_owner(auth.uid()))
  WITH CHECK (public.is_platform_owner(auth.uid()));

DROP POLICY IF EXISTS "Owners remove platform staff" ON public.platform_staff;
CREATE POLICY "Owners remove platform staff"
  ON public.platform_staff
  FOR DELETE
  TO authenticated
  USING (public.is_platform_owner(auth.uid()));

DROP TRIGGER IF EXISTS trg_platform_staff_updated ON public.platform_staff;
CREATE TRIGGER trg_platform_staff_updated
  BEFORE UPDATE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE OR REPLACE FUNCTION public.sync_platform_staff_admin_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.user_roles
    WHERE user_id = OLD.user_id
      AND role = 'admin'
      AND NOT EXISTS (
        SELECT 1
        FROM public.platform_staff ps
        WHERE ps.user_id = OLD.user_id
          AND ps.status = 'active'
      );

    RETURN OLD;
  END IF;

  IF NEW.status = 'active' THEN
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.user_id, 'admin')
    ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    DELETE FROM public.user_roles
    WHERE user_id = NEW.user_id
      AND role = 'admin'
      AND NOT EXISTS (
        SELECT 1
        FROM public.platform_staff ps
        WHERE ps.user_id = NEW.user_id
          AND ps.id <> NEW.id
          AND ps.status = 'active'
      );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_platform_staff_admin_role ON public.platform_staff;
CREATE TRIGGER trg_sync_platform_staff_admin_role
  AFTER INSERT OR UPDATE OR DELETE ON public.platform_staff
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_platform_staff_admin_role();

WITH ranked_admins AS (
  SELECT
    ur.user_id,
    u.created_at,
    ROW_NUMBER() OVER (ORDER BY u.created_at, u.id) AS admin_rank
  FROM public.user_roles ur
  JOIN auth.users u ON u.id = ur.user_id
  WHERE ur.role = 'admin'
)
INSERT INTO public.platform_staff (user_id, role, status, invited_by, invited_at, joined_at)
SELECT
  ranked_admins.user_id,
  CASE
    WHEN ranked_admins.admin_rank = 1 THEN 'owner'::public.platform_staff_role
    ELSE 'admin'::public.platform_staff_role
  END,
  'active'::public.staff_status,
  (
    SELECT user_id
    FROM ranked_admins
    WHERE admin_rank = 1
    LIMIT 1
  ),
  COALESCE(ranked_admins.created_at, now()),
  COALESCE(ranked_admins.created_at, now())
FROM ranked_admins
ON CONFLICT (user_id) DO NOTHING;

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
BEGIN
  IF NOT (
    public.is_platform_staff(auth.uid())
    OR public.has_role(auth.uid(), 'admin')
  ) THEN
    RAISE EXCEPTION 'Not authorized to view the platform team.';
  END IF;

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
  FROM public.platform_staff ps
  LEFT JOIN public.profiles p ON p.id = ps.user_id
  LEFT JOIN auth.users u ON u.id = ps.user_id
  ORDER BY
    CASE ps.role
      WHEN 'owner' THEN 0
      ELSE 1
    END,
    COALESCE(ps.joined_at, ps.invited_at) DESC,
    ps.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.is_platform_staff(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_platform_owner(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_platform_staff() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_platform_staff(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_platform_owner(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_platform_staff() TO authenticated;
