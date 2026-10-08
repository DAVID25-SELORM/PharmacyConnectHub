-- Delivery-based credit due dates (due_basis on the customer's terms, credit_due_basis on the order):
--   * order_date (default): unchanged - due = order date + terms, and delivery does not move it;
--   * delivery_date: no due date at checkout (nothing overdue, "current" aging, no reminders), the due date is
--     set when the order is delivered = delivery date + terms, with an audit entry;
--   * every creation path is covered (checked with a direct credit-order insert, as the RFQ award does);
--   * the basis is copied onto the order: switching the setting later affects only NEW orders;
--   * set_credit_due_basis: owner/manager only, validated, audited, tells the pharmacy;
--   * the credit-terms readers return due_basis; a cancelled order never gets a due date; cash orders untouched.
-- Run after setup.sql + migrations (through 20261027100000_delivery_based_due_dates.sql).
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

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a1', 'afin@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000041"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a2', 'aacc@zz.test', '{"full_name":"Alpha Accountant","phone":"+233241000042"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a3', 'aass@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000043"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b1', 'gacc@zz.test', '{"full_name":"Good Accountant","phone":"+233241000045"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = v.biz), v.uid, v.r::public.staff_role, 'active', now()
FROM (VALUES
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a1'::uuid, 'finance'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a2'::uuid, 'accountant'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a3'::uuid, 'assistant'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000b1'::uuid, 'accountant')) v(biz, uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'DD Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.ac AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Other Pharmacy') other_p,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  '30000000-0000-0000-0000-0000000000a1'::uuid u_wfin,
  '30000000-0000-0000-0000-0000000000a2'::uuid u_wacc,
  '30000000-0000-0000-0000-0000000000a3'::uuid u_wass,
  '30000000-0000-0000-0000-0000000000b1'::uuid u_pacc,
  (SELECT id FROM public.products WHERE name='DD Item') p_item;
CREATE TABLE zz.dd(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.ac), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.ac)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
-- Good Pharmacy: 30-day terms, delivery-based. Other Pharmacy: 45-day terms, order-date (the default).
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.ac UNION ALL SELECT alpha, other_p, 1000000, 45 FROM zz.ac;

-- 1. Defaults and the setter.
DO $$
DECLARE r TEXT; a UUID := (SELECT alpha FROM zz.ac); g UUID := (SELECT good FROM zz.ac);
  s TEXT := 'SELECT public.set_credit_due_basis(%L, %L, %L)::text';
BEGIN
  PERFORM zz.check('every existing customer starts on the order date', (SELECT bool_and(due_basis = 'order_date') FROM public.wholesaler_credit_terms));
  r := zz.val_as((SELECT u_wc FROM zz.ac), format(s, a, g, 'delivery_date'));  PERFORM zz.check('a cashier cannot change the basis', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wfin FROM zz.ac), format(s, a, g, 'delivery_date')); PERFORM zz.check('finance cannot change the basis', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wacc FROM zz.ac), format(s, a, g, 'delivery_date')); PERFORM zz.check('an accountant cannot change the basis', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ac), format(s, a, g, 'delivery_date'));  PERFORM zz.check('another wholesaler cannot', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format(s, a, g, 'delivery_date'));  PERFORM zz.check('the pharmacy cannot set its own supplier''s terms', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(s, a, g, 'whenever'));       PERFORM zz.check('an unknown basis is refused', r = 'ERR: Invalid due-date basis.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(s, a, g, 'order_date'));     PERFORM zz.check('setting the basis it already has is refused', r = 'ERR: The due date already starts from the order date.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ac), format(s, a, gen_random_uuid(), 'delivery_date')); PERFORM zz.check('a customer with no credit line is refused', r = 'ERR: No active credit line for this pharmacy.', r);
  r := zz.val_as((SELECT u_wm FROM zz.ac), format(s, a, g, 'delivery_date'));  PERFORM zz.check('a manager can switch Good Pharmacy to delivery-based', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the setting is stored', (SELECT due_basis FROM public.wholesaler_credit_terms WHERE pharmacy_id = g) = 'delivery_date');
  PERFORM zz.check('and Other Pharmacy is untouched', (SELECT due_basis FROM public.wholesaler_credit_terms WHERE pharmacy_id = (SELECT other_p FROM zz.ac)) = 'order_date');
  PERFORM zz.check('the change is audited with the old and new basis and "new orders only"',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit due-date basis changed' AND details->>'from' = 'order_date' AND details->>'to' = 'delivery_date' AND details->>'applies_to' = 'new orders only'));
  PERFORM zz.check('the pharmacy''s owner is told, in terms of "days after delivery"',
    EXISTS (SELECT 1 FROM public.notifications WHERE user_id = (SELECT u_po FROM zz.ac) AND title = 'Credit payment terms changed' AND body LIKE '%30 days after delivery%'));
END $$;

-- 2. An order placed BEFORE the switch for the other pharmacy-style default is not needed; place the orders now.
-- o_before: Other Pharmacy (order-date basis, 45 days). d1, d2: Good Pharmacy (delivery basis, 30 days).
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ac), (SELECT other_p FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset ob_
INSERT INTO zz.dd SELECT 'order_basis', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 2, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset d1_
INSERT INTO zz.dd SELECT 'd1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset d2_
INSERT INTO zz.dd SELECT 'd2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- A cash-on-delivery order from Good Pharmacy (not credit) for the "untouched" check.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'cod')) AS r \gset cod_
INSERT INTO zz.dd SELECT 'cod', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'order_basis');
  PERFORM zz.check('order-date customer: due date = order date + 45 days, as before', o.credit_due_basis = 'order_date' AND o.credit_due_date = o.created_at::date + 45 AND o.credit_terms_days = 45, o.credit_due_date::text);
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd1');
  PERFORM zz.check('delivery-based customer: the order records the basis and the 30-day terms', o.credit_due_basis = 'delivery_date' AND o.credit_terms_days = 30, o.credit_due_basis || '/' || COALESCE(o.credit_terms_days::text, 'null'));
  PERFORM zz.check('and has NO due date yet', o.credit_due_date IS NULL, COALESCE(o.credit_due_date::text, 'null'));
  PERFORM zz.check('it is still a real credit invoice in the ledger (2 x 100 = 200)', (SELECT invoice_ghs = 200 AND outstanding_ghs = 200 FROM public.credit_invoice_status((SELECT order_id FROM zz.dd WHERE label = 'd1'))));
  PERFORM zz.check('its status is "not_due" (never overdue before delivery)', (SELECT status FROM public.credit_invoice_status((SELECT order_id FROM zz.dd WHERE label = 'd1'))) = 'not_due');
  PERFORM zz.check('the checkout audit entry records the basis and that no due date is set yet',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id = (SELECT order_id FROM zz.dd WHERE label = 'd1') AND details::text LIKE '%delivery_date%'),
    (SELECT details::text FROM public.audit_logs WHERE record_id = (SELECT order_id FROM zz.dd WHERE label = 'd1') ORDER BY created_at LIMIT 1));
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'cod');
  PERFORM zz.check('a cash-on-delivery order is untouched (not credit, order-date default)', o.credit_due_basis = 'order_date' AND o.credit_due_date IS NULL AND o.is_credit_order = false);
END $$;

-- 3. Before delivery the invoice is not overdue, sits in "current", and no reminder is made for it.
DO $$
DECLARE s TEXT; n INTEGER;
BEGIN
  SELECT string_agg(bucket || '=' || invoices, ' ' ORDER BY bucket) INTO s FROM public.credit_aging_summary((SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac));
  PERFORM zz.check('aging: both undelivered invoices are in "current" (300), nothing overdue', (SELECT sum(outstanding_ghs) FILTER (WHERE bucket = 'current') = 300 AND sum(outstanding_ghs) FILTER (WHERE bucket <> 'current') = 0 FROM public.credit_aging_summary((SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac))), s);
  PERFORM zz.check('the register shows an empty due date and no days overdue',
    (SELECT due_date IS NULL AND days_overdue = 0 AND aging_bucket = 'current' FROM public.credit_invoice_register((SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac)) r WHERE r.order_id = (SELECT order_id FROM zz.dd WHERE label = 'd1')));
  PERFORM zz.check('and nothing is overdue on the overview (the order-date invoice is 45 days out)', (public.accounting_overview((SELECT alpha FROM zz.ac))->>'overdue_ghs')::numeric = 0);
END $$;
DO $$ BEGIN INSERT INTO zz.dd(label, order_id) VALUES ('reminders_before', NULL); PERFORM public.generate_credit_reminders(NULL); END $$;
DO $$
BEGIN
  PERFORM zz.check('no reminder is made for an invoice with no due date',
    NOT EXISTS (SELECT 1 FROM public.credit_reminders_sent WHERE order_id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'd2'))));
END $$;

-- 4. Switching the setting later affects only NEW orders: switch Good Pharmacy back to the order date.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT public.set_credit_due_basis(%L, %L, ''order_date'')::text', (SELECT alpha FROM zz.ac), (SELECT good FROM zz.ac)));
  PERFORM zz.check('the owner switches Good Pharmacy back to the order date', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the existing delivery-based invoices keep their basis (still no due date)', (SELECT bool_and(credit_due_basis = 'delivery_date' AND credit_due_date IS NULL) FROM public.orders WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'd2'))));
END $$;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ac), (SELECT good FROM zz.ac),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ac), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ac)::text, 'credit')) AS r \gset d3_
INSERT INTO zz.dd SELECT 'd3_order_date', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd3_order_date');
  PERFORM zz.check('a NEW order after switching back is order-date based again (due = today + 30)', o.credit_due_basis = 'order_date' AND o.credit_due_date = o.created_at::date + 30, COALESCE(o.credit_due_date::text, 'null'));
END $$;

-- 5. Any creation path: a direct credit-order insert (as the RFQ award does) for a delivery-based customer.
UPDATE public.wholesaler_credit_terms SET due_basis = 'delivery_date' WHERE pharmacy_id = (SELECT other_p FROM zz.ac);
INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date)
SELECT other_p, alpha, 100, 0, 0, 100, 'cod', true, current_date + 21 FROM zz.ac;
INSERT INTO zz.dd SELECT 'direct', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'direct');
  PERFORM zz.check('a credit order created by any other path (e.g. an RFQ award) under a delivery-based customer: due date cleared, its own 21-day terms kept',
    o.credit_due_basis = 'delivery_date' AND o.credit_due_date IS NULL AND o.credit_terms_days = 21, o.credit_due_basis || '/' || COALESCE(o.credit_due_date::text, 'null') || '/' || COALESCE(o.credit_terms_days::text, 'null'));
END $$;

-- 6. Delivery sets the due date. Production's order guard makes created_at immutable, so it is lifted ONLY to backdate
--    the fixtures (d1 was "placed" 10 days ago), then restored. (Without the guard this does nothing.)
DO $$
DECLARE trg RECORD;
BEGIN
  FOR trg IN SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass AND NOT tgisinternal
      AND tgfoid IN (SELECT oid FROM pg_proc WHERE proname = 'phase0_order_integrity') LOOP
    EXECUTE format('ALTER TABLE public.orders DISABLE TRIGGER %I', trg.tgname);
  END LOOP;
END $$;
UPDATE public.orders SET created_at = now() - interval '10 days' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
DO $$
DECLARE trg RECORD;
BEGIN
  FOR trg IN SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass AND NOT tgisinternal
      AND tgfoid IN (SELECT oid FROM pg_proc WHERE proname = 'phase0_order_integrity') LOOP
    EXECUTE format('ALTER TABLE public.orders ENABLE TRIGGER %I', trg.tgname);
  END LOOP;
END $$;
-- Walk d1 and the order-date order through the real lifecycle to delivered.
UPDATE public.orders SET status = 'accepted' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis', 'd2'));
UPDATE public.orders SET status = 'picking' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
UPDATE public.orders SET status = 'packed' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
UPDATE public.orders SET status = 'dispatched' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
DO $$
BEGIN
  PERFORM zz.check('while dispatched (not yet delivered) the delivery-based invoice still has no due date', (SELECT credit_due_date IS NULL FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd1')));
END $$;
UPDATE public.orders SET status = 'delivered' WHERE id IN (SELECT order_id FROM zz.dd WHERE label IN ('d1', 'order_basis'));
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd1');
  PERFORM zz.check('delivered: due date = DELIVERY date + 30 (today + 30), NOT the order date + 30 (10 days ago)',
    o.credit_due_date = o.delivered_at::date + 30 AND o.credit_due_date = current_date + 30 AND o.credit_due_date <> o.created_at::date + 30, COALESCE(o.credit_due_date::text, 'null'));
  PERFORM zz.check('the delivery sets the due date once and the order is now an ordinary dated invoice (status "not_due", 30 days ahead)', (SELECT status FROM public.credit_invoice_status(o.id)) = 'not_due');
  PERFORM zz.check('an audit entry records the due date set on delivery',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit due date set on delivery' AND record_id = o.id AND details->>'terms_days' = '30' AND (details->>'due_date')::date = o.credit_due_date AND details->>'basis' = 'delivery_date'));
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'order_basis');
  PERFORM zz.check('the order-date order is NOT moved by delivery: it keeps the due date set at checkout (today + 45)', o.credit_due_date = current_date + 45 AND o.credit_due_basis = 'order_date', o.credit_due_date::text);
  PERFORM zz.check('no "due date set on delivery" audit entry for the order-date order', NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Credit due date set on delivery' AND record_id = o.id));
END $$;

-- 7. A cancelled delivery-based order never gets a due date; the second order is cancelled after acceptance.
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd2');
DO $$
BEGIN
  PERFORM zz.check('a cancelled delivery-based order never gets a due date', (SELECT credit_due_date IS NULL AND status::text = 'cancelled' FROM public.orders WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd2')));
END $$;

-- 8. Reminders and aging work once the due date exists: make d1's due date look 31 days overdue.
UPDATE public.orders SET credit_due_date = current_date - 31 WHERE id = (SELECT order_id FROM zz.dd WHERE label = 'd1');
DO $$ BEGIN PERFORM public.generate_credit_reminders(NULL); END $$;
DO $$
BEGIN
  PERFORM zz.check('once a due date exists the invoice is reminded about like any other (31 days overdue = overdue_30)',
    EXISTS (SELECT 1 FROM public.credit_reminders_sent WHERE order_id = (SELECT order_id FROM zz.dd WHERE label = 'd1') AND kind = 'overdue_30'));
END $$;

-- 9. The readers return the basis.
DO $$
DECLARE a UUID := (SELECT alpha FROM zz.ac); r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ac), format('SELECT string_agg(pharmacy_name || '':'' || due_basis, '','' ORDER BY pharmacy_name) FROM public.list_wholesaler_credit_terms(%L)', a));
  PERFORM zz.check('the wholesaler''s terms list shows the basis per customer', r = 'Good Pharmacy:order_date,Other Pharmacy:delivery_date', r);
  r := zz.val_as((SELECT u_po FROM zz.ac), format('SELECT due_basis FROM public.get_my_credit_terms(%L, %L)', (SELECT good FROM zz.ac), a));
  PERFORM zz.check('the pharmacy sees its own supplier''s basis', r = 'order_date', r);
  r := zz.val_as((SELECT u_px FROM zz.ac), format('SELECT due_basis FROM public.get_my_credit_terms(%L, %L)', (SELECT other_p FROM zz.ac), a));
  PERFORM zz.check('and Other Pharmacy sees delivery_date', r = 'delivery_date', r);
  r := zz.val_as((SELECT u_wc FROM zz.ac), format('SELECT count(*)::text FROM public.list_wholesaler_credit_terms(%L)', a));
  PERFORM zz.check('the terms list is still owner/manager only (a cashier is refused)', r = 'ERR: Only wholesaler owners and managers may view credit terms.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
