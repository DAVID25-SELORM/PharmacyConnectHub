-- Order amendments, Phase 3b part 2: fail-closed in-place patches so that a cash (pay on delivery) order can be accepted with a
-- back-order, and so that everything that reads such an order knows its portions are collected one by one. Each patch rebuilds
-- the LIVE definition, must match exactly the expected number of times, otherwise stops without changing anything, and is safe
-- to re-run. Nothing changes for an order that has no back-order.
--
--   1. respond_to_amendment: the pharmacy may choose "accept and back-order the rest" on a cash order (it was refused).
--   2. order_receipt_supply: a receipt covers the main delivery, so it carries the main total (the effective total less the
--      shipments already dispatched); for any order without shipments that is the same number as before.
--   3. order_backorder_state / get_order_backorder: say whether the order is collected portion by portion, whether the main
--      delivery has been collected, and when each shipment was.
--   4. customer_statement: a cash order collected portion by portion shows one payment line per collection (a cash order paid
--      as one amount still shows its single payment line).
--   6. order_supply_summary: the main delivery's total no longer drops when a delivery problem is credited on a back-order shipment
--      (a latent slip from Phases 3 and 5: the shipment's credit lowered the order total, which the main total was derived from).
--   5. resolve_delivery_report: a delivery problem on a portion that has been collected cannot be credited (no cash refunds yet).

-- The patch helper (the same definition as in the effective-total migration, repeated so this file runs on its own; it only
-- replaces the helper with an identical copy).
CREATE OR REPLACE FUNCTION public.apply_function_regex_patch(
  p_function_name TEXT, p_pattern TEXT, p_replacement TEXT, p_expected INTEGER, p_applied_marker TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_oids OID[];
  v_def TEXT;
  v_count INTEGER;
BEGIN
  SELECT array_agg(p.oid) INTO v_oids FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_function_name;
  IF v_oids IS NULL THEN
    RETURN 'not present';
  END IF;
  IF array_length(v_oids, 1) <> 1 THEN
    RAISE EXCEPTION 'Function % has % overloads; patch it by signature instead. Nothing was changed.', p_function_name, array_length(v_oids, 1);
  END IF;
  v_def := replace(pg_get_functiondef(v_oids[1]), E'\r', '');
  IF position(p_applied_marker IN v_def) > 0 THEN
    RETURN 'already patched';
  END IF;
  SELECT count(*) INTO v_count FROM regexp_matches(v_def, p_pattern, 'g');
  IF v_count <> p_expected THEN
    RAISE EXCEPTION 'Unexpected definition of % (expected % match(es) of %, found %). Nothing was changed.', p_function_name, p_expected, p_pattern, v_count;
  END IF;
  EXECUTE regexp_replace(v_def, p_pattern, p_replacement, 'g');
  RETURN 'patched';
END;
$$;
REVOKE ALL ON FUNCTION public.apply_function_regex_patch(TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;

-- 1. Cash orders may be back-ordered.
SELECT public.apply_function_regex_patch('respond_to_amendment',
  'IF p_choice = ''accept_backorder'' AND NOT v_order\.is_credit_order THEN\s+RAISE EXCEPTION ''Back-orders are only available on credit orders for now\. Accept and cancel the rest, or reject\.'';\s+END IF;',
  '-- (cash orders may be back-ordered too: each portion is collected on its own)',
  1, 'cash orders may be back-ordered too');

-- 2. A receipt covers the main delivery.
SELECT public.apply_function_regex_patch('order_receipt_supply',
  '''effective_total_ghs'', COALESCE\(v_order\.effective_total_ghs, v_order\.total_ghs\),',
  '''effective_total_ghs'', public.order_main_total(p_order_id),', 1, 'order_main_total');

-- 3. What the screens need to know about collection.
SELECT public.apply_function_regex_patch('order_backorder_state',
  '''sent'', v_sent, ''cancelled'', v_cancelled\)',
  '''sent'', v_sent, ''cancelled'', v_cancelled,' || E'\n'
  || '                            ''cash_portions'', public.order_has_cash_portions(p_order_id),' || E'\n'
  || '                            ''main_collected'', EXISTS (SELECT 1 FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL))',
  1, 'cash_portions');
SELECT public.apply_function_regex_patch('get_order_backorder',
  '''state'', public\.order_backorder_state\(p_order_id\),',
  '''state'', public.order_backorder_state(p_order_id),' || E'\n'
  || '    ''cash_portions'', public.order_has_cash_portions(p_order_id),' || E'\n'
  || '    ''main_total'', public.order_main_total(p_order_id),' || E'\n'
  || '    ''main_collected_at'', (SELECT c.confirmed_at FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL),',
  1, 'main_collected_at');
SELECT public.apply_function_regex_patch('get_order_backorder',
  '''credit_due_date'', s\.credit_due_date,',
  '''credit_due_date'', s.credit_due_date,' || E'\n'
  || '        ''collected_at'', (SELECT c.confirmed_at FROM public.order_collections c WHERE c.shipment_id = s.id),',
  1, '''collected_at''');

SELECT public.apply_function_regex_patch('get_order_backorder',
  '''collected_at'', \(SELECT c\.confirmed_at FROM public\.order_collections c WHERE c\.shipment_id = s\.id\),',
  '''collected_at'', (SELECT c.confirmed_at FROM public.order_collections c WHERE c.shipment_id = s.id),' || E'\n'
  || '        ''receipt_sent_at'', (SELECT c.receipt_sent_at FROM public.order_collections c WHERE c.shipment_id = s.id),',
  1, '''receipt_sent_at''');
SELECT public.apply_function_regex_patch('get_order_backorder',
  '''main_collected_at'', \(SELECT c\.confirmed_at FROM public\.order_collections c WHERE c\.order_id = p_order_id AND c\.shipment_id IS NULL\),',
  '''main_collected_at'', (SELECT c.confirmed_at FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL),' || E'\n'
  || '    ''main_receipt_sent_at'', (SELECT c.receipt_sent_at FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL),',
  1, '''main_receipt_sent_at''');

-- 4. Statement: one payment line per collection for a cash order collected portion by portion.
SELECT public.apply_function_regex_patch('customer_statement',
  'AND o\.status <> ''cancelled'' AND o\.payment_status = ''paid'' AND NOT o\.is_credit_order',
  'AND o.status <> ''cancelled'' AND o.payment_status = ''paid'' AND NOT o.is_credit_order' || E'\n'
  || '      AND NOT EXISTS (SELECT 1 FROM public.order_collections oc0 WHERE oc0.order_id = o.id)' || E'\n'
  || '    UNION ALL' || E'\n'
  || '    SELECT oc.confirmed_at, ''payment'', ''credit'', oc.order_id, co.order_number, oc.amount_ghs, 0::NUMERIC' || E'\n'
  || '    FROM public.order_collections oc JOIN public.orders co ON co.id = oc.order_id' || E'\n'
  || '    WHERE co.wholesaler_id = p_wholesaler_id AND co.pharmacy_id = p_pharmacy_id AND co.status <> ''cancelled'' AND oc.amount_ghs > 0',
  1, 'order_collections');

-- 5. No credit for a portion that has already been collected.
SELECT public.apply_function_regex_patch('resolve_delivery_report',
  'NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN',
  'NOT v_order.is_credit_order' || E'\n'
  || '     AND (v_order.payment_status = ''paid'' OR EXISTS (SELECT 1 FROM public.order_collections oc WHERE oc.order_id = v_order.id AND oc.shipment_id IS NOT DISTINCT FROM v_r.shipment_id)) THEN',
  1, 'order_collections');

-- 6. The main total, net of credits on shipments.
SELECT public.apply_function_regex_patch('order_supply_summary',
  '- COALESCE\(\(SELECT SUM\(s\.amount_ghs\) FROM public\.order_shipments s WHERE s\.order_id = o\.id AND s\.status IN \(''dispatched'', ''delivered''\)\), 0\)',
  '- public.order_shipments_net(o.id)', 1, 'order_shipments_net');
