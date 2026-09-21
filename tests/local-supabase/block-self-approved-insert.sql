-- Run after setup.sql on a local stack with 20260921103000 applied.
DO $$
DECLARE u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other'); u_admin UUID := (SELECT id FROM zz.u WHERE k='admin'); r TEXT;
BEGIN
  r := zz.run_as(u_px, format($q$INSERT INTO public.businesses(owner_id,type,name,license_number,verification_status) VALUES (%L,'pharmacy','Self Approved','X-1','approved')$q$, u_px));
  PERFORM zz.check('direct INSERT as approved is denied (RLS)', r LIKE 'ERR:%row-level security%', r);
  r := zz.run_as(u_px, format($q$INSERT INTO public.businesses(owner_id,type,name,license_number) VALUES (%L,'pharmacy','Plain Pending','X-3')$q$, u_px));
  PERFORM zz.check('direct INSERT as pending still allowed', r='OK', r);
  r := zz.run_as(u_admin, format($q$INSERT INTO public.businesses(owner_id,type,name,license_number,verification_status) VALUES (%L,'pharmacy','Admin Created','X-4','approved')$q$, u_px));
  PERFORM zz.check('platform admin can insert any status', r='OK', r);
END $$;
