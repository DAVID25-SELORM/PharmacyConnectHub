-- Returns management (Phase 1).
--
-- Workflow: requested -> approved -> returned -> inspected -> resolved
--           (requested -> rejected | cancelled at the start)
--   * Pharmacy (owner/manager/cashier) requests a return of DELIVERED order lines within 30 days.
--   * Wholesaler (owner/manager/cashier) approves or rejects, marks the goods as returned;
--     owner/manager inspect (accepted quantity + restock yes/no per line) and resolve.
--   * Resolution: refund | credit | replacement | none.
--       - restockable accepted units go back into products.stock (inventory);
--       - refund/credit become a CREDIT line on the customer statement (customer balance);
--       - every step is written to audit_logs (admin Activity Log).
--
-- All writes go through SECURITY DEFINER RPCs that check the caller explicitly. The tables have
-- RLS enabled with an admin-only SELECT policy and no write grants, so the API cannot touch rows
-- directly. Sales reports and the customer list revenue are NOT netted for returns yet.

CREATE SEQUENCE IF NOT EXISTS public.order_returns_seq START 1000;

CREATE TABLE public.order_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  return_number TEXT NOT NULL UNIQUE DEFAULT ('RET-' || lpad(nextval('public.order_returns_seq')::text, 6, '0')),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  reason TEXT NOT NULL CHECK (reason IN ('wrong_product', 'damaged', 'short_dated', 'over_delivered', 'quality_issue', 'wrong_quantity')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 1000),
  status TEXT NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested', 'approved', 'rejected', 'cancelled', 'returned', 'inspected', 'resolved')),
  wholesaler_note TEXT CHECK (wholesaler_note IS NULL OR char_length(wholesaler_note) <= 1000),
  resolution TEXT CHECK (resolution IS NULL OR resolution IN ('refund', 'credit', 'replacement', 'none')),
  resolved_amount_ghs NUMERIC(12,2) CHECK (resolved_amount_ghs IS NULL OR resolved_amount_ghs >= 0),
  requested_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  returned_at TIMESTAMPTZ,
  inspected_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((status = 'resolved') = (resolution IS NOT NULL))
);

CREATE TABLE public.order_return_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id UUID NOT NULL REFERENCES public.order_returns(id) ON DELETE CASCADE,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
  product_name TEXT NOT NULL,
  unit_price_ghs NUMERIC(10,2) NOT NULL CHECK (unit_price_ghs >= 0),
  quantity_requested INTEGER NOT NULL CHECK (quantity_requested > 0),
  quantity_accepted INTEGER CHECK (quantity_accepted IS NULL OR quantity_accepted >= 0),
  restock BOOLEAN NOT NULL DEFAULT FALSE,
  UNIQUE (return_id, order_item_id),
  CHECK (quantity_accepted IS NULL OR quantity_accepted <= quantity_requested)
);

CREATE INDEX order_returns_wholesaler_idx ON public.order_returns (wholesaler_id, status, created_at DESC);
CREATE INDEX order_returns_pharmacy_idx ON public.order_returns (pharmacy_id, created_at DESC);
CREATE INDEX order_returns_order_idx ON public.order_returns (order_id);
CREATE INDEX order_return_items_order_item_idx ON public.order_return_items (order_item_id);

CREATE TRIGGER trg_order_returns_updated BEFORE UPDATE ON public.order_returns
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.order_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_return_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read returns" ON public.order_returns FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read return items" ON public.order_return_items FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_returns, public.order_return_items FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_returns, public.order_return_items TO authenticated;

-- ---------------------------------------------------------------------------
-- Access helper. Levels: 'read' (any active staff), 'process' (owner/manager/cashier),
-- 'manage' (owner/manager). The business owner always passes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_act_for_business(p_business_id UUID, p_level TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR (
      public.is_business_staff(auth.uid(), p_business_id)
      AND public.get_staff_role(auth.uid(), p_business_id)::TEXT = ANY (
        CASE p_level
          WHEN 'manage' THEN ARRAY['owner', 'manager']
          WHEN 'process' THEN ARRAY['owner', 'manager', 'cashier']
          ELSE ARRAY['owner', 'manager', 'cashier', 'assistant']
        END
      )
    )
$$;
REVOKE ALL ON FUNCTION public.can_act_for_business(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- What can still be returned from an order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_returnable_items(p_order_id UUID)
RETURNS TABLE (
  order_item_id UUID,
  product_name TEXT,
  quantity_ordered INTEGER,
  quantity_claimed INTEGER,
  quantity_available INTEGER,
  unit_price_ghs NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
BEGIN
  SELECT o.id, o.pharmacy_id, o.status, o.delivered_at, o.updated_at INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;
  IF v_order.status <> 'delivered' THEN RAISE EXCEPTION 'Only delivered orders can be returned.'; END IF;
  IF now() > COALESCE(v_order.delivered_at, v_order.updated_at) + interval '30 days' THEN
    RAISE EXCEPTION 'The 30-day return window for this order has passed.';
  END IF;

  RETURN QUERY
  SELECT oi.id, oi.product_name, oi.quantity,
    COALESCE(c.claimed, 0)::INTEGER,
    GREATEST(oi.quantity - COALESCE(c.claimed, 0), 0)::INTEGER,
    oi.unit_price_ghs
  FROM public.order_items oi
  LEFT JOIN LATERAL (
    SELECT SUM(CASE WHEN r.status = 'resolved' THEN COALESCE(ri.quantity_accepted, 0) ELSE ri.quantity_requested END) AS claimed
    FROM public.order_return_items ri JOIN public.order_returns r ON r.id = ri.return_id
    WHERE ri.order_item_id = oi.id AND r.status NOT IN ('rejected', 'cancelled')
  ) c ON TRUE
  WHERE oi.order_id = p_order_id
  ORDER BY oi.product_name;
END;
$$;

-- ---------------------------------------------------------------------------
-- Pharmacy: request a return
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_order_return(
  p_order_id UUID,
  p_reason TEXT,
  p_note TEXT,
  p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_pharmacy RECORD;
  v_return public.order_returns%ROWTYPE;
  v_entry JSONB;
  v_oi RECORD;
  v_qty INTEGER;
  v_claimed INTEGER;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to request a return.'; END IF;
  SELECT o.id, o.pharmacy_id, o.wholesaler_id, o.order_number, o.status, o.delivered_at, o.updated_at
    INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT public.can_act_for_business(v_order.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to request a return for this order.';
  END IF;
  SELECT b.name, b.verification_status INTO v_pharmacy FROM public.businesses b WHERE b.id = v_order.pharmacy_id;
  IF v_pharmacy.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified to request returns.'; END IF;
  IF v_order.status <> 'delivered' THEN RAISE EXCEPTION 'Only delivered orders can be returned.'; END IF;
  IF now() > COALESCE(v_order.delivered_at, v_order.updated_at) + interval '30 days' THEN
    RAISE EXCEPTION 'The 30-day return window for this order has passed.';
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('wrong_product', 'damaged', 'short_dated', 'over_delivered', 'quality_issue', 'wrong_quantity') THEN
    RAISE EXCEPTION 'Choose a return reason.';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 1000 THEN RAISE EXCEPTION 'The note is too long (1000 characters maximum).'; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'Choose between 1 and 20 order lines to return.';
  END IF;

  -- Serialise concurrent requests for the same order so quantities cannot be over-claimed.
  PERFORM 1 FROM public.order_items oi WHERE oi.order_id = p_order_id FOR UPDATE;

  INSERT INTO public.order_returns (order_id, pharmacy_id, wholesaler_id, reason, note, requested_by)
  VALUES (p_order_id, v_order.pharmacy_id, v_order.wholesaler_id, p_reason, v_note, auth.uid())
  RETURNING * INTO v_return;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := (v_entry ->> 'quantity')::INTEGER;
    IF v_qty IS NULL OR v_qty <= 0 THEN RAISE EXCEPTION 'Each returned line needs a quantity above zero.'; END IF;
    SELECT oi.id, oi.product_id, oi.product_name, oi.quantity, oi.unit_price_ghs INTO v_oi
    FROM public.order_items oi WHERE oi.id = (v_entry ->> 'order_item_id')::UUID AND oi.order_id = p_order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'One of the lines does not belong to this order.'; END IF;

    SELECT COALESCE(SUM(CASE WHEN r.status = 'resolved' THEN COALESCE(ri.quantity_accepted, 0) ELSE ri.quantity_requested END), 0)
      INTO v_claimed
    FROM public.order_return_items ri JOIN public.order_returns r ON r.id = ri.return_id
    WHERE ri.order_item_id = v_oi.id AND r.status NOT IN ('rejected', 'cancelled');
    IF v_qty > v_oi.quantity - v_claimed THEN
      RAISE EXCEPTION 'Only % unit(s) of % can still be returned.', GREATEST(v_oi.quantity - v_claimed, 0), v_oi.product_name;
    END IF;

    INSERT INTO public.order_return_items (return_id, order_item_id, product_id, product_name, unit_price_ghs, quantity_requested)
    VALUES (v_return.id, v_oi.id, v_oi.product_id, v_oi.product_name, v_oi.unit_price_ghs, v_qty);
  END LOOP;

  PERFORM public.write_audit_log('Return requested', v_pharmacy.name, 'order_return', v_return.id, v_return.return_number,
    jsonb_build_object('order_number', v_order.order_number, 'reason', p_reason, 'lines', jsonb_array_length(p_items)));
  RETURN v_return.id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Pharmacy: cancel a request that has not been reviewed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order_return(p_return_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_name TEXT;
BEGIN
  SELECT * INTO v_return FROM public.order_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND OR NOT public.can_act_for_business(v_return.pharmacy_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to cancel this return.';
  END IF;
  IF v_return.status <> 'requested' THEN RAISE EXCEPTION 'Only a return that has not been reviewed can be cancelled.'; END IF;
  UPDATE public.order_returns SET status = 'cancelled', cancelled_at = now() WHERE id = p_return_id;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_return.pharmacy_id;
  PERFORM public.write_audit_log('Return cancelled', v_name, 'order_return', v_return.id, v_return.return_number, '{}'::JSONB);
END;
$$;

-- ---------------------------------------------------------------------------
-- Wholesaler steps
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._load_return_for_wholesaler(p_return_id UUID, p_level TEXT, p_from TEXT)
RETURNS public.order_returns
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_status TEXT;
BEGIN
  SELECT * INTO v_return FROM public.order_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND OR NOT public.can_act_for_business(v_return.wholesaler_id, p_level) THEN
    RAISE EXCEPTION 'You do not have permission to update this return.';
  END IF;
  SELECT b.verification_status INTO v_status FROM public.businesses b WHERE b.id = v_return.wholesaler_id;
  IF v_status <> 'approved' THEN RAISE EXCEPTION 'Your business must be verified to process returns.'; END IF;
  IF v_return.status <> p_from THEN
    RAISE EXCEPTION 'This return is % and cannot be moved to the next step.', v_return.status;
  END IF;
  RETURN v_return;
END;
$$;
REVOKE ALL ON FUNCTION public._load_return_for_wholesaler(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.review_order_return(p_return_id UUID, p_approve BOOLEAN, p_note TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_name TEXT;
BEGIN
  v_return := public._load_return_for_wholesaler(p_return_id, 'process', 'requested');
  IF NOT COALESCE(p_approve, FALSE) AND v_note IS NULL THEN RAISE EXCEPTION 'Give the pharmacy a reason for rejecting this return.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 1000 THEN RAISE EXCEPTION 'The note is too long (1000 characters maximum).'; END IF;
  UPDATE public.order_returns
  SET status = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
      reviewed_by = auth.uid(), reviewed_at = now(), wholesaler_note = v_note
  WHERE id = p_return_id;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_return.wholesaler_id;
  PERFORM public.write_audit_log(CASE WHEN p_approve THEN 'Return approved' ELSE 'Return rejected' END, v_name,
    'order_return', v_return.id, v_return.return_number, '{}'::JSONB);
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_order_return_returned(p_return_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_name TEXT;
BEGIN
  v_return := public._load_return_for_wholesaler(p_return_id, 'process', 'approved');
  UPDATE public.order_returns SET status = 'returned', returned_at = now() WHERE id = p_return_id;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_return.wholesaler_id;
  PERFORM public.write_audit_log('Return received', v_name, 'order_return', v_return.id, v_return.return_number, '{}'::JSONB);
END;
$$;

CREATE OR REPLACE FUNCTION public.inspect_order_return(p_return_id UUID, p_items JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_entry JSONB;
  v_item public.order_return_items%ROWTYPE;
  v_accepted INTEGER;
  v_seen INTEGER := 0;
  v_expected INTEGER;
  v_name TEXT;
BEGIN
  v_return := public._load_return_for_wholesaler(p_return_id, 'manage', 'returned');
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'Inspection details are required.'; END IF;
  SELECT COUNT(*) INTO v_expected FROM public.order_return_items WHERE return_id = p_return_id;
  IF jsonb_array_length(p_items) <> v_expected THEN RAISE EXCEPTION 'Record the inspection result for every returned line.'; END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_item FROM public.order_return_items
    WHERE id = (v_entry ->> 'return_item_id')::UUID AND return_id = p_return_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'One of the inspected lines does not belong to this return.'; END IF;
    v_accepted := (v_entry ->> 'quantity_accepted')::INTEGER;
    IF v_accepted IS NULL OR v_accepted < 0 OR v_accepted > v_item.quantity_requested THEN
      RAISE EXCEPTION 'Accepted quantity for % must be between 0 and %.', v_item.product_name, v_item.quantity_requested;
    END IF;
    UPDATE public.order_return_items
    SET quantity_accepted = v_accepted, restock = COALESCE((v_entry ->> 'restock')::BOOLEAN, FALSE) AND v_accepted > 0
    WHERE id = v_item.id;
    v_seen := v_seen + 1;
  END LOOP;
  IF v_seen <> v_expected THEN RAISE EXCEPTION 'Record the inspection result for every returned line.'; END IF;

  UPDATE public.order_returns SET status = 'inspected', inspected_at = now() WHERE id = p_return_id;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_return.wholesaler_id;
  PERFORM public.write_audit_log('Return inspected', v_name, 'order_return', v_return.id, v_return.return_number, '{}'::JSONB);
END;
$$;

CREATE OR REPLACE FUNCTION public.resolve_order_return(p_return_id UUID, p_resolution TEXT, p_note TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_return public.order_returns%ROWTYPE;
  v_total NUMERIC(12,2);
  v_units INTEGER;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_item RECORD;
  v_name TEXT;
BEGIN
  v_return := public._load_return_for_wholesaler(p_return_id, 'manage', 'inspected');
  IF p_resolution IS NULL OR p_resolution NOT IN ('refund', 'credit', 'replacement', 'none') THEN
    RAISE EXCEPTION 'Choose how to resolve this return.';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 1000 THEN RAISE EXCEPTION 'The note is too long (1000 characters maximum).'; END IF;

  SELECT COALESCE(SUM(quantity_accepted * unit_price_ghs), 0), COALESCE(SUM(quantity_accepted), 0)
    INTO v_total, v_units FROM public.order_return_items WHERE return_id = p_return_id;
  IF v_units = 0 AND p_resolution <> 'none' THEN
    RAISE EXCEPTION 'No units were accepted, so the only possible resolution is "No action".';
  END IF;
  IF v_units > 0 AND p_resolution = 'none' THEN
    RAISE EXCEPTION 'Accepted units need a refund, credit or replacement.';
  END IF;

  FOR v_item IN
    SELECT product_id, quantity_accepted FROM public.order_return_items
    WHERE return_id = p_return_id AND restock AND quantity_accepted > 0 AND product_id IS NOT NULL
  LOOP
    UPDATE public.products SET stock = stock + v_item.quantity_accepted WHERE id = v_item.product_id;
  END LOOP;

  UPDATE public.order_returns
  SET status = 'resolved', resolution = p_resolution, resolved_amount_ghs = v_total, resolved_at = now(),
      wholesaler_note = COALESCE(v_note, wholesaler_note)
  WHERE id = p_return_id;

  SELECT name INTO v_name FROM public.businesses WHERE id = v_return.wholesaler_id;
  PERFORM public.write_audit_log('Return resolved', v_name, 'order_return', v_return.id, v_return.return_number,
    jsonb_build_object('resolution', p_resolution, 'amount_ghs', v_total, 'units_accepted', v_units));
  RETURN v_total;
END;
$$;

-- ---------------------------------------------------------------------------
-- Listing for either side (paged)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_order_returns(
  p_business_id UUID,
  p_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  id UUID,
  return_number TEXT,
  order_id UUID,
  order_number TEXT,
  status TEXT,
  reason TEXT,
  note TEXT,
  wholesaler_note TEXT,
  resolution TEXT,
  resolved_amount_ghs NUMERIC,
  counterparty_name TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  items JSONB,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_business_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to these returns.';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN ('requested', 'approved', 'rejected', 'cancelled', 'returned', 'inspected', 'resolved') THEN
    RAISE EXCEPTION 'Unknown return status.';
  END IF;

  RETURN QUERY
  SELECT r.id, r.return_number, r.order_id, o.order_number, r.status, r.reason, r.note, r.wholesaler_note,
    r.resolution, r.resolved_amount_ghs,
    cp.name,
    r.created_at, r.updated_at,
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', ri.id, 'product_name', ri.product_name, 'unit_price_ghs', ri.unit_price_ghs,
        'quantity_requested', ri.quantity_requested, 'quantity_accepted', ri.quantity_accepted, 'restock', ri.restock)
        ORDER BY ri.product_name)
      FROM public.order_return_items ri WHERE ri.return_id = r.id), '[]'::JSONB),
    COUNT(*) OVER ()
  FROM public.order_returns r
  JOIN public.orders o ON o.id = r.order_id
  JOIN public.businesses cp ON cp.id = CASE WHEN r.wholesaler_id = p_business_id THEN r.pharmacy_id ELSE r.wholesaler_id END
  WHERE (r.wholesaler_id = p_business_id OR r.pharmacy_id = p_business_id)
    AND (p_status IS NULL OR r.status = p_status)
  ORDER BY r.created_at DESC, r.id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- ---------------------------------------------------------------------------
-- Return credits for the statement. order_returns is hidden from direct reads, and the statement
-- runs as the caller, so this definer helper hands over only the resolved refund/credit lines of
-- one wholesaler/pharmacy pair, and only to people who belong to either business.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.statement_return_credits(p_wholesaler_id UUID, p_pharmacy_id UUID)
RETURNS TABLE (resolved_at TIMESTAMPTZ, order_id UUID, return_number TEXT, amount_ghs NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL
     OR NOT (public.can_act_for_business(p_wholesaler_id, 'read') OR public.can_act_for_business(p_pharmacy_id, 'read')) THEN
    RAISE EXCEPTION 'You do not have access to this statement.';
  END IF;
  RETURN QUERY
  SELECT r.resolved_at, r.order_id, r.return_number, r.resolved_amount_ghs
  FROM public.order_returns r
  WHERE r.wholesaler_id = p_wholesaler_id AND r.pharmacy_id = p_pharmacy_id
    AND r.status = 'resolved' AND r.resolution IN ('refund', 'credit') AND r.resolved_amount_ghs > 0;
END;
$$;

-- ---------------------------------------------------------------------------
-- Customer statement: refunded / credited returns are CREDIT lines (kind = 'return').
-- Same function as before with one extra ledger source.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_statement(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  c_line_cap CONSTANT INTEGER := 2000;
  v_wholesaler RECORD;
  v_pharmacy RECORD;
  v_opening NUMERIC;
  v_debits NUMERIC;
  v_credits NUMERIC;
  v_lines JSONB;
  v_line_count BIGINT;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
    RAISE EXCEPTION 'Choose a valid date range for the statement.';
  END IF;

  SELECT id, name, city, region, owner_id INTO v_wholesaler FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  SELECT id, name, city, region, owner_id INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_wholesaler.id IS NULL OR v_pharmacy.id IS NULL THEN RAISE EXCEPTION 'Statement not found.'; END IF;

  IF NOT (
    v_wholesaler.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_wholesaler_id)
    OR v_pharmacy.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_pharmacy_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this statement.';
  END IF;

  WITH ledger AS (
    SELECT o.created_at AS at, 'order'::TEXT AS kind, o.id AS order_id, o.order_number,
      o.total_ghs AS amount, o.discount_amount_ghs AS discount
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
    UNION ALL
    SELECT COALESCE(o.paid_at, o.payment_confirmed_at, o.created_at), 'payment', o.id, o.order_number,
      o.total_ghs, 0::NUMERIC
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status = 'paid'
    UNION ALL
    SELECT c.resolved_at, 'return', c.order_id, c.return_number, c.amount_ghs, 0::NUMERIC
    FROM public.statement_return_credits(p_wholesaler_id, p_pharmacy_id) c
  ),
  opening AS (
    SELECT COALESCE(SUM(CASE WHEN kind = 'order' THEN amount ELSE -amount END), 0) AS v
    FROM ledger WHERE at < p_from
  ),
  in_range AS (SELECT * FROM ledger WHERE at >= p_from AND at < p_to),
  totals AS (
    SELECT COALESCE(SUM(amount) FILTER (WHERE kind = 'order'), 0) AS debits,
      COALESCE(SUM(amount) FILTER (WHERE kind <> 'order'), 0) AS credits,
      COUNT(*) AS n
    FROM in_range
  ),
  running AS (
    SELECT r.*, (SELECT v FROM opening) + SUM(CASE WHEN r.kind = 'order' THEN r.amount ELSE -r.amount END)
      OVER (ORDER BY r.at, r.kind, r.order_number ROWS UNBOUNDED PRECEDING) AS balance
    FROM in_range r
    ORDER BY r.at, r.kind, r.order_number
    LIMIT c_line_cap
  )
  SELECT
    (SELECT v FROM opening), (SELECT debits FROM totals), (SELECT credits FROM totals), (SELECT n FROM totals),
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'date', x.at, 'kind', x.kind, 'order_id', x.order_id, 'order_number', x.order_number,
      'debit', CASE WHEN x.kind = 'order' THEN x.amount ELSE 0 END,
      'credit', CASE WHEN x.kind <> 'order' THEN x.amount ELSE 0 END,
      'discount', x.discount, 'balance', x.balance) ORDER BY x.at, x.kind, x.order_number) FROM running x), '[]'::JSONB)
  INTO v_opening, v_debits, v_credits, v_line_count, v_lines;

  RETURN jsonb_build_object(
    'wholesaler', jsonb_build_object('id', v_wholesaler.id, 'name', v_wholesaler.name, 'city', v_wholesaler.city, 'region', v_wholesaler.region),
    'pharmacy', jsonb_build_object('id', v_pharmacy.id, 'name', v_pharmacy.name, 'city', v_pharmacy.city, 'region', v_pharmacy.region),
    'from', p_from, 'to', p_to,
    'opening_balance', v_opening,
    'total_debits', v_debits,
    'total_credits', v_credits,
    'closing_balance', v_opening + v_debits - v_credits,
    'line_count', v_line_count,
    'truncated', v_line_count > c_line_cap,
    'lines', v_lines
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Grants: only the RPCs below are callable by signed-in users; the helpers are not.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_returnable_items(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_order_return(UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_order_return(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_order_return(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_order_return_returned(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.inspect_order_return(UUID, JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_order_return(UUID, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_order_returns(UUID, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.statement_return_credits(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_returnable_items(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_order_return(UUID, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_order_return(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_order_return(UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_order_return_returned(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.inspect_order_return(UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_order_return(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_order_returns(UUID, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.statement_return_credits(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
