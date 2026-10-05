-- Phase 3: credit foundation.
--   * exposure comes from the LEDGER, so partial payments / credit notes free credit immediately;
--   * cancelling a credit order releases its outstanding credit exactly once;
--   * a relationship can be suspended / blocked / reactivated (owner or manager, with a reason,
--     audited, pharmacy notified) and then refuses NEW credit orders but not payments;
--   * credit orders snapshot the payment-term length.
-- Run after setup.sql + migrations (through 20261016100000_credit_foundation.sql).
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables);
-- failing ones run in DO blocks that expect the exception. The simultaneous-order proof is
-- credit-concurrency.sh (it needs two database sessions at once, which a single SQL file can't do).
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

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'CF Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 10000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.cf AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM public.products WHERE name='CF Item') p_item;
CREATE TABLE zz.cf_runs(label TEXT PRIMARY KEY, order_id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000, 14 FROM zz.cf;

-- 1. Order A: 4 x 100 = 400 on credit (14-day terms).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 4, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit')) AS r \gset a_
INSERT INTO zz.cf_runs SELECT 'A', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.cf_runs WHERE label='A');
  PERFORM zz.check('order A is a 400 credit order', o.is_credit_order AND o.total_ghs = 400, o.total_ghs::text);
  PERFORM zz.check('order A snapshots the 14-day terms it was placed under', o.credit_terms_days = 14, o.credit_terms_days::text);
  PERFORM zz.check('order A due date is order date + 14 days (behaviour unchanged)', o.credit_due_date = (o.created_at + interval '14 days')::date);
  PERFORM zz.check('exposure comes from the ledger: 400', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 400);
  PERFORM zz.check('audit: credit position recorded with the order (limit 1000, before 0, after 400, 600 left)',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.record_id = o.id AND a.activity = 'Order classification recorded'
      AND (a.details #>> '{credit,limit_ghs}')::numeric = 1000 AND (a.details #>> '{credit,exposure_before_ghs}')::numeric = 0
      AND (a.details #>> '{credit,exposure_after_ghs}')::numeric = 400 AND (a.details #>> '{credit,available_after_ghs}')::numeric = 600
      AND (a.details #>> '{credit,terms_days}')::int = 14));
END $$;

-- 2. A PARTIAL payment frees credit immediately (the old order-total calculation did not).
DO $$
DECLARE r TEXT; a UUID := (SELECT order_id FROM zz.cf_runs WHERE label='A');
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.cf), format(
    'SELECT public.record_credit_payment(%L, %L, 150, ''bank_transfer'', ''REF-A1'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf), jsonb_build_array(jsonb_build_object('order_id', a, 'amount', 150))::text));
  PERFORM zz.check('a partial payment of 150 is recorded', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('...order A is only partly paid (still unpaid as an order)', (SELECT payment_status::text FROM public.orders WHERE id = a) = 'unpaid');
  PERFORM zz.check('...but exposure is now 250, not 400', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 250);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT outstanding_ghs || ''/'' || available_ghs || ''/'' || status FROM public.list_wholesaler_credit_terms(%L)', (SELECT alpha FROM zz.cf)));
  PERFORM zz.check('the wholesaler''s credit list shows 250 owed / 750 available / active', r = '250.00/750.00/active', r);
  r := zz.val_as((SELECT u_po FROM zz.cf), format('SELECT outstanding_ghs || ''/'' || available_ghs || ''/'' || status FROM public.get_my_credit_terms(%L, %L)', (SELECT good FROM zz.cf), (SELECT alpha FROM zz.cf)));
  PERFORM zz.check('the pharmacy sees the same 250 / 750 / active', r = '250.00/750.00/active', r);
END $$;

-- 3. The limit check uses the ledger: 250 owed + 700 = 950 fits a 1000 limit (it would have been
--    refused when 400 was counted). 250 + 800 = 1050 does not.
DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 8, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('an order that would pass the limit is refused with the real figures',
    r = 'Using credit with Alpha Wholesale would exceed your approved limit of GHS 1,000.00 (you currently owe GHS 250.00, this order is GHS 800.00).', r);
END $$;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 7, 'category', 'nhis')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit')) AS r \gset b_
INSERT INTO zz.cf_runs SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
BEGIN
  PERFORM zz.check('order B (700) is accepted because the partial payment freed credit', (SELECT total_ghs FROM public.orders WHERE id = (SELECT order_id FROM zz.cf_runs WHERE label='B')) = 700);
  PERFORM zz.check('exposure is now 950', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 950);
END $$;

-- 4. A credit note frees credit too.
DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT public.record_credit_adjustment(%L, %L, %L, ''credit_note'', ''credit'', 100, ''Order cancelled'')::text',
    (SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf), (SELECT order_id FROM zz.cf_runs WHERE label='B')));
  PERFORM zz.check('a 100 credit note is recorded', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('...exposure falls to 850', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 850);
END $$;

-- 5. Cancelling a credit order releases what is still outstanding on it, once.
--    Order B: invoice 700, credit note 100 -> 600 outstanding.
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.cf_runs WHERE label='B');
DO $$
DECLARE b UUID := (SELECT order_id FROM zz.cf_runs WHERE label='B');
BEGIN
  PERFORM zz.check('cancelling B posts one credit note for the 600 still outstanding',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = b AND cancellation_order_id = b AND entry_type = 'credit_note' AND direction = 'credit' AND amount_ghs = 600) = 1);
  PERFORM zz.check('...B''s own balance is zero', (SELECT outstanding_ghs FROM public.credit_invoice_status(b)) = 0);
  PERFORM zz.check('...exposure falls to 250 (only order A''s unpaid part)', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 250);
END $$;
-- Re-cancelling must not release credit a second time.
-- (Where production's lifecycle guard is installed an order can't be reopened at all, so there is
-- nothing to re-cancel; the attempt is allowed to be refused and the checks below still must hold.)
DO $$
BEGIN
  UPDATE public.orders SET status = 'pending' WHERE id = (SELECT order_id FROM zz.cf_runs WHERE label='B');
  UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.cf_runs WHERE label='B');
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'Invalid order transition:%' THEN RAISE; END IF;
END $$;
DO $$
BEGIN
  PERFORM zz.check('cancelling again does not double-release (still exactly one release entry)',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = (SELECT order_id FROM zz.cf_runs WHERE label='B') AND cancellation_order_id = (SELECT order_id FROM zz.cf_runs WHERE label='B')) = 1);
  PERFORM zz.check('...and exposure is unchanged at 250', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 250);
END $$;

-- 6. Suspend / block / reactivate.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.cf); p UUID := (SELECT good FROM zz.cf);
  q TEXT := 'SELECT public.set_credit_status(%L, %L, %L, %L)::text';
BEGIN
  r := zz.val_as((SELECT u_wc FROM zz.cf), format(q, w, p, 'suspended', 'Chasing an overdue invoice'));
  PERFORM zz.check('a wholesaler cashier cannot change credit status', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wx FROM zz.cf), format(q, w, p, 'suspended', 'Chasing an overdue invoice'));
  PERFORM zz.check('another wholesaler cannot change my credit status', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_po FROM zz.cf), format(q, w, p, 'suspended', 'Chasing an overdue invoice'));
  PERFORM zz.check('the pharmacy cannot change its supplier''s credit decision', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format(q, w, p, 'frozen', 'Chasing an overdue invoice'));
  PERFORM zz.check('an unknown status is refused', r = 'ERR: Invalid credit status.', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format(q, w, p, 'suspended', 'no'));
  PERFORM zz.check('a reason is required', r LIKE 'ERR: A reason of 5 to 500 characters is required%', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format(q, w, p, 'active', 'Already active, no change'));
  PERFORM zz.check('setting the same status is refused', r = 'ERR: This credit line is already active.', r);
  PERFORM zz.check('nothing changed after the refusals', (SELECT status FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p) = 'active'
    AND (SELECT count(*) FROM public.audit_logs WHERE activity LIKE 'Credit account %') = 0);

  r := zz.val_as((SELECT u_wm FROM zz.cf), format(q, w, p, 'suspended', 'Chasing an overdue invoice'));
  PERFORM zz.check('a manager can suspend credit', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit: from, to, reason, role, actor and exposure recorded',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit account suspended' AND a.details ->> 'from' = 'active' AND a.details ->> 'to' = 'suspended'
      AND a.details ->> 'reason' = 'Chasing an overdue invoice' AND a.details ->> 'actor_role' = 'manager' AND (a.details ->> 'exposure_ghs')::numeric = 250
      AND a.performed_by = (SELECT u_wm FROM zz.cf) AND a.business_id = w));
  PERFORM zz.check('the pharmacy owner is notified',
    EXISTS (SELECT 1 FROM public.notifications n WHERE n.user_id = (SELECT u_po FROM zz.cf) AND n.type = 'credit_status' AND n.title = 'Credit suspended' AND n.body LIKE '%Chasing an overdue invoice%'));
  r := zz.val_as((SELECT u_po FROM zz.cf), format('SELECT status FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('the pharmacy can see its credit is suspended', r = 'suspended', r);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('suspended credit refuses a new credit order, with a clear message',
    r = 'Alpha Wholesale has suspended credit for your pharmacy. Choose another payment method.', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format(
    'SELECT public.record_credit_payment(%L, %L, 50, ''cash'', ''REF-S1'', NULL, NULL, NULL, %L::jsonb)::text',
    (SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf), jsonb_build_array(jsonb_build_object('order_id', (SELECT order_id FROM zz.cf_runs WHERE label='A'), 'amount', 50))::text));
  PERFORM zz.check('...but a payment on an existing invoice is still accepted while suspended', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('...and frees credit as usual (exposure 200)', public.credit_exposure((SELECT alpha FROM zz.cf), (SELECT good FROM zz.cf)) = 200);
END $$;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 1, 'category', 'cash_private'))) AS r \gset cod_
DO $$
BEGIN
  PERFORM zz.check('a cash-on-delivery order from the same supplier is unaffected by the suspension',
    (SELECT count(*) FROM public.orders WHERE NOT is_credit_order AND wholesaler_id = (SELECT alpha FROM zz.cf)) = 1);
END $$;

DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.cf); p UUID := (SELECT good FROM zz.cf);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT public.set_credit_status(%L, %L, ''blocked'', ''Repeated late payment'')::text', w, p));
  PERFORM zz.check('the owner can escalate to blocked', r NOT LIKE 'ERR%', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('blocked credit refuses a new credit order, with its own message',
    r = 'Credit with Alpha Wholesale is blocked for your pharmacy. Choose another payment method.', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT public.set_credit_status(%L, %L, ''active'', ''Account settled and reviewed'')::text', w, p));
  PERFORM zz.check('the owner can reactivate credit', r NOT LIKE 'ERR%' AND (SELECT status FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p) = 'active', r);
  PERFORM zz.check('all three changes are in the audit log',
    (SELECT count(*) FROM public.audit_logs WHERE activity IN ('Credit account suspended', 'Credit account blocked', 'Credit account reactivated')) = 3);
END $$;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cf), (SELECT good FROM zz.cf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.cf), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cf)::text, 'credit')) AS r \gset c_
DO $$
BEGIN
  PERFORM zz.check('after reactivation a credit order is accepted again',
    (SELECT count(*) FROM public.orders WHERE is_credit_order AND wholesaler_id = (SELECT alpha FROM zz.cf) AND status <> 'cancelled') = 2);
END $$;

-- 7. A closed (revoked) line cannot be re-statused, and offers no credit.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.cf); p UUID := (SELECT good FROM zz.cf);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT public.revoke_credit_terms(%L, %L)::text', w, p));
  PERFORM zz.check('the line can be revoked (closed)', r = 'true', r);
  r := zz.val_as((SELECT u_wo FROM zz.cf), format('SELECT public.set_credit_status(%L, %L, ''suspended'', ''Trying on a closed line'')::text', w, p));
  PERFORM zz.check('a closed line can''t be suspended', r = 'ERR: No active credit line for this pharmacy.', r);
  r := zz.val_as((SELECT u_po FROM zz.cf), format('SELECT count(*)::text FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('a closed line no longer shows as available credit', r = '0', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;

DO $$ BEGIN IF EXISTS (SELECT 1 FROM zz.results WHERE NOT ok OR ok IS NULL) THEN RAISE EXCEPTION 'Credit foundation checks failed'; END IF; END $$;
