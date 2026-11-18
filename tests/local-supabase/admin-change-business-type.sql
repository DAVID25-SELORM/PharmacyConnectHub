-- admin_change_business_type / admin_business_type_blockers (migration 20261213100000).
-- Run after setup.sql with the migration applied:  psql -v ON_ERROR_STOP=1 -f admin-change-business-type.sql
-- Everything runs in a transaction that is rolled back.
BEGIN;

DO $$
DECLARE
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  e1 UUID; e2 UUID; e3 UUID; e4 UUID;
  r TEXT; t TEXT; st TEXT; n INT;
BEGIN
  -- Fixtures (inserted as the table owner, so auth.uid() is NULL and the triggers let it through).
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status, verified_at)
    VALUES (u_nb, 'pharmacy', 'TT Approved Empty Pharmacy', 'TT-1', 'approved', now()) RETURNING id INTO e1;
  INSERT INTO public.businesses(owner_id, type, name, license_number)
    VALUES (u_nb, 'pharmacy', 'TT Pending Empty Pharmacy', 'TT-2') RETURNING id INTO e2;
  INSERT INTO public.businesses(owner_id, type, name, license_number)
    VALUES (u_nb, 'pharmacy', 'TT Pharmacy With Data', 'TT-3') RETURNING id INTO e3;
  INSERT INTO public.businesses(owner_id, type, name, license_number)
    VALUES (u_nb, 'wholesaler', 'TT Wholesaler Empty', 'TT-4') RETURNING id INTO e4;
  DELETE FROM public.user_roles WHERE user_id = u_nb;
  INSERT INTO public.user_roles(user_id, role) VALUES (u_nb, 'pharmacy');

  -- Registration paperwork must NOT count as data: documents, staff row, audit trail all exist.
  INSERT INTO public.license_documents(business_id, doc_type, storage_path) VALUES (e1, 'pharmacy_council', 'tt/e1.pdf');
  PERFORM zz.check('fixture: paperwork rows exist',
    EXISTS (SELECT 1 FROM public.business_staff WHERE business_id = e1)
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = e1)
    AND EXISTS (SELECT 1 FROM public.license_documents WHERE business_id = e1));

  -- Real data on e3.
  INSERT INTO public.pharmacy_saved_carts(pharmacy_id, name) VALUES (e3, 'cart');

  -- Access control
  r := zz.run_as(u_wo, format($q$SELECT public.admin_change_business_type(%L,'wholesaler')$q$, e1));
  PERFORM zz.check('non-admin cannot switch a business', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_nb, format($q$SELECT public.admin_change_business_type(%L,'wholesaler')$q$, e1));
  PERFORM zz.check('the owner cannot switch their own business', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_wo, format($q$SELECT * FROM public.admin_business_type_blockers(%L)$q$, e1));
  PERFORM zz.check('non-admin cannot read blockers', r LIKE 'ERR: Only platform admins%', r);
  PERFORM zz.check('type untouched after refusals', (SELECT type::text FROM public.businesses WHERE id = e1) = 'pharmacy');

  -- Validation
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'clinic')$q$, e1));
  PERFORM zz.check('invalid type rejected', r LIKE 'ERR: Choose Pharmacy or Wholesaler%', r);
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'pharmacy')$q$, e1));
  PERFORM zz.check('same type rejected', r LIKE 'ERR: This business is already a pharmacy%', r);
  r := zz.run_as(u_admin, $q$SELECT public.admin_change_business_type('00000000-0000-0000-0000-00000000dead','wholesaler')$q$);
  PERFORM zz.check('unknown business rejected', r LIKE 'ERR: Business not found%', r);

  -- Blocked by data
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'wholesaler')$q$, e3));
  PERFORM zz.check('business with data cannot be switched', r LIKE 'ERR: This business already has data%pharmacy_saved_carts (1)%', r);
  PERFORM zz.check('blocked business is unchanged', (SELECT type::text FROM public.businesses WHERE id = e3) = 'pharmacy');
  -- Direct reads as the admin (claims set; still the table-owner role, which is fine for a read).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_admin::text, true);
  PERFORM zz.check('blockers list names the table',
    EXISTS (SELECT 1 FROM public.admin_business_type_blockers(e3) WHERE source_table = 'pharmacy_saved_carts' AND row_count = 1));
  PERFORM zz.check('empty business has no blockers (paperwork ignored)',
    NOT EXISTS (SELECT 1 FROM public.admin_business_type_blockers(e1)));
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  -- Empty approved business: switch works, goes back to pending, roles follow.
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'wholesaler','Registered as the wrong type')$q$, e1));
  PERFORM zz.check('admin can switch an empty approved business', r = 'OK', r);
  SELECT type::text, verification_status::text INTO t, st FROM public.businesses WHERE id = e1;
  PERFORM zz.check('type changed', t = 'wholesaler', t);
  PERFORM zz.check('approved business returns to pending', st = 'pending' AND (SELECT verified_at FROM public.businesses WHERE id = e1) IS NULL, st);
  PERFORM zz.check('owner gained the wholesaler role', EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = u_nb AND role = 'wholesaler'));
  PERFORM zz.check('owner keeps pharmacy role (still owns other pharmacies)', EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = u_nb AND role = 'pharmacy'));
  PERFORM zz.check('audit entry written with from/to/reason',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = e1 AND activity = 'Business type changed'
      AND details->>'from_type' = 'pharmacy' AND details->>'to_type' = 'wholesaler'
      AND details->>'reason' = 'Registered as the wrong type' AND details->>'to_status' = 'pending'));
  PERFORM zz.check('admins are told it is pending again',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = e1 AND activity = 'Business verification updated'));

  -- Pending empty business: stays pending; last pharmacy of the owner... e3 is still a pharmacy, so role stays.
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'wholesaler')$q$, e2));
  PERFORM zz.check('pending business can be switched, no reason needed', r = 'OK', r);
  PERFORM zz.check('pending stays pending', (SELECT verification_status::text FROM public.businesses WHERE id = e2) = 'pending');
  PERFORM zz.check('pharmacy role kept while another pharmacy remains', EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = u_nb AND role = 'pharmacy'));

  -- Wholesaler -> pharmacy works too, and superintendent rules still hold.
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'pharmacy')$q$, e4));
  PERFORM zz.check('wholesaler can be switched to pharmacy', r = 'OK', r);
  PERFORM zz.check('owner_is_superintendent default holds', (SELECT owner_is_superintendent FROM public.businesses WHERE id = e4));

  -- Role cleanup once the owner has no pharmacy left: move e3 away by deleting its data first.
  DELETE FROM public.pharmacy_saved_carts WHERE pharmacy_id = e3;
  DELETE FROM public.businesses WHERE id = e4;  -- remove the pharmacy created from e4 so e3 is the only one
  r := zz.run_as(u_admin, format($q$SELECT public.admin_change_business_type(%L,'wholesaler')$q$, e3));
  PERFORM zz.check('switch succeeds once the data is gone', r = 'OK', r);
  PERFORM zz.check('old role removed when owner has no business of that type left',
    NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = u_nb AND role = 'pharmacy'));
  SELECT count(*) INTO n FROM public.businesses WHERE owner_id = u_nb AND type = 'wholesaler';
  PERFORM zz.check('owner now has three wholesalers', n = 3, n::text);

  -- Other businesses untouched
  PERFORM zz.check('unrelated business untouched', (SELECT type::text FROM public.businesses WHERE name = 'Alpha Wholesale') = 'wholesaler');
END $$;

SELECT has_function_privilege('anon','public.admin_change_business_type(uuid,text,text)','EXECUTE') AS anon_exec_switch,
       has_function_privilege('authenticated','public.admin_change_business_type(uuid,text,text)','EXECUTE') AS auth_exec_switch,
       has_function_privilege('anon','public.admin_business_type_blockers(uuid)','EXECUTE') AS anon_exec_blockers;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
ROLLBACK;
