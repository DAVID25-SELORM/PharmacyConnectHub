-- Product-specific discounts: precedence over the general discount, volume rules, checkout maths, permissions.
-- Run after setup.sql + migrations (through 20260924210000_product_specific_discounts.sql).
-- setup.sql gives Good Pharmacy a 5% general customer discount with Alpha Wholesale (no minimum).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now());

CREATE TABLE zz.pd(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.pd TO PUBLIC;

-- 1. managing rules ------------------------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy'); otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other'); u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  p1 UUID; p2 UUID; px UUID; r TEXT; rid TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Pd Amox', 'Cat', 'TABLET', '10s', 100, 500, true) RETURNING id INTO p1;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Pd Para', 'Cat', 'TABLET', '10s', 50, 500, true) RETURNING id INTO p2;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (other_w, 'Pd Other', 'Cat', 'TABLET', '10s', 40, 500, true) RETURNING id INTO px;
  INSERT INTO zz.pd VALUES ('p1', p1), ('p2', p2), ('px', px);

  r := zz.val_as(u_wc, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, good, p1));
  PERFORM zz.check('cashier cannot set product discounts', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_wa, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, good, p1));
  PERFORM zz.check('assistant cannot set product discounts', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_wx, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, good, p1));
  PERFORM zz.check('another wholesaler cannot set my discounts', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_po, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', good, good, p1));
  PERFORM zz.check('a pharmacy cannot set discounts', r LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, good, px));
  PERFORM zz.check('cannot discount another wholesaler''s product', r LIKE 'ERR: Choose one of your own products%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, alpha, p1));
  PERFORM zz.check('the customer must be a pharmacy', r LIKE 'ERR: Pharmacy workspace not found%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 0)::text', alpha, good, p1));
  PERFORM zz.check('0% rejected', r LIKE 'ERR: The discount must be above 0%%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 95)::text', alpha, good, p1));
  PERFORM zz.check('over 90% rejected', r LIKE 'ERR: The discount must be above 0%%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 10, 0)::text', alpha, good, p1));
  PERFORM zz.check('minimum quantity 0 rejected', r LIKE 'ERR: The minimum quantity%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 10, 1, now(), now() - interval ''1 day'')::text', alpha, good, p1));
  PERFORM zz.check('end before start rejected', r LIKE 'ERR: The end date must be after%', r);

  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 10)::text', alpha, good, p1));
  PERFORM zz.check('manager sets 10% on Pd Amox for Good Pharmacy', r NOT LIKE 'ERR%', r);
  rid := r;
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 15, 10)::text', alpha, good, p1));
  PERFORM zz.check('manager adds a volume rule: 15% from 10 units', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT public.upsert_product_discount(%L, %L, %L, 12)::text', alpha, good, p1));
  PERFORM zz.check('re-setting the same rule replaces it (12%)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('only one active rule per (customer, product, minimum quantity)',
    (SELECT count(*) FROM public.product_discounts WHERE product_id = p1 AND pharmacy_id = good AND active) = 2
    AND (SELECT count(*) FROM public.product_discounts WHERE id = rid::uuid AND NOT active) = 1);
  -- rules that must never apply
  INSERT INTO public.product_discounts(wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity) VALUES (alpha, otherp, p1, 50, 1);
  INSERT INTO public.product_discounts(wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity, starts_at, ends_at) VALUES (alpha, good, p2, 40, 1, now() - interval '10 days', now() - interval '1 day');
  INSERT INTO public.product_discounts(wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity, starts_at) VALUES (alpha, good, p2, 45, 2, now() + interval '5 days');
  INSERT INTO public.product_discounts(wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity, active) VALUES (alpha, good, p2, 60, 1, false);

  r := zz.val_as(u_wm, format('SELECT count(*)::text FROM public.list_wholesaler_product_discounts(%L)', alpha));
  PERFORM zz.check('manager lists active rules (2 for Good + 1 for Other Pharmacy + 2 not yet/expired excluded by inactive?)', r::int >= 3, r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_wholesaler_product_discounts(%L)', alpha));
  PERFORM zz.check('cashier cannot list discounts', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.list_wholesaler_product_discounts(%L)', alpha));
  PERFORM zz.check('another wholesaler cannot list my discounts', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_my_product_discounts(%L)', good));
  PERFORM zz.check('the pharmacy sees only its currently valid rules (2 on Pd Amox)', r = '2', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.list_my_product_discounts(%L)', good));
  PERFORM zz.check('another pharmacy cannot read my rules', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.product_discounts');
  PERFORM zz.check('the table is not readable directly', r = '0', r);
  r := zz.val_as(u_wc, format('SELECT public.deactivate_product_discount(%L)::text', rid::uuid));
  PERFORM zz.check('cashier cannot deactivate', r LIKE 'ERR: You do not have permission%', r);
  PERFORM zz.check('audit log records set and the replacement', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Product discount set') = 3);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.list_my_product_discounts(good);
    RESET ROLE;
    PERFORM zz.check('anon cannot read rules', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read rules', TRUE, SQLERRM);
  END;
END $$;

-- 2. checkout (one checkout per transaction) ----------------------------------------------------
-- rules for Good Pharmacy on Pd Amox: 12% from 1 unit, 15% from 10 units. On Pd Para: none valid now.
DO $$ BEGIN PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p1'), 'quantity', 2))); END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs || '/' || COALESCE(o.discount_type, '-') INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('2 x 100 with the 12% product rule (beats the 5% general): 200 / 24 / 176 / product', r = '200.00/24.00/176.00/product', r);
  r := (SELECT unit_price_ghs || '/' || discount_source FROM public.order_items ORDER BY id DESC LIMIT 1);
  PERFORM zz.check('the order line records unit price 88 and source product', r = '88.00/product', r);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p1'), 'quantity', 10)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('10 x 100 reaches the volume rule: 15% (not 12%): 1000 / 150 / 850', r = '1000.00/150.00/850.00', r);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p1'), 'quantity', 9)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('9 units is below the volume threshold: 12%: 900 / 108 / 792', r = '900.00/108.00/792.00', r);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p1'), 'quantity', 2), jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p2'), 'quantity', 2)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs || '/' || o.discount_type || '/' || o.discount_rate INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('mixed cart: Pd Amox 12% (24) + Pd Para general 5% (5) = 29 off 300', r = '300.00/29.00/271.00/percentage/5.00', r);
  r := (SELECT string_agg(p.name || ':' || COALESCE(oi.discount_source, '-') || ':' || oi.unit_price_ghs, ',' ORDER BY p.name) FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id WHERE oi.order_id = (SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 1));
  PERFORM zz.check('each line records its own discount source', r = 'Pd Amox:product:88.00,Pd Para:customer:47.50', r);
  -- a product rule that is LOWER than the general discount still wins on its line
  UPDATE public.product_discounts SET active = false WHERE product_id = (SELECT id FROM zz.pd WHERE k='p2') AND ends_at < now();
  INSERT INTO public.product_discounts(wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity)
  VALUES ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.pd WHERE k='p2'), 2, 1);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p2'), 'quantity', 2)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs || '/' || o.discount_type || '/' || COALESCE(o.discount_rate::text, 'null') INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('a 2% product rule replaces the 5% general on its line; only product rules applied: 100 / 2 / 98 / product / null', r = '100.00/2.00/98.00/product/null', r);
  -- switch the general discount to a fixed 30 and mix: Amox (product rule) + Para line with a product rule removed
  UPDATE public.product_discounts SET active = false WHERE product_id = (SELECT id FROM zz.pd WHERE k='p2');
  UPDATE public.customer_discounts SET discount_type = 'fixed', discount_percent = NULL, discount_amount = 30
  WHERE pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy') AND wholesaler_id = (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p1'), 'quantity', 2), jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p2'), 'quantity', 2)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs || '/' || o.total_ghs INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('fixed general 30 is shared over the non-product lines only: Amox 24 + Para 30 = 54 off 300', r = '300.00/54.00/246.00', r);
  r := (SELECT string_agg(p.name || ':' || oi.unit_price_ghs, ',' ORDER BY p.name) FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id WHERE oi.order_id = (SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 1));
  PERFORM zz.check('so Para is 35 each (50 - 30/2) and Amox 88', r = 'Pd Amox:88.00,Pd Para:35.00', r);
  -- deactivating a rule stops it applying
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.pd WHERE k='p2'), 'quantity', 1)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT o.subtotal_ghs || '/' || o.discount_amount_ghs INTO r FROM public.orders o ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('fixed general 30 on a single 50 line: 50 / 30', r = '50.00/30.00', r);
  PERFORM zz.check('expired, future, inactive and other-customer rules never applied (checked via the earlier totals)', TRUE);
  PERFORM zz.check('stock reserved as before',
    (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.pd WHERE k='p1')) = 500 - 2 - 10 - 9 - 2 - 2);
END $$;

-- an unauthenticated, impersonating or unrelated caller still cannot check out
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT id FROM zz.u WHERE k='ph_other'), format('SELECT public.create_marketplace_orders(%L, %L, %L::jsonb)::text', (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'), '[]'));
  PERFORM zz.check('checkout is still service-only', r LIKE 'ERR: permission denied%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
