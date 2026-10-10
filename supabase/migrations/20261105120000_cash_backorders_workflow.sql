-- Order amendments, Phase 3b part 3: the cash-order back-order workflow.
--
--   * advance_backorder_shipment now also dispatches the shipments of a CASH (pay on delivery) order. There is no credit line, no
--     override and no ledger entry for them; the shipment is added to the order's effective total, and an order that had been
--     paid is reopened (the main delivery's collection is recorded first, so it is never asked for twice).
--   * confirm_cash_collection(order, shipment?) records that the cash for one portion was received: the main delivery (once it is
--     delivered) or one back-order shipment (once it is delivered). The order becomes paid when every portion that has gone out is
--     collected. cash_collection_receipt() and mark_collection_receipt_sent() serve the receipt endpoints.
--   * Guard: such an order cannot be marked paid by a direct update (only by confirm_cash_collection). A collected order is
--     delivered, and a delivered order can no longer be cancelled, so no separate cancellation guard is needed.

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
    -- 1. A credit order: the customer's credit line is locked, then re-checked exactly as checkout does. (A cash order has no credit
    --    line; it is collected shipment by shipment.)
    IF v_order.is_credit_order THEN
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
    IF v_order.is_credit_order AND v_s.amount_ghs > 0 THEN
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
    IF NOT v_order.is_credit_order AND v_order.payment_status = 'paid' AND v_s.amount_ghs > 0
       AND NOT EXISTS (SELECT 1 FROM public.order_collections c WHERE c.order_id = v_order_id AND c.shipment_id IS NULL) THEN
      -- The main delivery was collected before this shipment existed: record that, so it is never asked for twice.
      INSERT INTO public.order_collections(order_id, shipment_id, amount_ghs, confirmed_by, confirmed_at)
      SELECT v_order_id, NULL, public.order_main_total(v_order_id), o.payment_confirmed_by, COALESCE(o.payment_confirmed_at, o.paid_at, now())
      FROM public.orders o WHERE o.id = v_order_id;
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
-- Who may confirm that cash was received: the wholesaler's owner, or active staff other than the assistant and the warehouse
-- (the same people the existing confirm-payment endpoint allows).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._can_collect_cash(p_wholesaler_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid())
    OR (public.is_business_staff(auth.uid(), p_wholesaler_id)
        AND public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT NOT IN ('assistant', 'warehouse'))
$$;
REVOKE ALL ON FUNCTION public._can_collect_cash(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- confirm_cash_collection: the cash for ONE portion of a back-ordered cash order has been received.
--   p_shipment_id NULL = the main delivery (the order must be delivered); otherwise a back-order shipment (it must be delivered).
-- One collection per portion (the unique indexes refuse a second; a repeat returns the first). The order's own payment status
-- becomes 'paid' only when the main delivery and every dispatched shipment are collected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_cash_collection(p_order_id UUID, p_shipment_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_s RECORD;
  v_existing RECORD;
  v_amount NUMERIC(12,2);
  v_collection_id UUID;
  v_complete BOOLEAN;
  v_label TEXT;
  v_name TEXT;
  v_seq INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.is_credit_order, o.payment_status::TEXT AS payment_status
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public._can_collect_cash(v_order.wholesaler_id) THEN
    RAISE EXCEPTION 'Only the wholesaler owner or active order-processing staff can confirm payment.';
  END IF;
  IF NOT public.order_has_cash_portions(p_order_id) THEN
    RAISE EXCEPTION 'This order is paid as one amount: confirm payment on the order itself.';
  END IF;

  IF p_shipment_id IS NULL THEN
    SELECT c.* INTO v_existing FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL;
    IF FOUND THEN
      RETURN jsonb_build_object('collection_id', v_existing.id, 'portion', 'main', 'amount', v_existing.amount_ghs, 'replayed', TRUE,
                                'order_paid', v_order.payment_status = 'paid');
    END IF;
    IF v_order.status <> 'delivered' THEN
      RAISE EXCEPTION 'Mark this order as delivered before confirming payment for the main delivery.';
    END IF;
    v_amount := public.order_main_total(p_order_id);
    v_label := 'the main delivery';
  ELSE
    SELECT s.* INTO v_s FROM public.order_shipments s WHERE s.id = p_shipment_id AND s.order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'That shipment does not belong to this order.'; END IF;
    SELECT c.* INTO v_existing FROM public.order_collections c WHERE c.shipment_id = p_shipment_id;
    IF FOUND THEN
      RETURN jsonb_build_object('collection_id', v_existing.id, 'portion', 'shipment', 'shipment_id', p_shipment_id, 'sequence', v_s.sequence,
                                'amount', v_existing.amount_ghs, 'replayed', TRUE, 'order_paid', v_order.payment_status = 'paid');
    END IF;
    IF v_s.status <> 'delivered' THEN
      RAISE EXCEPTION 'Mark shipment % as delivered before confirming payment for it.', v_s.sequence;
    END IF;
    v_amount := public.order_shipment_net(p_shipment_id);
    v_seq := v_s.sequence;
    v_label := format('back-order shipment %s', v_s.sequence);
  END IF;

  INSERT INTO public.order_collections(order_id, shipment_id, amount_ghs, confirmed_by)
  VALUES (p_order_id, p_shipment_id, v_amount, auth.uid())
  RETURNING id INTO v_collection_id;

  -- The order is paid when the main delivery and every shipment that has gone out are collected.
  v_complete := EXISTS (SELECT 1 FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL)
    AND NOT EXISTS (
      SELECT 1 FROM public.order_shipments s
      WHERE s.order_id = p_order_id AND s.status IN ('dispatched', 'delivered')
        AND NOT EXISTS (SELECT 1 FROM public.order_collections c WHERE c.shipment_id = s.id));
  IF v_complete THEN
    PERFORM public._allow_order_total_change();
    UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = auth.uid()
    WHERE id = p_order_id;
  END IF;

  SELECT name INTO v_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.record_order_event(p_order_id, 'payment_confirmed', 'wholesaler',
    format('Payment of %s received for %s.', public._amendment_money(v_amount), v_label),
    jsonb_build_object('amount', v_amount, 'shipment_id', p_shipment_id, 'order_paid', v_complete), NULL, p_shipment_id);
  PERFORM public.write_audit_log('Cash payment confirmed', v_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('collection_id', v_collection_id, 'portion', CASE WHEN p_shipment_id IS NULL THEN 'main' ELSE 'shipment' END,
                       'shipment_id', p_shipment_id, 'amount', v_amount, 'order_paid', v_complete),
    _business_id => v_order.wholesaler_id);
  IF NOT v_complete THEN
    -- Marking the whole order paid notifies the pharmacy by itself; a part-payment needs its own message.
    BEGIN
      PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Payment received',
        format('Order #%s: %s received payment of %s for %s.', v_order.order_number, COALESCE(v_name, 'the wholesaler'), public._amendment_money(v_amount), v_label),
        '/pharmacy?tab=orders', jsonb_build_object('order_id', p_order_id, 'order_number', v_order.order_number, 'shipment_id', p_shipment_id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'collection notification failed: %', SQLERRM; END;
  END IF;

  RETURN jsonb_build_object('collection_id', v_collection_id, 'portion', CASE WHEN p_shipment_id IS NULL THEN 'main' ELSE 'shipment' END,
    'shipment_id', p_shipment_id, 'sequence', v_seq, 'amount', v_amount, 'replayed', FALSE, 'order_paid', v_complete);
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_cash_collection(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_cash_collection(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- cash_collection_receipt: what the receipt for one collected portion shows (used by the receipt endpoints, which may run as the
-- signed-in wholesaler user or with the service role). The main delivery's receipt lists what the main delivery supplied and its
-- delivery fee; a shipment's receipt lists the shipment's lines.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cash_collection_receipt(p_order_id UUID, p_shipment_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_c RECORD;
  v_seq INTEGER;
  v_s_delivered TIMESTAMPTZ;
BEGIN
  SELECT o.id, o.order_number, o.wholesaler_id, o.pharmacy_id, o.delivered_at, o.delivery_fee_ghs INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
    IF NOT public._can_collect_cash(v_order.wholesaler_id) THEN
      RAISE EXCEPTION 'Only the wholesaler owner or active order-processing staff can send receipts.';
    END IF;
  END IF;
  IF p_shipment_id IS NULL THEN
    SELECT c.* INTO v_c FROM public.order_collections c WHERE c.order_id = p_order_id AND c.shipment_id IS NULL;
  ELSE
    SELECT c.* INTO v_c FROM public.order_collections c WHERE c.shipment_id = p_shipment_id AND c.order_id = p_order_id;
    SELECT s.sequence, s.delivered_at INTO v_seq, v_s_delivered FROM public.order_shipments s WHERE s.id = p_shipment_id;
  END IF;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'collection_id', v_c.id,
    'order_number', CASE WHEN p_shipment_id IS NULL THEN v_order.order_number ELSE v_order.order_number || ' (shipment ' || v_seq || ')' END,
    'total_ghs', v_c.amount_ghs,
    'delivery_fee_ghs', CASE WHEN p_shipment_id IS NULL THEN v_order.delivery_fee_ghs ELSE 0 END,
    'delivered_at', CASE WHEN p_shipment_id IS NULL THEN v_order.delivered_at ELSE v_s_delivered END,
    'paid_at', v_c.confirmed_at,
    'receipt_sent_at', v_c.receipt_sent_at,
    'receipt_sent_to', v_c.receipt_sent_to,
    'items', CASE WHEN p_shipment_id IS NULL THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('product_name', oi.product_name, 'quantity', public.order_item_supplied_qty(oi.id),
          'unit_price_ghs', public.order_item_effective_price(oi.id)) ORDER BY oi.id)
        FROM public.order_items oi WHERE oi.order_id = p_order_id AND public.order_item_supplied_qty(oi.id) > 0), '[]'::JSONB)
      ELSE COALESCE((
        SELECT jsonb_agg(jsonb_build_object('product_name', sl.product_name, 'quantity', sl.quantity, 'unit_price_ghs', sl.unit_price_ghs) ORDER BY sl.product_name, sl.id)
        FROM public.order_shipment_lines sl WHERE sl.shipment_id = p_shipment_id), '[]'::JSONB) END);
END;
$$;
REVOKE ALL ON FUNCTION public.cash_collection_receipt(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cash_collection_receipt(UUID, UUID) TO authenticated, service_role;

-- Records that a receipt email went out (the only thing that may change on a collection afterwards).
CREATE OR REPLACE FUNCTION public.mark_collection_receipt_sent(p_collection_id UUID, p_email TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wholesaler UUID;
BEGIN
  SELECT o.wholesaler_id INTO v_wholesaler FROM public.order_collections c JOIN public.orders o ON o.id = c.order_id WHERE c.id = p_collection_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found.'; END IF;
  IF auth.role() IS DISTINCT FROM 'service_role' AND NOT public._can_collect_cash(v_wholesaler) THEN
    RAISE EXCEPTION 'Only the wholesaler owner or active order-processing staff can send receipts.';
  END IF;
  UPDATE public.order_collections SET receipt_sent_at = now(), receipt_sent_to = left(btrim(COALESCE(p_email, '')), 320) WHERE id = p_collection_id;
END;
$$;
REVOKE ALL ON FUNCTION public.mark_collection_receipt_sent(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_collection_receipt_sent(UUID, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Guards on the order row
-- ---------------------------------------------------------------------------
-- A cash order that is collected portion by portion is marked paid only by confirm_cash_collection(), never by a direct update.
CREATE OR REPLACE FUNCTION public.guard_cash_portion_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_status::TEXT = 'paid' AND OLD.payment_status::TEXT IS DISTINCT FROM 'paid'
     AND COALESCE(current_setting('drugxone.amendment_txid', true), '') <> txid_current()::TEXT
     AND public.order_has_cash_portions(NEW.id) THEN
    RAISE EXCEPTION 'This order is collected one delivery at a time: confirm payment for the main delivery and for each back-order shipment.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_cash_portion_payment ON public.orders;
CREATE TRIGGER trg_guard_cash_portion_payment
  BEFORE UPDATE OF payment_status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_cash_portion_payment();
