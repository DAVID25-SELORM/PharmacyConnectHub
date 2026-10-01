-- RFQ, part 2: logic. create_rfq / submit_rfq_quote / withdraw_rfq_quote / cancel_rfq.
--
-- Awarding a quote (accepting it, converting it into a real order, rejecting every other quote on
-- the RFQ) is deliberately NOT in this migration -- it needs the same stock-lock and credit-limit
-- discipline as create_marketplace_orders and is a bigger, separate piece of work. This phase ships
-- the request/respond loop first so it can be tested and used (a pharmacy can request and compare
-- quotes) before the award/conversion RPC lands on top of it.
--
-- Every mutation is a SECURITY DEFINER RPC (no direct INSERT/UPDATE/DELETE grant on any rfq_*
-- table, matching the products/procurements precedent); reads go through the plain RLS SELECT
-- policies from the schema migration.

-- ---------------------------------------------------------------------------
-- create_rfq: pharmacy creates an RFQ, inviting specific approved wholesalers.
-- p_items shape: [{ "productName": text, "quantity": int, "notes": text? }, ...]
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

  RETURN v_rfq_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- submit_rfq_quote: an invited wholesaler submits (or revises, while still open) its sealed
-- quote. Resubmitting replaces the previous line items entirely.
-- p_items shape: [{ "rfqItemId": uuid, "productId": uuid, "unitPriceGhs": numeric, "notes": text? }, ...]
-- A wholesaler may quote only a subset of the RFQ's items (it isn't required to cover every line);
-- the quoted quantity always equals the requested quantity for that line -- no partial quantities
-- in this phase.
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

  RETURN v_quote_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- withdraw_rfq_quote: a wholesaler withdraws its own submitted quote while the RFQ is still open.
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
END;
$$;

-- ---------------------------------------------------------------------------
-- cancel_rfq: the pharmacy cancels its own open RFQ before awarding it.
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

  SELECT r.id, r.status, r.pharmacy_id, r.title, b.owner_id INTO v_rfq
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
