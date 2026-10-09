-- Order amendments, Phase 5: delivery reconciliation (claims, the wholesaler's decision, returns reaching the ledger), against production-like rules.
-- Run after setup.sql + migrations (through 20261103120000_delivery_reconciliation_workflow.sql), with the production guard and stock
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


-- Extra orders for delivery reconciliation: N (cash, BO C x5 = 100, will be paid) and P (credit, BO A x4 = 400, with a back-order).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset n_
INSERT INTO zz.bo_orders SELECT 'N', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.bo), 'quantity', 4, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'credit')) AS r \gset p_
INSERT INTO zz.bo_orders SELECT 'P', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id IN (zz.ord('N'), zz.ord('P'));
CREATE TABLE zz.dr_ids(label TEXT PRIMARY KEY, id UUID);

CREATE FUNCTION zz.rl(p_order UUID, p_name TEXT, p_missing INT, p_damaged INT, p_rejected INT, p_reason TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'missing', p_missing, 'damaged', p_damaged, 'rejected', p_rejected, 'reason', p_reason) $$;
CREATE FUNCTION zz.submit(p_uid UUID, p_order UUID, p_ship UUID, p_lines JSONB, p_req UUID DEFAULT gen_random_uuid()) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.submit_delivery_report(%L, %L, %L::jsonb, ''checked on arrival'', %L)::text', p_order, p_ship, p_lines::text, p_req)) $$;

-- 0. Starting point: X and Y delivered; N delivered and paid; Z and W untouched.
SELECT zz.go(zz.ord('X'), 'delivered');
SELECT zz.go(zz.ord('Y'), 'delivered');
SELECT zz.go(zz.ord('N'), 'delivered');
ALTER TABLE public.orders DISABLE TRIGGER trg_mirror_legacy_credit_payment;
UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now() WHERE id = zz.ord('N');
ALTER TABLE public.orders ENABLE TRIGGER trg_mirror_legacy_credit_payment;
DO $$
BEGIN
  PERFORM zz.check('three orders are delivered; N is a paid cash order', (SELECT count(*) = 3 FROM public.orders WHERE id IN (zz.ord('X'), zz.ord('Y'), zz.ord('N')) AND status = 'delivered')
    AND (SELECT payment_status::text = 'paid' FROM public.orders WHERE id = zz.ord('N')));
END $$;

-- 1. Who may report, and what is refused.
DO $$
DECLARE x UUID := zz.ord('X'); z UUID := zz.ord('Z'); r TEXT; u RECORD; a UUID := (SELECT id FROM public.order_items WHERE order_id = zz.ord('X') AND product_name = 'BO A');
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy assistant', (SELECT u_pa FROM zz.bo)), ('another pharmacy', (SELECT u_px FROM zz.bo)), ('the wholesaler owner', (SELECT u_wo FROM zz.bo)),
      ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.submit(u.uid, x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 1, 0, 0, 'short')));
    PERFORM zz.check(u.label || ' cannot report on a delivery', r LIKE 'ERR: You do not have permission to report on this delivery.%', r);
  END LOOP;
  r := zz.submit((SELECT u_po FROM zz.bo), z, NULL, jsonb_build_array(zz.rl(z, 'BO C', 1, 0, 0, 'short')));
  PERFORM zz.check('an order that is not delivered cannot be reported on', r LIKE 'ERR: The order has not been marked delivered yet.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, gen_random_uuid(), '[]'::jsonb);
  PERFORM zz.check('a shipment that is not on this order is refused', r LIKE 'ERR: That shipment does not belong to this order.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 11, 0, 0, 'lost')));
  PERFORM zz.check('more than was delivered is refused', r LIKE 'ERR: You cannot report more than the 10 delivered of BO A.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 6, 5, 0, 'lost')));
  PERFORM zz.check('the parts must add up to what was delivered', r LIKE 'ERR: You cannot report more than the 10 delivered of BO A.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 2, 0, 0, '')));
  PERFORM zz.check('a reason is required for a problem', r LIKE 'ERR: Say what went wrong with BO A.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(jsonb_build_object('order_item_id', a, 'missing', -1, 'reason', 'lost')));
  PERFORM zz.check('negative quantities are refused', r LIKE 'ERR: Quantities for BO A must be whole numbers.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 1, 0, 0, 'lost'), zz.rl(x, 'BO A', 1, 0, 0, 'lost')));
  PERFORM zz.check('the same product twice is refused', r LIKE 'ERR: Each product can appear only once.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(jsonb_build_object('order_item_id', gen_random_uuid(), 'missing', 1, 'reason', 'lost')));
  PERFORM zz.check('a line from another delivery is refused', r LIKE 'ERR: A line does not belong to this delivery.%', r);
  PERFORM zz.check('none of the refused calls created a report', NOT EXISTS (SELECT 1 FROM public.order_delivery_reports));
END $$;

-- 2. A receipt in full is just a record.
DO $$
DECLARE y UUID := zz.ord('Y'); r TEXT; stock_before INT := zz.stock('BO C');
BEGIN
  r := zz.submit((SELECT u_pc FROM zz.bo), y, NULL, '[]'::jsonb);
  PERFORM zz.check('a pharmacy cashier confirms the delivery was received in full', r::jsonb->>'status' = 'received_in_full', r);
  PERFORM zz.check('it records every line as fully received and changes nothing else',
    (SELECT count(*) = 1 AND bool_and(received_qty = expected_qty AND missing_qty + damaged_qty + rejected_qty = 0) FROM public.order_delivery_report_lines WHERE report_id = (r::jsonb->>'report_id')::uuid)
    AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = y) AND zz.stock('BO C') = stock_before);
  PERFORM zz.check('the timeline says so', EXISTS (SELECT 1 FROM public.order_events WHERE order_id = y AND event_type = 'delivery_received_in_full'));
  r := zz.submit((SELECT u_po FROM zz.bo), y, NULL, jsonb_build_array(zz.rl(y, 'BO C', 1, 0, 0, 'found one short')));
  PERFORM zz.check('a second report for the same delivery is refused once one is in', r LIKE 'ERR: There is already a delivery report for this delivery.%', r);
END $$;

-- 3. A claim: nothing changes, and the claimed units are spoken for.
DO $$
DECLARE x UUID := zz.ord('X'); r TEXT; req UUID := gen_random_uuid(); rep UUID; stock_a INT := zz.stock('BO A'); stock_b INT := zz.stock('BO B');
BEGIN
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL,
    jsonb_build_array(zz.rl(x, 'BO A', 2, 0, 0, 'two cartons not on the truck'), zz.rl(x, 'BO B', 0, 4, 1, 'crushed boxes; one wrong strength')), req);
  rep := (r::jsonb->>'report_id')::uuid; INSERT INTO zz.dr_ids VALUES ('x1', rep);
  PERFORM zz.check('the pharmacy owner reports 2 missing, 4 damaged and 1 rejected', r::jsonb->>'status' = 'submitted' AND (r::jsonb->>'units')::int = 7, r);
  PERFORM zz.check('the lines record expected / received / missing / damaged / rejected and the reason',
    (SELECT expected_qty = 10 AND received_qty = 8 AND missing_qty = 2 AND reason LIKE 'two cartons%' FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO A')
    AND (SELECT expected_qty = 20 AND received_qty = 15 AND damaged_qty = 4 AND rejected_qty = 1 FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO B'));
  PERFORM zz.check('a claim moves nothing: stock, total and ledger are untouched',
    zz.stock('BO A') = stock_a AND zz.stock('BO B') = stock_b AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = x)
    AND (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE order_id = x) AND NOT EXISTS (SELECT 1 FROM public.order_returns WHERE order_id = x));
  PERFORM zz.check('the wholesaler''s owners and managers are told; the warehouse and cashier are not',
    (SELECT count(*) = 2 FROM public.notifications WHERE type = 'delivery_update' AND title = 'Delivery problem reported' AND user_id IN ((SELECT u_wo FROM zz.bo), (SELECT u_wm FROM zz.bo)))
    AND NOT EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Delivery problem reported' AND user_id IN ((SELECT u_wc FROM zz.bo), (SELECT u_ww FROM zz.bo))));
  PERFORM zz.check('the report is audited for the pharmacy',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Delivery problem reported' AND record_id = x AND business_id = (SELECT good FROM zz.bo)));
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 2, 0, 0, 'two cartons not on the truck'), zz.rl(x, 'BO B', 0, 4, 1, 'crushed boxes; one wrong strength')), req);
  PERFORM zz.check('repeating the same request returns the same report', r::jsonb->>'replayed' = 'true' AND (r::jsonb->>'report_id')::uuid = rep AND (SELECT count(*) = 1 FROM public.order_delivery_reports WHERE order_id = x), r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 1, 0, 0, 'another')));
  PERFORM zz.check('only one live report per delivery', r LIKE 'ERR: There is already a delivery report for this delivery.%', r);
  PERFORM zz.check('the claimed units cannot be returned a second time: BO A can return 10 - 2 = 8, BO B 20 - 5 = 15',
    zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO A''', x)) = '8'
    AND zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO B''', x)) = '15');
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', x, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(x, 'BO A'), 'quantity', 9))::text));
  PERFORM zz.check('a return of 9 BO A is refused while 2 are under a claim', r LIKE 'ERR: Only 8 unit(s) of BO A can still be returned.%', r);
END $$;

-- 4. Withdrawing.
DO $$
DECLARE x UUID := zz.ord('X'); rep UUID := (SELECT id FROM zz.dr_ids WHERE label = 'x1'); r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.withdraw_delivery_report(%L)::text', rep));
  PERFORM zz.check('the wholesaler cannot withdraw the pharmacy''s report', r LIKE 'ERR: You do not have permission to withdraw this report.%', r);
  r := zz.val_as((SELECT u_pa FROM zz.bo), format('SELECT public.withdraw_delivery_report(%L)::text', rep));
  PERFORM zz.check('a pharmacy assistant cannot either', r LIKE 'ERR: You do not have permission to withdraw this report.%', r);
  r := zz.val_as((SELECT u_pc FROM zz.bo), format('SELECT public.withdraw_delivery_report(%L)::text', rep));
  PERFORM zz.check('the pharmacy cashier withdraws it', r::jsonb->>'status' = 'withdrawn', r);
  r := zz.val_as((SELECT u_pc FROM zz.bo), format('SELECT public.withdraw_delivery_report(%L)::text', rep));
  PERFORM zz.check('withdrawing twice is a no-op', r::jsonb->>'replayed' = 'true', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, ''[]''::jsonb, NULL)::text', rep));
  PERFORM zz.check('a withdrawn report cannot be decided', r LIKE 'ERR: This report is withdrawn; there is nothing to decide.%', r);
  PERFORM zz.check('the units are free again after a withdrawal',
    zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO A''', x)) = '10');
  -- Submit the claim again (a new report is allowed after a withdrawal).
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL,
    jsonb_build_array(zz.rl(x, 'BO A', 2, 0, 0, 'two cartons not on the truck'), zz.rl(x, 'BO B', 0, 4, 1, 'crushed boxes; one wrong strength')));
  INSERT INTO zz.dr_ids VALUES ('x2', (r::jsonb->>'report_id')::uuid);
  PERFORM zz.check('a new report is accepted after the old one was withdrawn', r::jsonb->>'status' = 'submitted', r);
END $$;

-- 5. The wholesaler decides.
DO $$
DECLARE x UUID := zz.ord('X'); rep UUID := (SELECT id FROM zz.dr_ids WHERE label = 'x2'); r TEXT; u RECORD; l_a UUID; l_b UUID; dec JSONB;
BEGIN
  SELECT id INTO l_a FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO A';
  SELECT id INTO l_b FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO B';
  dec := jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'credit'),
                           jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'),
                           jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'));
  FOR u IN SELECT * FROM (VALUES ('the wholesaler cashier', (SELECT u_wc FROM zz.bo)), ('the warehouse user', (SELECT u_ww FROM zz.bo)), ('finance staff', (SELECT u_wf FROM zz.bo)),
      ('the pharmacy owner', (SELECT u_po FROM zz.bo)), ('another wholesaler', (SELECT u_wx FROM zz.bo))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep, dec::text));
    PERFORM zz.check(u.label || ' cannot decide a delivery report', r LIKE 'ERR: Only the wholesaler''s owner or manager can decide on a delivery report.%', r);
  END LOOP;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep, jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'credit'))::text));
  PERFORM zz.check('every discrepancy must be decided', r LIKE 'ERR: Decide every discrepancy on the report (3 to decide).%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'return'), jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'), jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'))::text));
  PERFORM zz.check('missing goods cannot be "returned"', r LIKE 'ERR: Missing goods cannot be returned%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'maybe'), jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'), jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'))::text));
  PERFORM zz.check('an unknown outcome is refused', r LIKE 'ERR: Choose credit, return or reject for BO A.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'damaged', 'outcome', 'credit'), jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'), jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'))::text));
  PERFORM zz.check('deciding something that was not reported is refused', r LIKE 'ERR: There is nothing reported as damaged on BO A.%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'reject'), jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'), jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'))::text));
  PERFORM zz.check('a rejection needs an explanation', r LIKE 'ERR: Explain to the pharmacy why a claim is rejected.%', r);
  PERFORM zz.check('all those refusals changed nothing', (SELECT status = 'submitted' FROM public.order_delivery_reports WHERE id = rep)
    AND NOT EXISTS (SELECT 1 FROM public.order_delivery_report_decisions) AND NOT EXISTS (SELECT 1 FROM public.order_returns WHERE order_id = x));
END $$;

DO $$
DECLARE x UUID := zz.ord('X'); rep UUID := (SELECT id FROM zz.dr_ids WHERE label = 'x2'); r TEXT; l_a UUID; l_b UUID; dec JSONB; stock_a INT := zz.stock('BO A'); stock_b INT := zz.stock('BO B'); ret UUID;
BEGIN
  SELECT id INTO l_a FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO A';
  SELECT id INTO l_b FROM public.order_delivery_report_lines WHERE report_id = rep AND product_name = 'BO B';
  dec := jsonb_build_array(jsonb_build_object('line_id', l_a, 'kind', 'missing', 'outcome', 'credit'),
                           jsonb_build_object('line_id', l_b, 'kind', 'damaged', 'outcome', 'return'),
                           jsonb_build_object('line_id', l_b, 'kind', 'rejected', 'outcome', 'credit'));
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, ''verified against the waybill'')::text', rep, dec::text));
  PERFORM zz.check('the wholesaler manager decides: credit the missing and the rejected, take the damaged back', r::jsonb->>'status' = 'resolved' AND (r::jsonb->>'credited')::numeric = 250 AND (r::jsonb->>'returns_opened')::int = 1, r);
  PERFORM zz.check('one credit note of 250 (200 missing + 50 rejected) was posted, linked to the report',
    (SELECT count(*) = 1 AND sum(amount_ghs) = 250 AND bool_and(entry_type = 'credit_note' AND direction = 'credit' AND order_id = x) FROM public.credit_ledger_entries WHERE delivery_report_id = rep));
  PERFORM zz.check('the order total is now 1750 (placed 2000); the placed total is untouched', (SELECT effective_total_ghs = 1750 AND total_ghs = 2000 FROM public.orders WHERE id = x));
  PERFORM zz.check('the invoice status nets the credit note: invoice 1750, nothing paid', (SELECT invoice_ghs = 1750 AND paid_ghs = 0 AND outstanding_ghs = 1750 FROM public.credit_invoice_status(x)),
    (SELECT invoice_ghs || '/' || paid_ghs || '/' || outstanding_ghs FROM public.credit_invoice_status(x)));
  SELECT id INTO ret FROM public.order_returns WHERE delivery_report_id = rep;
  PERFORM zz.check('a return was opened in the existing workflow: approved, linked to the report, for the 4 damaged units',
    (SELECT status = 'approved' AND reason = 'damaged' AND requested_by = (SELECT u_po FROM zz.bo) AND reviewed_by = (SELECT u_wm FROM zz.bo) FROM public.order_returns WHERE id = ret)
    AND (SELECT count(*) = 1 AND sum(quantity_requested) = 4 AND bool_and(unit_price_ghs = 50) FROM public.order_return_items WHERE return_id = ret));
  PERFORM zz.check('reporting and deciding moved no stock', zz.stock('BO A') = stock_a AND zz.stock('BO B') = stock_b);
  PERFORM zz.check('the decisions are recorded per discrepancy with amounts and the linked return',
    (SELECT count(*) = 3 FROM public.order_delivery_report_decisions WHERE report_id = rep)
    AND (SELECT amount_ghs = 200 AND outcome = 'credit' FROM public.order_delivery_report_decisions WHERE report_id = rep AND kind = 'missing')
    AND (SELECT return_id = ret AND outcome = 'return' AND amount_ghs = 0 FROM public.order_delivery_report_decisions WHERE report_id = rep AND kind = 'damaged'));
  PERFORM zz.check('the report records who decided, when and the note', (SELECT status = 'resolved' AND resolved_by = (SELECT u_wm FROM zz.bo) AND resolution_note = 'verified against the waybill' AND credit_total_ghs = 250 FROM public.order_delivery_reports WHERE id = rep));
  PERFORM zz.check('the pharmacy is told, including to send the goods back',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND title = 'Your delivery report was decided' AND body LIKE '%Send the goods back%'));
  PERFORM zz.check('events and audit exist for the decision', EXISTS (SELECT 1 FROM public.order_events WHERE order_id = x AND event_type = 'delivery_report_resolved' AND actor_side = 'wholesaler')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Delivery report decided' AND record_id = x AND business_id = (SELECT alpha FROM zz.bo)));
  PERFORM zz.check('the order timeline carries no ledger detail', NOT EXISTS (SELECT 1 FROM public.order_events WHERE order_id = x AND (details::text ILIKE '%ledger%' OR details::text ILIKE '%credit_note%')));
  -- Repeats.
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep, dec::text));
  PERFORM zz.check('deciding again is a no-op (replayed)', r::jsonb->>'replayed' = 'true', r);
  PERFORM zz.check('no second credit note, return or decision',
    (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE delivery_report_id = rep) AND (SELECT count(*) = 1 FROM public.order_returns WHERE delivery_report_id = rep)
    AND (SELECT count(*) = 3 FROM public.order_delivery_report_decisions WHERE report_id = rep));
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.withdraw_delivery_report(%L)::text', rep));
  PERFORM zz.check('a decided report cannot be withdrawn', r LIKE 'ERR: This report has already been resolved, so it can no longer be withdrawn.%', r);
  r := zz.submit((SELECT u_po FROM zz.bo), x, NULL, jsonb_build_array(zz.rl(x, 'BO A', 1, 0, 0, 'more')));
  PERFORM zz.check('and no new report can be opened for a settled delivery', r LIKE 'ERR: There is already a delivery report for this delivery.%', r);
  BEGIN INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, delivery_report_id)
    SELECT alpha, good, x, 'credit_note', 'credit', 1, rep FROM zz.bo;
    PERFORM zz.check('the database allows one credit note per delivery report', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('the database allows one credit note per delivery report', TRUE); END;
  BEGIN UPDATE public.order_delivery_report_lines SET missing_qty = 0 WHERE report_id = rep;
    PERFORM zz.check('report lines cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('report lines cannot be edited', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  BEGIN UPDATE public.order_delivery_reports SET note = 'changed' WHERE id = rep;
    PERFORM zz.check('a report''s content cannot be edited', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a report''s content cannot be edited', SQLERRM LIKE 'A delivery report cannot be edited after it is submitted%', SQLERRM); END;
  BEGIN DELETE FROM public.order_delivery_report_decisions WHERE report_id = rep;
    PERFORM zz.check('decisions cannot be deleted', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('decisions cannot be deleted', SQLERRM = 'Order amendment records are append-only.', SQLERRM); END;
  PERFORM zz.check('no client can write the report tables directly',
    zz.val_as((SELECT u_po FROM zz.bo), 'INSERT INTO public.order_delivery_reports(order_id, status, delivered_at, submitted_by, request_id) SELECT id, ''resolved'', now(), auth.uid(), gen_random_uuid() FROM public.orders LIMIT 1') LIKE 'ERR:%'
    AND zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.order_delivery_reports') = '0');
END $$;

-- 6. The return carries on through the existing workflow, and now reaches the ledger.
DO $$
DECLARE x UUID := zz.ord('X'); ret UUID := (SELECT id FROM public.order_returns WHERE delivery_report_id = (SELECT id FROM zz.dr_ids WHERE label = 'x2')); r TEXT; stock_b INT := zz.stock('BO B');
  item UUID; stmt JSONB;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.mark_order_return_returned(%L)::text', ret));
  PERFORM zz.check('the wholesaler marks the goods as received back', (SELECT status = 'returned' FROM public.order_returns WHERE id = ret), r);
  SELECT id INTO item FROM public.order_return_items WHERE return_id = ret;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', ret, jsonb_build_array(jsonb_build_object('return_item_id', item, 'quantity_accepted', 4, 'restock', true))::text));
  PERFORM zz.check('and inspects them: all 4 accepted, fit for stock', (SELECT status = 'inspected' FROM public.order_returns WHERE id = ret), r);
  PERFORM zz.check('nothing has moved before the return is resolved', zz.stock('BO B') = stock_b AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE return_id = ret));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_order_return(%L, ''credit'', ''thanks'')::text', ret));
  PERFORM zz.check('resolving as a credit returns 200 (4 x 50)', r = '200.00', r);
  PERFORM zz.check('stock goes back: +4 on BO B', zz.stock('BO B') = stock_b + 4);
  PERFORM zz.check('the credit now reaches the ledger: one credit note of 200 linked to the return (the old gap)',
    (SELECT count(*) = 1 AND sum(amount_ghs) = 200 AND bool_and(entry_type = 'credit_note' AND direction = 'credit' AND order_id = x) FROM public.credit_ledger_entries WHERE return_id = ret));
  PERFORM zz.check('and nets against the invoice: invoice 1550, nothing paid', (SELECT invoice_ghs = 1550 AND paid_ghs = 0 AND outstanding_ghs = 1550 FROM public.credit_invoice_status(x)),
    (SELECT invoice_ghs || '/' || paid_ghs || '/' || outstanding_ghs FROM public.credit_invoice_status(x)));
  PERFORM zz.check('the credit limit sees it: the customer owes 1550 + the other open credit orders',
    public.credit_exposure((SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)) = 1550 + 100 + 120 + 100 + 400);
  stmt := zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)));
  PERFORM zz.check('the statement shows the delivery credit (250) and the return credit (200) for order X, once each',
    (SELECT count(*) = 1 FROM jsonb_array_elements(stmt->'lines') l WHERE l->>'kind' = 'delivery_credit' AND l->>'order_id' = x::text AND (l->>'credit')::numeric = 250)
    AND (SELECT count(*) = 1 FROM jsonb_array_elements(stmt->'lines') l WHERE l->>'kind' = 'return' AND l->>'order_id' = x::text AND (l->>'credit')::numeric = 200));
  PERFORM zz.check('statement and ledger agree for order X: 2000 placed - 250 - 200 = 1550',
    (SELECT sum(CASE WHEN (l->>'debit')::numeric > 0 THEN (l->>'debit')::numeric ELSE -(l->>'credit')::numeric END) = 1550
     FROM jsonb_array_elements(stmt->'lines') l WHERE l->>'order_id' = x::text));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_order_return(%L, ''credit'', NULL)::text', ret));
  PERFORM zz.check('resolving the return again is refused (and posts nothing)', r LIKE 'ERR:%' AND (SELECT count(*) = 1 FROM public.credit_ledger_entries WHERE return_id = ret), r);
END $$;

-- 7. Other return resolutions: a replacement posts no credit; a refund on a credit order does.
DO $$
DECLARE w UUID := zz.ord('W'); r TEXT; ret UUID; item UUID; before_n INT;
BEGIN
  PERFORM zz.go(w, 'delivered');
  FOREACH r IN ARRAY ARRAY['replacement', 'refund'] LOOP
    before_n := (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = w);
    ret := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', w, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(w, 'BO C'), 'quantity', 1))::text))::uuid;
    PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.review_order_return(%L, true, NULL)::text', ret));
    PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.mark_order_return_returned(%L)::text', ret));
    SELECT id INTO item FROM public.order_return_items WHERE return_id = ret;
    PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', ret, jsonb_build_array(jsonb_build_object('return_item_id', item, 'quantity_accepted', 1, 'restock', false))::text));
    PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_order_return(%L, %L, NULL)::text', ret, r));
    PERFORM zz.check('return resolved as ' || r || (CASE r WHEN 'replacement' THEN ': no ledger entry' ELSE ': a credit note of 20 on the credit order' END),
      (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = w) = before_n + (CASE r WHEN 'replacement' THEN 0 ELSE 1 END)
      AND (SELECT count(*) = (CASE r WHEN 'replacement' THEN 0 ELSE 1 END) FROM public.credit_ledger_entries WHERE return_id = ret AND amount_ghs = 20));
  END LOOP;
END $$;

-- 8. A cash order: a credit lowers what is to be collected, and a paid cash order cannot be credited.
DO $$
DECLARE y UUID := zz.ord('Y'); n UUID := zz.ord('N'); r TEXT; rep UUID; l UUID;
BEGIN
  -- Y already has a received-in-full record, so it cannot be reported on again. Use N (paid) to test the refusal.
  r := zz.submit((SELECT u_po FROM zz.bo), n, NULL, jsonb_build_array(zz.rl(n, 'BO C', 0, 2, 1, 'broken seals')));
  rep := (r::jsonb->>'report_id')::uuid; INSERT INTO zz.dr_ids VALUES ('n1', rep);
  SELECT id INTO l FROM public.order_delivery_report_lines WHERE report_id = rep;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l, 'kind', 'damaged', 'outcome', 'credit'), jsonb_build_object('line_id', l, 'kind', 'rejected', 'outcome', 'return'))::text));
  PERFORM zz.check('a paid cash order cannot be credited (no refund process)', r LIKE 'ERR: This order has already been paid, and refunding it is not supported.%', r);
  PERFORM zz.check('the refusal left the report open and the order unchanged', (SELECT status = 'submitted' FROM public.order_delivery_reports WHERE id = rep) AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = n));
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep,
    jsonb_build_array(jsonb_build_object('line_id', l, 'kind', 'damaged', 'outcome', 'return'), jsonb_build_object('line_id', l, 'kind', 'rejected', 'outcome', 'return'))::text));
  PERFORM zz.check('but the goods can be taken back (two returns: damaged and rejected)', r::jsonb->>'returns_opened' = '2' AND (SELECT count(*) = 2 FROM public.order_returns WHERE delivery_report_id = rep), r);
  PERFORM zz.check('and no credit was posted for the cash order', NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = n) AND (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = n));
END $$;
-- An unpaid cash order: a second delivery check on a fresh order.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset q_
INSERT INTO zz.bo_orders SELECT 'Q', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('Q');
SELECT zz.go(zz.ord('Q'), 'delivered');
DO $$
DECLARE q UUID := zz.ord('Q'); r TEXT; rep UUID; l UUID; stock_before INT := zz.stock('BO C');
BEGIN
  r := zz.submit((SELECT u_po FROM zz.bo), q, NULL, jsonb_build_array(zz.rl(q, 'BO C', 3, 0, 0, 'carton missing')));
  rep := (r::jsonb->>'report_id')::uuid;
  SELECT id INTO l FROM public.order_delivery_report_lines WHERE report_id = rep;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep, jsonb_build_array(jsonb_build_object('line_id', l, 'kind', 'missing', 'outcome', 'credit'))::text));
  PERFORM zz.check('an unpaid cash order: the 3 missing units (60) are credited', r::jsonb->>'status' = 'resolved' AND (r::jsonb->>'credited')::numeric = 60, r);
  PERFORM zz.check('the amount to collect falls to 40 (placed 100) and no ledger entry exists', (SELECT effective_total_ghs = 40 AND total_ghs = 100 FROM public.orders WHERE id = q)
    AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = q));
  PERFORM zz.check('stock did not move', zz.stock('BO C') = stock_before);
  PERFORM zz.check('the statement shows the 60 as a delivery credit',
    EXISTS (SELECT 1 FROM jsonb_array_elements(zz.j((SELECT u_wo FROM zz.bo), format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.bo), (SELECT good FROM zz.bo)))->'lines') ln
            WHERE ln->>'kind' = 'delivery_credit' AND ln->>'order_id' = q::text AND (ln->>'credit')::numeric = 60));
END $$;

-- 9. A claim the wholesaler does not accept.
DO $$
DECLARE w UUID := zz.ord('W'); r TEXT; rep UUID; l UUID; avail TEXT;
BEGIN
  r := zz.submit((SELECT u_po FROM zz.bo), w, NULL, jsonb_build_array(zz.rl(w, 'BO C', 2, 0, 0, 'not on the truck')));
  rep := (r::jsonb->>'report_id')::uuid;
  avail := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO C''', w));
  PERFORM zz.check('while undecided, the 2 units are held back from returns (6 - 2 returned earlier - 2 claimed = 2)', avail = '2', avail);
  SELECT id INTO l FROM public.order_delivery_report_lines WHERE report_id = rep;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, ''Our driver has the signed waybill for all six'')::text', rep, jsonb_build_array(jsonb_build_object('line_id', l, 'kind', 'missing', 'outcome', 'reject'))::text));
  PERFORM zz.check('the wholesaler rejects the claim: the report is disputed', r::jsonb->>'status' = 'disputed' AND (r::jsonb->>'credited')::numeric = 0, r);
  PERFORM zz.check('nothing changed financially and the pharmacy sees why',
    NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE delivery_report_id = rep) AND (SELECT resolution_note LIKE 'Our driver%' FROM public.order_delivery_reports WHERE id = rep)
    AND EXISTS (SELECT 1 FROM public.order_events WHERE order_id = w AND event_type = 'delivery_report_resolved' AND summary LIKE '%did not accept%'));
  avail := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''BO C''', w));
  PERFORM zz.check('the units are returnable again after a rejection', avail = '4', avail);
  r := zz.submit((SELECT u_po FROM zz.bo), w, NULL, jsonb_build_array(zz.rl(w, 'BO C', 1, 0, 0, 'recounted: one short')));
  PERFORM zz.check('a new report can be made after a disputed one', r::jsonb->>'status' = 'submitted', r);
END $$;

-- 10. Back-order shipments reconcile on their own.
DO $$
DECLARE p UUID := zz.ord('P'); a UUID; r TEXT; s UUID; rep UUID; l UUID; stock_before INT;
BEGIN
  a := zz.amend(p, jsonb_build_array(zz.line(p, 'BO A', 2, 'write_off')), 'accept_backorder');
  PERFORM zz.go(p, 'delivered');
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.create_backorder_shipment(%L, %L::jsonb, NULL, gen_random_uuid())::text', p, jsonb_build_array(zz.sl(p, 'BO A', 2))::text));
  s := (r::jsonb->>'shipment_id')::uuid;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.submit_delivery_report(%L, %L, ''[]''::jsonb, NULL, gen_random_uuid())::text', p, s));
  PERFORM zz.check('a shipment that has not been delivered cannot be reported on', r LIKE 'ERR:%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.submit_delivery_report(%L, %L, ''[]''::jsonb, NULL, gen_random_uuid())::text', p, s));
  PERFORM zz.check('and neither can one that is only prepared', r LIKE 'ERR: That shipment has not been marked delivered yet.%', r);
  PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''packed'')::text', s));
  PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''dispatched'')::text', s));
  PERFORM zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.advance_backorder_shipment(%L, ''delivered'')::text', s));
  stock_before := zz.stock('BO A');
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.submit_delivery_report(%L, %L, %L::jsonb, ''checked'', gen_random_uuid())::text', p, s, jsonb_build_array(zz.rl(p, 'BO A', 1, 0, 0, 'one carton short'))::text));
  rep := (r::jsonb->>'report_id')::uuid;
  PERFORM zz.check('the shipment of 2 is reported with 1 missing; its expected quantity is the shipment''s (2), not the order''s', (SELECT expected_qty = 2 AND missing_qty = 1 FROM public.order_delivery_report_lines WHERE report_id = rep), r);
  PERFORM zz.check('the main delivery of the same order can still be reported on separately',
    zz.submit((SELECT u_po FROM zz.bo), p, NULL, '[]'::jsonb) LIKE '%received_in_full%');
  SELECT id INTO l FROM public.order_delivery_report_lines WHERE report_id = rep;
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.resolve_delivery_report(%L, %L::jsonb, NULL)::text', rep, jsonb_build_array(jsonb_build_object('line_id', l, 'kind', 'missing', 'outcome', 'credit'))::text));
  PERFORM zz.check('credited: 100 for the missing carton', r::jsonb->>'status' = 'resolved' AND (r::jsonb->>'credited')::numeric = 100, r);
  PERFORM zz.check('the order total (200 main + 200 shipment - 100) is 300', (SELECT effective_total_ghs = 300 FROM public.orders WHERE id = p), (SELECT effective_total_ghs::text FROM public.orders WHERE id = p));
  PERFORM zz.check('the ledger agrees: invoice 400 - 200 (back-order credit) + 200 (shipment) - 100 = 300 outstanding', (SELECT invoice_ghs = 300 AND outstanding_ghs = 300 FROM public.credit_invoice_status(p)),
    (SELECT invoice_ghs || '/' || outstanding_ghs FROM public.credit_invoice_status(p)));
  PERFORM zz.check('no stock moved by the claim or the credit', zz.stock('BO A') = stock_before);
END $$;

-- 11. Reading it back.
DO $$
DECLARE x UUID := zz.ord('X'); w JSONB; p JSONB; r TEXT;
BEGIN
  w := zz.j((SELECT u_wm FROM zz.bo), format('SELECT public.get_order_delivery_reports(%L)::text', x));
  p := zz.j((SELECT u_pc FROM zz.bo), format('SELECT public.get_order_delivery_reports(%L)::text', x));
  PERFORM zz.check('both sides see the deliveries and the reports with their decisions',
    jsonb_array_length(w->'deliveries') = 1 AND jsonb_array_length(w->'reports') = 2 AND jsonb_array_length(p->'reports') = 2
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(w->'reports') rp WHERE rp->>'status' = 'withdrawn')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(w->'reports') rp WHERE rp->>'status' = 'resolved' AND jsonb_array_length(rp->'decisions') = 3 AND (rp->>'credit_total')::numeric = 250), left(w::text, 300));
  PERFORM zz.check('the decision lists the return number', EXISTS (SELECT 1 FROM jsonb_array_elements(w->'reports') rp, jsonb_array_elements(rp->'decisions') d WHERE d->>'outcome' = 'return' AND d->>'return_number' LIKE 'RET-%'));
  PERFORM zz.check('the reporter is shown by email to the pharmacy and by business name to the wholesaler',
    EXISTS (SELECT 1 FROM jsonb_array_elements(p->'reports') rp WHERE rp->>'submitted_by_label' = 'po@zz.test')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(w->'reports') rp WHERE rp->>'submitted_by_label' = 'Good Pharmacy'));
  r := zz.val_as((SELECT u_px FROM zz.bo), format('SELECT public.get_order_delivery_reports(%L)::text', x));
  PERFORM zz.check('an unrelated business cannot read them', r LIKE 'ERR: You do not have access to this order.%', r);
  PERFORM zz.check('the main delivery is listed with what it was expected to bring (BO A 10, BO B 20)',
    (SELECT sum((e->>'quantity')::int) = 30 FROM jsonb_array_elements(w->'deliveries'->0->'expected') e));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
