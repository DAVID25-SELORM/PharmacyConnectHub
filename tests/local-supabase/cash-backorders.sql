-- Order amendments, Phase 3b: back-orders on cash (pay on delivery) orders, collected portion by portion, against production-like rules.
-- Run after setup.sql + migrations (through 20261105120000_cash_backorders_workflow.sql), with the production guard and stock
-- fixtures installed and the checkout compatibility migration (20261017110000) re-applied (fixture shared with the back-order suite).
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables).
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

-- X: credit, BO A x10 @100 + BO B x20 @50 = 2000.   Y: cash, BO C x10 = 200.   Z: credit, BO C x5 = 100.   W: credit, BO C x6 = 120.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private'),
                    jsonb_build_object('productId', (SELECT pb FROM zz.bo), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'credit')) AS r \gset x_
INSERT INTO zz.bo_orders SELECT 'X', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset y_
INSERT INTO zz.bo_orders SELECT 'Y', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'credit')) AS r \gset z_
INSERT INTO zz.bo_orders SELECT 'Z', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 6, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'credit')) AS r \gset w_
INSERT INTO zz.bo_orders SELECT 'W', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- L: a legacy credit order with no stock-deduction evidence (BO C x5 = 100) and its invoice entry.
ALTER TABLE public.orders DISABLE TRIGGER trg_notify_new_order;
INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_terms_days)
SELECT good, alpha, 100, 0, 0, 100, 'cod', true, 30 FROM zz.bo;
ALTER TABLE public.orders ENABLE TRIGGER trg_notify_new_order;
INSERT INTO zz.bo_orders SELECT 'L', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity)
SELECT zz.ord('L'), pcc, 'BO C', 20, 5 FROM zz.bo;
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note)
SELECT alpha, good, zz.ord('L'), 'invoice', 'debit', 100, 'legacy invoice' FROM zz.bo;

UPDATE public.orders SET status = 'accepted' WHERE id IN (SELECT order_id FROM zz.bo_orders);
CREATE TABLE zz.bo_ids(label TEXT PRIMARY KEY, id UUID);
CREATE FUNCTION zz.rl(p_order UUID, p_name TEXT, p_missing INT, p_damaged INT, p_rejected INT, p_reason TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'missing', p_missing, 'damaged', p_damaged, 'rejected', p_rejected, 'reason', p_reason) $$;
CREATE FUNCTION zz.submit(p_uid UUID, p_order UUID, p_ship UUID, p_lines JSONB, p_req UUID DEFAULT gen_random_uuid()) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.submit_delivery_report(%L, %L, %L::jsonb, ''checked on arrival'', %L)::text', p_order, p_ship, p_lines::text, p_req)) $$;


-- Orders for cash back-orders: C1 (cash, BO A x10 @100 + BO B x20 @50 = 2000), N (cash, BO C x5 @20 = 100, never back-ordered).
-- Y (cash, BO C x10 @20 = 200) and X (credit) come from the shared fixture above.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private'),
                    jsonb_build_object('productId', (SELECT pb FROM zz.bo), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset c1_
INSERT INTO zz.bo_orders SELECT 'C1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset n_
INSERT INTO zz.bo_orders SELECT 'N', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id IN (zz.ord('C1'), zz.ord('N'));

CREATE FUNCTION zz.collect(p_uid UUID, p_order UUID, p_ship UUID DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.confirm_cash_collection(%L, %L)::text', p_order, p_ship)) $$;
CREATE FUNCTION zz.mkship(p_order UUID, p_lines JSONB) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', p_order, p_lines::text));
  IF r LIKE 'ERR%' THEN RAISE EXCEPTION 'create shipment failed: %', r; END IF;
  RETURN (r::jsonb->>'shipment_id')::uuid;
END $$;
CREATE FUNCTION zz.adv(p_uid UUID, p_ship UUID, p_to TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.advance_backorder_shipment(%L, %L)::text', p_ship, p_to)) $$;
CREATE FUNCTION zz.ledger(p_order UUID) RETURNS BIGINT LANGUAGE sql AS $$ SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = p_order $$;
CREATE FUNCTION zz.coll(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$
  SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.order_collections WHERE order_id = p_order $$;

-- 0. Starting point.
DO $$
BEGIN
  PERFORM zz.check('the new cash orders are accepted', (SELECT count(*) = 2 FROM public.orders WHERE id IN (zz.ord('C1'), zz.ord('N')) AND status = 'accepted' AND NOT is_credit_order));
  PERFORM zz.check('an ordinary cash order has no portions', NOT public.order_has_cash_portions(zz.ord('N')) AND NOT public.order_has_cash_portions(zz.ord('X')));
END $$;

-- 1. A cash order can now be accepted with a back-order (C1: BO A 10 -> 6, BO B 20 -> 14; 4 and 6 back-ordered = 700).
DO $$
DECLARE c1 UUID := zz.ord('C1'); a UUID; stock_a INT := zz.stock('BO A'); stock_b INT := zz.stock('BO B'); st JSONB;
BEGIN
  a := zz.amend(c1, jsonb_build_array(zz.line(c1, 'BO A', 6, 'release'), zz.line(c1, 'BO B', 14, 'release')), 'accept_backorder');
  INSERT INTO zz.bo_ids VALUES ('c1a', a);
  PERFORM zz.check('the pharmacy accepts the cash order with a back-order', (SELECT status = 'accepted' AND response_choice = 'accept_backorder' FROM public.order_amendments WHERE id = a));
  PERFORM zz.check('the effective total is 1300 and the placed total is 2000', (SELECT effective_total_ghs = 1300 AND total_ghs = 2000 FROM public.orders WHERE id = c1));
  PERFORM zz.check('a cash order has no ledger: no entry at all', zz.ledger(c1) = 0);
  PERFORM zz.check('stock follows the per-line choice: BO A and BO B released (+4, +6)', zz.stock('BO A') = stock_a + 4 AND zz.stock('BO B') = stock_b + 6);
  PERFORM zz.check('the order is now collected portion by portion', public.order_has_cash_portions(c1));
  PERFORM zz.check('its main delivery is worth 1300 (nothing has been dispatched yet)', public.order_main_total(c1) = 1300);
  st := public.order_backorder_state(c1);
  PERFORM zz.check('the back-order state says so: open, 10 units, cash portions, main not yet collected',
    st->>'status' = 'open' AND (st->>'backordered')::int = 10 AND (st->>'cash_portions')::boolean AND NOT (st->>'main_collected')::boolean, st::text);
  PERFORM zz.check('an ordinary cash order reports no cash portions', NOT (public.order_backorder_state(zz.ord('N'))->>'cash_portions')::boolean);
END $$;

-- 2. Who may collect, and what is refused, before anything is delivered.
DO $$
DECLARE c1 UUID := zz.ord('C1'); r TEXT; u RECORD;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a warehouse user', (SELECT u_ww FROM zz.bo)), ('the pharmacy owner', (SELECT u_po FROM zz.bo)), ('another wholesaler', (SELECT u_wx FROM zz.bo)),
      ('a pharmacy assistant', (SELECT u_pa FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.collect(u.uid, c1);
    PERFORM zz.check(u.label || ' cannot confirm a collection', r LIKE 'ERR: Only the wholesaler owner or active order-processing staff can confirm payment.%', r);
  END LOOP;
  r := zz.collect((SELECT u_wc FROM zz.bo), c1);
  PERFORM zz.check('the main delivery cannot be collected before the order is delivered', r LIKE 'ERR: Mark this order as delivered before confirming payment for the main delivery.%', r);
  r := zz.collect((SELECT u_wc FROM zz.bo), zz.ord('N'));
  PERFORM zz.check('an ordinary cash order is paid as one amount, not through collections', r LIKE 'ERR: This order is paid as one amount: confirm payment on the order itself.%', r);
  r := zz.collect((SELECT u_wo FROM zz.bo), zz.ord('X'));
  PERFORM zz.check('so is a credit order (it is paid through the ledger)', r LIKE 'ERR: This order is paid as one amount: confirm payment on the order itself.%', r);
  r := zz.collect((SELECT u_wc FROM zz.bo), c1, gen_random_uuid());
  PERFORM zz.check('a shipment that is not on this order is refused', r LIKE 'ERR: That shipment does not belong to this order.%', r);
  -- A direct update cannot mark such an order paid.
  BEGIN
    UPDATE public.orders SET payment_status = 'paid' WHERE id = c1;
    PERFORM zz.check('a direct update cannot mark the order paid', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('a direct update cannot mark the order paid', SQLERRM LIKE 'This order is collected one delivery at a time%', SQLERRM);
  END;
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('UPDATE public.orders SET payment_status = ''paid'' WHERE id = %L RETURNING id::text', c1));
  PERFORM zz.check('nor can a cashier through the normal order update', r LIKE 'ERR:%', r);
  PERFORM zz.check('an ordinary cash order can still be updated as before', (SELECT count(*) = 1 FROM (SELECT 1 FROM public.orders WHERE id = zz.ord('N') AND payment_status = 'unpaid') q));
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('INSERT INTO public.order_collections(order_id, amount_ghs) VALUES (%L, 1)', c1));
  PERFORM zz.check('nobody can write a collection directly', r LIKE 'ERR:%', r);
END $$;

-- 3. The main delivery goes out and is collected.
SELECT zz.go(zz.ord('C1'), 'delivered');
DO $$
DECLARE c1 UUID := zz.ord('C1'); r TEXT;
BEGIN
  r := zz.collect((SELECT u_wf FROM zz.bo), c1);
  PERFORM zz.check('a finance user confirms the main delivery: 1300', r::jsonb->>'portion' = 'main' AND (r::jsonb->>'amount')::numeric = 1300 AND r::jsonb->>'replayed' = 'false', r);
  PERFORM zz.check('nothing else is owed yet, so the order is paid', (r::jsonb->>'order_paid')::boolean
    AND (SELECT payment_status::text = 'paid' AND paid_at IS NOT NULL AND payment_confirmed_at IS NOT NULL AND payment_confirmed_by = (SELECT u_wf FROM zz.bo) FROM public.orders WHERE id = c1));
  PERFORM zz.check('one collection of 1300 is recorded for the main delivery', zz.coll(c1) = '1/1300.00' AND EXISTS (SELECT 1 FROM public.order_collections WHERE order_id = c1 AND shipment_id IS NULL));
  r := zz.collect((SELECT u_wc FROM zz.bo), c1);
  PERFORM zz.check('confirming again changes nothing (replayed)', r::jsonb->>'replayed' = 'true' AND zz.coll(c1) = '1/1300.00', r);
  PERFORM zz.check('the timeline and audit record it',
    EXISTS (SELECT 1 FROM public.order_events WHERE order_id = c1 AND event_type = 'payment_confirmed')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Cash payment confirmed' AND record_id = c1));
  PERFORM zz.check('the back-order state now shows the main delivery as collected', (public.order_backorder_state(c1)->>'main_collected')::boolean);
END $$;

-- 4. Two shipments: BO A x4 (400) and BO B x6 (300). Dispatching reopens the paid order; nothing touches the ledger.
DO $$
DECLARE c1 UUID := zz.ord('C1'); r TEXT; s2 UUID; s3 UUID; stock_a INT := zz.stock('BO A'); stock_b INT := zz.stock('BO B'); v JSONB;
BEGIN
  s2 := zz.mkship(c1, jsonb_build_array(zz.sl(c1, 'BO A', 4)));
  s3 := zz.mkship(c1, jsonb_build_array(zz.sl(c1, 'BO B', 6)));
  INSERT INTO zz.bo_ids VALUES ('c1s2', s2), ('c1s3', s3);
  PERFORM zz.check('preparing shipments moves nothing: the order stays paid at 1300', (SELECT payment_status::text = 'paid' AND effective_total_ghs = 1300 FROM public.orders WHERE id = c1));
  r := zz.adv((SELECT u_ww FROM zz.bo), s2, 'packed');
  r := zz.adv((SELECT u_ww FROM zz.bo), s2, 'dispatched');
  PERFORM zz.check('a warehouse user dispatches shipment 2 of the cash order', r::jsonb->>'status' = 'dispatched' AND (r::jsonb->>'amount')::numeric = 400, r);
  PERFORM zz.check('no ledger entry: a cash shipment is not invoiced', zz.ledger(c1) = 0);
  PERFORM zz.check('the order total rises to 1700 and the order is reopened as unpaid',
    (SELECT effective_total_ghs = 1700 AND payment_status::text = 'unpaid' AND paid_at IS NULL FROM public.orders WHERE id = c1));
  PERFORM zz.check('the main delivery stays collected (1300) and is still worth 1300', zz.coll(c1) = '1/1300.00' AND public.order_main_total(c1) = 1300);
  PERFORM zz.check('stock was deducted once for the units sent (BO A -4)', zz.stock('BO A') = stock_a - 4 AND zz.stock('BO B') = stock_b);
  r := zz.adv((SELECT u_wo FROM zz.bo), s3, 'packed');
  r := zz.adv((SELECT u_wo FROM zz.bo), s3, 'dispatched');
  PERFORM zz.check('shipment 3 is dispatched: total 2000, still unpaid, no ledger', (SELECT effective_total_ghs = 2000 AND payment_status::text = 'unpaid' FROM public.orders WHERE id = c1) AND zz.ledger(c1) = 0);
  r := zz.adv((SELECT u_wo FROM zz.bo), s2, 'dispatched');
  PERFORM zz.check('dispatching again is a replay and adds nothing', r::jsonb->>'replayed' = 'true' AND (SELECT effective_total_ghs = 2000 FROM public.orders WHERE id = c1), r);
  r := zz.collect((SELECT u_wc FROM zz.bo), c1, s2);
  PERFORM zz.check('a shipment cannot be collected before it is delivered', r LIKE 'ERR: Mark shipment 2 as delivered before confirming payment for it.%', r);
  r := zz.adv((SELECT u_wo FROM zz.bo), s2, 'delivered');
  r := zz.adv((SELECT u_wo FROM zz.bo), s3, 'delivered');
  r := zz.collect((SELECT u_wc FROM zz.bo), c1, s2);
  PERFORM zz.check('shipment 2 is collected: 400', r::jsonb->>'portion' = 'shipment' AND (r::jsonb->>'sequence')::int = 2 AND (r::jsonb->>'amount')::numeric = 400, r);
  PERFORM zz.check('shipment 3 is still owed, so the order stays unpaid', NOT (r::jsonb->>'order_paid')::boolean AND (SELECT payment_status::text = 'unpaid' FROM public.orders WHERE id = c1));
  PERFORM zz.check('the pharmacy was told about the part-payment', EXISTS (SELECT 1 FROM public.notifications WHERE type = 'payment_update' AND title = 'Payment received'));
  r := zz.collect((SELECT u_wc FROM zz.bo), c1, s2);
  PERFORM zz.check('collecting shipment 2 again is a replay', r::jsonb->>'replayed' = 'true' AND zz.coll(c1) = '2/1700.00', r);
  r := zz.collect((SELECT u_wc FROM zz.bo), c1, s3);
  PERFORM zz.check('shipment 3 is collected: 300, and now the whole order is paid', (r::jsonb->>'amount')::numeric = 300 AND (r::jsonb->>'order_paid')::boolean
    AND (SELECT payment_status::text = 'paid' AND paid_at IS NOT NULL AND effective_total_ghs = 2000 FROM public.orders WHERE id = c1), r);
  PERFORM zz.check('three collections add up to the order total (1300 + 400 + 300)', zz.coll(c1) = '3/2000.00');
  PERFORM zz.check('the database allows one collection per portion',
    (SELECT count(*) = 3 FROM public.order_collections WHERE order_id = c1) AND (SELECT count(DISTINCT COALESCE(shipment_id, '00000000-0000-0000-0000-000000000000')) = 3 FROM public.order_collections WHERE order_id = c1));
  v := zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', c1));
  PERFORM zz.check('the read function reports cash portions, the main collection and each shipment''s collection',
    (v->>'cash_portions')::boolean AND (v->>'main_total')::numeric = 1300 AND v->>'main_collected_at' IS NOT NULL
    AND (SELECT count(*) = 2 AND bool_and(sh->>'collected_at' IS NOT NULL) FROM jsonb_array_elements(v->'shipments') sh), left(v::text, 300));
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.order_supply_summary(ARRAY[%L]::uuid[]) s)::text', c1));
  PERFORM zz.check('the order lists carry cash_portions and the main total (1300 of 2000)', (v->0->>'main_total_ghs')::numeric = 1300 AND (v->0->'backorder'->>'cash_portions')::boolean, left(v::text, 300));
END $$;

-- 5. Collections are append-only.
DO $$
DECLARE c1 UUID := zz.ord('C1'); r TEXT;
BEGIN
  BEGIN UPDATE public.order_collections SET amount_ghs = 1 WHERE order_id = c1; PERFORM zz.check('a collection cannot be edited', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a collection cannot be edited', SQLERRM LIKE '%append-only%', SQLERRM); END;
  BEGIN DELETE FROM public.order_collections WHERE order_id = c1; PERFORM zz.check('a collection cannot be deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a collection cannot be deleted', SQLERRM LIKE '%append-only%', SQLERRM); END;
END $$;

-- 6. Receipts: one per collected portion.
DO $$
DECLARE c1 UUID := zz.ord('C1'); s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 'c1s2'); v JSONB; r TEXT; cid UUID;
BEGIN
  v := zz.j((SELECT u_wf FROM zz.bo), format('SELECT public.cash_collection_receipt(%L, NULL)::text', c1));
  cid := (v->>'collection_id')::uuid;
  PERFORM zz.check('the main delivery''s receipt: 1300, the main quantities (BO A 6, BO B 14), the placed order number',
    (v->>'total_ghs')::numeric = 1300 AND v->>'order_number' = (SELECT order_number FROM public.orders WHERE id = c1)
    AND (SELECT sum((i->>'quantity')::int) = 20 FROM jsonb_array_elements(v->'items') i), left(v::text, 300));
  v := zz.j((SELECT u_wf FROM zz.bo), format('SELECT public.cash_collection_receipt(%L, %L)::text', c1, s2));
  PERFORM zz.check('a shipment''s receipt: 400, its own lines (BO A 4 at 100), no delivery fee, labelled with the shipment',
    (v->>'total_ghs')::numeric = 400 AND (v->>'delivery_fee_ghs')::numeric = 0 AND v->>'order_number' LIKE '% (shipment 2)'
    AND (SELECT count(*) = 1 AND bool_and((i->>'quantity')::int = 4 AND (i->>'unit_price_ghs')::numeric = 100) FROM jsonb_array_elements(v->'items') i), left(v::text, 300));
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.cash_collection_receipt(%L, NULL)::text', c1));
  PERFORM zz.check('a warehouse user cannot read a receipt', r LIKE 'ERR: Only the wholesaler owner or active order-processing staff can send receipts.%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.cash_collection_receipt(%L, NULL)::text', c1));
  PERFORM zz.check('nor can the pharmacy', r LIKE 'ERR: Only the wholesaler owner or active order-processing staff can send receipts.%', r);
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('SELECT public.mark_collection_receipt_sent(%L, ''pharmacy@example.test'')::text', cid));
  PERFORM zz.check('sending a receipt is recorded on the collection', r NOT LIKE 'ERR%' AND (SELECT receipt_sent_at IS NOT NULL AND receipt_sent_to = 'pharmacy@example.test' FROM public.order_collections WHERE id = cid), r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.mark_collection_receipt_sent(%L, ''x@example.test'')::text', cid));
  PERFORM zz.check('only the wholesaler can record it', r LIKE 'ERR: Only the wholesaler owner%', r);
  v := zz.j((SELECT u_wf FROM zz.bo), format('SELECT public.cash_collection_receipt(%L, NULL)::text', zz.ord('Y')));
  PERFORM zz.check('there is no receipt for a portion that has not been collected', v IS NULL);
END $$;

-- 7. The customer statement: one payment line per collection, and the order nets to zero.
DO $$
DECLARE c1 UUID := zz.ord('C1'); v JSONB; num TEXT := (SELECT order_number FROM public.orders WHERE id = zz.ord('C1'));
BEGIN
  v := zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)));
  PERFORM zz.check('three payment lines (1300, 400, 300), not one',
    (SELECT count(*) = 3 AND sum((ln->>'credit')::numeric) = 2000 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'payment' AND ln->>'order_number' = num), left(v::text, 200));
  PERFORM zz.check('two shipment charges (400, 300)',
    (SELECT count(*) = 2 AND sum((ln->>'debit')::numeric) = 700 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'shipment' AND ln->>'order_number' = num));
  PERFORM zz.check('placed 2000 - 700 (back-ordered) + 700 (shipped) - 2000 (collected) = 0 for the order',
    (SELECT sum((ln->>'debit')::numeric) - sum((ln->>'credit')::numeric) = 0 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'order_number' = num));
END $$;

-- 8. Y (cash, BO C x10 @20 = 200): the main delivery was marked paid the old way before the back-order shipped (backfill case),
--    and a delivery problem on an uncollected shipment can be credited.
DO $$
DECLARE y UUID := zz.ord('Y'); a UUID; s UUID; r TEXT; rep UUID; stock_c INT;
BEGIN
  a := zz.amend(y, jsonb_build_array(zz.line(y, 'BO C', 6, 'release')), 'accept_backorder');
  PERFORM zz.check('Y: accepted with a back-order of 4 (80); the order is now worth 120', (SELECT effective_total_ghs = 120 FROM public.orders WHERE id = y) AND zz.ledger(y) = 0);
  PERFORM zz.go(y, 'delivered');
  -- Marked paid outside confirm_cash_collection (as an order paid before this feature would be).
  ALTER TABLE public.orders DISABLE TRIGGER trg_guard_cash_portion_payment;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = (SELECT u_wo FROM zz.bo) WHERE id = y;
  ALTER TABLE public.orders ENABLE TRIGGER trg_guard_cash_portion_payment;
  stock_c := zz.stock('BO C');
  s := zz.mkship(y, jsonb_build_array(zz.sl(y, 'BO C', 4)));
  INSERT INTO zz.bo_ids VALUES ('ys', s);
  r := zz.adv((SELECT u_wo FROM zz.bo), s, 'packed');
  r := zz.adv((SELECT u_wo FROM zz.bo), s, 'dispatched');
  PERFORM zz.check('dispatching records the earlier payment of the main delivery first (120), then reopens the order',
    zz.coll(y) = '1/120.00' AND (SELECT confirmed_by = (SELECT u_wo FROM zz.bo) FROM public.order_collections WHERE order_id = y)
    AND (SELECT effective_total_ghs = 200 AND payment_status::text = 'unpaid' FROM public.orders WHERE id = y), zz.coll(y));
  PERFORM zz.check('and the stock for the 4 units was deducted', zz.stock('BO C') = stock_c - 4);
  r := zz.adv((SELECT u_wo FROM zz.bo), s, 'delivered');
  -- The pharmacy reports one missing unit on the shipment; the wholesaler credits it.
  r := zz.submit((SELECT u_po FROM zz.bo), y, s, jsonb_build_array(zz.rl(y, 'BO C', 1, 0, 0, 'one pack short')));
  rep := (r::jsonb->>'report_id')::uuid;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, ''checked'')::text', rep,
    (SELECT jsonb_agg(jsonb_build_object('line_id', id, 'kind', 'missing', 'outcome', 'credit')) FROM public.order_delivery_report_lines WHERE report_id = rep AND missing_qty > 0)::text));
  PERFORM zz.check('a delivery problem on an uncollected cash shipment can be credited (20)', r::jsonb->>'status' = 'resolved' AND (SELECT effective_total_ghs = 180 FROM public.orders WHERE id = y), r);
  PERFORM zz.check('the credit lowers what the shipment is worth (80 -> 60), not what the main delivery is worth (still 120)',
    public.order_shipment_net(s) = 60 AND public.order_main_total(y) = 120);
  r := zz.collect((SELECT u_wc FROM zz.bo), y, s);
  PERFORM zz.check('so the shipment is collected at 60 and the order is paid (120 + 60)', (r::jsonb->>'amount')::numeric = 60 AND (r::jsonb->>'order_paid')::boolean
    AND zz.coll(y) = '2/180.00' AND (SELECT payment_status::text = 'paid' FROM public.orders WHERE id = y), r);
END $$;

-- 9. A collected portion cannot be credited (no cash refunds): C1's shipment 2 is collected.
DO $$
DECLARE c1 UUID := zz.ord('C1'); s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 'c1s2'); r TEXT; rep UUID;
BEGIN
  r := zz.submit((SELECT u_po FROM zz.bo), c1, s2, jsonb_build_array(zz.rl(c1, 'BO A', 1, 0, 0, 'one pack short')));
  rep := (r::jsonb->>'report_id')::uuid;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, ''checked'')::text', rep,
    (SELECT jsonb_agg(jsonb_build_object('line_id', id, 'kind', 'missing', 'outcome', 'credit')) FROM public.order_delivery_report_lines WHERE report_id = rep AND missing_qty > 0)::text));
  PERFORM zz.check('crediting a problem on a collected shipment is refused', r LIKE 'ERR: This order has already been paid, and refunding it is not supported.%', r);
  PERFORM zz.check('and the order is untouched', (SELECT effective_total_ghs = 2000 FROM public.orders WHERE id = c1));
END $$;

-- 10. Back-orders on credit orders behave as before (the full credit suite is order-backorders.sql); here only the shared pieces.
DO $$
DECLARE x UUID := zz.ord('X'); v JSONB;
BEGIN
  v := zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', x));
  PERFORM zz.check('a credit order reports no cash portions', NOT (v->>'cash_portions')::boolean AND v->>'main_collected_at' IS NULL, left(v::text, 200));
  PERFORM zz.check('the cash tables have nothing for it', zz.coll(x) = '0/0');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
