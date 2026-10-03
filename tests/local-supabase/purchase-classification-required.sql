-- Phase 1: purchase classification is required on a real checkout, a mixed order stays ONE order
-- (even with credit), and a placed order's classification can only be changed by authorized staff
-- with a reason, fully audited.
-- Run after setup.sql + migrations (through 20261014100000_purchase_classification_required.sql).
-- Successful create_marketplace_orders calls are separate top-level statements (ON COMMIT DROP
-- temp tables); failing ones run inside DO blocks that expect the exception.
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

-- Extra pharmacy staff on Good Pharmacy: cashier, manager, accountant.
SELECT zz.mkuser('20000000-0000-0000-0000-0000000000c1', 'pc@zz.test', '{"full_name":"Pharm Cashier","phone":"+233241000021"}');
SELECT zz.mkuser('20000000-0000-0000-0000-0000000000c2', 'pm@zz.test', '{"full_name":"Pharm Manager","phone":"+233241000022"}');
SELECT zz.mkuser('20000000-0000-0000-0000-0000000000c3', 'pa@zz.test', '{"full_name":"Pharm Accountant","phone":"+233241000023"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name='Good Pharmacy'), v.uid, v.r::public.staff_role, 'active', now()
FROM (VALUES ('20000000-0000-0000-0000-0000000000c1'::uuid, 'cashier'),
             ('20000000-0000-0000-0000-0000000000c2'::uuid, 'manager'),
             ('20000000-0000-0000-0000-0000000000c3'::uuid, 'accountant')) v(uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'CR Paracetamol', 'Generic', 'Analgesic', 'TABLET', '100s', 10, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'CR Vitamin C', 'Generic', 'Supplement', 'TABLET', '30s', 20, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'CR Amoxicillin', 'Generic', 'Antibiotic', 'CAPSULE', '100s', 30, 1000, true FROM zz.b WHERE name='Alpha Wholesale';

CREATE TABLE zz.cr AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  '20000000-0000-0000-0000-0000000000c1'::uuid u_cashier,
  '20000000-0000-0000-0000-0000000000c2'::uuid u_manager,
  '20000000-0000-0000-0000-0000000000c3'::uuid u_accountant,
  (SELECT id FROM public.products WHERE name='CR Paracetamol') p_para,
  (SELECT id FROM public.products WHERE name='CR Vitamin C') p_vitc,
  (SELECT id FROM public.products WHERE name='CR Amoxicillin') p_amox;
CREATE TABLE zz.cr_runs(label TEXT PRIMARY KEY, procurement_id UUID, returned INTEGER);

-- Credit line with Alpha so we can prove a mixed order stays ONE credit order.
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 5000, 30 FROM zz.cr;
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;

-- 1. A real checkout (required = TRUE) with unclassified lines is refused; nothing is reserved.
DO $$
DECLARE r TEXT; stock_before INTEGER := (SELECT stock FROM public.products WHERE name='CR Paracetamol'); orders_before BIGINT := (SELECT count(*) FROM public.orders);
BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
      jsonb_build_object('productId', (SELECT p_para FROM zz.cr), 'quantity', 5, 'category', 'nhis'),
      jsonb_build_object('productId', (SELECT p_vitc FROM zz.cr), 'quantity', 2),
      jsonb_build_object('productId', (SELECT p_amox FROM zz.cr), 'quantity', 1)
    ), '{}', TRUE);
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('required: unclassified lines are refused with a count', r = '2 item(s) still need a purchase classification.', r);
  PERFORM zz.check('required: nothing reserved or created on refusal',
    (SELECT stock FROM public.products WHERE name='CR Paracetamol') = stock_before AND (SELECT count(*) FROM public.orders) = orders_before);
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
      jsonb_build_object('productId', (SELECT p_para FROM zz.cr), 'quantity', 1, 'category', 'wholesale')), '{}', TRUE);
    r := 'no error';
  EXCEPTION WHEN OTHERS THEN r := SQLERRM; END;
  PERFORM zz.check('required: an invalid classification value is still rejected', r = 'Invalid purchase category.', r);
END $$;

-- 2. Mixed classification + credit = ONE order, ONE credit invoice for the full total.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_para FROM zz.cr), 'quantity', 100, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_amox FROM zz.cr), 'quantity', 10, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_vitc FROM zz.cr), 'quantity', 5, 'category', 'cash_private')
), ARRAY[(SELECT alpha FROM zz.cr)], TRUE) AS returned \gset m_
INSERT INTO zz.cr_runs SELECT 'mixed', id, :m_returned FROM public.procurements ORDER BY created_at DESC LIMIT 1;
DO $$
DECLARE pid UUID := (SELECT procurement_id FROM zz.cr_runs WHERE label='mixed'); o RECORD; a RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE procurement_id = pid;
  PERFORM zz.check('mixed + credit: still a single order', (SELECT returned FROM zz.cr_runs WHERE label='mixed') = 1
    AND (SELECT count(*) FROM public.orders WHERE procurement_id = pid) = 1);
  PERFORM zz.check('...categorised mixed, with all three lines on it', o.purchase_category = 'mixed'
    AND (SELECT count(*) FROM public.order_items WHERE order_id = o.id) = 3);
  PERFORM zz.check('...the whole order is the credit invoice (1000 + 300 + 100 = 1400)', o.is_credit_order AND o.total_ghs = 1400, o.total_ghs::text);
  PERFORM zz.check('...one ledger invoice for the full total',
    (SELECT count(*) FROM public.credit_ledger_entries WHERE order_id = o.id AND entry_type='invoice' AND amount_ghs = 1400) = 1);
  PERFORM zz.check('...procurement category is mixed', (SELECT purchase_category FROM public.procurements WHERE id = pid) = 'mixed');
  SELECT * INTO a FROM public.audit_logs WHERE record_id = o.id AND activity = 'Order classification recorded';
  PERFORM zz.check('audit: classification recorded at submission', a.id IS NOT NULL);
  PERFORM zz.check('audit: carries the NHIS / cash split (2 NHIS lines worth 1300, 1 cash line worth 100)',
    a.details #>> '{by_classification,nhis,lines}' = '2' AND (a.details #>> '{by_classification,nhis,value_ghs}')::numeric = 1300
    AND a.details #>> '{by_classification,cash_private,lines}' = '1' AND (a.details #>> '{by_classification,cash_private,value_ghs}')::numeric = 100, a.details::text);
  PERFORM zz.check('audit: actor and pharmacy business recorded', a.performed_by = (SELECT u_po FROM zz.cr) AND a.business_id = (SELECT good FROM zz.cr));
END $$;

-- 3. All NHIS and all cash stay single orders with the matching category.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_para FROM zz.cr), 'quantity', 3, 'category', 'nhis'),
  jsonb_build_object('productId', (SELECT p_amox FROM zz.cr), 'quantity', 1, 'category', 'nhis')
), '{}', TRUE) AS returned \gset n_
INSERT INTO zz.cr_runs SELECT 'all-nhis', id, :n_returned FROM public.procurements ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_vitc FROM zz.cr), 'quantity', 2, 'category', 'cash_private')
), '{}', TRUE) AS returned \gset c_
INSERT INTO zz.cr_runs SELECT 'all-cash', id, :c_returned FROM public.procurements ORDER BY created_at DESC LIMIT 1;
DO $$
BEGIN
  PERFORM zz.check('all NHIS: one order, category nhis', (SELECT count(*) FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='all-nhis')) = 1
    AND (SELECT purchase_category FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='all-nhis')) = 'nhis');
  PERFORM zz.check('all cash: one order, category cash_private', (SELECT purchase_category FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='all-cash')) = 'cash_private');
END $$;

-- 4. Legacy callers (no flag, no categories) are unchanged: order stays unclassified, no error.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cr), (SELECT good FROM zz.cr), jsonb_build_array(
  jsonb_build_object('productId', (SELECT p_para FROM zz.cr), 'quantity', 1)
)) AS returned \gset l_
INSERT INTO zz.cr_runs SELECT 'legacy', id, :l_returned FROM public.procurements ORDER BY created_at DESC LIMIT 1;
DO $$
BEGIN
  PERFORM zz.check('legacy call: order created and left unclassified (never assumed cash)',
    (SELECT purchase_category FROM public.orders WHERE procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='legacy')) IS NULL);
END $$;

-- 5. Reclassifying a placed order: permissions.
CREATE TABLE zz.cr_t(k TEXT PRIMARY KEY, v TEXT);
GRANT ALL ON zz.cr_t TO PUBLIC;
INSERT INTO zz.cr_t SELECT 'item_vitc', oi.id::text FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='mixed') AND oi.product_name = 'CR Vitamin C';
INSERT INTO zz.cr_t SELECT 'item_legacy', oi.id::text FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id
  WHERE o.procurement_id = (SELECT procurement_id FROM zz.cr_runs WHERE label='legacy');

DO $$
DECLARE r TEXT; item UUID := (SELECT v::uuid FROM zz.cr_t WHERE k='item_vitc');
BEGIN
  r := zz.val_as((SELECT u_cashier FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('a cashier cannot change a classification', r LIKE 'ERR: Only the pharmacy owner, managers and accountants%', r);
  r := zz.val_as((SELECT u_px FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('another pharmacy cannot see or change it (not found)', r = 'ERR: Order item not found.', r);
  r := zz.val_as((SELECT u_wo FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('the supplying wholesaler cannot change it (not found)', r = 'ERR: Order item not found.', r);
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', '''')::text', item));
  PERFORM zz.check('a reason is required', r LIKE 'ERR: A reason of 5 to 500 characters is required%', r);
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''abc'')::text', item));
  PERFORM zz.check('a too-short reason is rejected', r LIKE 'ERR: A reason of 5 to 500 characters is required%', r);
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''retail'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('an unknown classification is rejected', r = 'ERR: Invalid purchase classification.', r);
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''cash_private'', ''No actual change here'')::text', item));
  PERFORM zz.check('setting the same value is rejected', r = 'ERR: This item is already classified that way.', r);
  r := zz.val_as(NULL, format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Claim approved by NHIA'')::text', item));
  PERFORM zz.check('no signed-in user is rejected', r LIKE 'ERR%', r);
  PERFORM zz.check('nothing changed after all the refusals',
    (SELECT purchase_category FROM public.order_items WHERE id = item) = 'cash_private'
    AND (SELECT count(*) FROM public.audit_logs WHERE activity = 'Order classification changed') = 0);
END $$;

-- 6. Reclassifying: success, re-derivation, audit.
DO $$
DECLARE r TEXT; item UUID := (SELECT v::uuid FROM zz.cr_t WHERE k='item_vitc');
  oid_ UUID := (SELECT order_id FROM public.order_items WHERE id = (SELECT v::uuid FROM zz.cr_t WHERE k='item_vitc'));
  pid UUID := (SELECT procurement_id FROM zz.cr_runs WHERE label='mixed'); a RECORD;
BEGIN
  r := zz.val_as((SELECT u_accountant FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Corrected after NHIA claim review'')::text', item));
  PERFORM zz.check('an accountant can change a classification', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the line changed and the order is now all NHIS (re-derived)',
    (SELECT purchase_category FROM public.order_items WHERE id = item) = 'nhis' AND (SELECT purchase_category FROM public.orders WHERE id = oid_) = 'nhis');
  PERFORM zz.check('the procurement category was re-derived too', (SELECT purchase_category FROM public.procurements WHERE id = pid) = 'nhis');
  PERFORM zz.check('it is still one order with unchanged totals', (SELECT count(*) FROM public.orders WHERE procurement_id = pid) = 1
    AND (SELECT total_ghs FROM public.orders WHERE id = oid_) = 1400);
  SELECT * INTO a FROM public.audit_logs WHERE activity = 'Order classification changed' AND record_id = oid_;
  PERFORM zz.check('audit: before/after, reason, role and actor are all recorded',
    a.details ->> 'from' = 'cash_private' AND a.details ->> 'to' = 'nhis' AND a.details ->> 'reason' = 'Corrected after NHIA claim review'
    AND a.details ->> 'actor_role' = 'accountant' AND a.details ->> 'order_category_from' = 'mixed' AND a.details ->> 'order_category_to' = 'nhis'
    AND a.performed_by = (SELECT u_accountant FROM zz.cr) AND a.business_id = (SELECT good FROM zz.cr), a.details::text);
  r := zz.val_as((SELECT u_manager FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''cash_private'', ''Reverted: item was cash'')::text', item));
  PERFORM zz.check('a manager can change it back; order is mixed again', r NOT LIKE 'ERR%'
    AND (SELECT purchase_category FROM public.orders WHERE id = oid_) = 'mixed', r);
  PERFORM zz.check('both changes are in the audit log (history kept)', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Order classification changed' AND record_id = oid_) = 2);
END $$;

-- 7. Legacy (unclassified) order can be classified by the owner; cancelled orders cannot be changed.
DO $$
DECLARE r TEXT; item UUID := (SELECT v::uuid FROM zz.cr_t WHERE k='item_legacy'); oid_ UUID := (SELECT order_id FROM public.order_items WHERE id = (SELECT v::uuid FROM zz.cr_t WHERE k='item_legacy'));
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''cash_private'', ''Confirmed cash purchase'')::text', item));
  PERFORM zz.check('the owner can classify a legacy (unclassified) order', r NOT LIKE 'ERR%' AND (SELECT purchase_category FROM public.orders WHERE id = oid_) = 'cash_private', r);
  UPDATE public.orders SET status = 'cancelled' WHERE id = oid_;
  r := zz.val_as((SELECT u_po FROM zz.cr), format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Trying after cancellation'')::text', item));
  PERFORM zz.check('a cancelled order cannot be reclassified', r = 'ERR: A cancelled order cannot be reclassified.', r);
END $$;

-- 8. Suspended / inactive staff cannot change classifications.
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '20000000-0000-0000-0000-0000000000c2';
DO $$
DECLARE r TEXT; item UUID := (SELECT v::uuid FROM zz.cr_t WHERE k='item_vitc');
BEGIN
  r := zz.val_as('20000000-0000-0000-0000-0000000000c2', format('SELECT public.change_order_item_classification(%L, ''nhis'', ''Inactive manager attempt'')::text', item));
  PERFORM zz.check('an inactive manager is treated as a non-member (not found)', r = 'ERR: Order item not found.', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
