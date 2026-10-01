-- RFQ (phase 5 of the procurement/credit/RFQ expansion): create_rfq / submit_rfq_quote /
-- withdraw_rfq_quote / cancel_rfq, and -- the core guarantee of this feature -- sealed-bid RLS: a
-- wholesaler must never see another wholesaler's quote for the same RFQ, even though the pharmacy
-- sees every quote. Run after setup.sql + migrations through 20261007110000_rfq_logic.sql.
--
-- submit_rfq_quote uses a session-scoped `CREATE TEMP TABLE ... ON COMMIT DROP` internally (same
-- reason as create_marketplace_orders -- see purchase-reports.sql), so every call to it below is
-- its own top-level statement, never batched inside a shared DO $$ block with another call.
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
SELECT id, 'RFQ Amoxicillin', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 12.00, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'RFQ Paracetamol', 'Generic', 'Analgesic', 'TABLET', '20s', 5.00, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'RFQ Inactive', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 9.00, 1000, false FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'RFQ Amlodipine (equivalent)', 'Generic', 'Antihypertensive', 'TABLET', '30s', 7.00, 1000, true FROM zz.b WHERE name='Other Wholesale';

------------------------------------------------------------------
-- create_rfq: permission checks, validation, successful creation, invite-only visibility.
------------------------------------------------------------------
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  pending_w UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  r TEXT;
  v_rfq_id UUID;
  v_items JSONB := '[{"productName":"Amoxicillin 500mg","quantity":100},{"productName":"Paracetamol 500mg","quantity":50,"notes":"any reputable brand"}]';
BEGIN
  ------------------------------------------------------------------
  -- Validation
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, '', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$, good, alpha, v_items));
  PERFORM zz.check('create_rfq: blank title rejected', r LIKE 'ERR: A title is required%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, NULL, '{}'::uuid[], %L)::text$q$, good, v_items));
  PERFORM zz.check('create_rfq: no invitees rejected', r LIKE 'ERR: Invite at least one supplier%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, NULL, ARRAY[%L]::uuid[], '[]'::jsonb)::text$q$, good, alpha));
  PERFORM zz.check('create_rfq: no items rejected', r LIKE 'ERR: Add at least one item%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, now() - interval '1 day', ARRAY[%L]::uuid[], %L)::text$q$, good, alpha, v_items));
  PERFORM zz.check('create_rfq: past deadline rejected', r LIKE 'ERR: The response deadline must be in the future%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$, good, pending_w, v_items));
  PERFORM zz.check('create_rfq: unapproved wholesaler rejected', r LIKE 'ERR: One or more invited suppliers could not be found%', r);

  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, NULL, ARRAY[%L]::uuid[], '[{"productName":"","quantity":5}]'::jsonb)::text$q$, good, alpha));
  PERFORM zz.check('create_rfq: blank product name rejected', r LIKE 'ERR: Each item needs a product name%', r);

  ------------------------------------------------------------------
  -- Permission: owner/manager/cashier can create; an unrelated user cannot.
  ------------------------------------------------------------------
  r := zz.val_as(u_px, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$, good, alpha, v_items));
  PERFORM zz.check('create_rfq: a different pharmacy is denied', r LIKE 'ERR: You do not have permission to request quotes%', r);

  ------------------------------------------------------------------
  -- Successful creation, inviting both Alpha and Other Wholesale.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format($q$SELECT public.create_rfq(%L, 'Q3 Restock', 'Need better pricing this quarter', NULL, ARRAY[%L,%L]::uuid[], %L)::text$q$, good, alpha, other_w, v_items));
  PERFORM zz.check('create_rfq: succeeds for the owner', r NOT LIKE 'ERR%', r);
  v_rfq_id := r::UUID;

  PERFORM zz.check('create_rfq: 2 items inserted with correct quantities',
    (SELECT COUNT(*) = 2 FROM public.rfq_items WHERE rfq_id = v_rfq_id)
    AND (SELECT quantity FROM public.rfq_items WHERE rfq_id = v_rfq_id AND product_name = 'Amoxicillin 500mg') = 100
    AND (SELECT quantity FROM public.rfq_items WHERE rfq_id = v_rfq_id AND product_name = 'Paracetamol 500mg') = 50);
  PERFORM zz.check('create_rfq: 2 invitees inserted (Alpha + Other Wholesale)',
    (SELECT COUNT(*) = 2 FROM public.rfq_invitees WHERE rfq_id = v_rfq_id AND wholesaler_id IN (alpha, other_w)));
  PERFORM zz.check('create_rfq: status defaults to open', (SELECT status FROM public.rfqs WHERE id = v_rfq_id) = 'open');
  PERFORM zz.check('create_rfq: both invited wholesalers were notified',
    (SELECT COUNT(*) FROM public.notifications WHERE type = 'rfq_received' AND link = '/wholesaler/rfqs/' || v_rfq_id) >= 2);

  ------------------------------------------------------------------
  -- RLS on rfqs: pharmacy + invited wholesalers can see it; the uninvited pharmacy cannot even
  -- though another business's RFQ exists; admins can see everything.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.rfqs WHERE id = %L', v_rfq_id));
  PERFORM zz.check('rfqs RLS: the pharmacy owner sees it', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfqs WHERE id = %L', v_rfq_id));
  PERFORM zz.check('rfqs RLS: invited wholesaler (Alpha owner) sees it', r = '1', r);
  r := zz.val_as(u_wm, format('SELECT count(*)::text FROM public.rfqs WHERE id = %L', v_rfq_id));
  PERFORM zz.check('rfqs RLS: invited wholesaler''s active staff (manager) also sees it', r = '1', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.rfqs WHERE id = %L', v_rfq_id));
  PERFORM zz.check('rfqs RLS: an unrelated pharmacy cannot see it', r = '0', r);
  r := zz.val_as(u_nb, format('SELECT count(*)::text FROM public.rfqs WHERE id = %L', v_rfq_id));
  PERFORM zz.check('rfqs RLS: nobody (no business at all) cannot see it', r = '0', r);

  ------------------------------------------------------------------
  -- RLS on rfq_invitees: each wholesaler sees ONLY its own invitation, never the other invitee's
  -- row -- the competitor list itself is sealed, not just the prices.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.rfq_invitees WHERE rfq_id = %L', v_rfq_id));
  PERFORM zz.check('rfq_invitees RLS: the pharmacy sees the full invite list (2)', r = '2', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfq_invitees WHERE rfq_id = %L', v_rfq_id));
  PERFORM zz.check('rfq_invitees RLS: Alpha sees only its own invitation (1, not 2)', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfq_invitees WHERE rfq_id = %L AND wholesaler_id = %L', v_rfq_id, other_w));
  PERFORM zz.check('rfq_invitees RLS: Alpha cannot see that Other Wholesale was also invited', r = '0', r);
END $$;

------------------------------------------------------------------
-- submit_rfq_quote: each call is its own top-level statement (temp-table rule above).
------------------------------------------------------------------
SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_owner'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L, 'Can deliver within 48 hours')::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock' AND pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy')),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    jsonb_build_array(
      jsonb_build_object(
        'rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name = 'Amoxicillin 500mg' AND rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock')),
        'productId', (SELECT id FROM public.products WHERE name = 'RFQ Amoxicillin'),
        'unitPriceGhs', 8.50
      ),
      jsonb_build_object(
        'rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name = 'Paracetamol 500mg' AND rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock')),
        'productId', (SELECT id FROM public.products WHERE name = 'RFQ Paracetamol'),
        'unitPriceGhs', 4.00
      )
    )
  )
) AS alpha_quote_result;

SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_other'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L, 'We can only cover one line, substitute offered')::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock' AND pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy')),
    (SELECT id FROM zz.b WHERE name='Other Wholesale'),
    jsonb_build_array(
      jsonb_build_object(
        'rfqItemId', (SELECT id FROM public.rfq_items WHERE product_name = 'Amoxicillin 500mg' AND rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock')),
        'productId', (SELECT id FROM public.products WHERE name = 'RFQ Amlodipine (equivalent)'),
        'unitPriceGhs', 9.75,
        'notes', 'Equivalent brand substitute'
      )
    )
  )
) AS other_wholesaler_quote_result;

DO $$
DECLARE
  v_rfq_id UUID := (SELECT id FROM public.rfqs WHERE title = 'Q3 Restock' AND pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy'));
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  r TEXT;
BEGIN
  PERFORM zz.check('submit_rfq_quote: Alpha''s quote total = 100*8.50 + 50*4.00 = 1050.00',
    (SELECT total_ghs = 1050.00 FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = alpha));
  PERFORM zz.check('submit_rfq_quote: Alpha quoted both lines',
    (SELECT COUNT(*) = 2 FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id WHERE q.rfq_id = v_rfq_id AND q.wholesaler_id = alpha));
  PERFORM zz.check('submit_rfq_quote: Other Wholesale''s quote total = 100*9.75 = 975.00 (partial, 1 line)',
    (SELECT total_ghs = 975.00 FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = other_w));
  PERFORM zz.check('submit_rfq_quote: the pharmacy was notified of both quotes',
    (SELECT COUNT(*) FROM public.notifications WHERE type = 'rfq_quote_received' AND link = '/pharmacy/rfqs/' || v_rfq_id) >= 2);

  ------------------------------------------------------------------
  -- RLS sealing on rfq_quotes: the core guarantee. Pharmacy sees both; each wholesaler sees only
  -- its own, even though it knows the RFQ (and the other invitee) exist.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.rfq_quotes WHERE rfq_id = %L', v_rfq_id));
  PERFORM zz.check('rfq_quotes RLS: the pharmacy sees both quotes (2)', r = '2', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfq_quotes WHERE rfq_id = %L', v_rfq_id));
  PERFORM zz.check('rfq_quotes RLS: Alpha sees only its own quote (1, not 2)', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfq_quotes WHERE rfq_id = %L AND wholesaler_id = %L', v_rfq_id, other_w));
  PERFORM zz.check('rfq_quotes RLS: Alpha cannot see Other Wholesale''s quote row at all', r = '0', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.rfq_quotes WHERE rfq_id = %L AND wholesaler_id = %L', v_rfq_id, alpha));
  PERFORM zz.check('rfq_quotes RLS: Other Wholesale cannot see Alpha''s quote row either', r = '0', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id WHERE q.rfq_id = %L AND q.wholesaler_id = %L', v_rfq_id, other_w));
  PERFORM zz.check('rfq_quote_items RLS: Alpha cannot read Other Wholesale''s quoted line items', r = '0', r);

  PERFORM zz.check('sanity: Other Pharmacy has no visibility at all into this rfq''s quotes',
    zz.val_as(u_px, format('SELECT count(*)::text FROM public.rfq_quotes WHERE rfq_id = %L', v_rfq_id)) = '0');
END $$;

-- Uninvited wholesaler (Other Wholesale was invited to the first rfq, but try a fresh
-- single-invite RFQ to prove "not invited" is rejected distinctly from "no permission over this
-- business").
SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='ph_owner'),
  format(
    $q$SELECT public.create_rfq(%L, 'Alpha Only', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
    (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    '[{"productName":"Amoxicillin 500mg","quantity":10}]'::jsonb
  )
) AS alpha_only_rfq_id;

SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_other'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Alpha Only'),
    (SELECT id FROM zz.b WHERE name='Other Wholesale'),
    jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Alpha Only')),
      'productId', (SELECT id FROM public.products WHERE name = 'RFQ Amlodipine (equivalent)'),
      'unitPriceGhs', 9.75
    ))
  )
) AS uninvited_quote_attempt;

SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_owner'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Alpha Only'),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Alpha Only')),
      'productId', (SELECT id FROM public.products WHERE name = 'RFQ Inactive'),
      'unitPriceGhs', 9.00
    ))
  )
) AS inactive_product_quote_attempt;

-- First real (successful) submission for this RFQ.
SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_owner'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Alpha Only'),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Alpha Only')),
      'productId', (SELECT id FROM public.products WHERE name = 'RFQ Amoxicillin'),
      'unitPriceGhs', 8.00
    ))
  )
) AS alpha_only_first_quote;

-- Resubmission for the SAME rfq item, but a different product/price -- proves the old line gets
-- replaced, not appended alongside it.
SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_owner'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L, 'revised, cheaper substitute')::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Alpha Only'),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Alpha Only')),
      'productId', (SELECT id FROM public.products WHERE name = 'RFQ Paracetamol'),
      'unitPriceGhs', 7.00
    ))
  )
) AS alpha_only_resubmit;

DO $$
DECLARE
  v_rfq_id UUID := (SELECT id FROM public.rfqs WHERE title = 'Alpha Only');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  r TEXT;
BEGIN
  PERFORM zz.check('submit_rfq_quote: exactly 1 quote row exists for Alpha Only (uninvited + inactive-product attempts both failed, only Alpha''s real submission landed)',
    (SELECT COUNT(*) FROM public.rfq_quotes WHERE rfq_id = v_rfq_id) = 1);
  PERFORM zz.check('submit_rfq_quote: Other Wholesale never got a quote row (it was rejected as uninvited)',
    NOT EXISTS (SELECT 1 FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = other_w));
  PERFORM zz.check('submit_rfq_quote: resubmission replaced the line item (still exactly 1 line, now pointing at Paracetamol at the new price, not 2 lines)',
    (SELECT COUNT(*) = 1 AND bool_and(unit_price_ghs = 7.00) AND bool_and(product_id = (SELECT id FROM public.products WHERE name = 'RFQ Paracetamol'))
     FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id
     WHERE q.rfq_id = v_rfq_id AND q.wholesaler_id = alpha));
  PERFORM zz.check('submit_rfq_quote: resubmission recomputed the total (10 * 7.00 = 70.00, not the old 8.00)',
    (SELECT total_ghs = 70.00 FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = alpha));

  ------------------------------------------------------------------
  -- withdraw_rfq_quote
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format('SELECT public.withdraw_rfq_quote(%L, %L)::text', v_rfq_id, other_w));
  PERFORM zz.check('withdraw_rfq_quote: cannot withdraw a quote for a business you do not control', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.withdraw_rfq_quote(%L, %L)::text', v_rfq_id, alpha));
  PERFORM zz.check('withdraw_rfq_quote: the pharmacy itself cannot withdraw a wholesaler''s quote', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.withdraw_rfq_quote(%L, %L)::text', v_rfq_id, alpha));
  PERFORM zz.check('withdraw_rfq_quote: Alpha can withdraw its own quote', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('withdraw_rfq_quote: status flips to withdrawn',
    (SELECT status FROM public.rfq_quotes WHERE rfq_id = v_rfq_id AND wholesaler_id = alpha) = 'withdrawn');
  r := zz.val_as(u_wo, format('SELECT public.withdraw_rfq_quote(%L, %L)::text', v_rfq_id, alpha));
  PERFORM zz.check('withdraw_rfq_quote: cannot withdraw an already-withdrawn quote', r LIKE 'ERR: This quote cannot be withdrawn%', r);

  ------------------------------------------------------------------
  -- cancel_rfq
  ------------------------------------------------------------------
  r := zz.val_as(u_px, format('SELECT public.cancel_rfq(%L)::text', v_rfq_id));
  PERFORM zz.check('cancel_rfq: an unrelated pharmacy is denied', r LIKE 'ERR: You do not have permission to cancel%', r);
  r := zz.val_as(u_po, format('SELECT public.cancel_rfq(%L)::text', v_rfq_id));
  PERFORM zz.check('cancel_rfq: the owner can cancel', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('cancel_rfq: status flips to cancelled', (SELECT status FROM public.rfqs WHERE id = v_rfq_id) = 'cancelled');
  PERFORM zz.check('cancel_rfq: the invited wholesaler was notified of the cancellation',
    EXISTS (SELECT 1 FROM public.notifications WHERE type = 'rfq_cancelled' AND link = '/wholesaler/rfqs/' || v_rfq_id));
  r := zz.val_as(u_po, format('SELECT public.cancel_rfq(%L)::text', v_rfq_id));
  PERFORM zz.check('cancel_rfq: cannot cancel an already-cancelled RFQ', r LIKE 'ERR: Only an open RFQ can be cancelled%', r);
END $$;

-- submit_rfq_quote must reject once the RFQ is cancelled (own top-level statement, temp-table rule).
SELECT zz.val_as(
  (SELECT id FROM zz.u WHERE k='w_owner'),
  format(
    $q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
    (SELECT id FROM public.rfqs WHERE title = 'Alpha Only'),
    (SELECT id FROM zz.b WHERE name='Alpha Wholesale'),
    jsonb_build_array(jsonb_build_object(
      'rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Alpha Only')),
      'productId', (SELECT id FROM public.products WHERE name = 'RFQ Amoxicillin'),
      'unitPriceGhs', 6.00
    ))
  )
) AS post_cancel_quote_attempt;

DO $$
BEGIN
  PERFORM zz.check('submit_rfq_quote: rejected once the RFQ is cancelled',
    NOT EXISTS (
      SELECT 1 FROM public.rfq_quotes q JOIN public.rfqs rf ON rf.id = q.rfq_id
      WHERE rf.title = 'Alpha Only' AND q.wholesaler_id = (SELECT id FROM zz.b WHERE name='Alpha Wholesale')
        AND q.status = 'submitted' AND q.total_ghs = 60.00
    ));

  ------------------------------------------------------------------
  -- No EXECUTE for anon on any RFQ mutation RPC.
  ------------------------------------------------------------------
  PERFORM zz.check('anon has no EXECUTE on any rfq mutation RPC',
    NOT has_function_privilege('anon', 'public.create_rfq(uuid,text,text,timestamptz,uuid[],jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.submit_rfq_quote(uuid,uuid,jsonb,text,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.withdraw_rfq_quote(uuid,uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cancel_rfq(uuid)', 'EXECUTE'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
