-- Realistic fixtures created through the real signup trigger (handle_new_user).
DELETE FROM public.order_items;
DELETE FROM public.orders;
DELETE FROM public.products;
DELETE FROM public.customer_discounts;
DELETE FROM auth.users WHERE email LIKE '%@zz.test';
DROP SCHEMA IF EXISTS zz CASCADE;
CREATE SCHEMA zz;

CREATE TABLE zz.results(seq SERIAL, name TEXT, ok BOOLEAN, detail TEXT);

CREATE FUNCTION zz.run_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
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

-- count rows a statement returns/affects as a given user (wrap DML in a CTE ... RETURNING)
CREATE FUNCTION zz.count_as(p_uid UUID, p_sql TEXT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') q' INTO n;
  EXCEPTION WHEN OTHERS THEN
    n := -1;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN n;
END $$;

CREATE FUNCTION zz.check(p_name TEXT, p_ok BOOLEAN, p_detail TEXT DEFAULT '') RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO zz.results(name, ok, detail) VALUES (p_name, COALESCE(p_ok, FALSE), p_detail);
  RAISE NOTICE '% | %  %', CASE WHEN COALESCE(p_ok, FALSE) THEN 'PASS' ELSE 'FAIL' END, p_name, p_detail;
END $$;

CREATE FUNCTION zz.mkuser(p_id UUID, p_email TEXT, p_meta JSONB) RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  VALUES (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', p_email, p_meta, '{"provider":"email"}', now(), now());
$$;

CREATE FUNCTION zz.biz_meta(p_role TEXT, p_name TEXT, p_lic TEXT, p_owner TEXT, p_phone TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('role', p_role, 'business_name', p_name, 'license_number', p_lic, 'city', 'Accra', 'region', 'Greater Accra',
    'full_name', p_owner, 'phone', p_phone, 'public_phone', p_phone, 'public_email', lower(replace(p_name, ' ', '')) || '@example.com',
    'owner_is_superintendent', true);
$$;

-- IDs
CREATE TABLE zz.u(k TEXT PRIMARY KEY, id UUID);
INSERT INTO zz.u VALUES
 ('admin',        '10000000-0000-0000-0000-000000000001'),
 ('w_owner',      '10000000-0000-0000-0000-000000000002'),
 ('w_manager',    '10000000-0000-0000-0000-000000000003'),
 ('w_cashier',    '10000000-0000-0000-0000-000000000004'),
 ('w_pending',    '10000000-0000-0000-0000-000000000005'),
 ('w_rejected',   '10000000-0000-0000-0000-000000000006'),
 ('w_other',      '10000000-0000-0000-0000-000000000007'),
 ('ph_owner',     '10000000-0000-0000-0000-000000000008'),
 ('ph_pending',   '10000000-0000-0000-0000-000000000009'),
 ('ph_other',     '10000000-0000-0000-0000-00000000000a'),
 ('nobody',       '10000000-0000-0000-0000-00000000000b');

-- The first auth user becomes the platform admin (handle_new_user), so create it first.
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='admin'), 'admin@zz.test', '{"full_name":"Admin User","phone":"+233241000001"}');
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_owner'),    'wo@zz.test', zz.biz_meta('wholesaler','Alpha Wholesale','W-1','Alpha Owner','+233241000002'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_manager'),  'wm@zz.test', '{"full_name":"Alpha Manager","phone":"+233241000003"}');
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_cashier'),  'wc@zz.test', '{"full_name":"Alpha Cashier","phone":"+233241000004"}');
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_pending'),  'wp@zz.test', zz.biz_meta('wholesaler','Pending Wholesale','W-2','Pending Owner','+233241000005'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_rejected'), 'wr@zz.test', zz.biz_meta('wholesaler','Rejected Wholesale','W-3','Rejected Owner','+233241000006'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='w_other'),    'wx@zz.test', zz.biz_meta('wholesaler','Other Wholesale','W-4','Other Owner','+233241000007'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='ph_owner'),   'po@zz.test', zz.biz_meta('pharmacy','Good Pharmacy','P-1','Pharm Owner','+233241000008'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='ph_pending'), 'pp@zz.test', zz.biz_meta('pharmacy','Pending Pharmacy','P-2','Pending Pharm','+233241000009'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='ph_other'),   'px@zz.test', zz.biz_meta('pharmacy','Other Pharmacy','P-3','Other Pharm','+233241000010'));
SELECT zz.mkuser((SELECT id FROM zz.u WHERE k='nobody'),     'nb@zz.test', '{"full_name":"Nobody Here","phone":"+233241000011"}');

CREATE VIEW zz.b AS SELECT b.name, b.id, b.owner_id, b.type, b.verification_status FROM public.businesses b;

-- statuses (postgres / no JWT => allowed by the verification trigger)
UPDATE public.businesses SET verification_status = 'approved' WHERE name IN ('Alpha Wholesale','Other Wholesale','Good Pharmacy','Other Pharmacy');
UPDATE public.businesses SET verification_status = 'rejected', rejection_reason = 'Licence unreadable' WHERE name = 'Rejected Wholesale';

-- staff on Alpha Wholesale
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.u WHERE k='w_manager'), 'manager', 'active', now();
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.u WHERE k='w_cashier'), 'cashier', 'active', now();

-- pre-existing discounts for direct-table RLS tests
INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent)
SELECT w.id, p.id, 'percentage', 5 FROM zz.b w, zz.b p WHERE w.name='Alpha Wholesale' AND p.name='Good Pharmacy';
INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent)
SELECT w.id, p.id, 'percentage', 6 FROM zz.b w, zz.b p WHERE w.name='Other Wholesale' AND p.name='Good Pharmacy';
INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent)
SELECT w.id, p.id, 'percentage', 7 FROM zz.b w, zz.b p WHERE w.name='Pending Wholesale' AND p.name='Good Pharmacy';
-- a wholesaler-created discount for a pending pharmacy (commercial terms that must not leak)
INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent)
SELECT w.id, p.id, 'percentage', 8 FROM zz.b w, zz.b p WHERE w.name='Alpha Wholesale' AND p.name='Pending Pharmacy';

SELECT k, id FROM zz.u WHERE k='admin';
SELECT name, type, verification_status FROM zz.b ORDER BY name;
SELECT (SELECT count(*) FROM public.user_roles WHERE role='admin') AS admins;

CREATE FUNCTION zz.dml_as(p_uid UUID, p_dml TEXT) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE n BIGINT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE 'WITH x AS (' || p_dml || ' RETURNING 1) SELECT count(*) FROM x' INTO n;
  EXCEPTION WHEN OTHERS THEN
    n := -1;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN n;
END $$;
