-- Hospitals and clinics (migration 20261214100000): businesses.facility_kind.
-- Run after setup.sql, with the migration applied in the same transaction (see the runner command
-- in the pull request):  psql -v ON_ERROR_STOP=1
-- Everything runs in a transaction that is rolled back.
DO $$
DECLARE
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  p1 UUID; w1 UUID; c1 UUID; bid UUID; sid UUID; sid2 UUID;
  r TEXT; n INT; k TEXT;
BEGIN
  INSERT INTO public.businesses(owner_id, type, name, license_number)
    VALUES (u_nb, 'pharmacy', 'TT Plain Pharmacy', 'TH-1') RETURNING id INTO p1;
  INSERT INTO public.businesses(owner_id, type, name, license_number)
    VALUES (u_nb, 'wholesaler', 'TT Plain Wholesaler', 'TH-2') RETURNING id INTO w1;

  PERFORM zz.check('existing businesses default to no facility kind',
    (SELECT facility_kind FROM public.businesses WHERE id = p1) IS NULL);

  -- Data rules
  r := zz.run_as(u_admin, format($q$UPDATE public.businesses SET facility_kind='surgery' WHERE id=%L$q$, p1));
  PERFORM zz.check('an unknown facility kind is rejected', r LIKE 'ERR:%', r);
  r := zz.run_as(u_admin, format($q$UPDATE public.businesses SET facility_kind='hospital_clinic' WHERE id=%L$q$, w1));
  PERFORM zz.check('a wholesaler cannot be marked a hospital or clinic (cleared, not stored)',
    (SELECT facility_kind FROM public.businesses WHERE id = w1) IS NULL, r);

  -- Admin sets and clears the kind
  r := zz.run_as(u_wo, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, p1));
  PERFORM zz.check('non-admin cannot mark a business', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_nb, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, p1));
  PERFORM zz.check('the owner cannot mark their own business through the function', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_nb, format($q$UPDATE public.businesses SET facility_kind='hospital_clinic' WHERE id=%L$q$, p1));
  PERFORM zz.check('the owner cannot mark their own business by editing the row', r LIKE 'ERR: Only admins can change%', r);
  PERFORM zz.check('still no kind after the refusals', (SELECT facility_kind FROM public.businesses WHERE id = p1) IS NULL);

  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'surgery')$q$, p1));
  PERFORM zz.check('admin: unknown kind rejected', r LIKE 'ERR: Unknown facility kind%', r);
  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, w1));
  PERFORM zz.check('admin: a wholesaler cannot be a hospital or clinic', r LIKE 'ERR: Only a pharmacy-type business%', r);
  r := zz.run_as(u_admin, $q$SELECT public.admin_set_facility_kind('00000000-0000-0000-0000-00000000dead','hospital_clinic')$q$);
  PERFORM zz.check('admin: unknown business rejected', r LIKE 'ERR: Business not found%', r);

  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, p1));
  PERFORM zz.check('admin can mark a pharmacy as a hospital or clinic', r = 'OK', r);
  PERFORM zz.check('kind stored and type unchanged',
    (SELECT facility_kind || '/' || type::text FROM public.businesses WHERE id = p1) = 'hospital_clinic/pharmacy');
  SELECT count(*) INTO n FROM public.audit_logs WHERE record_id = p1 AND activity = 'Facility kind changed';
  PERFORM zz.check('the change is audited', n = 1, n::text);
  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, p1));
  SELECT count(*) INTO n FROM public.audit_logs WHERE record_id = p1 AND activity = 'Facility kind changed';
  PERFORM zz.check('marking it again is harmless and not audited twice', r = 'OK' AND n = 1, n::text);

  -- Switching a hospital/clinic to wholesaler clears the kind (the empty business can switch).
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'wholesaler','Signed up as the wrong type')$q$, p1));
  PERFORM zz.check('a hospital/clinic can be switched to wholesaler', r = 'OK', r);
  PERFORM zz.check('the kind is cleared by the switch',
    (SELECT facility_kind FROM public.businesses WHERE id = p1) IS NULL
    AND (SELECT type::text FROM public.businesses WHERE id = p1) = 'wholesaler');

  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, w1));
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'pharmacy')$q$, p1));
  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,'hospital_clinic')$q$, p1));
  r := zz.run_as(u_admin, format($q$SELECT public.admin_set_facility_kind(%L,NULL)$q$, p1));
  PERFORM zz.check('admin can clear the kind', r = 'OK' AND (SELECT facility_kind FROM public.businesses WHERE id = p1) IS NULL, r);

  -- Adding another business under the same login
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','TT Clinic One','LIC-901','Kumasi','Ashanti','+233241234567','c@x.co', _facility_kind => 'hospital_clinic')$q$);
  PERFORM zz.check('add business: a hospital/clinic can be registered', r = 'OK', r);
  SELECT id INTO c1 FROM public.businesses WHERE name = 'TT Clinic One';
  PERFORM zz.check('add business: stored as pharmacy type with the kind and starts pending',
    (SELECT type::text || '/' || facility_kind || '/' || verification_status::text FROM public.businesses WHERE id = c1) = 'pharmacy/hospital_clinic/pending');
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','TT Plain Two','LIC-902','Kumasi','Ashanti','+233241234567','p@x.co')$q$);
  PERFORM zz.check('add business: leaving the kind out gives a plain pharmacy',
    r = 'OK' AND (SELECT facility_kind FROM public.businesses WHERE name = 'TT Plain Two') IS NULL, r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('wholesaler','TT Wholesale Two','LIC-903','Kumasi','Ashanti','+233241234567','w@x.co', _facility_kind => 'hospital_clinic')$q$);
  PERFORM zz.check('add business: a wholesaler never gets the kind',
    r = 'OK' AND (SELECT facility_kind FROM public.businesses WHERE name = 'TT Wholesale Two') IS NULL, r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','TT Clinic Bad','LIC-904','Kumasi','Ashanti','+233241234567','b@x.co', _facility_kind => 'surgery')$q$);
  PERFORM zz.check('add business: an unknown kind is ignored, not stored',
    (SELECT facility_kind FROM public.businesses WHERE name = 'TT Clinic Bad') IS NULL, r);

  -- Signup through the auth trigger
  sid := gen_random_uuid();
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  VALUES (sid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-clinic-signup@zz.test',
    jsonb_build_object('role','pharmacy','facility_kind','hospital_clinic','business_name','TT Signup Clinic','license_number','SU-1','city','Accra','region','Greater Accra','full_name','Clinic Owner','phone','+233241000999','owner_is_superintendent', true),
    now(), now());
  SELECT facility_kind INTO k FROM public.businesses WHERE owner_id = sid;
  PERFORM zz.check('signup: a hospital/clinic signs up with the pharmacy role and the kind',
    k = 'hospital_clinic' AND (SELECT type::text FROM public.businesses WHERE owner_id = sid) = 'pharmacy'
    AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = sid AND role = 'pharmacy'), k);

  sid2 := gen_random_uuid();
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  VALUES (sid2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-wh-signup@zz.test',
    jsonb_build_object('role','wholesaler','facility_kind','hospital_clinic','business_name','TT Signup Wholesale','license_number','SU-2','city','Accra','region','Greater Accra','full_name','Wholesale Owner','phone','+233241000998'),
    now(), now());
  PERFORM zz.check('signup: a wholesaler never gets the kind',
    (SELECT facility_kind FROM public.businesses WHERE owner_id = sid2) IS NULL
    AND (SELECT type::text FROM public.businesses WHERE owner_id = sid2) = 'wholesaler');

  sid := gen_random_uuid();
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
  VALUES (sid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-plain-signup@zz.test',
    jsonb_build_object('role','pharmacy','business_name','TT Signup Pharmacy','license_number','SU-3','city','Accra','region','Greater Accra','full_name','Pharm Owner','phone','+233241000997','owner_is_superintendent', true),
    now(), now());
  PERFORM zz.check('signup: an ordinary pharmacy still signs up without a kind',
    (SELECT facility_kind FROM public.businesses WHERE owner_id = sid) IS NULL
    AND (SELECT type::text FROM public.businesses WHERE owner_id = sid) = 'pharmacy');
END $$;
