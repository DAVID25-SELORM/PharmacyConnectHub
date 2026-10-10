-- Online payments (Pay Now), P2: starting a payment for an online order, checkout with Pay now (behind the platform switch), and the
-- block on accepting an unpaid online order. Run after setup.sql + migrations (through 20261107120000_payments_checkout_workflow.sql),
-- with the production guard and stock fixtures installed and the checkout compatibility migration (20261017110000) re-applied.
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


CREATE TABLE zz.mem(k TEXT PRIMARY KEY, v TEXT);
CREATE FUNCTION zz.svc(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
-- begin_order_payment as the server calls it: returns the answer as text (an error text starts with ERR:).
CREATE FUNCTION zz.begin(p_caller UUID, p_order UUID, p_ref TEXT, p_mode TEXT DEFAULT 'test') RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.begin_order_payment(%L, %L, ''paystack'', %L, %L)::text', p_caller, p_order, p_mode, p_ref)) $$;
CREATE FUNCTION zz.apply(p_ref TEXT, p_status TEXT, p_minor BIGINT, p_cur TEXT DEFAULT 'GHS') RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_payment_result(''paystack'', ''test'', %L, %L, %s, %L, ''tx-1'', ''card'', 150, ''verify'')::text', p_ref, p_status, p_minor, p_cur))::jsonb $$;
CREATE FUNCTION zz.astat(p_ref TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT status || '/' || COALESCE(flag_reason, '-') || '/' || refund_required FROM public.order_payment_attempts WHERE reference = p_ref $$;
CREATE FUNCTION zz.pstat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT payment_status::text FROM public.orders WHERE id = p_order $$;
-- Make an attempt look old (the protect trigger normally forbids touching what was asked).
CREATE FUNCTION zz.age(p_ref TEXT, p_minutes INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.order_payment_attempts DISABLE TRIGGER trg_order_payment_attempts_protect;
  UPDATE public.order_payment_attempts SET initiated_at = initiated_at - make_interval(mins => p_minutes) WHERE reference = p_ref;
  ALTER TABLE public.order_payment_attempts ENABLE TRIGGER trg_order_payment_attempts_protect;
END $$;

-- 0. The switch is off by default: checkout refuses Pay now exactly as before.
DO $$
DECLARE r TEXT; v_stock INT := zz.stock('BO C');
BEGIN
  INSERT INTO zz.mem VALUES ('stock0', v_stock::text);
  PERFORM zz.check('online payments are off by default', NOT public.online_payments_enabled() AND (public.online_payments_status() ->> 'enabled') = 'false');
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now'));
    PERFORM zz.check('with the switch off, Pay now is refused at checkout', FALSE, 'order created');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('with the switch off, Pay now is refused at checkout with the same message as before', SQLERRM = 'Online payment is not available yet. Choose another payment method.', SQLERRM);
  END;
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'bitcoin'));
    PERFORM zz.check('an unknown method is still invalid', FALSE, 'order created');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('an unknown method is still invalid', SQLERRM = 'Invalid payment method.', SQLERRM);
  END;
  PERFORM zz.check('nothing was reserved by the refused checkouts', zz.stock('BO C') = v_stock AND NOT EXISTS (SELECT 1 FROM public.orders WHERE payment_method::text = 'paystack'));
  r := zz.svc(format('SELECT public.begin_order_payment(%L, %L, ''paystack'', ''test'', ''dx-test-off-0001'')::text', (SELECT u_po FROM zz.bo), gen_random_uuid()));
  PERFORM zz.check('with the switch off, a payment cannot be started', r = 'ERR: Online payment is not available yet.', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.payments_settings');
  PERFORM zz.check('only an admin can read the switch row', r = '0' AND zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT count(*)::text FROM public.payments_settings') = '1', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'UPDATE public.payments_settings SET online_enabled = true');
  PERFORM zz.check('nobody can flip the switch through the API', r LIKE 'ERR:%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT public.online_payments_status()::text');
  PERFORM zz.check('a signed-in user can ask whether online payment is on (and in which mode)', r::jsonb = '{"enabled": false, "mode": "test"}'::jsonb, r);
END $$;

-- The platform switches online payments on (in test mode), as an administrator does in the SQL Editor.
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test';

-- Orders: A (pay now: the main one), B (cancelled), C (accept / paid), D (rate limit), E (late payment), F (ordinary cash order), G (total changes), H (marked paid elsewhere), H2 (repeated reports).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a_
INSERT INTO zz.bo_orders SELECT 'A', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset b_
INSERT INTO zz.bo_orders SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset c_
INSERT INTO zz.bo_orders SELECT 'C', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset d_
INSERT INTO zz.bo_orders SELECT 'D', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e_
INSERT INTO zz.bo_orders SELECT 'E', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'cod')) AS r \gset f_
INSERT INTO zz.bo_orders SELECT 'F', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset g_
INSERT INTO zz.bo_orders SELECT 'G', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset h_
INSERT INTO zz.bo_orders SELECT 'H', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset h2_
INSERT INTO zz.bo_orders SELECT 'H2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- 1. What checkout stored.
DO $$
DECLARE r TEXT; o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = zz.ord('A');
  PERFORM zz.check('a Pay now order is stored as an online order, unpaid and pending', o.payment_method::text = 'paystack' AND o.settlement_method = 'pay_now'
    AND o.payment_status::text = 'unpaid' AND o.status::text = 'pending' AND NOT o.is_credit_order AND o.total_ghs = 100, row_to_json(o)::text);
  PERFORM zz.check('its stock is reserved (5 units each for nine orders)', zz.stock('BO C') = (SELECT v::int FROM zz.mem WHERE k = 'stock0') - 45);
  PERFORM zz.check('an ordinary cash order is unchanged (cod, cod, unpaid)', (SELECT payment_method::text = 'cod' AND settlement_method = 'cod' AND payment_status::text = 'unpaid' FROM public.orders WHERE id = zz.ord('F')));
  PERFORM zz.check('the wholesaler was NOT told about the unpaid online order', NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'new_order' AND metadata ->> 'order_id' = zz.ord('A')::text));
  PERFORM zz.check('... but was told about the ordinary cash order, as before', EXISTS (SELECT 1 FROM public.notifications WHERE type = 'new_order' AND metadata ->> 'order_id' = zz.ord('F')::text));
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
      ARRAY[(SELECT alpha FROM zz.bo)], TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now'));
    PERFORM zz.check('pay now together with a credit request is refused as conflicting', FALSE, 'order created');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('pay now together with a credit request is refused as conflicting', SQLERRM LIKE 'Conflicting payment method%', SQLERRM);
  END;
  PERFORM zz.check('the audit trail records the settlement method', EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = zz.ord('A') AND details ->> 'settlement_method' = 'pay_now'));
END $$;

-- 2. Only the server can use the payment-start functions.
DO $$
DECLARE r TEXT; u RECORD;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.bo)), ('a wholesaler owner', (SELECT u_wo FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    r := zz.val_as(u.uid, format('SELECT public.begin_order_payment(%L, %L, ''paystack'', ''test'', ''dx-test-direct-1'')::text', u.uid, zz.ord('A')));
    PERFORM zz.check(u.label || ' cannot start a payment directly', r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(u.uid, 'SELECT public.record_attempt_authorization(gen_random_uuid(), ''https://x.test'', ''c'')::text');
    PERFORM zz.check(u.label || ' cannot record an authorization', r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(u.uid, 'SELECT public.fail_payment_attempt(gen_random_uuid(), ''x'')::text');
    PERFORM zz.check(u.label || ' cannot fail an attempt', r LIKE 'ERR: permission denied%', r);
    r := zz.val_as(u.uid, format('SELECT public.payment_attempts_to_check(%L, %L)::text', u.uid, zz.ord('A')));
    PERFORM zz.check(u.label || ' cannot list attempts to check', r LIKE 'ERR: permission denied%', r);
  END LOOP;
END $$;

-- 3. Starting a payment: who, which orders, what amount.
DO $$
DECLARE r TEXT; j JSONB;
BEGIN
  r := zz.begin((SELECT u_px FROM zz.bo), zz.ord('A'), 'dx-test-a-0001');
  PERFORM zz.check('a user from another pharmacy cannot start the payment', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.begin((SELECT u_wo FROM zz.bo), zz.ord('A'), 'dx-test-a-0001');
  PERFORM zz.check('the wholesaler cannot start the payment', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.begin((SELECT u_pa FROM zz.bo), zz.ord('A'), 'dx-test-a-0001');
  PERFORM zz.check('an assistant cannot start the payment', r = 'ERR: You do not have permission to pay for this order.', r);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('F'), 'dx-test-f-0001');
  PERFORM zz.check('an ordinary cash order cannot be paid online', r = 'ERR: This order was not placed for online payment.', r);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0001', 'live');
  PERFORM zz.check('a live-mode attempt is refused while the switch is in test mode', r = 'ERR: Online payment is not set up for this mode.', r);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'bad ref');
  PERFORM zz.check('a malformed reference is refused', r LIKE 'ERR:%', r);
  PERFORM zz.check('none of those created an attempt', (SELECT count(*) FROM public.order_payment_attempts) = 0);

  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0001');
  j := r::jsonb;
  PERFORM zz.check('the owner starts a payment: amount is the order total in cedis and pesewas, with the payer''s email', (j ->> 'reused') = 'false' AND (j ->> 'amount_ghs')::numeric = 100
    AND (j ->> 'amount_minor')::bigint = 10000 AND (j ->> 'email') = 'po@zz.test' AND (j ->> 'reference') = 'dx-test-a-0001', r);
  PERFORM zz.check('the attempt is stored initiated, by the payer, with a log entry', zz.astat('dx-test-a-0001') = 'initiated/-/false'
    AND (SELECT initiated_by = (SELECT u_po FROM zz.bo) FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0001')
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = zz.ord('A') AND kind = 'attempt_started'));
  PERFORM zz.check('the order itself is untouched by starting a payment', zz.pstat(zz.ord('A')) = 'unpaid' AND (SELECT status::text FROM public.orders WHERE id = zz.ord('A')) = 'pending');

  -- A second start before the provider answered: the first never got a checkout address, so it is closed and a new one made.
  r := zz.begin((SELECT u_pc FROM zz.bo), zz.ord('A'), 'dx-test-a-0002');
  PERFORM zz.check('a cashier can start a payment; the earlier unanswered attempt is closed', (r::jsonb ->> 'reused') = 'false' AND zz.astat('dx-test-a-0001') = 'expired/-/false'
    AND zz.astat('dx-test-a-0002') = 'initiated/-/false', r);

  -- The provider answered.
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''http://insecure.test/pay'', ''ac'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('a checkout address that is not https is refused', r LIKE 'ERR:%secure checkout address%', r);
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''http://localhost.evil.example/pay'', ''ac'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('a look-alike host is not treated as the local stand-in', r LIKE 'ERR:%secure checkout address%', r);
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''http://127.0.0.1x4010/pay'', ''ac'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('... nor a malformed loopback address', r LIKE 'ERR:%secure checkout address%', r);
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/abc'', ''ac_abc'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('the checkout address is recorded once', r = 'true', r);
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/other'', ''ac_other'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('... and cannot be replaced', r = 'false' AND (SELECT authorization_url FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002') = 'https://checkout.paystack.test/abc', r);
  r := zz.svc(format('SELECT public.fail_payment_attempt(%L, ''x'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0002')));
  PERFORM zz.check('an attempt that reached the provider is not marked "not started"', r = 'false' AND zz.astat('dx-test-a-0002') = 'initiated/-/false', r);

  -- Resuming.
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0003');
  j := r::jsonb;
  PERFORM zz.check('starting again soon resumes the same attempt (same reference and address, no new row)', (j ->> 'reused') = 'true' AND (j ->> 'reference') = 'dx-test-a-0002'
    AND (j ->> 'authorization_url') = 'https://checkout.paystack.test/abc' AND (SELECT count(*) FROM public.order_payment_attempts WHERE order_id = zz.ord('A')) = 2, r);
  PERFORM zz.age('dx-test-a-0002', 30);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0003');
  PERFORM zz.check('an attempt older than 25 minutes is not resumed: it is closed and a new one made', (r::jsonb ->> 'reused') = 'false' AND zz.astat('dx-test-a-0002') = 'expired/-/false'
    AND zz.astat('dx-test-a-0003') = 'initiated/-/false', r);

  -- Not reaching the provider.
  r := zz.svc(format('SELECT public.fail_payment_attempt(%L, ''Provider unreachable'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0003')));
  PERFORM zz.check('an attempt that never reached the provider is marked failed with the reason', r = 'true' AND zz.astat('dx-test-a-0003') = 'failed/-/false'
    AND (SELECT failure_reason FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0003') = 'Provider unreachable');
  r := zz.svc(format('SELECT public.fail_payment_attempt(%L, ''again'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-0003')));
  PERFORM zz.check('failing it twice changes nothing', r = 'false');
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0004');
  PERFORM zz.check('after a failure the payer can simply try again', (r::jsonb ->> 'reused') = 'false' AND zz.astat('dx-test-a-0004') = 'initiated/-/false', r);
END $$;

-- 4. What the screens may see, and what to ask the provider about.
DO $$
DECLARE r TEXT; j JSONB;
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('A')));
  j := r::jsonb;
  PERFORM zz.check('the pharmacy sees an awaiting-payment order with its amount and the last attempt', (j ->> 'online') = 'true' AND (j ->> 'awaiting_payment') = 'true' AND (j ->> 'side') = 'pharmacy'
    AND (j ->> 'amount_ghs')::numeric = 100 AND (j -> 'last_attempt' ->> 'status') = 'initiated', r);
  PERFORM zz.check('the summary holds no provider secrets', r NOT LIKE '%paystack.test%' AND r NOT LIKE '%access%' AND r NOT LIKE '%authorization%', r);
  r := zz.val_as((SELECT u_wm FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('A')));
  PERFORM zz.check('the wholesaler sees it too (as the supplier), without failure reasons', (r::jsonb ->> 'side') = 'wholesaler' AND (r::jsonb -> 'last_attempt' ->> 'reason') IS NULL, r);
  r := zz.val_as((SELECT u_wx FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('A')));
  PERFORM zz.check('a stranger sees nothing', r = 'ERR: Order not found.', r);
  r := zz.val_as((SELECT u_px FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('A')));
  PERFORM zz.check('another pharmacy sees nothing', r = 'ERR: Order not found.', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('F')));
  PERFORM zz.check('an ordinary cash order reports "not online"', (r::jsonb ->> 'online') = 'false', r);
  r := zz.val_as(NULL, format('SELECT public.order_payment_summary(%L)::text', zz.ord('A')));
  PERFORM zz.check('a visitor who is not signed in sees nothing', r LIKE 'ERR:%', r);

  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), zz.ord('A')));
  j := r::jsonb;
  PERFORM zz.check('the attempts to check: newest first, only those that could still be paid', jsonb_array_length(j -> 'attempts') = 3 AND (j -> 'attempts' -> 0 ->> 'reference') = 'dx-test-a-0004'
    AND (j ->> 'payment_status') = 'unpaid', r);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_px FROM zz.bo), zz.ord('A')));
  PERFORM zz.check('... and only for the paying side', r = 'ERR: Order not found.', r);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_wo FROM zz.bo), zz.ord('A')));
  PERFORM zz.check('... not for the wholesaler', r = 'ERR: Order not found.', r);
END $$;

-- 5. Cancelling an unpaid online order; nothing more can be paid for it.
DO $$
DECLARE r TEXT; v_stock INT := zz.stock('BO C');
BEGIN
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('B'), 'dx-test-b-0001');
  PERFORM zz.check('B: a payment is started', zz.astat('dx-test-b-0001') = 'initiated/-/false', r);
  UPDATE public.orders SET status = 'cancelled' WHERE id = zz.ord('B');
  PERFORM zz.check('B: cancelling an unpaid online order is allowed and returns its stock', (SELECT status::text FROM public.orders WHERE id = zz.ord('B')) = 'cancelled' AND zz.stock('BO C') = v_stock + 5);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('B'), 'dx-test-b-0002');
  PERFORM zz.check('B: a cancelled order can no longer be paid', r = 'ERR: This order was cancelled and can no longer be paid.', r);
END $$;

-- 5b. An online order keeps its payment method (and an ordinary cash order can still change its method, as before).
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.change_order_settlement_method(%L, ''cod'', ''Customer asked to pay in cash'')::text', zz.ord('C')));
  PERFORM zz.check('C: an unpaid online order''s payment method cannot be changed', r LIKE 'ERR: An online-payment order%payment method can''t be changed%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.change_order_settlement_method(%L, ''momo'', ''Customer prefers mobile money'')::text', zz.ord('F')));
  PERFORM zz.check('F: an ordinary cash order can still change its payment method', r NOT LIKE 'ERR%' AND (SELECT settlement_method FROM public.orders WHERE id = zz.ord('F')) = 'momo', r);
  PERFORM zz.check('C: nothing changed on the online order', (SELECT settlement_method || '/' || payment_method::text FROM public.orders WHERE id = zz.ord('C')) = 'pay_now/paystack');
END $$;

-- 6. An unpaid online order cannot be accepted; once paid it can.
DO $$
DECLARE r TEXT; j JSONB; s TEXT;
BEGIN
  BEGIN
    UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('C');
    PERFORM zz.check('C: the wholesaler cannot accept an unpaid online order', FALSE, 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('C: the wholesaler cannot accept an unpaid online order', SQLERRM LIKE '%waiting for the pharmacy''s online payment%', SQLERRM);
  END;
  FOREACH s IN ARRAY ARRAY['picking', 'packed', 'dispatched', 'delivered'] LOOP
    BEGIN
      UPDATE public.orders SET status = s::public.order_status WHERE id = zz.ord('C');
      PERFORM zz.check('C: it cannot be moved to ' || s || ' either', FALSE, 'moved');
    EXCEPTION WHEN OTHERS THEN
      PERFORM zz.check('C: it cannot be moved to ' || s || ' either', SQLERRM LIKE '%waiting for the pharmacy''s online payment%' OR SQLERRM LIKE 'Invalid order transition%', SQLERRM);
    END;
  END LOOP;
  PERFORM zz.check('C: still pending and unpaid', (SELECT status::text FROM public.orders WHERE id = zz.ord('C')) = 'pending' AND zz.pstat(zz.ord('C')) = 'unpaid');
  BEGIN
    UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('F');
    PERFORM zz.check('F: an ordinary cash order is accepted as before', (SELECT status::text FROM public.orders WHERE id = zz.ord('F')) = 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('F: an ordinary cash order is accepted as before', FALSE, SQLERRM);
  END;

  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('C'), 'dx-test-c-0001');
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/c1'', ''ac_c1'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-c-0001')));
  j := zz.apply('dx-test-c-0001', 'success', 10000);
  PERFORM zz.check('C: the verified payment marks the order paid', (j ->> 'outcome') = 'applied' AND zz.pstat(zz.ord('C')) = 'paid' AND zz.astat('dx-test-c-0001') = 'succeeded/-/false', j::text);
  PERFORM zz.check('C: the wholesaler was told of a new, paid order; the pharmacy that payment was confirmed',
    EXISTS (SELECT 1 FROM public.notifications WHERE title = 'New paid order' AND user_id = (SELECT u_wm FROM zz.bo) AND metadata ->> 'order_id' = zz.ord('C')::text)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Payment confirmed' AND user_id = (SELECT u_po FROM zz.bo) AND metadata ->> 'order_id' = zz.ord('C')::text));
  PERFORM zz.check('C: no "Payment received" text is sent any more', NOT EXISTS (SELECT 1 FROM public.notifications WHERE title = 'Payment received' AND metadata ->> 'order_id' = zz.ord('C')::text));
  BEGIN
    UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('C');
    PERFORM zz.check('C: once paid, the wholesaler can accept it', (SELECT status::text FROM public.orders WHERE id = zz.ord('C')) = 'accepted');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('C: once paid, the wholesaler can accept it', FALSE, SQLERRM);
  END;
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('C'), 'dx-test-c-0002');
  PERFORM zz.check('C: a paid order cannot be paid again', r = 'ERR: This order is already paid.', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('C')));
  PERFORM zz.check('C: the summary shows it paid and no longer awaiting payment', (r::jsonb ->> 'payment_status') = 'paid' AND (r::jsonb ->> 'awaiting_payment') = 'false', r);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), zz.ord('C')));
  PERFORM zz.check('C: nothing is left to check at the provider', jsonb_array_length(r::jsonb -> 'attempts') = 0 AND (r::jsonb ->> 'payment_status') = 'paid', r);
END $$;

-- 7. Rate limit: six attempts in an hour for one order, then it waits.
DO $$
DECLARE r TEXT; i INT;
BEGIN
  FOR i IN 1..5 LOOP
    INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, status, failure_reason)
    VALUES (zz.ord('D'), 'paystack', 'test', 'dx-test-d-000' || i, 100, 10000, 'failed', 'declined');
  END LOOP;
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('D'), 'dx-test-d-0006');
  PERFORM zz.check('D: the sixth attempt in an hour is allowed', (r::jsonb ->> 'reused') = 'false', r);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('D'), 'dx-test-d-0007');
  PERFORM zz.check('D: the seventh is refused with a clear message', r LIKE 'ERR: Too many payment attempts%', r);
  PERFORM zz.check('D: nothing was created or closed by the refusal', zz.astat('dx-test-d-0006') = 'initiated/-/false' AND NOT EXISTS (SELECT 1 FROM public.order_payment_attempts WHERE reference = 'dx-test-d-0007'));
  PERFORM zz.age('dx-test-d-0006', 90);
  PERFORM zz.age('dx-test-d-0001', 90);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('D'), 'dx-test-d-0008');
  PERFORM zz.check('D: an hour later the count is lower and a new attempt is allowed', (r::jsonb ->> 'reused') = 'false' AND zz.astat('dx-test-d-0008') = 'initiated/-/false', r);
END $$;


-- 7b. The amount asked is always the order's current total; an order marked paid some other way cannot be paid again.
DO $$
DECLARE r TEXT; j JSONB;
BEGIN
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('G'), 'dx-test-g-0001');
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/g1'', ''ac_g1'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-g-0001')));
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 90 WHERE id = zz.ord('G');
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('G'), 'dx-test-g-0002');
  j := r::jsonb;
  PERFORM zz.check('G: the total changed after a payment was started: it is not resumed; a new attempt asks for the new amount', (j ->> 'reused') = 'false' AND (j ->> 'amount_ghs')::numeric = 90
    AND (j ->> 'amount_minor')::bigint = 9000 AND zz.astat('dx-test-g-0001') = 'expired/-/false', r);
  j := zz.apply('dx-test-g-0001', 'success', 10000);
  PERFORM zz.check('G: a payment of the OLD amount is flagged, not applied', (j ->> 'outcome') = 'flagged' AND zz.pstat(zz.ord('G')) = 'unpaid', j::text);
  j := zz.apply('dx-test-g-0002', 'success', 9000);
  PERFORM zz.check('G: the payment of the new amount pays the order', (j ->> 'outcome') = 'applied' AND zz.pstat(zz.ord('G')) = 'paid', j::text);

  ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
  UPDATE public.orders SET payment_status = 'paid' WHERE id = zz.ord('H');
  ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('H'), 'dx-test-h-0001');
  PERFORM zz.check('H: an order that is already marked paid cannot be paid again, even with no attempt on record', r = 'ERR: This order is already paid.', r);
END $$;
-- 8. A payment that arrives for a closed (expired) attempt still pays the order once; the second one is flagged for refund.
DO $$
DECLARE r TEXT; j JSONB;
BEGIN
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('E'), 'dx-test-e-0001');
  r := zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.paystack.test/e1'', ''ac_e1'')::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-e-0001')));
  PERFORM zz.age('dx-test-e-0001', 30);
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('E'), 'dx-test-e-0002');
  PERFORM zz.check('E: the old attempt is closed and a second one is open', zz.astat('dx-test-e-0001') = 'expired/-/false' AND zz.astat('dx-test-e-0002') = 'initiated/-/false', r);
  j := zz.apply('dx-test-e-0001', 'success', 10000);
  PERFORM zz.check('E: the customer paid on the first (expired) attempt: the order is paid', (j ->> 'outcome') = 'applied' AND zz.pstat(zz.ord('E')) = 'paid', j::text);
  j := zz.apply('dx-test-e-0002', 'success', 10000);
  PERFORM zz.check('E: the second payment is flagged as a double payment to refund, and the order stays paid once',
    (j ->> 'outcome') = 'flagged' AND zz.astat('dx-test-e-0002') = 'flagged/already_paid/true' AND zz.pstat(zz.ord('E')) = 'paid'
    AND (SELECT count(*) FROM public.order_payment_attempts WHERE order_id = zz.ord('E') AND status = 'succeeded') = 1, j::text);
END $$;


-- 8b. The return page asks every few seconds: a repeated "abandoned" or "failed" report is recorded once; a later success still pays.
DO $$
DECLARE r TEXT; j JSONB;
BEGIN
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('H2'), 'dx-test-h2-0001');
  j := zz.apply('dx-test-h2-0001', 'abandoned', 10000);
  PERFORM zz.apply('dx-test-h2-0001', 'abandoned', 10000);
  PERFORM zz.apply('dx-test-h2-0001', 'abandoned', 10000);
  PERFORM zz.check('H2: an unchanged abandoned report repeated is logged once', (SELECT count(*) FROM public.order_payment_log WHERE order_id = zz.ord('H2') AND kind = 'payment_abandoned') = 1
    AND zz.astat('dx-test-h2-0001') = 'abandoned/-/false', j::text);
  j := zz.apply('dx-test-h2-0001', 'failed', 10000);
  PERFORM zz.check('H2: a changed status is still recorded (abandoned, then failed)', (SELECT count(*) FROM public.order_payment_log WHERE order_id = zz.ord('H2') AND kind = 'payment_failed') = 1 AND zz.astat('dx-test-h2-0001') = 'failed/-/false', j::text);
  j := zz.apply('dx-test-h2-0001', 'success', 10000);
  PERFORM zz.check('H2: and a later success on that attempt still pays the order', (j ->> 'outcome') = 'applied' AND zz.pstat(zz.ord('H2')) = 'paid', j::text);
END $$;
-- 9. The switch is turned off again: nothing new can start, and checkout refuses Pay now; existing paid orders are untouched.
UPDATE public.payments_settings SET online_enabled = FALSE;
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.begin((SELECT u_po FROM zz.bo), zz.ord('A'), 'dx-test-a-0009');
  PERFORM zz.check('switched off again: a payment cannot be started', r = 'ERR: Online payment is not available yet.', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now'));
    PERFORM zz.check('switched off again: Pay now is refused at checkout', FALSE, 'order created');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('switched off again: Pay now is refused at checkout', SQLERRM LIKE 'Online payment is not available yet%', SQLERRM);
  END;
  PERFORM zz.check('switched off again: orders already paid stay paid', zz.pstat(zz.ord('C')) = 'paid' AND zz.pstat(zz.ord('E')) = 'paid');
  r := zz.svc(format('SELECT public.apply_payment_result(''paystack'', ''test'', ''dx-test-a-0004'', ''success'', 10000, ''GHS'', ''tx-9'', ''card'', 100, ''webhook'')::text'));
  PERFORM zz.check('switched off again: a payment already in flight is still recorded when it is verified', (r::jsonb ->> 'outcome') = 'applied' AND zz.pstat(zz.ord('A')) = 'paid', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
