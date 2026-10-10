-- Online payments (Pay Now), P4a: the refund ledger and moving money back (requesting, approving, sending, following, failing, unknown outcomes, partial refunds, the cap).
-- Run after setup.sql + migrations (through 20261109110000_payments_refunds_workflow.sql), with the production guard and stock fixtures installed
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
CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
  SELECT p_order, 'paystack', 'test', p_ref, o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  RETURN v_id;
END $$;
-- A paid attempt (2000 pesewas = GHS 20.00, one unit of BO C).
CREATE FUNCTION zz.pay(p_order UUID, p_ref TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID := zz.att(p_order, p_ref);
BEGIN PERFORM zz.apply(p_ref, 'success', 2000); RETURN v_id; END $$;
CREATE FUNCTION zz.rid(p_ref TEXT) RETURNS UUID LANGUAGE sql AS $$
  SELECT r.id FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id WHERE a.reference = p_ref ORDER BY r.created_at LIMIT 1 $$;
CREATE FUNCTION zz.rstat(p_ref TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT string_agg(r.status || '/' || r.amount_minor || '/' || r.reason, ',' ORDER BY r.created_at) FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id WHERE a.reference = p_ref $$;
CREATE FUNCTION zz.adm(p_refund UUID, p_action TEXT, p_note TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.admin_refund_transition(%L, %L, %L, %L)::text', (SELECT u_admin FROM zz.bo), p_refund, p_action, p_note)) $$;
CREATE FUNCTION zz.ev(p_ref TEXT, p_event TEXT, p_minor BIGINT DEFAULT NULL, p_mode TEXT DEFAULT 'test') RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_refund_event(''paystack'', %L, %L, %L, ''rf-ext-1'', %s)::text', p_mode, p_ref, p_event, COALESCE(p_minor::text, 'NULL')))::jsonb $$;
CREATE FUNCTION zz.ostat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT status::text || '/' || payment_status::text FROM public.orders WHERE id = p_order $$;
CREATE FUNCTION zz.alerts(p_kind TEXT, p_order UUID DEFAULT NULL) RETURNS INT LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.payment_alerts WHERE kind = p_kind AND status = 'open' AND (p_order IS NULL OR order_id = p_order) $$;

UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', auto_refunds = FALSE;
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
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r6_
INSERT INTO zz.bo_orders SELECT 'R6', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r7_
INSERT INTO zz.bo_orders SELECT 'R7', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.bo), (SELECT good FROM zz.bo),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.bo), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.bo)::text, 'pay_now')) AS r \gset r8_
INSERT INTO zz.bo_orders SELECT 'R8', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

UPDATE public.payments_settings SET online_enabled = FALSE;

-- 1. A paid order is cancelled: the refund is requested, approved by an administrator, sent, and confirmed by the provider.
DO $$
DECLARE o UUID := zz.ord('R1'); a UUID; rid UUID; j TEXT;
BEGIN
  a := zz.pay(o, 'dx-test-r1-0001');
  PERFORM zz.check('R1: a payment cleanly applied asks for no refund', zz.rstat('dx-test-r1-0001') IS NULL AND zz.ostat(o) = 'pending/paid');
  UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  PERFORM zz.check('R1: cancelling a paid online order requests its full refund, waiting for approval (automatic refunds are off)',
    zz.rstat('dx-test-r1-0001') = 'requested/2000/cancelled_after_payment', zz.rstat('dx-test-r1-0001'));
  rid := zz.rid('dx-test-r1-0001');
  PERFORM zz.check('R1: the "refund needed" alert is open and the refund is not yet counted as returned', zz.alerts('refund_required', o) = 1);
  j := zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  PERFORM zz.check('R1: a refund that is not approved cannot be claimed for sending', j IS NULL, j);
  j := zz.adm(rid, 'approve');
  PERFORM zz.check('R1: an administrator approves it', (j::jsonb ->> 'status') = 'approved' AND (j::jsonb ->> 'needs_submission') = 'true' AND zz.rstat('dx-test-r1-0001') LIKE 'approved/%', j);
  PERFORM zz.check('R1: it shows in the list of refunds to send', zz.svc('SELECT public.refunds_to_submit(10)::text') LIKE '%' || rid::text || '%');
  j := zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  PERFORM zz.check('R1: exactly one worker can claim it, and gets what to send', (j::jsonb ->> 'transaction_reference') = 'dx-test-r1-0001' AND (j::jsonb ->> 'amount_minor') = '2000'
    AND zz.rstat('dx-test-r1-0001') LIKE 'submitting/%', j);
  PERFORM zz.check('R1: a second worker gets nothing', zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid)) IS NULL);
  j := zz.svc(format('SELECT public.record_refund_submission(%L, ''rf-100'', ''pending'')', rid));
  PERFORM zz.check('R1: once the provider accepts it, it is processing', j = 'processing' AND (SELECT provider_refund_id FROM public.order_refunds WHERE id = rid) = 'rf-100', j);
  PERFORM zz.check('R1: it is not refunded yet: the order is still paid and the alert still open', zz.ostat(o) = 'cancelled/paid' AND zz.alerts('refund_required', o) = 1);
  j := zz.ev('dx-test-r1-0001', 'refund.processed', 2000)::text;
  PERFORM zz.check('R1: the provider''s "processed" notification completes it', (j::jsonb ->> 'outcome') = 'succeeded' AND zz.rstat('dx-test-r1-0001') LIKE 'succeeded/%', j);
  PERFORM zz.check('R1: the order is now refunded and the alert closed itself', zz.ostat(o) = 'cancelled/refunded' AND zz.alerts('refund_required', o) = 0
    AND (SELECT resolution_note FROM public.payment_alerts WHERE kind = 'refund_required' AND order_id = o ORDER BY created_at DESC LIMIT 1) LIKE 'Closed automatically%');
  PERFORM zz.check('R1: the pharmacy was told, the log and audit trail record it', EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.bo) AND title = 'Refund sent' AND metadata ->> 'order_id' = o::text)
    AND EXISTS (SELECT 1 FROM public.order_payment_log WHERE order_id = o AND kind = 'refund_succeeded')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = rid AND activity = 'Refund completed'));
  j := zz.ev('dx-test-r1-0001', 'refund.processed', 2000)::text;
  PERFORM zz.check('R1: the same notification again changes nothing', (j::jsonb ->> 'outcome') = 'already_recorded' AND (SELECT count(*) = count(DISTINCT user_id) FROM public.notifications WHERE title = 'Refund sent' AND metadata ->> 'order_id' = o::text), j);
END $$;

-- 2. A late payment (the order was already cancelled) with automatic refunds ON is approved straight away.
DO $$
DECLARE o UUID := zz.ord('R2'); rid UUID;
BEGIN
  UPDATE public.payments_settings SET auto_refunds = TRUE;
  PERFORM zz.att(o, 'dx-test-r2-0001');
  UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  PERFORM zz.apply('dx-test-r2-0001', 'success', 2000);
  UPDATE public.payments_settings SET auto_refunds = FALSE;
  rid := zz.rid('dx-test-r2-0001');
  PERFORM zz.check('R2: a late payment''s refund is requested and approved automatically', zz.rstat('dx-test-r2-0001') = 'approved/2000/late_payment'
    AND (SELECT approved_at IS NOT NULL AND approved_by IS NULL FROM public.order_refunds WHERE id = rid), zz.rstat('dx-test-r2-0001'));
  PERFORM zz.check('R2: the order itself stays cancelled and unpaid (the money was never the order''s)', zz.ostat(o) = 'cancelled/unpaid');
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  PERFORM zz.svc(format('SELECT public.record_refund_submission(%L, ''rf-200'', ''processing'')', rid));
  PERFORM zz.ev('dx-test-r2-0001', 'refund.processed', NULL);
  PERFORM zz.check('R2: once refunded the order stays cancelled/unpaid (not "refunded": it was never paid)', zz.rstat('dx-test-r2-0001') LIKE 'succeeded/%' AND zz.ostat(o) = 'cancelled/unpaid');
END $$;

-- 3. A double payment: only the second payment is refunded.
DO $$
DECLARE o UUID := zz.ord('R3');
BEGIN
  PERFORM zz.pay(o, 'dx-test-r3-0001');
  PERFORM zz.pay(o, 'dx-test-r3-0002');
  PERFORM zz.check('R3: a double payment requests a refund of the second payment only', zz.rstat('dx-test-r3-0001') IS NULL AND zz.rstat('dx-test-r3-0002') = 'requested/2000/double_payment'
    AND zz.ostat(o) = 'pending/paid', coalesce(zz.rstat('dx-test-r3-0002'), 'none'));
END $$;

-- 4. The provider refuses a refund: failed, retried, refused again by a notification, then cancelled.
DO $$
DECLARE o UUID := zz.ord('R4'); rid UUID; j TEXT;
BEGIN
  PERFORM zz.pay(o, 'dx-test-r4-0001'); UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  rid := zz.rid('dx-test-r4-0001');
  PERFORM zz.adm(rid, 'approve');
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  j := zz.svc(format('SELECT public.record_refund_rejection(%L, ''Transaction is not eligible for refund'', true)', rid));
  PERFORM zz.check('R4: a definite refusal makes the refund failed, with the reason, and raises an alert', j = 'failed' AND zz.rstat('dx-test-r4-0001') LIKE 'failed/%'
    AND (SELECT failure_reason FROM public.order_refunds WHERE id = rid) LIKE 'Transaction is not eligible%' AND zz.alerts('refund_failed', o) = 1, j);
  PERFORM zz.check('R4: a failed refund is not sent again by itself', zz.svc('SELECT public.refunds_to_submit(10)::text') NOT LIKE '%' || rid::text || '%');
  j := zz.adm(rid, 'retry');
  PERFORM zz.check('R4: an administrator can retry it (approved again, the alert closed)', (j::jsonb ->> 'status') = 'approved' AND zz.alerts('refund_failed', o) = 0, j);
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  PERFORM zz.svc(format('SELECT public.record_refund_submission(%L, ''rf-400'', ''pending'')', rid));
  j := zz.ev('dx-test-r4-0001', 'refund.failed', 2000)::text;
  PERFORM zz.check('R4: a later "failed" notification fails it again, with an alert', (j::jsonb ->> 'outcome') = 'failed' AND zz.rstat('dx-test-r4-0001') LIKE 'failed/%' AND zz.alerts('refund_failed', o) = 1, j);
  j := zz.adm(rid, 'cancel', 'Refunded by bank transfer instead');
  PERFORM zz.check('R4: it can be cancelled, which closes its alert; the money still needs a person (the "refund needed" alert stays)', (j::jsonb ->> 'status') = 'cancelled'
    AND zz.alerts('refund_failed', o) = 0 AND zz.alerts('refund_required', o) = 1, j);
  BEGIN UPDATE public.order_refunds SET status = 'approved' WHERE id = rid; PERFORM zz.check('R4: a cancelled refund cannot be revived', FALSE, 'revived');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R4: a cancelled refund cannot be revived', SQLERRM LIKE '%cannot be revived%', SQLERRM); END;
END $$;

-- 5. It is not certain that the request arrived: never retried automatically.
DO $$
DECLARE o UUID := zz.ord('R5'); rid UUID; j TEXT;
BEGIN
  PERFORM zz.pay(o, 'dx-test-r5-0001'); UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  rid := zz.rid('dx-test-r5-0001');
  PERFORM zz.adm(rid, 'approve');
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  j := zz.svc(format('SELECT public.record_refund_rejection(%L, ''Paystack did not answer in time.'', false)', rid));
  PERFORM zz.check('R5: an answer that was lost makes the refund "unknown", with a critical alert telling a person to check first', j = 'unknown' AND zz.alerts('refund_stuck', o) = 1
    AND (SELECT summary FROM public.payment_alerts WHERE kind = 'refund_stuck' AND order_id = o AND status = 'open') LIKE '%BEFORE sending it again%', j);
  PERFORM zz.check('R5: it is never in the list of refunds to send', zz.svc('SELECT public.refunds_to_submit(10)::text') NOT LIKE '%' || rid::text || '%');
  j := zz.adm(rid, 'retry');
  PERFORM zz.check('R5: it cannot be retried from "unknown" (only a person''s check can move it)', j LIKE 'ERR: Only a refund that failed can be retried%', j);
  j := zz.adm(rid, 'mark_failed');
  PERFORM zz.check('R5: marking it failed needs a note saying what was checked', j LIKE 'ERR: A note of 5 to 500 characters%', j);
  j := zz.ev('dx-test-r5-0001', 'refund.processed', 2000)::text;
  PERFORM zz.check('R5: if the provider''s notification arrives, it completes by itself and the alerts close', (j::jsonb ->> 'outcome') = 'succeeded' AND zz.rstat('dx-test-r5-0001') LIKE 'succeeded/%'
    AND zz.alerts('refund_stuck', o) = 0 AND zz.ostat(o) = 'cancelled/refunded', j);
END $$;

-- 6. Needs attention, manual confirmation and marking as failed.
DO $$
DECLARE o UUID := zz.ord('R6'); rid UUID; j TEXT; o2 UUID := zz.ord('R7'); rid2 UUID;
BEGIN
  PERFORM zz.pay(o, 'dx-test-r6-0001'); UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  rid := zz.rid('dx-test-r6-0001');
  PERFORM zz.adm(rid, 'approve');
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid));
  PERFORM zz.svc(format('SELECT public.record_refund_submission(%L, ''rf-600'', ''pending'')', rid));
  j := zz.ev('dx-test-r6-0001', 'refund.needs-attention', 2000)::text;
  PERFORM zz.check('R6: "needs attention" makes the refund unknown with an alert', (j::jsonb ->> 'outcome') = 'needs_attention' AND zz.rstat('dx-test-r6-0001') LIKE 'unknown/%' AND zz.alerts('refund_stuck', o) = 1, j);
  j := zz.adm(rid, 'confirm_refunded');
  PERFORM zz.check('R6: confirming as refunded needs a note', j LIKE 'ERR: A note of 5 to 500 characters%', j);
  j := zz.adm(rid, 'confirm_refunded', 'Refunded from the Paystack dashboard, reference RF-123');
  PERFORM zz.check('R6: an administrator can confirm it was refunded by hand: succeeded, method manual, alerts closed', (j::jsonb ->> 'status') = 'succeeded'
    AND (SELECT method || '/' || note FROM public.order_refunds WHERE id = rid) LIKE 'manual/Refunded from the Paystack dashboard%' AND zz.alerts('refund_stuck', o) = 0 AND zz.ostat(o) = 'cancelled/refunded', j);
  j := zz.adm(rid, 'cancel');
  PERFORM zz.check('R6: a refund that succeeded cannot be cancelled', j LIKE 'ERR:%cannot be cancelled%', j);

  -- R7: requested, then confirmed as done by hand without ever being sent; and a processing one marked as failed.
  PERFORM zz.pay(o2, 'dx-test-r7-0001'); UPDATE public.orders SET status = 'cancelled' WHERE id = o2;
  rid2 := zz.rid('dx-test-r7-0001');
  PERFORM zz.adm(rid2, 'approve'); PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', rid2)); PERFORM zz.svc(format('SELECT public.record_refund_submission(%L, ''rf-700'', ''pending'')', rid2));
  j := zz.adm(rid2, 'mark_failed', 'Checked the dashboard: no such refund exists');
  PERFORM zz.check('R7: a refund that was processing can be marked failed by an administrator who checked, and then retried', (j::jsonb ->> 'status') = 'failed'
    AND (zz.adm(rid2, 'retry'))::jsonb ->> 'status' = 'approved', j);
END $$;

-- 7. Partial refunds and the cap (what amendments will use), idempotency, and the backstop.
DO $$
DECLARE o UUID := zz.ord('R8'); a UUID; r1 UUID; r2 UUID; r3 UUID;
BEGIN
  a := zz.pay(o, 'dx-test-r8-0001');
  r1 := public._request_refund(a, 500, 'amendment_reduction', 'test:partial:1', NULL, 'one unit short');
  PERFORM zz.check('R8: a partial refund of a payment that stays valid is allowed', zz.rstat('dx-test-r8-0001') = 'requested/500/amendment_reduction' AND zz.ostat(o) = 'pending/paid');
  PERFORM zz.check('R8: asking again with the same source gives the same refund, not a second one', public._request_refund(a, 500, 'amendment_reduction', 'test:partial:1', NULL, NULL) = r1
    AND (SELECT count(*) FROM public.order_refunds WHERE attempt_id = a) = 1);
  r2 := public._request_refund(a, 1000, 'amendment_reduction', 'test:partial:2', NULL, NULL);
  PERFORM zz.check('R8: a second partial refund is allowed while the total stays within what was received', r2 IS NOT NULL AND (SELECT sum(amount_minor) FROM public.order_refunds WHERE attempt_id = a) = 1500);
  BEGIN PERFORM public._request_refund(a, 600, 'amendment_reduction', 'test:partial:3', NULL, NULL); PERFORM zz.check('R8: refunds can never add up to more than the payment received', FALSE, 'allowed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R8: refunds can never add up to more than the payment received', SQLERRM LIKE '%cannot add up to more%', SQLERRM); END;
  BEGIN INSERT INTO public.order_refunds(order_id, attempt_id, provider, mode, amount_ghs, amount_minor, reason, source_key) VALUES (o, a, 'paystack', 'test', 9.99, 999, 'manual', 'test:direct');
    PERFORM zz.check('R8: the database itself refuses an over-refund even if the function is bypassed', FALSE, 'inserted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R8: the database itself refuses an over-refund even if the function is bypassed', SQLERRM LIKE '%cannot add up to more%', SQLERRM); END;
  r3 := public._request_refund(a, NULL, 'manual', 'test:rest', NULL, NULL);
  PERFORM zz.check('R8: asking for "the rest" refunds exactly what is left (500)', (SELECT amount_minor FROM public.order_refunds WHERE id = r3) = 500);
  PERFORM zz.check('R8: with nothing left, asking again returns nothing', public._request_refund(a, NULL, 'manual', 'test:more', NULL, NULL) IS NULL);
  PERFORM zz.adm(r1, 'cancel');
  PERFORM zz.check('R8: cancelling a refund frees its amount again', (SELECT sum(amount_minor) FROM public.order_refunds WHERE attempt_id = a AND status <> 'cancelled') = 1500);
  BEGIN UPDATE public.order_refunds SET amount_minor = 1, amount_ghs = 0.01 WHERE id = r2; PERFORM zz.check('R8: what a refund is for cannot be changed', FALSE, 'changed');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R8: what a refund is for cannot be changed', SQLERRM LIKE '%cannot be changed%', SQLERRM); END;
  BEGIN DELETE FROM public.order_refunds WHERE id = r2; PERFORM zz.check('R8: a refund is never deleted', FALSE, 'deleted');
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R8: a refund is never deleted', SQLERRM LIKE '%never deleted%', SQLERRM); END;
  BEGIN PERFORM public._request_refund((SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-a-none'), 100, 'manual', 'test:none', NULL, NULL);
  EXCEPTION WHEN OTHERS THEN PERFORM zz.check('R8: an attempt that does not exist cannot be refunded', SQLERRM LIKE '%Payment not found%', SQLERRM); END;
END $$;

-- 8. Notifications from the provider that do not match anything.
DO $$
DECLARE j JSONB;
BEGIN
  j := zz.ev('dx-test-r8-0001', 'refund.processed', 12345);
  PERFORM zz.check('an event for a refund this system did not send raises an alert, and changes nothing', (j ->> 'outcome') = 'unmatched' AND zz.alerts('refund_unmatched') = 1);
  PERFORM zz.check('an event for a reference we do not know is ignored quietly', (zz.ev('dx-test-nothing-here', 'refund.processed', 100) ->> 'outcome') = 'unknown_reference');
  PERFORM zz.check('an event from the other mode is refused', (zz.ev('dx-test-r8-0001', 'refund.processed', 100, 'live') ->> 'outcome') = 'mode_mismatch');
  PERFORM zz.check('an event that is not about a refund outcome is ignored', (zz.ev('dx-test-r8-0001', 'charge.success', 100) ->> 'outcome') = 'ignored');
  -- The provider states the amount in other units: a single in-flight refund is still the one meant.
  PERFORM zz.pay(zz.ord('R6'), 'dx-test-r6-0002');
  UPDATE public.orders SET status = 'cancelled' WHERE id = zz.ord('R6');
  PERFORM zz.adm(zz.rid('dx-test-r6-0002'), 'approve');
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', zz.rid('dx-test-r6-0002')));
  PERFORM zz.check('an event whose amount is in other units still matches the only refund in flight for that payment', (zz.ev('dx-test-r6-0002', 'refund.processed', 20) ->> 'outcome') = 'succeeded');
END $$;

-- 9. Refunds that have been sitting too long.
DO $$
DECLARE r UUID; n INT;
BEGIN
  -- R3's refund has been "requested" since this test began: age it, and an approved one, and a half-sent one.
  ALTER TABLE public.order_refunds DISABLE TRIGGER trg_order_refunds_protect;
  UPDATE public.order_refunds SET created_at = now() - interval '25 hours' WHERE id = zz.rid('dx-test-r3-0002');
  ALTER TABLE public.order_refunds ENABLE TRIGGER trg_order_refunds_protect;
  r := zz.rid('dx-test-r7-0001');   -- approved again by the retry in section 6
  UPDATE public.order_refunds SET approved_at = now() - interval '3 hours' WHERE id = r;
  n := zz.svc('SELECT public.flag_stale_refunds()::text')::int;
  PERFORM zz.check('refunds waiting for approval for a day, or approved but not sent for hours, raise warnings', n >= 2 AND zz.alerts('refund_stuck', zz.ord('R3')) = 1 AND zz.alerts('refund_stuck', zz.ord('R7')) = 1, n::text);
  PERFORM zz.svc(format('SELECT public.claim_refund_for_submission(%L)::text', r));
  UPDATE public.order_refunds SET submitted_at = now() - interval '20 minutes' WHERE id = r;
  PERFORM zz.svc('SELECT public.flag_stale_refunds()::text');
  PERFORM zz.check('a refund left half-sent by a dead worker becomes "unknown", never silently re-sent', zz.rstat('dx-test-r7-0001') LIKE 'unknown/%');
  PERFORM zz.check('running the check again does not duplicate alerts', (SELECT count(*) FROM public.payment_alerts WHERE kind = 'refund_stuck' AND status = 'open' AND dedupe_key LIKE 'refund_overdue:%') = 2);
END $$;

-- 10. What people can see, and who can do what.
DO $$
DECLARE r TEXT; j JSONB; fn TEXT; u RECORD;
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('R1')));
  j := r::jsonb;
  PERFORM zz.check('the pharmacy sees what it paid, what came back, and the refund', (j ->> 'paid_ghs')::numeric = 20 AND (j ->> 'refunded_ghs')::numeric = 20 AND jsonb_array_length(j -> 'refunds') = 1
    AND (j -> 'refunds' -> 0 ->> 'status') = 'succeeded' AND (j ->> 'refund_required') = 'false', r);
  r := zz.val_as((SELECT u_wo FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('R1')));
  PERFORM zz.check('the wholesaler sees the same facts', (r::jsonb ->> 'refunded_ghs')::numeric = 20, r);
  r := zz.val_as((SELECT u_px FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('R1')));
  PERFORM zz.check('a stranger sees nothing', r = 'ERR: Order not found.', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), format('SELECT public.order_payment_summary(%L)::text', zz.ord('R4')));
  PERFORM zz.check('while a refund is still owed the summary says so', (r::jsonb ->> 'refund_required') = 'true', r);
  r := zz.val_as((SELECT u_po FROM zz.bo), 'SELECT count(*)::text FROM public.order_refunds');
  PERFORM zz.check('a pharmacy cannot read the refund ledger directly', r = '0' OR r LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT (count(*) > 0)::text FROM public.order_refunds');
  PERFORM zz.check('an administrator can', r = 'true', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'UPDATE public.order_refunds SET status = ''succeeded'' WHERE true');
  PERFORM zz.check('nobody writes refunds directly, not even an administrator', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as((SELECT u_admin FROM zz.bo), 'SELECT public.admin_payment_overview()::text');
  j := r::jsonb;
  PERFORM zz.check('the admin overview lists refunds and counts the open ones; automatic refunds are shown as off', jsonb_array_length(j -> 'refunds') >= 5 AND (j -> 'counts' ->> 'refunds_open')::int >= 3
    AND (j -> 'settings' ->> 'auto_refunds') = 'false', left(r, 200));
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.bo)), ('a wholesaler owner', (SELECT u_wo FROM zz.bo)), ('an admin', (SELECT u_admin FROM zz.bo))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['refunds_to_submit(5)', 'claim_refund_for_submission(gen_random_uuid())', 'record_refund_submission(gen_random_uuid(), ''x'', ''y'')',
      'record_refund_rejection(gen_random_uuid(), ''x'', true)', 'apply_refund_event(''paystack'', ''test'', ''x'', ''refund.processed'', ''y'', 1)',
      'admin_refund_transition(gen_random_uuid(), gen_random_uuid(), ''approve'', NULL)', 'flag_stale_refunds()'] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
  r := zz.svc(format('SELECT public.admin_refund_transition(%L, %L, ''approve'', NULL)::text', (SELECT u_po FROM zz.bo), zz.rid('dx-test-r3-0002')));
  PERFORM zz.check('even through the server, only an administrator''s id can approve a refund', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.adm(zz.rid('dx-test-r3-0002'), 'launch');
  PERFORM zz.check('an unknown action is refused', r LIKE 'ERR: Unknown action%', r);
  r := zz.adm(zz.rid('dx-test-r1-0001'), 'approve');
  PERFORM zz.check('only a refund waiting for approval can be approved', r LIKE 'ERR: Only a refund that is waiting for approval%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
