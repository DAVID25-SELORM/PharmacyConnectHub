-- Order amendments, Phase 3 part 3: back-order workflow.
--
--   * respond_to_amendment gains the pharmacy's third accepting choice, 'accept_backorder' (credit orders): the available quantity
--     is supplied now, a credit note removes the rest from the invoice as before, and the rest stays on the same order as an
--     outstanding back-order. Every other behaviour of that function is unchanged; it also announces the total change.
--   * create_backorder_shipment / advance_backorder_shipment (pack, dispatch, deliver) / cancel_backorder_shipment /
--     cancel_backorder_remaining / get_order_backorder.
--   * Dispatching a shipment is the financial and stock moment: credit limit re-checked under the credit-line lock (a one-time
--     override may cover it), stock deducted once for exactly the units sent, ONE invoice entry on the credit ledger, the
--     order's effective total raised by the shipment, the order's payment state reopened if it had been paid.
--   * order_supply_summary also returns the main shipment's own total and the back-order state.

-- ---------------------------------------------------------------------------
-- Internal: announce an approved change to the order total (see protect_effective_total in part 2)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._allow_order_total_change()
RETURNS VOID
LANGUAGE sql
AS $$ SELECT set_config('drugxone.amendment_txid', txid_current()::TEXT, true)::TEXT; $$;
REVOKE ALL ON FUNCTION public._allow_order_total_change() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- create_backorder_shipment: the wholesaler puts some of the outstanding quantity into a shipment
-- ---------------------------------------------------------------------------
-- p_lines: [{"order_item_id": uuid, "quantity": int}, ...]. Safe to repeat with the same p_request_id.
CREATE OR REPLACE FUNCTION public.create_backorder_shipment(
  p_order_id UUID,
  p_lines JSONB,
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
  v_existing RECORD;
  v_el JSONB;
  v_item RECORD;
  v_qty INTEGER;
  v_outstanding INTEGER;
  v_amount NUMERIC(12,2) := 0;
  v_seq INTEGER;
  v_shipment_id UUID;
  v_lines JSONB := '[]'::JSONB;
  v_units INTEGER := 0;
  v_note TEXT := NULLIF(left(btrim(COALESCE(p_note, '')), 300), '');
  v_wholesaler_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A request id is required.'; END IF;

  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to prepare a shipment for this order.';
  END IF;

  SELECT s.id, s.sequence, s.status, s.amount_ghs INTO v_existing FROM public.order_shipments s WHERE s.order_id = p_order_id AND s.request_id = p_request_id;
  IF FOUND THEN
    RETURN jsonb_build_object('shipment_id', v_existing.id, 'sequence', v_existing.sequence, 'status', v_existing.status,
                              'amount', v_existing.amount_ghs, 'replayed', TRUE);
  END IF;

  IF v_order.status NOT IN ('dispatched', 'delivered') THEN
    RAISE EXCEPTION 'The main shipment must be dispatched before a back-order shipment can be prepared.';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Choose what goes in this shipment.';
  END IF;
  IF (SELECT count(DISTINCT e->>'order_item_id') FROM jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'Each product can appear only once.';
  END IF;

  FOR v_el IN SELECT e FROM jsonb_array_elements(p_lines) e LOOP
    IF COALESCE(v_el->>'order_item_id', '') !~ '^[0-9a-fA-F-]{36}$' THEN RAISE EXCEPTION 'A line does not belong to this order.'; END IF;
    SELECT oi.id, oi.product_id, oi.product_name, oi.unit_price_ghs INTO v_item
    FROM public.order_items oi WHERE oi.id = (v_el->>'order_item_id')::UUID AND oi.order_id = p_order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'A line does not belong to this order.'; END IF;
    IF COALESCE(v_el->>'quantity', '') !~ '^[0-9]{1,9}$' OR (v_el->>'quantity')::INTEGER < 1 THEN
      RAISE EXCEPTION 'The quantity for % must be a whole number above zero.', v_item.product_name;
    END IF;
    v_qty := (v_el->>'quantity')::INTEGER;
    v_outstanding := public.order_item_backorder_outstanding(v_item.id);
    IF v_qty > v_outstanding THEN
      RAISE EXCEPTION 'Only % unit(s) of % are waiting to be shipped.', v_outstanding, v_item.product_name;
    END IF;
    v_amount := v_amount + round(v_qty * v_item.unit_price_ghs, 2);
    v_units := v_units + v_qty;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('order_item_id', v_item.id, 'product_id', v_item.product_id,
      'product_name', v_item.product_name, 'quantity', v_qty, 'unit_price_ghs', v_item.unit_price_ghs));
  END LOOP;

  SELECT COALESCE(max(s.sequence), 1) + 1 INTO v_seq FROM public.order_shipments s WHERE s.order_id = p_order_id;
  INSERT INTO public.order_shipments(order_id, sequence, status, amount_ghs, note, request_id, created_by)
  VALUES (p_order_id, v_seq, 'pending', v_amount, v_note, p_request_id, auth.uid()) RETURNING id INTO v_shipment_id;
  INSERT INTO public.order_shipment_lines(shipment_id, order_item_id, product_id, product_name, quantity, unit_price_ghs)
  SELECT v_shipment_id, (l->>'order_item_id')::UUID, (l->>'product_id')::UUID, l->>'product_name', (l->>'quantity')::INTEGER, (l->>'unit_price_ghs')::NUMERIC
  FROM jsonb_array_elements(v_lines) l;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.record_order_event(p_order_id, 'shipment_created', 'wholesaler',
    format('Back-order shipment %s prepared: %s unit(s), %s.', v_seq, v_units, public._amendment_money(v_amount)),
    jsonb_build_object('sequence', v_seq, 'units', v_units), NULL, v_shipment_id);
  PERFORM public.write_audit_log('Back-order shipment prepared', v_wholesaler_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('shipment_id', v_shipment_id, 'sequence', v_seq, 'units', v_units, 'amount', v_amount),
    _business_id => v_order.wholesaler_id);
  RETURN jsonb_build_object('shipment_id', v_shipment_id, 'sequence', v_seq, 'status', 'pending', 'amount', v_amount, 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- advance_backorder_shipment: pending -> packed -> dispatched -> delivered
-- ---------------------------------------------------------------------------
-- Dispatching is the financial moment: under the order lock and the customer's credit-line lock it re-checks the credit limit
-- (a one-time override may cover it), deducts the stock for exactly the units sent (orders with stock evidence only), posts
-- ONE invoice entry for the shipment on the credit ledger, and adds the shipment to the order's effective total.
CREATE OR REPLACE FUNCTION public.advance_backorder_shipment(p_shipment_id UUID, p_to TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_s RECORD;
  v_terms RECORD;
  v_line RECORD;
  v_exposure NUMERIC(12,2);
  v_override_id UUID;
  v_prior NUMERIC(12,2);
  v_has_evidence BOOLEAN;
  v_stock INTEGER;
  v_due DATE;
  v_name TEXT;
  v_pharmacy_name TEXT;
  v_staff TEXT[] := ARRAY['owner', 'manager', 'cashier', 'warehouse'];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_to IS NULL OR p_to NOT IN ('packed', 'dispatched', 'delivered') THEN RAISE EXCEPTION 'Unsupported shipment step.'; END IF;
  SELECT s.order_id INTO v_order_id FROM public.order_shipments s WHERE s.id = p_shipment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shipment not found.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.is_credit_order, o.total_ghs, o.effective_total_ghs,
         o.payment_status::TEXT AS payment_status, o.credit_due_basis, o.credit_terms_days, o.credit_due_date
  INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_s FROM public.order_shipments s WHERE s.id = p_shipment_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to update this shipment.';
  END IF;
  IF v_s.status = p_to THEN
    RETURN jsonb_build_object('shipment_id', v_s.id, 'status', v_s.status, 'replayed', TRUE);
  END IF;
  IF v_s.status = 'cancelled' THEN RAISE EXCEPTION 'This shipment was cancelled.'; END IF;
  IF NOT ((v_s.status = 'pending' AND p_to = 'packed') OR (v_s.status = 'packed' AND p_to = 'dispatched') OR (v_s.status = 'dispatched' AND p_to = 'delivered')) THEN
    RAISE EXCEPTION 'A shipment that is % cannot move to %.', v_s.status, p_to;
  END IF;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;

  -- ----- packed ---------------------------------------------------------------------------------------------------------
  IF p_to = 'packed' THEN
    UPDATE public.order_shipments SET status = 'packed', packed_at = now(), packed_by = auth.uid() WHERE id = v_s.id;
    PERFORM public.record_order_event(v_order_id, 'shipment_packed', 'wholesaler', format('Back-order shipment %s packed.', v_s.sequence), '{}'::JSONB, NULL, v_s.id);
    RETURN jsonb_build_object('shipment_id', v_s.id, 'status', 'packed', 'replayed', FALSE);
  END IF;

  -- ----- dispatched -----------------------------------------------------------------------------------------------------
  IF p_to = 'dispatched' THEN
    IF NOT v_order.is_credit_order THEN
      RAISE EXCEPTION 'Back-orders are only available on credit orders for now.';
    END IF;
    -- 1. The customer's credit line: locked, then re-checked exactly as checkout does.
    SELECT c.credit_limit_ghs, c.active, c.status INTO v_terms FROM public.wholesaler_credit_terms c
    WHERE c.wholesaler_id = v_order.wholesaler_id AND c.pharmacy_id = v_order.pharmacy_id FOR UPDATE;
    IF NOT FOUND OR NOT v_terms.active THEN
      RAISE EXCEPTION 'Credit is closed for this customer, so this shipment cannot be invoiced on credit. Reopen the credit line first.';
    END IF;
    IF v_terms.status <> 'active' THEN
      RAISE EXCEPTION 'Credit for this customer is %. Reactivate it before dispatching this shipment.', v_terms.status;
    END IF;
    v_exposure := public.credit_exposure(v_order.wholesaler_id, v_order.pharmacy_id);
    IF v_exposure + v_s.amount_ghs > v_terms.credit_limit_ghs THEN
      SELECT ov.id INTO v_override_id FROM public.credit_overrides ov
      WHERE ov.wholesaler_id = v_order.wholesaler_id AND ov.pharmacy_id = v_order.pharmacy_id AND ov.status = 'active'
        AND ov.expires_at > now() AND ov.max_order_ghs >= v_s.amount_ghs FOR UPDATE;
      IF v_override_id IS NULL THEN
        RAISE EXCEPTION 'Dispatching this shipment (%) would take the customer above its credit limit of % (currently owed %). Ask the customer to pay, or approve a one-time credit override.',
          public._amendment_money(v_s.amount_ghs), public._amendment_money(v_terms.credit_limit_ghs), public._amendment_money(v_exposure);
      END IF;
    END IF;

    -- 2. Stock: only for orders whose original deduction is evidenced, and only for the units sent, once.
    v_has_evidence := public.order_has_stock_evidence(v_order_id);
    IF v_has_evidence THEN
      FOR v_line IN SELECT sl.* FROM public.order_shipment_lines sl WHERE sl.shipment_id = v_s.id ORDER BY sl.product_id LOOP
        SELECT p.stock INTO v_stock FROM public.products p WHERE p.id = v_line.product_id AND p.wholesaler_id = v_order.wholesaler_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'The product for % no longer belongs to the supplier.', v_line.product_name; END IF;
        IF v_stock < v_line.quantity THEN
          RAISE EXCEPTION 'Not enough stock of % to dispatch this shipment (% in stock, % needed). Receive the goods into stock first.',
            v_line.product_name, v_stock, v_line.quantity;
        END IF;
        INSERT INTO public.inventory_operation_context(transaction_id, actor_id, movement_type, order_id, request_id, reason)
        VALUES (txid_current(), auth.uid(), 'backorder_dispatch_deduction', v_order_id, v_s.id,
                format('Back-order shipment %s dispatched', v_s.sequence));
        UPDATE public.products SET stock = stock - v_line.quantity WHERE id = v_line.product_id AND wholesaler_id = v_order.wholesaler_id;
        DELETE FROM public.inventory_operation_context WHERE transaction_id = txid_current();
        INSERT INTO public.order_stock_movements(order_id, shipment_id, order_item_id, product_id, wholesaler_id, kind, quantity, stock_effect, created_by)
        VALUES (v_order_id, v_s.id, v_line.order_item_id, v_line.product_id, v_order.wholesaler_id, 'backorder_dispatch', v_line.quantity, -v_line.quantity, auth.uid());
      END LOOP;
    END IF;

    -- 3. The invoice entry (one per shipment: the unique index refuses a second) and the order's payment state.
    SELECT GREATEST(COALESCE(SUM(CASE e.direction WHEN 'debit' THEN e.amount_ghs ELSE -e.amount_ghs END), 0), 0)::NUMERIC(12,2) INTO v_prior
    FROM public.credit_ledger_entries e WHERE e.order_id = v_order_id;
    IF v_s.amount_ghs > 0 THEN
      INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, shipment_id)
      VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'invoice', 'debit', v_s.amount_ghs, auth.uid(),
              format('Back-order shipment %s', v_s.sequence), v_s.id);
    END IF;
    IF v_override_id IS NOT NULL THEN
      UPDATE public.credit_overrides SET status = 'used', used_order_id = v_order_id, used_at = now() WHERE id = v_override_id;
      PERFORM public.write_audit_log('Credit override used', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
        jsonb_build_object('override_id', v_override_id, 'limit_ghs', v_terms.credit_limit_ghs, 'shipment_id', v_s.id,
                           'shipment_ghs', v_s.amount_ghs, 'resulting_exposure_ghs', v_exposure + v_s.amount_ghs),
        _business_id => v_order.wholesaler_id);
    END IF;
    PERFORM public._allow_order_total_change();
    UPDATE public.orders SET
      effective_total_ghs = COALESCE(v_order.effective_total_ghs, v_order.total_ghs) + v_s.amount_ghs,
      payment_status = CASE WHEN v_order.payment_status = 'paid' AND v_s.amount_ghs > 0 THEN 'unpaid'::public.payment_status ELSE payment_status END,
      paid_at = CASE WHEN v_order.payment_status = 'paid' AND v_s.amount_ghs > 0 THEN NULL ELSE paid_at END,
      payment_confirmed_at = CASE WHEN v_order.payment_status = 'paid' AND v_s.amount_ghs > 0 THEN NULL ELSE payment_confirmed_at END,
      payment_confirmed_by = CASE WHEN v_order.payment_status = 'paid' AND v_s.amount_ghs > 0 THEN NULL ELSE payment_confirmed_by END
    WHERE id = v_order_id;

    UPDATE public.order_shipments SET status = 'dispatched', dispatched_at = now(), dispatched_by = auth.uid(), prior_outstanding_ghs = v_prior WHERE id = v_s.id;
    PERFORM public.record_order_event(v_order_id, 'shipment_dispatched', 'wholesaler',
      format('Back-order shipment %s dispatched (%s).', v_s.sequence, public._amendment_money(v_s.amount_ghs)),
      jsonb_build_object('sequence', v_s.sequence, 'amount', v_s.amount_ghs), NULL, v_s.id);
    PERFORM public.write_audit_log('Back-order shipment dispatched', v_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('shipment_id', v_s.id, 'sequence', v_s.sequence, 'amount', v_s.amount_ghs, 'stock_deducted', v_has_evidence),
      _business_id => v_order.wholesaler_id);
    BEGIN
      PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment',
        'Back-order shipment on its way',
        format('Order #%s: back-order shipment %s (%s) has been dispatched by %s.', v_order.order_number, v_s.sequence,
               public._amendment_money(v_s.amount_ghs), COALESCE(v_name, 'the wholesaler')),
        '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'shipment_id', v_s.id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'shipment notification failed: %', SQLERRM; END;
    RETURN jsonb_build_object('shipment_id', v_s.id, 'status', 'dispatched', 'replayed', FALSE, 'amount', v_s.amount_ghs);
  END IF;

  -- ----- delivered ----------------------------------------------------------------------------------------------------
  -- Delivery-date terms: this shipment's invoice falls due its terms after delivery. The order has one due date, which moves
  -- only when nothing else was owed on the order when the shipment was invoiced, so an unpaid earlier invoice never gets longer.
  v_due := v_order.credit_due_date;
  IF v_order.credit_due_basis = 'delivery_date' THEN
    v_due := current_date + COALESCE(v_order.credit_terms_days, 30);
  END IF;
  UPDATE public.order_shipments SET status = 'delivered', delivered_at = now(), delivered_by = auth.uid(), credit_due_date = v_due WHERE id = v_s.id;
  IF v_order.credit_due_basis = 'delivery_date' AND COALESCE(v_s.prior_outstanding_ghs, 0) <= 0 AND v_order.credit_due_date IS DISTINCT FROM v_due THEN
    UPDATE public.orders SET credit_due_date = v_due WHERE id = v_order_id;
  END IF;
  PERFORM public.record_order_event(v_order_id, 'shipment_delivered', 'wholesaler',
    format('Back-order shipment %s delivered.', v_s.sequence), '{}'::JSONB, NULL, v_s.id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment',
      'Back-order shipment delivered',
      format('Order #%s: back-order shipment %s is marked delivered.', v_order.order_number, v_s.sequence),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'shipment_id', v_s.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'shipment notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('shipment_id', v_s.id, 'status', 'delivered', 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.advance_backorder_shipment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.advance_backorder_shipment(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- cancel_backorder_shipment: before it is dispatched; its units go back to "waiting to be shipped"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_backorder_shipment(p_shipment_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_s RECORD;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT s.order_id INTO v_order_id FROM public.order_shipments s WHERE s.id = p_shipment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shipment not found.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_s FROM public.order_shipments s WHERE s.id = p_shipment_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to cancel this shipment.';
  END IF;
  IF v_s.status = 'cancelled' THEN RETURN jsonb_build_object('shipment_id', v_s.id, 'status', 'cancelled', 'replayed', TRUE); END IF;
  IF v_s.status NOT IN ('pending', 'packed') THEN
    RAISE EXCEPTION 'A shipment that is % can no longer be cancelled.', v_s.status;
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 3 THEN RAISE EXCEPTION 'Give a reason for cancelling this shipment.'; END IF;
  UPDATE public.order_shipments SET status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(v_reason, 500) WHERE id = v_s.id;
  PERFORM public.record_order_event(v_order_id, 'shipment_cancelled', 'wholesaler',
    format('Back-order shipment %s was cancelled before dispatch; its units are waiting to be shipped again.', v_s.sequence),
    jsonb_build_object('reason', left(v_reason, 500)), NULL, v_s.id);
  PERFORM public.write_audit_log('Back-order shipment cancelled', (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id),
    'order', v_order_id, v_order.order_number, jsonb_build_object('shipment_id', v_s.id, 'sequence', v_s.sequence, 'reason', left(v_reason, 500)),
    _business_id => v_order.wholesaler_id);
  RETURN jsonb_build_object('shipment_id', v_s.id, 'status', 'cancelled', 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_backorder_shipment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_backorder_shipment(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- cancel_backorder_remaining: either side gives up what has not yet been put into a shipment
-- ---------------------------------------------------------------------------
-- Nothing was ever invoiced for these units (the credit note was issued when the back-order was accepted), so there is no
-- financial entry and no stock movement; only the outstanding quantity is closed, with who and why.
CREATE OR REPLACE FUNCTION public.cancel_backorder_remaining(p_order_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_side TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_item RECORD;
  v_out INTEGER;
  v_units INTEGER := 0;
  v_names TEXT;
  v_actor_name TEXT;
  v_other UUID;
  v_roles TEXT[];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF public.can_act_for_business(v_order.wholesaler_id, 'process') THEN v_side := 'wholesaler';
  ELSIF public.can_act_for_business(v_order.pharmacy_id, 'process') THEN v_side := 'pharmacy';
  ELSE RAISE EXCEPTION 'You do not have permission to cancel the back-order on this order.';
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 3 THEN RAISE EXCEPTION 'Give a reason for cancelling the remaining back-order.'; END IF;

  FOR v_item IN SELECT oi.id, oi.product_name FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id LOOP
    v_out := public.order_item_backorder_outstanding(v_item.id);
    IF v_out > 0 THEN
      INSERT INTO public.order_backorder_cancellations(order_id, order_item_id, quantity, reason, cancelled_side, cancelled_by)
      VALUES (p_order_id, v_item.id, v_out, left(v_reason, 500), v_side, auth.uid());
      v_units := v_units + v_out;
      v_names := COALESCE(v_names || ', ', '') || v_item.product_name;
    END IF;
  END LOOP;
  IF v_units = 0 THEN RAISE EXCEPTION 'Nothing is waiting to be shipped on this order.'; END IF;

  SELECT name INTO v_actor_name FROM public.businesses WHERE id = CASE v_side WHEN 'wholesaler' THEN v_order.wholesaler_id ELSE v_order.pharmacy_id END;
  PERFORM public.record_order_event(p_order_id, 'backorder_cancelled', v_side,
    format('The remaining back-order (%s unit(s)) was cancelled by the %s.', v_units, v_side),
    jsonb_build_object('reason', left(v_reason, 500), 'units', v_units));
  PERFORM public.write_audit_log('Back-order cancelled', v_actor_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('reason', left(v_reason, 500), 'units', v_units, 'products', v_names),
    _business_id => CASE v_side WHEN 'wholesaler' THEN v_order.wholesaler_id ELSE v_order.pharmacy_id END);
  v_other := CASE v_side WHEN 'wholesaler' THEN v_order.pharmacy_id ELSE v_order.wholesaler_id END;
  v_roles := CASE v_side WHEN 'wholesaler' THEN ARRAY['owner', 'manager', 'cashier'] ELSE ARRAY['owner', 'manager', 'cashier', 'warehouse'] END;
  BEGIN
    PERFORM public.notify_business(v_other, v_roles, 'order_amendment', 'Back-order cancelled',
      format('Order #%s: the remaining back-order (%s unit(s)) was cancelled by %s. Reason: %s', v_order.order_number, v_units,
             COALESCE(v_actor_name, 'the other party'), left(v_reason, 200)),
      CASE v_side WHEN 'wholesaler' THEN '/pharmacy?tab=orders' ELSE '/wholesaler?tab=orders' END,
      jsonb_build_object('order_id', p_order_id, 'order_number', v_order.order_number));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'back-order notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('order_id', p_order_id, 'cancelled_units', v_units);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_backorder_remaining(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_backorder_remaining(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- get_order_backorder: the back-order picture of one order, for both parties
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_order_backorder(p_order_id UUID)
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
  SELECT o.id, o.pharmacy_id, o.wholesaler_id, o.is_credit_order INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF public.can_act_for_business(v_order.wholesaler_id, 'read') THEN v_side := 'wholesaler';
  ELSIF public.can_act_for_business(v_order.pharmacy_id, 'read') THEN v_side := 'pharmacy';
  ELSIF public.has_role(auth.uid(), 'admin') THEN v_side := 'admin';
  ELSE RAISE EXCEPTION 'You do not have access to this order.';
  END IF;
  RETURN jsonb_build_object(
    'state', public.order_backorder_state(p_order_id),
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'order_item_id', oi.id, 'product_name', oi.product_name, 'unit_price_ghs', oi.unit_price_ghs,
        'backordered', public.order_item_backordered_qty(oi.id),
        'sent', public.order_item_shipment_qty(oi.id, TRUE),
        'planned', public.order_item_shipment_qty(oi.id, FALSE) - public.order_item_shipment_qty(oi.id, TRUE),
        'cancelled', COALESCE((SELECT SUM(c.quantity) FROM public.order_backorder_cancellations c WHERE c.order_item_id = oi.id), 0),
        'outstanding', public.order_item_backorder_outstanding(oi.id)) ORDER BY oi.id)
      FROM public.order_items oi WHERE oi.order_id = p_order_id AND public.order_item_backordered_qty(oi.id) > 0), '[]'::JSONB),
    'shipments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'sequence', s.sequence, 'status', s.status, 'amount', s.amount_ghs, 'note', s.note,
        'created_at', s.created_at, 'packed_at', s.packed_at, 'dispatched_at', s.dispatched_at, 'delivered_at', s.delivered_at,
        'cancelled_at', s.cancelled_at, 'cancel_reason', s.cancel_reason, 'credit_due_date', s.credit_due_date,
        'lines', (SELECT jsonb_agg(jsonb_build_object('order_item_id', sl.order_item_id, 'product_name', sl.product_name,
            'quantity', sl.quantity, 'unit_price_ghs', sl.unit_price_ghs) ORDER BY sl.product_name, sl.id)
          FROM public.order_shipment_lines sl WHERE sl.shipment_id = s.id)) ORDER BY s.sequence)
      FROM public.order_shipments s WHERE s.order_id = p_order_id), '[]'::JSONB)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_order_backorder(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_backorder(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- order_supply_summary: also carries the main shipment's own total and the back-order state
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.order_supply_summary(UUID[]);
CREATE FUNCTION public.order_supply_summary(p_order_ids UUID[])
RETURNS TABLE(order_id UUID, current_total_ghs NUMERIC, main_total_ghs NUMERIC, has_open_amendment BOOLEAN, backorder JSONB, lines JSONB)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.id, COALESCE(o.effective_total_ghs, o.total_ghs),
    COALESCE(o.effective_total_ghs, o.total_ghs)
      - COALESCE((SELECT SUM(s.amount_ghs) FROM public.order_shipments s WHERE s.order_id = o.id AND s.status IN ('dispatched', 'delivered')), 0),
    EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = o.id AND a.status IN ('proposed', 'clarification_requested')),
    public.order_backorder_state(o.id),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'product_id', oi.product_id, 'ordered_qty', oi.quantity,
        'supplied_qty', public.order_item_supplied_qty(oi.id), 'fulfilled_qty', public.order_item_fulfilled_qty(oi.id)) ORDER BY oi.id)
      FROM public.order_items oi WHERE oi.order_id = o.id), '[]'::JSONB)
  FROM public.orders o
  WHERE o.id = ANY (p_order_ids) AND auth.uid() IS NOT NULL
    AND (o.effective_total_ghs IS NOT NULL OR EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = o.id))
    AND (public.can_act_for_business(o.wholesaler_id, 'read') OR public.can_act_for_business(o.pharmacy_id, 'read')
         OR public.has_role(auth.uid(), 'admin'))
$$;
REVOKE ALL ON FUNCTION public.order_supply_summary(UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_supply_summary(UUID[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cancelling an order closes its back-order: nothing will be shipped, and nobody has to remember to say so.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_backorder_on_order_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_out INTEGER;
  v_units INTEGER := 0;
BEGIN
  FOR v_item IN SELECT oi.id FROM public.order_items oi WHERE oi.order_id = NEW.id LOOP
    v_out := public.order_item_backorder_outstanding(v_item.id);
    IF v_out > 0 THEN
      INSERT INTO public.order_backorder_cancellations(order_id, order_item_id, quantity, reason, cancelled_side, cancelled_by)
      VALUES (NEW.id, v_item.id, v_out, 'The order was cancelled', 'system', auth.uid());
      v_units := v_units + v_out;
    END IF;
  END LOOP;
  IF v_units > 0 THEN
    PERFORM public.record_order_event(NEW.id, 'backorder_cancelled', 'system',
      format('The order was cancelled, so the remaining back-order (%s unit(s)) was closed.', v_units), jsonb_build_object('units', v_units));
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_close_backorder_on_order_cancel ON public.orders;
CREATE TRIGGER trg_close_backorder_on_order_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (NEW.status::TEXT = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.close_backorder_on_order_cancel();

-- ---------------------------------------------------------------------------
-- 2. respond_to_amendment  (pharmacy)
-- ---------------------------------------------------------------------------
-- p_choice: 'accept_cancel_remaining' | 'accept_backorder' (credit orders: the rest is shipped later) | 'reject' |
-- 'request_clarification' (a question needs p_note)
CREATE OR REPLACE FUNCTION public.respond_to_amendment(p_amendment_id UUID, p_choice TEXT, p_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_a RECORD;
  v_line RECORD;
  v_ev RECORD;
  v_alloc RECORD;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_pharmacy_name TEXT;
  v_remaining INTEGER;
  v_excess INTEGER;
  v_take INTEGER;
  v_units_released INTEGER := 0;
  v_units_written_off INTEGER := 0;
  v_credit NUMERIC(12,2) := 0;
  v_staff TEXT[] := ARRAY['owner', 'manager', 'cashier', 'warehouse'];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_choice IS NULL OR p_choice NOT IN ('accept_cancel_remaining', 'accept_backorder', 'reject', 'request_clarification') THEN
    RAISE EXCEPTION 'Unsupported response.';
  END IF;

  SELECT a.order_id INTO v_order_id FROM public.order_amendments a WHERE a.id = p_amendment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal not found.'; END IF;
  -- Lock order first, then the proposal (the same order every function uses).
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.is_credit_order
  INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_a FROM public.order_amendments a WHERE a.id = p_amendment_id FOR UPDATE;

  IF NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to respond to this proposal.';
  END IF;
  IF v_a.kind <> 'partial_fulfilment' THEN RAISE EXCEPTION 'Unsupported proposal type.'; END IF;
  IF p_choice = 'accept_backorder' AND NOT v_order.is_credit_order THEN
    RAISE EXCEPTION 'Back-orders are only available on credit orders for now. Accept and cancel the rest, or reject.';
  END IF;

  -- Already answered: repeating the same answer is a no-op, a different answer is refused.
  IF v_a.status IN ('accepted', 'rejected', 'withdrawn') THEN
    IF v_a.response_choice = p_choice THEN
      RETURN jsonb_build_object('amendment_id', v_a.id, 'status', v_a.status, 'replayed', TRUE);
    END IF;
    RAISE EXCEPTION 'This proposal has already been %.', v_a.status;
  END IF;
  IF v_a.status = 'clarification_requested' THEN
    IF p_choice = 'request_clarification' AND v_note IS NOT NULL THEN
      -- A further question while waiting is just another message.
      INSERT INTO public.order_amendment_messages(amendment_id, order_id, author_side, author_id, message)
      VALUES (v_a.id, v_order_id, 'pharmacy', auth.uid(), left(v_note, 500));
      RETURN jsonb_build_object('amendment_id', v_a.id, 'status', v_a.status, 'replayed', FALSE);
    END IF;
    RAISE EXCEPTION 'You asked a question; the wholesaler must reply before you can decide.';
  END IF;
  IF v_order.status NOT IN ('accepted', 'picking', 'packed', 'ready_for_dispatch') THEN
    RAISE EXCEPTION 'This order is no longer being prepared; the proposal can no longer be applied.';
  END IF;

  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;

  -- ----- request clarification -------------------------------------------------------------------------------------
  IF p_choice = 'request_clarification' THEN
    IF v_note IS NULL OR char_length(v_note) < 3 THEN RAISE EXCEPTION 'Write your question for the wholesaler.'; END IF;
    INSERT INTO public.order_amendment_messages(amendment_id, order_id, author_side, author_id, message)
    VALUES (v_a.id, v_order_id, 'pharmacy', auth.uid(), left(v_note, 500));
    UPDATE public.order_amendments SET status = 'clarification_requested', response_choice = 'request_clarification',
      responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
    PERFORM public.record_order_event(v_order_id, 'amendment_clarification_requested', 'pharmacy',
      'The pharmacy asked a question about the proposed supply change.', jsonb_build_object('message', left(v_note, 500)), v_a.id);
    PERFORM public.write_audit_log('Order supply change question asked', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('amendment_id', v_a.id, 'message', left(v_note, 500)), _business_id => v_order.pharmacy_id);
    BEGIN
      PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'The pharmacy asked a question',
        format('Order #%s: %s', v_order.order_number, left(v_note, 200)), '/wholesaler?tab=orders',
        jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'clarification_requested', 'replayed', FALSE);
  END IF;

  -- ----- reject ------------------------------------------------------------------------------------------------------
  IF p_choice = 'reject' THEN
    UPDATE public.order_amendments SET status = 'rejected', response_choice = 'reject', response_note = left(v_note, 500),
      responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
    PERFORM public.record_order_event(v_order_id, 'amendment_rejected', 'pharmacy',
      'The pharmacy rejected the proposed supply change. The order stands as placed.',
      jsonb_build_object('note', left(v_note, 500)), v_a.id);
    PERFORM public.write_audit_log('Order supply change rejected', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('amendment_id', v_a.id, 'note', left(v_note, 500)), _business_id => v_order.pharmacy_id);
    BEGIN
      PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'Supply change rejected',
        format('Order #%s: the pharmacy rejected the reduced supply. Supply the full order, cancel it, or propose again.', v_order.order_number),
        '/wholesaler?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'rejected', 'replayed', FALSE);
  END IF;

  -- ----- accept and cancel the remaining quantity ----------------------------------------------------------------------
  -- 1. Stock, per line, products in id order so concurrent sessions lock in the same order.
  FOR v_line IN
    SELECT l.* FROM public.order_amendment_lines l WHERE l.amendment_id = v_a.id AND l.short_qty > 0 ORDER BY l.product_id
  LOOP
    IF v_line.stock_treatment IN ('release', 'write_off') THEN
      PERFORM 1 FROM public.products p WHERE p.id = v_line.product_id AND p.wholesaler_id = v_order.wholesaler_id FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'The product for % no longer belongs to the supplier.', v_line.product_name; END IF;
      SELECT d.quantity, d.restored_at INTO v_ev FROM public.order_stock_deductions d
      WHERE d.order_id = v_order_id AND d.product_id = v_line.product_id FOR UPDATE;
      IF NOT FOUND OR v_ev.restored_at IS NOT NULL THEN
        RAISE EXCEPTION 'The stock for % is no longer held for this order; reconcile it manually.', v_line.product_name;
      END IF;
      v_remaining := v_ev.quantity - public.order_amendment_stock_taken(v_order_id, v_line.product_id);
      IF v_remaining < v_line.short_qty THEN
        RAISE EXCEPTION 'Only % unit(s) of % are still held for this order; the shortage is %.', v_remaining, v_line.product_name, v_line.short_qty;
      END IF;
      IF v_line.stock_treatment = 'release' THEN
        INSERT INTO public.inventory_operation_context(transaction_id, actor_id, movement_type, order_id, request_id, reason)
        VALUES (txid_current(), v_a.proposed_by, 'order_amendment_release', v_order_id, v_a.id,
                'Partial fulfilment approved by the pharmacy: ' || left(v_a.reason, 200));
        UPDATE public.products SET stock = stock + v_line.short_qty WHERE id = v_line.product_id AND wholesaler_id = v_order.wholesaler_id;
        DELETE FROM public.inventory_operation_context WHERE transaction_id = txid_current();
        v_units_released := v_units_released + v_line.short_qty;
      ELSE
        v_units_written_off := v_units_written_off + v_line.short_qty;
      END IF;
      INSERT INTO public.order_stock_movements(order_id, amendment_id, order_item_id, product_id, wholesaler_id, kind, quantity, stock_effect, created_by)
      VALUES (v_order_id, v_a.id, v_line.order_item_id, v_line.product_id, v_order.wholesaler_id,
              CASE v_line.stock_treatment WHEN 'release' THEN 'shortage_release' ELSE 'shortage_write_off' END,
              v_line.short_qty, CASE v_line.stock_treatment WHEN 'release' THEN v_line.short_qty ELSE 0 END, auth.uid());

      -- 2. Batches: take the surplus allocation off the latest-expiring batches first. Released units go back to the batch;
      --    written-off units do not exist, so the batch stays reduced and a write-off movement records it.
      SELECT COALESCE(SUM(a.quantity), 0) - v_line.supplied_qty INTO v_excess
      FROM public.order_batch_allocations a WHERE a.order_item_id = v_line.order_item_id;
      IF v_excess > 0 THEN
        FOR v_alloc IN
          SELECT a.id, a.batch_id, a.quantity, b.product_id AS b_product, b.wholesaler_id AS b_wholesaler
          FROM public.order_batch_allocations a JOIN public.product_batches b ON b.id = a.batch_id
          WHERE a.order_item_id = v_line.order_item_id ORDER BY b.expiry_date DESC, a.batch_id DESC FOR UPDATE OF b
        LOOP
          EXIT WHEN v_excess <= 0;
          v_take := LEAST(v_alloc.quantity, v_excess);
          IF v_line.stock_treatment = 'release' THEN
            UPDATE public.product_batches SET quantity_on_hand = LEAST(quantity_on_hand + v_take, quantity_received) WHERE id = v_alloc.batch_id;
            INSERT INTO public.batch_movements(batch_id, product_id, wholesaler_id, kind, quantity, order_id, created_by)
            VALUES (v_alloc.batch_id, v_alloc.b_product, v_alloc.b_wholesaler, 'released', v_take, v_order_id, auth.uid());
          ELSE
            INSERT INTO public.batch_movements(batch_id, product_id, wholesaler_id, kind, quantity, order_id, reason, note, created_by)
            VALUES (v_alloc.batch_id, v_alloc.b_product, v_alloc.b_wholesaler, 'write_off', v_take, v_order_id, 'other',
                    'Order #' || v_order.order_number || ' shortage: units do not exist', auth.uid());
          END IF;
          IF v_take = v_alloc.quantity THEN
            DELETE FROM public.order_batch_allocations WHERE id = v_alloc.id;
          ELSE
            UPDATE public.order_batch_allocations SET quantity = quantity - v_take WHERE id = v_alloc.id;
          END IF;
          v_excess := v_excess - v_take;
        END LOOP;
      END IF;
    END IF;
  END LOOP;

  -- 3. Money. total_ghs is untouched; the effective total carries the amended figure.
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = v_a.proposed_total_ghs WHERE id = v_order_id;
  IF v_order.is_credit_order AND v_a.delta_ghs < 0 THEN
    v_credit := -v_a.delta_ghs;
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, amendment_id)
    VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'credit_note', 'credit', v_credit, auth.uid(),
            CASE WHEN p_choice = 'accept_backorder' THEN 'Supply reduced by agreement (proposal ' || v_a.version || '); remaining quantity placed on back-order'
                 ELSE 'Supply reduced by agreement (proposal ' || v_a.version || '); remaining quantity cancelled' END, v_a.id);
  END IF;

  -- 4. The proposal itself.
  UPDATE public.order_amendments SET status = 'accepted', response_choice = p_choice, response_note = left(v_note, 500),
    responded_by = auth.uid(), responded_at = now(), applied_at = now() WHERE id = v_a.id;

  PERFORM public.record_order_event(v_order_id, 'amendment_accepted', 'pharmacy',
    CASE WHEN p_choice = 'accept_backorder'
      THEN format('The pharmacy accepted the reduced supply and asked for the rest on back-order. The order total is now %s (was %s); the back-ordered goods are invoiced when each shipment is dispatched.',
                  public._amendment_money(v_a.proposed_total_ghs), public._amendment_money(v_a.original_total_ghs))
      ELSE format('The pharmacy accepted the reduced supply and cancelled the remaining quantity. The order total is now %s (was %s).',
                  public._amendment_money(v_a.proposed_total_ghs), public._amendment_money(v_a.original_total_ghs)) END,
    jsonb_build_object('original_total', v_a.original_total_ghs, 'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500), 'choice', p_choice), v_a.id);
  PERFORM public.write_audit_log('Order supply change accepted', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'original_total', v_a.original_total_ghs,
                       'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500), 'choice', p_choice), _business_id => v_order.pharmacy_id);
  PERFORM public.write_audit_log('Order supply change applied', (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id),
    'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'new_total', v_a.proposed_total_ghs, 'credit_note_ghs', v_credit,
                       'units_released_to_stock', v_units_released, 'units_written_off', v_units_written_off),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'Supply change accepted',
      CASE WHEN p_choice = 'accept_backorder'
      THEN format('Order #%s: the pharmacy accepted the reduced supply and wants the rest on back-order. New total %s. Dispatch can continue; ship the rest when it is ready.', v_order.order_number, public._amendment_money(v_a.proposed_total_ghs))
      ELSE format('Order #%s: the pharmacy accepted the reduced supply. New total %s. Dispatch can continue.', v_order.order_number, public._amendment_money(v_a.proposed_total_ghs)) END,
      '/wholesaler?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;

  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'accepted', 'replayed', FALSE,
    'new_total', v_a.proposed_total_ghs, 'units_released_to_stock', v_units_released, 'units_written_off', v_units_written_off);
END;
$$;
REVOKE ALL ON FUNCTION public.respond_to_amendment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_amendment(UUID, TEXT, TEXT) TO authenticated;

