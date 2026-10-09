-- Order amendments, Phase 4: price amendments (the wholesaler proposes new unit prices before dispatch; only the pharmacy's approval applies them), against production-like rules.
-- Run after setup.sql + migrations (through 20261104120000_price_amendments_workflow.sql), with the production guard and stock
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


-- Extra orders for price amendments: N (cash, BO C x5 = 100) and V (credit, BO A x10 = 1000).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset n_
INSERT INTO zz.bo_orders SELECT 'N', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'credit')) AS r \gset v_
INSERT INTO zz.bo_orders SELECT 'V', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id IN (zz.ord('N'), zz.ord('V'));

-- A price line for propose_price_amendment, the call itself (as p_uid), and the pharmacy's / wholesaler's replies.
CREATE FUNCTION zz.pl(p_order UUID, p_name TEXT, p_price NUMERIC) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'unit_price_ghs', p_price) $$;
CREATE FUNCTION zz.pp(p_uid UUID, p_order UUID, p_lines JSONB, p_reason TEXT DEFAULT 'Supplier price revised', p_req UUID DEFAULT gen_random_uuid()) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.propose_price_amendment(%L, %L, %L::jsonb, %L)::text', p_order, p_reason, p_lines::text, p_req)) $$;
CREATE FUNCTION zz.pr(p_uid UUID, p_amendment UUID, p_choice TEXT, p_note TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.respond_to_price_amendment(%L, %L, %L)::text', p_amendment, p_choice, p_note)) $$;
CREATE FUNCTION zz.aid(p_order UUID, p_version INT) RETURNS UUID LANGUAGE sql AS $$
  SELECT id FROM public.order_amendments WHERE order_id = p_order AND version = p_version $$;
CREATE FUNCTION zz.price(p_order UUID, p_name TEXT) RETURNS NUMERIC LANGUAGE sql AS $$ SELECT public.order_item_effective_price(zz.item(p_order, p_name)) $$;
CREATE FUNCTION zz.entries(p_order UUID, p_type TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.credit_ledger_entries WHERE order_id = p_order AND entry_type = p_type AND amendment_id IS NOT NULL $$;

-- 0. Starting point.
DO $$
BEGIN
  PERFORM zz.check('seven orders are accepted', (SELECT count(*) = 7 FROM public.orders WHERE status = 'accepted'));
  PERFORM zz.check('before any amendment the price in force is the price as placed',
    zz.price(zz.ord('X'), 'BO A') = 100 AND zz.price(zz.ord('X'), 'BO B') = 50 AND zz.price(zz.ord('Z'), 'BO C') = 20);
END $$;

-- 1. Who may propose, and what is refused.
DO $$
DECLARE x UUID := zz.ord('X'); n UUID := zz.ord('N'); r TEXT; u RECORD;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a wholesaler cashier', (SELECT u_wc FROM zz.bo)), ('a warehouse user', (SELECT u_ww FROM zz.bo)), ('a finance user', (SELECT u_wf FROM zz.bo)),
      ('another wholesaler', (SELECT u_wx FROM zz.bo)), ('the pharmacy owner', (SELECT u_po FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.pp(u.uid, x, jsonb_build_array(zz.pl(x, 'BO A', 120)));
    PERFORM zz.check(u.label || ' cannot propose a price change', r LIKE 'ERR: Only the owner or a manager can propose a price change on an order.%', r);
  END LOOP;
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 120)), 'no');
  PERFORM zz.check('a reason is required', r LIKE 'ERR: A reason for the price change is required%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, '[]'::jsonb);
  PERFORM zz.check('at least one product is required', r LIKE 'ERR: Say which products get a new price.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(jsonb_build_object('order_item_id', gen_random_uuid(), 'unit_price_ghs', 5)));
  PERFORM zz.check('a line from another order is refused', r LIKE 'ERR: A line does not belong to this order.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 120), zz.pl(x, 'BO A', 130)));
  PERFORM zz.check('the same product twice is refused', r LIKE 'ERR: Each product can appear only once.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(x, 'BO A'), 'unit_price_ghs', 'abc')));
  PERFORM zz.check('a price that is not a number is refused', r LIKE 'ERR: Enter the new price of BO A as an amount in cedis with at most two decimals.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(x, 'BO A'), 'unit_price_ghs', 10.123)));
  PERFORM zz.check('three decimals are refused', r LIKE 'ERR: Enter the new price of BO A%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', -5)));
  PERFORM zz.check('a negative price is refused', r LIKE 'ERR: Enter the new price of BO A%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 0)));
  PERFORM zz.check('a zero price is refused', r LIKE 'ERR: The new price of BO A must be more than zero.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 100)));
  PERFORM zz.check('the same price is refused', r LIKE 'ERR: The new price of BO A is the same as its current price.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(x, 'BO A'))));
  PERFORM zz.check('a missing price is refused', r LIKE 'ERR: Enter the new price of BO A%', r);
  -- A paid cash order cannot be amended (no refunds yet).
  ALTER TABLE public.orders DISABLE TRIGGER trg_mirror_legacy_credit_payment;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now() WHERE id = n;
  ALTER TABLE public.orders ENABLE TRIGGER trg_mirror_legacy_credit_payment;
  r := zz.pp((SELECT u_wo FROM zz.bo), n, jsonb_build_array(zz.pl(n, 'BO C', 18)));
  PERFORM zz.check('a paid cash order is refused', r LIKE 'ERR: This order has already been paid.%', r);
  PERFORM zz.check('none of the refused calls created a proposal', NOT EXISTS (SELECT 1 FROM public.order_amendments));
END $$;

-- 2. X (credit, BO A x10 @100 + BO B x20 @50 = 2000): propose BO A 120, BO B 45 (+200 - 100 = +100).
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; a UUID; req UUID := gen_random_uuid(); v JSONB; ev_before INT;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 120), zz.pl(x, 'BO B', 45)), 'Supplier cost went up', req);
  PERFORM zz.check('the owner proposes new prices', r::jsonb->>'status' = 'proposed' AND (r::jsonb->>'proposed_total')::numeric = 2100 AND (r::jsonb->>'delta')::numeric = 100, r);
  a := (r::jsonb->>'amendment_id')::uuid; INSERT INTO zz.bo_ids VALUES ('x1', a);
  PERFORM zz.check('it is a price change with one line per changed product, quantities untouched, nothing applied',
    (SELECT kind = 'price_change' AND status = 'proposed' AND applied_at IS NULL AND original_total_ghs = 2000 AND proposed_total_ghs = 2100 AND stock_mode = 'none' FROM public.order_amendments WHERE id = a)
    AND (SELECT count(*) = 2 AND bool_and(short_qty = 0 AND supplied_qty = prior_supplied_qty AND stock_treatment = 'none') FROM public.order_amendment_lines WHERE amendment_id = a));
  PERFORM zz.check('each line keeps the price at the time and the proposed price',
    EXISTS (SELECT 1 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'BO A' AND unit_price_ghs = 100 AND proposed_unit_price_ghs = 120)
    AND EXISTS (SELECT 1 FROM public.order_amendment_lines WHERE amendment_id = a AND product_name = 'BO B' AND unit_price_ghs = 50 AND proposed_unit_price_ghs = 45));
  PERFORM zz.check('nothing has moved: same total, same prices, no ledger entry, no effective total',
    (SELECT effective_total_ghs IS NULL AND total_ghs = 2000 FROM public.orders WHERE id = x) AND zz.price(x, 'BO A') = 100 AND zz.price(x, 'BO B') = 50
    AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE amendment_id = a));
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 120), zz.pl(x, 'BO B', 45)), 'Supplier cost went up', req);
  PERFORM zz.check('repeating the request returns the same proposal (replayed)', r::jsonb->>'replayed' = 'true' AND (r::jsonb->>'amendment_id')::uuid = a
    AND (SELECT count(*) = 1 FROM public.order_amendments WHERE order_id = x), r);
  r := zz.pp((SELECT u_wm FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 130)));
  PERFORM zz.check('a second proposal is refused while one is open', r LIKE 'ERR: A change is already awaiting a response on this order. Withdraw it first.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.propose_partial_fulfilment(%L, ''Short'', %L::jsonb, gen_random_uuid())::text', x, jsonb_build_array(zz.line(x, 'BO A', 5, 'release'))::text));
  PERFORM zz.check('and so is a supply change', r LIKE 'ERR: A supply change is already awaiting a response on this order.%', r);
  -- No dispatch while a proposal is open.
  UPDATE public.orders SET status = 'picking' WHERE id = x;
  UPDATE public.orders SET status = 'packed' WHERE id = x;
  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = x;
  BEGIN
    UPDATE public.orders SET status = 'dispatched' WHERE id = x;
    PERFORM zz.check('the order cannot be dispatched while the proposal is open', FALSE, 'dispatched');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('the order cannot be dispatched while the proposal is open', SQLERRM LIKE 'This order has a proposed supply change awaiting%', SQLERRM);
  END;
  -- The supply-change replies refuse a price proposal.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.withdraw_amendment(%L, NULL)::text', a));
  PERFORM zz.check('the supply-change withdraw refuses a price proposal', r LIKE 'ERR: Use the price proposal actions for a price proposal.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.answer_amendment_clarification(%L, ''hello'')::text', a));
  PERFORM zz.check('the supply-change reply refuses a price proposal', r LIKE 'ERR: Use the price proposal actions for a price proposal.%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.respond_to_amendment(%L, ''reject'', NULL)::text', a));
  PERFORM zz.check('the supply-change response refuses a price proposal', r LIKE 'ERR: Unsupported proposal type.%', r);
  -- What each side sees.
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT public.get_order_amendments(%L)::text', x));
  PERFORM zz.check('the pharmacy sees the price proposal with both prices and the totals',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v->'amendments') am WHERE am->>'kind' = 'price_change' AND (am->>'proposed_total')::numeric = 2100 AND (am->>'delta')::numeric = 100
      AND EXISTS (SELECT 1 FROM jsonb_array_elements(am->'lines') l WHERE l->>'product_name' = 'BO A' AND (l->>'unit_price_ghs')::numeric = 100 AND (l->>'proposed_unit_price_ghs')::numeric = 120)), left(v::text, 300));
  PERFORM zz.check('the order lines still show the price in force (100 for BO A)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v->'lines') l WHERE l->>'product_name' = 'BO A' AND (l->>'unit_price_ghs')::numeric = 100));
  PERFORM zz.check('the timeline has the event', EXISTS (SELECT 1 FROM public.order_events WHERE order_id = x AND amendment_id = a AND event_type = 'amendment_proposed'));
  PERFORM zz.check('the pharmacy was notified', EXISTS (SELECT 1 FROM public.notifications WHERE type = 'order_amendment' AND title = 'A price change needs your decision'));
  PERFORM zz.check('the proposal is audited', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order price change proposed' AND record_id = x));
END $$;

-- 3. Questions.
DO $$
DECLARE x UUID := zz.ord('X'); a UUID := zz.aid(zz.ord('X'), 1); r TEXT;
BEGIN
  r := zz.pr((SELECT u_pa FROM zz.bo), a, 'request_clarification', 'Why?');
  PERFORM zz.check('a pharmacy assistant cannot respond', r LIKE 'ERR: You do not have permission to respond to this proposal.%', r);
  r := zz.pr((SELECT u_px FROM zz.bo), a, 'accept');
  PERFORM zz.check('another pharmacy cannot respond', r LIKE 'ERR: You do not have permission to respond to this proposal.%', r);
  r := zz.pr((SELECT u_wo FROM zz.bo), a, 'accept');
  PERFORM zz.check('the wholesaler cannot approve its own proposal', r LIKE 'ERR: You do not have permission to respond to this proposal.%', r);
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'maybe');
  PERFORM zz.check('an unknown choice is refused', r LIKE 'ERR: Unsupported response.%', r);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'request_clarification', NULL);
  PERFORM zz.check('a question needs words', r LIKE 'ERR: Write your question for the wholesaler.%', r);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'request_clarification', 'Which products went up and why?');
  PERFORM zz.check('a pharmacy cashier asks a question', r::jsonb->>'status' = 'clarification_requested', r);
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('the pharmacy cannot decide while its question is open', r LIKE 'ERR: You asked a question; the wholesaler must reply before you can decide.%', r);
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('SELECT public.answer_price_clarification(%L, ''Cost of the raw material'')::text', a));
  PERFORM zz.check('a wholesaler cashier cannot reply', r LIKE 'ERR: Only the owner or a manager can reply on a price proposal.%', r);
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.answer_price_clarification(%L, '''')::text', a));
  PERFORM zz.check('an empty reply is refused', r LIKE 'ERR: Write your reply.%', r);
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.answer_price_clarification(%L, ''Cost of the raw material'')::text', a));
  PERFORM zz.check('a manager replies and the proposal awaits the pharmacy again', r::jsonb->>'status' = 'proposed', r);
  PERFORM zz.check('the conversation is kept', (SELECT count(*) = 2 FROM public.order_amendment_messages WHERE amendment_id = a));
END $$;

-- 4. Accepting an increase on a credit order: needs credit (or a one-time override).
DO $$
DECLARE x UUID := zz.ord('X'); a UUID := zz.aid(zz.ord('X'), 1); r TEXT; expo NUMERIC; stock_a INT := zz.stock('BO A'); stock_b INT := zz.stock('BO B'); ov INT;
BEGIN
  expo := public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo));
  UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = expo + 50 WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'accept');
  PERFORM zz.check('an increase above the credit limit is refused', r LIKE 'ERR: This increase (GHS 100.00) would take the account above its credit limit%', r);
  PERFORM zz.check('and nothing was applied', (SELECT status = 'proposed' FROM public.order_amendments WHERE id = a) AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = x)
    AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE amendment_id = a));
  UPDATE public.wholesaler_credit_terms SET status = 'blocked' WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'accept');
  PERFORM zz.check('a blocked credit line refuses the increase', r LIKE 'ERR: Credit for this customer is blocked.%', r);
  UPDATE public.wholesaler_credit_terms SET status = 'active', active = false WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'accept');
  PERFORM zz.check('a closed credit line refuses the increase', r LIKE 'ERR: Credit is closed for this customer%', r);
  UPDATE public.wholesaler_credit_terms SET active = true WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.grant_credit_override(%L, %L, 100, 7, ''Price increase approved'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)));
  PERFORM zz.check('the wholesaler grants a one-time override', r NOT LIKE 'ERR%', r);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'accept', 'Agreed');
  PERFORM zz.check('with the override a pharmacy cashier approves the new prices', r::jsonb->>'status' = 'accepted' AND r::jsonb->>'replayed' = 'false' AND (r::jsonb->>'new_total')::numeric = 2100, r);
  PERFORM zz.check('the proposal records the approval',
    (SELECT status = 'accepted' AND response_choice = 'accept_price' AND response_note = 'Agreed' AND applied_at IS NOT NULL AND responded_by = (SELECT u_pc FROM zz.bo) FROM public.order_amendments WHERE id = a));
  PERFORM zz.check('the effective total is 2100 and the placed total is still 2000', (SELECT effective_total_ghs = 2100 AND total_ghs = 2000 FROM public.orders WHERE id = x));
  PERFORM zz.check('the placed lines are untouched but the price in force is 120 / 45',
    (SELECT unit_price_ghs = 100 FROM public.order_items WHERE id = zz.item(x, 'BO A')) AND (SELECT unit_price_ghs = 50 FROM public.order_items WHERE id = zz.item(x, 'BO B'))
    AND zz.price(x, 'BO A') = 120 AND zz.price(x, 'BO B') = 45);
  PERFORM zz.check('one debit note of 100 was posted, tagged with the amendment, and no credit note', zz.entries(x, 'debit_note') = '1/100.00' AND zz.entries(x, 'credit_note') = '0/0');
  PERFORM zz.check('the invoice shows 2100 owed',
    (SELECT invoice_ghs = 2100 AND outstanding_ghs = 2100 FROM public.credit_invoice_status(x)));
  PERFORM zz.check('the override was consumed once', (SELECT count(*) = 1 FROM public.credit_overrides WHERE status = 'used' AND used_order_id = x) AND NOT EXISTS (SELECT 1 FROM public.credit_overrides WHERE status = 'active'));
  PERFORM zz.check('exposure rose by 100', public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)) = expo + 100);
  PERFORM zz.check('stock did not move', zz.stock('BO A') = stock_a AND zz.stock('BO B') = stock_b);
  r := zz.pr((SELECT u_pc FROM zz.bo), a, 'accept');
  PERFORM zz.check('approving again changes nothing (replayed)', r::jsonb->>'replayed' = 'true' AND zz.entries(x, 'debit_note') = '1/100.00' AND (SELECT effective_total_ghs = 2100 FROM public.orders WHERE id = x), r);
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'reject');
  PERFORM zz.check('rejecting after approval is refused', r LIKE 'ERR: This proposal has already been accepted.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.withdraw_price_amendment(%L, NULL)::text', a));
  PERFORM zz.check('withdrawing after approval is refused', r LIKE 'ERR: This proposal has already been accepted.%', r);
  PERFORM zz.check('the timeline, audit and notifications record it',
    EXISTS (SELECT 1 FROM public.order_events WHERE amendment_id = a AND event_type = 'amendment_accepted')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order price change accepted' AND record_id = x)
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order price change applied' AND record_id = x)
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit override used' AND record_id = x)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Price change approved'));
  UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = 1000000 WHERE wholesaler_id = (SELECT alpha FROM zz.bo);
END $$;

-- 5. A second amendment starts from the price in force; a net-zero change moves no money.
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; a UUID;
BEGIN
  r := zz.pp((SELECT u_wm FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 110), zz.pl(x, 'BO B', 50)), 'Settled at a lower figure');
  PERFORM zz.check('a manager proposes again: the prices it replaces are the ones in force (120 and 45)',
    r::jsonb->>'status' = 'proposed' AND (r::jsonb->>'version')::int = 2 AND (r::jsonb->>'delta')::numeric = 0
    AND EXISTS (SELECT 1 FROM public.order_amendment_lines WHERE amendment_id = (r::jsonb->>'amendment_id')::uuid AND product_name = 'BO A' AND unit_price_ghs = 120 AND proposed_unit_price_ghs = 110), r);
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('approved: the prices change but no money does (-100 and +100)', r::jsonb->>'status' = 'accepted' AND (r::jsonb->>'delta')::numeric = 0, r);
  PERFORM zz.check('so there is no new ledger entry and the total stays 2100',
    zz.entries(x, 'debit_note') = '1/100.00' AND zz.entries(x, 'credit_note') = '0/0' AND (SELECT effective_total_ghs = 2100 FROM public.orders WHERE id = x));
  PERFORM zz.check('the price in force is now the latest accepted one (110 / 50)', zz.price(x, 'BO A') = 110 AND zz.price(x, 'BO B') = 50);
  PERFORM zz.check('the invoice still shows 2100', (SELECT invoice_ghs = 2100 FROM public.credit_invoice_status(x)));
END $$;

-- 6. A decrease on a credit order (Z: BO C x5 @20 = 100 -> 18): one credit note.
DO $$
DECLARE z UUID := zz.ord('Z'); r TEXT; a UUID; expo NUMERIC := public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo));
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), z, jsonb_build_array(zz.pl(z, 'BO C', 18)), 'Promotional price');
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('a decrease of 10 is proposed', (r::jsonb->>'delta')::numeric = -10 AND (r::jsonb->>'proposed_total')::numeric = 90, r);
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('approved', r::jsonb->>'status' = 'accepted', r);
  PERFORM zz.check('one credit note of 10 and no debit note', zz.entries(z, 'credit_note') = '1/10.00' AND zz.entries(z, 'debit_note') = '0/0');
  PERFORM zz.check('the order total is 90 and the invoice shows 90', (SELECT effective_total_ghs = 90 FROM public.orders WHERE id = z) AND (SELECT invoice_ghs = 90 AND outstanding_ghs = 90 FROM public.credit_invoice_status(z)));
  PERFORM zz.check('exposure fell by 10', public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)) = expo - 10);
  PERFORM zz.check('the unique marker allows no second note for the amendment',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE amendment_id = a) = 1);
  BEGIN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note, amendment_id)
    SELECT alpha, good, z, 'credit_note', 'credit', 10, 'duplicate', a FROM zz.bo;
    PERFORM zz.check('a duplicate credit note for the amendment is refused by the database', FALSE, 'inserted');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a duplicate credit note for the amendment is refused by the database', TRUE);
  END;
END $$;

-- 7. Reject, withdraw, and cancelling the order (W: credit, BO C x6 @20 = 120).
DO $$
DECLARE w UUID := zz.ord('W'); r TEXT; a1 UUID; a2 UUID; a3 UUID;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), w, jsonb_build_array(zz.pl(w, 'BO C', 25)));
  a1 := (r::jsonb->>'amendment_id')::uuid;
  r := zz.pr((SELECT u_pa FROM zz.bo), a1, 'reject', 'No');
  PERFORM zz.check('an assistant cannot reject', r LIKE 'ERR: You do not have permission to respond to this proposal.%', r);
  r := zz.pr((SELECT u_po FROM zz.bo), a1, 'reject', 'Too expensive');
  PERFORM zz.check('the pharmacy rejects the increase', r::jsonb->>'status' = 'rejected', r);
  PERFORM zz.check('nothing changed: no effective total, no ledger entry, same price',
    (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = w) AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE amendment_id = a1) AND zz.price(w, 'BO C') = 20);
  PERFORM zz.check('the rejection is recorded with its note and notified', (SELECT response_choice = 'reject' AND response_note = 'Too expensive' FROM public.order_amendments WHERE id = a1)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Price change rejected'));
  r := zz.pr((SELECT u_po FROM zz.bo), a1, 'accept');
  PERFORM zz.check('a rejected proposal cannot be approved afterwards', r LIKE 'ERR: This proposal has already been rejected.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), w, jsonb_build_array(zz.pl(w, 'BO C', 22)), 'A smaller increase');
  a2 := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('the wholesaler may propose again (version 2)', (r::jsonb->>'version')::int = 2, r);
  r := zz.val_as((SELECT u_wc FROM zz.bo), format('SELECT public.withdraw_price_amendment(%L, ''changed my mind'')::text', a2));
  PERFORM zz.check('a cashier cannot withdraw a price proposal', r LIKE 'ERR: Only the owner or a manager can withdraw a price proposal.%', r);
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.withdraw_price_amendment(%L, ''changed my mind'')::text', a2));
  PERFORM zz.check('a manager withdraws it', r::jsonb->>'status' = 'withdrawn', r);
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.withdraw_price_amendment(%L, NULL)::text', a2));
  PERFORM zz.check('withdrawing twice is a replay', r::jsonb->>'replayed' = 'true', r);
  r := zz.pr((SELECT u_po FROM zz.bo), a2, 'accept');
  PERFORM zz.check('a withdrawn proposal cannot be approved', r LIKE 'ERR: This proposal has already been withdrawn.%', r);
  r := zz.pp((SELECT u_wo FROM zz.bo), w, jsonb_build_array(zz.pl(w, 'BO C', 21)));
  a3 := (r::jsonb->>'amendment_id')::uuid;
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'test' WHERE id = w;
  PERFORM zz.check('cancelling the order closes the open price proposal',
    (SELECT status = 'withdrawn' AND response_choice = 'order_cancelled' FROM public.order_amendments WHERE id = a3));
END $$;

-- 8. A cash order (Y: COD, BO C x10 @20 = 200): the effective total is what is collected; no ledger.
DO $$
DECLARE y UUID := zz.ord('Y'); n UUID := zz.ord('N'); r TEXT; a UUID;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), y, jsonb_build_array(zz.pl(y, 'BO C', 15)), 'Volume discount');
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('approved on a cash order', r::jsonb->>'status' = 'accepted' AND (r::jsonb->>'new_total')::numeric = 150, r);
  PERFORM zz.check('the amount to collect is 150 and no ledger entry exists',
    (SELECT effective_total_ghs = 150 AND total_ghs = 200 FROM public.orders WHERE id = y) AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = y));
  -- N was paid before: refused at the proposal. A proposal made before payment cannot be approved after it.
  ALTER TABLE public.orders DISABLE TRIGGER trg_mirror_legacy_credit_payment;
  UPDATE public.orders SET payment_status = 'unpaid', paid_at = NULL, payment_confirmed_at = NULL WHERE id = n;
  ALTER TABLE public.orders ENABLE TRIGGER trg_mirror_legacy_credit_payment;
  r := zz.pp((SELECT u_wo FROM zz.bo), n, jsonb_build_array(zz.pl(n, 'BO C', 18)));
  a := (r::jsonb->>'amendment_id')::uuid;
  ALTER TABLE public.orders DISABLE TRIGGER trg_mirror_legacy_credit_payment;
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now() WHERE id = n;
  ALTER TABLE public.orders ENABLE TRIGGER trg_mirror_legacy_credit_payment;
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('an order paid in the meantime cannot be amended', r LIKE 'ERR: This order has already been paid.%', r);
  PERFORM zz.check('and its proposal stays open, unapplied', (SELECT status = 'proposed' FROM public.order_amendments WHERE id = a) AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = n));
END $$;

-- 9. A proposal that no longer describes the order is refused (L: a legacy credit order, BO C x5 @20, invoice 100).
DO $$
DECLARE l UUID := zz.ord('L'); r TEXT; a UUID; a2 UUID; stock_c INT := zz.stock('BO C');
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), l, jsonb_build_array(zz.pl(l, 'BO C', 22)));
  a := (r::jsonb->>'amendment_id')::uuid;
  -- Something else changed the price in force in the meantime.
  INSERT INTO public.order_amendments(order_id, version, kind, status, reason, proposed_by, original_total_ghs, proposed_total_ghs, delta_ghs, request_id, applied_at)
  SELECT l, 50, 'price_change', 'accepted', 'earlier change', u_wo, 100, 105, 5, gen_random_uuid(), now() FROM zz.bo;
  INSERT INTO public.order_amendment_lines(amendment_id, order_item_id, product_id, product_name, ordered_qty, prior_supplied_qty, supplied_qty, short_qty, unit_price_ghs, proposed_unit_price_ghs)
  SELECT zz.aid(l, 50), zz.item(l, 'BO C'), pcc, 'BO C', 5, 5, 5, 0, 20, 21 FROM zz.bo;
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('the price changed since the proposal: approval is refused', r LIKE 'ERR: The order changed since this proposal was made (BO C). Ask the wholesaler for a new proposal.%', r);
  PERFORM zz.check('and nothing was applied', (SELECT status = 'proposed' FROM public.order_amendments WHERE id = a) AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE amendment_id = a));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.withdraw_price_amendment(%L, NULL)::text', a));
  r := zz.pp((SELECT u_wo FROM zz.bo), l, jsonb_build_array(zz.pl(l, 'BO C', 22)));
  a2 := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.check('a new proposal starts from the price in force (21)', EXISTS (SELECT 1 FROM public.order_amendment_lines WHERE amendment_id = a2 AND unit_price_ghs = 21 AND proposed_unit_price_ghs = 22), r);
  r := zz.pr((SELECT u_po FROM zz.bo), a2, 'accept');
  PERFORM zz.check('approved on a legacy order: a debit note of 5', r::jsonb->>'status' = 'accepted' AND zz.entries(l, 'debit_note') = '1/5.00', r);
  PERFORM zz.check('and stock never moves for a price change (not even for a legacy order)', zz.stock('BO C') = stock_c);
END $$;

-- 10. Price changes and back-orders (V: credit, BO A x10 @100). The price is raised, then 4 units are back-ordered.
DO $$
DECLARE v UUID := zz.ord('V'); r TEXT; a UUID; s UUID; stock_a INT;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), v, jsonb_build_array(zz.pl(v, 'BO A', 120)));
  a := (r::jsonb->>'amendment_id')::uuid;
  r := zz.pr((SELECT u_po FROM zz.bo), a, 'accept');
  PERFORM zz.check('V: the price rises to 120 (+200): total 1200', r::jsonb->>'status' = 'accepted' AND (SELECT effective_total_ghs = 1200 FROM public.orders WHERE id = v) AND zz.entries(v, 'debit_note') = '1/200.00', r);
  a := zz.amend(v, jsonb_build_array(zz.line(v, 'BO A', 6, 'release')), 'accept_backorder');
  PERFORM zz.check('then 4 units are back-ordered: the shortage is valued at the price in force (4 x 120 = 480)',
    (SELECT delta_ghs = -480 FROM public.order_amendments WHERE id = a) AND zz.entries(v, 'credit_note') = '1/480.00' AND (SELECT effective_total_ghs = 720 FROM public.orders WHERE id = v));
  PERFORM zz.check('the order now stands at 6 x 120 = 720', (SELECT invoice_ghs = 720 FROM public.credit_invoice_status(v)));
  PERFORM zz.go(v, 'dispatched');
  r := zz.pp((SELECT u_wo FROM zz.bo), v, jsonb_build_array(zz.pl(v, 'BO A', 130)));
  PERFORM zz.check('after dispatch a price change is refused', r LIKE 'ERR: Prices can only be changed while the order is being prepared%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', v, jsonb_build_array(zz.sl(v, 'BO A', 4))::text));
  PERFORM zz.check('the back-order shipment is valued at the price in force (4 x 120 = 480)', (r::jsonb->>'amount')::numeric = 480, r);
  s := (r::jsonb->>'shipment_id')::uuid;
  PERFORM zz.check('its line carries 120', (SELECT unit_price_ghs = 120 FROM public.order_shipment_lines WHERE shipment_id = s));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s));
  PERFORM zz.check('dispatching posts one invoice of 480 and the order is back to 1200',
    r::jsonb->>'status' = 'dispatched' AND (SELECT effective_total_ghs = 1200 FROM public.orders WHERE id = v)
    AND (SELECT count(*) || '/' || sum(amount_ghs) = '1/480.00' FROM public.credit_ledger_entries WHERE shipment_id = s AND entry_type = 'invoice'), r);
END $$;

-- 11. X is dispatched and delivered; later readers use the price in force (110 for BO A, 50 for BO B).
UPDATE public.orders SET status = 'dispatched' WHERE id = zz.ord('X');
UPDATE public.orders SET status = 'delivered' WHERE id = zz.ord('X');
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; v JSONB; a UUID; rid UUID;
BEGIN
  r := zz.pp((SELECT u_wo FROM zz.bo), x, jsonb_build_array(zz.pl(x, 'BO A', 105)));
  PERFORM zz.check('X: a delivered order cannot be repriced', r LIKE 'ERR: Prices can only be changed while the order is being prepared%', r);
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT public.get_order_delivery_reports(%L)::text', x));
  PERFORM zz.check('the delivery check expects BO A at 110 and BO B at 50',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v->'deliveries'->0->'expected') e WHERE e->>'product_name' = 'BO A' AND (e->>'unit_price_ghs')::numeric = 110)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'deliveries'->0->'expected') e WHERE e->>'product_name' = 'BO B' AND (e->>'unit_price_ghs')::numeric = 50), left(v::text, 300));
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 1, 0, 0, 'one pack short')));
  rid := (r::jsonb->>'report_id')::uuid;
  PERFORM zz.check('the delivery report records the price in force (110)', (SELECT unit_price_ghs = 110 FROM public.order_delivery_report_lines WHERE report_id = rid AND product_name = 'BO A'), r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, ''checked'')::text', rid,
    (SELECT jsonb_agg(jsonb_build_object('line_id', id, 'kind', 'missing', 'outcome', 'credit')) FROM public.order_delivery_report_lines WHERE report_id = rid AND missing_qty > 0)::text));
  PERFORM zz.check('crediting the missing pack credits 110, the price paid', (SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) = '1/110.00' FROM public.credit_ledger_entries WHERE delivery_report_id = rid), r);
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(g)) FROM public.get_returnable_items(%L) g)::text', x));
  PERFORM zz.check('a return of BO A is valued at 110', EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e->>'product_name' = 'BO A' AND (e->>'unit_price_ghs')::numeric = 110), v::text);
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_products(%L, ''all'') s)::text', (SELECT good FROM zz.bo)));
  PERFORM zz.check('the product report values BO A at the price in force (X: 10 x 110; V: 10 x 120 = 2300 for 20 units)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e->>'product_name' = 'BO A' AND (e->>'spend_ghs')::numeric = 2300), v::text);
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_purchases(%L, ''all'') s)::text', (SELECT good FROM zz.bo)));
  PERFORM zz.check('the purchases list shows 110 for X''s BO A', EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e->>'order_id' = x::text AND e->>'product_name' = 'BO A' AND (e->>'unit_price_ghs')::numeric = 110), left(v::text, 300));
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_purchases_summary(%L, ''all'') s)::text', (SELECT good FROM zz.bo)));
  PERFORM zz.check('the purchases summary runs', v IS NOT NULL, v::text);
  v := zz.j((SELECT u_wo FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.wholesaler_report_products(%L, ''all'') s)::text', (SELECT alpha FROM zz.bo)));
  PERFORM zz.check('the wholesaler product report values BO A at the price in force', EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e->>'product_name' = 'BO A' AND (e->>'revenue_ghs')::numeric = 2300), v::text);
  v := zz.j((SELECT u_po FROM zz.bo), format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_price_history(%L, ''all'', NULL, NULL, NULL, NULL, NULL, 50, 0) s)::text', (SELECT good FROM zz.bo)));
  PERFORM zz.check('the price history reports the price actually paid for BO A (latest 120 on V)', EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e->>'product_name' = 'BO A' AND (e->>'max_paid_ghs')::numeric = 120), left(v::text, 400));
  v := zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)));
  PERFORM zz.check('the statement shows price changes as their own lines (X +100, Z -10, V +200, Y -50 cash, L +5 twice: the simulated earlier change and the real one)',
    (SELECT count(*) = 6 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'price_adjustment')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'price_adjustment' AND ln->>'order_number' = (SELECT order_number FROM public.orders WHERE id = x) AND (ln->>'debit')::numeric = 100),
    (SELECT jsonb_agg(ln) FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'price_adjustment')::text);
  PERFORM zz.check('and the net-zero change (version 2) is not a statement line', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'lines') ln WHERE ln->>'kind' = 'price_adjustment' AND (ln->>'debit')::numeric = 0 AND (ln->>'credit')::numeric = 0));
END $$;

-- 12. Records are append-only and the table rules hold.
DO $$
DECLARE x UUID := zz.ord('X'); a UUID := zz.aid(zz.ord('X'), 1); r TEXT;
BEGIN
  BEGIN UPDATE public.order_amendment_lines SET proposed_unit_price_ghs = 999 WHERE amendment_id = a; PERFORM zz.check('a price line cannot be edited', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a price line cannot be edited', SQLERRM LIKE '%append-only%', SQLERRM); END;
  BEGIN DELETE FROM public.order_amendment_lines WHERE amendment_id = a; PERFORM zz.check('a price line cannot be deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a price line cannot be deleted', SQLERRM LIKE '%append-only%', SQLERRM); END;
  BEGIN UPDATE public.order_amendments SET proposed_total_ghs = 1 WHERE id = a; PERFORM zz.check('an approved proposal cannot be edited', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('an approved proposal cannot be edited', SQLERRM LIKE 'A proposal cannot be edited after it is made%', SQLERRM); END;
  BEGIN
    INSERT INTO public.order_amendment_lines(amendment_id, order_item_id, product_id, product_name, ordered_qty, prior_supplied_qty, supplied_qty, short_qty, unit_price_ghs, proposed_unit_price_ghs)
    SELECT a, zz.item(x, 'BO A'), pa, 'BO A', 10, 10, 10, 0, 100, 100 FROM zz.bo;
    PERFORM zz.check('a price line must change the price', FALSE, 'inserted');
  EXCEPTION WHEN check_violation THEN PERFORM zz.check('a price line must change the price', TRUE); END;
  BEGIN
    INSERT INTO public.order_amendment_lines(amendment_id, order_item_id, product_id, product_name, ordered_qty, prior_supplied_qty, supplied_qty, short_qty, unit_price_ghs, proposed_unit_price_ghs, stock_treatment)
    SELECT a, zz.item(x, 'BO A'), pa, 'BO A', 10, 10, 8, 2, 100, 90, 'release' FROM zz.bo;
    PERFORM zz.check('a price line cannot also cut a quantity', FALSE, 'inserted');
  EXCEPTION WHEN check_violation THEN PERFORM zz.check('a price line cannot also cut a quantity', TRUE); END;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT count(*)::text FROM public.order_amendment_lines WHERE amendment_id = %L', a));
  PERFORM zz.check('the lines are not readable directly by a wholesaler (only through the checked functions)', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('UPDATE public.orders SET effective_total_ghs = 1 WHERE id = %L RETURNING effective_total_ghs::text', x));
  PERFORM zz.check('staff cannot edit the effective total directly', r LIKE 'ERR:%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
