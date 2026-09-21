DO $$
DECLARE
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  r TEXT; bid UUID; st TEXT; n INT;
  call_sql TEXT := $q$SELECT public.create_additional_business(%L, %L, 'LIC-777', 'Kumasi', 'Ashanti', '+233241234567', 'Second@Example.com')$q$;
BEGIN
  r := zz.run_as(u_wo, format(call_sql, 'pharmacy', 'Second Pharmacy'));
  PERFORM zz.check('existing wholesaler owner can add a pharmacy', r='OK', r);
  SELECT id, verification_status::text INTO bid, st FROM public.businesses WHERE name='Second Pharmacy';
  PERFORM zz.check('new business is owned by the caller and starts PENDING', st='pending' AND (SELECT owner_id FROM public.businesses WHERE id=bid)=u_wo, st);
  PERFORM zz.check('owner staff row created for the new business', EXISTS (SELECT 1 FROM public.business_staff WHERE business_id=bid AND user_id=u_wo AND role='owner'));
  PERFORM zz.check('private contacts row created with owner details from the profile',
    EXISTS (SELECT 1 FROM public.business_private_contacts WHERE business_id=bid AND owner_full_name='Alpha Owner' AND owner_phone='+233241000002' AND owner_email='wo@zz.test' AND superintendent_full_name='Alpha Owner'));
  PERFORM zz.check('audit entry written for the new business', EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id=bid AND activity ILIKE '%submitted%'));
  PERFORM zz.check('public email is lower-cased', (SELECT public_email FROM public.businesses WHERE id=bid)='second@example.com');
  PERFORM zz.check('user now owns two businesses', (SELECT count(*) FROM public.businesses WHERE owner_id=u_wo)=2);
  PERFORM zz.check('existing business is untouched (still approved)', (SELECT verification_status::text FROM public.businesses WHERE name='Alpha Wholesale')='approved');

  r := zz.run_as(u_nb, format(call_sql, 'wholesaler', 'Nobody Wholesale'));
  PERFORM zz.check('a user with no business can add one', r='OK', r);
  r := zz.run_as(u_wo, format(call_sql, 'clinic', 'Bad Type'));
  PERFORM zz.check('invalid type rejected', r LIKE 'ERR: Choose Pharmacy or Wholesaler%', r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','X','LIC-777','Kumasi','Ashanti','+233241234567','a@b.co')$q$);
  PERFORM zz.check('short name rejected', r LIKE 'ERR: Business name is required%', r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','Bad Email Pharm','LIC-777','Kumasi','Ashanti','+233241234567','not-an-email')$q$);
  PERFORM zz.check('invalid public email rejected', r LIKE 'ERR: Enter a valid public business email%', r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','Super Missing','LIC-777','Kumasi','Ashanti','+233241234567','a@b.co',NULL,NULL,NULL,false)$q$);
  PERFORM zz.check('pharmacy without owner-as-superintendent needs superintendent details', r LIKE 'ERR:%uperintendent%', r);
  r := zz.run_as(u_wo, $q$SELECT public.create_additional_business('pharmacy','Super Ok Pharmacy','LIC-778','Kumasi','Ashanti','+233241234567','a@b.co',NULL,NULL,NULL,false,'Dr Kofi Mensah','024 123 4568','kofi@example.com')$q$);
  PERFORM zz.check('pharmacy with a separate superintendent succeeds', r='OK', r);
  PERFORM zz.check('superintendent details stored privately', EXISTS (SELECT 1 FROM public.business_private_contacts c JOIN public.businesses b ON b.id=c.business_id WHERE b.name='Super Ok Pharmacy' AND c.superintendent_full_name='Dr Kofi Mensah' AND c.superintendent_phone='+233241234568'));

  -- caller cannot pick approval or someone else as owner: there is no such parameter; direct-insert probe below
  n := (SELECT count(*) FROM public.businesses WHERE owner_id=u_px);
  PERFORM zz.check('another user''s businesses are unaffected', n=1, n::text);

  -- cap of 10
  FOR i IN 1..8 LOOP
    r := zz.run_as(u_wo, format(call_sql, 'pharmacy', 'Cap Pharmacy ' || i));
  END LOOP;
  r := zz.run_as(u_wo, format(call_sql, 'pharmacy', 'Cap Pharmacy 11'));
  PERFORM zz.check('ownership cap (10) enforced', r LIKE 'ERR: This account already owns the maximum%', r);
END $$;

-- grants: anon cannot call, authenticated can
SELECT has_function_privilege('anon','public.create_additional_business(text,text,text,text,text,text,text,text,text,text,boolean,text,text,text)','EXECUTE') AS anon_exec,
       has_function_privilege('authenticated','public.create_additional_business(text,text,text,text,text,text,text,text,text,text,boolean,text,text,text)','EXECUTE') AS auth_exec;

-- PROBE (pre-existing behaviour): can a signed-in user insert an already-APPROVED business directly?
SELECT zz.run_as((SELECT id FROM zz.u WHERE k='ph_other'),
  format($q$INSERT INTO public.businesses(owner_id,type,name,license_number,verification_status) VALUES (%L,'pharmacy','Self Approved','X-1','approved')$q$, (SELECT id FROM zz.u WHERE k='ph_other'))) AS direct_insert_approved;
SELECT name, verification_status FROM public.businesses WHERE name='Self Approved';
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
