-- Online payments (Pay Now), P3: alerts, checking attempts with the provider, expiring unpaid online orders, the daily comparison and the admin views.
-- Run after setup.sql + migrations (through 20261108110000_payments_operations_workflow.sql), with the production guard and stock fixtures installed
-- and the checkout compatibility migration (20261017110000) re-applied. Successful create_marketplace_orders calls are top-level statements.
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
CREATE FUNCTION zz.astat(p_ref TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT status || '/' || COALESCE(flag_reason, '-') || '/' || refund_required FROM public.order_payment_attempts WHERE reference = p_ref $$;
CREATE FUNCTION zz.pstat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT payment_status::text FROM public.orders WHERE id = p_order $$;
CREATE FUNCTION zz.ostat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT status::text || '/' || payment_status::text FROM public.orders WHERE id = p_order $$;
-- An attempt for an order, started p_minutes ago (the protect trigger normally forbids touching what was asked, so it is inserted already old).
CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT, p_minutes INT DEFAULT 0, p_status TEXT DEFAULT 'initiated', p_checked_minutes INT DEFAULT NULL) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, initiated_at, status, last_checked_at)
  SELECT p_order, 'paystack', 'test', p_ref, o.total_ghs, public.payment_minor_from_ghs(o.total_ghs), now() - make_interval(mins => p_minutes), p_status,
         CASE WHEN p_checked_minutes IS NULL THEN NULL ELSE now() - make_interval(mins => p_checked_minutes) END
  FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  RETURN v_id;
END $$;
-- Make an order look old.
CREATE FUNCTION zz.age_order(p_order UUID, p_minutes INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
  UPDATE public.orders SET created_at = now() - make_interval(mins => p_minutes) WHERE id = p_order;
  ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
END $$;
CREATE FUNCTION zz.alerts(p_kind TEXT, p_order UUID DEFAULT NULL) RETURNS INT LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.payment_alerts WHERE kind = p_kind AND status = 'open' AND (p_order IS NULL OR order_id = p_order) $$;

UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test';
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a1_
INSERT INTO zz.bo_orders SELECT 'A1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a2_
INSERT INTO zz.bo_orders SELECT 'A2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a3_
INSERT INTO zz.bo_orders SELECT 'A3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset a4_
INSERT INTO zz.bo_orders SELECT 'A4', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e1_
INSERT INTO zz.bo_orders SELECT 'E1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e2_
INSERT INTO zz.bo_orders SELECT 'E2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e3_
INSERT INTO zz.bo_orders SELECT 'E3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e4_
INSERT INTO zz.bo_orders SELECT 'E4', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e5_
INSERT INTO zz.bo_orders SELECT 'E5', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset e6_
INSERT INTO zz.bo_orders SELECT 'E6', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r1_
INSERT INTO zz.bo_orders SELECT 'R1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r2_
INSERT INTO zz.bo_orders SELECT 'R2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r3_
INSERT INTO zz.bo_orders SELECT 'R3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r4_
INSERT INTO zz.bo_orders SELECT 'R4', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r5_
INSERT INTO zz.bo_orders SELECT 'R5', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

UPDATE public.payments_settings SET online_enabled = FALSE;
INSERT INTO zz.mem VALUES ('stock0', zz.stock('BO C')::text);

-- 1. Alerts: a payment that needs a person always raises one, whichever path recorded it.
DO $$
DECLARE j JSONB; n0 INT;
BEGIN
  -- A1: a payment of the wrong amount is flagged.
  PERFORM zz.att(zz.ord('A1'), 'dx-test-a1-0001', 5);
  j := zz.apply('dx-test-a1-0001', 'success', 1999);
  PERFORM zz.check('A1: a flagged payment raises one critical alert', zz.astat('dx-test-a1-0001') = 'flagged/amount_mismatch/false' AND zz.alerts('flagged_payment', zz.ord('A1')) = 1
    AND (SELECT severity FROM public.payment_alerts WHERE kind = 'flagged_payment' AND order_id = zz.ord('A1')) = 'critical', j::text);
  PERFORM zz.check('A1: the platform admin and the pharmacy were told', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_admin FROM zz.bo) AND title = 'Payment problem: action needed' AND metadata ->> 'order_id' = zz.ord('A1')::text)
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND title = 'A payment needs attention' AND metadata ->> 'order_id' = zz.ord('A1')::text));
  PERFORM zz.check('A1: the pharmacy''s message promises nothing the system does not do', (SELECT body FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND metadata ->> 'order_id' = zz.ord('A1')::text AND title = 'A payment needs attention' LIMIT 1) NOT ILIKE '%refund%');
  n0 := (SELECT count(*) FROM public.notifications WHERE title = 'Payment problem: action needed');
  j := zz.apply('dx-test-a1-0001', 'success', 1999);
  PERFORM zz.check('A1: the same result reported again changes nothing (no second alert, no second notification)', zz.alerts('flagged_payment', zz.ord('A1')) = 1
    AND (SELECT count(*) FROM public.notifications WHERE title = 'Payment problem: action needed') = n0, j::text);

  -- A2: money arrives for a cancelled order.
  PERFORM zz.att(zz.ord('A2'), 'dx-test-a2-0001', 5);
  UPDATE public.orders SET status = 'cancelled' WHERE id = zz.ord('A2');
  j := zz.apply('dx-test-a2-0001', 'success', 2000);
  PERFORM zz.check('A2: a late payment raises a refund alert', (j ->> 'outcome') = 'late' AND zz.alerts('refund_required', zz.ord('A2')) = 1, j::text);
  PERFORM zz.check('A2: the pharmacy is told the payment cannot be kept (and not to pay again)', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND metadata ->> 'order_id' = zz.ord('A2')::text AND body LIKE '%arrange the refund%'));

  -- A3: paid, then cancelled.
  PERFORM zz.att(zz.ord('A3'), 'dx-test-a3-0001', 5);
  j := zz.apply('dx-test-a3-0001', 'success', 2000);
  PERFORM zz.check('A3: paid cleanly: no alert', (j ->> 'outcome') = 'applied' AND zz.alerts('refund_required', zz.ord('A3')) = 0 AND zz.alerts('flagged_payment', zz.ord('A3')) = 0);
  UPDATE public.orders SET status = 'cancelled' WHERE id = zz.ord('A3');
  PERFORM zz.check('A3: cancelling a paid online order raises a refund alert', zz.astat('dx-test-a3-0001') = 'succeeded/order_cancelled_after_payment/true' AND zz.alerts('refund_required', zz.ord('A3')) = 1);

  -- A4: a double payment.
  PERFORM zz.att(zz.ord('A4'), 'dx-test-a4-0001', 20, 'expired');
  PERFORM zz.att(zz.ord('A4'), 'dx-test-a4-0002', 5);
  PERFORM zz.apply('dx-test-a4-0001', 'success', 2000);
  j := zz.apply('dx-test-a4-0002', 'success', 2000);
  PERFORM zz.check('A4: a double payment raises a refund alert for the second one only', (j ->> 'outcome') = 'flagged' AND zz.alerts('refund_required', zz.ord('A4')) = 1
    AND (SELECT attempt_id FROM public.payment_alerts WHERE kind = 'refund_required' AND order_id = zz.ord('A4')) = (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a4-0002'), j::text);
END $$;

-- 2. Who can see and change alerts.
DO $$
DECLARE r TEXT; v_alert UUID := (SELECT id FROM public.payment_alerts WHERE kind = 'flagged_payment' AND order_id = zz.ord('A1'));
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.payment_alerts');
  PERFORM zz.check('a pharmacy cannot read alerts', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), 'SELECT count(*)::text FROM public.payment_alerts');
  PERFORM zz.check('a wholesaler cannot read alerts', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT (count(*) > 0)::text FROM public.payment_alerts');
  PERFORM zz.check('a platform admin can read alerts', r = 'true', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'UPDATE public.payment_alerts SET status = ''resolved'' WHERE true');
  PERFORM zz.check('nobody writes alerts directly, not even an admin', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.admin_resolve_payment_alert(%L, ''Looked into it and handled'')::text', v_alert));
  PERFORM zz.check('a pharmacy cannot resolve an alert', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), format('SELECT public.admin_resolve_payment_alert(%L, ''no'')::text', v_alert));
  PERFORM zz.check('resolving needs a real note', r LIKE 'ERR: A note of 5 to 500 characters%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), format('SELECT public.admin_resolve_payment_alert(%L, ''Contacted the pharmacy; refunded in the Paystack dashboard'')::text', v_alert));
  PERFORM zz.check('an admin resolves it with a note', r NOT LIKE 'ERR%' AND (SELECT status || '/' || (resolved_by IS NOT NULL) FROM public.payment_alerts WHERE id = v_alert) = 'resolved/true', r);
  PERFORM zz.check('resolving is recorded in the audit log', EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = v_alert AND activity = 'Payment alert resolved'));
  r := zz.val_as((SELECT u_admin FROM zz.bo), format('SELECT public.admin_resolve_payment_alert(%L, ''Resolving a second time is harmless'')::text', v_alert));
  PERFORM zz.check('resolving again is harmless', r NOT LIKE 'ERR%', r);
  BEGIN UPDATE public.payment_alerts SET summary = 'x' WHERE id = v_alert; PERFORM zz.check('what an alert says cannot be rewritten', FALSE, 'updated');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('what an alert says cannot be rewritten', SQLERRM LIKE '%cannot be changed%', SQLERRM); END;
  BEGIN UPDATE public.payment_alerts SET status = 'open', resolved_at = NULL WHERE id = v_alert; PERFORM zz.check('a resolved alert cannot be reopened', FALSE, 'reopened');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('a resolved alert cannot be reopened', SQLERRM LIKE '%cannot be reopened%', SQLERRM); END;
  BEGIN DELETE FROM public.payment_alerts WHERE id = v_alert; PERFORM zz.check('an alert is never deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('an alert is never deleted', SQLERRM LIKE '%never deleted%', SQLERRM); END;
  PERFORM zz.check('the problem, if it returns, gets a new alert (the resolved one is not reused)', public._raise_payment_alert('flagged_payment', 'critical', zz.ord('A1'), NULL, 'flagged:' || (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a1-0001'), 'again', '{}') <> v_alert);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT public.admin_payment_overview()::text');
  PERFORM zz.check('a pharmacy cannot open the admin overview', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT public.admin_payment_overview()::text');
  PERFORM zz.check('an admin gets the overview: counts, alerts and attempts', (r::jsonb -> 'counts' ->> 'open_alerts')::int >= 1 AND jsonb_array_length(r::jsonb -> 'alerts') >= 1
    AND jsonb_array_length(r::jsonb -> 'attempts') >= 4 AND (r::jsonb -> 'counts' ->> 'refunds_required')::int >= 2 AND (r::jsonb -> 'settings' ->> 'enabled') = 'false', left(r, 300));
END $$;

-- 3. The return page's check is throttled and never says "verified" by itself.
DO $$
DECLARE r TEXT; j JSONB; o UUID := zz.ord('R1'); a UUID;
BEGIN
  a := zz.att(o, 'dx-test-r1-0001', 1);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), o));
  j := r::jsonb;
  PERFORM zz.check('the first check lists the attempt', jsonb_array_length(j -> 'attempts') = 1 AND (j ->> 'throttled') = 'false' AND (j -> 'attempts' -> 0 ->> 'reference') = 'dx-test-r1-0001', r);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), o));
  j := r::jsonb;
  PERFORM zz.check('asking again straight away is throttled (nothing listed, flagged as throttled)', jsonb_array_length(j -> 'attempts') = 0 AND (j ->> 'throttled') = 'true', r);
  PERFORM zz.check('asking does not count as verified', (SELECT last_checked_at IS NULL FROM public.order_payment_attempts WHERE id = a));
  UPDATE public.order_payment_attempts SET check_requested_at = now() - interval '5 seconds' WHERE id = a;
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), o));
  PERFORM zz.check('after a few seconds it is listed again', jsonb_array_length(r::jsonb -> 'attempts') = 1, r);
  PERFORM zz.svc(format('SELECT public.mark_attempt_checked(%L)::text', a));
  PERFORM zz.check('once the provider has answered, the attempt counts as checked', (SELECT last_checked_at IS NOT NULL AND check_count = 1 FROM public.order_payment_attempts WHERE id = a));
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_px FROM zz.bo), o));
  PERFORM zz.check('another pharmacy still cannot ask about the order', r = 'ERR: Order not found.', r);
  r := zz.svc(format('SELECT public.payment_attempts_to_check(%L, %L)::text', (SELECT u_po FROM zz.bo), zz.ord('R2')));
  PERFORM zz.check('an order with no attempts is not "throttled", just empty', (r::jsonb ->> 'throttled') = 'false' AND jsonb_array_length(r::jsonb -> 'attempts') = 0, r);
END $$;

-- 4. What the reconciler asks the provider about, and closing stale attempts.
DO $$
DECLARE j JSONB; refs TEXT[]; o UUID := zz.ord('R3');
BEGIN
  PERFORM zz.att(o, 'dx-test-r3-fresh', 1);                       -- too young
  PERFORM zz.att(o, 'dx-test-r3-due01', 10);                      -- due (never checked)
  PERFORM zz.att(o, 'dx-test-r3-chk01', 20, 'pending', 1);        -- checked a minute ago
  PERFORM zz.att(o, 'dx-test-r3-chk02', 20, 'pending', 10);       -- checked ten minutes ago: due again
  PERFORM zz.att(o, 'dx-test-r3-exp01', 60, 'expired', 30);       -- closed, checked 30 minutes ago: not yet (hourly)
  PERFORM zz.att(o, 'dx-test-r3-exp02', 600, 'expired', 90);      -- closed, checked 90 minutes ago: due
  PERFORM zz.att(o, 'dx-test-r3-old01', 49 * 60);                 -- older than 48 hours
  PERFORM zz.att(o, 'dx-test-r3-fail1', 30, 'failed');            -- final
  j := zz.svc('SELECT public.payment_attempts_due_for_check(50)::text')::jsonb;
  SELECT array_agg(x ->> 'reference' ORDER BY x ->> 'reference') INTO refs FROM jsonb_array_elements(j) x WHERE x ->> 'reference' LIKE 'dx-test-r3-%';
  PERFORM zz.check('due for a check: unchecked open, open checked long ago, closed checked over an hour ago; not: too young, just checked, final, older than 48 h',
    refs = ARRAY['dx-test-r3-chk02', 'dx-test-r3-due01', 'dx-test-r3-exp02'], array_to_string(refs, ','));
  j := zz.svc('SELECT public.payment_attempts_due_for_check(1)::text')::jsonb;
  PERFORM zz.check('the batch is limited, oldest-checked first', jsonb_array_length(j) = 1);
  PERFORM zz.att(zz.ord('A2'), 'dx-test-a2-0009', 10);              -- an open attempt of a CANCELLED order
  PERFORM zz.check('the attempts of a cancelled order are still due (that is how a late payment is found)',
    (zz.svc('SELECT public.payment_attempts_due_for_check(50)::text')) LIKE '%dx-test-a2-0009%');
  PERFORM zz.check('closing stale attempts closes only those open for over 48 hours', zz.svc('SELECT public.close_stale_payment_attempts()::text') = '1'
    AND zz.astat('dx-test-r3-old01') = 'expired/-/false' AND zz.astat('dx-test-r3-due01') = 'initiated/-/false');
END $$;

-- 5. Expiring unpaid online orders.
DO $$
DECLARE j JSONB; r TEXT; v_stock INT;
BEGIN
  v_stock := zz.stock('BO C');
  -- E1: no attempt ever, placed 45 minutes ago.   E2: placed 45 minutes ago, an attempt started 10 minutes ago.
  -- E3: placed 45 minutes ago, an open attempt started 40 minutes ago, never checked.   E4: placed 10 minutes ago.   E5: already paid.
  -- E6: placed 3 hours ago with a recent, checked attempt.
  PERFORM zz.age_order(zz.ord('E1'), 45);
  PERFORM zz.age_order(zz.ord('E2'), 45);  PERFORM zz.att(zz.ord('E2'), 'dx-test-e2-0001', 10, 'initiated', 1);
  PERFORM zz.age_order(zz.ord('E3'), 45);  PERFORM zz.att(zz.ord('E3'), 'dx-test-e3-0001', 40);
  PERFORM zz.age_order(zz.ord('E4'), 10);
  PERFORM zz.age_order(zz.ord('E5'), 60);  PERFORM zz.att(zz.ord('E5'), 'dx-test-e5-0001', 50);  PERFORM zz.apply('dx-test-e5-0001', 'success', 2000);
  PERFORM zz.age_order(zz.ord('E6'), 180); PERFORM zz.att(zz.ord('E6'), 'dx-test-e6-0001', 3, 'initiated', 1);

  j := zz.svc('SELECT public.expire_unpaid_online_orders()::text')::jsonb;
  PERFORM zz.check('E1: an old order with no attempt is cancelled and its stock returned (with E6 in the same run: two units)', zz.ostat(zz.ord('E1')) = 'cancelled/unpaid' AND zz.stock('BO C') = v_stock + 2, j::text || zz.ostat(zz.ord('E1')));
  PERFORM zz.check('E1: it says why, the pharmacy was told, the log and audit trail record it', (SELECT cancellation_reason FROM public.orders WHERE id = zz.ord('E1')) = 'The online payment was not completed in time.'
    AND EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND title = 'Order cancelled: payment not completed' AND metadata ->> 'order_id' = zz.ord('E1')::text)
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = zz.ord('E1') AND kind = 'order_expired')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = zz.ord('E1') AND activity = 'Online order expired unpaid'));
  PERFORM zz.check('E2: an attempt started 10 minutes ago keeps the order alive', zz.ostat(zz.ord('E2')) = 'pending/unpaid');
  PERFORM zz.check('E3: an open attempt that was never checked with the provider blocks the expiry, and says so', zz.ostat(zz.ord('E3')) = 'pending/unpaid' AND zz.alerts('expiry_blocked', zz.ord('E3')) = 1
    AND (j ->> 'blocked')::int >= 1, j::text);
  PERFORM zz.check('E4: a recent order is untouched', zz.ostat(zz.ord('E4')) = 'pending/unpaid');
  PERFORM zz.check('E5: a paid order is never expired', zz.ostat(zz.ord('E5')) = 'pending/paid');
  PERFORM zz.check('E6: even a recently active order is cancelled once it is 2 hours old (its attempts were checked)', zz.ostat(zz.ord('E6')) = 'cancelled/unpaid' AND zz.astat('dx-test-e6-0001') = 'expired/-/false', zz.ostat(zz.ord('E6')));

  PERFORM zz.svc(format('SELECT public.mark_attempt_checked(%L)::text', (SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-e3-0001')));
  j := zz.svc('SELECT public.expire_unpaid_online_orders()::text')::jsonb;
  PERFORM zz.check('E3: once the provider has been asked, the order is expired and its attempt closed', zz.ostat(zz.ord('E3')) = 'cancelled/unpaid' AND zz.astat('dx-test-e3-0001') = 'expired/-/false', j::text);
  j := zz.svc('SELECT public.expire_unpaid_online_orders()::text')::jsonb;
  PERFORM zz.check('running it again changes nothing', (j ->> 'expired') = '0' AND zz.ostat(zz.ord('E2')) = 'pending/unpaid', j::text);
  -- a payment that was in flight when the order expired is still found and refunded
  j := zz.apply('dx-test-e3-0001', 'success', 2000);
  PERFORM zz.check('E3: a payment that arrives after the expiry is recorded as a late payment needing a refund', (j ->> 'outcome') = 'late' AND zz.alerts('refund_required', zz.ord('E3')) = 1, j::text);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.expire_unpaid_online_orders()::text'));
  PERFORM zz.check('nobody but the server can run the expiry', r LIKE 'ERR: permission denied%', r);
END $$;

-- 6. The daily comparison with the provider.
DO $$
DECLARE j JSONB; tx JSONB; o3 UUID := zz.ord('R4'); o4 UUID := zz.ord('R5'); n_missing INT;
BEGIN
  -- R4: our attempt succeeded (paid just now).  R5: our attempt is open, the provider says it was paid.
  PERFORM zz.att(o3, 'dx-test-r4-0001', 20); PERFORM zz.apply('dx-test-r4-0001', 'success', 2000);
  PERFORM zz.att(o4, 'dx-test-r5-0001', 20);
  tx := jsonb_build_array(
    jsonb_build_object('reference', 'dx-test-r4-0001', 'status', 'success', 'amount_minor', 2000, 'currency', 'GHS'),
    jsonb_build_object('reference', 'dx-test-r5-0001', 'status', 'success', 'amount_minor', 2000, 'currency', 'GHS'),
    jsonb_build_object('reference', 'dx-test-ghost-01', 'status', 'success', 'amount_minor', 5000, 'currency', 'GHS'),
    jsonb_build_object('reference', 'dx-test-ghost-02', 'status', 'abandoned', 'amount_minor', 5000, 'currency', 'GHS'),
    jsonb_build_object('reference', 'dx-live-ghost-03', 'status', 'success', 'amount_minor', 5000, 'currency', 'GHS'),
    jsonb_build_object('reference', 'someone-elses-ref', 'status', 'success', 'amount_minor', 5000, 'currency', 'GHS'));
  j := zz.svc(format('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', %L::jsonb, true, false)::text', tx))::jsonb;
  PERFORM zz.check('a settled payment that matches raises nothing; an unsettled one the provider says was paid is handed back to be verified', (j -> 'to_verify')::text = '["dx-test-r5-0001"]' AND (j ->> 'checked') = '4', j::text);
  PERFORM zz.check('a successful provider payment we have no record of is a critical alert; an unfinished one, another mode and someone else''s reference are ignored',
    zz.alerts('unknown_at_provider') = 1 AND (SELECT summary FROM public.payment_alerts WHERE kind = 'unknown_at_provider' AND status = 'open') LIKE '%dx-test-ghost-01%');
  PERFORM zz.check('nothing is raised for the unsettled one in the first pass', zz.alerts('paid_not_applied') = 0);
  j := zz.svc(format('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', %L::jsonb, true, true)::text', tx))::jsonb;
  PERFORM zz.check('the final pass raises "paid but not applied" for what is still unsettled', zz.alerts('paid_not_applied', o4) = 1, j::text);
  PERFORM zz.apply('dx-test-r5-0001', 'success', 2000);
  PERFORM zz.check('and applying that payment closes the alert by itself', zz.alerts('paid_not_applied', o4) = 0 AND zz.pstat(o4) = 'paid'
    AND (SELECT resolution_note FROM public.payment_alerts WHERE kind = 'paid_not_applied' AND order_id = o4) LIKE 'Closed automatically%');
  -- amount mismatch
  tx := jsonb_build_array(jsonb_build_object('reference', 'dx-test-r4-0001', 'status', 'success', 'amount_minor', 1500, 'currency', 'GHS'));
  PERFORM zz.svc(format('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', %L::jsonb, false, true)::text', tx));
  PERFORM zz.check('a different amount at the provider is a critical alert', zz.alerts('amount_mismatch', o3) = 1);
  -- status mismatch
  tx := jsonb_build_array(jsonb_build_object('reference', 'dx-test-r4-0001', 'status', 'failed', 'amount_minor', 2000, 'currency', 'GHS'));
  PERFORM zz.svc(format('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', %L::jsonb, false, true)::text', tx));
  PERFORM zz.check('paid here but not paid at the provider is a critical alert', zz.alerts('status_mismatch', o3) = 1);
  -- ours but missing at the provider
  n_missing := zz.alerts('missing_at_provider');
  PERFORM zz.svc('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', ''[]''::jsonb, false, true)::text');
  PERFORM zz.check('with an incomplete provider list, "missing at the provider" is not judged', zz.alerts('missing_at_provider') = n_missing);
  PERFORM zz.svc('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', ''[]''::jsonb, true, true)::text');
  PERFORM zz.check('with a complete list, every payment of ours that the provider does not show is a critical alert', zz.alerts('missing_at_provider') >= 2);
  PERFORM zz.check('a list that is not a list is refused', zz.svc('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', ''{}''::jsonb, true, true)::text') = 'ERR: The provider list must be an array.');
  PERFORM zz.svc('SELECT public.reconcile_provider_transactions(''paystack'', ''test'', now() - interval ''1 day'', now() + interval ''1 hour'', ''[]''::jsonb, true, true)::text');
  PERFORM zz.check('the same difference found again counts once more but does not make a second alert', (SELECT count(*) FROM public.payment_alerts WHERE kind = 'missing_at_provider' AND status = 'open' AND order_id = o3) = 1
    AND (SELECT occurrences FROM public.payment_alerts WHERE kind = 'missing_at_provider' AND status = 'open' AND order_id = o3) >= 2);
END $$;

-- 7. Only the server (or an admin, for the admin views) can use any of it.
DO $$
DECLARE r TEXT; u RECORD; fn TEXT;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.bo)), ('a wholesaler owner', (SELECT u_wo FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['payment_attempts_due_for_check(10)', 'close_stale_payment_attempts()', 'expire_unpaid_online_orders()', 'mark_attempt_checked(gen_random_uuid())',
      'reconcile_provider_transactions(''paystack'', ''test'', now(), now(), ''[]''::jsonb, true, false)', 'payment_user_is_admin(gen_random_uuid())',
      'report_payment_job_problem(''provider_unreachable'', ''x'', ''{}''::jsonb, ''k'')', 'admin_attempts_to_reverify(gen_random_uuid(), gen_random_uuid())'] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
  PERFORM zz.check('the server can ask whether a user is an admin', zz.svc(format('SELECT public.payment_user_is_admin(%L)::text', (SELECT u_admin FROM zz.bo))) = 'true'
    AND zz.svc(format('SELECT public.payment_user_is_admin(%L)::text', (SELECT u_po FROM zz.bo))) = 'false');
  r := zz.svc(format('SELECT public.admin_attempts_to_reverify(%L, %L)::text', (SELECT u_po FROM zz.bo), zz.ord('A1')));
  PERFORM zz.check('re-verify is for admins only', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.svc(format('SELECT public.admin_attempts_to_reverify(%L, %L)::text', (SELECT u_admin FROM zz.bo), zz.ord('A1')));
  PERFORM zz.check('an admin gets the attempts of an order to re-verify', jsonb_array_length(r::jsonb) = 1, r);
  r := zz.svc('SELECT public.report_payment_job_problem(''provider_unreachable'', ''The provider could not be reached'', ''{}''::jsonb, ''provider_unreachable:test'')::text');
  PERFORM zz.check('the server can report a job problem once, and again without a second alert', r NOT LIKE 'ERR%'
    AND zz.svc('SELECT public.report_payment_job_problem(''provider_unreachable'', ''still down'', ''{}''::jsonb, ''provider_unreachable:test'')::text') NOT LIKE 'ERR%'
    AND (SELECT count(*) FROM public.payment_alerts WHERE kind = 'provider_unreachable' AND status = 'open') = 1, r);
  r := zz.svc('SELECT public.report_payment_job_problem(''flagged_payment'', ''x'', ''{}''::jsonb, ''k'')::text');
  PERFORM zz.check('a job cannot raise the kinds of alert that belong to a payment', r LIKE 'ERR: Unknown kind%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
