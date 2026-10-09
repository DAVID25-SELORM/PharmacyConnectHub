-- Order amendments, Phase 5 part 2: fail-closed in-place patches that delivery reconciliation needs in existing code (each
-- rebuilds the LIVE definition, must match exactly the expected number of times, otherwise stops without changing anything,
-- and is safe to re-run).
--
--   1. A resolved return that credits or refunds a credit order now reaches the credit ledger: one credit note, once, linked to
--      the return. Until now a credited return reduced the customer statement but never the invoice balance, so the two
--      disagreed. Resolved returns that exist before this migration are NOT back-filled (see docs, section 18).
--   2. credit_invoice_status() nets those credit notes, and the ones a delivery claim creates, against the invoice (they reduce
--      what was invoiced; they are not payments).
--   3. Returns cannot claim units a delivery claim already speaks for.
--   4. The customer statement shows a delivery credit as its own dated line.

-- ---------------------------------------------------------------------------
-- 1. Returns reach the ledger
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('resolve_order_return',
  'PERFORM public\.write_audit_log\(''Return resolved'', v_name,',
  'IF p_resolution IN (''refund'', ''credit'') AND v_total > 0' || E'\n'
  || '     AND EXISTS (SELECT 1 FROM public.orders o WHERE o.id = v_return.order_id AND o.is_credit_order) THEN' || E'\n'
  || '    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, return_id)' || E'\n'
  || '    VALUES (v_return.wholesaler_id, v_return.pharmacy_id, v_return.order_id, ''credit_note'', ''credit'', v_total, auth.uid(),' || E'\n'
  || '            ''Return '' || v_return.return_number || '' accepted ('' || p_resolution || '')'', v_return.id);' || E'\n'
  || '  END IF;' || E'\n'
  || '  PERFORM public.write_audit_log(''Return resolved'', v_name,',
  1, 'note, return_id)');

-- ---------------------------------------------------------------------------
-- 2. Credit notes from amendments, delivery claims and returns reduce the invoice
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('credit_invoice_status',
  'FILTER \(WHERE amendment_id IS NOT NULL\)',
  'FILTER (WHERE amendment_id IS NOT NULL OR delivery_report_id IS NOT NULL OR return_id IS NOT NULL)',
  1, 'delivery_report_id IS NOT NULL');

-- ---------------------------------------------------------------------------
-- 3. Returnable quantity: units under a delivery claim are spoken for
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('get_returnable_items',
  'public\.order_item_fulfilled_qty\(oi\.id\)',
  '(public.order_item_fulfilled_qty(oi.id) - public.order_item_reconciled_qty(oi.id))', 1, 'order_item_reconciled_qty');
SELECT public.apply_function_regex_patch('request_order_return',
  'public\.order_item_fulfilled_qty\(oi\.id\) AS quantity',
  '(public.order_item_fulfilled_qty(oi.id) - public.order_item_reconciled_qty(oi.id)) AS quantity', 1, 'order_item_reconciled_qty');

-- ---------------------------------------------------------------------------
-- 4. Statement: a delivery credit is a dated credit line
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('customer_statement',
  'SELECT s\.dispatched_at, ''shipment'',',
  'SELECT r.resolved_at, ''delivery_credit'', ''credit'', r.order_id, ro.order_number, r.credit_total_ghs, 0::NUMERIC' || E'\n'
  || '    FROM public.order_delivery_reports r JOIN public.orders ro ON ro.id = r.order_id' || E'\n'
  || '    WHERE ro.wholesaler_id = p_wholesaler_id AND ro.pharmacy_id = p_pharmacy_id AND r.status = ''resolved'' AND r.credit_total_ghs > 0' || E'\n'
  || '      AND ro.status <> ''cancelled'' AND ro.payment_status <> ''refunded''' || E'\n'
  || '    UNION ALL' || E'\n'
  || '    SELECT s.dispatched_at, ''shipment'',',
  1, '''delivery_credit''');
