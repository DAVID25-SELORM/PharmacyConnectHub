-- Order amendments, Phase 2: partial fulfilment (propose / respond / withdraw / reconcile), against production-like rules.
-- Run after setup.sql + migrations (through 20261030120000_order_amendments_partial_fulfilment.sql), with the production
-- guard and stock fixtures installed and the checkout compatibility migration (20261017110000) re-applied.
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
FROM zz.b b, (VALUES ('PF A', 100, 1000), ('PF B', 50, 500), ('PF C', 20, 200), ('PF D', 10, 300)) v(n, p, s) WHERE b.name = 'Alpha Wholesale';
CREATE TABLE zz.pf AS SELECT
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
  (SELECT id FROM public.products WHERE name='PF A') pa,
  (SELECT id FROM public.products WHERE name='PF B') pb,
  (SELECT id FROM public.products WHERE name='PF C') pcc,
  (SELECT id FROM public.products WHERE name='PF D') pd;
CREATE TABLE zz.pf_orders(label TEXT PRIMARY KEY, order_id UUID);
CREATE FUNCTION zz.ord(p_label TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT order_id FROM zz.pf_orders WHERE label = p_label $$;
CREATE FUNCTION zz.item(p_order UUID, p_name TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT id FROM public.order_items WHERE order_id = p_order AND product_name = p_name $$;
CREATE FUNCTION zz.stock(p_name TEXT) RETURNS INTEGER LANGUAGE sql AS $$ SELECT stock FROM public.products WHERE name = p_name $$;
CREATE FUNCTION zz.line(p_order UUID, p_name TEXT, p_qty INT, p_treat TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'supplied_qty', p_qty, 'stock_treatment', p_treat) $$;

SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.pf), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.pf)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.pf;

-- Order A: credit, 3 lines (PF A x10 @100, PF B x20 @50, PF C x5 @20) = 2100.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 10, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pb FROM zz.pf), 'quantity', 20, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'credit')) AS r \gset a_
INSERT INTO zz.pf_orders SELECT 'A', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order B: cash on delivery, PF A x4 + PF B x10 = 900.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 4, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pb FROM zz.pf), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset b_
INSERT INTO zz.pf_orders SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order D: credit, PF A x5 = 500, with a payment of 200 already recorded.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'credit')) AS r \gset d_
INSERT INTO zz.pf_orders SELECT 'D', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note)
SELECT alpha, good, zz.ord('D'), 'payment', 'credit', 200, 'test payment' FROM zz.pf;
-- Order E and F: cash on delivery, PF D (batched), 30 and 20 units.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pd FROM zz.pf), 'quantity', 30, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset e_
INSERT INTO zz.pf_orders SELECT 'E', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pd FROM zz.pf), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset f_
INSERT INTO zz.pf_orders SELECT 'F', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order G: a legacy order with no stock deduction evidence (cod, PF C x10 = 200).
ALTER TABLE public.orders DISABLE TRIGGER trg_notify_new_order;
INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order)
SELECT good, alpha, 200, 0, 0, 200, 'cod', false FROM zz.pf;
ALTER TABLE public.orders ENABLE TRIGGER trg_notify_new_order;
INSERT INTO zz.pf_orders SELECT 'G', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity)
SELECT zz.ord('G'), pcc, 'PF C', 20, 10 FROM zz.pf;
-- Order H: pending (never accepted).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset h_
INSERT INTO zz.pf_orders SELECT 'H', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Batches for PF D (stock 300 - 30 - 20 = 250 after the two checkouts).
INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
SELECT pd, alpha, 'B-EARLY', current_date + 60, 20, 20 FROM zz.pf;
INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
SELECT pd, alpha, 'B-LATE', current_date + 120, 100, 100 FROM zz.pf;

UPDATE public.orders SET status = 'accepted' WHERE id IN (SELECT order_id FROM zz.pf_orders WHERE label IN ('A', 'B', 'D', 'E', 'F', 'G'));

-- 0. Starting point.
DO $$
BEGIN
  PERFORM zz.check('orders placed: A credit 2100, B cod 900, D credit 500',
    (SELECT total_ghs FROM public.orders WHERE id = zz.ord('A')) = 2100 AND (SELECT total_ghs FROM public.orders WHERE id = zz.ord('B')) = 900
    AND (SELECT total_ghs FROM public.orders WHERE id = zz.ord('D')) = 500);
  PERFORM zz.check('checkout deducted stock: PF A 1000-10-4-5=981, PF B 500-20-10=470, PF C 200-5-1=194, PF D 300-30-20=250',
    zz.stock('PF A') = 981 AND zz.stock('PF B') = 470 AND zz.stock('PF C') = 194 AND zz.stock('PF D') = 250,
    zz.stock('PF A') || '/' || zz.stock('PF B') || '/' || zz.stock('PF C') || '/' || zz.stock('PF D'));
  PERFORM zz.check('orders A..F have deduction evidence, the legacy order G does not',
    public.order_has_stock_evidence(zz.ord('A')) AND public.order_has_stock_evidence(zz.ord('F')) AND NOT public.order_has_stock_evidence(zz.ord('G')));
  PERFORM zz.check('no order has an effective total or an amendment yet',
    NOT EXISTS (SELECT 1 FROM public.orders WHERE effective_total_ghs IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM public.order_amendments));
  PERFORM zz.check('supplied quantity equals ordered quantity for an un-amended line', public.order_item_supplied_qty(zz.item(zz.ord('A'), 'PF A')) = 10);
END $$;

-- 1. Who may propose, and what is refused.
DO $$
DECLARE o UUID := zz.ord('A'); u RECORD; r TEXT; tmpl TEXT;
BEGIN
  tmpl := 'SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text';
  FOR u IN SELECT * FROM (VALUES ('the pharmacy owner', (SELECT u_po FROM zz.pf)), ('another pharmacy', (SELECT u_px FROM zz.pf)),
      ('another wholesaler', (SELECT u_wx FROM zz.pf)), ('finance staff', (SELECT u_wf FROM zz.pf)), ('a platform admin', (SELECT u_admin FROM zz.pf))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format(tmpl, o, jsonb_build_array(zz.line(o, 'PF A', 7, 'release'))::text));
    PERFORM zz.check(u.label || ' cannot propose a supply change', r LIKE 'ERR: You do not have permission to propose%', r);
  END LOOP;
  r := zz.val_as(NULL, format(tmpl, o, jsonb_build_array(zz.line(o, 'PF A', 7, 'release'))::text));
  PERFORM zz.check('an unauthenticated call is refused', r LIKE 'ERR:%', r);

  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', zz.ord('H'), jsonb_build_array(zz.line(zz.ord('H'), 'PF C', 0, 'release'))::text));
  PERFORM zz.check('a pending order cannot be amended (only accepted .. ready for dispatch)', r LIKE 'ERR: Supply can only be changed while the order is being prepared%', r);

  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, '' '', %L::jsonb, gen_random_uuid())::text', o, jsonb_build_array(zz.line(o, 'PF A', 7, 'release'))::text));
  PERFORM zz.check('a blank reason is refused', r LIKE 'ERR: A reason for the shortage is required%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', ''[]''::jsonb, gen_random_uuid())::text', o));
  PERFORM zz.check('no lines is refused', r LIKE 'ERR: Say which products%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(jsonb_build_object('order_item_id', gen_random_uuid(), 'supplied_qty', 1, 'stock_treatment', 'release'))::text));
  PERFORM zz.check('a line that is not on the order is refused', r LIKE 'ERR: A line does not belong to this order.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF A', 6, 'release'))::text));
  PERFORM zz.check('the same product twice is refused', r LIKE 'ERR: Each product can appear only once.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 11, 'release'))::text));
  PERFORM zz.check('supplying more than ordered is refused', r LIKE 'ERR: You cannot supply more of PF A%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o, 'PF A'), 'supplied_qty', -1, 'stock_treatment', 'release'))::text));
  PERFORM zz.check('a negative quantity is refused', r LIKE 'ERR: The quantity to supply for PF A must be a whole number.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o, 'PF A'), 'supplied_qty', 2.5, 'stock_treatment', 'release'))::text));
  PERFORM zz.check('a fractional quantity is refused', r LIKE 'ERR: The quantity to supply for PF A must be a whole number.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 10, 'release'))::text));
  PERFORM zz.check('a proposal that reduces nothing is refused', r LIKE 'ERR: Nothing is being reduced.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 0, 'release'), zz.line(o, 'PF B', 0, 'release'), zz.line(o, 'PF C', 0, 'release'))::text));
  PERFORM zz.check('supplying nothing at all is refused (that is a cancellation)', r LIKE 'ERR: Supplying nothing is a cancellation.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o, 'PF A'), 'supplied_qty', 7))::text));
  PERFORM zz.check('a shortage with no stock treatment is refused when stock evidence exists', r LIKE 'ERR: Say what happens to the stock for PF A%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Not enough stock'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'destroy'))::text));
  PERFORM zz.check('an unknown stock treatment is refused', r LIKE 'ERR: Say what happens to the stock for PF A%', r);
  PERFORM zz.check('none of the refused calls created a proposal or changed anything',
    NOT EXISTS (SELECT 1 FROM public.order_amendments) AND zz.stock('PF A') = 981 AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = o));
END $$;

-- 2. A valid proposal on order A, made by the warehouse user: PF A 10 -> 7 (release), PF B 20 -> 15 (write off).
CREATE TABLE zz.pf_ids(label TEXT PRIMARY KEY, id UUID);
CREATE TABLE zz.pf_req(label TEXT PRIMARY KEY, id UUID DEFAULT gen_random_uuid());
INSERT INTO zz.pf_req(label) VALUES ('a1'), ('a2'), ('a3');
DO $$
DECLARE o UUID := zz.ord('A'); r TEXT; r2 TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_ww FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short on PF A and PF B'', %L::jsonb, %L)::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF B', 15, 'write_off'))::text, (SELECT id FROM zz.pf_req WHERE label = 'a1')));
  PERFORM zz.check('a warehouse user can propose a partial supply', r NOT LIKE 'ERR%' AND r::jsonb->>'status' = 'proposed', r);
  a := (r::jsonb->>'amendment_id')::uuid;
  INSERT INTO zz.pf_ids VALUES ('a1', a);
  PERFORM zz.check('the proposal fixes the totals: 2100 -> 1550 (delta -550, from 300 + 250)',
    (SELECT original_total_ghs = 2100 AND proposed_total_ghs = 1550 AND delta_ghs = -550 AND version = 1 AND stock_mode = 'evidence' AND kind = 'partial_fulfilment' FROM public.order_amendments WHERE id = a), r);
  PERFORM zz.check('every order line is recorded (3), with ordered / prior / supplied / short / price / treatment',
    (SELECT count(*) = 3 AND sum(short_qty) = 8 AND bool_and(supplied_qty + short_qty = prior_supplied_qty) FROM public.order_amendment_lines WHERE amendment_id = a)
    AND (SELECT stock_treatment = 'release' AND short_qty = 3 AND unit_price_ghs = 100 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF A')
    AND (SELECT stock_treatment = 'write_off' AND short_qty = 5 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF B')
    AND (SELECT stock_treatment = 'none' AND short_qty = 0 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF C'));
  PERFORM zz.check('proposing changes nothing yet: no effective total, stock, ledger or supplied quantity',
    (SELECT effective_total_ghs IS NULL AND total_ghs = 2100 FROM public.orders WHERE id = o)
    AND zz.stock('PF A') = 981 AND zz.stock('PF B') = 470
    AND (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE order_id = o)
    AND public.order_item_supplied_qty(zz.item(o, 'PF A')) = 10
    AND NOT EXISTS (SELECT 1 FROM public.order_stock_movements));
  PERFORM zz.check('a proposed-by-warehouse event is on the timeline',
    (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_proposed' AND actor_side = 'wholesaler' AND amendment_id = a));
  PERFORM zz.check('the proposal is audited for the wholesaler with its reason and totals',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order supply change proposed' AND record_id = o AND business_id = (SELECT alpha FROM zz.pf)
      AND details->>'reason' = 'Supplier short on PF A and PF B' AND (details->>'proposed_total')::numeric = 1550));
  PERFORM zz.check('the pharmacy owner and cashier are notified, the proposing wholesaler is not',
    (SELECT count(*) = 2 FROM public.notifications WHERE type = 'order_amendment' AND user_id IN ((SELECT u_po FROM zz.pf), (SELECT u_pc FROM zz.pf)))
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_ww FROM zz.pf))
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_pa FROM zz.pf)));
  -- Idempotency.
  r2 := zz.val_as((SELECT u_ww FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short on PF A and PF B'', %L::jsonb, %L)::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF B', 15, 'write_off'))::text, (SELECT id FROM zz.pf_req WHERE label = 'a1')));
  PERFORM zz.check('repeating the same request returns the same proposal (replayed)', r2::jsonb->>'replayed' = 'true' AND (r2::jsonb->>'amendment_id')::uuid = a, r2);
  PERFORM zz.check('and creates nothing new', (SELECT count(*) = 1 FROM public.order_amendments WHERE order_id = o)
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_proposed'));
  r2 := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Another try'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF C', 3, 'release'))::text));
  PERFORM zz.check('only one open proposal per order', r2 LIKE 'ERR: A supply change is already awaiting a response%', r2);
  BEGIN
    INSERT INTO public.order_amendments(order_id, version, kind, reason, proposed_by, original_total_ghs, proposed_total_ghs, delta_ghs, request_id)
    VALUES (o, 9, 'partial_fulfilment', 'sneaky', (SELECT u_wo FROM zz.pf), 1, 1, 0, gen_random_uuid());
    PERFORM zz.check('the database itself allows only one open proposal per order', FALSE, 'second open row inserted');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('the database itself allows only one open proposal per order', TRUE);
  END;
END $$;

-- 3. While a proposal is open the order cannot be dispatched.
DO $$
DECLARE o UUID := zz.ord('A');
BEGIN
  UPDATE public.orders SET status = 'picking' WHERE id = o;
  UPDATE public.orders SET status = 'packed' WHERE id = o;
  PERFORM zz.check('preparation can continue while the proposal is open (accepted -> picking -> packed)', (SELECT status::text = 'packed' FROM public.orders WHERE id = o));
  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = o;
  BEGIN
    UPDATE public.orders SET status = 'dispatched' WHERE id = o;
    PERFORM zz.check('dispatch is blocked while a proposal awaits the pharmacy', FALSE, 'dispatch allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('dispatch is blocked while a proposal awaits the pharmacy', SQLERRM LIKE 'This order has a proposed supply change awaiting%', SQLERRM);
  END;
  PERFORM zz.check('and the order stays where it was', (SELECT status::text = 'ready_for_dispatch' FROM public.orders WHERE id = o));
END $$;

-- 4. Reading the proposal.
DO $$
DECLARE o UUID := zz.ord('A'); w JSONB; p JSONB; r TEXT;
BEGIN
  w := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.get_order_amendments(%L)::text', o))::jsonb;
  p := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.get_order_amendments(%L)::text', o))::jsonb;
  PERFORM zz.check('the wholesaler sees the proposal, its lines, stock treatment and stock mode',
    w->'amendments'->0->>'status' = 'proposed' AND jsonb_array_length(w->'amendments'->0->'lines') = 3
    AND w->'amendments'->0->>'stock_mode' = 'evidence' AND (w->>'stock_evidence')::boolean
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(w->'amendments'->0->'lines') l WHERE l->>'stock_treatment' = 'write_off'), w::text);
  PERFORM zz.check('the pharmacy sees the same proposal but not the wholesaler''s stock treatment',
    p->'amendments'->0->>'status' = 'proposed' AND jsonb_array_length(p->'amendments'->0->'lines') = 3
    AND p->'amendments'->0->>'stock_mode' IS NULL AND p->>'stock_evidence' IS NULL
    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p->'amendments'->0->'lines') l WHERE l->>'stock_treatment' IS NOT NULL), p::text);
  PERFORM zz.check('originals are preserved: original total 2100, current total 2100 until accepted',
    (w->>'original_total')::numeric = 2100 AND (w->>'current_total')::numeric = 2100 AND (w->>'amended')::boolean = FALSE);
  PERFORM zz.check('the proposer is shown by email to the wholesaler and by business name to the pharmacy',
    w->'amendments'->0->>'proposed_by_label' = 'ww@zz.test' AND p->'amendments'->0->>'proposed_by_label' = 'Alpha Wholesale');
  PERFORM zz.check('the open proposal is reported', (w->>'open_amendment_id')::uuid = (SELECT id FROM zz.pf_ids WHERE label = 'a1'));
  FOR r IN SELECT unnest(ARRAY['px', 'wx']) LOOP
    PERFORM zz.check('an unrelated ' || CASE r WHEN 'px' THEN 'pharmacy' ELSE 'wholesaler' END || ' cannot read the proposal',
      zz.val_as(CASE r WHEN 'px' THEN (SELECT u_px FROM zz.pf) ELSE (SELECT u_wx FROM zz.pf) END, format('SELECT public.get_order_amendments(%L)::text', o)) LIKE 'ERR: You do not have access to this order.%');
  END LOOP;
  PERFORM zz.check('a platform admin can read it', zz.val_as((SELECT u_admin FROM zz.pf), format('SELECT public.get_order_amendments(%L)::text', o)) NOT LIKE 'ERR%');
  PERFORM zz.check('the supply summary reports the open proposal and the lines',
    zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT (SELECT has_open_amendment::text FROM public.order_supply_summary(ARRAY[%L]::uuid[]))', o)) = 'true');
  PERFORM zz.check('the supply summary is empty for an un-amended order and for outsiders',
    zz.val_as((SELECT u_po FROM zz.pf), format('SELECT count(*)::text FROM public.order_supply_summary(ARRAY[%L]::uuid[])', zz.ord('B'))) = '0'
    AND zz.val_as((SELECT u_px FROM zz.pf), format('SELECT count(*)::text FROM public.order_supply_summary(ARRAY[%L]::uuid[])', o)) = '0');
END $$;

-- 5. Responding: who may, clarification, rejection.
DO $$
DECLARE a UUID := (SELECT id FROM zz.pf_ids WHERE label = 'a1'); o UUID := zz.ord('A'); r TEXT;
BEGIN
  FOR r IN SELECT unnest(ARRAY['px', 'wo', 'pa', 'wx', 'wm']) LOOP
    PERFORM zz.check('only the pharmacy''s own order staff can respond: ' || r || ' is refused',
      zz.val_as((SELECT CASE r WHEN 'px' THEN u_px WHEN 'wo' THEN u_wo WHEN 'pa' THEN u_pa WHEN 'wx' THEN u_wx ELSE u_wm END FROM zz.pf),
        format('SELECT public.respond_to_amendment(%L, ''reject'', ''no'')::text', a)) LIKE 'ERR: You do not have permission to respond%');
  END LOOP;
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''request_clarification'', NULL)::text', a));
  PERFORM zz.check('a question needs text', r LIKE 'ERR: Write your question%', r);
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''request_clarification'', ''When will the rest arrive?'')::text', a));
  PERFORM zz.check('the pharmacy cashier can ask a question', r::jsonb->>'status' = 'clarification_requested', r);
  PERFORM zz.check('the question is recorded, the proposal is on hold, and the wholesaler''s team is told',
    (SELECT status = 'clarification_requested' FROM public.order_amendments WHERE id = a)
    AND (SELECT count(*) = 1 FROM public.order_amendment_messages WHERE amendment_id = a AND author_side = 'pharmacy')
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_clarification_requested')
    AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_wo FROM zz.pf) AND title = 'The pharmacy asked a question'));
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('the pharmacy cannot decide while its own question is unanswered', r LIKE 'ERR: You asked a question%', r);
  BEGIN
    UPDATE public.orders SET status = 'dispatched' WHERE id = o;
    PERFORM zz.check('dispatch stays blocked while the question is open', FALSE, 'dispatch allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('dispatch stays blocked while the question is open', SQLERRM LIKE 'This order has a proposed supply change awaiting%', SQLERRM);
  END;
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.answer_amendment_clarification(%L, ''x'')::text', a));
  PERFORM zz.check('the pharmacy cannot answer its own question', r LIKE 'ERR: You do not have permission to reply%', r);
  r := zz.val_as((SELECT u_wf FROM zz.pf), format('SELECT public.answer_amendment_clarification(%L, ''Next week'')::text', a));
  PERFORM zz.check('finance staff cannot reply', r LIKE 'ERR: You do not have permission to reply%', r);
  r := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.answer_amendment_clarification(%L, ''Back stock arrives next week'')::text', a));
  PERFORM zz.check('the wholesaler manager can reply', r::jsonb->>'status' = 'proposed', r);
  PERFORM zz.check('the reply is recorded and the proposal is open for decision again',
    (SELECT status = 'proposed' AND response_choice IS NULL FROM public.order_amendments WHERE id = a)
    AND (SELECT count(*) = 2 FROM public.order_amendment_messages WHERE amendment_id = a)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_po FROM zz.pf) AND title = 'The wholesaler replied'));
  r := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.answer_amendment_clarification(%L, ''again'')::text', a));
  PERFORM zz.check('a reply with no open question is refused', r LIKE 'ERR: There is no open question%', r);

  -- Reject.
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''reject'', ''We need the full quantity'')::text', a));
  PERFORM zz.check('the pharmacy can reject', r::jsonb->>'status' = 'rejected', r);
  PERFORM zz.check('rejecting leaves the order exactly as placed (total, stock, ledger, supplied quantities)',
    (SELECT effective_total_ghs IS NULL AND total_ghs = 2100 FROM public.orders WHERE id = o)
    AND zz.stock('PF A') = 981 AND zz.stock('PF B') = 470
    AND (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE order_id = o)
    AND public.order_item_supplied_qty(zz.item(o, 'PF A')) = 10 AND NOT EXISTS (SELECT 1 FROM public.order_stock_movements));
  PERFORM zz.check('the rejection is recorded with who, when and why, and the wholesaler is told',
    (SELECT status = 'rejected' AND response_choice = 'reject' AND response_note = 'We need the full quantity' AND responded_by = (SELECT u_pc FROM zz.pf) AND responded_at IS NOT NULL FROM public.order_amendments WHERE id = a)
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_rejected')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order supply change rejected' AND record_id = o AND business_id = (SELECT good FROM zz.pf))
    AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_wo FROM zz.pf) AND title = 'Supply change rejected'));
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''reject'', ''We need the full quantity'')::text', a));
  PERFORM zz.check('repeating the rejection is a no-op', r::jsonb->>'replayed' = 'true' AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_rejected'), r);
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('a rejected proposal cannot later be accepted', r LIKE 'ERR: This proposal has already been rejected.%', r);
  PERFORM zz.check('after a rejection the order can be dispatched again if nothing else is open',
    (SELECT public.order_item_supplied_qty(zz.item(o, 'PF B')) = 20));
END $$;

-- 6. A second proposal (version 2) is accepted. Order A moves to ready for dispatch first.
DO $$
DECLARE o UUID := zz.ord('A'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short on PF A and PF B'', %L::jsonb, %L)::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF B', 15, 'write_off'))::text, (SELECT id FROM zz.pf_req WHERE label = 'a2')));
  a := (r::jsonb->>'amendment_id')::uuid;
  INSERT INTO zz.pf_ids VALUES ('a2', a);
  PERFORM zz.check('a new proposal after a rejection is version 2', (SELECT version = 2 FROM public.order_amendments WHERE id = a), r);
  PERFORM zz.check('the earlier rejected proposal is preserved untouched',
    (SELECT status = 'rejected' AND proposed_total_ghs = 1550 FROM public.order_amendments WHERE id = (SELECT id FROM zz.pf_ids WHERE label = 'a1')));

  -- Accept as the pharmacy owner.
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', ''OK, cancel the rest'')::text', a));
  PERFORM zz.check('the pharmacy owner accepts and cancels the remaining quantity', r::jsonb->>'status' = 'accepted' AND r::jsonb->>'replayed' = 'false', r);
  PERFORM zz.check('the order''s effective total is 1550 and the placed total stays 2100',
    (SELECT effective_total_ghs = 1550 AND total_ghs = 2100 FROM public.orders WHERE id = o) AND public.order_effective_total(o) = 1550);
  PERFORM zz.check('supplied quantities are now 7 / 15 / 5 while ordered quantities are untouched',
    public.order_item_supplied_qty(zz.item(o, 'PF A')) = 7 AND public.order_item_supplied_qty(zz.item(o, 'PF B')) = 15 AND public.order_item_supplied_qty(zz.item(o, 'PF C')) = 5
    AND (SELECT quantity = 10 FROM public.order_items WHERE id = zz.item(o, 'PF A')));
  PERFORM zz.check('one credit note of 550 was posted for the amendment, linked to it',
    (SELECT count(*) = 1 AND sum(amount_ghs) = 550 AND bool_and(direction = 'credit' AND entry_type = 'credit_note' AND amendment_id = a) FROM public.credit_ledger_entries WHERE order_id = o AND amendment_id IS NOT NULL));
  PERFORM zz.check('the invoice entry itself is untouched (2100)', (SELECT amount_ghs = 2100 FROM public.credit_ledger_entries WHERE order_id = o AND entry_type = 'invoice'));
  PERFORM zz.check('the invoice status nets the credit note: invoice 1550, paid 0, outstanding 1550',
    (SELECT invoice_ghs = 1550 AND paid_ghs = 0 AND outstanding_ghs = 1550 FROM public.credit_invoice_status(o)));
  PERFORM zz.check('stock: PF A released 3 (981 -> 984); PF B written off 5 (still 470); PF C untouched (194)',
    zz.stock('PF A') = 984 AND zz.stock('PF B') = 470 AND zz.stock('PF C') = 194, zz.stock('PF A') || '/' || zz.stock('PF B') || '/' || zz.stock('PF C'));
  PERFORM zz.check('the release is in the inventory ledger as an order_amendment_release of +3 tied to the order and the proposal',
    (SELECT count(*) = 1 AND bool_and(quantity_delta = 3 AND quantity_before = 981 AND quantity_after = 984 AND request_id = a AND order_id = o) FROM public.inventory_movements WHERE movement_type = 'order_amendment_release' AND order_id = o));
  PERFORM zz.check('the write-off moved no stock, so it has no inventory movement, but it is recorded as an order stock movement',
    NOT EXISTS (SELECT 1 FROM public.inventory_movements WHERE order_id = o AND product_id = (SELECT pb FROM zz.pf) AND movement_type = 'order_amendment_release')
    AND (SELECT count(*) = 1 AND bool_and(quantity = 5 AND stock_effect = 0) FROM public.order_stock_movements WHERE amendment_id = a AND kind = 'shortage_write_off'));
  PERFORM zz.check('the release is also an order stock movement (+3)',
    (SELECT count(*) = 1 AND bool_and(quantity = 3 AND stock_effect = 3 AND created_by = (SELECT u_po FROM zz.pf)) FROM public.order_stock_movements WHERE amendment_id = a AND kind = 'shortage_release'));
  PERFORM zz.check('no inventory context row is left behind', NOT EXISTS (SELECT 1 FROM public.inventory_operation_context));
  PERFORM zz.check('the proposal records who accepted and when, and is final',
    (SELECT status = 'accepted' AND response_choice = 'accept_cancel_remaining' AND responded_by = (SELECT u_po FROM zz.pf) AND applied_at IS NOT NULL AND response_note = 'OK, cancel the rest' FROM public.order_amendments WHERE id = a));
  PERFORM zz.check('events and audit entries exist on both sides, and the wholesaler is told',
    (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_accepted' AND actor_side = 'pharmacy')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order supply change accepted' AND record_id = o AND business_id = (SELECT good FROM zz.pf))
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order supply change applied' AND record_id = o AND business_id = (SELECT alpha FROM zz.pf)
        AND (details->>'credit_note_ghs')::numeric = 550 AND (details->>'units_released_to_stock')::int = 3 AND (details->>'units_written_off')::int = 5)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_wo FROM zz.pf) AND title = 'Supply change accepted'));
  PERFORM zz.check('the credit ledger never appears in the order timeline details',
    NOT EXISTS (SELECT 1 FROM public.order_events WHERE order_id = o AND (details::text ILIKE '%credit_note%' OR details::text ILIKE '%ledger%')));

  -- Idempotency of the acceptance.
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', ''OK, cancel the rest'')::text', a));
  PERFORM zz.check('repeating the acceptance changes nothing (replayed)', r::jsonb->>'replayed' = 'true', r);
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('a different pharmacy user repeating it is also a no-op', r::jsonb->>'replayed' = 'true', r);
  PERFORM zz.check('no duplicate credit note, stock movement, event or inventory movement after the repeats',
    (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE amendment_id = a)
    AND (SELECT count(*) = 2 FROM public.order_stock_movements WHERE amendment_id = a)
    AND (SELECT count(*) = 1 FROM public.inventory_movements WHERE movement_type = 'order_amendment_release' AND request_id = a)
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_accepted')
    AND zz.stock('PF A') = 984);
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''reject'', NULL)::text', a));
  PERFORM zz.check('an accepted proposal cannot be rejected afterwards', r LIKE 'ERR: This proposal has already been accepted.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.withdraw_amendment(%L, NULL)::text', a));
  PERFORM zz.check('an accepted proposal cannot be withdrawn', r LIKE 'ERR: This proposal has already been accepted.%', r);

  -- The database protects the records.
  BEGIN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, amendment_id)
    SELECT alpha, good, o, 'credit_note', 'credit', 1, a FROM zz.pf;
    PERFORM zz.check('a second credit note for the same amendment is impossible', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second credit note for the same amendment is impossible', TRUE);
  END;
  BEGIN
    INSERT INTO public.order_stock_movements(order_id, amendment_id, order_item_id, product_id, wholesaler_id, kind, quantity, stock_effect)
    SELECT o, a, zz.item(o, 'PF A'), pa, alpha, 'shortage_release', 3, 3 FROM zz.pf;
    PERFORM zz.check('a second stock movement for the same line and amendment is impossible', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second stock movement for the same line and amendment is impossible', TRUE);
  END;
  BEGIN
    INSERT INTO public.inventory_movements(product_id, wholesaler_id, order_id, request_id, movement_type, quantity_delta, quantity_before, quantity_after, source_operation)
    SELECT pa, alpha, o, a, 'order_amendment_release', 1, 984, 985, 'test' FROM zz.pf;
    PERFORM zz.check('a second inventory release for the same order, product and proposal is impossible', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second inventory release for the same order, product and proposal is impossible', TRUE);
  END;
  BEGIN UPDATE public.order_amendment_lines SET supplied_qty = 9 WHERE amendment_id = a;
    PERFORM zz.check('proposal lines cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('proposal lines cannot be edited', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  BEGIN DELETE FROM public.order_stock_movements WHERE amendment_id = a;
    PERFORM zz.check('stock movements cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('stock movements cannot be deleted', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  BEGIN UPDATE public.order_amendments SET proposed_total_ghs = 1 WHERE id = a;
    PERFORM zz.check('an accepted proposal''s figures cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('an accepted proposal''s figures cannot be edited', SQLERRM LIKE 'A proposal cannot be edited after it is made%', SQLERRM); END;
  BEGIN DELETE FROM public.order_amendments WHERE id = a;
    PERFORM zz.check('a proposal cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a proposal cannot be deleted', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  PERFORM zz.check('no client can write the amendment tables directly',
    zz.val_as((SELECT u_wo FROM zz.pf), 'INSERT INTO public.order_amendments(order_id, version, kind, reason, proposed_by, original_total_ghs, proposed_total_ghs, delta_ghs, request_id) SELECT id, 99, ''partial_fulfilment'', ''x1x'', auth.uid(), 1, 1, 0, gen_random_uuid() FROM public.orders LIMIT 1') LIKE 'ERR:%'
    AND zz.val_as((SELECT u_po FROM zz.pf), 'SELECT count(*)::text FROM public.order_amendments') = '0');

  -- Dispatch now continues.
  UPDATE public.orders SET status = 'dispatched' WHERE id = o;
  PERFORM zz.check('with the proposal settled the order can be dispatched', (SELECT status::text = 'dispatched' FROM public.orders WHERE id = o));
END $$;

-- 7. A second amendment on an already-amended order (order A is dispatched, so use order D for the sequential case below);
--    here: amendment on a credit order that has a payment (order D).
DO $$
DECLARE o UUID := zz.ord('D'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wc FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Only 3 left'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 3, 'release'))::text));
  PERFORM zz.check('a wholesaler cashier can propose', r::jsonb->>'status' = 'proposed', r);
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('the credit order with a payment: totals 500 -> 300', (SELECT original_total_ghs = 500 AND proposed_total_ghs = 300 AND delta_ghs = -200 FROM public.order_amendments WHERE id = a));
  PERFORM zz.check('before acceptance the status reflects the payment: invoice 500, paid 200, outstanding 300',
    (SELECT invoice_ghs = 500 AND paid_ghs = 200 AND outstanding_ghs = 300 FROM public.credit_invoice_status(o)));
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('accepted', r::jsonb->>'status' = 'accepted', r);
  PERFORM zz.check('after acceptance: invoice 300, paid 200 (the credit note is not a payment), outstanding 100',
    (SELECT invoice_ghs = 300 AND paid_ghs = 200 AND outstanding_ghs = 100 FROM public.credit_invoice_status(o)),
    (SELECT invoice_ghs || '/' || paid_ghs || '/' || outstanding_ghs FROM public.credit_invoice_status(o)));
  PERFORM zz.check('the status is partially paid, as before, not paid', (SELECT status = 'partially_paid' FROM public.credit_invoice_status(o)));
  PERFORM zz.check('the credit exposure fell by the credit note (and no more)',
    (SELECT COALESCE(SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END), 0) = 100 FROM public.credit_ledger_entries WHERE order_id = o));
  PERFORM zz.check('stock: 2 units of PF A released for order D (the sum of all releases so far: 3 for A, 2 for D)',
    (SELECT sum(quantity) = 2 FROM public.order_stock_movements WHERE order_id = o AND kind = 'shortage_release'));
END $$;

-- 8. A cash-on-delivery order: no ledger, effective total is what is collected.
DO $$
DECLARE o UUID := zz.ord('B'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short on PF A'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 2, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('a cod amendment is accepted', r::jsonb->>'status' = 'accepted', r);
  PERFORM zz.check('cod order: effective total 700 (900 - 2 x 100), placed total 900', (SELECT effective_total_ghs = 700 AND total_ghs = 900 FROM public.orders WHERE id = o));
  PERFORM zz.check('cod order: no ledger entries at all', NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = o));
  PERFORM zz.check('cod order: stock released for PF A', EXISTS (SELECT 1 FROM public.order_stock_movements WHERE order_id = o AND kind = 'shortage_release' AND quantity = 2));
END $$;

-- 9. A cod order that is already paid cannot be amended (no refund process).
DO $$
DECLARE o UUID := zz.ord('F'); r TEXT;
BEGIN
  UPDATE public.orders SET payment_status = 'paid' WHERE id = o;
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF D', 15, 'release'))::text));
  PERFORM zz.check('an already paid non-credit order cannot be amended', r LIKE 'ERR: This order has already been paid.%', r);
  UPDATE public.orders SET payment_status = 'unpaid' WHERE id = o;
END $$;

-- 10. Legacy order (no stock evidence): financial change only, never a stock write.
DO $$
DECLARE o UUID := zz.ord('G'); r TEXT; a UUID; before_stock INT := zz.stock('PF C'); moves INT := (SELECT count(*) FROM public.inventory_movements);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Legacy shortage'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF C', 6, 'release'))::text));
  PERFORM zz.check('a legacy order can be proposed (no stock treatment needed)', r::jsonb->>'status' = 'proposed', r);
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('its stock mode is "none" and the requested treatment is forced to none',
    (SELECT stock_mode = 'none' FROM public.order_amendments WHERE id = a)
    AND (SELECT stock_treatment = 'none' AND short_qty = 4 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF C'));
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('accepted', r::jsonb->>'status' = 'accepted' AND (r::jsonb->>'units_released_to_stock')::int = 0, r);
  PERFORM zz.check('the legacy order is repriced (200 -> 120) but no stock is written and no inventory movement is recorded',
    (SELECT effective_total_ghs = 120 FROM public.orders WHERE id = o) AND zz.stock('PF C') = before_stock
    AND (SELECT count(*) FROM public.inventory_movements) = moves AND NOT EXISTS (SELECT 1 FROM public.order_stock_movements WHERE order_id = o));
END $$;

-- 11. Batches: shortage on a batched, picked order. Order E: 30 units picked FEFO (20 early + 10 late), 8 released.
DO $$
DECLARE o UUID := zz.ord('E'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.confirm_order_picks(%L)::text', o));
  PERFORM zz.check('picks confirmed for order E: 30 units allocated (20 early, 10 late)',
    (SELECT sum(quantity) = 30 FROM public.order_batch_allocations WHERE order_id = o)
    AND (SELECT quantity_on_hand = 0 FROM public.product_batches WHERE batch_number = 'B-EARLY') AND (SELECT quantity_on_hand = 90 FROM public.product_batches WHERE batch_number = 'B-LATE'), r);
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Damaged in store'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF D', 22, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('picks can still be suggested while a proposal is open (original quantity until accepted)',
    zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT (SELECT quantity_needed::text FROM public.suggest_order_picks(%L))', o)) = '30');
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('accepted: 8 units released to stock (250 -> 258)', r::jsonb->>'status' = 'accepted' AND zz.stock('PF D') = 258, zz.stock('PF D')::text);
  PERFORM zz.check('batches reconciled: the 8 units come off the LATEST-expiring allocation (late 10 -> 2) and go back to that batch (90 -> 98)',
    (SELECT sum(a2.quantity) = 22 FROM public.order_batch_allocations a2 WHERE a2.order_id = o)
    AND (SELECT a2.quantity = 2 FROM public.order_batch_allocations a2 JOIN public.product_batches b ON b.id = a2.batch_id WHERE a2.order_id = o AND b.batch_number = 'B-LATE')
    AND (SELECT a2.quantity = 20 FROM public.order_batch_allocations a2 JOIN public.product_batches b ON b.id = a2.batch_id WHERE a2.order_id = o AND b.batch_number = 'B-EARLY')
    AND (SELECT quantity_on_hand = 98 FROM public.product_batches WHERE batch_number = 'B-LATE')
    AND (SELECT quantity_on_hand = 0 FROM public.product_batches WHERE batch_number = 'B-EARLY'));
  PERFORM zz.check('a batch movement "released" of 8 is recorded for the order',
    (SELECT count(*) = 1 AND sum(quantity) = 8 FROM public.batch_movements WHERE order_id = o AND kind = 'released'));
  PERFORM zz.check('suggested picks now use the supplied quantity (22), and re-confirming allocates 22, not 30',
    zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT (SELECT quantity_needed::text FROM public.suggest_order_picks(%L))', o)) = '22');
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.confirm_order_picks(%L)::text', o));
  PERFORM zz.check('re-confirmed picks allocate exactly 22 units', (SELECT sum(quantity) = 22 FROM public.order_batch_allocations WHERE order_id = o), r);
  PERFORM zz.check('batch totals still add up (early 0 + late 98 + 22 allocated = 120 received)',
    (SELECT sum(quantity_on_hand) FROM public.product_batches) = 98 AND (SELECT sum(quantity_on_hand) + 22 = 120 FROM public.product_batches));
END $$;

-- 12. Batches with a write-off shortage (units do not exist): the batch stays reduced and a write-off is logged. Order F, warehouse proposes.
DO $$
DECLARE o UUID := zz.ord('F'); r TEXT; a UUID; early_before INT; late_before INT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.confirm_order_picks(%L)::text', o));
  SELECT quantity_on_hand INTO late_before FROM public.product_batches WHERE batch_number = 'B-LATE';
  r := zz.val_as((SELECT u_ww FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Units missing at count'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF D', 15, 'write_off'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('accepted; nothing returned to stock (258 stays 258)', r::jsonb->>'status' = 'accepted' AND zz.stock('PF D') = 258 AND (r::jsonb->>'units_written_off')::int = 5, zz.stock('PF D')::text || ' ' || r);
  PERFORM zz.check('the allocation shrinks to 15 but the batch is not credited back (written-off units do not exist)',
    (SELECT sum(quantity) = 15 FROM public.order_batch_allocations WHERE order_id = o)
    AND (SELECT quantity_on_hand = late_before FROM public.product_batches WHERE batch_number = 'B-LATE'));
  PERFORM zz.check('a batch write-off movement of 5 records it', (SELECT count(*) = 1 AND sum(quantity) = 5 FROM public.batch_movements WHERE order_id = o AND kind = 'write_off'));
END $$;

-- 13. Withdrawing.
DO $$
DECLARE o UUID := zz.ord('B'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short on PF B'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF B', 8, 'write_off'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('a second proposal on an already-amended order is based on what is currently committed (v2, prior 10)',
    (SELECT version = 2 FROM public.order_amendments WHERE id = a) AND (SELECT prior_supplied_qty = 10 AND supplied_qty = 8 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF B'));
  PERFORM zz.check('and starts from the current effective total (700)', (SELECT original_total_ghs = 700 AND proposed_total_ghs = 600 FROM public.order_amendments WHERE id = a));
  FOR r IN SELECT unnest(ARRAY['po', 'pc', 'wf', 'wx']) LOOP
    PERFORM zz.check('withdrawal is only for the wholesaler''s order staff: ' || r || ' is refused',
      zz.val_as((SELECT CASE r WHEN 'po' THEN u_po WHEN 'pc' THEN u_pc WHEN 'wf' THEN u_wf ELSE u_wx END FROM zz.pf), format('SELECT public.withdraw_amendment(%L, NULL)::text', a)) LIKE 'ERR: You do not have permission to withdraw%');
  END LOOP;
  r := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.withdraw_amendment(%L, ''Found the stock'')::text', a));
  PERFORM zz.check('a wholesaler manager can withdraw', r::jsonb->>'status' = 'withdrawn' AND r::jsonb->>'replayed' = 'false', r);
  PERFORM zz.check('withdrawing changes nothing about the order', (SELECT effective_total_ghs = 700 FROM public.orders WHERE id = o) AND public.order_item_supplied_qty(zz.item(o, 'PF B')) = 10);
  PERFORM zz.check('the pharmacy is told and the event is logged',
    EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND user_id = (SELECT u_po FROM zz.pf) AND title = 'Supply change withdrawn')
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_withdrawn' AND actor_side = 'wholesaler'));
  r := zz.val_as((SELECT u_wm FROM zz.pf), format('SELECT public.withdraw_amendment(%L, NULL)::text', a));
  PERFORM zz.check('withdrawing twice is a no-op', r::jsonb->>'replayed' = 'true', r);
  r := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('a withdrawn proposal cannot be accepted', r LIKE 'ERR: This proposal has already been withdrawn.%', r);
END $$;

-- 14. Cancelling an order closes its open proposal. Order H is pending; use a fresh accepted order C.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 4, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset c_
INSERT INTO zz.pf_orders SELECT 'C', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('C');
DO $$
DECLARE o UUID := zz.ord('C'); r TEXT; a UUID; c_before INT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF C', 1, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  c_before := zz.stock('PF C');
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'changed mind' WHERE id = o;
  PERFORM zz.check('cancelling the order closes its open proposal (withdrawn, order_cancelled)',
    (SELECT status = 'withdrawn' AND response_choice = 'order_cancelled' FROM public.order_amendments WHERE id = a)
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'amendment_withdrawn' AND actor_side = 'system'));
  PERFORM zz.check('and the cancellation restored the full original 4 units (nothing was released or written off)', zz.stock('PF C') = c_before + 4, zz.stock('PF C')::text);
END $$;

-- 15. Cancelling an amended order restores only what is still deducted, once.
--     Order E (released 8 of 30) and F (written off 5 of 20) are cod orders still accepted: cancel both.
DO $$
DECLARE stock_before INT := zz.stock('PF D'); r TEXT;
BEGIN
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = zz.ord('E');
  PERFORM zz.check('cancelling order E restores only the 22 units still deducted (258 -> 280), not the original 30',
    zz.stock('PF D') = stock_before + 22, zz.stock('PF D')::text);
  PERFORM zz.check('the restore movement is +22', (SELECT count(*) = 1 AND bool_and(quantity_delta = 22) FROM public.inventory_movements WHERE order_id = zz.ord('E') AND movement_type = 'order_cancellation_restore'));
  PERFORM zz.check('the evidence row is stamped restored exactly once', (SELECT restored_at IS NOT NULL FROM public.order_stock_deductions WHERE order_id = zz.ord('E')));
  stock_before := zz.stock('PF D');
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = zz.ord('F');
  PERFORM zz.check('cancelling order F restores only the 15 units that exist (write-off: the 5 never come back)', zz.stock('PF D') = stock_before + 15, zz.stock('PF D')::text);
  PERFORM zz.check('batch units of both cancelled orders are released again (no allocations left)',
    NOT EXISTS (SELECT 1 FROM public.order_batch_allocations WHERE order_id IN (zz.ord('E'), zz.ord('F'))));
END $$;

-- 16. Cancelling the credit order D: the cancellation credit is only what is still outstanding after the amendment (not the original total).
DO $$
DECLARE o UUID := zz.ord('D');
BEGIN
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = o;
  PERFORM zz.check('cancelling the amended credit order credits only the net charges: invoice 500 - amendment 200 = 300 (payment of 200 stays as account credit)',
    (SELECT amount_ghs = 300 FROM public.credit_ledger_entries WHERE order_id = o AND cancellation_order_id = o));
  PERFORM zz.check('the order ledger nets to the payment held on account: debits 500, credits 200 + 200 + 300 = 700 (net -200)',
    (SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) = -200 FROM public.credit_ledger_entries WHERE order_id = o));
  PERFORM zz.check('stock for order D: PF A restored only what was still deducted (3 of the original 5)',
    (SELECT quantity_delta = 3 FROM public.inventory_movements WHERE order_id = o AND movement_type = 'order_cancellation_restore'));
END $$;

-- 17. A second amendment on order A is not possible once dispatched; cancelling a dispatched order is not offered. Order A's ledger is correct.
DO $$
DECLARE o UUID := zz.ord('A'); r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Too late'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF C', 3, 'release'))::text));
  PERFORM zz.check('after dispatch no further supply change can be proposed', r LIKE 'ERR: Supply can only be changed while the order is being prepared%', r);
  PERFORM zz.check('order A: invoice 2100, one credit note 550; effective total 1550',
    (SELECT count(*) FILTER (WHERE entry_type = 'invoice') = 1 AND count(*) FILTER (WHERE entry_type = 'credit_note') = 1 FROM public.credit_ledger_entries WHERE order_id = o)
    AND public.order_effective_total(o) = 1550);
END $$;

-- 18. Two-step amendment on an order that is still being prepared (order I): both amendments net correctly, then a cancellation restores the rest.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 10, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pb FROM zz.pf), 'quantity', 20, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'credit')) AS r \gset i_
INSERT INTO zz.pf_orders SELECT 'I', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('I');
CREATE TABLE zz.pf_stock0 AS SELECT zz.stock('PF A') pa, zz.stock('PF B') pb, zz.stock('PF C') pc;
DO $$
DECLARE o UUID := zz.ord('I'); r TEXT; a UUID;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''First shortage'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF B', 15, 'write_off'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Second shortage'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF C', 3, 'release'), zz.line(o, 'PF A', 6, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('second amendment: prior supplied quantities reflect the first (PF A prior 7)',
    (SELECT prior_supplied_qty = 7 AND supplied_qty = 6 AND short_qty = 1 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'PF A')
    AND (SELECT original_total_ghs = 1550 AND proposed_total_ghs = 1410 AND version = 2 FROM public.order_amendments WHERE id = a), r);
  r := zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  PERFORM zz.check('both amendments applied: effective total 1410, supplied 6 / 15 / 3',
    (SELECT effective_total_ghs = 1410 FROM public.orders WHERE id = o) AND public.order_item_supplied_qty(zz.item(o, 'PF A')) = 6
    AND public.order_item_supplied_qty(zz.item(o, 'PF B')) = 15 AND public.order_item_supplied_qty(zz.item(o, 'PF C')) = 3, r);
  PERFORM zz.check('two credit notes (550 + 140) and an invoice status of 1410 with nothing paid',
    (SELECT count(*) = 2 AND sum(amount_ghs) = 690 FROM public.credit_ledger_entries WHERE order_id = o AND entry_type = 'credit_note')
    AND (SELECT invoice_ghs = 1410 AND paid_ghs = 0 AND outstanding_ghs = 1410 FROM public.credit_invoice_status(o)));
  PERFORM zz.check('stock released so far: PF A +3 +1, PF C +2; PF B written off',
    zz.stock('PF A') = (SELECT pa FROM zz.pf_stock0) + 4 AND zz.stock('PF C') = (SELECT pc FROM zz.pf_stock0) + 2 AND zz.stock('PF B') = (SELECT pb FROM zz.pf_stock0));
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = o;
  PERFORM zz.check('cancelling restores only what is still deducted: PF A back to start+10-... i.e. +6 more, PF C +3 more, PF B +15 more',
    zz.stock('PF A') = (SELECT pa FROM zz.pf_stock0) + 10 AND zz.stock('PF C') = (SELECT pc FROM zz.pf_stock0) + 5
    AND zz.stock('PF B') = (SELECT pb FROM zz.pf_stock0) + 15,
    zz.stock('PF A') || '/' || zz.stock('PF B') || '/' || zz.stock('PF C'));
  PERFORM zz.check('the cancellation credit is the net charge (1410): the order ledger nets to zero',
    (SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) = 0 FROM public.credit_ledger_entries WHERE order_id = o)
    AND (SELECT amount_ghs = 1410 FROM public.credit_ledger_entries WHERE order_id = o AND cancellation_order_id = o));
END $$;

-- 19. Reminder after 24 hours (once).
DO $$
DECLARE o UUID := zz.ord('B'); r TEXT; a UUID; n INT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short again'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF B', 9, 'write_off'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  n := public.send_amendment_reminders();
  PERFORM zz.check('no reminder for a fresh proposal', n = 0 AND (SELECT reminder_sent_at IS NULL FROM public.order_amendments WHERE id = a));
  ALTER TABLE public.order_amendments DISABLE TRIGGER trg_order_amendments_protect;
  UPDATE public.order_amendments SET proposed_at = now() - interval '25 hours' WHERE id = a;
  ALTER TABLE public.order_amendments ENABLE TRIGGER trg_order_amendments_protect;
  n := public.send_amendment_reminders();
  PERFORM zz.check('a reminder is sent once after 24 hours', n = 1 AND (SELECT reminder_sent_at IS NOT NULL FROM public.order_amendments WHERE id = a)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND title = 'Still waiting for your decision' AND user_id = (SELECT u_po FROM zz.pf)));
  n := public.send_amendment_reminders();
  PERFORM zz.check('and not again', n = 0);
  PERFORM zz.check('the reminder function is not callable by users', zz.val_as((SELECT u_po FROM zz.pf), 'SELECT public.send_amendment_reminders()::text') LIKE 'ERR:%');
  PERFORM zz.check('a proposal never expires by itself: it is still open', (SELECT status = 'proposed' FROM public.order_amendments WHERE id = a));
END $$;

-- 20. The timeline tells the whole story to both sides.
DO $$
DECLARE o UUID := zz.ord('A'); w TEXT; p TEXT;
BEGIN
  w := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT string_agg(event_type, '','' ORDER BY at, event_type) FROM public.order_timeline(%L) WHERE source = ''event''', o));
  p := zz.val_as((SELECT u_pc FROM zz.pf), format('SELECT string_agg(event_type, '','' ORDER BY at, event_type) FROM public.order_timeline(%L) WHERE source = ''event''', o));
  PERFORM zz.check('the timeline shows proposal, question, reply, rejection, new proposal and acceptance to both sides',
    w LIKE '%amendment_proposed%amendment_clarification_requested%amendment_clarification_answered%amendment_rejected%amendment_proposed%amendment_accepted%' AND w = p, w);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
