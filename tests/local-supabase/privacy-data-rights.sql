-- Privacy and data rights (migration 20261215110000, which needs 20261215100000 first for has_role).
-- Self-contained: makes its own users. Run with both migrations applied in the same transaction:
--   (echo 'BEGIN;'; cat 20261215100000*.sql 20261215110000*.sql; cat this-file; echo 'ROLLBACK;') | psql -v ON_ERROR_STOP=1
-- Everything is rolled back.

CREATE SCHEMA IF NOT EXISTS zz;
CREATE TABLE IF NOT EXISTS zz.results(seq SERIAL, name TEXT, ok BOOLEAN, detail TEXT);
CREATE OR REPLACE FUNCTION zz.check(p_name TEXT, p_ok BOOLEAN, p_detail TEXT DEFAULT '') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO zz.results(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
  RAISE NOTICE '% | %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;
GRANT USAGE ON SCHEMA zz TO authenticated;

CREATE OR REPLACE FUNCTION zz.as_user(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql;
    r := 'OK';
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

-- A scalar the user is allowed to see, as text.
CREATE OR REPLACE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE v TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO v;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN v;
END $$;

DO $$
DECLARE
  u_admin UUID := '30000000-0000-0000-0000-0000000000a1';
  u_owner UUID := '30000000-0000-0000-0000-0000000000b1';
  u_staff UUID := '30000000-0000-0000-0000-0000000000c1';
  u_other UUID := '30000000-0000-0000-0000-0000000000d1';
  biz UUID; req UUID; req2 UUID; r TEXT; v TEXT; n INT; j JSONB;
BEGIN
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at, last_sign_in_at)
  VALUES
    (u_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-priv-admin@zz.test',
      jsonb_build_object('role','pharmacy','business_name','TT Priv Admin','license_number','PA-1','city','Accra','region','Greater Accra','full_name','Priv Admin','phone','+233241000801','owner_is_superintendent', true), now(), now(), now()),
    (u_owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-priv-owner@zz.test',
      jsonb_build_object('role','pharmacy','business_name','TT Priv Owner Pharmacy','license_number','PO-1','city','Accra','region','Greater Accra','full_name','Priv Owner','phone','+233241000802','owner_is_superintendent', true), now(), now(), now()),
    (u_staff, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-priv-staff@zz.test',
      jsonb_build_object('role','pharmacy','business_name','TT Priv Staff Temp','license_number','PS-1','city','Accra','region','Greater Accra','full_name','Priv Staff','phone','+233241000803','owner_is_superintendent', true), now(), now(), now()),
    (u_other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tt-priv-other@zz.test',
      jsonb_build_object('role','pharmacy','business_name','TT Priv Other','license_number','PX-1','city','Accra','region','Greater Accra','full_name','Priv Other','phone','+233241000804','owner_is_superintendent', true), now(), now(), now());
  INSERT INTO public.user_roles(user_id, role) VALUES (u_admin, 'admin') ON CONFLICT DO NOTHING;
  DELETE FROM public.user_roles WHERE role = 'admin' AND user_id <> u_admin;
  -- u_staff is staff at the owner's pharmacy, not an owner: drop the business signup made for them.
  DELETE FROM public.businesses WHERE owner_id = u_staff;
  SELECT id INTO biz FROM public.businesses WHERE owner_id = u_owner;
  INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES (biz, u_staff, 'cashier', 'active', now());
  INSERT INTO public.push_subscriptions(user_id, endpoint, p256dh, auth) VALUES (u_staff, 'https://push.example/zz-staff', 'k', 'a');
  INSERT INTO public.notifications(user_id, type, title, body) VALUES (u_staff, 'info', 'Hello', 'Test');

  -- Consent ------------------------------------------------------------------------------------
  r := zz.as_user(u_owner, $q$SELECT public.record_consent('2026-11-22', 'signup')$q$);
  PERFORM zz.check('a person can record consent', r = 'OK', r);
  PERFORM zz.check('consent stores the privacy notice and the terms',
    (SELECT count(*) FROM public.consent_records WHERE user_id = u_owner AND version = '2026-11-22') = 2);
  r := zz.as_user(u_owner, $q$SELECT public.record_consent('2026-11-22', 'app')$q$);
  PERFORM zz.check('recording the same version again is harmless', r = 'OK', r);
  PERFORM zz.check('...and does not duplicate rows', (SELECT count(*) FROM public.consent_records WHERE user_id = u_owner) = 2);
  r := zz.as_user(u_owner, $q$SELECT public.record_consent('', 'app')$q$);
  PERFORM zz.check('an empty version is refused', r LIKE 'ERR: A document version is required%', r);
  r := zz.as_user(u_owner, $q$SELECT public.record_consent('x', 'email')$q$);
  PERFORM zz.check('an unknown source is refused', r LIKE 'ERR: Unknown source%', r);
  PERFORM zz.check('a person sees only their own consent records',
    zz.val_as(u_other, 'SELECT count(*)::text FROM public.consent_records') = '0'
    AND zz.val_as(u_owner, 'SELECT count(*)::text FROM public.consent_records') = '2');
  r := zz.as_user(u_owner, $q$INSERT INTO public.consent_records(user_id, document, version) VALUES (auth.uid(), 'terms', 'forged')$q$);
  PERFORM zz.check('consent cannot be written directly, only through the function', r LIKE 'ERR:%', r);

  -- Requests -----------------------------------------------------------------------------------------
  r := zz.as_user(u_staff, $q$SELECT public.request_data_action('erase-everything')$q$);
  PERFORM zz.check('an unknown request type is refused', r LIKE 'ERR: Unknown request type%', r);
  r := zz.as_user(u_staff, $q$SELECT public.request_data_action('correction')$q$);
  PERFORM zz.check('a correction request must say what to correct', r LIKE 'ERR: Tell us what you need%', r);
  r := zz.as_user(u_staff, $q$SELECT public.request_data_action('deletion', 'I left the company')$q$);
  PERFORM zz.check('a person can ask for their data to be deleted', r = 'OK', r);
  SELECT id INTO req FROM public.data_requests WHERE user_id = u_staff AND kind = 'deletion';
  PERFORM zz.check('the request is stored open with a 30 day deadline',
    (SELECT status = 'open' AND due_at > now() + INTERVAL '29 days' FROM public.data_requests WHERE id = req));
  r := zz.as_user(u_staff, $q$SELECT public.request_data_action('deletion')$q$);
  PERFORM zz.check('a second open request of the same kind is refused', r LIKE 'ERR: You already have an open request%', r);
  PERFORM zz.check('the admin was notified',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id = u_admin AND type = 'privacy_request'));
  PERFORM zz.check('a person sees only their own requests',
    zz.val_as(u_other, 'SELECT count(*)::text FROM public.data_requests') = '0'
    AND zz.val_as(u_staff, 'SELECT count(*)::text FROM public.data_requests') = '1');

  r := zz.as_user(u_staff, $q$SELECT public.admin_list_data_requests()$q$);
  PERFORM zz.check('non-admin cannot list the queue', r LIKE 'ERR: Only platform admins%', r);
  r := zz.as_user(u_admin, $q$SELECT public.admin_list_data_requests()$q$);
  PERFORM zz.check('admin can list the queue', r = 'OK', r);
  v := zz.val_as(u_admin, $q$SELECT (public.admin_list_data_requests() -> 0 ->> 'email')$q$);
  PERFORM zz.check('the queue shows who asked', v = 'tt-priv-staff@zz.test', v);

  -- Export --------------------------------------------------------------------------------------------------
  r := zz.as_user(u_owner, $q$SELECT public.export_my_data()$q$);
  PERFORM zz.check('a person can export their data', r = 'OK', r);
  v := zz.val_as(u_owner, $q$SELECT public.export_my_data() ->> 'account'$q$);
  PERFORM zz.check('the export holds their account', v LIKE '%tt-priv-owner@zz.test%', v);
  v := zz.val_as(u_owner, $q$SELECT public.export_my_data()::text$q$);
  PERFORM zz.check('the export holds their business', v LIKE '%TT Priv Owner Pharmacy%');
  PERFORM zz.check('the export holds nothing about other people',
    v NOT LIKE '%tt-priv-staff%' AND v NOT LIKE '%tt-priv-other%' AND v NOT LIKE '%TT Priv Other%');
  v := zz.val_as(u_staff, $q$SELECT public.export_my_data()::text$q$);
  PERFORM zz.check('a staff member export lists the membership and not the owner''s details',
    v LIKE '%TT Priv Owner Pharmacy%' AND v LIKE '%cashier%' AND v NOT LIKE '%tt-priv-owner%');

  -- Resolving ------------------------------------------------------------------------------------------------
  r := zz.as_user(u_staff, format($q$SELECT public.admin_resolve_data_request(%L, 'completed')$q$, req));
  PERFORM zz.check('non-admin cannot resolve', r LIKE 'ERR: Only platform admins%', r);
  r := zz.as_user(u_admin, format($q$SELECT public.admin_resolve_data_request(%L, 'declined')$q$, req));
  PERFORM zz.check('declining needs a reason', r LIKE 'ERR: Write the reason%', r);
  r := zz.as_user(u_admin, format($q$SELECT public.admin_resolve_data_request(%L, 'in_progress', 'Checking records')$q$, req));
  PERFORM zz.check('admin can mark it in progress', r = 'OK', r);

  -- Anonymise --------------------------------------------------------------------------------------------------
  r := zz.as_user(u_staff, format($q$SELECT public.admin_anonymise_user(%L)$q$, u_staff));
  PERFORM zz.check('non-admin cannot anonymise', r LIKE 'ERR: Only platform admins%', r);
  r := zz.as_user(u_admin, format($q$SELECT public.admin_anonymise_user(%L)$q$, u_admin));
  PERFORM zz.check('an admin cannot remove themselves', r LIKE 'ERR: You cannot remove your own account%', r);
  r := zz.as_user(u_admin, format($q$SELECT public.admin_anonymise_user(%L)$q$, u_owner));
  PERFORM zz.check('a business owner cannot be removed while they own a business', r LIKE 'ERR: This person owns: TT Priv Owner Pharmacy%', r);
  PERFORM zz.check('...and nothing changed', (SELECT email FROM auth.users WHERE id = u_owner) = 'tt-priv-owner@zz.test');
  r := zz.as_user(u_admin, $q$SELECT public.admin_anonymise_user('30000000-0000-0000-0000-0000000000ff')$q$);
  PERFORM zz.check('an unknown person is refused', r LIKE 'ERR: Person not found%', r);

  INSERT INTO auth.sessions(id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), u_staff, now(), now());
  r := zz.as_user(u_admin, format($q$SELECT public.admin_anonymise_user(%L, %L, 'Left the company')$q$, u_staff, req));
  PERFORM zz.check('admin can anonymise a staff member', r = 'OK', r);
  PERFORM zz.check('their email is replaced', (SELECT email FROM auth.users WHERE id = u_staff) = 'deleted-' || u_staff::TEXT || '@deleted.invalid');
  PERFORM zz.check('they are banned from signing in', (SELECT banned_until FROM auth.users WHERE id = u_staff) = 'infinity'::TIMESTAMPTZ);
  PERFORM zz.check('their password is gone', (SELECT encrypted_password FROM auth.users WHERE id = u_staff) IS NULL);
  PERFORM zz.check('their name and phone are removed',
    (SELECT full_name = 'Deleted user' AND phone IS NULL FROM public.profiles WHERE id = u_staff));
  PERFORM zz.check('their sessions, devices and notifications are removed',
    NOT EXISTS (SELECT 1 FROM auth.sessions WHERE user_id = u_staff)
    AND NOT EXISTS (SELECT 1 FROM public.push_subscriptions WHERE user_id = u_staff)
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = u_staff));
  PERFORM zz.check('their staff access is switched off',
    (SELECT status::TEXT FROM public.business_staff WHERE user_id = u_staff) = 'inactive');
  PERFORM zz.check('the business record they worked on is untouched',
    EXISTS (SELECT 1 FROM public.businesses WHERE id = biz AND name = 'TT Priv Owner Pharmacy'));
  PERFORM zz.check('the request was closed with the note',
    (SELECT status = 'completed' AND resolution_note = 'Left the company' AND requester_email IS NULL FROM public.data_requests WHERE id = req));
  PERFORM zz.check('removal was audited',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'User anonymised' AND record_id = u_staff));
  r := zz.as_user(u_admin, format($q$SELECT public.admin_anonymise_user(%L)$q$, u_staff));
  PERFORM zz.check('removing the same person twice is refused', r LIKE 'ERR: This person has already been removed%', r);
  r := zz.as_user(u_admin, format($q$SELECT public.admin_resolve_data_request(%L, 'completed')$q$, req));
  PERFORM zz.check('a closed request cannot be changed again', r LIKE 'ERR: This request is already closed%', r);

  -- Retention -----------------------------------------------------------------------------------------------------
  INSERT INTO public.push_subscriptions(user_id, endpoint, p256dh, auth, last_seen_at)
  VALUES (u_other, 'https://push.example/zz-stale', 'k', 'a', now() - INTERVAL '120 days'),
         (u_other, 'https://push.example/zz-fresh', 'k', 'a', now() - INTERVAL '10 days');
  INSERT INTO public.notifications(user_id, type, title, body, read, created_at)
  VALUES (u_other, 'info', 'old read', 'x', TRUE, now() - INTERVAL '200 days'),
         (u_other, 'info', 'recent read', 'x', TRUE, now() - INTERVAL '20 days'),
         (u_other, 'info', 'old unread', 'x', FALSE, now() - INTERVAL '100 days'),
         (u_other, 'info', 'ancient unread', 'x', FALSE, now() - INTERVAL '400 days');
  r := zz.as_user(u_other, 'SELECT public.run_data_retention()');
  PERFORM zz.check('only the server can run retention', r LIKE 'ERR: permission denied%', r);
  j := public.run_data_retention();
  PERFORM zz.check('retention removes the stale device and keeps the fresh one',
    (j ->> 'push_devices')::INT >= 1
    AND NOT EXISTS (SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.example/zz-stale')
    AND EXISTS (SELECT 1 FROM public.push_subscriptions WHERE endpoint = 'https://push.example/zz-fresh'));
  PERFORM zz.check('retention removes old read and ancient notifications only',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE user_id = u_other AND title IN ('old read', 'ancient unread'))
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = u_other AND title IN ('recent read', 'old unread')));
END $$;

SELECT name, ok, detail FROM zz.results WHERE NOT ok;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
