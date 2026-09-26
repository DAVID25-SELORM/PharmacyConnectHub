-- Batch and expiry tracking for wholesalers (Phase 1).
--
-- products.stock stays the single sellable total that checkout reserves against; batches are an
-- optional layer on top of it:
--   * Receiving a batch adds its quantity to products.stock (stock you had before batches existed
--     simply shows up as "not batched").
--   * A write-off (expired / damaged / other) removes units from both the batch and products.stock.
--   * FEFO (first expiry, first out): for an order, suggest the earliest-expiring non-expired
--     batches; confirming records which batch each unit came from (traceability) and reduces the
--     batch's quantity on hand. products.stock is NOT touched again there: checkout already
--     reserved it. Cancelling the order releases the batch quantities.
--   * Every change is appended to batch_movements and written to the audit log.
--
-- Not built: automatic expiry notifications (needs a scheduler), blocking sales of expired
-- batches at checkout (checkout does not look at batches), restocking returned units into a batch,
-- batch numbers on printed pick sheets/invoices, discounting short-dated stock.
--
-- Tables are RLS-protected with an admin-only SELECT policy; users go through the functions below.

CREATE TABLE public.product_batches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  batch_number TEXT NOT NULL CHECK (char_length(btrim(batch_number)) BETWEEN 1 AND 60),
  expiry_date DATE NOT NULL,
  quantity_received INTEGER NOT NULL CHECK (quantity_received > 0),
  quantity_on_hand INTEGER NOT NULL CHECK (quantity_on_hand >= 0),
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (quantity_on_hand <= quantity_received)
);
CREATE UNIQUE INDEX product_batches_product_number_uniq ON public.product_batches (product_id, lower(btrim(batch_number)));
CREATE INDEX product_batches_wholesaler_expiry_idx ON public.product_batches (wholesaler_id, expiry_date) WHERE quantity_on_hand > 0;
CREATE INDEX product_batches_product_fefo_idx ON public.product_batches (product_id, expiry_date, id) WHERE quantity_on_hand > 0;

CREATE TRIGGER trg_product_batches_updated BEFORE UPDATE ON public.product_batches
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE public.batch_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id UUID NOT NULL REFERENCES public.product_batches(id) ON DELETE CASCADE,
  product_id UUID NOT NULL,
  wholesaler_id UUID NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('received', 'allocated', 'released', 'write_off')),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  order_id UUID,
  reason TEXT CHECK (reason IS NULL OR reason IN ('expired', 'damaged', 'other')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  created_by UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX batch_movements_batch_idx ON public.batch_movements (batch_id, created_at DESC);

CREATE TABLE public.order_batch_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  batch_id UUID NOT NULL REFERENCES public.product_batches(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX order_batch_allocations_order_idx ON public.order_batch_allocations (order_id);
CREATE INDEX order_batch_allocations_batch_idx ON public.order_batch_allocations (batch_id);

ALTER TABLE public.product_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.batch_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_batch_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read batches" ON public.product_batches FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read batch movements" ON public.batch_movements FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read batch allocations" ON public.order_batch_allocations FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.product_batches, public.batch_movements, public.order_batch_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.product_batches, public.batch_movements, public.order_batch_allocations TO authenticated;

-- ---------------------------------------------------------------------------
-- Receive a batch (adds to sellable stock). Owner/manager only.
-- Receiving more of an existing batch number is allowed when the expiry date matches.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.receive_product_batch(
  p_product_id UUID,
  p_batch_number TEXT,
  p_expiry_date DATE,
  p_quantity INTEGER
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product RECORD;
  v_batch public.product_batches%ROWTYPE;
  v_number TEXT := btrim(COALESCE(p_batch_number, ''));
  v_status TEXT;
  v_org TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to receive stock.'; END IF;
  SELECT p.id, p.name, p.wholesaler_id INTO v_product FROM public.products p WHERE p.id = p_product_id FOR UPDATE;
  IF NOT FOUND OR NOT public.can_act_for_business(v_product.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to receive stock for this product.';
  END IF;
  SELECT b.verification_status::TEXT, b.name INTO v_status, v_org FROM public.businesses b WHERE b.id = v_product.wholesaler_id;
  IF v_status <> 'approved' THEN RAISE EXCEPTION 'Your business must be verified to manage stock.'; END IF;
  IF char_length(v_number) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'Enter a batch number (up to 60 characters).'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000000 THEN RAISE EXCEPTION 'Enter a quantity between 1 and 1,000,000.'; END IF;
  IF p_expiry_date IS NULL THEN RAISE EXCEPTION 'Enter the expiry date.'; END IF;
  IF p_expiry_date < current_date THEN RAISE EXCEPTION 'This batch has already expired, so it cannot be received into stock.'; END IF;
  IF p_expiry_date > current_date + interval '10 years' THEN RAISE EXCEPTION 'The expiry date is more than 10 years away. Check the date.'; END IF;

  SELECT * INTO v_batch FROM public.product_batches
  WHERE product_id = p_product_id AND lower(btrim(batch_number)) = lower(v_number) FOR UPDATE;
  IF FOUND THEN
    IF v_batch.expiry_date <> p_expiry_date THEN
      RAISE EXCEPTION 'Batch % already exists with a different expiry date (%).', v_number, v_batch.expiry_date;
    END IF;
    UPDATE public.product_batches
    SET quantity_received = quantity_received + p_quantity, quantity_on_hand = quantity_on_hand + p_quantity
    WHERE id = v_batch.id;
  ELSE
    INSERT INTO public.product_batches (product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand, created_by)
    VALUES (p_product_id, v_product.wholesaler_id, v_number, p_expiry_date, p_quantity, p_quantity, auth.uid())
    RETURNING * INTO v_batch;
  END IF;

  UPDATE public.products SET stock = stock + p_quantity WHERE id = p_product_id;
  INSERT INTO public.batch_movements (batch_id, product_id, wholesaler_id, kind, quantity, created_by)
  VALUES (v_batch.id, p_product_id, v_product.wholesaler_id, 'received', p_quantity, auth.uid());
  PERFORM public.write_audit_log('Batch received', v_org, 'product_batch', v_batch.id, v_number,
    jsonb_build_object('product', v_product.name, 'quantity', p_quantity, 'expiry_date', p_expiry_date));
  RETURN v_batch.id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Write off units (expired / damaged / other). Removes them from the batch AND from sellable stock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.write_off_batch(
  p_batch_id UUID,
  p_quantity INTEGER,
  p_reason TEXT,
  p_note TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_batch public.product_batches%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_org TEXT;
  v_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to write off stock.'; END IF;
  SELECT * INTO v_batch FROM public.product_batches WHERE id = p_batch_id FOR UPDATE;
  IF NOT FOUND OR NOT public.can_act_for_business(v_batch.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to write off this batch.';
  END IF;
  IF p_reason IS NULL OR p_reason NOT IN ('expired', 'damaged', 'other') THEN RAISE EXCEPTION 'Choose a write-off reason.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The note is too long (500 characters maximum).'; END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > v_batch.quantity_on_hand THEN
    RAISE EXCEPTION 'Enter a quantity between 1 and % (the units on hand in this batch).', v_batch.quantity_on_hand;
  END IF;

  UPDATE public.product_batches SET quantity_on_hand = quantity_on_hand - p_quantity WHERE id = p_batch_id;
  UPDATE public.products SET stock = GREATEST(stock - p_quantity, 0) WHERE id = v_batch.product_id;
  INSERT INTO public.batch_movements (batch_id, product_id, wholesaler_id, kind, quantity, reason, note, created_by)
  VALUES (p_batch_id, v_batch.product_id, v_batch.wholesaler_id, 'write_off', p_quantity, p_reason, v_note, auth.uid());
  SELECT name INTO v_org FROM public.businesses WHERE id = v_batch.wholesaler_id;
  SELECT name INTO v_name FROM public.products WHERE id = v_batch.product_id;
  PERFORM public.write_audit_log('Batch written off', v_org, 'product_batch', p_batch_id, v_batch.batch_number,
    jsonb_build_object('product', v_name, 'quantity', p_quantity, 'reason', p_reason));
END;
$$;

-- ---------------------------------------------------------------------------
-- Batch list with expiry buckets and whole-catalogue summary numbers on every row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_product_batches(
  p_business_id UUID,
  p_filter TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  batch_id UUID,
  product_id UUID,
  product_name TEXT,
  batch_number TEXT,
  expiry_date DATE,
  days_to_expiry INTEGER,
  expiry_status TEXT,
  quantity_received INTEGER,
  quantity_on_hand INTEGER,
  product_stock INTEGER,
  product_batched_units BIGINT,
  received_at TIMESTAMPTZ,
  summary_expired BIGINT,
  summary_within_30 BIGINT,
  summary_within_60 BIGINT,
  summary_within_90 BIGINT,
  summary_units_at_risk BIGINT,
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
  v_search TEXT := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_business_id, 'process') THEN
    RAISE EXCEPTION 'You do not have access to this business''s batches.';
  END IF;
  IF p_filter IS NOT NULL AND p_filter NOT IN ('expired', 'within_30', 'within_60', 'within_90', 'depleted') THEN
    RAISE EXCEPTION 'Unknown batch filter.';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      b.id AS bid, b.product_id AS pid, p.name AS pname, b.batch_number AS bnum, b.expiry_date AS bexp,
      (b.expiry_date - current_date) AS dte,
      CASE
        WHEN b.expiry_date < current_date THEN 'expired'
        WHEN b.expiry_date <= current_date + 30 THEN 'within_30'
        WHEN b.expiry_date <= current_date + 60 THEN 'within_60'
        WHEN b.expiry_date <= current_date + 90 THEN 'within_90'
        ELSE 'ok'
      END AS st,
      b.quantity_received AS qrec, b.quantity_on_hand AS qhand, p.stock AS pstock, b.received_at AS rat,
      (SELECT COALESCE(SUM(x.quantity_on_hand), 0) FROM public.product_batches x WHERE x.product_id = b.product_id) AS batched
    FROM public.product_batches b
    JOIN public.products p ON p.id = b.product_id
    WHERE b.wholesaler_id = p_business_id
  ),
  summary AS (
    SELECT base.*,
      COUNT(*) FILTER (WHERE base.qhand > 0 AND base.st = 'expired') OVER () AS s_exp,
      COUNT(*) FILTER (WHERE base.qhand > 0 AND base.st = 'within_30') OVER () AS s_30,
      COUNT(*) FILTER (WHERE base.qhand > 0 AND base.st = 'within_60') OVER () AS s_60,
      COUNT(*) FILTER (WHERE base.qhand > 0 AND base.st = 'within_90') OVER () AS s_90,
      COALESCE(SUM(base.qhand) FILTER (WHERE base.st IN ('expired', 'within_30', 'within_60', 'within_90')) OVER (), 0) AS s_units
    FROM base
  ),
  filtered AS (
    SELECT s.* FROM summary s
    WHERE (v_search IS NULL OR s.pname ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%'
           OR s.bnum ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      AND CASE WHEN p_filter = 'depleted' THEN s.qhand = 0
               WHEN p_filter IS NULL THEN s.qhand > 0
               ELSE s.qhand > 0 AND s.st = p_filter END
  )
  SELECT f.bid, f.pid, f.pname, f.bnum, f.bexp, f.dte::INTEGER, f.st, f.qrec, f.qhand, f.pstock, f.batched, f.rat,
    f.s_exp, f.s_30, f.s_60, f.s_90, f.s_units, COUNT(*) OVER ()
  FROM filtered f
  ORDER BY f.bexp ASC, f.pname ASC, f.bid ASC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- ---------------------------------------------------------------------------
-- FEFO picks for an order: earliest-expiring, non-expired batches first
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.suggest_order_picks(p_order_id UUID)
RETURNS TABLE (
  order_item_id UUID,
  product_name TEXT,
  quantity_needed INTEGER,
  allocated BOOLEAN,
  picks JSONB,
  shortfall INTEGER
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_item RECORD;
  v_batch RECORD;
  v_remaining INTEGER;
  v_take INTEGER;
  v_picks JSONB;
  v_allocated BOOLEAN;
BEGIN
  SELECT o.id, o.wholesaler_id, o.status::TEXT AS status INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to view picks for this order.';
  END IF;

  FOR v_item IN SELECT oi.id, oi.product_id, oi.product_name, oi.quantity FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id LOOP
    v_allocated := EXISTS (SELECT 1 FROM public.order_batch_allocations a WHERE a.order_item_id = v_item.id);
    IF v_allocated THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('batch_id', b.id, 'batch_number', b.batch_number, 'expiry_date', b.expiry_date, 'quantity', a.quantity)
                                ORDER BY b.expiry_date, b.id), '[]'::JSONB),
             v_item.quantity - COALESCE(SUM(a.quantity), 0)
        INTO v_picks, v_remaining
      FROM public.order_batch_allocations a JOIN public.product_batches b ON b.id = a.batch_id
      WHERE a.order_item_id = v_item.id;
    ELSE
      v_picks := '[]'::JSONB;
      v_remaining := v_item.quantity;
      FOR v_batch IN
        SELECT b.id, b.batch_number, b.expiry_date, b.quantity_on_hand FROM public.product_batches b
        WHERE b.product_id = v_item.product_id AND b.quantity_on_hand > 0 AND b.expiry_date >= current_date
        ORDER BY b.expiry_date, b.id
      LOOP
        EXIT WHEN v_remaining <= 0;
        v_take := LEAST(v_batch.quantity_on_hand, v_remaining);
        v_picks := v_picks || jsonb_build_object('batch_id', v_batch.id, 'batch_number', v_batch.batch_number,
                                                 'expiry_date', v_batch.expiry_date, 'quantity', v_take);
        v_remaining := v_remaining - v_take;
      END LOOP;
    END IF;
    order_item_id := v_item.id;
    product_name := v_item.product_name;
    quantity_needed := v_item.quantity;
    allocated := v_allocated;
    picks := v_picks;
    shortfall := GREATEST(v_remaining, 0);
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Releases every allocation of an order back to its batches. Caller must hold the order lock.
CREATE OR REPLACE FUNCTION public._release_order_batches(p_order_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_alloc RECORD;
  v_units INTEGER := 0;
BEGIN
  FOR v_alloc IN
    SELECT a.id, a.batch_id, a.quantity, b.product_id, b.wholesaler_id
    FROM public.order_batch_allocations a JOIN public.product_batches b ON b.id = a.batch_id
    WHERE a.order_id = p_order_id ORDER BY a.batch_id FOR UPDATE OF b
  LOOP
    UPDATE public.product_batches SET quantity_on_hand = LEAST(quantity_on_hand + v_alloc.quantity, quantity_received) WHERE id = v_alloc.batch_id;
    INSERT INTO public.batch_movements (batch_id, product_id, wholesaler_id, kind, quantity, order_id, created_by)
    VALUES (v_alloc.batch_id, v_alloc.product_id, v_alloc.wholesaler_id, 'released', v_alloc.quantity, p_order_id, auth.uid());
    v_units := v_units + v_alloc.quantity;
  END LOOP;
  DELETE FROM public.order_batch_allocations WHERE order_id = p_order_id;
  RETURN v_units;
END;
$$;
REVOKE ALL ON FUNCTION public._release_order_batches(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Confirm picks: record which batch each unit comes from. Safe to repeat (re-allocates).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_order_picks(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_item RECORD;
  v_batch RECORD;
  v_remaining INTEGER;
  v_take INTEGER;
  v_allocated INTEGER := 0;
  v_short INTEGER := 0;
  v_org TEXT;
BEGIN
  SELECT o.id, o.wholesaler_id, o.order_number, o.status::TEXT AS status INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to confirm picks for this order.';
  END IF;
  IF v_order.status NOT IN ('accepted', 'packed') THEN
    RAISE EXCEPTION 'Batches can only be confirmed while the order is accepted or packed.';
  END IF;

  PERFORM public._release_order_batches(p_order_id);

  FOR v_item IN SELECT oi.id, oi.product_id, oi.quantity FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id LOOP
    v_remaining := v_item.quantity;
    FOR v_batch IN
      SELECT b.id, b.quantity_on_hand FROM public.product_batches b
      WHERE b.product_id = v_item.product_id AND b.quantity_on_hand > 0 AND b.expiry_date >= current_date
      ORDER BY b.expiry_date, b.id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(v_batch.quantity_on_hand, v_remaining);
      UPDATE public.product_batches SET quantity_on_hand = quantity_on_hand - v_take WHERE id = v_batch.id;
      INSERT INTO public.order_batch_allocations (order_id, order_item_id, batch_id, quantity) VALUES (p_order_id, v_item.id, v_batch.id, v_take);
      INSERT INTO public.batch_movements (batch_id, product_id, wholesaler_id, kind, quantity, order_id, created_by)
      VALUES (v_batch.id, v_item.product_id, v_order.wholesaler_id, 'allocated', v_take, p_order_id, auth.uid());
      v_remaining := v_remaining - v_take;
      v_allocated := v_allocated + v_take;
    END LOOP;
    v_short := v_short + GREATEST(v_remaining, 0);
  END LOOP;

  SELECT name INTO v_org FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.write_audit_log('Batches allocated', v_org, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('units_allocated', v_allocated, 'units_not_batched', v_short));
  RETURN jsonb_build_object('units_allocated', v_allocated, 'units_not_batched', v_short);
END;
$$;

-- Cancelling an order gives its batch units back.
CREATE OR REPLACE FUNCTION public.release_batches_on_order_cancel()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status::TEXT = 'cancelled' AND OLD.status::TEXT <> 'cancelled' THEN
    PERFORM public._release_order_batches(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_release_batches_on_cancel ON public.orders;
CREATE TRIGGER trg_release_batches_on_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.release_batches_on_order_cancel();

REVOKE ALL ON FUNCTION public.receive_product_batch(UUID, TEXT, DATE, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.write_off_batch(UUID, INTEGER, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_product_batches(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.suggest_order_picks(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_order_picks(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_product_batch(UUID, TEXT, DATE, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.write_off_batch(UUID, INTEGER, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_product_batches(UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suggest_order_picks(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_order_picks(UUID) TO authenticated;
