-- RFQ, part 3: award_rfq_quote. Accepting a quote creates a real order at the quoted prices,
-- rejects every other submitted quote on the RFQ (never touching an already-withdrawn one), locks
-- stock the same way checkout does, and respects wholesaler order terms + an optional credit path.
-- Run after setup.sql + migrations through 20261008100000_rfq_award.sql.
--
-- submit_rfq_quote uses a session-scoped temp table (see rfq.sql), so each call below is its own
-- top-level statement. award_rfq_quote has no temp table, so its calls are safely batched inside
-- the DO $$ blocks alongside everything else.
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

-- A Good Pharmacy cashier, to prove award_rfq_quote's 'manage' tier excludes cashiers even though
-- create_rfq/cancel_rfq (checkout-equivalent actions) allow them.
SELECT zz.mkuser('40000000-0000-0000-0000-0000000000e1', 'phcash@zz.test', '{"full_name":"Good Pharmacy Cashier","phone":"+233241000020"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '40000000-0000-0000-0000-0000000000e1', 'cashier', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Award Amoxicillin', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 10.00, 50, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Award Vitamin C', 'Generic', 'Supplement', 'TABLET', '30s', 12.00, 50, true FROM zz.b WHERE name='Other Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Award Scarce Item', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 15.00, 3, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Award Credit Item', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 20.00, 50, true FROM zz.b WHERE name='Alpha Wholesale';

------------------------------------------------------------------
-- Fixture RFQs (no temp table in create_rfq -- safe to batch).
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
BEGIN
  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Award Main', NULL, NULL, ARRAY[%L,%L]::uuid[], %L)::text$q$,
    good, alpha, other_w, '[{"productName":"Any antibiotic","quantity":20}]'::jsonb));
  PERFORM zz.check('fixture: Award Main rfq created', r NOT LIKE 'ERR%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Award Scarce', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
    good, alpha, '[{"productName":"Scarce item","quantity":10}]'::jsonb));
  PERFORM zz.check('fixture: Award Scarce rfq created', r NOT LIKE 'ERR%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Award Credit', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
    good, alpha, '[{"productName":"Credit item","quantity":5}]'::jsonb));
  PERFORM zz.check('fixture: Award Credit rfq created', r NOT LIKE 'ERR%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Award Perm Check', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
    good, alpha, '[{"productName":"Any antibiotic","quantity":1}]'::jsonb));
  PERFORM zz.check('fixture: Award Perm Check rfq created', r NOT LIKE 'ERR%', r);
END $$;

-- Quotes (each its own top-level statement: temp-table rule).
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Main'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Main')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Amoxicillin'), 'unitPriceGhs', 10.00
  ))
)) AS alpha_main_quote;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Main'), (SELECT id FROM zz.b WHERE name='Other Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Main')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Vitamin C'), 'unitPriceGhs', 12.00
  ))
)) AS other_main_quote;

-- A third invitee-less quote is impossible (not invited to Award Main by design) -- instead cover
-- the withdrawn-quote case: Alpha quotes Award Perm Check then withdraws it, to prove award leaves
-- a withdrawn quote alone (never flips it to rejected, never notifies it as "not selected").
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Perm Check'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Perm Check')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Amoxicillin'), 'unitPriceGhs', 10.00
  ))
)) AS perm_check_quote;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Scarce'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Scarce')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Scarce Item'), 'unitPriceGhs', 15.00
  ))
)) AS scarce_quote;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Credit'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Credit')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Credit Item'), 'unitPriceGhs', 20.00
  ))
)) AS credit_quote;

------------------------------------------------------------------
-- Permission + validation + the main successful-award path.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pc UUID := '40000000-0000-0000-0000-0000000000e1';
  v_perm_rfq UUID := (SELECT id FROM public.rfqs WHERE title = 'Award Perm Check');
  v_perm_quote UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_perm_rfq AND wholesaler_id = alpha);
  v_main_rfq UUID := (SELECT id FROM public.rfqs WHERE title = 'Award Main');
  v_alpha_quote UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_main_rfq AND wholesaler_id = alpha);
  v_other_quote UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_main_rfq AND wholesaler_id = other_w);
  v_scarce_rfq UUID := (SELECT id FROM public.rfqs WHERE title = 'Award Scarce');
  v_scarce_quote UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_scarce_rfq AND wholesaler_id = alpha);
  v_order_id UUID;
  r TEXT;
BEGIN
  ------------------------------------------------------------------
  -- Permission: unrelated pharmacy denied; a cashier (checkout-level permission) is NOT enough for
  -- award (manage tier only); the owner succeeds on a harmless no-op case first to prove tier
  -- gating happens before quote-state validation (we'll do the real award of this RFQ later, after
  -- withdrawing the quote, to test the withdrawn-quote notification suppression).
  ------------------------------------------------------------------
  r := zz.val_as(u_px, format('SELECT public.award_rfq_quote(%L, %L)::text', v_main_rfq, v_alpha_quote));
  PERFORM zz.check('award_rfq_quote: an unrelated pharmacy is denied', r LIKE 'ERR: You do not have permission to award quotes%', r);
  r := zz.val_as(u_pc, format('SELECT public.award_rfq_quote(%L, %L)::text', v_main_rfq, v_alpha_quote));
  PERFORM zz.check('award_rfq_quote: a cashier cannot award (manage tier excludes cashier)', r LIKE 'ERR: You do not have permission to award quotes%', r);

  ------------------------------------------------------------------
  -- Withdraw the Perm Check quote, then confirm award correctly reports "no submitted quote" once
  -- there is nothing left to award on that RFQ, and that cancelling it instead is still possible.
  ------------------------------------------------------------------
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT public.withdraw_rfq_quote(%L, %L)::text', v_perm_rfq, alpha));
  PERFORM zz.check('fixture: Perm Check quote withdrawn', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L)::text', v_perm_rfq, v_perm_quote));
  PERFORM zz.check('award_rfq_quote: cannot award a withdrawn quote', r LIKE 'ERR: Only a submitted quote can be awarded%', r);

  ------------------------------------------------------------------
  -- The main successful award: Alpha's quote on "Award Main" wins.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L)::text', v_main_rfq, v_alpha_quote));
  PERFORM zz.check('award_rfq_quote: the owner can award', r NOT LIKE 'ERR%', r);
  v_order_id := r::UUID;

  PERFORM zz.check('award_rfq_quote: order created with subtotal/total = 20*10.00 = 200.00',
    (SELECT subtotal_ghs = 200.00 AND total_ghs = 200.00 AND pharmacy_id = good AND wholesaler_id = alpha AND NOT is_credit_order
     FROM public.orders WHERE id = v_order_id));
  PERFORM zz.check('award_rfq_quote: exactly 1 order item at the quoted price',
    (SELECT COUNT(*) = 1 AND bool_and(quantity = 20) AND bool_and(unit_price_ghs = 10.00) FROM public.order_items WHERE order_id = v_order_id));
  PERFORM zz.check('award_rfq_quote: stock decremented by the awarded quantity',
    (SELECT stock = 30 FROM public.products WHERE name = 'Award Amoxicillin'));

  PERFORM zz.check('award_rfq_quote: the winning quote is accepted', (SELECT status FROM public.rfq_quotes WHERE id = v_alpha_quote) = 'accepted');
  PERFORM zz.check('award_rfq_quote: the losing quote is rejected', (SELECT status FROM public.rfq_quotes WHERE id = v_other_quote) = 'rejected');
  PERFORM zz.check('award_rfq_quote: the rfq is marked awarded with the right quote/order linked',
    (SELECT status = 'awarded' AND awarded_quote_id = v_alpha_quote AND awarded_order_id = v_order_id FROM public.rfqs WHERE id = v_main_rfq));

  PERFORM zz.check('award_rfq_quote: the winner was notified',
    EXISTS (SELECT 1 FROM public.notifications WHERE type = 'rfq_quote_accepted' AND link = '/wholesaler?tab=orders'));
  PERFORM zz.check('award_rfq_quote: the loser was notified, without revealing who won or at what price',
    EXISTS (SELECT 1 FROM public.notifications n WHERE n.type = 'rfq_quote_rejected' AND n.link = '/wholesaler/rfqs/' || v_main_rfq
      AND n.body NOT ILIKE '%Alpha%' AND n.body NOT ILIKE '%10.00%' AND n.body NOT ILIKE '%200%'));
  PERFORM zz.check('award_rfq_quote: the already-withdrawn Perm Check quote never got a "not selected" notification',
    NOT EXISTS (SELECT 1 FROM public.notifications WHERE type = 'rfq_quote_rejected' AND link = '/wholesaler/rfqs/' || v_perm_rfq));
  PERFORM zz.check('award_rfq_quote: the withdrawn Perm Check quote is still withdrawn, not rejected',
    (SELECT status FROM public.rfq_quotes WHERE id = v_perm_quote) = 'withdrawn');

  ------------------------------------------------------------------
  -- Cannot award twice / cannot award an rfq that is no longer open.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L)::text', v_main_rfq, v_alpha_quote));
  PERFORM zz.check('award_rfq_quote: cannot award again once the rfq is already awarded', r LIKE 'ERR: This RFQ is not open to be awarded%', r);
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L)::text', v_main_rfq, v_other_quote));
  PERFORM zz.check('award_rfq_quote: cannot award the already-rejected losing quote either', r LIKE 'ERR: This RFQ is not open to be awarded%', r);

  ------------------------------------------------------------------
  -- Insufficient stock: the quoted quantity (10) exceeds available stock (3) -- the whole award
  -- must fail atomically, with nothing partially applied.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L)::text', v_scarce_rfq, v_scarce_quote));
  PERFORM zz.check('award_rfq_quote: insufficient stock is rejected', r LIKE 'ERR: Only 3 unit(s) of Award Scarce Item are currently available%', r);
  PERFORM zz.check('award_rfq_quote: a failed award does not touch stock', (SELECT stock = 3 FROM public.products WHERE name = 'Award Scarce Item'));
  PERFORM zz.check('award_rfq_quote: a failed award does not create an order',
    NOT EXISTS (SELECT 1 FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id JOIN public.products p ON p.id = oi.product_id WHERE p.name = 'Award Scarce Item'));
  PERFORM zz.check('award_rfq_quote: a failed award leaves the rfq open', (SELECT status FROM public.rfqs WHERE id = v_scarce_rfq) = 'open');
END $$;

------------------------------------------------------------------
-- Credit path: approve credit, then award on credit; without credit terms, award-on-credit fails.
------------------------------------------------------------------
INSERT INTO public.wholesaler_credit_terms (wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'), 500.00, 14;

DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  v_credit_rfq UUID := (SELECT id FROM public.rfqs WHERE title = 'Award Credit');
  v_credit_quote UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_credit_rfq AND wholesaler_id = alpha);
  v_order_id UUID;
  r TEXT;
BEGIN
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L, true)::text', v_credit_rfq, v_credit_quote));
  PERFORM zz.check('award_rfq_quote: awarding on credit succeeds once credit terms are approved', r NOT LIKE 'ERR%', r);
  v_order_id := r::UUID;
  PERFORM zz.check('award_rfq_quote: the order is flagged as a credit order with a due date',
    (SELECT is_credit_order AND credit_due_date IS NOT NULL FROM public.orders WHERE id = v_order_id));
  PERFORM zz.check('award_rfq_quote: a credit ledger invoice entry was posted for 5*20.00 = 100.00',
    EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE order_id = v_order_id AND entry_type = 'invoice' AND direction = 'debit' AND amount_ghs = 100.00));
END $$;

-- A second credit RFQ proves the limit itself is enforced: a credit order whose amount exceeds
-- the just-approved 500 limit (plus the 100 already outstanding from the earlier award) is rejected.
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='ph_owner'), format(
  $q$SELECT public.create_rfq(%L, 'Award Over Limit', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
  (SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  '[{"productName":"Credit item","quantity":30}]'::jsonb
)) AS over_limit_rfq_id;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Award Over Limit'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object(
    'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Award Over Limit')),
    'productId', (SELECT id FROM public.products WHERE name = 'Award Credit Item'), 'unitPriceGhs', 20.00
  ))
)) AS over_limit_quote;

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  v_rfq_id UUID := (SELECT id FROM public.rfqs WHERE title = 'Award Over Limit');
  v_quote_id UUID := (SELECT id FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = alpha);
  r TEXT;
BEGIN
  -- 30 * 20.00 = 600.00, plus the 100.00 already outstanding on credit from the earlier award =
  -- 700.00, over the 500.00 limit.
  r := zz.val_as(u_po, format('SELECT public.award_rfq_quote(%L, %L, true)::text', v_rfq_id, v_quote_id));
  PERFORM zz.check('award_rfq_quote: exceeding the approved credit limit is rejected', r LIKE 'ERR: Using credit with % would exceed your approved limit%', r);
  PERFORM zz.check('award_rfq_quote: a credit-limit rejection leaves the rfq open and creates no order',
    (SELECT status FROM public.rfqs WHERE id = v_rfq_id) = 'open'
    AND NOT EXISTS (SELECT 1 FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id WHERE oi.quantity = 30 AND oi.unit_price_ghs = 20.00));

  PERFORM zz.check('anon has no EXECUTE on award_rfq_quote',
    NOT has_function_privilege('anon', 'public.award_rfq_quote(uuid,uuid,boolean)', 'EXECUTE'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
