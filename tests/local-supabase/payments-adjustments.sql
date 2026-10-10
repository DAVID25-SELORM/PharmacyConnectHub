-- Online payments (Pay Now), P4b: amendments on an order that was PAID ONLINE (a refund of what the order no longer costs, a top-up for what it now costs more, back-orders refused,
-- the dispatch block, the extra payment itself). Run after setup.sql + migrations (through 20261110120000_payments_adjustments_patches.sql), with the production guard and stock fixtures
-- installed and the checkout compatibility migration (20261017110000) re-applied. Successful create_marketplace_orders calls are top-level statements.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
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
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;
CREATE FUNCTION zz.j(p_uid UUID, p_sql TEXT) RETURNS JSONB LANGUAGE sql AS $$ SELECT NULLIF(zz.val_as(p_uid, p_sql), '')::jsonb $$;

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c1', 'ww@zz.test', '{"full_name":"Alpha Warehouse","phone":"+233241000051"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c2', 'wf@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000052"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c3', 'pc@zz.test', '{"full_name":"Good Cashier","phone":"+233241000053"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c4', 'pa@zz.test', '{"full_name":"Good Assistant","phone":"+233241000054"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = v.biz), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000c1'::uuid, 'warehouse'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000c2'::uuid, 'finance'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000c3'::uuid, 'cashier'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000c4'::uuid, 'assistant')) v(biz, uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT b.id, v.n, 'Generic', 'Analgesic', 'TABLET', '100s', v.p, v.s, true
FROM zz.b b, (VALUES ('BO A', 100, 1000), ('BO B', 50, 500), ('BO C', 20, 400)) v(n, p, s) WHERE b.name = 'Alpha Wholesale';
CREATE TABLE zz.bo AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  '30000000-0000-0000-0000-0000000000c1'::uuid u_ww,
  '30000000-0000-0000-0000-0000000000c2'::uuid u_wf,
  '30000000-0000-0000-0000-0000000000c3'::uuid u_pc,
  '30000000-0000-0000-0000-0000000000c4'::uuid u_pa,
  (SELECT id FROM public.products WHERE name='BO A') pa,
  (SELECT id FROM public.products WHERE name='BO B') pb,
  (SELECT id FROM public.products WHERE name='BO C') pcc;
CREATE TABLE zz.bo_orders(label TEXT PRIMARY KEY, order_id UUID);
CREATE FUNCTION zz.ord(p_label TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT order_id FROM zz.bo_orders WHERE label = p_label $$;
CREATE FUNCTION zz.item(p_order UUID, p_name TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT id FROM public.order_items WHERE order_id = p_order AND product_name = p_name $$;
CREATE FUNCTION zz.stock(p_name TEXT) RETURNS INTEGER LANGUAGE sql AS $$ SELECT stock FROM public.products WHERE name = p_name $$;
CREATE FUNCTION zz.line(p_order UUID, p_name TEXT, p_qty INT, p_treat TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'supplied_qty', p_qty, 'stock_treatment', p_treat) $$;
CREATE FUNCTION zz.sl(p_order UUID, p_name TEXT, p_qty INT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'quantity', p_qty) $$;
-- Propose (as the wholesaler owner) and accept with a choice (as the pharmacy owner); returns the amendment id.
CREATE FUNCTION zz.amend(p_order UUID, p_lines JSONB, p_choice TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short'', %L::jsonb, gen_random_uuid())::text', p_order, p_lines::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  IF a IS NULL THEN RAISE EXCEPTION 'propose failed: %', r; END IF;
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.respond_to_amendment(%L, %L, NULL)::text', a, p_choice));
  IF r LIKE 'ERR%' THEN RAISE EXCEPTION 'respond failed: %', r; END IF;
  RETURN a;
END $$;
CREATE FUNCTION zz.go(p_order UUID, p_to TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE s TEXT;
BEGIN
  FOREACH s IN ARRAY (CASE p_to WHEN 'dispatched' THEN ARRAY['picking','packed','ready_for_dispatch','dispatched']
                                WHEN 'delivered' THEN ARRAY['picking','packed','ready_for_dispatch','dispatched','delivered'] ELSE ARRAY['picking'] END) LOOP
    EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', s, p_order);
  END LOOP;
END $$;

SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.bo), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.bo)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.bo;



CREATE TABLE zz.mem(k TEXT PRIMARY KEY, v TEXT);
CREATE FUNCTION zz.svc(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
CREATE FUNCTION zz.apply(p_ref TEXT, p_status TEXT, p_minor BIGINT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_payment_result(''paystack'', ''test'', %L, %L, %s, ''GHS'', ''tx-1'', ''card'', 50, ''reconcile'')::text', p_ref, p_status, p_minor))::jsonb $$;
CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
  SELECT p_order, 'paystack', 'test', p_ref, o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  RETURN v_id;
END $$;
-- The order is paid in full (GHS 1000.00 = 100000 pesewas) and accepted by the wholesaler: now it can be amended.
CREATE FUNCTION zz.paid_accepted(p_order UUID, p_ref TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID := zz.att(p_order, p_ref);
BEGIN
  PERFORM zz.apply(p_ref, 'success', 100000);
  UPDATE public.orders SET status = 'accepted' WHERE id = p_order;
  RETURN v_id;
END $$;
CREATE FUNCTION zz.ostat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT status::text || '/' || payment_status::text FROM public.orders WHERE id = p_order $$;
CREATE FUNCTION zz.eff(p_order UUID) RETURNS NUMERIC LANGUAGE sql AS $$ SELECT COALESCE(effective_total_ghs, total_ghs) FROM public.orders WHERE id = p_order $$;
CREATE FUNCTION zz.bal(p_order UUID) RETURNS BIGINT LANGUAGE sql AS $$ SELECT (public.order_money(p_order) ->> 'balance_minor')::BIGINT $$;
CREATE FUNCTION zz.due(p_order UUID) RETURNS BIGINT LANGUAGE sql AS $$ SELECT public.order_topup_due_minor(p_order) $$;
CREATE FUNCTION zz.rstat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$
  SELECT string_agg(r.status || '/' || r.amount_minor || '/' || r.reason, ',' ORDER BY r.created_at, r.amount_minor) FROM public.order_refunds r WHERE r.order_id = p_order $$;
CREATE FUNCTION zz.alerts(p_kind TEXT, p_order UUID DEFAULT NULL) RETURNS INT LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.payment_alerts WHERE kind = p_kind AND status = 'open' AND (p_order IS NULL OR order_id = p_order) $$;
CREATE FUNCTION zz.adm(p_refund UUID, p_action TEXT, p_note TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.admin_refund_transition(%L, %L, %L, %L)::text', (SELECT u_admin FROM zz.bo), p_refund, p_action, p_note)) $$;
CREATE FUNCTION zz.topup(p_order UUID, p_ref TEXT, p_caller UUID DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.begin_order_topup(%L, %L, ''paystack'', ''test'', %L)::text', COALESCE(p_caller, (SELECT u_po FROM zz.bo)), p_order, p_ref)) $$;
-- Price and delivery-report helpers (as in the price-change and delivery suites).
CREATE FUNCTION zz.pl(p_order UUID, p_name TEXT, p_price NUMERIC) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'unit_price_ghs', p_price) $$;
CREATE FUNCTION zz.pp(p_uid UUID, p_order UUID, p_lines JSONB, p_reason TEXT DEFAULT 'Supplier price revised') RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.propose_price_amendment(%L, %L, %L::jsonb, gen_random_uuid())::text', p_order, p_reason, p_lines::text)) $$;
CREATE FUNCTION zz.pr(p_uid UUID, p_amendment UUID, p_choice TEXT, p_note TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.respond_to_price_amendment(%L, %L, %L)::text', p_amendment, p_choice, p_note)) $$;
CREATE FUNCTION zz.aid(p_order UUID, p_version INT) RETURNS UUID LANGUAGE sql AS $$ SELECT id FROM public.order_amendments WHERE order_id = p_order AND version = p_version $$;
-- Raise the price of BO A on an order: propose as the wholesaler, accept as the pharmacy.
CREATE FUNCTION zz.reprice(p_order UUID, p_price NUMERIC, p_version INT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), p_order, jsonb_build_array(zz.pl(p_order, 'BO A', p_price)));
  IF r LIKE 'ERR%' THEN RETURN r; END IF;
  RETURN zz.pr((SELECT u_po FROM zz.bo), zz.aid(p_order, p_version), 'accept');
END $$;

UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', auto_refunds = FALSE;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a1_
INSERT INTO zz.bo_orders SELECT 'A1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a2_
INSERT INTO zz.bo_orders SELECT 'A2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a3_
INSERT INTO zz.bo_orders SELECT 'A3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a4_
INSERT INTO zz.bo_orders SELECT 'A4', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a5_
INSERT INTO zz.bo_orders SELECT 'A5', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a6_
INSERT INTO zz.bo_orders SELECT 'A6', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a7_
INSERT INTO zz.bo_orders SELECT 'A7', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a8_
INSERT INTO zz.bo_orders SELECT 'A8', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a9_
INSERT INTO zz.bo_orders SELECT 'A9', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a10_
INSERT INTO zz.bo_orders SELECT 'A10', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Orders that are NOT online, for comparison (a cash order, paid).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset f_
INSERT INTO zz.bo_orders SELECT 'F', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- 1. A shortage accepted on an order paid online: the pharmacy is refunded the difference.
DO $$
DECLARE o UUID := zz.ord('A1'); a UUID; r TEXT; j JSONB;
BEGIN
  PERFORM zz.paid_accepted(o, 'dx-test-j1-0001');
  PERFORM zz.check('A1: paid in full, nothing owed either way', zz.ostat(o) = 'accepted/paid' AND zz.bal(o) = 0 AND zz.due(o) = 0);
  a := zz.amend(o, jsonb_build_array(zz.line(o, 'BO A', 7, 'release')), 'accept_cancel_remaining');
  PERFORM zz.check('A1: the shortage was accepted on an order paid online and the order now costs 700', a IS NOT NULL AND zz.eff(o) = 700);
  PERFORM zz.check('A1: the 300 difference is refunded: requested, waiting for approval (automatic refunds are off)', zz.rstat(o) = 'requested/30000/amendment_reduction', zz.rstat(o));
  PERFORM zz.check('A1: the order stays paid, and nothing more is owed in either direction', zz.ostat(o) = 'accepted/paid' AND zz.bal(o) = 0 AND zz.due(o) = 0, zz.bal(o)::text);
  PERFORM zz.check('A1: the payment log says why', EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'refund_for_change'));
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', o));
  j := r::jsonb;
  PERFORM zz.check('A1: the pharmacy sees what it paid, the new price and the refund on its way', (j ->> 'paid_ghs')::numeric = 1000 AND (j ->> 'amount_ghs')::numeric = 700 AND jsonb_array_length(j -> 'refunds') = 1
    AND (j -> 'refunds' -> 0 ->> 'status') = 'requested' AND (j ->> 'topup_due_ghs')::numeric = 0, r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', o));
  PERFORM zz.check('A1: the wholesaler sees the same facts', (r::jsonb ->> 'amount_ghs')::numeric = 700, r);
END $$;

-- 2. With automatic refunds on, an amendment's refund is approved at once; a delivery-problem credit never is.
DO $$
DECLARE o UUID := zz.ord('A2'); o4 UUID := zz.ord('A4'); a UUID; rep UUID; l_a UUID; r TEXT;
BEGIN
  UPDATE public.payments_settings SET auto_refunds = TRUE;
  PERFORM zz.paid_accepted(o, 'dx-test-j2-0001');
  a := zz.amend(o, jsonb_build_array(zz.line(o, 'BO A', 8, 'release')), 'accept_cancel_remaining');
  PERFORM zz.check('A2: with automatic refunds on, the refund for an accepted shortage is approved straight away', zz.rstat(o) = 'approved/20000/amendment_reduction'
    AND (SELECT approved_by IS NULL AND approved_at IS NOT NULL FROM public.order_refunds WHERE order_id = o), zz.rstat(o));

  -- A delivery problem on a delivered, paid online order, credited by the wholesaler.
  PERFORM zz.paid_accepted(o4, 'dx-test-j4-0001');
  PERFORM zz.go(o4, 'delivered');
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.submit_delivery_report(%L, NULL, %L::jsonb, ''checked on arrival'', gen_random_uuid())::text', o4,
        jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o4, 'BO A'), 'missing', 2, 'damaged', 0, 'rejected', 0, 'reason', 'two boxes missing'))::text));
  PERFORM zz.check('A4: the pharmacy can report a delivery problem on an order paid online', r NOT LIKE 'ERR%', r);
  rep := (r::jsonb ->> 'report_id')::uuid;
  SELECT id INTO l_a FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO A';
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
        jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'credit'))::text));
  PERFORM zz.check('A4: the wholesaler can credit it (this was refused for a paid order before)', r NOT LIKE 'ERR%' AND zz.eff(o4) = 800, r);
  PERFORM zz.check('A4: the credit becomes a refund that WAITS FOR AN ADMINISTRATOR even though automatic refunds are on', zz.rstat(o4) = 'requested/20000/delivery_credit', zz.rstat(o4));
  UPDATE public.payments_settings SET auto_refunds = FALSE;
END $$;

-- 3. A price decrease is refunded; a price increase must be paid before dispatch.
DO $$
DECLARE o UUID := zz.ord('A3'); o5 UUID := zz.ord('A5'); r TEXT; j JSONB; ref TEXT;
BEGIN
  PERFORM zz.paid_accepted(o5, 'dx-test-j5-0001');
  r := zz.reprice(o5, 80, 1);
  PERFORM zz.check('A5: a price decrease accepted on an order paid online refunds the difference', r NOT LIKE 'ERR%' AND zz.eff(o5) = 800 AND zz.rstat(o5) = 'requested/20000/amendment_reduction', coalesce(r, '') || zz.rstat(o5));

  PERFORM zz.paid_accepted(o, 'dx-test-j3-0001');
  r := zz.reprice(o, 110, 1);
  PERFORM zz.check('A3: a price increase is accepted on an order paid online', r NOT LIKE 'ERR%' AND zz.eff(o) = 1100, r);
  PERFORM zz.check('A3: it stays paid but the pharmacy owes the extra 100.00, and no refund is made', zz.ostat(o) = 'accepted/paid' AND zz.due(o) = 10000 AND zz.bal(o) = 10000 AND zz.rstat(o) IS NULL, zz.due(o)::text);
  PERFORM zz.check('A3: both sides were told', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_pc FROM zz.bo) AND title = 'Payment needed for a price change' AND metadata ->> 'order_id' = o::text)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_wm FROM zz.bo) AND title = 'Waiting for payment of a price change' AND metadata ->> 'order_id' = o::text));
  UPDATE public.orders SET status = 'picking' WHERE id = o; UPDATE public.orders SET status = 'packed' WHERE id = o; UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = o;
  PERFORM zz.check('A3: it can still be picked, packed and made ready', zz.ostat(o) = 'ready_for_dispatch/paid');
  BEGIN UPDATE public.orders SET status = 'dispatched' WHERE id = o; PERFORM zz.check('A3: it cannot be dispatched until the extra payment is made', FALSE, 'dispatched');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('A3: it cannot be dispatched until the extra payment is made', SQLERRM LIKE '%must be paid online before it can be dispatched%', SQLERRM); END;
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', o));
  PERFORM zz.check('A3: the pharmacy''s summary shows what is due', (r::jsonb ->> 'topup_due_ghs')::numeric = 100, r);

  -- Starting the extra payment.
  r := zz.topup(o, 'dx-test-j3-0002', (SELECT u_px FROM zz.bo));
  PERFORM zz.check('A3: another pharmacy cannot start it', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.topup(o, 'dx-test-j3-0002', (SELECT u_wo FROM zz.bo));
  PERFORM zz.check('A3: the wholesaler cannot start it', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.topup(o, 'dx-test-j3-0002', (SELECT u_pa FROM zz.bo));
  PERFORM zz.check('A3: an assistant cannot start it', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.topup(zz.ord('F'), 'dx-test-jf-0001');
  PERFORM zz.check('A3: a cash order cannot be topped up', r = 'ERR: This order was not placed for online payment.', r);
  r := zz.topup(o, 'dx-test-j3-0002');
  j := r::jsonb;
  PERFORM zz.check('A3: the owner starts an extra payment for exactly the amount due, as a top-up', (j ->> 'reused') = 'false' AND (j ->> 'amount_minor') = '10000' AND (j ->> 'amount_ghs')::numeric = 100
    AND (SELECT purpose || '/' || status FROM public.order_payment_attempts WHERE reference = 'dx-test-j3-0002') = 'top_up/initiated', r);
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/j3'', ''ac_j3'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-j3-0002')));
  r := zz.topup(o, 'dx-test-j3-0003');
  PERFORM zz.check('A3: starting again resumes the same extra payment', (r::jsonb ->> 'reused') = 'true' AND (r::jsonb ->> 'reference') = 'dx-test-j3-0002', r);
  r := zz.svc(format('SELECT public.begin_order_payment(%L, %L, ''paystack'', ''test'', ''dx-test-j3-0009'')::text', (SELECT u_po FROM zz.bo), o));
  PERFORM zz.check('A3: the ordinary "pay for the order" start still refuses a paid order', r = 'ERR: This order is already paid.', r);

  -- Paying it.
  j := zz.apply('dx-test-j3-0002', 'success', 10000);
  PERFORM zz.check('A3: the verified extra payment is applied: the order stays paid and nothing is due', (j ->> 'outcome') = 'applied' AND zz.due(o) = 0 AND zz.bal(o) = 0 AND zz.ostat(o) = 'ready_for_dispatch/paid', j::text);
  PERFORM zz.check('A3: it is recorded as a top-up, and the order''s own payment is untouched', (SELECT string_agg(purpose || '/' || status, ',' ORDER BY purpose) FROM public.order_payment_attempts WHERE order_id = o AND status = 'succeeded') = 'order/succeeded,top_up/succeeded'
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'topup_applied'));
  PERFORM zz.check('A3: the wholesaler was told it can be dispatched', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_wm FROM zz.bo) AND title = 'Price change paid' AND metadata ->> 'order_id' = o::text));
  j := zz.apply('dx-test-j3-0002', 'success', 10000);
  PERFORM zz.check('A3: the same result again changes nothing and still says paid', (j ->> 'outcome') = 'duplicate' AND (j ->> 'order_paid') = 'true', j::text);
  BEGIN UPDATE public.orders SET status = 'dispatched' WHERE id = o; PERFORM zz.check('A3: now it can be dispatched', zz.ostat(o) = 'dispatched/paid');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('A3: now it can be dispatched', FALSE, SQLERRM); END;
  r := zz.topup(o, 'dx-test-j3-0004');
  PERFORM zz.check('A3: nothing more can be paid on it', r = 'ERR: There is nothing more to pay on this order.', r);
END $$;

-- 4. Extra payments that cannot be applied are flagged and refunded, never silently kept.
DO $$
DECLARE o UUID := zz.ord('A6'); j JSONB; r TEXT; o2 UUID := zz.ord('A7'); o3 UUID := zz.ord('A8');
BEGIN
  PERFORM zz.paid_accepted(o, 'dx-test-j6-0001');
  PERFORM zz.reprice(o, 110, 1);
  r := zz.topup(o, 'dx-test-j6-0002');
  j := zz.apply('dx-test-j6-0002', 'success', 9999);
  PERFORM zz.check('A6: an extra payment of the wrong amount is flagged, not applied, and its money is refunded; the amount is still due',
    (j ->> 'outcome') = 'flagged' AND (j ->> 'flag') = 'amount_mismatch' AND zz.due(o) = 10000 AND (SELECT status || '/' || refund_required FROM public.order_payment_attempts WHERE reference = 'dx-test-j6-0002') = 'flagged/true'
    AND zz.alerts('refund_required', o) >= 1, j::text);
  r := zz.topup(o, 'dx-test-j6-0003');
  PERFORM zz.apply('dx-test-j6-0003', 'success', 10000);
  r := zz.topup(o, 'dx-test-j6-0004');
  PERFORM zz.check('A6: a failed attempt does not block starting another; once paid there is nothing more to pay', r = 'ERR: There is nothing more to pay on this order.', r);
  -- the price is raised again, a second extra payment is made, and a stale first one then arrives
  PERFORM zz.paid_accepted(o2, 'dx-test-j7-0001');
  PERFORM zz.reprice(o2, 110, 1);
  r := zz.topup(o2, 'dx-test-j7-0002');
  PERFORM zz.reprice(o2, 120, 2);
  j := zz.apply('dx-test-j7-0002', 'success', 10000);
  PERFORM zz.check('A7: an extra payment for an amount that no longer matches what is due is flagged (order total changed) and refunded', (j ->> 'outcome') = 'flagged' AND (j ->> 'flag') = 'order_total_changed' AND zz.due(o2) = 20000, j::text);
  PERFORM zz.reprice(o2, 100, 3);
  r := zz.topup(o2, 'dx-test-j7-0003');
  PERFORM zz.check('A7: when the price comes back down nothing is due', r = 'ERR: There is nothing more to pay on this order.' AND zz.due(o2) = 0, r);

  -- the order is cancelled while an extra payment is in flight
  PERFORM zz.paid_accepted(o3, 'dx-test-j8-0001');
  PERFORM zz.reprice(o3, 110, 1);
  PERFORM zz.topup(o3, 'dx-test-j8-0002');
  UPDATE public.orders SET status = 'cancelled' WHERE id = o3;
  j := zz.apply('dx-test-j8-0002', 'success', 10000);
  PERFORM zz.check('A8: an extra payment arriving after the order was cancelled is recorded as late, with a refund; the order is not revived', (j ->> 'outcome') = 'late' AND zz.ostat(o3) = 'cancelled/paid'
    AND (SELECT refund_required FROM public.order_payment_attempts WHERE reference = 'dx-test-j8-0002'), j::text);
  PERFORM zz.check('A8: the order itself was refunded for its own payment (cancelled after payment) and the late extra payment has its own refund', (SELECT count(*) FROM public.order_refunds WHERE order_id = o3) = 2, zz.rstat(o3));
END $$;

-- 5. Back-orders are not available on an order paid online (yet); a rejected change leaves everything as it was.
DO $$
DECLARE o UUID := zz.ord('A9'); r TEXT; a UUID;
BEGIN
  PERFORM zz.paid_accepted(o, 'dx-test-j9-0001');
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short'', %L::jsonb, gen_random_uuid())::text', o, jsonb_build_array(zz.line(o, 'BO A', 6, 'release'))::text));
  a := (r::jsonb ->> 'amendment_id')::uuid;
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.respond_to_amendment(%L, ''accept_backorder'', NULL)::text', a));
  PERFORM zz.check('A9: accepting a shortage by back-ordering the rest is refused for an order paid online, with a clear reason', r LIKE 'ERR: Back-ordering the rest is not available for an order paid online yet%', r);
  PERFORM zz.check('A9: nothing changed (no new total, no refund)', zz.eff(o) = 1000 AND zz.rstat(o) IS NULL AND (SELECT status FROM public.order_amendments WHERE id = a) = 'proposed');
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.respond_to_amendment(%L, ''reject'', ''no'')::text', a));
  PERFORM zz.check('A9: rejecting it works, and the order stands as placed', r NOT LIKE 'ERR%' AND zz.eff(o) = 1000 AND zz.rstat(o) IS NULL AND zz.bal(o) = 0, r);
END $$;

-- 6. A price that rises again nets off a refund that has not been sent yet.
DO $$
DECLARE o UUID := zz.ord('A10'); r TEXT; a UUID;
BEGIN
  PERFORM zz.paid_accepted(o, 'dx-test-j10-0001');
  a := zz.amend(o, jsonb_build_array(zz.line(o, 'BO A', 7, 'release')), 'accept_cancel_remaining');
  PERFORM zz.check('A10: a shortage of 3 units asks for a refund of 300', zz.rstat(o) = 'requested/30000/amendment_reduction', zz.rstat(o));
  r := zz.reprice(o, 110, 2);
  PERFORM zz.check('A10: the price then rises to 110 for the 7 units that remain (they now cost 770)', r NOT LIKE 'ERR%' AND zz.eff(o) = 770, r);
  PERFORM zz.check('A10: the refund of 300 that had not been sent is cancelled automatically and replaced by one for the 230 still due',
    zz.rstat(o) = 'requested/23000/amendment_reduction,cancelled/30000/amendment_reduction'
    AND (SELECT note FROM public.order_refunds WHERE order_id = o AND status = 'cancelled') LIKE 'Cancelled automatically%', zz.rstat(o));
  PERFORM zz.check('A10: nothing is due from the pharmacy, and the balance is settled', zz.due(o) = 0 AND zz.bal(o) = 0, zz.bal(o)::text);
END $$;

-- 7. A refund that was cancelled leaves a balance nobody has refunded: it is flagged, and an administrator can ask for it.
DO $$
DECLARE o UUID := zz.ord('A1'); rid UUID; r TEXT; n INT;
BEGIN
  SELECT id INTO rid FROM public.order_refunds WHERE order_id = o AND status = 'requested';
  PERFORM zz.adm(rid, 'cancel', 'cancelled by mistake');
  PERFORM zz.check('A1: with the refund cancelled, the order costs less than was paid and nothing is on the way', zz.bal(o) = -30000 AND zz.alerts('refund_required', o) = 0, zz.bal(o)::text);
  n := zz.svc('SELECT public.flag_unrefunded_balances()::text')::int;
  PERFORM zz.check('A1: the unrefunded balance is flagged for a person', n >= 1 AND zz.alerts('refund_required', o) = 1, n::text);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT public.admin_payment_overview()::text');
  PERFORM zz.check('A1: the admin overview marks that alert so the screen can offer the refund, and shows each attempt''s purpose',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r::jsonb -> 'alerts') x WHERE (x ->> 'order_id') = o::text AND (x ->> 'balance_refund_missing') = 'true' AND x ->> 'status' = 'open')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r::jsonb -> 'attempts') x WHERE x ->> 'purpose' = 'top_up'), left(r, 200));
  r := zz.svc(format('SELECT public.admin_request_balance_refund(%L, %L)::text', (SELECT u_po FROM zz.bo), o));
  PERFORM zz.check('A1: only an administrator can ask for it', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.svc(format('SELECT public.admin_request_balance_refund(%L, %L)::text', (SELECT u_admin FROM zz.bo), o));
  PERFORM zz.check('A1: an administrator asks for the difference: a new refund of 300 is requested', (r::jsonb ->> 'requested_minor') = '30000' AND zz.bal(o) = 0
    AND (SELECT count(*) FROM public.order_refunds WHERE order_id = o AND status = 'requested' AND amount_minor = 30000) = 1, r);
  r := zz.svc(format('SELECT public.admin_request_balance_refund(%L, %L)::text', (SELECT u_admin FROM zz.bo), o));
  PERFORM zz.check('A1: asking again when nothing is owed is refused', r LIKE 'ERR: This order does not cost less than was paid%', r);
  r := zz.svc(format('SELECT public.admin_request_balance_refund(%L, %L)::text', (SELECT u_admin FROM zz.bo), zz.ord('F')));
  PERFORM zz.check('A1: it works only for orders paid online', r LIKE 'ERR: Only an order that was paid online%', r);
END $$;

-- 8. Cash and credit orders are unchanged.
DO $$
DECLARE o UUID := zz.ord('F'); r TEXT;
BEGIN
  ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
  UPDATE public.orders SET status = 'accepted', payment_status = 'paid', paid_at = now() WHERE id = o;
  ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short'', %L::jsonb, gen_random_uuid())::text', o, jsonb_build_array(zz.line(o, 'BO A', 7, 'release'))::text));
  PERFORM zz.check('F: a paid CASH order still cannot be amended (no cash refunds)', r LIKE 'ERR: This order has already been paid. Changing it needs a refund%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), o, jsonb_build_array(zz.pl(o, 'BO A', 90)));
  PERFORM zz.check('F: nor can its price be changed', r LIKE 'ERR: This order has already been paid. Changing its price needs a refund%', r);
  PERFORM zz.check('F: the money rule leaves it alone: no refunds, nothing due', zz.rstat(o) IS NULL AND zz.due(o) = 0);
  PERFORM zz.check('F: it is not treated as online', NOT public.order_is_online(o) AND public.order_is_online(zz.ord('A1')));
END $$;

-- 9. Who can do what.
DO $$
DECLARE r TEXT; u RECORD; fn TEXT;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.bo)), ('a wholesaler owner', (SELECT u_wo FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['begin_order_topup(gen_random_uuid(), gen_random_uuid(), ''paystack'', ''test'', ''x'')', 'order_money(gen_random_uuid())', 'order_topup_due_minor(gen_random_uuid())',
      'flag_unrefunded_balances()', 'admin_request_balance_refund(gen_random_uuid(), gen_random_uuid())'] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
  UPDATE public.payments_settings SET online_enabled = FALSE;
  r := zz.topup(zz.ord('A5'), 'dx-test-jx-0001');
  PERFORM zz.check('with online payments switched off, an extra payment cannot be started', r = 'ERR: Online payment is not available yet.', r);
  r := zz.svc(format('SELECT public.begin_order_topup(%L, %L, ''paystack'', ''live'', ''dx-live-jx-0001'')::text', (SELECT u_po FROM zz.bo), zz.ord('A5')));
  PERFORM zz.check('and the mode must match', r LIKE 'ERR: Online payment is not %', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
