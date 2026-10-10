-- Order amendments, Phase 3: back-orders and shipments (credit orders), against production-like rules.
-- Run after setup.sql + migrations (through 20261102120000_order_backorders_workflow.sql), with the production guard and stock
-- fixtures installed and the checkout compatibility migration (20261017110000) re-applied.
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

-- 0. Starting point.
DO $$
BEGIN
  PERFORM zz.check('checkout deducted stock: BO A 990, BO B 480, BO C 400-10-5-6=379',
    zz.stock('BO A') = 990 AND zz.stock('BO B') = 480 AND zz.stock('BO C') = 379, zz.stock('BO A') || '/' || zz.stock('BO B') || '/' || zz.stock('BO C'));
  PERFORM zz.check('no back-order exists yet', public.order_backorder_state(zz.ord('X'))->>'status' = 'none');
END $$;

-- 1. Accepting with a back-order.
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; a UUID;
BEGIN
  -- (A cash order may take the back-order choice too: see cash-backorders.sql.)

  -- The credit order X: BO A 10 -> 7 (write off 3: the units are not here yet), BO B 20 -> 12 (release 8: the units exist).
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.propose_partial_fulfilment(%L, ''Supplier short'', %L::jsonb, gen_random_uuid())::text', x,
    jsonb_build_array(zz.line(x, 'BO A', 7, 'write_off'), zz.line(x, 'BO B', 12, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  INSERT INTO zz.bo_ids VALUES ('x1', a);
  r := zz.val_as((SELECT u_pc FROM zz.bo), format('SELECT public.respond_to_amendment(%L, ''accept_backorder'', ''send the rest when you can'')::text', a));
  PERFORM zz.check('the pharmacy cashier accepts with a back-order', r::jsonb->>'status' = 'accepted', r);
  PERFORM zz.check('the proposal records the back-order choice', (SELECT response_choice = 'accept_backorder' AND status = 'accepted' FROM public.order_amendments WHERE id = a));
  PERFORM zz.check('the order total is now 1300 (placed 2000); the placed total is untouched', (SELECT effective_total_ghs = 1300 AND total_ghs = 2000 FROM public.orders WHERE id = x));
  PERFORM zz.check('one credit note of 700 removes the back-ordered goods from the invoice',
    (SELECT count(*) = 1 AND sum(amount_ghs) = 700 FROM public.credit_ledger_entries WHERE amendment_id = a AND entry_type = 'credit_note')
    AND (SELECT invoice_ghs = 1300 AND outstanding_ghs = 1300 FROM public.credit_invoice_status(x)));
  PERFORM zz.check('stock follows the per-line choice: BO A written off (990 stays), BO B released (480 -> 488)', zz.stock('BO A') = 990 AND zz.stock('BO B') = 488, zz.stock('BO A') || '/' || zz.stock('BO B'));
  PERFORM zz.check('main shipment quantities are 7 and 12; 3 and 8 are back-ordered',
    public.order_item_supplied_qty(zz.item(x, 'BO A')) = 7 AND public.order_item_supplied_qty(zz.item(x, 'BO B')) = 12
    AND public.order_item_backordered_qty(zz.item(x, 'BO A')) = 3 AND public.order_item_backordered_qty(zz.item(x, 'BO B')) = 8);
  PERFORM zz.check('the back-order is open with 11 units outstanding, none planned or sent',
    (public.order_backorder_state(x)->>'status') = 'open' AND (public.order_backorder_state(x)->>'outstanding')::int = 11 AND (public.order_backorder_state(x)->>'sent')::int = 0);
  PERFORM zz.check('the event says the rest is on back-order', EXISTS (SELECT 1 FROM public.order_events WHERE order_id = x AND event_type = 'amendment_accepted' AND summary LIKE '%back-order%'));

  -- A back-order shipment needs the main shipment to have gone out.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', x, jsonb_build_array(zz.sl(x, 'BO A', 1))::text));
  PERFORM zz.check('no shipment can be prepared before the main shipment is dispatched', r LIKE 'ERR: The main shipment must be dispatched%', r);
END $$;

-- 2. Main shipment goes out; preparing back-order shipments.
SELECT zz.go(zz.ord('X'), 'dispatched');
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; u RECORD; req UUID := gen_random_uuid(); s2 UUID; s3 UUID; tmpl TEXT;
BEGIN
  tmpl := 'SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text';
  FOR u IN SELECT * FROM (VALUES ('the pharmacy owner', (SELECT u_po FROM zz.bo)), ('a pharmacy cashier', (SELECT u_pc FROM zz.bo)), ('another wholesaler', (SELECT u_wx FROM zz.bo)),
      ('finance staff', (SELECT u_wf FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 1))::text));
    PERFORM zz.check(u.label || ' cannot prepare a shipment', r LIKE 'ERR: You do not have permission to prepare a shipment%', r);
  END LOOP;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, '[]'));
  PERFORM zz.check('an empty shipment is refused', r LIKE 'ERR: Choose what goes in this shipment.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 4))::text));
  PERFORM zz.check('more than is outstanding is refused (3 of BO A)', r LIKE 'ERR: Only 3 unit(s) of BO A are waiting to be shipped.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 0))::text));
  PERFORM zz.check('a zero quantity is refused', r LIKE 'ERR: The quantity for BO A must be a whole number above zero.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 1), zz.sl(x, 'BO A', 1))::text));
  PERFORM zz.check('the same product twice is refused', r LIKE 'ERR: Each product can appear only once.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(jsonb_build_object('order_item_id', gen_random_uuid(), 'quantity', 1))::text));
  PERFORM zz.check('a line from another order is refused', r LIKE 'ERR: A line does not belong to this order.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, zz.ord('Y'), jsonb_build_array(zz.sl(zz.ord('Y'), 'BO C', 1))::text));
  PERFORM zz.check('an order with no back-order has nothing to ship', r LIKE 'ERR:%', r);

  -- Shipment 2: BO A 2 + BO B 3 = 350, prepared by the warehouse user.
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, ''first part'', %L)::text', x, jsonb_build_array(zz.sl(x, 'BO A', 2), zz.sl(x, 'BO B', 3))::text, req));
  PERFORM zz.check('a warehouse user prepares shipment 2 (350)', r::jsonb->>'status' = 'pending' AND (r::jsonb->>'sequence')::int = 2 AND (r::jsonb->>'amount')::numeric = 350, r);
  s2 := (r::jsonb->>'shipment_id')::uuid; INSERT INTO zz.bo_ids VALUES ('s2', s2);
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, ''first part'', %L)::text', x, jsonb_build_array(zz.sl(x, 'BO A', 2), zz.sl(x, 'BO B', 3))::text, req));
  PERFORM zz.check('repeating the same request returns the same shipment (replayed)', r::jsonb->>'replayed' = 'true' AND (r::jsonb->>'shipment_id')::uuid = s2
    AND (SELECT count(*) = 1 FROM public.order_shipments WHERE order_id = x), r);
  PERFORM zz.check('preparing a shipment moves nothing: no ledger entry, no stock change, same total',
    (SELECT count(*) = 2 FROM public.credit_ledger_entries WHERE order_id = x) AND zz.stock('BO A') = 990 AND (SELECT effective_total_ghs = 1300 FROM public.orders WHERE id = x));
  PERFORM zz.check('outstanding is reduced for the units in the shipment (BO A 1, BO B 5)',
    public.order_item_backorder_outstanding(zz.item(x, 'BO A')) = 1 AND public.order_item_backorder_outstanding(zz.item(x, 'BO B')) = 5);
  -- Shipment 3 takes the rest.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 1), zz.sl(x, 'BO B', 5))::text));
  s3 := (r::jsonb->>'shipment_id')::uuid; INSERT INTO zz.bo_ids VALUES ('s3', s3);
  PERFORM zz.check('shipment 3 takes the rest (350, sequence 3)', (r::jsonb->>'sequence')::int = 3 AND (r::jsonb->>'amount')::numeric = 350, r);
  PERFORM zz.check('nothing is left to put in a shipment', public.order_item_backorder_outstanding(zz.item(x, 'BO A')) = 0 AND public.order_item_backorder_outstanding(zz.item(x, 'BO B')) = 0);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 1))::text));
  PERFORM zz.check('so another shipment is refused', r LIKE 'ERR: Only 0 unit(s) of BO A are waiting to be shipped.%', r);
  PERFORM zz.check('the database allows each shipment number once', (SELECT count(*) = 2 FROM public.order_shipments WHERE order_id = x AND sequence IN (2, 3)));

  -- A pending shipment can be cancelled and its units go back; a cancelled one cannot be dispatched.
  r := zz.val_as((SELECT u_wf FROM zz.bo), format('SELECT public.cancel_backorder_shipment(%L, ''changed plan'')::text', s3));
  PERFORM zz.check('finance staff cannot cancel a shipment', r LIKE 'ERR: You do not have permission to cancel this shipment.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.cancel_backorder_shipment(%L, '' '')::text', s3));
  PERFORM zz.check('cancelling needs a reason', r LIKE 'ERR: Give a reason%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.cancel_backorder_shipment(%L, ''changed plan'')::text', s3));
  PERFORM zz.check('the wholesaler cancels shipment 3 before dispatch', r::jsonb->>'status' = 'cancelled', r);
  PERFORM zz.check('its units are waiting to be shipped again (BO A 1, BO B 5)', public.order_item_backorder_outstanding(zz.item(x, 'BO A')) = 1 AND public.order_item_backorder_outstanding(zz.item(x, 'BO B')) = 5);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s3));
  PERFORM zz.check('a cancelled shipment cannot be packed or dispatched', r LIKE 'ERR: This shipment was cancelled.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.cancel_backorder_shipment(%L, ''again'')::text', s3));
  PERFORM zz.check('cancelling twice is a no-op', r::jsonb->>'replayed' = 'true', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format(tmpl, x, jsonb_build_array(zz.sl(x, 'BO A', 1), zz.sl(x, 'BO B', 5))::text));
  s3 := (r::jsonb->>'shipment_id')::uuid; INSERT INTO zz.bo_ids VALUES ('s3b', s3);
  PERFORM zz.check('a new shipment takes the same units (sequence 4)', (r::jsonb->>'sequence')::int = 4, r);
END $$;

-- 3. Status machine and permissions.
DO $$
DECLARE s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's2'); r TEXT; u RECORD;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('a shipment must be packed before it is dispatched', r LIKE 'ERR: A shipment that is pending cannot move to dispatched.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s2));
  PERFORM zz.check('and cannot be delivered before it is dispatched', r LIKE 'ERR: A shipment that is pending cannot move to delivered.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''shipped'')::text', s2));
  PERFORM zz.check('an unknown step is refused', r LIKE 'ERR: Unsupported shipment step.%', r);
  FOR u IN SELECT * FROM (VALUES ('the pharmacy owner', (SELECT u_po FROM zz.bo)), ('another wholesaler', (SELECT u_wx FROM zz.bo)), ('finance staff', (SELECT u_wf FROM zz.bo))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s2));
    PERFORM zz.check(u.label || ' cannot pack a shipment', r LIKE 'ERR: You do not have permission to update this shipment.%', r);
  END LOOP;
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s2));
  PERFORM zz.check('the warehouse user packs it', r::jsonb->>'status' = 'packed', r);
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s2));
  PERFORM zz.check('packing twice is a no-op', r::jsonb->>'replayed' = 'true', r);
END $$;

-- 4. Dispatch: the credit limit is re-checked, a one-time override can cover it, stock must be there.
DO $$
DECLARE x UUID := zz.ord('X'); s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's2'); r TEXT; exposure NUMERIC; stock_a INT;
BEGIN
  exposure := public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo));
  -- Credit line exactly full.
  UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = exposure WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('dispatch is refused when it would take the customer over its credit limit',
    r LIKE 'ERR: Dispatching this shipment (GHS 350.00) would take the customer above its credit limit%', r);
  PERFORM zz.check('and the refusal changed nothing (no invoice entry, no stock, still packed)',
    (SELECT status = 'packed' FROM public.order_shipments WHERE id = s2) AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE shipment_id = s2) AND zz.stock('BO A') = 990);
  -- A suspended or blocked line refuses too, even with room.
  UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = 1000000, status = 'suspended' WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('a suspended credit line refuses the dispatch', r LIKE 'ERR: Credit for this customer is suspended.%', r);
  UPDATE public.wholesaler_credit_terms SET status = 'blocked' WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('a blocked credit line refuses the dispatch', r LIKE 'ERR: Credit for this customer is blocked.%', r);
  UPDATE public.wholesaler_credit_terms SET status = 'active', active = false WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('a closed credit line refuses the dispatch', r LIKE 'ERR: Credit is closed for this customer%', r);
  UPDATE public.wholesaler_credit_terms SET active = true, credit_limit_ghs = exposure WHERE wholesaler_id = (SELECT alpha FROM zz.bo);

  -- The wholesaler approves a one-time override big enough for one shipment.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.grant_credit_override(%L, %L, 400, 7, ''Back-order shipment approved'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)));
  PERFORM zz.check('an override is granted', r NOT LIKE 'ERR%', r);

  -- Not enough stock at that moment.
  UPDATE public.products SET stock = 1 WHERE name = 'BO A';
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('dispatch needs the stock: 1 in stock, 2 needed', r LIKE 'ERR: Not enough stock of BO A to dispatch this shipment (1 in stock, 2 needed)%', r);
  PERFORM zz.check('and a refused dispatch does not consume the override', EXISTS (SELECT 1 FROM public.credit_overrides WHERE status = 'active'));
  UPDATE public.products SET stock = 990 WHERE name = 'BO A';

  -- Dispatch by the warehouse user.
  stock_a := zz.stock('BO A');
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('the warehouse user dispatches shipment 2 on the override', r::jsonb->>'status' = 'dispatched' AND (r::jsonb->>'amount')::numeric = 350, r);
  PERFORM zz.check('one invoice entry of 350 was posted for the shipment',
    (SELECT count(*) = 1 AND sum(amount_ghs) = 350 AND bool_and(entry_type = 'invoice' AND direction = 'debit' AND order_id = x) FROM public.credit_ledger_entries WHERE shipment_id = s2));
  PERFORM zz.check('the invoice status now shows invoice 1650 (1300 + 350) and 1650 outstanding',
    (SELECT invoice_ghs = 1650 AND outstanding_ghs >= 1650 FROM public.credit_invoice_status(x)));
  PERFORM zz.check('the order total rose by the shipment: 1650 (placed 2000, so the order is still below what was placed)', (SELECT effective_total_ghs = 1650 AND total_ghs = 2000 FROM public.orders WHERE id = x));
  PERFORM zz.check('stock was deducted once for exactly the units sent: BO A 990 -> 988, BO B 488 -> 485', zz.stock('BO A') = stock_a - 2 AND zz.stock('BO B') = 485, zz.stock('BO A') || '/' || zz.stock('BO B'));
  PERFORM zz.check('the inventory ledger has the deductions, tied to the order and the shipment',
    (SELECT count(*) = 2 AND bool_and(request_id = s2 AND order_id = x AND quantity_delta < 0) FROM public.inventory_movements WHERE movement_type = 'backorder_dispatch_deduction'));
  PERFORM zz.check('and the order stock movements record them (-2 and -3)',
    (SELECT count(*) = 2 AND sum(stock_effect) = -5 FROM public.order_stock_movements WHERE shipment_id = s2 AND kind = 'backorder_dispatch'));
  PERFORM zz.check('the override was consumed by this dispatch', (SELECT count(*) = 1 FROM public.credit_overrides WHERE status = 'used' AND used_order_id = x) AND NOT EXISTS (SELECT 1 FROM public.credit_overrides WHERE status = 'active'));
  PERFORM zz.check('the dispatch is audited (shipment, override used) and told to the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Back-order shipment dispatched' AND record_id = x AND (details->>'amount')::numeric = 350)
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit override used' AND record_id = x)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND title = 'Back-order shipment on its way'));
  PERFORM zz.check('the state is partially fulfilled (5 units sent, 6 still to come)',
    public.order_backorder_state(x)->>'status' = 'partially_fulfilled' AND (public.order_backorder_state(x)->>'sent')::int = 5, public.order_backorder_state(x)::text);
  PERFORM zz.check('the dispatch event is on the timeline for both sides',
    (SELECT count(*) = 1 FROM public.order_events WHERE order_id = x AND event_type = 'shipment_dispatched' AND shipment_id = s2));

  -- Repeats are harmless.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s2));
  PERFORM zz.check('dispatching again is a no-op (replayed)', r::jsonb->>'replayed' = 'true', r);
  PERFORM zz.check('no second invoice entry, stock deduction or order total change',
    (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE shipment_id = s2) AND zz.stock('BO A') = stock_a - 2
    AND (SELECT count(*) = 2 FROM public.inventory_movements WHERE movement_type = 'backorder_dispatch_deduction') AND (SELECT effective_total_ghs = 1650 FROM public.orders WHERE id = x));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.cancel_backorder_shipment(%L, ''too late'')::text', s2));
  PERFORM zz.check('a dispatched shipment can no longer be cancelled', r LIKE 'ERR: A shipment that is dispatched can no longer be cancelled.%', r);
  BEGIN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, shipment_id)
    SELECT alpha, good, x, 'invoice', 'debit', 1, s2 FROM zz.bo;
    PERFORM zz.check('the database allows one invoice entry per shipment', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('the database allows one invoice entry per shipment', TRUE); END;
  BEGIN
    INSERT INTO public.order_stock_movements(order_id, shipment_id, order_item_id, product_id, wholesaler_id, kind, quantity, stock_effect)
    SELECT x, s2, zz.item(x, 'BO A'), pa, alpha, 'backorder_dispatch', 2, -2 FROM zz.bo;
    PERFORM zz.check('the database allows one stock movement per shipment line', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('the database allows one stock movement per shipment line', TRUE); END;
  BEGIN
    INSERT INTO public.inventory_movements(product_id, wholesaler_id, order_id, request_id, movement_type, quantity_delta, quantity_before, quantity_after, source_operation)
    SELECT pa, alpha, x, s2, 'backorder_dispatch_deduction', -1, 988, 987, 'test' FROM zz.bo;
    PERFORM zz.check('the inventory ledger allows one deduction per order, product and shipment', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('the inventory ledger allows one deduction per order, product and shipment', TRUE); END;
END $$;

-- 5. The override is gone, so the next shipment cannot go out while the line is full; then room is made and it ships.
DO $$
DECLARE s3 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's3b'); x UUID := zz.ord('X'); r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s3));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s3));
  PERFORM zz.check('the override cannot be used twice: the next shipment is refused at the limit', r LIKE 'ERR: Dispatching this shipment (GHS 350.00) would take the customer above its credit limit%', r);
  UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = 1000000 WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s3));
  PERFORM zz.check('with room on the credit line it dispatches', r::jsonb->>'status' = 'dispatched', r);
  PERFORM zz.check('the order is now invoiced in full: 2000 (1300 + 350 + 350), the same as was placed', (SELECT effective_total_ghs = 2000 FROM public.orders WHERE id = x)
    AND (SELECT invoice_ghs = 2000 FROM public.credit_invoice_status(x)));
  PERFORM zz.check('the back-order is fulfilled', public.order_backorder_state(x)->>'status' = 'fulfilled', public.order_backorder_state(x)::text);
  PERFORM zz.check('three invoice entries exist for the order: the original and one per shipment',
    (SELECT count(*) = 3 AND count(DISTINCT shipment_id) = 2 FROM public.credit_ledger_entries WHERE order_id = x AND entry_type = 'invoice'));
END $$;

-- 6. Delivery and due dates.
DO $$
DECLARE x UUID := zz.ord('X'); s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's2'); s3 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's3b');
  r TEXT; due0 DATE; ord_due DATE;
BEGIN
  SELECT credit_due_date INTO due0 FROM public.orders WHERE id = x;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s2));
  PERFORM zz.check('shipment 2 is delivered', r::jsonb->>'status' = 'delivered', r);
  PERFORM zz.check('order-date terms: the shipment shares the order''s due date and the order''s date does not move',
    (SELECT credit_due_date = due0 FROM public.order_shipments WHERE id = s2) AND (SELECT credit_due_date = due0 FROM public.orders WHERE id = x), due0::text);
  -- Delivery-date terms, with something still owed from before: the order's due date must not move later.
  UPDATE public.orders SET credit_due_basis = 'delivery_date' WHERE id = x;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s3));
  PERFORM zz.check('shipment 3 is delivered', r::jsonb->>'status' = 'delivered', r);
  PERFORM zz.check('delivery-date terms: the shipment falls due 30 days after its delivery',
    (SELECT credit_due_date = current_date + 30 FROM public.order_shipments WHERE id = s3));
  PERFORM zz.check('but an unpaid earlier balance keeps its due date (prior outstanding was above zero)',
    (SELECT prior_outstanding_ghs > 0 FROM public.order_shipments WHERE id = s3) AND (SELECT credit_due_date = due0 FROM public.orders WHERE id = x));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s3));
  PERFORM zz.check('delivering twice is a no-op', r::jsonb->>'replayed' = 'true', r);
  PERFORM zz.check('the delivery events are logged', (SELECT count(*) = 2 FROM public.order_events WHERE order_id = x AND event_type = 'shipment_delivered'));
END $$;

-- 7. A shipment invoiced after everything else was paid starts a new due date (delivery-date terms): order W.
DO $$
DECLARE w UUID := zz.ord('W'); a UUID; r TEXT; s UUID;
BEGIN
  a := zz.amend(w, jsonb_build_array(zz.line(w, 'BO C', 2, 'write_off')), 'accept_backorder');
  PERFORM zz.go(w, 'delivered');
  PERFORM zz.check('order W: accepted with a back-order of 4 (120 -> 40)', (SELECT effective_total_ghs = 40 FROM public.orders WHERE id = w) AND (public.order_backorder_state(w)->>'outstanding')::int = 4);
  -- W is paid in full on the ledger, on delivery-date terms.
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note)
  SELECT alpha, good, w, 'payment', 'credit', 40, 'paid' FROM zz.bo;
  UPDATE public.orders SET credit_due_basis = 'delivery_date', credit_due_date = current_date - 5 WHERE id = w;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', w, jsonb_build_array(zz.sl(w, 'BO C', 3))::text));
  s := (r::jsonb->>'shipment_id')::uuid; INSERT INTO zz.bo_ids VALUES ('ws', s);
  -- The order is marked paid (as recording the payment on the ledger does); the warehouse user dispatches.
  ALTER TABLE public.orders DISABLE TRIGGER trg_mirror_legacy_credit_payment;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now() WHERE id = w;
  ALTER TABLE public.orders ENABLE TRIGGER trg_mirror_legacy_credit_payment;
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s));
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s));
  PERFORM zz.check('W: the shipment of 3 (60) is dispatched; the order was fully paid before it', r::jsonb->>'status' = 'dispatched'
    AND (SELECT prior_outstanding_ghs = 0 FROM public.order_shipments WHERE id = s), r);
  PERFORM zz.check('W: a paid order is reopened by the new charge, even when a warehouse user dispatches',
    (SELECT payment_status::text = 'unpaid' AND paid_at IS NULL AND payment_confirmed_at IS NULL FROM public.orders WHERE id = w));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s));
  PERFORM zz.check('W: after delivery the order''s due date moves to the shipment''s (30 days out), because nothing earlier was owed',
    (SELECT credit_due_date = current_date + 30 FROM public.orders WHERE id = w) AND (SELECT credit_due_date = current_date + 30 FROM public.order_shipments WHERE id = s));
  PERFORM zz.check('W: the order is owed 60 on the ledger (invoice 100 net of the credit note, plus the shipment, less the payment)',
    (SELECT outstanding_ghs = 60 FROM public.credit_invoice_status(w)), (SELECT outstanding_ghs::text FROM public.credit_invoice_status(w)));

  -- Cancel what is left (1 unit): either side may; it needs a reason, nothing is posted, nothing moves in stock.
  PERFORM zz.check('W: 1 unit is left waiting', (public.order_backorder_state(w)->>'outstanding')::int = 1);
  r := zz.val_as((SELECT u_pa FROM zz.bo), format('SELECT public.cancel_backorder_remaining(%L, ''not needed any more'')::text', w));
  PERFORM zz.check('a pharmacy assistant cannot cancel the back-order', r LIKE 'ERR: You do not have permission to cancel the back-order%', r);
  r := zz.val_as((SELECT u_px FROM zz.bo), format('SELECT public.cancel_backorder_remaining(%L, ''not needed any more'')::text', w));
  PERFORM zz.check('another pharmacy cannot', r LIKE 'ERR: You do not have permission to cancel the back-order%', r);
  r := zz.val_as((SELECT u_pc FROM zz.bo), format('SELECT public.cancel_backorder_remaining(%L, '' '')::text', w));
  PERFORM zz.check('a reason is required', r LIKE 'ERR: Give a reason%', r);
END $$;
DO $$
DECLARE w UUID := zz.ord('W'); r TEXT; stock_before INT := zz.stock('BO C'); ledger_before INT := (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = zz.ord('W'));
BEGIN
  r := zz.val_as((SELECT u_pc FROM zz.bo), format('SELECT public.cancel_backorder_remaining(%L, ''not needed any more'')::text', w));
  PERFORM zz.check('the pharmacy cashier cancels the remaining back-order (1 unit)', (r::jsonb->>'cancelled_units')::int = 1, r);
  PERFORM zz.check('the state is closed (some sent, the rest cancelled)', public.order_backorder_state(w)->>'status' = 'closed', public.order_backorder_state(w)::text);
  PERFORM zz.check('nothing was posted and no stock moved', (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = w) = ledger_before AND zz.stock('BO C') = stock_before);
  PERFORM zz.check('the wholesaler is told; the event and audit exist',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_wo FROM zz.bo) AND title = 'Back-order cancelled')
    AND (SELECT count(*) = 1 FROM public.order_events WHERE order_id = w AND event_type = 'backorder_cancelled' AND actor_side = 'pharmacy')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Back-order cancelled' AND record_id = w AND business_id = (SELECT good FROM zz.bo)));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.cancel_backorder_remaining(%L, ''again'')::text', w));
  PERFORM zz.check('cancelling again finds nothing to cancel', r LIKE 'ERR: Nothing is waiting to be shipped on this order.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', w, jsonb_build_array(zz.sl(w, 'BO C', 1))::text));
  PERFORM zz.check('and nothing more can be shipped', r LIKE 'ERR: Only 0 unit(s) of BO C are waiting to be shipped.%', r);
END $$;

-- 8. Cancelling an order that has a back-order before the main dispatch: the back-order closes and stock is restored net.
DO $$
DECLARE z UUID := zz.ord('Z'); a UUID; before_c INT; after_accept INT; ledger_sum NUMERIC;
BEGIN
  a := zz.amend(z, jsonb_build_array(zz.line(z, 'BO C', 3, 'release')), 'accept_backorder');
  after_accept := zz.stock('BO C');
  PERFORM zz.check('order Z: accepted with a back-order of 2 (100 -> 60); 2 units released to stock',
    (SELECT effective_total_ghs = 60 FROM public.orders WHERE id = z) AND (public.order_backorder_state(z)->>'outstanding')::int = 2);
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = z;
  PERFORM zz.check('cancelling the order closes the back-order by itself', public.order_backorder_state(z)->>'status' = 'cancelled'
    AND (SELECT count(*) = 1 FROM public.order_backorder_cancellations WHERE order_id = z AND cancelled_side = 'system'), public.order_backorder_state(z)::text);
  PERFORM zz.check('stock restored only for what was still deducted: 5 - 2 released = 3 more units', zz.stock('BO C') = after_accept + 3, zz.stock('BO C')::text);
  SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) INTO ledger_sum FROM public.credit_ledger_entries WHERE order_id = z;
  PERFORM zz.check('the order''s ledger nets to zero: invoice 100, credit note 40, cancellation credit 60', ledger_sum = 0, ledger_sum::text);
  PERFORM zz.check('the closing is logged', (SELECT count(*) = 1 FROM public.order_events WHERE order_id = z AND event_type = 'backorder_cancelled' AND actor_side = 'system'));
END $$;

-- 9. A legacy order (no stock evidence): shipments are invoiced but never touch stock.
DO $$
DECLARE l UUID := zz.ord('L'); a UUID; r TEXT; s UUID; stock_before INT; moves INT;
BEGIN
  a := zz.amend(l, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(l, 'BO C'), 'supplied_qty', 3)), 'accept_backorder');
  PERFORM zz.go(l, 'delivered');
  PERFORM zz.check('legacy order L: accepted with a back-order of 2 (100 -> 60)', (SELECT effective_total_ghs = 60 FROM public.orders WHERE id = l));
  stock_before := zz.stock('BO C'); moves := (SELECT count(*) FROM public.inventory_movements);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', l, jsonb_build_array(zz.sl(l, 'BO C', 2))::text));
  s := (r::jsonb->>'shipment_id')::uuid;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s));
  PERFORM zz.check('legacy order: the shipment dispatches and is invoiced (40)', r::jsonb->>'status' = 'dispatched'
    AND (SELECT count(*) = 1 AND sum(amount_ghs) = 40 FROM public.credit_ledger_entries WHERE shipment_id = s), r);
  PERFORM zz.check('but no stock is written and no inventory movement recorded', zz.stock('BO C') = stock_before AND (SELECT count(*) FROM public.inventory_movements) = moves
    AND NOT EXISTS (SELECT 1 FROM public.order_stock_movements WHERE shipment_id = s));
END $$;

-- 10. The order total cannot be edited directly, and the records are protected.
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; s2 UUID := (SELECT id FROM zz.bo_ids WHERE label = 's2');
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('UPDATE public.orders SET effective_total_ghs = 1 WHERE id = %L RETURNING id::text', x));
  PERFORM zz.check('the wholesaler owner cannot edit the order total directly', r LIKE 'ERR: The order total can only change through an approved%', r);
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('UPDATE public.orders SET effective_total_ghs = 1 WHERE id = %L RETURNING id::text', x));
  PERFORM zz.check('a cashier cannot either', r LIKE 'ERR: The order total can only change through an approved%', r);
  r := zz.val_as((SELECT u_ww FROM zz.bo), format('UPDATE public.orders SET payment_status = ''paid'' WHERE id = %L RETURNING id::text', x));
  PERFORM zz.check('warehouse staff still cannot change payment details by hand', r LIKE 'ERR: Warehouse staff cannot change payment or receipt details.%', r);
  PERFORM zz.check('the total is unchanged (2000)', (SELECT effective_total_ghs = 2000 FROM public.orders WHERE id = x));
  BEGIN UPDATE public.order_shipments SET amount_ghs = 1 WHERE id = s2;
    PERFORM zz.check('a shipment''s amount cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a shipment''s amount cannot be edited', SQLERRM LIKE 'A shipment cannot be edited%', SQLERRM); END;
  BEGIN DELETE FROM public.order_shipments WHERE id = s2;
    PERFORM zz.check('a shipment cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a shipment cannot be deleted', SQLERRM = 'Order shipment records are append-only.', SQLERRM); END;
  BEGIN UPDATE public.order_shipment_lines SET quantity = 9 WHERE shipment_id = s2;
    PERFORM zz.check('shipment lines cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('shipment lines cannot be edited', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  BEGIN UPDATE public.order_shipments SET status = 'pending' WHERE id = s2;
    PERFORM zz.check('a delivered shipment cannot be moved back', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a delivered shipment cannot be moved back', SQLERRM LIKE 'This shipment is already delivered.%', SQLERRM); END;
  BEGIN DELETE FROM public.order_backorder_cancellations;
    PERFORM zz.check('back-order cancellations cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('back-order cancellations cannot be deleted', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  PERFORM zz.check('no client can write the shipment tables directly',
    zz.val_as((SELECT u_wo FROM zz.bo), 'INSERT INTO public.order_shipments(order_id, sequence, amount_ghs, request_id, created_by) SELECT id, 9, 1, gen_random_uuid(), auth.uid() FROM public.orders LIMIT 1') LIKE 'ERR:%'
    AND zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.order_shipments') = '0');
END $$;

-- 11. Reading it back: the order's back-order picture for each side.
DO $$
DECLARE x UUID := zz.ord('X'); w JSONB; p JSONB;
BEGIN
  w := zz.j((SELECT u_wm FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', x));
  p := zz.j((SELECT u_pc FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', x));
  PERFORM zz.check('both sides see the state, the lines and every shipment with its status',
    w->'state'->>'status' = 'fulfilled' AND jsonb_array_length(w->'shipments') = 3 AND jsonb_array_length(w->'lines') = 2 AND w = p, left(w::text, 300));
  PERFORM zz.check('shipment 3 (cancelled) is kept in the history with its reason', EXISTS (SELECT 1 FROM jsonb_array_elements(w->'shipments') s WHERE s->>'status' = 'cancelled' AND s->>'cancel_reason' = 'changed plan'));
  PERFORM zz.check('lines show backordered 3 and 8, sent 3 and 8, outstanding 0',
    EXISTS (SELECT 1 FROM jsonb_array_elements(w->'lines') l WHERE l->>'product_name' = 'BO A' AND (l->>'backordered')::int = 3 AND (l->>'sent')::int = 3 AND (l->>'outstanding')::int = 0)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(w->'lines') l WHERE l->>'product_name' = 'BO B' AND (l->>'backordered')::int = 8 AND (l->>'sent')::int = 8), w->>'lines');
  PERFORM zz.check('an unrelated business cannot read it', zz.val_as((SELECT u_px FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', x)) LIKE 'ERR: You do not have access to this order.%'
    AND zz.val_as((SELECT u_wx FROM zz.bo), format('SELECT public.get_order_backorder(%L)::text', x)) LIKE 'ERR: You do not have access to this order.%');
  p := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT to_jsonb(s) FROM public.order_supply_summary(ARRAY[%L]::uuid[]) s)::text', x));
  PERFORM zz.check('the supply summary reports the current total (2000), the main shipment''s own total (1300) and the state',
    (p->>'current_total_ghs')::numeric = 2000 AND (p->>'main_total_ghs')::numeric = 1300 AND p->'backorder'->>'status' = 'fulfilled', p::text);
  PERFORM zz.check('the summary lines carry the supplied (main) and fulfilled (everything sent) quantities',
    EXISTS (SELECT 1 FROM jsonb_array_elements(p->'lines') l WHERE (l->>'supplied_qty')::int = 7 AND (l->>'fulfilled_qty')::int = 10));
END $$;

-- 12. Statement, readers and returns see the shipments.
DO $$
DECLARE w UUID := (SELECT u_wo FROM zz.bo); r JSONB; q TEXT; x UUID := zz.ord('X'); rr TEXT;
BEGIN
  q := format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo));
  r := zz.j(w, q);
  PERFORM zz.check('statement: the order stays at its placed amount, the back-ordered goods are an adjustment credit of 700, and each dispatched shipment is a 350 charge',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') l WHERE l->>'kind' = 'order' AND l->>'order_id' = x::text AND (l->>'debit')::numeric = 2000)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') l WHERE l->>'kind' = 'adjustment' AND l->>'order_id' = x::text AND (l->>'credit')::numeric = 700)
    AND (SELECT count(*) = 2 FROM jsonb_array_elements(r->'lines') l WHERE l->>'kind' = 'shipment' AND l->>'order_id' = x::text AND (l->>'debit')::numeric = 350), left(r::text, 300));
  PERFORM zz.check('statement: for order X the charges and credits add back up to the 2000 invoiced (2000 - 700 + 350 + 350)',
    (SELECT sum(CASE WHEN (l->>'debit')::numeric > 0 THEN (l->>'debit')::numeric ELSE -(l->>'credit')::numeric END) = 2000
     FROM jsonb_array_elements(r->'lines') l WHERE l->>'order_id' = x::text AND l->>'kind' IN ('order', 'adjustment', 'shipment')));
  PERFORM zz.check('the pharmacy sees the same closing balance', zz.j((SELECT u_po FROM zz.bo), q)->>'closing_balance' = r->>'closing_balance');
  PERFORM zz.check('reports: units sold count dispatched back-order units (X: 7+12+3+8 = 30)',
    (SELECT sum(public.order_item_fulfilled_qty(oi.id)) = 30 FROM public.order_items oi WHERE oi.order_id = x));
  UPDATE public.orders SET status = 'delivered' WHERE id = x;
  rr := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO A''', x));
  PERFORM zz.check('returns: BO A can be returned up to everything delivered (7 + 3 = 10)', rr = '10', rr);
END $$;

-- 13. The earlier amendment records are untouched by all this.
DO $$
BEGIN
  PERFORM zz.check('the proposal for X is still accepted and its credit note is the only amendment-linked ledger entry',
    (SELECT status = 'accepted' FROM public.order_amendments WHERE id = (SELECT id FROM zz.bo_ids WHERE label = 'x1'))
    AND (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE order_id = zz.ord('X') AND amendment_id IS NOT NULL));
  PERFORM zz.check('no inventory context row is left behind', NOT EXISTS (SELECT 1 FROM public.inventory_operation_context));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
