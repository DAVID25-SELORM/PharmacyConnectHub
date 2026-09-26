-- Order terms: minimum order value + delivery fee (+ free-delivery threshold) in checkout.
-- Run after setup.sql + migrations (through 20260924200000_order_terms_min_value_delivery_fee.sql).
-- setup.sql gives Good Pharmacy a 5% customer discount with Alpha Wholesale (no minimum).
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

CREATE TABLE zz.tp(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.tp TO PUBLIC;

-- 1. setting terms, listing, validation ----------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  pendw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other'); u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  u_pw UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  pa UUID; pb UUID; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Tm Amox', 'Cat', 'TABLET', '10s', 100, 200, true) RETURNING id INTO pa;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (other_w, 'Tm Other', 'Cat', 'TABLET', '10s', 50, 100, true) RETURNING id INTO pb;
  INSERT INTO zz.tp VALUES ('pa', pa), ('pb', pb);

  r := zz.val_as(u_wc, format('SELECT public.set_order_terms(%L, 300, 20, 1000)::text', alpha));
  PERFORM zz.check('cashier cannot set terms', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wa, format('SELECT public.set_order_terms(%L, 300, 20, 1000)::text', alpha));
  PERFORM zz.check('assistant cannot set terms', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wx, format('SELECT public.set_order_terms(%L, 300, 20, 1000)::text', alpha));
  PERFORM zz.check('another wholesaler cannot set my terms', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.set_order_terms(%L, 300, 20, 1000)::text', good));
  PERFORM zz.check('a pharmacy cannot set terms', r LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, -1, 20, NULL)::text', alpha));
  PERFORM zz.check('negative minimum rejected', r LIKE 'ERR: The minimum order must be%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, 0, -5, NULL)::text', alpha));
  PERFORM zz.check('negative fee rejected', r LIKE 'ERR: The delivery fee must be%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, 0, 0, 500)::text', alpha));
  PERFORM zz.check('free-delivery amount without a fee rejected', r LIKE 'ERR: Set a delivery fee before%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, 300, 20, 100)::text', alpha));
  PERFORM zz.check('free-delivery amount below the minimum rejected', r LIKE 'ERR: The free-delivery amount cannot be lower%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, 300, 20, 0)::text', alpha));
  PERFORM zz.check('free-delivery amount of zero rejected', r LIKE 'ERR: The free-delivery amount must be above zero%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_order_terms(%L, 300, 20, 1000)::text', alpha));
  PERFORM zz.check('manager sets minimum 300, fee 20, free from 1000', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_pw, format('SELECT public.set_order_terms(%L, 100, 5, NULL)::text', pendw));
  PERFORM zz.check('an unapproved wholesaler can save terms', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit log records the change', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Order terms updated') = 2);

  r := zz.val_as(u_po, 'SELECT min_order_value_ghs || ''/'' || delivery_fee_ghs || ''/'' || free_delivery_threshold_ghs FROM public.list_order_terms()');
  PERFORM zz.check('a pharmacy can read approved wholesalers'' terms', r = '300.00/20.00/1000.00', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_order_terms(ARRAY[%L]::uuid[])', other_w));
  PERFORM zz.check('a wholesaler without terms returns no row', r = '0', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.list_order_terms()');
  PERFORM zz.check('unapproved wholesalers'' terms are hidden', r = '1', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.wholesaler_order_terms');
  PERFORM zz.check('the table itself is not readable directly', r = '0', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.list_order_terms();
    RESET ROLE;
    PERFORM zz.check('anon cannot read terms', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read terms', TRUE, SQLERRM);
  END;
END $$;

-- 2. checkout: each call is its own transaction ----------------------------------------------
DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 3)));
  PERFORM zz.check('3 units (300, 285 after the 5% discount) is below the 300 minimum', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('minimum is measured after discounts: 3 units = 285 < 300, rejected with a clear message',
    SQLERRM = 'Alpha Wholesale requires a minimum order of GHS 300.00 (your order with them is GHS 285.00).', SQLERRM);
END $$;

DO $$ BEGIN
  PERFORM zz.check('the rejected checkout reserved no stock and created no order',
    (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.tp WHERE k='pa')) = 200 AND (SELECT count(*) FROM public.orders) = 0);
  PERFORM zz.check('4 units (400, 380 net) passes and pays the delivery fee',
    public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 4))) = 1);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT subtotal_ghs || '/' || discount_amount_ghs || '/' || delivery_fee_ghs || '/' || total_ghs INTO r FROM public.orders ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('order: subtotal 400, discount 20, delivery 20, total 400 (380 goods + 20)', r = '400.00/20.00/20.00/400.00', r);
  PERFORM zz.check('stock reserved for the accepted order', (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.tp WHERE k='pa')) = 196);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 10)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT subtotal_ghs || '/' || discount_amount_ghs || '/' || delivery_fee_ghs || '/' || total_ghs INTO r FROM public.orders ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('10 units: 1000 gross but 950 net is below the 1000 free-delivery amount, so the fee applies (total 970)', r = '1000.00/50.00/20.00/970.00', r);
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 11)));
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT subtotal_ghs || '/' || discount_amount_ghs || '/' || delivery_fee_ghs || '/' || total_ghs INTO r FROM public.orders ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('11 units: 1045 net reaches the free-delivery amount, no fee (total 1045)', r = '1100.00/55.00/0.00/1045.00', r);
END $$;

-- a multi-wholesaler cart where one group is below its minimum fails as a whole
DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 1),
                      jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pb'), 'quantity', 5)));
  PERFORM zz.check('a cart with one wholesaler below its minimum is rejected', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('a cart with one wholesaler below its minimum is rejected as a whole', SQLERRM LIKE 'Alpha Wholesale requires a minimum order%', SQLERRM);
END $$;

DO $$
DECLARE before_orders BIGINT;
BEGIN
  PERFORM zz.check('the other wholesaler''s stock was not reserved by the failed cart', (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.tp WHERE k='pb')) = 100);
  PERFORM zz.check('a wholesaler without terms has no minimum or fee',
    public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pb'), 'quantity', 1))) = 1);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT delivery_fee_ghs || '/' || total_ghs INTO r FROM public.orders WHERE wholesaler_id = (SELECT id FROM zz.b WHERE name='Other Wholesale');
  PERFORM zz.check('that order has fee 0 and total 47 (the seeded 6% discount)', r = '0.00/47.00', r);
  UPDATE public.wholesaler_order_terms SET min_order_value_ghs = 0, delivery_fee_ghs = 0, free_delivery_threshold_ghs = NULL WHERE wholesaler_id = (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
END $$;

DO $$ BEGIN
  PERFORM zz.check('with terms cleared a single unit is accepted again',
    public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.tp WHERE k='pa'), 'quantity', 1))) = 1);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  SELECT delivery_fee_ghs || '/' || total_ghs INTO r FROM public.orders WHERE wholesaler_id = (SELECT id FROM zz.b WHERE name='Alpha Wholesale') ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('and it has no fee (95 after the discount)', r = '0.00/95.00', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT (s->>''total_debits'') FROM (SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'') s) q', (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy')));
  PERFORM zz.check('the customer statement charges the fee-inclusive totals: 400 + 970 + 1045 + 95', r::numeric = 2510, r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
