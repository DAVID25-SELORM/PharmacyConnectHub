-- Phase 2: settlement (payment) method. Choosing a method is never payment: every order starts
-- unpaid. Online payment is refused until it exists. Credit contradicting another method is an
-- error. A placed order's method can be changed only while unpaid / non-credit / open, with a
-- reason, by authorized staff, and is audited.
-- Run after setup.sql + migrations (through 20261015100000_settlement_method.sql).
-- Successful create_marketplace_orders calls are separate top-level statements (ON COMMIT DROP
-- temp tables); failing ones run in DO blocks that expect the exception.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
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
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

SELECT zz.mkuser('20000000-0000-0000-0000-0000000000d1', 'sc@zz.test', '{"full_name":"Pharm Cashier","phone":"+233241000031"}');
SELECT zz.mkuser('20000000-0000-0000-0000-0000000000d2', 'sa@zz.test', '{"full_name":"Pharm Assistant","phone":"+233241000032"}');
SELECT zz.mkuser('20000000-0000-0000-0000-0000000000d3', 'sacc@zz.test', '{"full_name":"Pharm Accountant","phone":"+233241000033"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name='Good Pharmacy'), v.uid, v.r::public.staff_role, 'active', now()
FROM (VALUES ('20000000-0000-0000-0000-0000000000d1'::uuid, 'cashier'),
             ('20000000-0000-0000-0000-0000000000d2'::uuid, 'assistant'),
             ('20000000-0000-0000-0000-0000000000d3'::uuid, 'accountant')) v(uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'ST Alpha Item', 'Generic', 'Analgesic', 'TABLET', '100s', 10, 5000, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'ST Other Item', 'Generic', 'Antibiotic', 'CAPSULE', '100s', 20, 5000, true FROM zz.b WHERE name='Other Wholesale';

CREATE TABLE zz.st AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other_w,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  '20000000-0000-0000-0000-0000000000d1'::uuid u_cashier,
  '20000000-0000-0000-0000-0000000000d2'::uuid u_assistant,
  '20000000-0000-0000-0000-0000000000d3'::uuid u_accountant,
  (SELECT id FROM public.products WHERE name='ST Alpha Item') p_alpha,
  (SELECT id FROM public.products WHERE name='ST Other Item') p_other;
CREATE TABLE zz.st_runs(label TEXT PRIMARY KEY, procurement_id UUID, returned INTEGER);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 5000, 30 FROM zz.st;

-- 1. Every non-credit method is stored, and none of them is payment.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'bank_transfer')) AS r \gset m1_
INSERT INTO zz.st_runs SELECT 'bank_transfer', id, :m1_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'momo')) AS r \gset m2_
INSERT INTO zz.st_runs SELECT 'momo', id, :m2_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'cheque')) AS r \gset m3_
INSERT INTO zz.st_runs SELECT 'cheque', id, :m3_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'other')) AS r \gset m4_
INSERT INTO zz.st_runs SELECT 'other', id, :m4_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'cod')) AS r \gset m5_
INSERT INTO zz.st_runs SELECT 'cod', id, :m5_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;

DO $$
DECLARE lbl TEXT; o RECORD;
BEGIN
  FOREACH lbl IN ARRAY ARRAY['bank_transfer', 'momo', 'cheque', 'other', 'cod'] LOOP
    SELECT * INTO o FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label = lbl);
    PERFORM zz.check(lbl || ': method stored on the order', o.settlement_method = lbl, o.settlement_method);
    PERFORM zz.check(lbl || ': created UNPAID, no paid_at, no confirmation (selecting a method is not payment)',
      o.payment_status = 'unpaid' AND o.paid_at IS NULL AND o.payment_confirmed_at IS NULL);
    PERFORM zz.check(lbl || ': not a credit order, no due date, nothing in the credit ledger',
      NOT o.is_credit_order AND o.credit_due_date IS NULL AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = o.id));
  END LOOP;
END $$;

-- 2. Credit chosen through the map alone.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 10, 'category', 'nhis')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'credit')) AS r \gset c1_
INSERT INTO zz.st_runs SELECT 'credit-map', id, :c1_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
-- Legacy credit list with no map still means credit; no arguments at all still means COD.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
  ARRAY[(SELECT alpha FROM zz.st)], TRUE) AS r \gset c2_
INSERT INTO zz.st_runs SELECT 'credit-legacy', id, :c2_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1))) AS r \gset c3_
INSERT INTO zz.st_runs SELECT 'default', id, :c3_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='credit-map');
  PERFORM zz.check('credit via map: settlement credit, credit order with due date, still UNPAID',
    o.settlement_method = 'credit' AND o.is_credit_order AND o.credit_due_date IS NOT NULL AND o.payment_status = 'unpaid' AND o.paid_at IS NULL);
  PERFORM zz.check('credit via map: one ledger invoice for the full total',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = o.id AND entry_type = 'invoice' AND amount_ghs = o.total_ghs) = 1);
  PERFORM zz.check('legacy credit list (no map) still records credit',
    (SELECT settlement_method FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='credit-legacy')) = 'credit');
  PERFORM zz.check('no method given at all defaults to cash on delivery, unpaid',
    (SELECT settlement_method = 'cod' AND payment_status = 'unpaid' FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='default')));
  PERFORM zz.check('audit: payment terms recorded with the order',
    (SELECT details ->> 'settlement_method' FROM public.audit_logs WHERE record_id = o.id AND activity = 'Order classification recorded') = 'credit'
    AND (SELECT details ->> 'payment_status' FROM public.audit_logs WHERE record_id = o.id AND activity = 'Order classification recorded') = 'unpaid');
END $$;

-- 3. Refusals, each before anything is reserved.
DO $$
DECLARE r TEXT; stock_before INTEGER := (SELECT stock FROM public.products WHERE name = 'ST Alpha Item'); orders_before BIGINT := (SELECT count(*) FROM public.orders);
  items JSONB := jsonb_build_array(jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 1, 'category', 'cash_private'));
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st), items, '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'pay_now'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('Pay Now is refused: no online payment exists', r = 'Online payment is not available yet. Choose another payment method.', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st), items, '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'barter'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('an unknown method is refused', r = 'Invalid payment method.', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st), items, '{}', TRUE, '["cod"]'::jsonb);
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('a non-map payload is refused', r = 'Payment methods must be a map of supplier to method.', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st), items, ARRAY[(SELECT alpha FROM zz.st)], TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'momo'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('credit requested but another method chosen is an error, not a silent pick', r LIKE 'Conflicting payment method for Alpha Wholesale%', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_other FROM zz.st), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT other_w FROM zz.st)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('credit with a supplier that has not approved it is refused', r = 'Other Wholesale has not approved credit for your pharmacy.', r);
  PERFORM zz.check('nothing reserved or created by any refusal',
    (SELECT stock FROM public.products WHERE name = 'ST Alpha Item') = stock_before AND (SELECT count(*) FROM public.orders) = orders_before);
END $$;

-- 4. Two suppliers in one cart, a different method for each.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.st), (SELECT good FROM zz.st), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_alpha FROM zz.st), 'quantity', 2, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_other FROM zz.st), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.st)::text, 'credit', (SELECT other_w FROM zz.st)::text, 'momo')) AS r \gset two_
INSERT INTO zz.st_runs SELECT 'two-suppliers', id, :two_r FROM public.procurements ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE pid UUID := (SELECT procurement_id FROM zz.st_runs WHERE label='two-suppliers');
BEGIN
  PERFORM zz.check('two suppliers, two orders, each with its own method',
    (SELECT returned FROM zz.st_runs WHERE label='two-suppliers') = 2
    AND (SELECT settlement_method FROM public.orders WHERE procurement_id = pid AND wholesaler_id = (SELECT alpha FROM zz.st)) = 'credit'
    AND (SELECT settlement_method FROM public.orders WHERE procurement_id = pid AND wholesaler_id = (SELECT other_w FROM zz.st)) = 'momo');
END $$;

-- 5. Changing the method of a placed order.
CREATE TABLE zz.st_t(k TEXT PRIMARY KEY, v TEXT);
GRANT ALL ON zz.st_t TO PUBLIC;
INSERT INTO zz.st_t SELECT 'cod_order', id::text FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='cod');
INSERT INTO zz.st_t SELECT 'credit_order', id::text FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='credit-map');
INSERT INTO zz.st_t SELECT 'cheque_order', id::text FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='cheque');
INSERT INTO zz.st_t SELECT 'momo_order', id::text FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='momo');
INSERT INTO zz.st_t SELECT 'other_order', id::text FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.st_runs WHERE label='other');

DO $$
DECLARE r TEXT; ord UUID := (SELECT v::uuid FROM zz.st_t WHERE k='cod_order');
  q TEXT := 'SELECT public.change_order_settlement_method(%L, %L, %L)::text';
BEGIN
  r := zz.val_as((SELECT u_px FROM zz.st), format(q, ord, 'bank_transfer', 'Supplier asked for a transfer'));
  PERFORM zz.check('another pharmacy cannot see or change it (not found)', r = 'ERR: Order not found.', r);
  r := zz.val_as((SELECT u_wo FROM zz.st), format(q, ord, 'bank_transfer', 'Supplier asked for a transfer'));
  PERFORM zz.check('the supplier cannot change the pharmacy''s payment method (not found)', r = 'ERR: Order not found.', r);
  r := zz.val_as((SELECT u_assistant FROM zz.st), format(q, ord, 'bank_transfer', 'Supplier asked for a transfer'));
  PERFORM zz.check('an assistant cannot change it', r LIKE 'ERR: You do not have permission to change the payment method%', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'bank_transfer', ''));
  PERFORM zz.check('a reason is required', r LIKE 'ERR: A reason of 5 to 500 characters is required%', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'credit', 'Want to defer payment'));
  PERFORM zz.check('switching to credit after placing is refused', r = 'ERR: Credit and online payment can only be chosen when the order is placed.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'pay_now', 'Want to pay online'));
  PERFORM zz.check('switching to online payment is refused', r = 'ERR: Credit and online payment can only be chosen when the order is placed.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'barter', 'Something unusual here'));
  PERFORM zz.check('an unknown method is refused', r = 'ERR: Invalid payment method.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'cod', 'Same method again please'));
  PERFORM zz.check('setting the same method is refused', r = 'ERR: This order already uses that payment method.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, (SELECT v::uuid FROM zz.st_t WHERE k='credit_order'), 'bank_transfer', 'Move off credit please'));
  PERFORM zz.check('a credit order cannot be switched off credit', r LIKE 'ERR: A credit order%can''t be changed%', r);
  PERFORM zz.check('nothing changed after all refusals', (SELECT settlement_method FROM public.orders WHERE id = ord) = 'cod'
    AND (SELECT count(*) FROM public.audit_logs WHERE activity = 'Order payment method changed') = 0);

  r := zz.val_as((SELECT u_cashier FROM zz.st), format(q, ord, 'bank_transfer', 'Supplier asked for a transfer'));
  PERFORM zz.check('a cashier can change an unpaid order''s method', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the method changed, and the order is still unpaid',
    (SELECT settlement_method = 'bank_transfer' AND payment_status = 'unpaid' AND paid_at IS NULL FROM public.orders WHERE id = ord));
  PERFORM zz.check('audit: from, to, reason, role, actor and business are recorded',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Order payment method changed' AND a.record_id = ord
      AND a.details ->> 'from' = 'cod' AND a.details ->> 'to' = 'bank_transfer' AND a.details ->> 'reason' = 'Supplier asked for a transfer'
      AND a.details ->> 'actor_role' = 'cashier' AND a.performed_by = (SELECT u_cashier FROM zz.st) AND a.business_id = (SELECT good FROM zz.st)));
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, ord, 'cheque', 'Cheque agreed on the phone'));
  PERFORM zz.check('the owner can change it again; history keeps both entries', r NOT LIKE 'ERR%'
    AND (SELECT count(*) FROM public.audit_logs WHERE activity = 'Order payment method changed' AND record_id = ord) = 2, r);
  r := zz.val_as((SELECT u_accountant FROM zz.st), format(q, ord, 'other', 'Settled through the accountant'));
  PERFORM zz.check('an accountant can change it too', r NOT LIKE 'ERR%'
    AND (SELECT settlement_method FROM public.orders WHERE id = ord) = 'other', r);
END $$;

-- 6. No change once paid, delivered or cancelled.
UPDATE public.orders SET payment_status = 'paid', paid_at = now() WHERE id = (SELECT v::uuid FROM zz.st_t WHERE k='momo_order');
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT v::uuid FROM zz.st_t WHERE k='cheque_order');
UPDATE public.orders SET status = 'delivered' WHERE id = (SELECT v::uuid FROM zz.st_t WHERE k='other_order');
DO $$
DECLARE r TEXT; q TEXT := 'SELECT public.change_order_settlement_method(%L, ''bank_transfer'', ''Trying to change it'')::text';
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, (SELECT v::uuid FROM zz.st_t WHERE k='momo_order')));
  PERFORM zz.check('a paid order''s method is locked', r = 'ERR: The payment method can''t be changed once payment has been recorded.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, (SELECT v::uuid FROM zz.st_t WHERE k='cheque_order')));
  PERFORM zz.check('a cancelled order''s method is locked', r = 'ERR: The payment method can no longer be changed on a cancelled order.', r);
  r := zz.val_as((SELECT u_po FROM zz.st), format(q, (SELECT v::uuid FROM zz.st_t WHERE k='other_order')));
  PERFORM zz.check('a delivered order''s method is locked', r = 'ERR: The payment method can no longer be changed on a delivered order.', r);
END $$;

-- 7. Inactive staff are treated as non-members.
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '20000000-0000-0000-0000-0000000000d1';
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_cashier FROM zz.st), format('SELECT public.change_order_settlement_method(%L, ''momo'', ''Inactive cashier attempt'')::text', (SELECT v::uuid FROM zz.st_t WHERE k='cod_order')));
  PERFORM zz.check('an inactive cashier is treated as a non-member (not found)', r = 'ERR: Order not found.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
