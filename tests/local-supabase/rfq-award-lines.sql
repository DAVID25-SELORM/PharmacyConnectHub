-- RFQ phase 5: quote terms (delivery charge, lead time, payment terms, per-line available quantity
-- and discount) and award_rfq_lines (line-level / split awards -> one order per supplier).
-- Run after setup.sql + migrations through 20261013110000_rfq_quote_terms_logic.sql.
--
-- submit_rfq_quote uses a session-scoped temp table (ON COMMIT DROP), so every SUCCESSFUL call is
-- its own top-level statement; failing calls (which roll back their own temp table) are batched
-- inside DO blocks. award_rfq_lines has no temp table and is safe to batch.
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

SELECT zz.mkuser('40000000-0000-0000-0000-0000000000d1', 'phcash2@zz.test', '{"full_name":"Good Pharmacy Cashier","phone":"+233241000050"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '40000000-0000-0000-0000-0000000000d1', 'cashier', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Split Para A', 'Generic', 'Analgesic', 'TABLET', '20s', 5.00, 100, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Split Amox A', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 10.00, 100, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Split Para O', 'Generic', 'Analgesic', 'TABLET', '20s', 4.80, 100, true FROM zz.b WHERE name='Other Wholesale';

DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
BEGIN
  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Split Main', NULL, NULL, ARRAY[%L,%L]::uuid[], %L)::text$q$,
    good, alpha, other_w, '[{"productName":"Paracetamol","quantity":100},{"productName":"Amoxicillin","quantity":20}]'::jsonb));
  PERFORM zz.check('fixture: Split Main rfq created', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Split Partial', NULL, NULL, ARRAY[%L,%L]::uuid[], %L)::text$q$,
    good, alpha, other_w, '[{"productName":"Paracetamol","quantity":10}]'::jsonb));
  PERFORM zz.check('fixture: Split Partial rfq created', r NOT LIKE 'ERR%', r);
END $$;

------------------------------------------------------------------
-- Validation of the new quote terms (all failing -> safe to batch).
------------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  v_rfq UUID := (SELECT id FROM public.rfqs WHERE title='Split Main');
  v_para_item UUID := (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title='Split Main') AND product_name='Paracetamol');
  v_prod UUID := (SELECT id FROM public.products WHERE name='Split Para A');
  r TEXT;
BEGIN
  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$, v_rfq, alpha,
    jsonb_build_array(jsonb_build_object('rfqItemId', v_para_item, 'productId', v_prod, 'unitPriceGhs', 5.00, 'quantity', 101))));
  PERFORM zz.check('quote: a quantity above what was requested is rejected', r LIKE 'ERR: A quoted quantity must be between 1 and the quantity requested%', r);

  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$, v_rfq, alpha,
    jsonb_build_array(jsonb_build_object('rfqItemId', v_para_item, 'productId', v_prod, 'unitPriceGhs', 5.00, 'quantity', 0))));
  PERFORM zz.check('quote: a zero quantity is rejected', r LIKE 'ERR: A quoted quantity must be between 1 and the quantity requested%', r);

  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$, v_rfq, alpha,
    jsonb_build_array(jsonb_build_object('rfqItemId', v_para_item, 'productId', v_prod, 'unitPriceGhs', 5.00, 'discountPercent', 100))));
  PERFORM zz.check('quote: a 100% discount is rejected', r LIKE 'ERR: A discount must be at least 0% and less than 100%%', r);

  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, %L, NULL, NULL, -1)::text$q$, v_rfq, alpha,
    jsonb_build_array(jsonb_build_object('rfqItemId', v_para_item, 'productId', v_prod, 'unitPriceGhs', 5.00))));
  PERFORM zz.check('quote: a negative delivery charge is rejected', r LIKE 'ERR: The delivery charge cannot be negative%', r);

  r := zz.val_as(u_wo, format($q$SELECT public.submit_rfq_quote(%L, %L, %L, NULL, NULL, 0, -2)::text$q$, v_rfq, alpha,
    jsonb_build_array(jsonb_build_object('rfqItemId', v_para_item, 'productId', v_prod, 'unitPriceGhs', 5.00))));
  PERFORM zz.check('quote: a negative lead time is rejected', r LIKE 'ERR: The lead time cannot be negative%', r);

  PERFORM zz.check('quote: none of the rejected attempts left a quote row behind',
    (SELECT COUNT(*) = 0 FROM public.rfq_quotes WHERE rfq_id = v_rfq));
END $$;

------------------------------------------------------------------
-- Real quotes. Alpha offers only 60 of 100 Paracetamol at 10% off, all 20 Amoxicillin, with a
-- delivery charge, lead time and payment terms. Other quotes all 100 Paracetamol.
------------------------------------------------------------------
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L, 'Delivered Mon-Fri', NULL, 15, 3, 'Net 14')::text$q$,
  (SELECT id FROM public.rfqs WHERE title='Split Main'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(
    jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name='Paracetamol' AND rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Main')),
      'productId', (SELECT id FROM public.products WHERE name='Split Para A'), 'unitPriceGhs', 5.00, 'quantity', 60, 'discountPercent', 10),
    jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name='Amoxicillin' AND rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Main')),
      'productId', (SELECT id FROM public.products WHERE name='Split Amox A'), 'unitPriceGhs', 10.00)
  ))) AS alpha_split_quote;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title='Split Main'), (SELECT id FROM zz.b WHERE name='Other Wholesale'),
  jsonb_build_array(
    jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name='Paracetamol' AND rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Main')),
      'productId', (SELECT id FROM public.products WHERE name='Split Para O'), 'unitPriceGhs', 4.80)
  ))) AS other_split_quote;

-- A re-submission with the same content, to prove it is audited as a revision.
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L, 'Delivered Mon-Fri', NULL, 15, 3, 'Net 14')::text$q$,
  (SELECT id FROM public.rfqs WHERE title='Split Main'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(
    jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name='Paracetamol' AND rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Main')),
      'productId', (SELECT id FROM public.products WHERE name='Split Para A'), 'unitPriceGhs', 5.00, 'quantity', 60, 'discountPercent', 10),
    jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name='Amoxicillin' AND rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Main')),
      'productId', (SELECT id FROM public.products WHERE name='Split Amox A'), 'unitPriceGhs', 10.00)
  ))) AS alpha_split_revision;

-- Split Partial: both quote 10 Paracetamol.
SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title='Split Partial'), (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Partial')),
    'productId', (SELECT id FROM public.products WHERE name='Split Para A'), 'unitPriceGhs', 5.00))
)) AS alpha_partial_quote;

SELECT zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format(
  $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title='Split Partial'), (SELECT id FROM zz.b WHERE name='Other Wholesale'),
  jsonb_build_array(jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id=(SELECT id FROM public.rfqs WHERE title='Split Partial')),
    'productId', (SELECT id FROM public.products WHERE name='Split Para O'), 'unitPriceGhs', 4.80))
)) AS other_partial_quote;

DO $$
DECLARE
  v_rfq UUID := (SELECT id FROM public.rfqs WHERE title='Split Main');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
BEGIN
  PERFORM zz.check('quote: the line stores a discount, the final unit price and the reduced quantity',
    (SELECT qi.quantity = 60 AND qi.unit_price_ghs = 5.00 AND qi.discount_percent = 10 AND qi.final_unit_price_ghs = 4.50 AND qi.line_total_ghs = 270.00
     FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id = qi.rfq_item_id
     WHERE q.rfq_id = v_rfq AND q.wholesaler_id = alpha AND ri.product_name = 'Paracetamol'));
  PERFORM zz.check('quote: a line with no quantity defaults to the full requested quantity',
    (SELECT qi.quantity = 20 AND qi.final_unit_price_ghs = 10.00
     FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id = qi.rfq_item_id
     WHERE q.rfq_id = v_rfq AND q.wholesaler_id = alpha AND ri.product_name = 'Amoxicillin'));
  PERFORM zz.check('quote: delivery charge, lead time and payment terms are stored',
    (SELECT delivery_charge_ghs = 15 AND lead_time_days = 3 AND payment_terms = 'Net 14' FROM public.rfq_quotes WHERE rfq_id = v_rfq AND wholesaler_id = alpha));
  PERFORM zz.check('quote: total_ghs is the goods total (270 + 200), excluding the delivery charge',
    (SELECT total_ghs = 470.00 FROM public.rfq_quotes WHERE rfq_id = v_rfq AND wholesaler_id = alpha));
  PERFORM zz.check('audit: a first submission is "RFQ quote submitted"',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ quote submitted' AND business_id = alpha));
  PERFORM zz.check('audit: a re-submission is "RFQ quote revised", not a second "submitted"',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ quote revised' AND business_id = alpha)
    AND (SELECT COUNT(*) FROM public.audit_logs WHERE activity = 'RFQ quote submitted' AND business_id = alpha AND details->>'rfq_id' = v_rfq::text) = 1);
END $$;

------------------------------------------------------------------
-- award_rfq_lines: permissions and validation (every failure must leave stock, orders and the RFQ
-- untouched).
------------------------------------------------------------------
DO $$
DECLARE
  v_rfq UUID := (SELECT id FROM public.rfqs WHERE title='Split Main');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_cash UUID := '40000000-0000-0000-0000-0000000000d1';
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  v_a_para UUID; v_a_amox UUID; v_o_para UUID;
  r TEXT;
BEGIN
  SELECT qi.id INTO v_a_para FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id=qi.rfq_item_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=alpha AND ri.product_name='Paracetamol';
  SELECT qi.id INTO v_a_amox FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id=qi.rfq_item_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=alpha AND ri.product_name='Amoxicillin';
  SELECT qi.id INTO v_o_para FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=other_w;

  r := zz.val_as(u_px, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', v_a_para, 'quantity', 10))));
  PERFORM zz.check('award_lines: an unrelated pharmacy is denied', r LIKE 'ERR: You do not have permission to award quotes%', r);
  r := zz.val_as(u_cash, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', v_a_para, 'quantity', 10))));
  PERFORM zz.check('award_lines: a cashier cannot award (manage tier)', r LIKE 'ERR: You do not have permission to award quotes%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, '[]'::jsonb)::text$q$, v_rfq));
  PERFORM zz.check('award_lines: an empty selection is rejected', r LIKE 'ERR: Choose at least one line%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', v_a_para, 'quantity', 61))));
  PERFORM zz.check('award_lines: awarding more than the supplier offered on a line is rejected', r LIKE 'ERR: You cannot award more than the 60 unit(s)%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(
    jsonb_build_object('quoteItemId', v_a_para, 'quantity', 60), jsonb_build_object('quoteItemId', v_o_para, 'quantity', 41))));
  PERFORM zz.check('award_lines: splitting a line so the total exceeds the quantity requested is rejected', r LIKE 'ERR: The awarded quantities for an item add up to more than was requested%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(
    jsonb_build_object('quoteItemId', v_a_para, 'quantity', 10), jsonb_build_object('quoteItemId', v_a_para, 'quantity', 10))));
  PERFORM zz.check('award_lines: the same quote line twice is rejected', r LIKE 'ERR: Each quote line can only be awarded once%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', gen_random_uuid(), 'quantity', 1))));
  PERFORM zz.check('award_lines: a line that does not exist is rejected', r LIKE 'ERR: A selected quote line does not belong to this RFQ%', r);
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, (SELECT id FROM public.rfqs WHERE title='Split Partial'),
    jsonb_build_array(jsonb_build_object('quoteItemId', v_a_para, 'quantity', 5))));
  PERFORM zz.check('award_lines: a line from a different RFQ is rejected', r LIKE 'ERR: A selected quote line does not belong to this RFQ%', r);

  PERFORM zz.check('award_lines: none of the rejected attempts changed stock, created an order, or closed the RFQ',
    (SELECT stock = 100 FROM public.products WHERE name='Split Para A')
    AND (SELECT stock = 100 FROM public.products WHERE name='Split Para O')
    AND NOT EXISTS (SELECT 1 FROM public.orders WHERE notes = 'Created from RFQ Split Main')
    AND (SELECT status = 'open' FROM public.rfqs WHERE id = v_rfq));
END $$;

------------------------------------------------------------------
-- The split award itself: Paracetamol 60 -> Alpha, 40 -> Other; Amoxicillin 20 -> Alpha.
-- Alpha order: 60*4.50 + 20*10.00 = 470.00 + 15.00 delivery = 485.00. Other order: 40*4.80 = 192.00.
------------------------------------------------------------------
DO $$
DECLARE
  v_rfq UUID := (SELECT id FROM public.rfqs WHERE title='Split Main');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  v_a_para UUID; v_a_amox UUID; v_o_para UUID;
  r TEXT;
BEGIN
  SELECT qi.id INTO v_a_para FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id=qi.rfq_item_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=alpha AND ri.product_name='Paracetamol';
  SELECT qi.id INTO v_a_amox FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id JOIN public.rfq_items ri ON ri.id=qi.rfq_item_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=alpha AND ri.product_name='Amoxicillin';
  SELECT qi.id INTO v_o_para FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id
    WHERE q.rfq_id=v_rfq AND q.wholesaler_id=other_w;

  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(
    jsonb_build_object('quoteItemId', v_a_para, 'quantity', 60),
    jsonb_build_object('quoteItemId', v_a_amox, 'quantity', 20),
    jsonb_build_object('quoteItemId', v_o_para, 'quantity', 40))));
  PERFORM zz.check('award_lines: a split award across two suppliers succeeds', r NOT LIKE 'ERR%', r);

  PERFORM zz.check('award_lines: exactly one order per supplier was created',
    (SELECT COUNT(*) = 2 FROM public.orders WHERE notes = 'Created from RFQ Split Main'));
  PERFORM zz.check('award_lines: Alpha order = 470.00 goods + 15.00 quoted delivery charge = 485.00',
    (SELECT subtotal_ghs = 470.00 AND delivery_fee_ghs = 15.00 AND total_ghs = 485.00 FROM public.orders
     WHERE notes = 'Created from RFQ Split Main' AND wholesaler_id = alpha));
  PERFORM zz.check('award_lines: Other order = 40 x 4.80 = 192.00, no delivery charge',
    (SELECT subtotal_ghs = 192.00 AND delivery_fee_ghs = 0 AND total_ghs = 192.00 FROM public.orders
     WHERE notes = 'Created from RFQ Split Main' AND wholesaler_id = other_w));
  PERFORM zz.check('award_lines: Alpha order items carry the awarded quantities at the FINAL (discounted) price',
    (SELECT COUNT(*) = 2 AND SUM(oi.quantity) = 80 AND bool_and(oi.unit_price_ghs = oi.base_unit_price_ghs)
       AND (SELECT oi2.unit_price_ghs FROM public.order_items oi2 WHERE oi2.order_id = o.id AND oi2.product_name = 'Split Para A') = 4.50
     FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
     WHERE o.notes = 'Created from RFQ Split Main' AND o.wholesaler_id = alpha GROUP BY o.id));
  PERFORM zz.check('award_lines: stock was decremented by the awarded quantities only (60, 20 and 40)',
    (SELECT stock = 40 FROM public.products WHERE name = 'Split Para A')
    AND (SELECT stock = 80 FROM public.products WHERE name = 'Split Amox A')
    AND (SELECT stock = 60 FROM public.products WHERE name = 'Split Para O'));
  PERFORM zz.check('award_lines: three rfq_awards rows were recorded',
    (SELECT COUNT(*) = 3 FROM public.rfq_awards WHERE rfq_id = v_rfq));
  PERFORM zz.check('award_lines: the RFQ is awarded; with two winners the singular legacy columns stay NULL',
    (SELECT status = 'awarded' AND awarded_quote_id IS NULL AND awarded_order_id IS NULL FROM public.rfqs WHERE id = v_rfq));
  PERFORM zz.check('award_lines: both quotes are accepted',
    (SELECT COUNT(*) = 2 FROM public.rfq_quotes WHERE rfq_id = v_rfq AND status = 'accepted'));
  PERFORM zz.check('award_lines: the split is audited, with supplier and line counts',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'RFQ awarded' AND record_id = v_rfq
      AND (details->>'split')::boolean AND (details->>'supplier_count')::int = 2 AND (details->>'line_count')::int = 3));

  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', v_a_para, 'quantity', 1))));
  PERFORM zz.check('award_lines: an RFQ that is already awarded cannot be awarded again', r LIKE 'ERR: This RFQ is not open to be awarded%', r);

  ------------------------------------------------------------------
  -- Confidentiality of the outcome (RLS, not UI): each supplier sees only its own award rows.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.rfq_awards WHERE rfq_id = %L', v_rfq));
  PERFORM zz.check('rls: the pharmacy sees every award row', r = '3', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT count(*)::text FROM public.rfq_awards WHERE rfq_id = %L', v_rfq));
  PERFORM zz.check('rls: Alpha sees only its own 2 award rows', r = '2', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_other'), format('SELECT count(*)::text FROM public.rfq_awards WHERE rfq_id = %L', v_rfq));
  PERFORM zz.check('rls: Other sees only its own 1 award row', r = '1', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='ph_other'), format('SELECT count(*)::text FROM public.rfq_awards WHERE rfq_id = %L', v_rfq));
  PERFORM zz.check('rls: an unrelated pharmacy sees none', r = '0', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT count(*)::text FROM public.rfq_awards WHERE wholesaler_id = %L', other_w));
  PERFORM zz.check('rls: Alpha cannot read Other''s award rows even by filtering for them', r = '0', r);
END $$;

------------------------------------------------------------------
-- Partial award: award only Alpha's line on Split Partial; Other's quote must be rejected (and
-- notified without revealing the winner), and the singular legacy columns point at the one winner.
------------------------------------------------------------------
DO $$
DECLARE
  v_rfq UUID := (SELECT id FROM public.rfqs WHERE title='Split Partial');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  v_line UUID;
  r TEXT;
BEGIN
  SELECT qi.id INTO v_line FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id=qi.rfq_quote_id WHERE q.rfq_id=v_rfq AND q.wholesaler_id=alpha;
  r := zz.val_as(u_po, format($q$SELECT public.award_rfq_lines(%L, %L)::text$q$, v_rfq, jsonb_build_array(jsonb_build_object('quoteItemId', v_line, 'quantity', 4))));
  PERFORM zz.check('award_lines: a partial-quantity award to one supplier succeeds', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('award_lines: a quantity below what was requested is allowed (4 of 10)',
    (SELECT quantity = 4 FROM public.rfq_awards WHERE rfq_id = v_rfq));
  PERFORM zz.check('award_lines: the quote that won nothing is rejected',
    (SELECT status = 'rejected' FROM public.rfq_quotes WHERE rfq_id = v_rfq AND wholesaler_id = other_w));
  PERFORM zz.check('award_lines: a single winner fills the legacy awarded_quote_id / awarded_order_id',
    (SELECT awarded_quote_id IS NOT NULL AND awarded_order_id IS NOT NULL FROM public.rfqs WHERE id = v_rfq));
  PERFORM zz.check('award_lines: the loser is told only that it was not selected',
    EXISTS (SELECT 1 FROM public.notifications n WHERE n.type = 'rfq_quote_rejected' AND n.link = '/wholesaler/rfqs/' || v_rfq
      AND n.body NOT ILIKE '%Alpha%' AND n.body NOT ILIKE '%4.80%' AND n.body NOT ILIKE '%5.00%'));
END $$;

DO $$
BEGIN
  PERFORM zz.check('anon has no EXECUTE on award_rfq_lines or the new submit_rfq_quote',
    NOT has_function_privilege('anon', 'public.award_rfq_lines(uuid,jsonb,boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.submit_rfq_quote(uuid,uuid,jsonb,text,timestamptz,numeric,integer,text)', 'EXECUTE'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
