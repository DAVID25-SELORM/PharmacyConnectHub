-- Order amendments, Phase 2 part 3: partial fulfilment (supply less than was ordered, with the pharmacy's approval).
--
-- The flow, enforced here and not only by the screens:
--   1. The wholesaler's order staff (owner, manager, cashier, warehouse) propose a reduced supply on an order that is being
--      prepared (accepted .. ready for dispatch): per product the quantity that can be supplied, what to do with the
--      stock for the shortfall (release it to sellable stock, or write it off because it does not physically exist),
--      and a required reason. The proposal fixes the totals. Nothing else changes yet, and the order cannot be
--      dispatched while a proposal is open.
--   2. The pharmacy's owner, manager or cashier answers: accept (and cancel the rest), reject, or ask a question.
--      Rejecting leaves the order exactly as placed. Asking puts the proposal on hold until the wholesaler replies.
--   3. Accepting applies everything in ONE transaction: the order's effective total, the credit note on a credit order,
--      the stock effect, the batch allocations, the activity log, the audit entries and the notifications. Repeating the
--      same answer changes nothing.
-- orders.total_ghs and the order lines are never edited; the effective total sits beside them.
--
-- Rules fixed by the design review (docs/order-amendments-and-partial-fulfilment.md):
--   * unit prices do not change when quantities fall; the delivery fee is unchanged;
--   * credit orders get one credit note per amendment for the value removed; cash orders have no ledger, their total to
--     collect is the effective total; a non-credit order that is already paid cannot be amended (no refund process yet);
--   * stock is only written for orders with verified deduction evidence; legacy orders get no stock write;
--   * cancelling later restores only what is still deducted (patched in part 2).

-- ---------------------------------------------------------------------------
-- Internal: who is looking (own side shows people by email, the other side by business name)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._amendment_actor_label(p_user_id UUID, p_actor_side TEXT, p_viewer_side TEXT, p_order_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_user_id IS NULL THEN 'System'
    WHEN p_viewer_side = p_actor_side OR p_viewer_side = 'admin'
      THEN (SELECT u.email FROM auth.users u WHERE u.id = p_user_id)
    ELSE (SELECT b.name FROM public.orders o JOIN public.businesses b
          ON b.id = CASE p_actor_side WHEN 'wholesaler' THEN o.wholesaler_id ELSE o.pharmacy_id END
          WHERE o.id = p_order_id)
  END
$$;
REVOKE ALL ON FUNCTION public._amendment_actor_label(UUID, TEXT, TEXT, UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._amendment_money(p_amount NUMERIC)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$ SELECT 'GHS ' || to_char(p_amount, 'FM999,999,990.00') $$;
REVOKE ALL ON FUNCTION public._amendment_money(NUMERIC) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. propose_partial_fulfilment
-- ---------------------------------------------------------------------------
-- p_lines: [{"order_item_id": uuid, "supplied_qty": int, "stock_treatment": "release"|"write_off", "note": text?}, ...]
-- Lines left out are supplied as before. Safe to repeat with the same p_request_id.
CREATE OR REPLACE FUNCTION public.propose_partial_fulfilment(
  p_order_id UUID,
  p_reason TEXT,
  p_lines JSONB,
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
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_has_evidence BOOLEAN;
  v_item RECORD;
  v_el JSONB;
  v_supplied INTEGER;
  v_short INTEGER;
  v_treatment TEXT;
  v_note TEXT;
  v_lines JSONB := '[]'::JSONB;
  v_short_lines INTEGER := 0;
  v_short_units INTEGER := 0;
  v_short_value NUMERIC(12,2) := 0;
  v_supplied_total INTEGER := 0;
  v_original NUMERIC(12,2);
  v_proposed NUMERIC(12,2);
  v_version INTEGER;
  v_amendment_id UUID;
  v_wholesaler_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A request id is required.'; END IF;

  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.total_ghs, o.effective_total_ghs,
         o.is_credit_order, o.payment_status::TEXT AS payment_status
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to propose a supply change on this order.';
  END IF;

  -- Repeating the same request returns the same proposal.
  SELECT a.id, a.version, a.status INTO v_existing FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.request_id = p_request_id;
  IF FOUND THEN
    RETURN jsonb_build_object('amendment_id', v_existing.id, 'version', v_existing.version, 'status', v_existing.status, 'replayed', TRUE);
  END IF;

  IF v_order.status NOT IN ('accepted', 'picking', 'packed', 'ready_for_dispatch') THEN
    RAISE EXCEPTION 'Supply can only be changed while the order is being prepared (accepted up to ready for dispatch).';
  END IF;
  IF NOT v_order.is_credit_order AND v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'This order has already been paid. Changing it needs a refund, which is not supported yet; contact support.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.status IN ('proposed', 'clarification_requested')) THEN
    RAISE EXCEPTION 'A supply change is already awaiting a response on this order. Withdraw it first.';
  END IF;
  IF char_length(v_reason) < 3 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason for the shortage is required (3 to 500 characters).';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Say which products will be supplied in a smaller quantity.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) e
    WHERE NOT EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = p_order_id AND oi.id::TEXT = e->>'order_item_id')
  ) THEN
    RAISE EXCEPTION 'A line does not belong to this order.';
  END IF;
  IF (SELECT count(DISTINCT e->>'order_item_id') FROM jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'Each product can appear only once.';
  END IF;

  v_has_evidence := public.order_has_stock_evidence(p_order_id);

  FOR v_item IN
    SELECT oi.id, oi.product_id, oi.product_name, oi.quantity, oi.unit_price_ghs, public.order_item_supplied_qty(oi.id) AS prior_qty
    FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id
  LOOP
    SELECT e INTO v_el FROM jsonb_array_elements(p_lines) e WHERE e->>'order_item_id' = v_item.id::TEXT LIMIT 1;
    v_supplied := v_item.prior_qty;
    v_treatment := 'none';
    v_note := NULL;
    IF v_el IS NOT NULL THEN
      IF COALESCE(v_el->>'supplied_qty', '') !~ '^[0-9]{1,9}$' THEN
        RAISE EXCEPTION 'The quantity to supply for % must be a whole number.', v_item.product_name;
      END IF;
      v_supplied := (v_el->>'supplied_qty')::INTEGER;
      IF v_supplied > v_item.prior_qty THEN
        RAISE EXCEPTION 'You cannot supply more of % (%) than is currently committed (%).', v_item.product_name, v_supplied, v_item.prior_qty;
      END IF;
      v_note := NULLIF(left(btrim(COALESCE(v_el->>'note', '')), 300), '');
      IF v_supplied < v_item.prior_qty AND v_has_evidence THEN
        v_treatment := COALESCE(v_el->>'stock_treatment', '');
        IF v_treatment NOT IN ('release', 'write_off') THEN
          RAISE EXCEPTION 'Say what happens to the stock for % : release it to stock, or write it off.', v_item.product_name;
        END IF;
      END IF;
    END IF;
    v_short := v_item.prior_qty - v_supplied;
    IF v_short > 0 THEN
      v_short_lines := v_short_lines + 1;
      v_short_units := v_short_units + v_short;
      v_short_value := v_short_value + round(v_short * v_item.unit_price_ghs, 2);
    END IF;
    v_supplied_total := v_supplied_total + v_supplied;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'order_item_id', v_item.id, 'product_id', v_item.product_id, 'product_name', v_item.product_name,
      'ordered_qty', v_item.quantity, 'prior_supplied_qty', v_item.prior_qty, 'supplied_qty', v_supplied, 'short_qty', v_short,
      'unit_price_ghs', v_item.unit_price_ghs, 'stock_treatment', v_treatment, 'note', v_note));
  END LOOP;

  IF v_short_lines = 0 THEN RAISE EXCEPTION 'Nothing is being reduced. Enter a smaller quantity for at least one product.'; END IF;
  IF v_supplied_total = 0 THEN
    RAISE EXCEPTION 'Supplying nothing is a cancellation. Cancel the order instead of proposing a partial supply.';
  END IF;

  v_original := COALESCE(v_order.effective_total_ghs, v_order.total_ghs);
  v_proposed := v_original - v_short_value;
  IF v_proposed < 0 THEN RAISE EXCEPTION 'The proposed total cannot be negative.'; END IF;

  SELECT COALESCE(max(a.version), 0) + 1 INTO v_version FROM public.order_amendments a WHERE a.order_id = p_order_id;
  INSERT INTO public.order_amendments(order_id, version, kind, status, reason, proposed_by, original_total_ghs, proposed_total_ghs,
                                      delta_ghs, stock_mode, request_id)
  VALUES (p_order_id, v_version, 'partial_fulfilment', 'proposed', v_reason, auth.uid(), v_original, v_proposed,
          v_proposed - v_original, CASE WHEN v_has_evidence THEN 'evidence' ELSE 'none' END, p_request_id)
  RETURNING id INTO v_amendment_id;

  INSERT INTO public.order_amendment_lines(amendment_id, order_item_id, product_id, product_name, ordered_qty, prior_supplied_qty,
                                           supplied_qty, short_qty, unit_price_ghs, stock_treatment, note)
  SELECT v_amendment_id, (l->>'order_item_id')::UUID, (l->>'product_id')::UUID, l->>'product_name', (l->>'ordered_qty')::INTEGER,
         (l->>'prior_supplied_qty')::INTEGER, (l->>'supplied_qty')::INTEGER, (l->>'short_qty')::INTEGER,
         (l->>'unit_price_ghs')::NUMERIC, l->>'stock_treatment', l->>'note'
  FROM jsonb_array_elements(v_lines) l;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.record_order_event(p_order_id, 'amendment_proposed', 'wholesaler',
    format('Partial supply proposed: %s unit(s) short on %s line(s); the order total would change from %s to %s.',
           v_short_units, v_short_lines, public._amendment_money(v_original), public._amendment_money(v_proposed)),
    jsonb_build_object('reason', v_reason, 'original_total', v_original, 'proposed_total', v_proposed, 'version', v_version),
    v_amendment_id);
  PERFORM public.write_audit_log('Order supply change proposed', v_wholesaler_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_amendment_id, 'version', v_version, 'reason', v_reason, 'lines_short', v_short_lines,
                       'units_short', v_short_units, 'original_total', v_original, 'proposed_total', v_proposed),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment',
      'Supply change needs your decision',
      format('%s cannot supply all of order #%s. Reason: %s. Review and accept, reject or ask a question.', COALESCE(v_wholesaler_name, 'The wholesaler'), v_order.order_number, v_reason),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', p_order_id, 'order_number', v_order.order_number, 'amendment_id', v_amendment_id));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'amendment notification failed: %', SQLERRM;
  END;

  RETURN jsonb_build_object('amendment_id', v_amendment_id, 'version', v_version, 'status', 'proposed', 'replayed', FALSE,
    'original_total', v_original, 'proposed_total', v_proposed, 'delta', v_proposed - v_original);
END;
$$;
REVOKE ALL ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. respond_to_amendment  (pharmacy)
-- ---------------------------------------------------------------------------
-- p_choice: 'accept_cancel_remaining' | 'reject' | 'request_clarification' (a question needs p_note)
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
  IF p_choice IS NULL OR p_choice NOT IN ('accept_cancel_remaining', 'reject', 'request_clarification') THEN
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
  UPDATE public.orders SET effective_total_ghs = v_a.proposed_total_ghs WHERE id = v_order_id;
  IF v_order.is_credit_order AND v_a.delta_ghs < 0 THEN
    v_credit := -v_a.delta_ghs;
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, amendment_id)
    VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'credit_note', 'credit', v_credit, auth.uid(),
            'Supply reduced by agreement (proposal ' || v_a.version || '); remaining quantity cancelled', v_a.id);
  END IF;

  -- 4. The proposal itself.
  UPDATE public.order_amendments SET status = 'accepted', response_choice = 'accept_cancel_remaining', response_note = left(v_note, 500),
    responded_by = auth.uid(), responded_at = now(), applied_at = now() WHERE id = v_a.id;

  PERFORM public.record_order_event(v_order_id, 'amendment_accepted', 'pharmacy',
    format('The pharmacy accepted the reduced supply and cancelled the remaining quantity. The order total is now %s (was %s).',
           public._amendment_money(v_a.proposed_total_ghs), public._amendment_money(v_a.original_total_ghs)),
    jsonb_build_object('original_total', v_a.original_total_ghs, 'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500)), v_a.id);
  PERFORM public.write_audit_log('Order supply change accepted', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'original_total', v_a.original_total_ghs,
                       'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500)), _business_id => v_order.pharmacy_id);
  PERFORM public.write_audit_log('Order supply change applied', (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id),
    'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'new_total', v_a.proposed_total_ghs, 'credit_note_ghs', v_credit,
                       'units_released_to_stock', v_units_released, 'units_written_off', v_units_written_off),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'Supply change accepted',
      format('Order #%s: the pharmacy accepted the reduced supply. New total %s. Dispatch can continue.', v_order.order_number,
             public._amendment_money(v_a.proposed_total_ghs)),
      '/wholesaler?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;

  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'accepted', 'replayed', FALSE,
    'new_total', v_a.proposed_total_ghs, 'units_released_to_stock', v_units_released, 'units_written_off', v_units_written_off);
END;
$$;
REVOKE ALL ON FUNCTION public.respond_to_amendment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_amendment(UUID, TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. answer_amendment_clarification / withdraw_amendment  (wholesaler)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.answer_amendment_clarification(p_amendment_id UUID, p_message TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_a RECORD;
  v_message TEXT := btrim(COALESCE(p_message, ''));
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT a.order_id INTO v_order_id FROM public.order_amendments a WHERE a.id = p_amendment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal not found.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_a FROM public.order_amendments a WHERE a.id = p_amendment_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to reply on this order.';
  END IF;
  IF v_a.status <> 'clarification_requested' THEN
    RAISE EXCEPTION 'There is no open question on this proposal.';
  END IF;
  IF char_length(v_message) < 1 THEN RAISE EXCEPTION 'Write your reply.'; END IF;

  INSERT INTO public.order_amendment_messages(amendment_id, order_id, author_side, author_id, message)
  VALUES (v_a.id, v_order_id, 'wholesaler', auth.uid(), left(v_message, 500));
  UPDATE public.order_amendments SET status = 'proposed', response_choice = NULL, responded_by = NULL, responded_at = NULL WHERE id = v_a.id;
  PERFORM public.record_order_event(v_order_id, 'amendment_clarification_answered', 'wholesaler',
    'The wholesaler replied to the pharmacy''s question. The proposal awaits the pharmacy''s decision.',
    jsonb_build_object('message', left(v_message, 500)), v_a.id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment', 'The wholesaler replied',
      format('Order #%s: %s', v_order.order_number, left(v_message, 200)), '/pharmacy?tab=orders',
      jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'proposed');
END;
$$;
REVOKE ALL ON FUNCTION public.answer_amendment_clarification(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.answer_amendment_clarification(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.withdraw_amendment(p_amendment_id UUID, p_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_a RECORD;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT a.order_id INTO v_order_id FROM public.order_amendments a WHERE a.id = p_amendment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal not found.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_a FROM public.order_amendments a WHERE a.id = p_amendment_id FOR UPDATE;
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to withdraw this proposal.';
  END IF;
  IF v_a.status = 'withdrawn' THEN
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'withdrawn', 'replayed', TRUE);
  END IF;
  IF v_a.status NOT IN ('proposed', 'clarification_requested') THEN
    RAISE EXCEPTION 'This proposal has already been %.', v_a.status;
  END IF;
  UPDATE public.order_amendments SET status = 'withdrawn', response_choice = 'withdrawn', response_note = left(v_note, 500),
    responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
  PERFORM public.record_order_event(v_order_id, 'amendment_withdrawn', 'wholesaler',
    'The wholesaler withdrew the proposed supply change. The order stands as placed.',
    jsonb_build_object('note', left(v_note, 500)), v_a.id);
  PERFORM public.write_audit_log('Order supply change withdrawn', (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id),
    'order', v_order_id, v_order.order_number, jsonb_build_object('amendment_id', v_a.id, 'note', left(v_note, 500)),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment', 'Supply change withdrawn',
      format('Order #%s: the wholesaler withdrew the proposed supply change. Nothing about your order has changed.', v_order.order_number),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'withdrawn', 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.withdraw_amendment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_amendment(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Reading: one order's proposals (both parties), and supplied quantities for lists
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_order_amendments(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_side TEXT;
  v_wholesaler_view BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.total_ghs, o.effective_total_ghs, o.is_credit_order
  INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF public.can_act_for_business(v_order.wholesaler_id, 'read') THEN v_side := 'wholesaler';
  ELSIF public.can_act_for_business(v_order.pharmacy_id, 'read') THEN v_side := 'pharmacy';
  ELSIF public.has_role(auth.uid(), 'admin') THEN v_side := 'admin';
  ELSE RAISE EXCEPTION 'You do not have access to this order.';
  END IF;
  v_wholesaler_view := v_side IN ('wholesaler', 'admin');

  RETURN jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number, 'status', v_order.status,
    'original_total', v_order.total_ghs, 'current_total', COALESCE(v_order.effective_total_ghs, v_order.total_ghs),
    'amended', v_order.effective_total_ghs IS NOT NULL, 'is_credit_order', v_order.is_credit_order,
    'open_amendment_id', (SELECT a.id FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.status IN ('proposed', 'clarification_requested')),
    'stock_evidence', CASE WHEN v_wholesaler_view THEN public.order_has_stock_evidence(p_order_id) ELSE NULL END,
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'product_name', oi.product_name, 'ordered_qty', oi.quantity,
        'supplied_qty', public.order_item_supplied_qty(oi.id), 'unit_price_ghs', oi.unit_price_ghs) ORDER BY oi.id)
      FROM public.order_items oi WHERE oi.order_id = p_order_id), '[]'::JSONB),
    'amendments', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', a.id, 'version', a.version, 'kind', a.kind, 'status', a.status, 'reason', a.reason, 'proposed_at', a.proposed_at,
        'proposed_by_label', public._amendment_actor_label(a.proposed_by, 'wholesaler', v_side, p_order_id),
        'original_total', a.original_total_ghs, 'proposed_total', a.proposed_total_ghs, 'delta', a.delta_ghs,
        'response_choice', a.response_choice, 'response_note', a.response_note, 'responded_at', a.responded_at,
        'responded_by_label', CASE WHEN a.responded_by IS NULL THEN NULL
          WHEN a.response_choice IN ('withdrawn') THEN public._amendment_actor_label(a.responded_by, 'wholesaler', v_side, p_order_id)
          ELSE public._amendment_actor_label(a.responded_by, 'pharmacy', v_side, p_order_id) END,
        'stock_mode', CASE WHEN v_wholesaler_view THEN a.stock_mode ELSE NULL END,
        'lines', (SELECT jsonb_agg(jsonb_build_object(
            'order_item_id', l.order_item_id, 'product_name', l.product_name, 'ordered_qty', l.ordered_qty,
            'prior_supplied_qty', l.prior_supplied_qty, 'supplied_qty', l.supplied_qty, 'short_qty', l.short_qty,
            'unit_price_ghs', l.unit_price_ghs, 'note', l.note,
            'stock_treatment', CASE WHEN v_wholesaler_view THEN l.stock_treatment ELSE NULL END) ORDER BY l.product_name, l.order_item_id)
          FROM public.order_amendment_lines l WHERE l.amendment_id = a.id),
        'messages', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'side', m.author_side, 'message', m.message, 'at', m.created_at,
            'author_label', public._amendment_actor_label(m.author_id, m.author_side, v_side, p_order_id)) ORDER BY m.created_at)
          FROM public.order_amendment_messages m WHERE m.amendment_id = a.id), '[]'::JSONB)
      ) ORDER BY a.version)
      FROM public.order_amendments a WHERE a.order_id = p_order_id), '[]'::JSONB)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_order_amendments(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_amendments(UUID) TO authenticated;

-- For order lists and pick sheets: the quantity committed per line and the current total, for amended orders only.
CREATE OR REPLACE FUNCTION public.order_supply_summary(p_order_ids UUID[])
RETURNS TABLE(order_id UUID, current_total_ghs NUMERIC, has_open_amendment BOOLEAN, lines JSONB)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.id, COALESCE(o.effective_total_ghs, o.total_ghs),
    EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = o.id AND a.status IN ('proposed', 'clarification_requested')),
    COALESCE((SELECT jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'product_id', oi.product_id, 'ordered_qty', oi.quantity,
        'supplied_qty', public.order_item_supplied_qty(oi.id)) ORDER BY oi.id)
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
-- 5. Guards: no dispatch while a proposal is open; cancelling withdraws an open proposal
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_dispatch_during_amendment()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = NEW.id AND a.status IN ('proposed', 'clarification_requested')) THEN
    RAISE EXCEPTION 'This order has a proposed supply change awaiting the pharmacy''s decision. It cannot be dispatched until the change is accepted, rejected or withdrawn.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_block_dispatch_during_amendment ON public.orders;
CREATE TRIGGER trg_block_dispatch_during_amendment
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (NEW.status::TEXT IN ('dispatched', 'delivered') AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.block_dispatch_during_amendment();

CREATE OR REPLACE FUNCTION public.withdraw_amendments_on_order_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
BEGIN
  FOR v_a IN SELECT a.id FROM public.order_amendments a WHERE a.order_id = NEW.id AND a.status IN ('proposed', 'clarification_requested') LOOP
    UPDATE public.order_amendments SET status = 'withdrawn', response_choice = 'order_cancelled', responded_at = now() WHERE id = v_a.id;
    PERFORM public.record_order_event(NEW.id, 'amendment_withdrawn', 'system',
      'The order was cancelled, so the open supply proposal was closed.', '{}'::JSONB, v_a.id);
  END LOOP;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_withdraw_amendments_on_order_cancel ON public.orders;
CREATE TRIGGER trg_withdraw_amendments_on_order_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (NEW.status::TEXT = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.withdraw_amendments_on_order_cancel();

-- ---------------------------------------------------------------------------
-- 6. Reminder for proposals nobody has answered for a day (once per proposal; no auto-expiry)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_amendment_reminders()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR v_a IN
    SELECT a.id, a.order_id, o.order_number, o.pharmacy_id FROM public.order_amendments a JOIN public.orders o ON o.id = a.order_id
    WHERE a.status = 'proposed' AND a.reminder_sent_at IS NULL AND a.proposed_at < now() - interval '24 hours'
    ORDER BY a.proposed_at LIMIT 200
  LOOP
    BEGIN
      PERFORM public.notify_business(v_a.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment', 'Still waiting for your decision',
        format('Order #%s has been waiting more than a day for your decision on a reduced supply.', v_a.order_number), '/pharmacy?tab=orders',
        jsonb_build_object('order_id', v_a.order_id, 'order_number', v_a.order_number, 'amendment_id', v_a.id));
      UPDATE public.order_amendments SET reminder_sent_at = now() WHERE id = v_a.id;
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'amendment reminder failed: %', SQLERRM;
    END;
  END LOOP;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.send_amendment_reminders() FROM PUBLIC, anon, authenticated;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('drugxone-amendment-reminders', '15 * * * *', 'SELECT public.send_amendment_reminders()');
  ELSE
    RAISE NOTICE 'pg_cron is not enabled: supply-change reminders will not be sent automatically.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Could not schedule amendment reminders with pg_cron: %', SQLERRM;
END $$;
