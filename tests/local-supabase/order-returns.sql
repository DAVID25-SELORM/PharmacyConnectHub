-- Returns management: workflow, permissions, quantities, restock, statement credit, audit log.
-- Run after setup.sql + migrations (through 20260924140000_order_returns.sql).
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
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.u WHERE k='ph_pending'), 'assistant', 'active', now());

CREATE TABLE zz.ret(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.ret TO PUBLIC;

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pa UUID := (SELECT id FROM zz.u WHERE k='ph_pending');   -- assistant on Good Pharmacy
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  p1 UUID; p2 UUID; o_del UUID; o_pend UUID; o_old UUID; oi1 UUID; oi2 UUID;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Ret Amox', 'Cat', 'TABLET', '10s', 10, 20, true) RETURNING id INTO p1;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Ret Para', 'Cat', 'TABLET', '10s', 5, 50, true) RETURNING id INTO p2;

  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, delivered_at)
  VALUES (good, alpha, 'delivered', 150, 150, 0, 'unpaid', 'cod', now() - interval '2 days') RETURNING id INTO o_del;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_del, p1, 'Ret Amox', 10, 10) RETURNING id INTO oi1;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_del, p2, 'Ret Para', 5, 10) RETURNING id INTO oi2;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
  VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_pend;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_pend, p1, 'Ret Amox', 10, 1);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, delivered_at)
  VALUES (good, alpha, 'delivered', 10, 10, 0, 'paid', 'cod', now() - interval '40 days') RETURNING id INTO o_old;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_old, p1, 'Ret Amox', 10, 1);

  INSERT INTO zz.ret VALUES ('o_del', o_del), ('o_pend', o_pend), ('o_old', o_old), ('oi1', oi1), ('oi2', oi2), ('p1', p1), ('p2', p2);
END $$;

-- 1. requesting -------------------------------------------------------------
DO $$
DECLARE
  o_del UUID := (SELECT id FROM zz.ret WHERE k='o_del'); o_pend UUID := (SELECT id FROM zz.ret WHERE k='o_pend'); o_old UUID := (SELECT id FROM zz.ret WHERE k='o_old');
  oi1 UUID := (SELECT id FROM zz.ret WHERE k='oi1'); oi2 UUID := (SELECT id FROM zz.ret WHERE k='oi2');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pa UUID := (SELECT id FROM zz.u WHERE k='ph_pending'); u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  r TEXT;
BEGIN
  r := zz.val_as(u_po, format('SELECT public.get_returnable_items(%L)::text', o_del));
  PERFORM zz.check('returnable items readable by the pharmacy owner', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', ''Box crushed'', %L::jsonb)::text', o_pend, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('pending order cannot be returned', r LIKE 'ERR: Only delivered%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_old, jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = o_old), 'quantity', 1))::text));
  PERFORM zz.check('delivered 40 days ago is outside the 30-day window', r LIKE 'ERR: The 30-day%', r);
  r := zz.val_as(u_px, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('another pharmacy cannot request', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wo, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('the wholesaler cannot request a return for the pharmacy', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_pa, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('pharmacy assistant cannot request', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''bogus'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('invalid reason rejected', r LIKE 'ERR: Choose a return reason%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 11))::text));
  PERFORM zz.check('cannot return more than was ordered', r LIKE 'ERR: Only 10 unit(s)%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, '[]'));
  PERFORM zz.check('empty request rejected', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', gen_random_uuid(), 'quantity', 1))::text));
  PERFORM zz.check('a line from another order is rejected', r LIKE 'ERR: One of the lines%', r);

  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', ''Box crushed'', %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 4), jsonb_build_object('order_item_id', oi2, 'quantity', 2))::text));
  PERFORM zz.check('valid request succeeds', r NOT LIKE 'ERR%', r);
  INSERT INTO zz.ret VALUES ('r1', r::uuid);
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 7))::text));
  PERFORM zz.check('open request reserves quantity: 7 more of 6 remaining rejected', r LIKE 'ERR: Only 6 unit(s)%', r);
  PERFORM zz.check('the failed request left no return row behind', (SELECT count(*) FROM public.order_returns) = 1);
END $$;

-- 2. visibility and direct table access --------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale'); otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  r TEXT;
BEGIN
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.list_order_returns(%L)', alpha));
  PERFORM zz.check('wholesaler owner lists 1 return', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT counterparty_name FROM public.list_order_returns(%L)', alpha));
  PERFORM zz.check('wholesaler sees the pharmacy as counterparty', r = 'Good Pharmacy', r);
  r := zz.val_as(u_po, format('SELECT counterparty_name FROM public.list_order_returns(%L)', good));
  PERFORM zz.check('pharmacy sees the wholesaler as counterparty', r = 'Alpha Wholesale', r);
  r := zz.val_as(u_wa, format('SELECT count(*)::text FROM public.list_order_returns(%L)', alpha));
  PERFORM zz.check('wholesaler assistant can read the list', r = '1', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.list_order_returns(%L)', alpha));
  PERFORM zz.check('another wholesaler cannot list my returns', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.list_order_returns(%L)', other_w));
  PERFORM zz.check('another wholesaler sees none of mine in their own list', r = '0', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.list_order_returns(%L)', good));
  PERFORM zz.check('another pharmacy cannot list my returns', r LIKE 'ERR%', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.list_order_returns(%L)', otherp));
  PERFORM zz.check('another pharmacy lists only its own (none)', r = '0', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.order_returns');
  PERFORM zz.check('direct table read is hidden by RLS', r = '0', r);
  r := zz.val_as(u_po, format('UPDATE public.order_returns SET status = ''resolved''', NULL));
  PERFORM zz.check('direct table update is denied', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('INSERT INTO public.order_returns(order_id, pharmacy_id, wholesaler_id, reason) VALUES (gen_random_uuid(), %L, %L, ''damaged'')', good, alpha));
  PERFORM zz.check('direct table insert is denied', r LIKE 'ERR%', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.list_order_returns(alpha);
    RESET ROLE;
    PERFORM zz.check('anon cannot list returns', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot list returns', TRUE, SQLERRM);
  END;
END $$;

-- 3. workflow ----------------------------------------------------------------
DO $$
DECLARE
  r1 UUID := (SELECT id FROM zz.ret WHERE k='r1'); p1 UUID := (SELECT id FROM zz.ret WHERE k='p1'); p2 UUID := (SELECT id FROM zz.ret WHERE k='p2');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  it1 UUID; it2 UUID; r TEXT;
BEGIN
  SELECT id INTO it1 FROM public.order_return_items WHERE return_id = r1 AND product_name = 'Ret Amox';
  SELECT id INTO it2 FROM public.order_return_items WHERE return_id = r1 AND product_name = 'Ret Para';

  r := zz.val_as(u_wa, format('SELECT public.review_order_return(%L, true, NULL)::text', r1));
  PERFORM zz.check('wholesaler assistant cannot approve', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wx, format('SELECT public.review_order_return(%L, true, NULL)::text', r1));
  PERFORM zz.check('another wholesaler cannot approve', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.review_order_return(%L, true, NULL)::text', r1));
  PERFORM zz.check('the pharmacy cannot approve its own return', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wc, format('SELECT public.mark_order_return_returned(%L)::text', r1));
  PERFORM zz.check('cannot skip approval', r LIKE 'ERR: This return is requested%', r);
  r := zz.val_as(u_wc, format('SELECT public.review_order_return(%L, false, '''')::text', r1));
  PERFORM zz.check('rejecting needs a reason', r LIKE 'ERR: Give the pharmacy a reason%', r);
  r := zz.val_as(u_wc, format('SELECT public.review_order_return(%L, true, ''OK, send it back'')::text', r1));
  PERFORM zz.check('cashier can approve', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT public.cancel_order_return(%L)::text', r1));
  PERFORM zz.check('cannot cancel after approval', r LIKE 'ERR: Only a return that has not been reviewed%', r);
  r := zz.val_as(u_wc, format('SELECT public.review_order_return(%L, true, NULL)::text', r1));
  PERFORM zz.check('cannot approve twice', r LIKE 'ERR: This return is approved%', r);
  r := zz.val_as(u_wm, format('SELECT public.inspect_order_return(%L, ''[]'')::text', r1));
  PERFORM zz.check('cannot inspect before the goods are received', r LIKE 'ERR: This return is approved%', r);
  r := zz.val_as(u_wc, format('SELECT public.mark_order_return_returned(%L)::text', r1));
  PERFORM zz.check('cashier can mark received', r NOT LIKE 'ERR%', r);

  r := zz.val_as(u_wc, format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', r1, jsonb_build_array(jsonb_build_object('return_item_id', it1, 'quantity_accepted', 3, 'restock', true), jsonb_build_object('return_item_id', it2, 'quantity_accepted', 0, 'restock', false))::text));
  PERFORM zz.check('cashier cannot inspect (manager/owner only)', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wm, format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', r1, jsonb_build_array(jsonb_build_object('return_item_id', it1, 'quantity_accepted', 5, 'restock', true), jsonb_build_object('return_item_id', it2, 'quantity_accepted', 0, 'restock', false))::text));
  PERFORM zz.check('accepted above requested rejected', r LIKE 'ERR: Accepted quantity%', r);
  r := zz.val_as(u_wm, format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', r1, jsonb_build_array(jsonb_build_object('return_item_id', it1, 'quantity_accepted', 3, 'restock', true))::text));
  PERFORM zz.check('every line must be inspected', r LIKE 'ERR: Record the inspection result%', r);
  r := zz.val_as(u_wm, format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', r1, jsonb_build_array(jsonb_build_object('return_item_id', it1, 'quantity_accepted', 3, 'restock', true), jsonb_build_object('return_item_id', it2, 'quantity_accepted', 0, 'restock', true))::text));
  PERFORM zz.check('manager can inspect: 3 of 4 amox accepted and restockable, para refused', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('a refused line is never restockable', (SELECT NOT restock FROM public.order_return_items WHERE id = it2));

  r := zz.val_as(u_wc, format('SELECT public.resolve_order_return(%L, ''credit'', NULL)::text', r1));
  PERFORM zz.check('cashier cannot resolve', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wm, format('SELECT public.resolve_order_return(%L, ''none'', NULL)::text', r1));
  PERFORM zz.check('accepted units cannot be resolved as "none"', r LIKE 'ERR: Accepted units need%', r);
  r := zz.val_as(u_wm, format('SELECT public.resolve_order_return(%L, ''bogus'', NULL)::text', r1));
  PERFORM zz.check('unknown resolution rejected', r LIKE 'ERR: Choose how%', r);
  PERFORM zz.check('stock untouched before resolution', (SELECT stock FROM public.products WHERE id = p1) = 20);
  r := zz.val_as(u_wm, format('SELECT public.resolve_order_return(%L, ''credit'', ''Credited to your account'')::text', r1));
  PERFORM zz.check('manager resolves as credit; amount = 3 x 10 = 30', r = '30.00', r);
  PERFORM zz.check('inventory: 3 restockable units added back (20 -> 23)', (SELECT stock FROM public.products WHERE id = p1) = 23);
  PERFORM zz.check('inventory: refused para line not restocked (50)', (SELECT stock FROM public.products WHERE id = p2) = 50);
  r := zz.val_as(u_wm, format('SELECT public.resolve_order_return(%L, ''credit'', NULL)::text', r1));
  PERFORM zz.check('cannot resolve twice (no double restock)', r LIKE 'ERR: This return is resolved%', r);
  PERFORM zz.check('stock still 23 after the rejected second resolve', (SELECT stock FROM public.products WHERE id = p1) = 23);
END $$;

-- 4. customer balance, audit log, reject / cancel paths -------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  o_del UUID := (SELECT id FROM zz.ret WHERE k='o_del'); oi1 UUID := (SELECT id FROM zz.ret WHERE k='oi1');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  r TEXT; r2 TEXT; r3 TEXT;
BEGIN
  -- order 150 unpaid = debit 150; credit return 30 => closing 120
  r := zz.val_as(u_wo, format('SELECT (s->>''total_debits'') || ''/'' || (s->>''total_credits'') || ''/'' || (s->>''closing_balance'') FROM (SELECT public.customer_statement(%L, %L, now() - interval ''30 days'', now() + interval ''1 day'') s) q', alpha, good));
  PERFORM zz.check('statement: charges 170, credits 40 (10 payment + 30 return), closing 130', r = '170.00/40.00/130.00', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM (SELECT jsonb_array_elements(public.customer_statement(%L, %L, now() - interval ''60 days'', now() + interval ''1 day'')->''lines'') l) q WHERE l->>''kind'' = ''return'' AND (l->>''credit'')::numeric = 30', alpha, good));
  PERFORM zz.check('statement shows the return as a 30.00 credit line', r = '1', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM (SELECT jsonb_array_elements(public.customer_statement(%L, %L, now() - interval ''60 days'', now() + interval ''1 day'')->''lines'') l) q WHERE l->>''kind'' = ''return''', alpha, good));
  PERFORM zz.check('the pharmacy sees the same return credit line', r = '1', r);

  PERFORM zz.check('audit log has requested/approved/received/inspected/resolved',
    (SELECT count(DISTINCT activity) FROM public.audit_logs WHERE record_type = 'order_return' AND activity IN ('Return requested', 'Return approved', 'Return received', 'Return inspected', 'Return resolved')) = 5);

  -- reject path and cancel path
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''wrong_quantity'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 1))::text));
  PERFORM zz.check('a second request for the remaining units works (10-3 accepted=7 left)', r NOT LIKE 'ERR%', r);
  r2 := zz.val_as(u_po, format('SELECT public.cancel_order_return(%L)::text', r::uuid));
  PERFORM zz.check('pharmacy can cancel an unreviewed request', r2 NOT LIKE 'ERR%', r2);
  PERFORM zz.check('cancelled returns free the quantity again', zz.val_as(u_po, format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''Ret Amox''', o_del)) = '7');
  r := zz.val_as(u_po, format('SELECT public.request_order_return(%L, ''quality_issue'', NULL, %L::jsonb)::text', o_del, jsonb_build_array(jsonb_build_object('order_item_id', oi1, 'quantity', 2))::text));
  r2 := zz.val_as(u_wo, format('SELECT public.review_order_return(%L, false, ''Not our product'')::text', r::uuid));
  PERFORM zz.check('owner can reject with a reason', r2 NOT LIKE 'ERR%', r2);
  PERFORM zz.check('rejected returns free the quantity again', zz.val_as(u_po, format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''Ret Amox''', o_del)) = '7');
  r3 := zz.val_as((SELECT id FROM zz.u WHERE k='ph_other'), format('SELECT count(*)::text FROM public.statement_return_credits(%L, %L)', alpha, good));
  PERFORM zz.check('an outsider cannot read return credits directly', r3 LIKE 'ERR%', r3);
  PERFORM zz.check('the pharmacy can read the rejection reason',
    zz.val_as(u_po, format('SELECT wholesaler_note FROM public.list_order_returns(%L) WHERE id = %L', good, r::uuid)) = 'Not our product');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
