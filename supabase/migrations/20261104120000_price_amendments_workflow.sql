-- Order amendments, Phase 4 part 3: the price-amendment workflow. The wholesaler's owner or a manager proposes new unit prices
-- on an order that has not been dispatched; ONLY the pharmacy's explicit approval applies them.
--
--   propose_price_amendment(order, reason, lines, request_id)    owner / manager of the wholesaler
--   respond_to_price_amendment(amendment, choice, note)          owner / manager / cashier of the pharmacy:
--                                                                 accept | reject | request_clarification
--   answer_price_clarification(amendment, message)               owner / manager of the wholesaler
--   withdraw_price_amendment(amendment, note)                    owner / manager of the wholesaler
--
-- Rules (decisions D2, D5, D6, D11, D12, applied):
--   * only while the order is being prepared (accepted .. ready for dispatch); one open proposal per order (shared with supply
--     changes, by the existing unique index); no dispatch while one is open (the existing trigger);
--   * an order line's placed price is never edited: the accepted price lives on the amendment line and is read through
--     order_item_effective_price(). The delivery fee and the quantities never change here;
--   * the order's effective total moves by sum((new price - price now) x units the wholesaler is committed to supply). Units still
--     waiting in a back-order are billed later, at the price in force when their shipment is prepared;
--   * credit order: a decrease posts ONE credit note, an increase ONE debit note, each tagged with the amendment (the unique index
--     refuses a second); an increase is checked against the customer's credit line under its lock, like checkout and a back-order
--     dispatch (a one-time override can cover it and is consumed once); a paid credit order is reopened by an increase;
--   * cash order: the effective total is what is collected; an order that is already paid cannot be amended (no refund process).

-- ---------------------------------------------------------------------------
-- 1. propose_price_amendment
-- ---------------------------------------------------------------------------
-- p_lines: [{"order_item_id": uuid, "unit_price_ghs": number, "note": text?}, ...]; products left out keep their price.
CREATE OR REPLACE FUNCTION public.propose_price_amendment(
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
  v_item RECORD;
  v_el JSONB;
  v_text TEXT;
  v_new NUMERIC(12,2);
  v_note TEXT;
  v_lines JSONB := '[]'::JSONB;
  v_changed INTEGER := 0;
  v_delta NUMERIC(12,2) := 0;
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
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only the owner or a manager can propose a price change on an order.';
  END IF;

  SELECT a.id, a.version, a.status, a.kind INTO v_existing FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.kind <> 'price_change' THEN RAISE EXCEPTION 'This request id was already used for another kind of proposal.'; END IF;
    RETURN jsonb_build_object('amendment_id', v_existing.id, 'version', v_existing.version, 'status', v_existing.status, 'replayed', TRUE);
  END IF;

  IF v_order.status NOT IN ('accepted', 'picking', 'packed', 'ready_for_dispatch') THEN
    RAISE EXCEPTION 'Prices can only be changed while the order is being prepared (accepted up to ready for dispatch).';
  END IF;
  IF NOT v_order.is_credit_order AND v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'This order has already been paid. Changing its price needs a refund, which is not supported yet; contact support.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.status IN ('proposed', 'clarification_requested')) THEN
    RAISE EXCEPTION 'A change is already awaiting a response on this order. Withdraw it first.';
  END IF;
  IF char_length(v_reason) < 3 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason for the price change is required (3 to 500 characters).';
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Say which products get a new price.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_lines) e
    WHERE jsonb_typeof(e) <> 'object'
       OR NOT EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = p_order_id AND oi.id::TEXT = e->>'order_item_id')
  ) THEN
    RAISE EXCEPTION 'A line does not belong to this order.';
  END IF;
  IF (SELECT count(DISTINCT e->>'order_item_id') FROM jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'Each product can appear only once.';
  END IF;

  FOR v_item IN
    SELECT oi.id, oi.product_id, oi.product_name, oi.quantity, public.order_item_effective_price(oi.id) AS price_now,
           public.order_item_supplied_qty(oi.id) AS committed
    FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id
  LOOP
    SELECT e INTO v_el FROM jsonb_array_elements(p_lines) e WHERE e->>'order_item_id' = v_item.id::TEXT;
    CONTINUE WHEN v_el IS NULL;
    v_text := btrim(COALESCE(v_el->>'unit_price_ghs', ''));
    IF v_text !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' THEN
      RAISE EXCEPTION 'Enter the new price of % as an amount in cedis with at most two decimals.', v_item.product_name;
    END IF;
    v_new := v_text::NUMERIC(12,2);
    IF v_new <= 0 THEN
      RAISE EXCEPTION 'The new price of % must be more than zero. To stop supplying it, propose a smaller quantity instead.', v_item.product_name;
    END IF;
    IF v_new = v_item.price_now THEN
      RAISE EXCEPTION 'The new price of % is the same as its current price.', v_item.product_name;
    END IF;
    v_note := NULLIF(left(btrim(COALESCE(v_el->>'note', '')), 300), '');
    v_changed := v_changed + 1;
    v_delta := v_delta + round((v_new - v_item.price_now) * v_item.committed, 2);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'order_item_id', v_item.id, 'product_id', v_item.product_id, 'product_name', v_item.product_name, 'ordered_qty', v_item.quantity,
      'committed_qty', v_item.committed, 'unit_price_ghs', v_item.price_now, 'proposed_unit_price_ghs', v_new, 'note', v_note));
  END LOOP;
  IF v_changed = 0 THEN RAISE EXCEPTION 'Nothing is being changed. Enter a different price for at least one product.'; END IF;

  v_original := COALESCE(v_order.effective_total_ghs, v_order.total_ghs);
  v_proposed := v_original + v_delta;
  IF v_proposed < 0 THEN RAISE EXCEPTION 'The proposed total cannot be negative.'; END IF;

  SELECT COALESCE(max(a.version), 0) + 1 INTO v_version FROM public.order_amendments a WHERE a.order_id = p_order_id;
  INSERT INTO public.order_amendments(order_id, version, kind, status, reason, proposed_by, original_total_ghs, proposed_total_ghs,
                                      delta_ghs, stock_mode, request_id)
  VALUES (p_order_id, v_version, 'price_change', 'proposed', v_reason, auth.uid(), v_original, v_proposed, v_proposed - v_original, 'none', p_request_id)
  RETURNING id INTO v_amendment_id;

  INSERT INTO public.order_amendment_lines(amendment_id, order_item_id, product_id, product_name, ordered_qty, prior_supplied_qty,
                                           supplied_qty, short_qty, unit_price_ghs, proposed_unit_price_ghs, stock_treatment, note)
  SELECT v_amendment_id, (l->>'order_item_id')::UUID, (l->>'product_id')::UUID, l->>'product_name', (l->>'ordered_qty')::INTEGER,
         (l->>'committed_qty')::INTEGER, (l->>'committed_qty')::INTEGER, 0, (l->>'unit_price_ghs')::NUMERIC,
         (l->>'proposed_unit_price_ghs')::NUMERIC, 'none', l->>'note'
  FROM jsonb_array_elements(v_lines) l;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.record_order_event(p_order_id, 'amendment_proposed', 'wholesaler',
    format('Price change proposed on %s line(s); the order total would change from %s to %s.',
           v_changed, public._amendment_money(v_original), public._amendment_money(v_proposed)),
    jsonb_build_object('kind', 'price_change', 'reason', v_reason, 'original_total', v_original, 'proposed_total', v_proposed, 'version', v_version),
    v_amendment_id);
  PERFORM public.write_audit_log('Order price change proposed', v_wholesaler_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_amendment_id, 'version', v_version, 'reason', v_reason, 'lines_changed', v_changed,
                       'original_total', v_original, 'proposed_total', v_proposed),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment',
      'A price change needs your decision',
      format('Order #%s: %s proposes new prices (total %s instead of %s). Nothing changes unless you approve it.',
             v_order.order_number, COALESCE(v_wholesaler_name, 'the wholesaler'), public._amendment_money(v_proposed), public._amendment_money(v_original)),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', p_order_id, 'order_number', v_order.order_number, 'amendment_id', v_amendment_id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;

  RETURN jsonb_build_object('amendment_id', v_amendment_id, 'version', v_version, 'status', 'proposed', 'replayed', FALSE,
    'original_total', v_original, 'proposed_total', v_proposed, 'delta', v_proposed - v_original);
END;
$$;
REVOKE ALL ON FUNCTION public.propose_price_amendment(UUID, TEXT, JSONB, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.propose_price_amendment(UUID, TEXT, JSONB, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. respond_to_price_amendment (pharmacy): accept | reject | request_clarification
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.respond_to_price_amendment(p_amendment_id UUID, p_choice TEXT, p_note TEXT DEFAULT NULL)
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
  v_terms RECORD;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_pharmacy_name TEXT;
  v_wholesaler_name TEXT;
  v_exposure NUMERIC(12,2);
  v_override_id UUID;
  v_choice TEXT;
  v_staff TEXT[] := ARRAY['owner', 'manager'];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_choice IS NULL OR p_choice NOT IN ('accept', 'reject', 'request_clarification') THEN
    RAISE EXCEPTION 'Unsupported response.';
  END IF;
  v_choice := CASE p_choice WHEN 'accept' THEN 'accept_price' ELSE p_choice END;

  SELECT a.order_id INTO v_order_id FROM public.order_amendments a WHERE a.id = p_amendment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proposal not found.'; END IF;
  -- Lock order first, then the proposal (the same order every function uses).
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.is_credit_order, o.payment_status::TEXT AS payment_status,
         o.total_ghs, o.effective_total_ghs
  INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_a FROM public.order_amendments a WHERE a.id = p_amendment_id FOR UPDATE;

  IF NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to respond to this proposal.';
  END IF;
  IF v_a.kind <> 'price_change' THEN RAISE EXCEPTION 'This is not a price proposal.'; END IF;

  IF v_a.status IN ('accepted', 'rejected', 'withdrawn') THEN
    IF v_a.response_choice = v_choice THEN
      RETURN jsonb_build_object('amendment_id', v_a.id, 'status', v_a.status, 'replayed', TRUE);
    END IF;
    RAISE EXCEPTION 'This proposal has already been %.', v_a.status;
  END IF;
  IF v_a.status = 'clarification_requested' THEN
    IF p_choice = 'request_clarification' AND v_note IS NOT NULL THEN
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
  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;

  -- ----- request clarification -------------------------------------------------------------------------------------
  IF p_choice = 'request_clarification' THEN
    IF v_note IS NULL OR char_length(v_note) < 3 THEN RAISE EXCEPTION 'Write your question for the wholesaler.'; END IF;
    INSERT INTO public.order_amendment_messages(amendment_id, order_id, author_side, author_id, message)
    VALUES (v_a.id, v_order_id, 'pharmacy', auth.uid(), left(v_note, 500));
    UPDATE public.order_amendments SET status = 'clarification_requested', response_choice = 'request_clarification',
      responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
    PERFORM public.record_order_event(v_order_id, 'amendment_clarification_requested', 'pharmacy',
      'The pharmacy asked a question about the proposed price change.', jsonb_build_object('message', left(v_note, 500)), v_a.id);
    PERFORM public.write_audit_log('Order price change question asked', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('amendment_id', v_a.id, 'message', left(v_note, 500)), _business_id => v_order.pharmacy_id);
    BEGIN
      PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'The pharmacy asked a question',
        format('Order #%s: %s', v_order.order_number, left(v_note, 200)), '/wholesaler?tab=orders',
        jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'clarification_requested', 'replayed', FALSE);
  END IF;

  -- ----- reject --------------------------------------------------------------------------------------------------------
  IF p_choice = 'reject' THEN
    UPDATE public.order_amendments SET status = 'rejected', response_choice = 'reject', response_note = left(v_note, 500),
      responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
    PERFORM public.record_order_event(v_order_id, 'amendment_rejected', 'pharmacy',
      'The pharmacy rejected the proposed price change. The prices stand as agreed.', jsonb_build_object('note', left(v_note, 500)), v_a.id);
    PERFORM public.write_audit_log('Order price change rejected', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('amendment_id', v_a.id, 'note', left(v_note, 500)), _business_id => v_order.pharmacy_id);
    BEGIN
      PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'Price change rejected',
        format('Order #%s: the pharmacy rejected the new prices. The order stands at the agreed prices; supply it as agreed, cancel it, or propose again.', v_order.order_number),
        '/wholesaler?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'rejected', 'replayed', FALSE);
  END IF;

  -- ----- accept ----------------------------------------------------------------------------------------------------------
  IF NOT v_order.is_credit_order AND v_order.payment_status = 'paid' THEN
    RAISE EXCEPTION 'This order has already been paid. Changing its price needs a refund, which is not supported yet; contact support.';
  END IF;
  -- The proposal must still describe the order: same price now, same units committed, on every line.
  FOR v_line IN SELECT l.* FROM public.order_amendment_lines l WHERE l.amendment_id = v_a.id ORDER BY l.order_item_id LOOP
    IF public.order_item_effective_price(v_line.order_item_id) <> v_line.unit_price_ghs
       OR public.order_item_supplied_qty(v_line.order_item_id) <> v_line.supplied_qty THEN
      RAISE EXCEPTION 'The order changed since this proposal was made (%). Ask the wholesaler for a new proposal.', v_line.product_name;
    END IF;
  END LOOP;

  -- An increase on a credit order must fit the customer's credit line (locked, then checked as checkout does).
  IF v_order.is_credit_order AND v_a.delta_ghs > 0 THEN
    SELECT c.credit_limit_ghs, c.active, c.status INTO v_terms FROM public.wholesaler_credit_terms c
    WHERE c.wholesaler_id = v_order.wholesaler_id AND c.pharmacy_id = v_order.pharmacy_id FOR UPDATE;
    IF NOT FOUND OR NOT v_terms.active THEN
      RAISE EXCEPTION 'Credit is closed for this customer, so a price increase cannot be added to a credit order.';
    END IF;
    IF v_terms.status <> 'active' THEN
      RAISE EXCEPTION 'Credit for this customer is %. It must be active before a price increase can be added.', v_terms.status;
    END IF;
    v_exposure := public.credit_exposure(v_order.wholesaler_id, v_order.pharmacy_id);
    IF v_exposure + v_a.delta_ghs > v_terms.credit_limit_ghs THEN
      SELECT ov.id INTO v_override_id FROM public.credit_overrides ov
      WHERE ov.wholesaler_id = v_order.wholesaler_id AND ov.pharmacy_id = v_order.pharmacy_id AND ov.status = 'active'
        AND ov.expires_at > now() AND ov.max_order_ghs >= v_a.delta_ghs FOR UPDATE;
      IF v_override_id IS NULL THEN
        RAISE EXCEPTION 'This increase (%) would take the account above its credit limit of % (currently owed %). Pay down the balance, or ask the wholesaler to approve a one-time credit override.',
          public._amendment_money(v_a.delta_ghs), public._amendment_money(v_terms.credit_limit_ghs), public._amendment_money(v_exposure);
      END IF;
    END IF;
  END IF;

  -- Money. total_ghs and the order lines are untouched; the effective total and the price now in force carry the change.
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET
    effective_total_ghs = v_a.proposed_total_ghs,
    payment_status = CASE WHEN v_order.is_credit_order AND v_order.payment_status = 'paid' AND v_a.delta_ghs > 0 THEN 'unpaid'::public.payment_status ELSE payment_status END,
    paid_at = CASE WHEN v_order.is_credit_order AND v_order.payment_status = 'paid' AND v_a.delta_ghs > 0 THEN NULL ELSE paid_at END,
    payment_confirmed_at = CASE WHEN v_order.is_credit_order AND v_order.payment_status = 'paid' AND v_a.delta_ghs > 0 THEN NULL ELSE payment_confirmed_at END,
    payment_confirmed_by = CASE WHEN v_order.is_credit_order AND v_order.payment_status = 'paid' AND v_a.delta_ghs > 0 THEN NULL ELSE payment_confirmed_by END
  WHERE id = v_order_id;
  IF v_order.is_credit_order AND v_a.delta_ghs < 0 THEN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, amendment_id)
    VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'credit_note', 'credit', -v_a.delta_ghs, auth.uid(),
            'Prices lowered by agreement (proposal ' || v_a.version || ')', v_a.id);
  ELSIF v_order.is_credit_order AND v_a.delta_ghs > 0 THEN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note, amendment_id)
    VALUES (v_order.wholesaler_id, v_order.pharmacy_id, v_order_id, 'debit_note', 'debit', v_a.delta_ghs, auth.uid(),
            'Prices raised by agreement (proposal ' || v_a.version || ')', v_a.id);
  END IF;
  IF v_override_id IS NOT NULL THEN
    UPDATE public.credit_overrides SET status = 'used', used_order_id = v_order_id, used_at = now() WHERE id = v_override_id;
    PERFORM public.write_audit_log('Credit override used', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
      jsonb_build_object('override_id', v_override_id, 'limit_ghs', v_terms.credit_limit_ghs, 'amendment_id', v_a.id,
                         'increase_ghs', v_a.delta_ghs, 'resulting_exposure_ghs', v_exposure + v_a.delta_ghs),
      _business_id => v_order.wholesaler_id);
  END IF;

  UPDATE public.order_amendments SET status = 'accepted', response_choice = 'accept_price', response_note = left(v_note, 500),
    responded_by = auth.uid(), responded_at = now(), applied_at = now() WHERE id = v_a.id;

  PERFORM public.record_order_event(v_order_id, 'amendment_accepted', 'pharmacy',
    format('The pharmacy approved the new prices. The order total is now %s (was %s).',
           public._amendment_money(v_a.proposed_total_ghs), public._amendment_money(v_a.original_total_ghs)),
    jsonb_build_object('kind', 'price_change', 'original_total', v_a.original_total_ghs, 'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500)), v_a.id);
  PERFORM public.write_audit_log('Order price change accepted', v_pharmacy_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'original_total', v_a.original_total_ghs,
                       'new_total', v_a.proposed_total_ghs, 'note', left(v_note, 500)), _business_id => v_order.pharmacy_id);
  PERFORM public.write_audit_log('Order price change applied', v_wholesaler_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('amendment_id', v_a.id, 'version', v_a.version, 'new_total', v_a.proposed_total_ghs, 'delta', v_a.delta_ghs,
                       'ledger_note', CASE WHEN NOT v_order.is_credit_order OR v_a.delta_ghs = 0 THEN 'none'
                                           WHEN v_a.delta_ghs < 0 THEN 'credit_note' ELSE 'debit_note' END),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.wholesaler_id, v_staff, 'order_amendment', 'Price change approved',
      format('Order #%s: the pharmacy approved the new prices. New total %s. Dispatch can continue.', v_order.order_number,
             public._amendment_money(v_a.proposed_total_ghs)),
      '/wholesaler?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;

  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'accepted', 'replayed', FALSE,
    'new_total', v_a.proposed_total_ghs, 'delta', v_a.delta_ghs);
END;
$$;
REVOKE ALL ON FUNCTION public.respond_to_price_amendment(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_price_amendment(UUID, TEXT, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. answer_price_clarification / withdraw_price_amendment (wholesaler owner / manager)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.answer_price_clarification(p_amendment_id UUID, p_message TEXT)
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
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only the owner or a manager can reply on a price proposal.';
  END IF;
  IF v_a.kind <> 'price_change' THEN RAISE EXCEPTION 'This is not a price proposal.'; END IF;
  IF v_a.status <> 'clarification_requested' THEN
    RAISE EXCEPTION 'There is no open question on this proposal.';
  END IF;
  IF char_length(v_message) < 1 THEN RAISE EXCEPTION 'Write your reply.'; END IF;

  INSERT INTO public.order_amendment_messages(amendment_id, order_id, author_side, author_id, message)
  VALUES (v_a.id, v_order_id, 'wholesaler', auth.uid(), left(v_message, 500));
  UPDATE public.order_amendments SET status = 'proposed', response_choice = NULL, responded_by = NULL, responded_at = NULL WHERE id = v_a.id;
  PERFORM public.record_order_event(v_order_id, 'amendment_clarification_answered', 'wholesaler',
    'The wholesaler replied to the pharmacy''s question. The price proposal awaits the pharmacy''s decision.',
    jsonb_build_object('message', left(v_message, 500)), v_a.id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment', 'The wholesaler replied',
      format('Order #%s: %s', v_order.order_number, left(v_message, 200)), '/pharmacy?tab=orders',
      jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'proposed');
END;
$$;
REVOKE ALL ON FUNCTION public.answer_price_clarification(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.answer_price_clarification(UUID, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.withdraw_price_amendment(p_amendment_id UUID, p_note TEXT DEFAULT NULL)
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
  IF NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only the owner or a manager can withdraw a price proposal.';
  END IF;
  IF v_a.kind <> 'price_change' THEN RAISE EXCEPTION 'This is not a price proposal.'; END IF;
  IF v_a.status = 'withdrawn' THEN
    RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'withdrawn', 'replayed', TRUE);
  END IF;
  IF v_a.status NOT IN ('proposed', 'clarification_requested') THEN
    RAISE EXCEPTION 'This proposal has already been %.', v_a.status;
  END IF;
  UPDATE public.order_amendments SET status = 'withdrawn', response_choice = 'withdrawn', response_note = left(v_note, 500),
    responded_by = auth.uid(), responded_at = now() WHERE id = v_a.id;
  PERFORM public.record_order_event(v_order_id, 'amendment_withdrawn', 'wholesaler',
    'The wholesaler withdrew the proposed price change. The prices stand as agreed.', jsonb_build_object('note', left(v_note, 500)), v_a.id);
  PERFORM public.write_audit_log('Order price change withdrawn', (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id),
    'order', v_order_id, v_order.order_number, jsonb_build_object('amendment_id', v_a.id, 'note', left(v_note, 500)),
    _business_id => v_order.wholesaler_id);
  BEGIN
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_amendment', 'Price change withdrawn',
      format('Order #%s: the wholesaler withdrew the proposed price change. Nothing about your order has changed.', v_order.order_number),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order_id, 'order_number', v_order.order_number, 'amendment_id', v_a.id));
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'amendment notification failed: %', SQLERRM; END;
  RETURN jsonb_build_object('amendment_id', v_a.id, 'status', 'withdrawn', 'replayed', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.withdraw_price_amendment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_price_amendment(UUID, TEXT) TO authenticated;
