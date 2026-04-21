-- Remove xtalcfc@gmail.com from the Ideal Pharmacy business team roster only.
-- This keeps any platform-level access intact while clearing the workspace staff record.

DELETE FROM public.business_staff AS bs
USING public.businesses AS b, auth.users AS u
WHERE bs.business_id = b.id
  AND bs.user_id = u.id
  AND lower(b.name) = lower('Ideal Pharmacy')
  AND lower(u.email) = lower('xtalcfc@gmail.com');
