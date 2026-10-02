-- RFQ phase 5, part 2: logic.
--
--  * submit_rfq_quote -- rebuilt on its exact current body (20261011110000_audit_centre_logic.sql)
--    to accept delivery charge / lead time / payment terms on the quote and, per line, an
--    available quantity (<= requested) and a discount. A re-submission is now audited as
--    'RFQ quote revised' instead of repeating 'RFQ quote submitted' (a gap found in the review).
--    Its parameter list grows, so the old signature is dropped first (CREATE OR REPLACE cannot
--    change a function's parameter count -- see the earlier write_audit_log overload bug).
--  * award_rfq_lines -- new. Awards chosen quote lines (optionally partial quantities) to one or
--    more suppliers in a single call, creating one real order per supplier at the quoted final
--    prices. award_rfq_quote is left exactly as it was.

DROP FUNCTION IF EXISTS public.submit_rfq_quote(UUID, UUID, JSONB, TEXT, TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION public.submit_rfq_quote(
  p_rfq_id UUID,
  p_wholesaler_id UUID,
  p_items JSONB,
  p_delivery_notes TEXT DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_delivery_charge NUMERIC DEFAULT 0,
  p_lead_time_days INTEGER DEFAULT NULL,
  p_payment_terms TEXT DEFAULT NULL
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
  v_existing BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF NOT public.can_act_for_business(p_wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to submit quotes for this wholesaler.';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Quote at least one item.';
  END IF;
  IF p_valid_until IS NOT NULL AND p_valid_until <= now() THEN RAISE EXCEPTION 'The quote validity date must be in the future.'; END IF;
  IF COALESCE(p_delivery_charge, 0) < 0 THEN RAISE EXCEPTION 'The delivery charge cannot be negative.'; END IF;
  IF p_lead_time_days IS NOT NULL AND p_lead_time_days < 0 THEN RAISE EXCEPTION 'The lead time cannot be negative.'; END IF;
  IF p_payment_terms IS NOT NULL AND char_length(p_payment_terms) > 200 THEN RAISE EXCEPTION 'Payment terms are too long (200 characters maximum).'; END IF;

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
  v_existing := EXISTS (SELECT 1 FROM public.rfq_quotes WHERE rfq_id = p_rfq_id AND wholesaler_id = p_wholesaler_id);

  INSERT INTO public.rfq_quotes (rfq_id, wholesaler_id, status, delivery_notes, valid_until, total_ghs, submitted_at,
    delivery_charge_ghs, lead_time_days, payment_terms)
  VALUES (p_rfq_id, p_wholesaler_id, 'submitted', NULLIF(btrim(p_delivery_notes), ''), p_valid_until, 0, now(),
    COALESCE(p_delivery_charge, 0), p_lead_time_days, NULLIF(btrim(p_payment_terms), ''))
  ON CONFLICT (rfq_id, wholesaler_id) DO UPDATE SET
    status = 'submitted', delivery_notes = EXCLUDED.delivery_notes, valid_until = EXCLUDED.valid_until, submitted_at = now(),
    delivery_charge_ghs = EXCLUDED.delivery_charge_ghs, lead_time_days = EXCLUDED.lead_time_days, payment_terms = EXCLUDED.payment_terms
  RETURNING id INTO v_quote_id;

  DELETE FROM public.rfq_quote_items WHERE rfq_quote_id = v_quote_id;

  CREATE TEMP TABLE tmp_quote_items (
    rfq_item_id UUID, product_id UUID, unit_price_ghs NUMERIC(10,2), quantity INTEGER, discount_percent NUMERIC(5,2), notes TEXT
  ) ON COMMIT DROP;
  INSERT INTO tmp_quote_items
  SELECT (item ->> 'rfqItemId')::UUID, (item ->> 'productId')::UUID, (item ->> 'unitPriceGhs')::NUMERIC,
    NULLIF(item ->> 'quantity', '')::INTEGER, COALESCE(NULLIF(item ->> 'discountPercent', '')::NUMERIC, 0), NULLIF(btrim(item ->> 'notes'), '')
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
  IF EXISTS (SELECT 1 FROM tmp_quote_items t WHERE t.discount_percent < 0 OR t.discount_percent >= 100) THEN
    RAISE EXCEPTION 'A discount must be at least 0%% and less than 100%%.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM tmp_quote_items t JOIN public.rfq_items ri ON ri.id = t.rfq_item_id
    WHERE t.quantity IS NOT NULL AND (t.quantity < 1 OR t.quantity > ri.quantity)
  ) THEN
    RAISE EXCEPTION 'A quoted quantity must be between 1 and the quantity requested.';
  END IF;
  IF EXISTS (SELECT 1 FROM tmp_quote_items t WHERE round(t.unit_price_ghs * (1 - t.discount_percent / 100), 2) <= 0) THEN
    RAISE EXCEPTION 'The price after discount must be greater than zero.';
  END IF;

  INSERT INTO public.rfq_quote_items (rfq_quote_id, rfq_item_id, product_id, quantity, unit_price_ghs, discount_percent, final_unit_price_ghs, line_total_ghs, notes)
  SELECT v_quote_id, t.rfq_item_id, t.product_id, COALESCE(t.quantity, ri.quantity), t.unit_price_ghs, t.discount_percent,
    round(t.unit_price_ghs * (1 - t.discount_percent / 100), 2),
    round(round(t.unit_price_ghs * (1 - t.discount_percent / 100), 2) * COALESCE(t.quantity, ri.quantity), 2), t.notes
  FROM tmp_quote_items t JOIN public.rfq_items ri ON ri.id = t.rfq_item_id;

  SELECT COALESCE(SUM(line_total_ghs), 0) INTO v_total FROM public.rfq_quote_items WHERE rfq_quote_id = v_quote_id;
  UPDATE public.rfq_quotes SET total_ghs = v_total WHERE id = v_quote_id;

  PERFORM public.notify_business(v_rfq.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'rfq_quote_received',
    CASE WHEN v_existing THEN 'Quote updated' ELSE 'New quote received' END,
    format(CASE WHEN v_existing THEN '%s updated their quote for your RFQ.' ELSE '%s submitted a quote for your RFQ.' END, v_wholesaler_name),
    '/pharmacy/rfqs/' || p_rfq_id);

  PERFORM public.write_audit_log(CASE WHEN v_existing THEN 'RFQ quote revised' ELSE 'RFQ quote submitted' END,
    v_wholesaler_name, 'rfq_quote', v_quote_id, v_wholesaler_name,
    jsonb_build_object('rfq_id', p_rfq_id, 'total_ghs', v_total, 'item_count', v_item_count,
      'delivery_charge_ghs', COALESCE(p_delivery_charge, 0), 'lead_time_days', p_lead_time_days),
    _business_id => p_wholesaler_id);

  RETURN v_quote_id;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_rfq_quote(UUID, UUID, JSONB, TEXT, TIMESTAMPTZ, NUMERIC, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_rfq_quote(UUID, UUID, JSONB, TEXT, TIMESTAMPTZ, NUMERIC, INTEGER, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- award_rfq_lines: award specific quote lines (full or partial quantity) to one or more suppliers.
-- p_awards = [{ "quoteItemId": uuid, "quantity": int }, ...]. One order is created per supplier at
-- that supplier's quoted FINAL unit prices; stock, order terms and the optional credit path follow
-- the same rules as award_rfq_quote / checkout. Every submitted quote that wins nothing is
-- rejected (and told only that it wasn't selected). A supplier's delivery charge, when it quoted
-- one, replaces the order-terms delivery fee for that supplier's order.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.award_rfq_lines(
  p_rfq_id UUID,
  p_awards JSONB,
  p_use_credit BOOLEAN DEFAULT false
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rfq RECORD;
  v_entry RECORD;
  v_line RECORD;
  v_wh RECORD;
  v_terms RECORD;
  v_terms_found BOOLEAN;
  v_credit RECORD;
  v_credit_outstanding NUMERIC;
  v_order_id UUID;
  v_order_ids UUID[] := ARRAY[]::UUID[];
  v_winning_quote_ids UUID[] := ARRAY[]::UUID[];
  v_subtotal NUMERIC(12,2);
  v_grand_total NUMERIC(12,2) := 0;
  v_fee NUMERIC(10,2);
  v_due_date DATE;
  v_wholesaler_name TEXT;
  v_line_count INTEGER;
  v_total_lines INTEGER;
  v_product RECORD;
  v_rejected RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT r.id, r.pharmacy_id, r.status, r.title, b.name AS pharmacy_name INTO v_rfq
  FROM public.rfqs r JOIN public.businesses b ON b.id = r.pharmacy_id
  WHERE r.id = p_rfq_id FOR UPDATE OF r;
  IF NOT FOUND THEN RAISE EXCEPTION 'RFQ not found.'; END IF;
  IF NOT public.can_act_for_business(v_rfq.pharmacy_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to award quotes for this pharmacy.';
  END IF;
  IF v_rfq.status <> 'open' THEN RAISE EXCEPTION 'This RFQ is not open to be awarded.'; END IF;
  IF p_awards IS NULL OR jsonb_typeof(p_awards) <> 'array' OR jsonb_array_length(p_awards) = 0 THEN
    RAISE EXCEPTION 'Choose at least one line to award.';
  END IF;
  v_total_lines := jsonb_array_length(p_awards);

  -- Validate every requested line before touching anything.
  FOR v_entry IN
    SELECT (a ->> 'quoteItemId')::UUID AS quote_item_id, (a ->> 'quantity')::INTEGER AS qty
    FROM jsonb_array_elements(p_awards) a
  LOOP
    IF v_entry.quote_item_id IS NULL OR v_entry.qty IS NULL OR v_entry.qty < 1 THEN
      RAISE EXCEPTION 'Each awarded line needs a quote line and a quantity of at least 1.';
    END IF;
    SELECT qi.id, qi.quantity, q.status, q.rfq_id INTO v_line
    FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id
    WHERE qi.id = v_entry.quote_item_id;
    IF NOT FOUND OR v_line.rfq_id <> p_rfq_id THEN RAISE EXCEPTION 'A selected quote line does not belong to this RFQ.'; END IF;
    IF v_line.status <> 'submitted' THEN RAISE EXCEPTION 'Only lines from a submitted quote can be awarded.'; END IF;
    IF v_entry.qty > v_line.quantity THEN
      RAISE EXCEPTION 'You cannot award more than the % unit(s) the supplier offered on a line.', v_line.quantity;
    END IF;
  END LOOP;
  IF v_total_lines <> (SELECT COUNT(DISTINCT a ->> 'quoteItemId') FROM jsonb_array_elements(p_awards) a) THEN
    RAISE EXCEPTION 'Each quote line can only be awarded once.';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT qi.rfq_item_id, SUM((a ->> 'quantity')::INTEGER) AS awarded
      FROM jsonb_array_elements(p_awards) a JOIN public.rfq_quote_items qi ON qi.id = (a ->> 'quoteItemId')::UUID
      GROUP BY qi.rfq_item_id
    ) s JOIN public.rfq_items ri ON ri.id = s.rfq_item_id
    WHERE s.awarded > ri.quantity
  ) THEN
    RAISE EXCEPTION 'The awarded quantities for an item add up to more than was requested.';
  END IF;

  -- One order per supplier, in a stable order so concurrent awards lock products consistently.
  FOR v_wh IN
    SELECT DISTINCT q.id AS quote_id, q.wholesaler_id, q.delivery_charge_ghs
    FROM jsonb_array_elements(p_awards) a
    JOIN public.rfq_quote_items qi ON qi.id = (a ->> 'quoteItemId')::UUID
    JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id
    ORDER BY q.wholesaler_id
  LOOP
    SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wh.wholesaler_id;
    v_subtotal := 0;
    v_line_count := 0;

    FOR v_line IN
      SELECT qi.id AS quote_item_id, qi.rfq_item_id, qi.product_id, qi.final_unit_price_ghs, (a ->> 'quantity')::INTEGER AS qty
      FROM jsonb_array_elements(p_awards) a JOIN public.rfq_quote_items qi ON qi.id = (a ->> 'quoteItemId')::UUID
      WHERE qi.rfq_quote_id = v_wh.quote_id
      ORDER BY qi.product_id, qi.id
    LOOP
      -- Re-read under lock each time so two lines backed by the same product are checked against
      -- the stock the earlier line already left behind.
      SELECT p.name, p.stock, p.active INTO v_product FROM public.products p WHERE p.id = v_line.product_id FOR UPDATE;
      IF NOT v_product.active THEN RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name; END IF;
      IF v_product.stock < v_line.qty THEN
        RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
      END IF;
      UPDATE public.products SET stock = stock - v_line.qty WHERE id = v_line.product_id;
      v_subtotal := v_subtotal + round(v_line.final_unit_price_ghs * v_line.qty, 2);
      v_line_count := v_line_count + 1;
    END LOOP;

    v_fee := 0;
    SELECT t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs INTO v_terms
    FROM public.wholesaler_order_terms t WHERE t.wholesaler_id = v_wh.wholesaler_id;
    v_terms_found := FOUND;
    IF v_terms_found AND v_terms.min_order_value_ghs > 0 AND v_subtotal < v_terms.min_order_value_ghs THEN
      RAISE EXCEPTION '% requires a minimum order of GHS % (the lines awarded to them come to GHS %).',
        v_wholesaler_name, to_char(v_terms.min_order_value_ghs, 'FM999,999,990.00'), to_char(v_subtotal, 'FM999,999,990.00');
    END IF;
    IF v_wh.delivery_charge_ghs > 0 THEN
      v_fee := v_wh.delivery_charge_ghs;
    ELSIF v_terms_found AND v_terms.delivery_fee_ghs > 0
       AND NOT (v_terms.free_delivery_threshold_ghs IS NOT NULL AND v_subtotal >= v_terms.free_delivery_threshold_ghs) THEN
      v_fee := v_terms.delivery_fee_ghs;
    END IF;

    v_due_date := NULL;
    IF p_use_credit THEN
      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active INTO v_credit
      FROM public.wholesaler_credit_terms c
      WHERE c.wholesaler_id = v_wh.wholesaler_id AND c.pharmacy_id = v_rfq.pharmacy_id
      FOR UPDATE;
      IF NOT FOUND OR NOT v_credit.active THEN
        RAISE EXCEPTION '% has not approved credit for your pharmacy.', v_wholesaler_name;
      END IF;
      SELECT COALESCE(SUM(o.total_ghs), 0) INTO v_credit_outstanding
      FROM public.orders o
      WHERE o.wholesaler_id = v_wh.wholesaler_id AND o.pharmacy_id = v_rfq.pharmacy_id
        AND o.is_credit_order AND o.status <> 'cancelled' AND o.payment_status IN ('unpaid', 'failed');
      IF v_credit_outstanding + v_subtotal + v_fee > v_credit.credit_limit_ghs THEN
        RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
          v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_subtotal + v_fee, 'FM999,999,990.00');
      END IF;
      v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;
    END IF;

    INSERT INTO public.orders (pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date, notes)
    VALUES (v_rfq.pharmacy_id, v_wh.wholesaler_id, v_subtotal, 0, v_fee, v_subtotal + v_fee, 'cod', p_use_credit, v_due_date,
      'Created from RFQ ' || v_rfq.title)
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs)
    SELECT v_order_id, qi.product_id, p.name, (a ->> 'quantity')::INTEGER, qi.final_unit_price_ghs, qi.final_unit_price_ghs, 0
    FROM jsonb_array_elements(p_awards) a
    JOIN public.rfq_quote_items qi ON qi.id = (a ->> 'quoteItemId')::UUID
    JOIN public.products p ON p.id = qi.product_id
    WHERE qi.rfq_quote_id = v_wh.quote_id;

    INSERT INTO public.rfq_awards (rfq_id, rfq_item_id, rfq_quote_id, rfq_quote_item_id, wholesaler_id, quantity, unit_price_ghs, order_id, created_by)
    SELECT p_rfq_id, qi.rfq_item_id, qi.rfq_quote_id, qi.id, v_wh.wholesaler_id, (a ->> 'quantity')::INTEGER, qi.final_unit_price_ghs, v_order_id, auth.uid()
    FROM jsonb_array_elements(p_awards) a
    JOIN public.rfq_quote_items qi ON qi.id = (a ->> 'quoteItemId')::UUID
    WHERE qi.rfq_quote_id = v_wh.quote_id;

    IF p_use_credit THEN
      INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
      VALUES (v_wh.wholesaler_id, v_rfq.pharmacy_id, v_order_id, 'invoice', 'debit', v_subtotal + v_fee, auth.uid());
    END IF;

    UPDATE public.rfq_quotes SET status = 'accepted' WHERE id = v_wh.quote_id;
    v_order_ids := array_append(v_order_ids, v_order_id);
    v_winning_quote_ids := array_append(v_winning_quote_ids, v_wh.quote_id);
    v_grand_total := v_grand_total + v_subtotal + v_fee;

    PERFORM public.notify_business(v_wh.wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_quote_accepted',
      'Quote accepted', format('Your quote for "%s" was accepted for %s line(s). A new order has been created.', v_rfq.title, v_line_count),
      '/wholesaler?tab=orders');
  END LOOP;

  FOR v_rejected IN
    SELECT id, wholesaler_id FROM public.rfq_quotes WHERE rfq_id = p_rfq_id AND status = 'submitted'
  LOOP
    UPDATE public.rfq_quotes SET status = 'rejected' WHERE id = v_rejected.id;
    PERFORM public.notify_business(v_rejected.wholesaler_id, ARRAY['owner', 'manager', 'cashier', 'warehouse'], 'rfq_quote_rejected',
      'Quote not selected', format('Your quote for "%s" was not selected.', v_rfq.title), '/wholesaler/rfqs/' || p_rfq_id);
  END LOOP;

  UPDATE public.rfqs SET status = 'awarded',
    awarded_quote_id = CASE WHEN cardinality(v_winning_quote_ids) = 1 THEN v_winning_quote_ids[1] END,
    awarded_order_id = CASE WHEN cardinality(v_order_ids) = 1 THEN v_order_ids[1] END
  WHERE id = p_rfq_id;

  PERFORM public.write_audit_log('RFQ awarded', v_rfq.pharmacy_name, 'rfq', p_rfq_id, v_rfq.title,
    jsonb_build_object('order_ids', to_jsonb(v_order_ids), 'supplier_count', cardinality(v_order_ids),
      'line_count', v_total_lines, 'amount_ghs', v_grand_total, 'split', cardinality(v_order_ids) > 1),
    _business_id => v_rfq.pharmacy_id);

  RETURN jsonb_build_object('order_ids', to_jsonb(v_order_ids));
END;
$$;

REVOKE ALL ON FUNCTION public.award_rfq_lines(UUID, JSONB, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.award_rfq_lines(UUID, JSONB, BOOLEAN) TO authenticated;
