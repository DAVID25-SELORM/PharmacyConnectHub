-- One-time credit override: a wholesaler owner/manager approves ONE credit order above the limit,
-- up to a stated maximum, within a window, with a reason. It is consumed by the first order that
-- needs it, never overrides suspension / blocking, never changes the limit, and is fully audited.
-- Run after setup.sql + migrations (through 20261019100000_credit_override.sql).
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables);
-- failing ones run in DO blocks that expect the exception. The "used by exactly one of two
-- simultaneous orders" proof is credit-override-concurrency.sh.
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
SELECT id, 'CO Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 10000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.co AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM public.products WHERE name='CO Item') p_item;
CREATE TABLE zz.co_runs(label TEXT PRIMARY KEY, order_id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000, 30 FROM zz.co;

-- Order A: 800 on credit -> exposure 800, 200 of the 1000 limit left.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 8, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit')) AS r \gset a_
INSERT INTO zz.co_runs SELECT 'A', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- 1. Without an override, an order that doesn't fit is refused.
DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('no override: a 500 order against 200 available is refused',
    r = 'Using credit with Alpha Wholesale would exceed your approved limit of GHS 1,000.00 (you currently owe GHS 800.00, this order is GHS 500.00).', r);
END $$;

-- 2. Granting: permissions and validation.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.co); p UUID := (SELECT good FROM zz.co);
  q TEXT := 'SELECT public.grant_credit_override(%L, %L, %s, %s, %L)::text';
BEGIN
  r := zz.val_as((SELECT u_wc FROM zz.co), format(q, w, p, 600, 7, 'One-off bulk purchase'));
  PERFORM zz.check('a wholesaler cashier cannot grant an override', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wx FROM zz.co), format(q, w, p, 600, 7, 'One-off bulk purchase'));
  PERFORM zz.check('another wholesaler cannot grant an override on my line', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_po FROM zz.co), format(q, w, p, 600, 7, 'One-off bulk purchase'));
  PERFORM zz.check('the pharmacy cannot grant itself an override', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 0, 7, 'One-off bulk purchase'));
  PERFORM zz.check('a zero amount is refused', r = 'ERR: The override amount must be above 0 and at most 10,000,000.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 600, 0, 'One-off bulk purchase'));
  PERFORM zz.check('0 days is refused', r = 'ERR: An override can be valid for 1 to 30 days.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 600, 31, 'One-off bulk purchase'));
  PERFORM zz.check('31 days is refused', r = 'ERR: An override can be valid for 1 to 30 days.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 600, 7, 'no'));
  PERFORM zz.check('a reason is required', r LIKE 'ERR: A reason of 5 to 500 characters is required to grant a credit override.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 150, 7, 'One-off bulk purchase'));
  PERFORM zz.check('no override is needed when the amount already fits (200 available)', r = 'ERR: No override is needed: this pharmacy already has GHS 200.00 of credit available.', r);
  PERFORM zz.check('nothing was granted after the refusals', (SELECT count(*) FROM public.credit_overrides) = 0);

  r := zz.val_as((SELECT u_wm FROM zz.co), format(q, w, p, 600, 7, 'One-off bulk purchase'));
  PERFORM zz.check('a manager can grant an override of up to 600 for 7 days', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit: grant records amount, reason, role, actor, limit, exposure and available credit',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit override granted'
      AND (a.details ->> 'max_order_ghs')::numeric = 600 AND a.details ->> 'reason' = 'One-off bulk purchase' AND a.details ->> 'actor_role' = 'manager'
      AND (a.details ->> 'limit_ghs')::numeric = 1000 AND (a.details ->> 'exposure_ghs')::numeric = 800 AND (a.details ->> 'available_ghs')::numeric = 200
      AND a.performed_by = (SELECT u_wm FROM zz.co) AND a.business_id = w));
  PERFORM zz.check('the pharmacy owner is notified',
    EXISTS (SELECT 1 FROM public.notifications n WHERE n.user_id = (SELECT u_po FROM zz.co) AND n.type = 'credit_override' AND n.body LIKE '%GHS 600.00%'));
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 700, 7, 'A second override at once'));
  PERFORM zz.check('a second override while one is active is refused', r = 'ERR: An override is already active for this pharmacy. Revoke it before granting another.', r);
  r := zz.val_as((SELECT u_po FROM zz.co), format('SELECT override_max_order_ghs::text FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('the pharmacy can see the override (600)', r = '600.00', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT override_max_order_ghs || ''/'' || override_reason FROM public.list_wholesaler_credit_terms(%L)', w));
  PERFORM zz.check('the wholesaler''s list shows the override and why', r = '600.00/One-off bulk purchase', r);
END $$;

-- 3. An order bigger than the override's maximum is still refused.
DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 7, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('a 700 order exceeds the 600 override and is refused', r LIKE 'Using credit with Alpha Wholesale would exceed your approved limit%', r);
  PERFORM zz.check('...and the override is untouched', (SELECT status FROM public.credit_overrides) = 'active');
END $$;

-- 4. The 500 order goes through on the override.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit')) AS r \gset b_
INSERT INTO zz.co_runs SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE b UUID := (SELECT order_id FROM zz.co_runs WHERE label='B');
BEGIN
  PERFORM zz.check('order B (500) is accepted on the override', (SELECT is_credit_order AND total_ghs = 500 FROM public.orders WHERE id = b));
  PERFORM zz.check('...the ledger holds its 500 invoice and exposure is 1300 (above the 1000 limit)',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = b AND entry_type = 'invoice' AND amount_ghs = 500) = 1
    AND public.credit_exposure((SELECT alpha FROM zz.co), (SELECT good FROM zz.co)) = 1300);
  PERFORM zz.check('...the override is now USED, tied to order B',
    (SELECT status = 'used' AND used_order_id = b AND used_at IS NOT NULL FROM public.credit_overrides));
  PERFORM zz.check('audit: use records limit 1000, available before 200, order 500, override amount 300, resulting exposure 1300',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit override used' AND a.record_id = b
      AND (a.details ->> 'limit_ghs')::numeric = 1000 AND (a.details ->> 'available_before_ghs')::numeric = 200
      AND (a.details ->> 'order_ghs')::numeric = 500 AND (a.details ->> 'override_amount_ghs')::numeric = 300
      AND (a.details ->> 'resulting_exposure_ghs')::numeric = 1300 AND a.performed_by = (SELECT u_po FROM zz.co)));
  PERFORM zz.check('the limit itself is unchanged (1000)', (SELECT credit_limit_ghs FROM public.wholesaler_credit_terms WHERE wholesaler_id = (SELECT alpha FROM zz.co)) = 1000);
  PERFORM zz.check('the used override no longer shows as available to the pharmacy',
    zz.val_as((SELECT u_po FROM zz.co), format('SELECT coalesce(override_max_order_ghs::text, ''none'') FROM public.get_my_credit_terms(%L, %L)', (SELECT good FROM zz.co), (SELECT alpha FROM zz.co))) = 'none');
END $$;

-- 5. One use only: the next over-limit order is refused.
DO $$
DECLARE r TEXT;
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 1, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('a second over-limit order is refused: the override was one-time',
    r = 'Using credit with Alpha Wholesale would exceed your approved limit of GHS 1,000.00 (you currently owe GHS 1,300.00, this order is GHS 100.00).', r);
END $$;

-- 6. Cancelling the order that used it does not give the override back.
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.co_runs WHERE label='B');
DO $$
BEGIN
  PERFORM zz.check('cancelling B releases its credit (exposure back to 800)', public.credit_exposure((SELECT alpha FROM zz.co), (SELECT good FROM zz.co)) = 800);
  PERFORM zz.check('...but the override stays used (not refunded)', (SELECT status FROM public.credit_overrides) = 'used');
END $$;

-- 7. An override never beats suspension.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.co); p UUID := (SELECT good FROM zz.co);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT public.grant_credit_override(%L, %L, 600, 7, ''Second approved purchase'')::text', w, p));
  PERFORM zz.check('a new override can be granted once the old one is used', r NOT LIKE 'ERR%', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT public.set_credit_status(%L, %L, ''suspended'', ''Overdue invoice being chased'')::text', w, p));
  PERFORM zz.check('the line is suspended', r NOT LIKE 'ERR%', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('suspended credit refuses the order even with an active override',
    r = 'Alpha Wholesale has suspended credit for your pharmacy. Choose another payment method.', r);
  PERFORM zz.check('...and the override is not consumed', (SELECT count(*) FROM public.credit_overrides WHERE status = 'active') = 1);
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT public.set_credit_status(%L, %L, ''active'', ''Account settled and reviewed'')::text', w, p));
  PERFORM zz.check('the line is reactivated', r NOT LIKE 'ERR%', r);
END $$;

-- 8. Revoking.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.co); p UUID := (SELECT good FROM zz.co);
  q TEXT := 'SELECT public.revoke_credit_override(%L, %L, %L)::text';
BEGIN
  r := zz.val_as((SELECT u_wc FROM zz.co), format(q, w, p, 'Changed our minds'));
  PERFORM zz.check('a cashier cannot revoke an override', r = 'ERR: Only wholesaler owners and managers may manage credit terms.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 'no'));
  PERFORM zz.check('revoking needs a reason', r LIKE 'ERR: A reason of 5 to 500 characters is required to revoke a credit override.', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 'Changed our minds'));
  PERFORM zz.check('the owner can revoke an unused override', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit: revoke records who, why, and the original grant reason',
    EXISTS (SELECT 1 FROM public.audit_logs a WHERE a.activity = 'Credit override revoked' AND a.details ->> 'reason' = 'Changed our minds'
      AND a.details ->> 'granted_reason' = 'Second approved purchase' AND a.details ->> 'actor_role' = 'owner' AND a.business_id = w));
  r := zz.val_as((SELECT u_wo FROM zz.co), format(q, w, p, 'Nothing left to revoke'));
  PERFORM zz.check('revoking again finds nothing', r = 'ERR: There is no active override to revoke for this pharmacy.', r);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('after revoking, the over-limit order is refused again', r LIKE 'Using credit with Alpha Wholesale would exceed your approved limit%', r);
END $$;

-- 9. Expiry.
DO $$
DECLARE r TEXT; w UUID := (SELECT alpha FROM zz.co); p UUID := (SELECT good FROM zz.co);
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT public.grant_credit_override(%L, %L, 600, 1, ''Short window approval'')::text', w, p));
  PERFORM zz.check('a 1-day override is granted', r NOT LIKE 'ERR%', r);
  UPDATE public.credit_overrides SET expires_at = now() - interval '1 minute' WHERE status = 'active';
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.co), (SELECT good FROM zz.co),
      jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.co), 'quantity', 5, 'category', 'cash_private')),
      '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.co)::text, 'credit'));
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('an expired override cannot be used', r LIKE 'Using credit with Alpha Wholesale would exceed your approved limit%', r);
  r := zz.val_as((SELECT u_po FROM zz.co), format('SELECT coalesce(override_max_order_ghs::text, ''none'') FROM public.get_my_credit_terms(%L, %L)', p, w));
  PERFORM zz.check('...and is no longer shown to the pharmacy', r = 'none', r);
  r := zz.val_as((SELECT u_wo FROM zz.co), format('SELECT public.grant_credit_override(%L, %L, 600, 3, ''Fresh approval after expiry'')::text', w, p));
  PERFORM zz.check('a fresh override can be granted over an expired one (the stale row is marked expired)',
    r NOT LIKE 'ERR%' AND (SELECT count(*) FROM public.credit_overrides WHERE status = 'expired') = 1 AND (SELECT count(*) FROM public.credit_overrides WHERE status = 'active') = 1, r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
