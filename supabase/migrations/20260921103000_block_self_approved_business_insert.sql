-- SECURITY: the businesses INSERT policy only checked ownership (auth.uid() = owner_id), and the
-- verification trigger runs on UPDATE only. Any signed-in user could therefore INSERT a business
-- with verification_status = 'approved' straight through the API and skip admin verification
-- entirely (reproduced on a local stack). New businesses must start as pending; only an admin
-- may insert any other status. Signup and create_additional_business() insert as SECURITY
-- DEFINER, which bypasses RLS, so they are unaffected.

DROP POLICY IF EXISTS "Owners insert own business" ON public.businesses;
CREATE POLICY "Owners insert own business"
  ON public.businesses
  FOR INSERT
  WITH CHECK (
    (auth.uid() = owner_id AND verification_status = 'pending')
    OR public.has_role(auth.uid(), 'admin')
  );
