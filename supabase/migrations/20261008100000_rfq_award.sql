-- RFQ, part 3: award_rfq_quote. Accepting a quote auto-converts it into a real order at the
-- quoted (negotiated) prices -- no catalog discounts apply, the quote's own unit_price_ghs is
-- final. Mirrors create_marketplace_orders' stock-lock discipline (FOR UPDATE + decrement inside
-- the same transaction) and, optionally, its credit-limit check, but is much simpler: exactly one
-- wholesaler is ever involved (the quote's own), so there is no per-wholesaler cart split and no
-- procurement grouping needed.
--
-- Awarding is a financial commitment (it creates a real debt/order), so it is gated tighter than
-- create_rfq/cancel_rfq: owner or manager only, via can_act_for_business(..., 'manage') -- matching
-- record_credit_adjustment's tier, not checkout's cashier-inclusive one.

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

  SELECT r.id, r.pharmacy_id, r.status, r.title INTO v_rfq FROM public.rfqs r WHERE r.id = p_rfq_id;
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

  RETURN v_order_id;
END;
$$;

REVOKE ALL ON FUNCTION public.award_rfq_quote(UUID, UUID, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.award_rfq_quote(UUID, UUID, BOOLEAN) TO authenticated;
