-- Order amendments, Phase 5 part 3: delivery reconciliation workflow.
--
--   1. The pharmacy's owner, manager or cashier records what a delivery actually brought (submit_delivery_report). A report with
--      no discrepancy is just a receipt ("received in full"). A report with discrepancies is a CLAIM: nothing about stock or money
--      changes, and the claimed units cannot be claimed again through a return.
--   2. The wholesaler's owner or manager verifies it (resolve_delivery_report) and decides each discrepancy: credit it, take the
--      goods back through the existing returns workflow, or reject the claim. Only then does anything change:
--        credit  -> a credit note on a credit order (once, linked to the report) and a lower order total; on a cash order that
--                   is not yet paid, just the lower order total (a paid cash order needs a refund, which is not supported);
--        return  -> a return in the existing workflow, already approved, linked to the report; stock and money then follow
--                   the return's own inspection and resolution (which now reaches the ledger);
--        reject  -> nothing changes; the units become returnable again.
--      Missing goods are credited or rejected; damaged and rejected goods can also be returned.
--   3. The pharmacy can withdraw a claim nobody has decided yet.
-- No stock is ever touched by a report. Every step is in the order's activity timeline, the audit log and a notification.

-- ---------------------------------------------------------------------------
-- submit_delivery_report
-- ---------------------------------------------------------------------------
-- p_shipment_id NULL = the order's main shipment. p_lines: [{"order_item_id", "received", "missing", "damaged", "rejected",
-- "reason"}]; products left out are received in full. Safe to repeat with the same p_request_id.
CREATE OR REPLACE FUNCTION public.submit_delivery_report(
  p_order_id UUID,
  p_shipment_id UUID DEFAULT NULL,
  p_lines JSONB DEFAULT '[]'::JSONB,
  p_note TEXT DEFAULT NULL,
  p_request_id UUID DEFAULT gen_random_uuid()
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_ship RECORD;
  v_existing RECORD;
  v_delivered_at TIMESTAMPTZ;
  v_item RECORD;
  v_el JSONB;
  v_exp INTEGER;
  v_missing INTEGER;
  v_damaged INTEGER;
  v_rejected INTEGER;
  v_received INTEGER;
  v_reason TEXT;
  v_lines JSONB := '[]'::JSONB;
  v_any BOOLEAN := FALSE;
  v_units INTEGER := 0;
  v_report_id UUID;
  v_status TEXT;
  v_note TEXT := NULLIF(left(btrim(COALESCE(p_note, '')), 500), '');
  v_pharmacy_name TEXT;
  v_label TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A request id is required.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.delivered_at
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to report on this delivery.';
  END IF;

  SELECT r.id, r.status INTO v_existing FROM public.order_delivery_reports r WHERE r.order_id = p_order_id AND r.request_id = p_request_id;
  IF FOUND THEN
    RETURN jsonb_build_object('report_id', v_existing.id, 'status', v_existing.status, 'replayed', TRUE);
  END IF;

  IF p_shipment_id IS NULL THEN
    IF v_order.status <> 'delivered' THEN RAISE EXCEPTION 'The order has not been marked delivered yet.'; END IF;
    v_delivered_at := v_order.delivered_at;
    v_label := 'the main delivery';
  ELSE
    SELECT s.id, s.sequence, s.status, s.delivered_at INTO v_ship FROM public.order_shipments s WHERE s.id = p_shipment_id AND s.order_id = p_order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'That shipment does not belong to this order.'; END IF;
    IF v_ship.status <> 'delivered' THEN RAISE EXCEPTION 'That shipment has not been marked delivered yet.'; END IF;
    v_delivered_at := v_ship.delivered_at;
    v_label := format('back-order shipment %s', v_ship.sequence);
  END IF;
  v_delivered_at := COALESCE(v_delivered_at, now());
  IF now() > v_delivered_at + interval '30 days' THEN
    RAISE EXCEPTION 'The 30-day window to report on this delivery has passed.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_delivery_reports r WHERE r.order_id = p_order_id
             AND r.shipment_id IS NOT DISTINCT FROM p_shipment_id AND r.status IN ('submitted', 'resolved', 'received_in_full')) THEN
    RAISE EXCEPTION 'There is already a delivery report for this delivery.';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN RAISE EXCEPTION 'Lines must be a list.'; END IF;
  IF (SELECT count(DISTINCT e->>'order_item_id') FROM jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'Each product can appear only once.';
  END IF;

  -- What this delivery brought, per product.
  FOR v_item IN
    SELECT x.id, x.product_id, x.product_name, x.unit_price_ghs, x.expected FROM (
      SELECT oi.id, oi.product_id, oi.product_name, oi.unit_price_ghs,
        CASE WHEN p_shipment_id IS NULL THEN public.order_item_supplied_qty(oi.id)
             ELSE COALESCE((SELECT sl.quantity FROM public.order_shipment_lines sl WHERE sl.shipment_id = p_shipment_id AND sl.order_item_id = oi.id), 0) END AS expected
      FROM public.order_items oi WHERE oi.order_id = p_order_id) x
    WHERE x.expected > 0 ORDER BY x.id
  LOOP
    SELECT e INTO v_el FROM jsonb_array_elements(p_lines) e WHERE e->>'order_item_id' = v_item.id::TEXT LIMIT 1;
    v_exp := v_item.expected;
    v_missing := 0; v_damaged := 0; v_rejected := 0; v_reason := NULL;
    IF v_el IS NOT NULL THEN
      IF COALESCE(v_el->>'missing', '0') !~ '^[0-9]{1,9}$' OR COALESCE(v_el->>'damaged', '0') !~ '^[0-9]{1,9}$'
         OR COALESCE(v_el->>'rejected', '0') !~ '^[0-9]{1,9}$' THEN
        RAISE EXCEPTION 'Quantities for % must be whole numbers.', v_item.product_name;
      END IF;
      v_missing := COALESCE(v_el->>'missing', '0')::INTEGER;
      v_damaged := COALESCE(v_el->>'damaged', '0')::INTEGER;
      v_rejected := COALESCE(v_el->>'rejected', '0')::INTEGER;
      v_reason := NULLIF(left(btrim(COALESCE(v_el->>'reason', '')), 300), '');
      IF v_el->>'received' IS NOT NULL AND (v_el->>'received') !~ '^[0-9]{1,9}$' THEN
        RAISE EXCEPTION 'Quantities for % must be whole numbers.', v_item.product_name;
      END IF;
    END IF;
    IF v_missing + v_damaged + v_rejected > v_exp THEN
      RAISE EXCEPTION 'You cannot report more than the % delivered of %.', v_exp, v_item.product_name;
    END IF;
    v_received := v_exp - v_missing - v_damaged - v_rejected;
    IF v_el IS NOT NULL AND v_el->>'received' IS NOT NULL AND (v_el->>'received')::INTEGER <> v_received THEN
      RAISE EXCEPTION 'The quantities for % do not add up to the % delivered.', v_item.product_name, v_exp;
    END IF;
    IF v_missing + v_damaged + v_rejected > 0 THEN
      v_any := TRUE;
      IF v_reason IS NULL OR char_length(v_reason) < 3 THEN
        RAISE EXCEPTION 'Say what went wrong with %.', v_item.product_name;
      END IF;
      -- Units already spoken for by a return or another claim cannot be reported again.
      IF v_missing + v_damaged + v_rejected > public.order_item_fulfilled_qty(v_item.id)
           - public.order_item_reconciled_qty(v_item.id)
           - COALESCE((SELECT SUM(COALESCE(ri.quantity_accepted, ri.quantity_requested)) FROM public.order_return_items ri
                       JOIN public.order_returns r ON r.id = ri.return_id
                       WHERE ri.order_item_id = v_item.id AND r.status NOT IN ('rejected', 'cancelled')), 0) THEN
        RAISE EXCEPTION 'Some of the units of % are already part of a return or another claim.', v_item.product_name;
      END IF;
    END IF;
    v_units := v_units + v_missing + v_damaged + v_rejected;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('order_item_id', v_item.id, 'product_id', v_item.product_id,
      'product_name', v_item.product_name, 'unit_price_ghs', v_item.unit_price_ghs, 'expected_qty', v_exp, 'received_qty', v_received,
      'missing_qty', v_missing, 'damaged_qty', v_damaged, 'rejected_qty', v_rejected, 'reason', v_reason));
  END LOOP;
  IF jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'This delivery has nothing to report on.'; END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) e
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE l->>'order_item_id' = e->>'order_item_id')
  ) THEN
    RAISE EXCEPTION 'A line does not belong to this delivery.';
  END IF;

  v_status := CASE WHEN v_any THEN 'submitted' ELSE 'received_in_full' END;
  INSERT INTO public.order_delivery_reports(order_id, shipment_id, status, note, delivered_at, submitted_by, request_id)
  VALUES (p_order_id, p_shipment_id, v_status, v_note, v_delivered_at, auth.uid(), p_request_id) RETURNING id INTO v_report_id;
  INSERT INTO public.order_delivery_report_lines(report_id, order_item_id, product_id, product_name, unit_price_ghs, expected_qty,
                                                 received_qty, missing_qty, damaged_qty, rejected_qty, reason)
  SELECT v_report_id, (l->>'order_item_id')::UUID, (l->>'product_id')::UUID, l->>'product_name', (l->>'unit_price_ghs')::NUMERIC,
         (l->>'expected_qty')::INTEGER, (l->>'received_qty')::INTEGER, (l->>'missing_qty')::INTEGER, (l->>'damaged_qty')::INTEGER,
         (l->>'rejected_qty')::INTEGER, l->>'reason'
  FROM jsonb_array_elements(v_lines) l;

  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  IF v_any THEN
    PERFORM public.record_order_event(p_order_id, 'delivery_report_submitted', 'pharmacy',
      format('The pharmacy reported a problem with %s: %s unit(s) missing, damaged or rejected. Awaiting the wholesaler''s check.', v_label, v_units),
      jsonb_build_object('units', v_units, 'note', v_note), NULL, p_shipment_id);
    PERFORM public.write_audit_log('Delivery problem reported', v_pharmacy_name, 'order', p_order_id, v_order.order_number,
      jsonb_build_object('report_id', v_report_id, 'delivery', v_label, 'units', v_units), _business_id => v_order.pharmacy_id);
    BEGIN
      PERFORM public.notify_business(v_order.wholesaler_id, ARRAY['owner', 'manager'], 'delivery_update', 'Delivery problem reported',
        format('Order #%s: %s reported a problem with %s (%s unit(s)). Please check it and decide.', v_order.order_number,
               COALESCE(v_pharmacy_name, 'the pharmacy'), v_label, v_units),
        '/wholesaler?tab=orders', jsonb_build_object('order_id', p_order_id, 'order_number', v_order.order_number, 'report_id', v_report_id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'delivery report notification failed: %', SQLERRM; END;
  ELSE
    PERFORM public.record_order_event(p_order_id, 'delivery_received_in_full', 'pharmacy',
      format('The pharmacy confirmed %s was received in full.', v_label), jsonb_build_object('note', v_note), NULL, p_shipment_id);
  END IF;
  RETURN jsonb_build_object('report_id', v_report_id, 'status', v_status, 'replayed', FALSE, 'units', v_units);
END;
$$;
REVOKE ALL ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- withdraw_delivery_report (pharmacy, before anyone has decided)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdraw_delivery_report(p_report_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_r RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT r.order_id INTO v_order_id FROM public.order_delivery_reports r WHERE r.id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Report not found.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_r FROM public.order_delivery_reports r WHERE r.id = p_report_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to withdraw this report.';
  END IF;
  IF v_r.status = 'withdrawn' THEN RETURN jsonb_build_object('report_id', v_r.id, 'status', 'withdrawn', 'replayed', TRUE); END IF;
  IF v_r.status <> 'submitted' THEN RAISE EXCEPTION 'This report has already been %, so it can no longer be withdrawn.', v_r.status; END IF;
  UPDATE public.order_delivery_reports SET status = 'withdrawn', withdrawn_at = now() WHERE id = v_r.id;
  PERFORM public.record_order_event(v_order_id, 'delivery_report_withdrawn', 'pharmacy', 'The pharmacy withdrew its delivery report.', '{}'::JSONB, NULL, v_r.shipment_id);
  PERFORM public.write_audit_log('Delivery report withdrawn', (SELECT name FROM public.businesses WHERE id = v_order.pharmacy_id), 'order', v_order_id,
    v_order.order_number, jsonb_build_object('report_id', v_r.id), _business_id => v_order.pharmacy_id);
  RETURN jsonb_build_object('report_id', v_r.id, 'status', 'withdrawn', 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.withdraw_delivery_report(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_delivery_report(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- resolve_delivery_report (wholesaler owner / manager)
-- ---------------------------------------------------------------------------
-- p_decisions: [{"line_id": uuid, "kind": "missing"|"damaged"|"rejected", "outcome": "credit"|"return"|"reject"}] covering EVERY
-- discrepancy of the report. A rejection needs a note. Safe to repeat: a settled report answers "replayed".
CREATE OR REPLACE FUNCTION public.resolve_delivery_report(p_report_id UUID, p_decisions JSONB, p_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_r RECORD;
  v_line RECORD;
  v_kind TEXT;
  v_qty INTEGER;
  v_d JSONB;
  v_outcome TEXT;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_credit NUMERIC(12,2) := 0;
  v_amount NUMERIC(12,2);
  v_total_decisions INTEGER := 0;
  v_rejects INTEGER := 0;
  v_expected INTEGER := 0;
  v_return_damaged UUID;
  v_return_rejected UUID;
  v_return_id UUID;
  v_status TEXT;
  v_returns INTEGER := 0;
  v_wholesaler_name TEXT;
  v_summary TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT r.order_id INTO v_order_id FROM public.order_delivery_reports r WHERE r.id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Report not found.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id, o.is_credit_order, o.total_ghs, o.effective_total_ghs, o.payment_status::TEXT AS payment_status
  INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_r FROM public.order_delivery_reports r WHERE r.id = p_report_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only the wholesaler''s owner or manager can decide on a delivery report.';
  END IF;
  IF v_r.status IN ('resolved', 'disputed') THEN
    RETURN jsonb_build_object('report_id', v_r.id, 'status', v_r.status, 'replayed', TRUE);
  END IF;
  IF v_r.status <> 'submitted' THEN RAISE EXCEPTION 'This report is %; there is nothing to decide.', v_r.status; END IF;
  IF p_decisions IS NULL OR jsonb_typeof(p_decisions) <> 'array' THEN RAISE EXCEPTION 'Decide each discrepancy.'; END IF;

  -- Every discrepancy needs exactly one decision.
  SELECT (count(*) FILTER (WHERE l.missing_qty > 0) + count(*) FILTER (WHERE l.damaged_qty > 0) + count(*) FILTER (WHERE l.rejected_qty > 0))
  INTO v_expected FROM public.order_delivery_report_lines l WHERE l.report_id = p_report_id;
  IF jsonb_array_length(p_decisions) <> v_expected THEN
    RAISE EXCEPTION 'Decide every discrepancy on the report (% to decide).', v_expected;
  END IF;
  IF (SELECT count(DISTINCT (e->>'line_id') || (e->>'kind')) FROM jsonb_array_elements(p_decisions) e) <> v_expected THEN
    RAISE EXCEPTION 'Each discrepancy can be decided only once.';
  END IF;

  -- First pass: validate and add up the credit (nothing is written yet).
  FOR v_d IN SELECT e FROM jsonb_array_elements(p_decisions) e LOOP
    IF COALESCE(v_d->>'line_id', '') !~ '^[0-9a-fA-F-]{36}$' THEN RAISE EXCEPTION 'A decision refers to a line that is not on this report.'; END IF;
    SELECT * INTO v_line FROM public.order_delivery_report_lines l WHERE l.id = (v_d->>'line_id')::UUID AND l.report_id = p_report_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A decision refers to a line that is not on this report.'; END IF;
    v_kind := v_d->>'kind'; v_outcome := v_d->>'outcome';
    v_qty := CASE v_kind WHEN 'missing' THEN v_line.missing_qty WHEN 'damaged' THEN v_line.damaged_qty WHEN 'rejected' THEN v_line.rejected_qty ELSE NULL END;
    IF v_qty IS NULL OR v_qty = 0 THEN RAISE EXCEPTION 'There is nothing reported as % on %.', COALESCE(v_kind, '?'), v_line.product_name; END IF;
    IF v_outcome IS NULL OR v_outcome NOT IN ('credit', 'return', 'reject') THEN RAISE EXCEPTION 'Choose credit, return or reject for %.', v_line.product_name; END IF;
    IF v_outcome = 'return' AND v_kind = 'missing' THEN RAISE EXCEPTION 'Missing goods cannot be returned: credit them or reject the claim.'; END IF;
    IF v_outcome = 'credit' THEN v_credit := v_credit + round(v_qty * v_line.unit_price_ghs, 2); END IF;
    IF v_outcome = 'reject' THEN v_rejects := v_rejects + 1; END IF;
  END LOOP;
  IF v_rejects > 0 AND (v_note IS NULL OR char_length(v_note) < 3) THEN
    RAISE EXCEPTION 'Explain to the pharmacy why a claim is rejected.';
  END IF;
  IF v_credit > 0 AND NOT v_order.is_credit_order AND v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'This order has already been paid, and refunding it is not supported. Use "return" for damaged goods, or reject the claim.';
  END IF;

  -- Second pass: write the decisions and their effects.
  FOR v_d IN SELECT e FROM jsonb_array_elements(p_decisions) e LOOP
    SELECT * INTO v_line FROM public.order_delivery_report_lines l WHERE l.id = (v_d->>'line_id')::UUID;
    v_kind := v_d->>'kind'; v_outcome := v_d->>'outcome';
    v_qty := CASE v_kind WHEN 'missing' THEN v_line.missing_qty WHEN 'damaged' THEN v_line.damaged_qty ELSE v_line.rejected_qty END;
    v_amount := CASE WHEN v_outcome = 'credit' THEN round(v_qty * v_line.unit_price_ghs, 2) ELSE 0 END;
    v_return_id := NULL;
    IF v_outcome = 'return' THEN
      IF v_kind = 'damaged' THEN
        IF v_return_damaged IS NULL THEN
          INSERT INTO public.order_returns(order_id, pharmacy_id, wholesaler_id, reason, note, status, requested_by, reviewed_by, reviewed_at, wholesaler_note, delivery_report_id)
          VALUES (v_order_id, v_order.pharmacy_id, v_order.wholesaler_id, 'damaged', 'Opened from a delivery report', 'approved', v_r.submitted_by, auth.uid(), now(), left(v_note, 1000), p_report_id)
          RETURNING id INTO v_return_damaged;
          v_returns := v_returns + 1;
        END IF;
        v_return_id := v_return_damaged;
      ELSE
        IF v_return_rejected IS NULL THEN
          INSERT INTO public.order_returns(order_id, pharmacy_id, wholesaler_id, reason, note, status, requested_by, reviewed_by, reviewed_at, wholesaler_note, delivery_report_id)
          VALUES (v_order_id, v_order.pharmacy_id, v_order.wholesaler_id, 'quality_issue', 'Opened from a delivery report', 'approved', v_r.submitted_by, auth.uid(), now(), left(v_note, 1000), p_report_id)
          RETURNING id INTO v_return_rejected;
          v_returns := v_returns + 1;
        END IF;
        v_return_id := v_return_rejected;
      END IF;
      INSERT INTO public.order_return_items(return_id, order_item_id, product_id, product_name, unit_price_ghs, quantity_requested)
      VALUES (v_return_id, v_line.order_item_id, v_line.product_id, v_line.product_name, v_line.unit_price_ghs, v_qty);
    END IF;
    INSERT INTO public.order_delivery_report_decisions(report_id, line_id, kind, quantity, outcome, amount_ghs, return_id)
    VALUES (p_report_id, v_line.id, v_kind, v_qty, v_outcome, v_amount, v_return_id);
    v_total_decisions := v_total_decisions + 1;
  END LOOP;

  IF v_credit > 0 THEN
    IF v_order.is_credit_order THEN
      INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, delivery_report_id)
      VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'credit_note', 'credit', v_credit, auth.uid(),
              'Delivery problem credited after the wholesaler''s check', p_report_id);
    END IF;
    PERFORM public._allow_order_total_change();
    UPDATE public.orders SET effective_total_ghs = GREATEST(COALESCE(v_order.effective_total_ghs, v_order.total_ghs) - v_credit, 0) WHERE id = v_order_id;
  END IF;

  v_status := CASE WHEN v_rejects = v_total_decisions THEN 'disputed' ELSE 'resolved' END;
  UPDATE public.order_delivery_reports SET status = v_status, resolved_by = auth.uid(), resolved_at = now(),
    resolution_note = left(v_note, 500), credit_total_ghs = v_credit WHERE id = p_report_id;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  v_summary := CASE v_status WHEN 'disputed' THEN 'The wholesaler checked the delivery report and did not accept it.'
    ELSE format('The wholesaler checked the delivery report: %s credited%s.', public._amendment_money(v_credit),
                CASE WHEN v_returns > 0 THEN format(', %s return(s) opened for the goods', v_returns) ELSE '' END) END;
  PERFORM public.record_order_event(v_order_id, 'delivery_report_resolved', 'wholesaler', v_summary,
    jsonb_build_object('status', v_status, 'credited', v_credit, 'returns', v_returns, 'note', left(v_note, 500)), NULL, v_r.shipment_id);
  PERFORM public.write_audit_log('Delivery report decided', v_wholesaler_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('report_id', p_report_id, 'status', v_status, 'credited', v_credit, 'returns_opened', v_returns, 'rejected', v_rejects),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'delivery_update', 'Your delivery report was decided',
      format('Order #%s: %s%s', v_order.order_number, v_summary,
             CASE WHEN v_returns > 0 THEN ' Send the goods back through Returns.' ELSE '' END),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'report_id', p_report_id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'delivery report notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('report_id', p_report_id, 'status', v_status, 'replayed', FALSE, 'credited', v_credit, 'returns_opened', v_returns);
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_delivery_report(UUID, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_delivery_report(UUID, JSONB, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_order_delivery_reports: the order's deliveries, with their reports, for both sides
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_order_delivery_reports(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_side TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.pharmacy_id, o.wholesaler_id, o.status::TEXT AS status, o.delivered_at INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF public.can_act_for_business(v_order.wholesaler_id, 'read') THEN v_side := 'wholesaler';
  ELSIF public.can_act_for_business(v_order.pharmacy_id, 'read') THEN v_side := 'pharmacy';
  ELSIF public.has_role(auth.uid(), 'admin') THEN v_side := 'admin';
  ELSE RAISE EXCEPTION 'You do not have access to this order.';
  END IF;
  RETURN jsonb_build_object(
    'deliveries', (
      SELECT COALESCE(jsonb_agg(d ORDER BY d->>'sort'), '[]'::JSONB) FROM (
        SELECT jsonb_build_object('shipment_id', NULL::UUID, 'label', 'Main delivery', 'sort', '0', 'delivered_at', v_order.delivered_at,
          'delivered', v_order.status = 'delivered',
          'expected', COALESCE((SELECT jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'product_name', oi.product_name,
              'quantity', public.order_item_supplied_qty(oi.id), 'unit_price_ghs', oi.unit_price_ghs) ORDER BY oi.id)
            FROM public.order_items oi WHERE oi.order_id = p_order_id AND public.order_item_supplied_qty(oi.id) > 0), '[]'::JSONB)) AS d
        UNION ALL
        SELECT jsonb_build_object('shipment_id', s.id, 'label', 'Back-order shipment ' || s.sequence, 'sort', s.sequence::TEXT,
          'delivered_at', s.delivered_at, 'delivered', s.status = 'delivered',
          'expected', COALESCE((SELECT jsonb_agg(jsonb_build_object('order_item_id', sl.order_item_id, 'product_name', sl.product_name,
              'quantity', sl.quantity, 'unit_price_ghs', sl.unit_price_ghs) ORDER BY sl.product_name, sl.id)
            FROM public.order_shipment_lines sl WHERE sl.shipment_id = s.id), '[]'::JSONB))
        FROM public.order_shipments s WHERE s.order_id = p_order_id AND s.status <> 'cancelled'
      ) q),
    'reports', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', r.id, 'shipment_id', r.shipment_id, 'status', r.status, 'note', r.note, 'submitted_at', r.submitted_at,
        'submitted_by_label', public._amendment_actor_label(r.submitted_by, 'pharmacy', v_side, p_order_id),
        'resolved_at', r.resolved_at, 'resolution_note', r.resolution_note, 'credit_total', r.credit_total_ghs,
        'resolved_by_label', CASE WHEN r.resolved_by IS NULL THEN NULL ELSE public._amendment_actor_label(r.resolved_by, 'wholesaler', v_side, p_order_id) END,
        'lines', (SELECT jsonb_agg(jsonb_build_object(
            'id', l.id, 'order_item_id', l.order_item_id, 'product_name', l.product_name, 'unit_price_ghs', l.unit_price_ghs,
            'expected', l.expected_qty, 'received', l.received_qty, 'missing', l.missing_qty, 'damaged', l.damaged_qty,
            'rejected', l.rejected_qty, 'reason', l.reason) ORDER BY l.product_name, l.id)
          FROM public.order_delivery_report_lines l WHERE l.report_id = r.id),
        'decisions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'line_id', d.line_id, 'kind', d.kind, 'quantity', d.quantity, 'outcome', d.outcome, 'amount', d.amount_ghs,
            'return_number', (SELECT rr.return_number FROM public.order_returns rr WHERE rr.id = d.return_id)) ORDER BY d.kind, d.id)
          FROM public.order_delivery_report_decisions d WHERE d.report_id = r.id), '[]'::JSONB)
      ) ORDER BY r.submitted_at)
      FROM public.order_delivery_reports r WHERE r.order_id = p_order_id), '[]'::JSONB)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_order_delivery_reports(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_delivery_reports(UUID) TO authenticated;
