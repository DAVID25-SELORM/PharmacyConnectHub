-- Run against the isolated credit_review_clean fixtures; all changes roll back.
BEGIN;
DO $$
DECLARE owner_uid UUID := (SELECT id FROM zz.u WHERE k='w_owner');
 admin_uid UUID := (SELECT id FROM zz.u WHERE k='admin');
 other_uid UUID := (SELECT id FROM zz.u WHERE k='ph_other');
 bid UUID := (SELECT id FROM public.businesses WHERE name='Alpha Wholesale');
 new_id UUID; r RECORD;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',admin_uid::text,true);
 SELECT * INTO r FROM public.update_business_profile_with_contacts(bid,'Alpha Wholesale','LIC-777',true,NULL,'Accra','Greater Accra','0241234567',NULL,'a@example.com',NULL,NULL,'Alpha Owner','0241000002','wo@zz.test',NULL,NULL);
 IF r.business_id IS DISTINCT FROM bid OR r.owner_phone IS DISTINCT FROM '+233241000002' THEN RAISE EXCEPTION 'Admin update failed'; END IF;
 -- A legacy login profile can be incomplete while its business contacts are valid.
 UPDATE public.profiles SET full_name=NULL,phone=NULL WHERE id=owner_uid;
 PERFORM set_config('request.jwt.claim.sub',owner_uid::text,true);
 new_id:=public.create_additional_business('pharmacy','Regression second pharmacy','LIC-778','Accra','Greater Accra','0241234567','second@example.com');
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=new_id AND owner_id=owner_uid AND verification_status='pending') THEN RAISE EXCEPTION 'Wrong ownership/status'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.business_private_contacts WHERE business_id=new_id AND owner_full_name='Alpha Owner' AND owner_phone='+233241000002' AND superintendent_phone=owner_phone) THEN RAISE EXCEPTION 'Contact fallback failed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.business_staff WHERE business_id=new_id AND user_id=owner_uid AND role='owner') THEN RAISE EXCEPTION 'Owner membership missing'; END IF;
 PERFORM public.update_business_profile_with_contacts(new_id,'Updated second pharmacy','LIC-778',true,NULL,'Accra','Greater Accra','0241234567',NULL,'second@example.com',NULL,NULL,'Alpha Owner','0241000002','wo@zz.test',NULL,NULL);
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=new_id AND name='Updated second pharmacy') THEN RAISE EXCEPTION 'Owner update failed'; END IF;
 PERFORM set_config('request.jwt.claim.sub',other_uid::text,true);
 BEGIN
  PERFORM public.update_business_profile_with_contacts(new_id,'Forbidden','LIC-778',true,NULL,'Accra','Greater Accra','0241234567',NULL,'second@example.com',NULL,NULL,'Other','0241000002','other@example.com',NULL,NULL);
  RAISE EXCEPTION 'Unauthorized update succeeded';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM <> 'Not authorized to update this business.' THEN RAISE; END IF;
 END;
 -- An unrelated user's contacts must not fill an account with no owner details.
 UPDATE public.profiles SET full_name=NULL,phone=NULL WHERE id=(SELECT id FROM zz.u WHERE k='nobody');
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='nobody'),true);
 BEGIN
  PERFORM public.create_additional_business('pharmacy','Must not exist','LIC-779','Accra','Greater Accra','0241234567','none@example.com');
  RAISE EXCEPTION 'Missing contacts accepted';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM NOT LIKE 'Your owner name and phone are incomplete.%' THEN RAISE; END IF;
 END;
 IF EXISTS(SELECT 1 FROM public.businesses WHERE name='Must not exist') THEN RAISE EXCEPTION 'Failed creation left a business'; END IF;
 RAISE NOTICE 'PASS: admin/owner edits, legacy contact fallback, pending ownership, membership, cross-owner denial';
END $$;
ROLLBACK;
