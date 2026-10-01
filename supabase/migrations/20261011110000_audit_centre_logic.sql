-- Audit Centre, part 2: retrofits audit logging onto the RFQ RPCs (which had none at all -- a
-- documented gap from the RFQ phase) and adds business_id to the credit-ledger and product-import
-- call sites that already logged but couldn't be filtered per-business. Also adds list_audit_log,
-- the read RPC the Audit Centre UI calls.
--
-- Every function below is rebuilt on its exact current body (re-read fresh from its own source
-- migration immediately before writing this file) -- only the write_audit_log call sites change:
-- either gaining a trailing _business_id argument, or being added where there was none.

-- ---------------------------------------------------------------------------
-- create_rfq -- unchanged except for one new write_audit_log call before the RETURN.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_rfq(
  p_pharmacy_id UUID,
  p_title TEXT,
  p_notes TEXT,
  p_response_deadline TIMESTAMPTZ,
  p_wholesaler_ids UUID[],
  p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_rfq_id UUID;
  v_item_count INTEGER;
  v_wholesaler_count INTEGER;
  v_wholesaler_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF p_title IS NULL OR btrim(p_title) = '' THEN RAISE EXCEPTION 'A title is required.'; END IF;
  IF p_wholesaler_ids IS NULL OR array_length(p_wholesaler_ids, 1) IS NULL THEN RAISE EXCEPTION 'Invite at least one supplier.'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Add at least one item.'; END IF;
  IF p_response_deadline IS NOT NULL AND p_response_deadline <= now() THEN RAISE EXCEPTION 'The response deadline must be in the future.'; END IF;

  SELECT id, name, owner_id, type, verification_status INTO v_business FROM public.businesses WHERE id = p_pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_business.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified before requesting quotes.'; END IF;
  v_is_owner := v_business.owner_id = auth.uid();
  IF NOT v_is_owner THEN
    v_role := public.get_staff_role(auth.uid(), p_pharmacy_id);
    IF v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to request quotes for this pharmacy.';
    END IF;
  END IF;

  SELECT COUNT(*) INTO v_wholesaler_count FROM public.businesses b
  WHERE b.id = ANY(p_wholesaler_ids) AND b.type = 'wholesaler' AND b.verification_status = 'approved';
  IF v_wholesaler_count <> cardinality(ARRAY(SELECT DISTINCT unnest(p_wholesaler_ids))) THEN
    RAISE EXCEPTION 'One or more invited suppliers could not be found.';
  END IF;

  INSERT INTO public.rfqs (pharmacy_id, title, notes, response_deadline, created_by)
  VALUES (p_pharmacy_id, btrim(p_title), NULLIF(btrim(p_notes), ''), p_response_deadline, auth.uid())
  RETURNING id INTO v_rfq_id;

  INSERT INTO public.rfq_items (rfq_id, product_name, quantity, notes)
  SELECT v_rfq_id, btrim(item ->> 'productName'), (item ->> 'quantity')::INTEGER, NULLIF(btrim(item ->> 'notes'), '')
  FROM jsonb_array_elements(p_items) item
  WHERE NULLIF(btrim(item ->> 'productName'), '') IS NOT NULL
    AND (item ->> 'quantity') IS NOT NULL AND (item ->> 'quantity')::INTEGER > 0;
  GET DIAGNOSTICS v_item_count = ROW_COUNT;
  IF v_item_count = 0 THEN RAISE EXCEPTION 'Each item needs a product name and a quantity greater than zero.'; END IF;

  INSERT INTO public.rfq_invitees (rfq_id, wholesaler_id)
  SELECT v_rfq_id, w FROM unnest(p_wholesaler_ids) AS w
  ON CONFLICT DO NOTHING;

  FOR v_wholesaler_id IN SELECT DISTINCT unnest(p_wholesaler_ids) LOOP
    PERFORM public.notify_business(v_wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_received',
      'New quote request',
      format('%s has requested a quote: %s', v_business.name, btrim(p_title)),
      '/wholesaler/rfqs/' || v_rfq_id);
  END LOOP;

  PERFORM public.write_audit_log('RFQ created', v_business.name, 'rfq', v_rfq_id, btrim(p_title),
    jsonb_build_object('invited_wholesaler_count', v_wholesaler_count, 'item_count', v_item_count, 'response_deadline', p_response_deadline),
    _business_id => p_pharmacy_id);

  RETURN v_rfq_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- submit_rfq_quote -- unchanged except for one new write_audit_log call before the RETURN.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_rfq_quote(
  p_rfq_id UUID,
  p_wholesaler_id UUID,
  p_items JSONB,
  p_delivery_notes TEXT DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rfq RECORD;
  v_quote_id UUID;
  v_total NUMERIC(12,2);
  v_item_count INTEGER;
  v_wholesaler_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF NOT public.can_act_for_business(p_wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to submit quotes for this wholesaler.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Quote at least one item.';
  END IF;
  IF p_valid_until IS NOT NULL AND p_valid_until <= now() THEN RAISE EXCEPTION 'The quote validity date must be in the future.'; END IF;

  SELECT r.id, r.status, r.response_deadline, r.pharmacy_id INTO v_rfq
  FROM public.rfqs r WHERE r.id = p_rfq_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RFQ not found.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rfq_invitees WHERE rfq_id = p_rfq_id AND wholesaler_id = p_wholesaler_id) THEN
    RAISE EXCEPTION 'This wholesaler was not invited to this RFQ.';
  END IF;
  IF v_rfq.status <> 'open' THEN RAISE EXCEPTION 'This RFQ is no longer accepting quotes.'; END IF;
  IF v_rfq.response_deadline IS NOT NULL AND now() > v_rfq.response_deadline THEN
    RAISE EXCEPTION 'The response deadline for this RFQ has passed.';
  END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id;

  INSERT INTO public.rfq_quotes (rfq_id, wholesaler_id, status, delivery_notes, valid_until, total_ghs, submitted_at)
  VALUES (p_rfq_id, p_wholesaler_id, 'submitted', NULLIF(btrim(p_delivery_notes), ''), p_valid_until, 0, now())
  ON CONFLICT (rfq_id, wholesaler_id) DO UPDATE SET
    status = 'submitted', delivery_notes = EXCLUDED.delivery_notes, valid_until = EXCLUDED.valid_until, submitted_at = now()
  RETURNING id INTO v_quote_id;

  DELETE FROM public.rfq_quote_items WHERE rfq_quote_id = v_quote_id;

  CREATE TEMP TABLE tmp_quote_items (
    rfq_item_id UUID, product_id UUID, unit_price_ghs NUMERIC(10,2), notes TEXT
  ) ON COMMIT DROP;
  INSERT INTO tmp_quote_items
  SELECT (item ->> 'rfqItemId')::UUID, (item ->> 'productId')::UUID, (item ->> 'unitPriceGhs')::NUMERIC, NULLIF(btrim(item ->> 'notes'), '')
  FROM jsonb_array_elements(p_items) item
  WHERE (item ->> 'rfqItemId') IS NOT NULL AND (item ->> 'productId') IS NOT NULL
    AND (item ->> 'unitPriceGhs') IS NOT NULL AND (item ->> 'unitPriceGhs')::NUMERIC > 0;
  SELECT COUNT(*) INTO v_item_count FROM tmp_quote_items;
  IF v_item_count = 0 THEN RAISE EXCEPTION 'Each quoted item needs a valid item reference, product and price.'; END IF;
  IF v_item_count <> (SELECT COUNT(DISTINCT rfq_item_id) FROM tmp_quote_items) THEN
    RAISE EXCEPTION 'Each item can only be quoted once.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM tmp_quote_items t
    WHERE NOT EXISTS (SELECT 1 FROM public.rfq_items ri WHERE ri.id = t.rfq_item_id AND ri.rfq_id = p_rfq_id)
  ) THEN
    RAISE EXCEPTION 'One or more items do not belong to this RFQ.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM tmp_quote_items t
    WHERE NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = t.product_id AND p.wholesaler_id = p_wholesaler_id AND p.active)
  ) THEN
    RAISE EXCEPTION 'One or more quoted products are not in your active catalog.';
  END IF;

  INSERT INTO public.rfq_quote_items (rfq_quote_id, rfq_item_id, product_id, quantity, unit_price_ghs, line_total_ghs, notes)
  SELECT v_quote_id, t.rfq_item_id, t.product_id, ri.quantity, t.unit_price_ghs, round(t.unit_price_ghs * ri.quantity, 2), t.notes
  FROM tmp_quote_items t JOIN public.rfq_items ri ON ri.id = t.rfq_item_id;

  SELECT COALESCE(SUM(line_total_ghs), 0) INTO v_total FROM public.rfq_quote_items WHERE rfq_quote_id = v_quote_id;
  UPDATE public.rfq_quotes SET total_ghs = v_total WHERE id = v_quote_id;

  PERFORM public.notify_business(v_rfq.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'rfq_quote_received',
    'New quote received', format('%s submitted a quote for your RFQ.', v_wholesaler_name), '/pharmacy/rfqs/' || p_rfq_id);

  PERFORM public.write_audit_log('RFQ quote submitted', v_wholesaler_name, 'rfq_quote', v_quote_id, v_wholesaler_name,
    jsonb_build_object('rfq_id', p_rfq_id, 'total_ghs', v_total, 'item_count', v_item_count),
    _business_id => p_wholesaler_id);

  RETURN v_quote_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- withdraw_rfq_quote -- unchanged except for one new write_audit_log call before the END.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdraw_rfq_quote(p_rfq_id UUID, p_wholesaler_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rfq_status TEXT;
  v_quote RECORD;
  v_wholesaler_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF NOT public.can_act_for_business(p_wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to withdraw quotes for this wholesaler.';
  END IF;

  SELECT status INTO v_rfq_status FROM public.rfqs WHERE id = p_rfq_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RFQ not found.'; END IF;
  IF v_rfq_status <> 'open' THEN RAISE EXCEPTION 'This RFQ is no longer open.'; END IF;

  SELECT id, status INTO v_quote FROM public.rfq_quotes WHERE rfq_id = p_rfq_id AND wholesaler_id = p_wholesaler_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'You have not submitted a quote for this RFQ.'; END IF;
  IF v_quote.status <> 'submitted' THEN RAISE EXCEPTION 'This quote cannot be withdrawn.'; END IF;

  UPDATE public.rfq_quotes SET status = 'withdrawn' WHERE id = v_quote.id;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id;
  PERFORM public.write_audit_log('RFQ quote withdrawn', v_wholesaler_name, 'rfq_quote', v_quote.id, v_wholesaler_name,
    jsonb_build_object('rfq_id', p_rfq_id), _business_id => p_wholesaler_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- cancel_rfq -- unchanged except the RFQ's pharmacy name is now selected (for the audit log) and
-- one new write_audit_log call is added before the END.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_rfq(p_rfq_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rfq RECORD;
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_invitee RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT r.id, r.status, r.pharmacy_id, r.title, b.owner_id, b.name AS pharmacy_name INTO v_rfq
  FROM public.rfqs r JOIN public.businesses b ON b.id = r.pharmacy_id
  WHERE r.id = p_rfq_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RFQ not found.'; END IF;

  v_is_owner := v_rfq.owner_id = auth.uid();
  IF NOT v_is_owner THEN
    v_role := public.get_staff_role(auth.uid(), v_rfq.pharmacy_id);
    IF v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to cancel this RFQ.';
    END IF;
  END IF;

  IF v_rfq.status <> 'open' THEN RAISE EXCEPTION 'Only an open RFQ can be cancelled.'; END IF;

  UPDATE public.rfqs SET status = 'cancelled' WHERE id = p_rfq_id;

  FOR v_invitee IN SELECT wholesaler_id FROM public.rfq_invitees WHERE rfq_id = p_rfq_id LOOP
    PERFORM public.notify_business(v_invitee.wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_cancelled',
      'Quote request cancelled', format('The RFQ "%s" was cancelled by the pharmacy.', v_rfq.title), '/wholesaler/rfqs/' || p_rfq_id);
  END LOOP;

  PERFORM public.write_audit_log('RFQ cancelled', v_rfq.pharmacy_name, 'rfq', p_rfq_id, v_rfq.title, '{}'::JSONB,
    _business_id => v_rfq.pharmacy_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_rfq(UUID, TEXT, TEXT, TIMESTAMPTZ, UUID[], JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_rfq_quote(UUID, UUID, JSONB, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.withdraw_rfq_quote(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_rfq(UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_rfq(UUID, TEXT, TEXT, TIMESTAMPTZ, UUID[], JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_rfq_quote(UUID, UUID, JSONB, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_rfq_quote(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_rfq(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- award_rfq_quote -- unchanged except the pharmacy's name is now selected (for the audit log) and
-- one new write_audit_log call is added before the RETURN.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.award_rfq_quote(
  p_rfq_id UUID,
  p_quote_id UUID,
  p_use_credit BOOLEAN DEFAULT false
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rfq RECORD;
  v_quote RECORD;
  v_item RECORD;
  v_order_id UUID;
  v_subtotal NUMERIC(12,2);
  v_terms RECORD;
  v_terms_found BOOLEAN;
  v_fee NUMERIC(10,2) := 0;
  v_credit RECORD;
  v_credit_found BOOLEAN;
  v_credit_outstanding NUMERIC;
  v_due_date DATE;
  v_wholesaler_name TEXT;
  v_rejected RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT r.id, r.pharmacy_id, r.status, r.title, b.name AS pharmacy_name INTO v_rfq
  FROM public.rfqs r JOIN public.businesses b ON b.id = r.pharmacy_id WHERE r.id = p_rfq_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RFQ not found.'; END IF;
  IF NOT public.can_act_for_business(v_rfq.pharmacy_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to award quotes for this pharmacy.';
  END IF;
  IF v_rfq.status <> 'open' THEN RAISE EXCEPTION 'This RFQ is not open to be awarded.'; END IF;

  SELECT q.id, q.rfq_id, q.wholesaler_id, q.status, q.delivery_notes INTO v_quote
  FROM public.rfq_quotes q WHERE q.id = p_quote_id AND q.rfq_id = p_rfq_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Quote not found.'; END IF;
  IF v_quote.status <> 'submitted' THEN RAISE EXCEPTION 'Only a submitted quote can be awarded.'; END IF;

  -- Lock every quoted product and apply the same availability checks as checkout: must still be
  -- active, and enough stock for the quoted quantity. The quoted price is final either way -- it
  -- was agreed when the wholesaler submitted it, so there is no discount recomputation here.
  FOR v_item IN
    SELECT qi.id, qi.quantity, qi.unit_price_ghs, p.id AS product_id, p.name AS product_name, p.stock, p.active
    FROM public.rfq_quote_items qi JOIN public.products p ON p.id = qi.product_id
    WHERE qi.rfq_quote_id = p_quote_id
    FOR UPDATE OF p
  LOOP
    IF NOT v_item.active THEN RAISE EXCEPTION '% is no longer active in the marketplace.', v_item.product_name; END IF;
    IF v_item.stock < v_item.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_item.stock, v_item.product_name;
    END IF;
    UPDATE public.products SET stock = stock - v_item.quantity WHERE id = v_item.product_id;
  END LOOP;

  SELECT COALESCE(SUM(unit_price_ghs * quantity), 0) INTO v_subtotal FROM public.rfq_quote_items WHERE rfq_quote_id = p_quote_id;
  IF v_subtotal <= 0 THEN RAISE EXCEPTION 'This quote has no quoted lines.'; END IF;

  SELECT t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs INTO v_terms
  FROM public.wholesaler_order_terms t WHERE t.wholesaler_id = v_quote.wholesaler_id;
  v_terms_found := FOUND;
  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_quote.wholesaler_id;
  IF v_terms_found THEN
    IF v_terms.min_order_value_ghs > 0 AND v_subtotal < v_terms.min_order_value_ghs THEN
      RAISE EXCEPTION '% requires a minimum order of GHS % (this quote is GHS %).',
        v_wholesaler_name, to_char(v_terms.min_order_value_ghs, 'FM999,999,990.00'), to_char(v_subtotal, 'FM999,999,990.00');
    END IF;
    IF v_terms.delivery_fee_ghs > 0
       AND NOT (v_terms.free_delivery_threshold_ghs IS NOT NULL AND v_subtotal >= v_terms.free_delivery_threshold_ghs) THEN
      v_fee := v_terms.delivery_fee_ghs;
    END IF;
  END IF;

  v_due_date := NULL;
  IF p_use_credit THEN
    SELECT c.credit_limit_ghs, c.payment_terms_days, c.active INTO v_credit
    FROM public.wholesaler_credit_terms c
    WHERE c.wholesaler_id = v_quote.wholesaler_id AND c.pharmacy_id = v_rfq.pharmacy_id
    FOR UPDATE;
    v_credit_found := FOUND AND v_credit.active;
    IF NOT v_credit_found THEN
      RAISE EXCEPTION '% has not approved credit for your pharmacy.', v_wholesaler_name;
    END IF;
    SELECT COALESCE(SUM(o.total_ghs), 0) INTO v_credit_outstanding
    FROM public.orders o
    WHERE o.wholesaler_id = v_quote.wholesaler_id AND o.pharmacy_id = v_rfq.pharmacy_id
      AND o.is_credit_order AND o.status <> 'cancelled' AND o.payment_status IN ('unpaid', 'failed');
    IF v_credit_outstanding + v_subtotal + v_fee > v_credit.credit_limit_ghs THEN
      RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
        v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_subtotal + v_fee, 'FM999,999,990.00');
    END IF;
    v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;
  END IF;

  INSERT INTO public.orders (pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date, notes)
  VALUES (v_rfq.pharmacy_id, v_quote.wholesaler_id, v_subtotal, 0, v_fee, v_subtotal + v_fee, 'cod', p_use_credit, v_due_date,
    'Created from RFQ ' || v_rfq.title)
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_items (order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs)
  SELECT v_order_id, qi.product_id, p.name, qi.quantity, qi.unit_price_ghs, qi.unit_price_ghs, 0
  FROM public.rfq_quote_items qi JOIN public.products p ON p.id = qi.product_id
  WHERE qi.rfq_quote_id = p_quote_id;

  IF p_use_credit THEN
    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
    VALUES (v_quote.wholesaler_id, v_rfq.pharmacy_id, v_order_id, 'invoice', 'debit', v_subtotal + v_fee, auth.uid());
  END IF;

  UPDATE public.rfq_quotes SET status = 'accepted' WHERE id = p_quote_id;
  UPDATE public.rfq_quotes SET status = 'rejected' WHERE rfq_id = p_rfq_id AND id <> p_quote_id AND status = 'submitted';
  UPDATE public.rfqs SET status = 'awarded', awarded_quote_id = p_quote_id, awarded_order_id = v_order_id WHERE id = p_rfq_id;

  PERFORM public.notify_business(v_quote.wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_quote_accepted',
    'Quote accepted', format('Your quote for "%s" was accepted. A new order has been created.', v_rfq.title), '/wholesaler?tab=orders');

  FOR v_rejected IN SELECT wholesaler_id FROM public.rfq_quotes WHERE rfq_id = p_rfq_id AND id <> p_quote_id AND status = 'rejected' LOOP
    PERFORM public.notify_business(v_rejected.wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_quote_rejected',
      'Quote not selected', format('Your quote for "%s" was not selected.', v_rfq.title), '/wholesaler/rfqs/' || p_rfq_id);
  END LOOP;

  PERFORM public.write_audit_log('RFQ awarded', v_rfq.pharmacy_name, 'rfq', p_rfq_id, v_rfq.title,
    jsonb_build_object('quote_id', p_quote_id, 'wholesaler_id', v_quote.wholesaler_id, 'order_id', v_order_id, 'amount_ghs', v_subtotal + v_fee),
    _business_id => v_rfq.pharmacy_id);

  RETURN v_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.award_rfq_quote(UUID, UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.award_rfq_quote(UUID, UUID, BOOLEAN) TO authenticated;
