-- Online payments (Pay Now), P1: the provider-neutral core (provider notifications, attempts, the single function that records a verified result), against production-like rules.
-- Run after setup.sql + migrations (through 20261106110000_payments_core_workflow.sql), with the production guard and stock
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

-- Orders for the payment core: eight cash orders (BO C x5 @20 = 100 each) turned into online (paystack) orders, plus one ordinary cash order.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p1_
INSERT INTO zz.bo_orders SELECT 'P1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p2_
INSERT INTO zz.bo_orders SELECT 'P2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p3_
INSERT INTO zz.bo_orders SELECT 'P3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p4_
INSERT INTO zz.bo_orders SELECT 'P4', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p5_
INSERT INTO zz.bo_orders SELECT 'P5', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p6_
INSERT INTO zz.bo_orders SELECT 'P6', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- P1..P5 become online orders awaiting payment; P6 stays an ordinary cash order.
-- (checkout will create these orders as online orders in P2; production's guard forbids changing the method afterwards, so the guard
-- is switched off for this fixture only.)
ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
UPDATE public.orders SET payment_method = 'paystack', settlement_method = 'pay_now' WHERE id IN (zz.ord('P1'), zz.ord('P2'), zz.ord('P3'), zz.ord('P4'), zz.ord('P5'));
ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;

CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT, p_amount NUMERIC DEFAULT NULL, p_mode TEXT DEFAULT 'test') RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
  SELECT p_order, 'paystack', p_mode, p_ref, COALESCE(p_amount, COALESCE(o.effective_total_ghs, o.total_ghs)),
         public.payment_minor_from_ghs(COALESCE(p_amount, COALESCE(o.effective_total_ghs, o.total_ghs)))
  FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  RETURN v_id;
END $$;
-- Call a service-role-only function as the service role (what the server endpoints do).
CREATE FUNCTION zz.svc(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
CREATE FUNCTION zz.apply(p_ref TEXT, p_status TEXT, p_minor BIGINT, p_cur TEXT DEFAULT 'GHS', p_mode TEXT DEFAULT 'test', p_source TEXT DEFAULT 'verify') RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_payment_result(''paystack'', %L, %L, %L, %s, %L, ''tx-1'', ''card'', 150, %L)::text', p_mode, p_ref, p_status, p_minor, p_cur, p_source))::jsonb $$;
CREATE FUNCTION zz.pstat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT payment_status::text FROM public.orders WHERE id = p_order $$;
CREATE FUNCTION zz.astat(p_ref TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT status || '/' || COALESCE(flag_reason, '-') || '/' || refund_required FROM public.order_payment_attempts WHERE reference = p_ref $$;

-- 0. Starting point.
DO $$
BEGIN
  PERFORM zz.check('five online orders awaiting payment, one ordinary cash order', (SELECT count(*) = 5 FROM public.orders WHERE payment_method::text = 'paystack' AND payment_status::text = 'unpaid')
    AND (SELECT payment_method::text = 'cod' FROM public.orders WHERE id = zz.ord('P6')));
  PERFORM zz.check('the conversion to the provider''s minor unit is exact', public.payment_minor_from_ghs(100) = 10000 AND public.payment_minor_from_ghs(0.1 + 0.2) = 30 AND public.payment_minor_from_ghs(12.34) = 1234
    AND public.payment_minor_from_ghs(1999.99) = 199999);
END $$;

-- 1. Nobody but the service role can use any of it.
DO $$
DECLARE r TEXT; u RECORD;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.bo)), ('a wholesaler owner', (SELECT u_wo FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.val_as(u.uid, 'SELECT public.apply_payment_result(''paystack'', ''test'', ''x'', ''success'', 1, ''GHS'')::text');
    PERFORM zz.check(u.label || ' cannot apply a payment result', r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(u.uid, 'SELECT public.record_payment_provider_event(''paystack'', ''k'', ''charge.success'', ''x'', ''test'', ''{}''::jsonb)::text');
    PERFORM zz.check(u.label || ' cannot record a provider event', r LIKE 'ERR: permission denied%', r);
  END LOOP;
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.order_payment_attempts');
  PERFORM zz.check('a pharmacy cannot read the attempts', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.payment_provider_events');
  PERFORM zz.check('a pharmacy cannot read provider events', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT access_code FROM public.order_payment_attempts LIMIT 1');
  PERFORM zz.check('even an admin cannot read the provider access code through the API', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT count(*)::text FROM public.order_payment_attempts');
  PERFORM zz.check('an admin can read the rest of an attempt', r NOT LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor) VALUES (gen_random_uuid(), ''paystack'', ''test'', ''DX-12345678'', 1, 100)');
  PERFORM zz.check('nobody can write an attempt directly', r LIKE 'ERR:%', r);
END $$;

-- 2. Provider notifications are stored once.
DO $$
DECLARE r JSONB; r2 JSONB; ev UUID;
BEGIN
  r := zz.svc('SELECT public.record_payment_provider_event(''paystack'', ''charge.success:111'', ''charge.success'', ''DX-AAAA0001'', ''test'', ''{"a":1}''::jsonb)::text')::jsonb;
  ev := (r->>'event_id')::uuid;
  PERFORM zz.check('a new notification is stored (not a duplicate, not processed)', NOT (r->>'duplicate')::boolean AND NOT (r->>'already_processed')::boolean, r::text);
  r2 := zz.svc('SELECT public.record_payment_provider_event(''paystack'', ''charge.success:111'', ''charge.success'', ''DX-AAAA0001'', ''test'', ''{"a":1}''::jsonb)::text')::jsonb;
  PERFORM zz.check('the same notification again is recognised as a duplicate (same row)', (r2->>'duplicate')::boolean AND (r2->>'event_id')::uuid = ev AND (SELECT count(*) = 1 FROM public.payment_provider_events WHERE dedupe_key = 'charge.success:111'), r2::text);
  PERFORM zz.svc(format('SELECT public.finish_payment_provider_event(%L, ''applied'', NULL)::text', ev));
  r2 := zz.svc('SELECT public.record_payment_provider_event(''paystack'', ''charge.success:111'', ''charge.success'', ''DX-AAAA0001'', ''test'', ''{"a":1}''::jsonb)::text')::jsonb;
  PERFORM zz.check('once processed, a repeat says so', (r2->>'already_processed')::boolean, r2::text);
  PERFORM zz.svc(format('SELECT public.finish_payment_provider_event(%L, ''error'', ''boom'')::text', ev));
  r2 := zz.svc('SELECT public.record_payment_provider_event(''paystack'', ''charge.success:111'', ''charge.success'', ''DX-AAAA0001'', ''test'', ''{"a":1}''::jsonb)::text')::jsonb;
  PERFORM zz.check('a notification whose processing failed is NOT treated as done (it must be retried)', (r2->>'duplicate')::boolean AND NOT (r2->>'already_processed')::boolean, r2::text);
  BEGIN UPDATE public.payment_provider_events SET payload = '{}'::jsonb WHERE id = ev; PERFORM zz.check('a stored notification cannot be edited', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a stored notification cannot be edited', SQLERRM LIKE '%append-only%', SQLERRM); END;
  BEGIN DELETE FROM public.payment_provider_events WHERE id = ev; PERFORM zz.check('nor deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('nor deleted', SQLERRM LIKE '%append-only%', SQLERRM); END;
  PERFORM zz.check('a mode that is neither test nor live is refused',
    zz.svc('SELECT public.record_payment_provider_event(''paystack'', ''charge.success:222'', ''charge.success'', NULL, ''staging'', ''{}''::jsonb)::text') LIKE 'ERR:%violates check constraint%');
END $$;

-- 3. A verified payment is applied once (P1).
DO $$
DECLARE o UUID := zz.ord('P1'); a UUID; r JSONB; n_before INT; wn_before INT;
BEGIN
  a := zz.att(o, 'DX-TEST-0001');
  PERFORM zz.check('the attempt records exactly what was asked (100.00 = 10000 pesewas, GHS)', (SELECT amount_ghs = 100 AND amount_minor = 10000 AND currency = 'GHS' AND status = 'initiated' FROM public.order_payment_attempts WHERE id = a));
  n_before := (SELECT count(*) FROM public.notifications WHERE type = 'payment_update');
  r := zz.apply('DX-TEST-0001', 'success', 10000);
  PERFORM zz.check('a verified success for the exact amount is applied', r->>'outcome' = 'applied' AND (r->>'order_paid')::boolean, r::text);
  PERFORM zz.check('the attempt succeeded with what the provider verified', (SELECT status = 'succeeded' AND verified_amount_minor = 10000 AND channel = 'card' AND fee_minor = 150 AND provider_transaction_id = 'tx-1' AND paid_at IS NOT NULL AND NOT refund_required FROM public.order_payment_attempts WHERE id = a));
  PERFORM zz.check('the order is paid, with its reference', zz.pstat(o) = 'paid' AND (SELECT paid_at IS NOT NULL AND payment_confirmed_at IS NOT NULL AND paystack_reference = 'DX-TEST-0001' FROM public.orders WHERE id = o));
  PERFORM zz.check('the timeline, audit and log record it', EXISTS (SELECT 1 FROM public.order_events WHERE order_id = o AND event_type = 'payment_received' AND actor_side = 'system')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Online payment received' AND record_id = o)
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'payment_applied'));
  PERFORM zz.check('both sides were told (pharmacy: payment confirmed; wholesaler: online payment received)', EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Payment confirmed' AND user_id = (SELECT u_po FROM zz.bo))
    AND EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Payment received' AND user_id = (SELECT u_wm FROM zz.bo))
    AND (SELECT count(*) FROM public.notifications WHERE type = 'payment_update') > n_before);
  wn_before := (SELECT count(*) FROM public.notifications WHERE type = 'payment_update');
  r := zz.apply('DX-TEST-0001', 'success', 10000, 'GHS', 'test', 'webhook');
  PERFORM zz.check('the same result again (the webhook after the verify) is a duplicate and changes nothing', r->>'outcome' = 'duplicate'
    AND (SELECT count(*) FROM public.notifications WHERE type = 'payment_update') = wn_before AND (SELECT count(*) = 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'payment_applied'), r::text);
  r := zz.apply('DX-TEST-0001', 'failed', 10000);
  PERFORM zz.check('a later "failed" report cannot undo a paid attempt', r->>'outcome' = 'duplicate' AND zz.pstat(o) = 'paid' AND (SELECT status = 'succeeded' FROM public.order_payment_attempts WHERE id = a), r::text);
  PERFORM zz.check('the order timeline reads cleanly', (SELECT count(*) = 1 FROM public.order_events WHERE order_id = o AND event_type = 'payment_received'));
END $$;

-- 4. Wrong amount, wrong currency, unknown reference, wrong mode: never paid.
DO $$
DECLARE o UUID := zz.ord('P2'); r JSONB; n_before INT := (SELECT count(*) FROM public.notifications WHERE type = 'payment_update');
BEGIN
  PERFORM zz.att(o, 'DX-TEST-0002');
  r := zz.apply('DX-TEST-0002', 'success', 9999);
  PERFORM zz.check('one pesewa less than asked is flagged, not paid', r->>'outcome' = 'flagged' AND r->>'flag' = 'amount_mismatch' AND zz.pstat(o) = 'unpaid', r::text);
  PERFORM zz.check('the attempt says why and no refund is assumed (a person decides)', zz.astat('DX-TEST-0002') = 'flagged/amount_mismatch/false');
  PERFORM zz.check('nobody was told the order is paid', (SELECT count(*) FROM public.notifications WHERE type = 'payment_update') = n_before);
  r := zz.apply('DX-TEST-0002', 'success', 10000);
  PERFORM zz.check('once flagged, a later correct-looking result does not reopen it (duplicate)', r->>'outcome' = 'duplicate' AND zz.pstat(o) = 'unpaid', r::text);
  PERFORM zz.check('the log records the flag', EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'payment_flagged'));

  o := zz.ord('P3');
  PERFORM zz.att(o, 'DX-TEST-0003');
  r := zz.apply('DX-TEST-0003', 'success', 10000, 'USD');
  PERFORM zz.check('another currency is flagged', r->>'flag' = 'currency_mismatch' AND zz.pstat(o) = 'unpaid', r::text);

  r := zz.apply('DX-NOSUCH-REF', 'success', 10000);
  PERFORM zz.check('an unknown reference does nothing', r->>'outcome' = 'unknown_reference', r::text);

  o := zz.ord('P4');
  PERFORM zz.att(o, 'DX-TEST-0004', NULL, 'test');
  r := zz.apply('DX-TEST-0004', 'success', 10000, 'GHS', 'live');
  PERFORM zz.check('a live-mode result for a test-mode attempt is refused', r->>'outcome' = 'mode_mismatch' AND zz.pstat(o) = 'unpaid' AND zz.astat('DX-TEST-0004') = 'initiated/-/false', r::text);
END $$;

-- 5. Failed, abandoned, pending, unknown; a failed attempt can still succeed on the same reference.
DO $$
DECLARE o UUID := zz.ord('P4'); r JSONB;
BEGIN
  r := zz.apply('DX-TEST-0004', 'pending', 10000);
  PERFORM zz.check('pending moves an initiated attempt to pending', r->>'outcome' = 'pending' AND zz.astat('DX-TEST-0004') = 'pending/-/false', r::text);
  r := zz.apply('DX-TEST-0004', 'something_new', 10000);
  PERFORM zz.check('a status it does not know is ignored, and logged', r->>'outcome' = 'ignored' AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'status_ignored'), r::text);
  r := zz.svc('SELECT public.apply_payment_result(''paystack'', ''test'', ''DX-TEST-0004'', ''failed'', 10000, ''GHS'', NULL, ''card'', NULL, ''verify'', NULL, ''Declined by the bank'')::text')::jsonb;
  PERFORM zz.check('failed is recorded with its reason and the order stays unpaid', r->>'outcome' = 'failed' AND zz.pstat(o) = 'unpaid'
    AND (SELECT status = 'failed' AND failure_reason = 'Declined by the bank' FROM public.order_payment_attempts WHERE reference = 'DX-TEST-0004'), r::text);
  r := zz.apply('DX-TEST-0004', 'success', 10000);
  PERFORM zz.check('the customer retried on the same reference and it worked: applied after a failure', r->>'outcome' = 'applied' AND zz.pstat(o) = 'paid'
    AND (SELECT failure_reason IS NULL FROM public.order_payment_attempts WHERE reference = 'DX-TEST-0004'), r::text);
  o := zz.ord('P5');
  PERFORM zz.att(o, 'DX-TEST-0005');
  r := zz.apply('DX-TEST-0005', 'abandoned', 10000);
  PERFORM zz.check('abandoned is recorded and the order stays unpaid', r->>'outcome' = 'abandoned' AND zz.pstat(o) = 'unpaid' AND zz.astat('DX-TEST-0005') = 'abandoned/-/false', r::text);
END $$;

-- 6. Late payment, double payment, a changed order, an order that is not online.
DO $$
DECLARE o UUID := zz.ord('P5'); r JSONB; a2 UUID; n_before INT;
BEGIN
  -- P5 has an abandoned attempt. A second attempt for the same order; both are paid at Paystack.
  a2 := zz.att(o, 'DX-TEST-0006');
  r := zz.apply('DX-TEST-0006', 'success', 10000);
  PERFORM zz.check('P5: the second attempt pays the order', r->>'outcome' = 'applied' AND zz.pstat(o) = 'paid', r::text);
  PERFORM zz.att(o, 'DX-TEST-0007');
  r := zz.apply('DX-TEST-0007', 'success', 10000);
  PERFORM zz.check('a third attempt that also paid is a DOUBLE payment: flagged, refund required, the order is not changed', r->>'outcome' = 'flagged' AND r->>'flag' = 'already_paid'
    AND (r->>'refund_required')::boolean AND zz.astat('DX-TEST-0007') = 'flagged/already_paid/true' AND zz.pstat(o) = 'paid', r::text);
  r := zz.apply('DX-TEST-0005', 'success', 10000);
  PERFORM zz.check('the first, abandoned attempt turning out to have paid too is also a double payment', r->>'flag' = 'already_paid' AND (r->>'refund_required')::boolean, r::text);
  PERFORM zz.check('only one attempt per order is ever the one that paid it', (SELECT count(*) = 1 FROM public.order_payment_attempts WHERE order_id = o AND status = 'succeeded' AND NOT refund_required));
  BEGIN
    UPDATE public.order_payment_attempts SET status = 'succeeded', refund_required = FALSE, flag_reason = NULL WHERE reference = 'DX-TEST-0007';
    PERFORM zz.check('the database itself refuses a second paying attempt', FALSE, 'updated');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('the database itself refuses a second paying attempt', TRUE); END;
END $$;
-- Two more online orders: P7 (cancelled while its customer is still paying) and P8 (its total changes after the attempt).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p7_
INSERT INTO zz.bo_orders SELECT 'P7', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset p8_
INSERT INTO zz.bo_orders SELECT 'P8', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
UPDATE public.orders SET payment_method = 'paystack', settlement_method = 'pay_now' WHERE id IN (zz.ord('P7'), zz.ord('P8'));
ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
DO $$
DECLARE o UUID := zz.ord('P7'); r JSONB; stock_before INT := zz.stock('BO C');
BEGIN
  PERFORM zz.att(o, 'DX-TEST-0008');
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'payment window ended' WHERE id = o;
  r := zz.apply('DX-TEST-0008', 'success', 10000);
  PERFORM zz.check('a payment for a cancelled order is recorded as RECEIVED, refund required, and the order is NOT revived', r->>'outcome' = 'late' AND (r->>'refund_required')::boolean
    AND zz.pstat(o) = 'unpaid' AND (SELECT status::text = 'cancelled' FROM public.orders WHERE id = o) AND zz.astat('DX-TEST-0008') = 'succeeded/order_cancelled/true', r::text);
  PERFORM zz.check('the late payment is in the log', EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'late_payment'));
  r := zz.apply('DX-TEST-0008', 'success', 10000, 'GHS', 'test', 'webhook');
  PERFORM zz.check('and a repeat of it is a duplicate', r->>'outcome' = 'duplicate', r::text);

  -- The order's total changed after the attempt was made.
  o := zz.ord('P8');
  PERFORM zz.att(o, 'DX-TEST-0009', 150);
  r := zz.apply('DX-TEST-0009', 'success', 15000);
  PERFORM zz.check('the order is worth 100 but 150 was asked and paid: flagged as a changed order, refund required, not paid', r->>'flag' = 'order_total_changed' AND (r->>'refund_required')::boolean AND zz.pstat(o) = 'unpaid', r::text);

  -- An ordinary cash order can never be marked paid by a provider result.
  o := zz.ord('P6');
  PERFORM zz.att(o, 'DX-TEST-0010');
  r := zz.apply('DX-TEST-0010', 'success', 10000);
  PERFORM zz.check('an ordinary cash order is flagged, not paid', r->>'flag' = 'order_not_online' AND zz.pstat(o) = 'unpaid', r::text);
END $$;

-- 6b. Cancelling an order that was paid online keeps the money visible: the attempt that paid it needs a refund.
DO $$
DECLARE o UUID := zz.ord('P1');
BEGIN
  PERFORM zz.check('before the cancellation the paying attempt needs no refund', zz.astat('DX-TEST-0001') = 'succeeded/-/false');
  UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'customer asked' WHERE id = o;
  PERFORM zz.check('cancelling a paid online order marks its paying attempt refund-required, and logs it', zz.astat('DX-TEST-0001') = 'succeeded/order_cancelled_after_payment/true'
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'refund_required'));
  PERFORM zz.check('the order itself is cancelled as usual (stock restored by the existing path)', (SELECT status::text = 'cancelled' FROM public.orders WHERE id = o));
  PERFORM zz.check('cancelling an ordinary cash order touches no payment record', NOT EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = zz.ord('P6') AND kind = 'refund_required'));
END $$;

-- 7. What an attempt asked for never changes; the log is append-only.
DO $$
BEGIN
  BEGIN UPDATE public.order_payment_attempts SET amount_ghs = 1, amount_minor = 100 WHERE reference = 'DX-TEST-0001'; PERFORM zz.check('the amount asked cannot be changed', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('the amount asked cannot be changed', SQLERRM LIKE 'What was asked of the provider cannot be changed%', SQLERRM); END;
  BEGIN UPDATE public.order_payment_attempts SET reference = 'DX-CHANGED-1' WHERE reference = 'DX-TEST-0001'; PERFORM zz.check('the reference cannot be changed', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('the reference cannot be changed', SQLERRM LIKE 'What was asked of the provider cannot be changed%', SQLERRM); END;
  BEGIN DELETE FROM public.order_payment_attempts WHERE reference = 'DX-TEST-0001'; PERFORM zz.check('an attempt cannot be deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('an attempt cannot be deleted', SQLERRM LIKE 'Payment attempts are never deleted%', SQLERRM); END;
  BEGIN UPDATE public.order_payment_log SET summary = 'x'; PERFORM zz.check('the log cannot be edited', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('the log cannot be edited', SQLERRM LIKE '%append-only%', SQLERRM); END;
  BEGIN INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor) VALUES (zz.ord('P6'), 'paystack', 'test', 'DX-TEST-0011', 100, 9999);
    PERFORM zz.check('an attempt whose minor amount does not match its cedis amount is refused', FALSE, 'inserted');
  EXCEPTION WHEN check_violation THEN PERFORM zz.check('an attempt whose minor amount does not match its cedis amount is refused', TRUE); END;
  BEGIN INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor) VALUES (zz.ord('P6'), 'paystack', 'test', 'DX-TEST-0001', 100, 10000);
    PERFORM zz.check('a reference is used once', FALSE, 'inserted');
  EXCEPTION WHEN unique_violation THEN PERFORM zz.check('a reference is used once', TRUE); END;
  BEGIN INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, currency) VALUES (zz.ord('P6'), 'paystack', 'test', 'DX-TEST-0012', 100, 10000, 'USD');
    PERFORM zz.check('only cedis can be asked for', FALSE, 'inserted');
  EXCEPTION WHEN check_violation THEN PERFORM zz.check('only cedis can be asked for', TRUE); END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
