-- Notifications centre: recipients by role, actor exclusion, tamper protection, failure isolation.
-- Run after setup.sql + migrations (through 20260924160000_notifications_centre.sql).
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

-- who got a notification of a type (comma-separated user keys)
CREATE FUNCTION zz.who(p_type TEXT, p_since TIMESTAMPTZ) RETURNS TEXT LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(u.k, ',' ORDER BY u.k), '-')
  FROM public.notifications n JOIN zz.u u ON u.id = n.user_id
  WHERE n.type = p_type AND n.created_at >= p_since
$$;

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO zz.u VALUES ('w_assist', '10000000-0000-0000-0000-0000000000a1');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.u WHERE k='ph_other'), 'cashier', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.u WHERE k='ph_pending'), 'assistant', 'active', now());
DELETE FROM public.notifications;

CREATE TABLE zz.ctx(k TEXT PRIMARY KEY, id UUID, ts TIMESTAMPTZ);
GRANT ALL ON zz.ctx TO PUBLIC;

-- 1. orders ------------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  t0 TIMESTAMPTZ := now(); o UUID; o2 UUID; p UUID; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Nt Amox', 'Cat', 'TABLET', '10s', 10, 5, true) RETURNING id INTO p;
  DELETE FROM public.notifications;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
  VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o, p, 'Nt Amox', 10, 1);
  INSERT INTO zz.ctx VALUES ('o', o, t0), ('p', p, t0);

  PERFORM zz.check('new order: owner, manager and cashier are notified, the assistant is not',
    zz.who('new_order', t0) = 'w_cashier,w_manager,w_owner', zz.who('new_order', t0));
  PERFORM zz.check('new order notification links to the orders tab',
    (SELECT count(*) FROM public.notifications WHERE type = 'new_order' AND link = '/wholesaler?tab=orders') = 3);
  PERFORM zz.check('another wholesaler receives nothing', (SELECT count(*) FROM public.notifications n JOIN zz.u u ON u.id = n.user_id WHERE u.k IN ('w_other', 'ph_other') AND n.type = 'new_order') = 0);

  UPDATE public.orders SET status = 'accepted' WHERE id = o;
  PERFORM zz.check('status change: pharmacy owner and cashier are notified, the pharmacy assistant is not',
    zz.who('order_status', t0) = 'ph_other,ph_owner', zz.who('order_status', t0));

  UPDATE public.orders SET payment_status = 'paid' WHERE id = o;
  PERFORM zz.check('COD payment confirmed: pharmacy team only', zz.who('payment_update', t0) = 'ph_other,ph_owner', zz.who('payment_update', t0));
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
  VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'paystack') RETURNING id INTO o2;
  DELETE FROM public.notifications WHERE type = 'payment_update';
  UPDATE public.orders SET payment_status = 'paid' WHERE id = o2;
  PERFORM zz.check('online payment: the wholesaler team is notified too',
    zz.who('payment_update', t0) = 'ph_other,ph_owner,w_cashier,w_manager,w_owner', zz.who('payment_update', t0));
  UPDATE public.orders SET payment_status = 'failed' WHERE id = o2;
  PERFORM zz.check('failed payment notifies the pharmacy', (SELECT count(*) FROM public.notifications WHERE title = 'Payment failed') = 2);
END $$;

-- 2. returns -------------------------------------------------------------------
DO $$
DECLARE
  o UUID := (SELECT id FROM zz.ctx WHERE k='o'); t0 TIMESTAMPTZ := (SELECT ts FROM zz.ctx WHERE k='o');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  oi UUID; ret TEXT; r TEXT;
BEGIN
  UPDATE public.orders SET status = 'delivered', delivered_at = now() WHERE id = o;
  SELECT id INTO oi FROM public.order_items WHERE order_id = o;
  ret := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o, jsonb_build_array(jsonb_build_object('order_item_id', oi, 'quantity', 1))::text));
  INSERT INTO zz.ctx VALUES ('ret', ret::uuid, now());
  PERFORM zz.check('return requested: wholesaler team notified, requester not', zz.who('return_requested', t0) = 'w_cashier,w_manager,w_owner', zz.who('return_requested', t0));
  r := zz.val_as(u_wc, format('SELECT public.review_order_return(%L, true, NULL)::text', ret::uuid));
  PERFORM zz.check('return approved: pharmacy team notified, the approver is not a recipient of it',
    zz.who('return_update', t0) = 'ph_other,ph_owner', zz.who('return_update', t0));
  PERFORM zz.check('return notification links to the returns tab', (SELECT count(*) FROM public.notifications WHERE type = 'return_update' AND link = '/pharmacy?tab=returns') = 2);
END $$;

-- 3. delivery ---------------------------------------------------------------------
DO $$
DECLARE
  o UUID := (SELECT id FROM zz.ctx WHERE k='o'); t0 TIMESTAMPTZ := (SELECT ts FROM zz.ctx WHERE k='o');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); r TEXT;
BEGIN
  UPDATE public.orders SET status = 'dispatched', created_at = now() - interval '4 hours' WHERE id = o;
  DELETE FROM public.notifications WHERE type = 'delivery_update';
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Ama Rider'', ''0245550202'', ''DEL-1'', NULL)::text', o));
  PERFORM zz.check('delivery details: pharmacy team notified', zz.who('delivery_update', t0) = 'ph_other,ph_owner', zz.who('delivery_update', t0) || ' / ' || r);
  DELETE FROM public.notifications WHERE type = 'delivery_update';
  r := zz.val_as(u_wo, format('SELECT public.record_order_proof_of_delivery(%L, ''John Mensah'', now() - interval ''10 minutes'', NULL)::text', o));
  PERFORM zz.check('proof of delivery: "Delivery confirmed" with the receiver''s name',
    (SELECT count(*) FROM public.notifications WHERE title = 'Delivery confirmed' AND body LIKE '%John Mensah%') = 2, r);
  DELETE FROM public.notifications WHERE type = 'delivery_update';
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Ama Rider'', ''0245550202'', ''DEL-1'', NULL)::text', o));
  PERFORM zz.check('saving identical details again sends no duplicate notification', (SELECT count(*) FROM public.notifications WHERE type = 'delivery_update') = 0);
END $$;

-- 4. out of stock / verification -----------------------------------------------------
DO $$
DECLARE
  p UUID := (SELECT id FROM zz.ctx WHERE k='p'); t0 TIMESTAMPTZ := (SELECT ts FROM zz.ctx WHERE k='o');
BEGIN
  UPDATE public.products SET stock = 3 WHERE id = p;
  PERFORM zz.check('stock reduced but still positive: no alert', zz.who('low_stock', t0) = '-');
  UPDATE public.products SET stock = 0 WHERE id = p;
  PERFORM zz.check('out of stock: owner and manager only', zz.who('low_stock', t0) = 'w_manager,w_owner', zz.who('low_stock', t0));
  UPDATE public.products SET stock = 0 WHERE id = p;
  PERFORM zz.check('staying at zero does not alert again', (SELECT count(*) FROM public.notifications WHERE type = 'low_stock') = 2);
END $$;

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000b1', 'fresh@zz.test', zz.biz_meta('pharmacy', 'Fresh Pharmacy', 'P-9', 'Fresh Owner', '+233241000099'));

DO $$
DECLARE t0 TIMESTAMPTZ := (SELECT ts FROM zz.ctx WHERE k='o');
BEGIN
  PERFORM zz.check('a new business awaiting verification notifies the admin', zz.who('verification_pending', t0) = 'admin', zz.who('verification_pending', t0));
  PERFORM zz.check('admin notification links to /admin', (SELECT link FROM public.notifications WHERE type = 'verification_pending' LIMIT 1) = '/admin');
END $$;

-- 5. tamper protection and isolation ---------------------------------------------------
DO $$
DECLARE
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  nid UUID; r TEXT;
BEGIN
  SELECT id INTO nid FROM public.notifications WHERE user_id = u_wo LIMIT 1;
  r := zz.val_as(u_wo, format('UPDATE public.notifications SET title = ''hacked'' WHERE id = %L', nid));
  PERFORM zz.check('users cannot edit a notification''s title', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('UPDATE public.notifications SET user_id = %L WHERE id = %L', u_wx, nid));
  PERFORM zz.check('users cannot reassign a notification', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('WITH u AS (UPDATE public.notifications SET read = true WHERE id = %L RETURNING 1) SELECT count(*)::text FROM u', nid));
  PERFORM zz.check('users can mark their own notification read', r = '1', r);
  PERFORM zz.check('the read flag actually changed', (SELECT read FROM public.notifications WHERE id = nid));
  r := zz.val_as(u_wx, format('WITH u AS (UPDATE public.notifications SET read = true WHERE user_id = %L RETURNING 1) SELECT count(*)::text FROM u', u_wo));
  PERFORM zz.check('another user cannot mark my notifications read', r = '0', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.notifications WHERE user_id = %L', u_wo));
  PERFORM zz.check('another user cannot read my notifications', r = '0', r);
  r := zz.val_as(u_wo, format('INSERT INTO public.notifications(user_id, type, title, body) VALUES (%L, ''x'', ''fake'', ''fake'')', u_wo));
  PERFORM zz.check('users cannot create notifications', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('DELETE FROM public.notifications WHERE user_id = %L', u_wo));
  PERFORM zz.check('users cannot delete notifications', r LIKE 'ERR%' OR (SELECT count(*) FROM public.notifications WHERE user_id = u_wo) > 0, r);
  BEGIN
    INSERT INTO public.notifications(user_id, type, title, body, link) VALUES (u_wo, 'x', 't', 'b', 'http://evil.example');
    PERFORM zz.check('external links are rejected by the database', FALSE);
  EXCEPTION WHEN check_violation THEN
    PERFORM zz.check('external links are rejected by the database', TRUE);
  END;
  BEGIN
    INSERT INTO public.notifications(user_id, type, title, body, link) VALUES (u_wo, 'x', 't', 'b', '//evil.example');
    PERFORM zz.check('protocol-relative links are rejected', FALSE);
  EXCEPTION WHEN check_violation THEN
    PERFORM zz.check('protocol-relative links are rejected', TRUE);
  END;
  PERFORM zz.check('the other wholesaler never received any notification',
    (SELECT count(*) FROM public.notifications WHERE user_id = u_wx) = 0);
END $$;

-- 6. a failing notification must never block the business action ------------------------
ALTER TABLE public.notifications ADD CONSTRAINT zz_block CHECK (false) NOT VALID;
DO $$
DECLARE alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy'); n INT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
  VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'cod');
  UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 1);
  PERFORM zz.check('orders can still be placed and updated while notifications are failing', TRUE);
END $$;
ALTER TABLE public.notifications DROP CONSTRAINT zz_block;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
