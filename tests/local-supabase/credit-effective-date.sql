-- Future effective date for credit terms: a credit line that starts in the future, and a scheduled
-- change to a running line. Until the date arrives the current terms stay in force; once it arrives
-- every reader and the checkout use the new terms, and the stored row is rewritten exactly once.
-- Run after setup.sql + migrations (through 20261020100000_credit_terms_effective_date.sql).
-- The clock can't be advanced in a test, so "the date has arrived" is simulated by back-dating the
-- stored effective / pending date. Successful create_marketplace_orders calls are top-level
-- statements (ON COMMIT DROP temp tables); failing ones run in DO blocks expecting the exception.
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
SELECT id, 'CE Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 10000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.ce AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Other Pharmacy') other_p,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM public.products WHERE name='CE Item') p_item;
CREATE TABLE zz.ce_runs(label TEXT PRIMARY KEY, order_id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000, 30 FROM zz.ce;

-- Order A: 800 on credit under the current 1000 / 30-day terms.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ce), (SELECT good FROM zz.ce),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ce), 'quantity', 8, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ce)::text, 'credit')) AS r \gset a_

-- 1. Scheduling: permissions and validation.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); p UUID := (SELECT good FROM zz.ce);
  q TEXT := 'SELECT public.schedule_credit_terms(%L, %L, %s, %s, %L, ''Agreed on review'')::text';
BEGIN
  r := zz.val_as((SELECT u_wc FROM zz.ce), format(q, w, p, 3000, 45, (current_date + 10)::text));
  PERFORM zz.check('a wholesaler cashier cannot schedule a change', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wx FROM zz.ce), format(q, w, p, 3000, 45, (current_date + 10)::text));
  PERFORM zz.check('another wholesaler cannot schedule a change on my line', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_po FROM zz.ce), format(q, w, p, 3000, 45, (current_date + 10)::text));
  PERFORM zz.check('the pharmacy cannot schedule its own terms', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format(q, w, p, 3000, 45, current_date::text));
  PERFORM zz.check('today is refused (use immediate terms instead)', r = 'ERR: The effective date must be in the future. To change terms now, save them without a date.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format(q, w, p, 3000, 45, (current_date - 1)::text));
  PERFORM zz.check('a past date is refused', r LIKE 'ERR: The effective date must be in the future%', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format(q, w, p, 3000, 45, (current_date + 366)::text));
  PERFORM zz.check('more than a year ahead is refused', r = 'ERR: The effective date can be at most one year ahead.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format(q, w, p, 0, 45, (current_date + 10)::text));
  PERFORM zz.check('a zero limit is refused', r LIKE 'ERR: The credit limit must be above GHS 0%', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format(q, w, p, 3000, 0, (current_date + 10)::text));
  PERFORM zz.check('0 payment days is refused', r = 'ERR: Payment terms must be between 1 and 365 days.', r);
  PERFORM zz.check('nothing was scheduled after the refusals',
    (SELECT pending_effective_date FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p) IS NULL
    AND (SELECT count(*) FROM public.audit_logs WHERE activity LIKE 'Credit terms change%' OR activity LIKE 'Credit line scheduled%') = 0);
END $$;

-- 2. Schedule a change on the running line: 3000 / 45 days from 10 days ahead.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); p UUID := (SELECT good FROM zz.ce);
BEGIN
  r := zz.val_as((SELECT u_wm FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 3000, 45, %L, ''Agreed on review'')::text', w, p, (current_date + 10)::text));
  PERFORM zz.check('a manager can schedule a change', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('today''s terms stay in force: 1000 / 30 days, change scheduled for +10 days',
    (SELECT credit_limit_ghs = 1000 AND payment_terms_days = 30 AND in_force AND scheduled_credit_limit_ghs = 3000
        AND scheduled_payment_terms_days = 45 AND scheduled_effective_date = current_date + 10 FROM public.credit_effective_terms(w, p)));
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT credit_limit_ghs || ''/'' || payment_terms_days || ''/'' || available_ghs || ''/'' || scheduled_credit_limit_ghs || ''/'' || scheduled_payment_terms_days FROM public.list_wholesaler_credit_terms(%L)', w));
  PERFORM zz.check('the wholesaler''s list shows 1000 / 30 days / 200 available, with 3000 / 45 scheduled', r = '1000.00/30/200.00/3000.00/45', r);
  r := zz.val_as((SELECT u_po FROM zz.ce), format('SELECT credit_limit_ghs || ''/'' || status || ''/'' || scheduled_credit_limit_ghs FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('the pharmacy sees the same: limit 1000, active, 3000 scheduled', r = '1000.00/active/3000.00', r);
  PERFORM zz.check('audit: scheduled values, the terms they replace, role and actor are recorded',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit terms change scheduled'
      AND (a.details ->> 'credit_limit_ghs')::numeric = 3000 AND (a.details ->> 'payment_terms_days')::int = 45
      AND (a.details ->> 'current_credit_limit_ghs')::numeric = 1000 AND (a.details ->> 'current_payment_terms_days')::int = 30
      AND a.details ->> 'effective_date' = (current_date + 10)::text AND a.details ->> 'actor_role' = 'manager'
      AND a.performed_by = (SELECT u_wm FROM zz.ce) AND a.business_id = w));
  PERFORM zz.check('the pharmacy owner is notified',
    EXISTS (SELECT 1 FROM public.notifications n WHERE n.user_id = (SELECT u_po FROM zz.ce) AND n.type = 'credit_terms_scheduled' AND n.body LIKE '%GHS 3,000.00%'));
END $$;

-- 3. Until the date, checkout still uses 1000.
DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.ce), (SELECT good FROM zz.ce),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ce), 'quantity', 15, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ce)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('before the date a 1500 order is refused against the current 1000 limit',
    r = 'Using credit with Alpha Wholesale would exceed your approved limit of GHS 1,000.00 (you currently owe GHS 800.00, this order is GHS 1,500.00).', r);
  PERFORM zz.check('...and the stored terms were not touched', (SELECT credit_limit_ghs FROM public.wholesaler_credit_terms WHERE wholesaler_id = (SELECT alpha FROM zz.ce) AND pharmacy_id = (SELECT good FROM zz.ce)) = 1000);
END $$;

-- 4. The date arrives (simulated). Readers switch at once; the row is rewritten at first use.
UPDATE public.wholesaler_credit_terms SET pending_effective_date = current_date - 1
WHERE wholesaler_id = (SELECT alpha FROM zz.ce) AND pharmacy_id = (SELECT good FROM zz.ce);
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); p UUID := (SELECT good FROM zz.ce);
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ce), format('SELECT credit_limit_ghs || ''/'' || payment_terms_days || ''/'' || available_ghs || ''/'' || coalesce(scheduled_credit_limit_ghs::text, ''none'') FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('once the date has arrived the pharmacy''s view already shows 3000 / 45 days / 2200 available, nothing scheduled', r = '3000.00/45/2200.00/none', r);
  PERFORM zz.check('...even though the stored row has not been rewritten yet', (SELECT credit_limit_ghs FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p) = 1000);
  -- A judge of "no override needed" must use the terms that apply today (2200 available), not the stale 1000.
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.grant_credit_override(%L, %L, 2000, 7, ''Checking the applied limit'')::text', w, p));
  PERFORM zz.check('granting an override first applies the due change and judges against 3000 (2200 available)',
    r = 'ERR: No override is needed: this pharmacy already has GHS 2,200.00 of credit available.', r);
  -- (The refused call rolls back as a whole, so the stored row is still waiting to be rewritten; the
  -- rewrite is proven below by the order that follows.)
  PERFORM zz.check('...and a refused call leaves the stored row untouched (the rewrite happens at the next successful use)',
    (SELECT credit_limit_ghs = 1000 AND pending_effective_date IS NOT NULL FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p)
    AND (SELECT count(*) FROM public.audit_logs WHERE activity = 'Credit terms change took effect') = 0);
END $$;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ce), (SELECT good FROM zz.ce),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ce), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ce)::text, 'credit')) AS r \gset b_
INSERT INTO zz.ce_runs SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE o RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = (SELECT order_id FROM zz.ce_runs WHERE label='B');
  PERFORM zz.check('a 2000 credit order (800 + 2000 = 2800) now fits the 3000 limit', o.is_credit_order AND o.total_ghs = 2000, o.total_ghs::text);
  PERFORM zz.check('...and snapshots the NEW 45-day terms', o.credit_terms_days = 45 AND o.credit_due_date = (o.created_at + interval '45 days')::date, o.credit_terms_days::text);
  PERFORM zz.check('the change took effect exactly once (audited by the system, with before / after)',
    (SELECT count(*) FROM public.audit_logs WHERE activity = 'Credit terms change took effect') = 1
    AND EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit terms change took effect'
      AND (a.details ->> 'from_credit_limit_ghs')::numeric = 1000 AND (a.details ->> 'to_credit_limit_ghs')::numeric = 3000
      AND (a.details ->> 'from_payment_terms_days')::int = 30 AND (a.details ->> 'to_payment_terms_days')::int = 45
      AND a.performed_by IS NULL AND a.business_id = (SELECT alpha FROM zz.ce)));
END $$;

-- 5. Rescheduling replaces the earlier scheduled change; cancelling clears it.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); p UUID := (SELECT good FROM zz.ce);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 5000, 60, %L)::text', w, p, (current_date + 10)::text));
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 4000, 30, %L)::text', w, p, (current_date + 20)::text));
  PERFORM zz.check('rescheduling replaces the earlier change (only the +20 day 4000 / 30 remains)',
    (SELECT pending_credit_limit_ghs = 4000 AND pending_payment_terms_days = 30 AND pending_effective_date = current_date + 20 FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p));
  PERFORM zz.check('...and the audit shows which scheduled date it replaced',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit terms change scheduled' AND a.details ->> 'replaced_scheduled_date' = (current_date + 10)::text));
  r := zz.val_as((SELECT u_wc FROM zz.ce), format('SELECT public.cancel_scheduled_credit_terms(%L, %L, ''Plans changed'')::text', w, p));
  PERFORM zz.check('a cashier cannot cancel a scheduled change', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.cancel_scheduled_credit_terms(%L, %L, ''no'')::text', w, p));
  PERFORM zz.check('cancelling needs a reason', r LIKE 'ERR: A reason of 5 to 500 characters is required to cancel a scheduled credit change.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.cancel_scheduled_credit_terms(%L, %L, ''Plans changed'')::text', w, p));
  PERFORM zz.check('the owner can cancel it', r NOT LIKE 'ERR%'
    AND (SELECT pending_effective_date IS NULL AND credit_limit_ghs = 3000 FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p), r);
  PERFORM zz.check('audit: the cancellation records what was cancelled, why, and by whom',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit scheduled change cancelled' AND a.details ->> 'was' = 'scheduled terms change'
      AND (a.details ->> 'credit_limit_ghs')::numeric = 4000 AND a.details ->> 'reason' = 'Plans changed' AND a.details ->> 'actor_role' = 'owner'));
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.cancel_scheduled_credit_terms(%L, %L, ''Nothing is left'')::text', w, p));
  PERFORM zz.check('cancelling again finds nothing scheduled', r = 'ERR: There is nothing scheduled to cancel for this pharmacy.', r);
END $$;

-- 6. A brand-new line that starts in the future (Other Pharmacy has no line yet).
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); o UUID := (SELECT other_p FROM zz.ce);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 2000, 21, %L, ''New customer, starts next week'')::text', w, o, (current_date + 7)::text));
  PERFORM zz.check('a manager can schedule a new credit line to start in 7 days', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit: recorded as a line scheduled to start',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit line scheduled to start' AND a.record_id = o AND (a.details ->> 'credit_limit_ghs')::numeric = 2000));
  r := zz.val_as((SELECT u_px FROM zz.ce), format('SELECT status || ''/'' || starts_on FROM public.get_my_credit_terms(%L, %L)', o, w));
  PERFORM zz.check('the pharmacy sees its credit as scheduled, with the start date', r = 'scheduled/' || (current_date + 7)::text, r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT starts_on::text FROM public.list_wholesaler_credit_terms(%L) WHERE pharmacy_id = %L', w, o));
  PERFORM zz.check('the wholesaler''s list shows when it starts', r = (current_date + 7)::text, r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_px FROM zz.ce), o,
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ce), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object(w::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('a credit order before the start date is refused, naming the date',
    r = 'Credit with Alpha Wholesale starts on ' || to_char(current_date + 7, 'DD Mon YYYY') || '. Choose another payment method.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.grant_credit_override(%L, %L, 5000, 7, ''Too early for this line'')::text', w, o));
  PERFORM zz.check('an override can''t be granted on a line that hasn''t started', r LIKE 'ERR: Credit for this pharmacy has not started yet (it starts on %', r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.cancel_scheduled_credit_terms(%L, %L, ''Customer changed their mind'')::text', w, o));
  PERFORM zz.check('a not-yet-started line can be cancelled, which closes it',
    r NOT LIKE 'ERR%' AND (SELECT NOT active AND effective_date IS NULL FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = o), r);
  PERFORM zz.check('...and it no longer shows to the pharmacy',
    zz.val_as((SELECT u_px FROM zz.ce), format('SELECT count(*)::text FROM public.get_my_credit_terms(%L, %L)', o, w)) = '0');
  -- Re-approve the closed line, starting in the future again.
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 2500, 14, %L)::text', w, o, (current_date + 5)::text));
  PERFORM zz.check('a closed line can be re-approved to start in the future', r NOT LIKE 'ERR%'
    AND (SELECT active AND credit_limit_ghs = 2500 AND effective_date = current_date + 5 FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = o), r);
END $$;

-- 7. The start date arrives (simulated): the line works.
UPDATE public.wholesaler_credit_terms SET effective_date = current_date - 1
WHERE wholesaler_id = (SELECT alpha FROM zz.ce) AND pharmacy_id = (SELECT other_p FROM zz.ce);
DO $$
BEGIN
  PERFORM zz.check('once the start date has arrived the pharmacy''s credit is active',
    zz.val_as((SELECT u_px FROM zz.ce), format('SELECT status FROM public.get_my_credit_terms(%L, %L)', (SELECT other_p FROM zz.ce), (SELECT alpha FROM zz.ce))) = 'active');
END $$;
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ce), (SELECT other_p FROM zz.ce),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.ce), 'quantity', 3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ce)::text, 'credit')) AS r \gset c_
DO $$
BEGIN
  PERFORM zz.check('...and a credit order on it is accepted under the 14-day terms',
    (SELECT is_credit_order AND total_ghs = 300 AND credit_terms_days = 14 FROM public.orders WHERE pharmacy_id = (SELECT other_p FROM zz.ce) ORDER BY created_at DESC LIMIT 1));
END $$;

-- 8. Immediate approval starts now; revoking drops anything scheduled.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.ce); p UUID := (SELECT good FROM zz.ce);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 9000, 90, %L)::text', w, p, (current_date + 30)::text));
  PERFORM zz.check('a change is scheduled on the Good Pharmacy line again', r NOT LIKE 'ERR%'
    AND (SELECT pending_effective_date IS NOT NULL FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p), r);
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.revoke_credit_terms(%L, %L)::text', w, p));
  PERFORM zz.check('revoking the line also drops the scheduled change',
    r = 'true' AND (SELECT NOT active AND pending_effective_date IS NULL AND pending_credit_limit_ghs IS NULL FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p), r);
  -- A future-start line saved WITHOUT a date starts immediately.
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.schedule_credit_terms(%L, %L, 1500, 10, %L)::text', w, p, (current_date + 12)::text));
  r := zz.val_as((SELECT u_wo FROM zz.ce), format('SELECT public.set_credit_terms(%L, %L, 1500, 10, ''Starting now instead'')::text', w, p));
  PERFORM zz.check('saving terms without a date starts the line now (the future start date is cleared)',
    (SELECT active AND effective_date IS NULL AND credit_limit_ghs = 1500 FROM public.wholesaler_credit_terms WHERE wholesaler_id = w AND pharmacy_id = p)
    AND zz.val_as((SELECT u_po FROM zz.ce), format('SELECT status FROM public.get_my_credit_terms(%L, %L)', p, w)) = 'active');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
