-- Order amendments, Phase 3 part 1: back-orders and shipments (schema and read helpers; no behaviour change yet).
--
-- When a pharmacy accepts a reduced supply it may choose "accept what is available and back-order the rest" (credit orders
-- for now). The rest stays on the SAME parent order as an outstanding quantity; it is later sent as one or more
-- back-order shipments, each with its own status, stock deduction and invoice entry:
--
--   order_shipments              shipment 1 is the order itself (existing flow, unchanged); back-order shipments are
--                                sequence 2, 3, ... with their own status machine: pending -> packed -> dispatched ->
--                                delivered, or cancelled before dispatch.
--   order_shipment_lines         what each shipment carries (immutable).
--   order_backorder_cancellations  quantity that will never be sent (immutable), with who and why.
--
-- An item's back-ordered quantity is the shortage of accepted back-order proposals; its outstanding quantity is what is not
-- yet in a live shipment and not cancelled. Nothing is stored twice: every figure below is computed.
--
-- order_stock_movements now also records the stock deducted when a back-order shipment is dispatched, and the markers that
-- stop a shipment being invoiced, deducted or dispatched twice are unique constraints.

-- ---------------------------------------------------------------------------
-- 1. Shipments
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_shipments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  sequence INTEGER NOT NULL CHECK (sequence >= 2),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'packed', 'dispatched', 'delivered', 'cancelled')),
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs >= 0),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 300),
  request_id UUID NOT NULL,
  created_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  packed_at TIMESTAMPTZ,
  packed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  dispatched_at TIMESTAMPTZ,
  dispatched_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  delivered_at TIMESTAMPTZ,
  delivered_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  cancelled_at TIMESTAMPTZ,
  cancelled_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  cancel_reason TEXT CHECK (cancel_reason IS NULL OR char_length(cancel_reason) <= 500),
  -- What the order owed on the credit ledger just before this shipment was invoiced; decides whether the due date moves.
  prior_outstanding_ghs NUMERIC(12,2),
  credit_due_date DATE,
  UNIQUE (order_id, sequence),
  UNIQUE (order_id, request_id)
);
CREATE INDEX IF NOT EXISTS order_shipments_order_idx ON public.order_shipments (order_id, sequence);

CREATE TABLE IF NOT EXISTS public.order_shipment_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shipment_id UUID NOT NULL REFERENCES public.order_shipments(id) ON DELETE RESTRICT,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price_ghs NUMERIC(12,2) NOT NULL CHECK (unit_price_ghs >= 0),
  UNIQUE (shipment_id, order_item_id)
);
CREATE INDEX IF NOT EXISTS order_shipment_lines_item_idx ON public.order_shipment_lines (order_item_id);

CREATE TABLE IF NOT EXISTS public.order_backorder_cancellations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 3 AND 500),
  cancelled_side TEXT NOT NULL CHECK (cancelled_side IN ('wholesaler', 'pharmacy', 'system')),
  cancelled_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS order_backorder_cancellations_item_idx ON public.order_backorder_cancellations (order_item_id);

-- Links from the earlier tables now point at real shipments.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'credit_ledger_entries_shipment_fk') THEN
    ALTER TABLE public.credit_ledger_entries
      ADD CONSTRAINT credit_ledger_entries_shipment_fk FOREIGN KEY (shipment_id) REFERENCES public.order_shipments(id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_events_shipment_fk') THEN
    ALTER TABLE public.order_events
      ADD CONSTRAINT order_events_shipment_fk FOREIGN KEY (shipment_id) REFERENCES public.order_shipments(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Stock movements may now belong to a shipment instead of a proposal
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_stock_movements ADD COLUMN IF NOT EXISTS shipment_id UUID REFERENCES public.order_shipments(id) ON DELETE RESTRICT;
ALTER TABLE public.order_stock_movements ALTER COLUMN amendment_id DROP NOT NULL;
DO $$
DECLARE
  v_name TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_stock_movements_kind_v2') THEN
    -- Replace the two phase 2 CHECKs (kind list, stock effect by kind) with ones that also know about shipments.
    FOR v_name IN
      SELECT c.conname FROM pg_constraint c
      WHERE c.conrelid = 'public.order_stock_movements'::regclass AND c.contype = 'c'
        AND (pg_get_constraintdef(c.oid) LIKE '%shortage_release%')
    LOOP
      EXECUTE format('ALTER TABLE public.order_stock_movements DROP CONSTRAINT %I', v_name);
    END LOOP;
    ALTER TABLE public.order_stock_movements ADD CONSTRAINT order_stock_movements_kind_v2 CHECK (
      kind IN ('shortage_release', 'shortage_write_off', 'backorder_dispatch'));
    ALTER TABLE public.order_stock_movements ADD CONSTRAINT order_stock_movements_effect_v2 CHECK (
      (kind = 'shortage_release' AND stock_effect = quantity)
      OR (kind = 'shortage_write_off' AND stock_effect = 0)
      OR (kind = 'backorder_dispatch' AND stock_effect = -quantity));
    ALTER TABLE public.order_stock_movements ADD CONSTRAINT order_stock_movements_owner_v2 CHECK (
      (amendment_id IS NOT NULL AND shipment_id IS NULL AND kind IN ('shortage_release', 'shortage_write_off'))
      OR (shipment_id IS NOT NULL AND amendment_id IS NULL AND kind = 'backorder_dispatch'));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS order_stock_movements_shipment_once
  ON public.order_stock_movements (shipment_id, order_item_id, kind) WHERE shipment_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. Immutability and access
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_shipments_protect_record()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Order shipment records are append-only.'; END IF;
  IF (to_jsonb(NEW) - 'status' - 'packed_at' - 'packed_by' - 'dispatched_at' - 'dispatched_by' - 'delivered_at' - 'delivered_by'
        - 'cancelled_at' - 'cancelled_by' - 'cancel_reason' - 'prior_outstanding_ghs' - 'credit_due_date')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'status' - 'packed_at' - 'packed_by' - 'dispatched_at' - 'dispatched_by' - 'delivered_at' - 'delivered_by'
        - 'cancelled_at' - 'cancelled_by' - 'cancel_reason' - 'prior_outstanding_ghs' - 'credit_due_date')
  THEN
    RAISE EXCEPTION 'A shipment cannot be edited; cancel it and create another.';
  END IF;
  IF OLD.status IN ('delivered', 'cancelled') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'This shipment is already %.', OLD.status;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_shipments_protect ON public.order_shipments;
CREATE TRIGGER trg_order_shipments_protect BEFORE UPDATE OR DELETE ON public.order_shipments
  FOR EACH ROW EXECUTE FUNCTION public.order_shipments_protect_record();
DROP TRIGGER IF EXISTS trg_order_shipment_lines_append_only ON public.order_shipment_lines;
CREATE TRIGGER trg_order_shipment_lines_append_only BEFORE UPDATE OR DELETE ON public.order_shipment_lines
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();
DROP TRIGGER IF EXISTS trg_order_backorder_cancellations_append_only ON public.order_backorder_cancellations;
CREATE TRIGGER trg_order_backorder_cancellations_append_only BEFORE UPDATE OR DELETE ON public.order_backorder_cancellations
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();

ALTER TABLE public.order_shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_shipment_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_backorder_cancellations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read order shipments" ON public.order_shipments;
CREATE POLICY "Admins read order shipments" ON public.order_shipments FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order shipment lines" ON public.order_shipment_lines;
CREATE POLICY "Admins read order shipment lines" ON public.order_shipment_lines FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order backorder cancellations" ON public.order_backorder_cancellations;
CREATE POLICY "Admins read order backorder cancellations" ON public.order_backorder_cancellations FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_shipments, public.order_shipment_lines, public.order_backorder_cancellations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_shipments, public.order_shipment_lines, public.order_backorder_cancellations TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Computed quantities
-- ---------------------------------------------------------------------------
-- Units of a line placed on back-order by accepted proposals.
CREATE OR REPLACE FUNCTION public.order_item_backordered_qty(p_order_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(l.short_qty), 0)::INTEGER
  FROM public.order_amendment_lines l JOIN public.order_amendments a ON a.id = l.amendment_id
  WHERE l.order_item_id = p_order_item_id AND a.status = 'accepted' AND a.response_choice = 'accept_backorder'
$$;

-- Units of a line in back-order shipments that have not been cancelled, optionally only those already sent.
CREATE OR REPLACE FUNCTION public.order_item_shipment_qty(p_order_item_id UUID, p_sent_only BOOLEAN DEFAULT FALSE)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(sl.quantity), 0)::INTEGER
  FROM public.order_shipment_lines sl JOIN public.order_shipments s ON s.id = sl.shipment_id
  WHERE sl.order_item_id = p_order_item_id
    AND CASE WHEN p_sent_only THEN s.status IN ('dispatched', 'delivered') ELSE s.status <> 'cancelled' END
$$;

-- Units still waiting to be put into a shipment: back-ordered, less what is in a live shipment, less what was cancelled.
CREATE OR REPLACE FUNCTION public.order_item_backorder_outstanding(p_order_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(
    public.order_item_backordered_qty(p_order_item_id)
    - public.order_item_shipment_qty(p_order_item_id, FALSE)
    - COALESCE((SELECT SUM(c.quantity) FROM public.order_backorder_cancellations c WHERE c.order_item_id = p_order_item_id), 0)::INTEGER,
    0)
$$;

-- Everything supplied on the order so far: the main shipment's commitment plus back-order units already dispatched. This is
-- what reports, returns and receipts count; pick sheets for the main shipment keep using order_item_supplied_qty().
CREATE OR REPLACE FUNCTION public.order_item_fulfilled_qty(p_order_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.order_item_supplied_qty(p_order_item_id) + public.order_item_shipment_qty(p_order_item_id, TRUE)
$$;

-- The order-level back-order state, in the vocabulary the screens use:
--   none | open | partially_fulfilled | fulfilled | cancelled | closed
-- open = nothing sent yet; partially_fulfilled = some sent and some still to come; fulfilled = everything sent;
-- cancelled = nothing was sent and the rest was cancelled; closed = some sent and the rest cancelled.
CREATE OR REPLACE FUNCTION public.order_backorder_state(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_back INTEGER := 0;
  v_outstanding INTEGER := 0;
  v_planned INTEGER := 0;
  v_sent INTEGER := 0;
  v_cancelled INTEGER := 0;
  v_item UUID;
  v_status TEXT;
BEGIN
  FOR v_item IN SELECT oi.id FROM public.order_items oi WHERE oi.order_id = p_order_id LOOP
    v_back := v_back + public.order_item_backordered_qty(v_item);
    v_outstanding := v_outstanding + public.order_item_backorder_outstanding(v_item);
    v_sent := v_sent + public.order_item_shipment_qty(v_item, TRUE);
    v_planned := v_planned + public.order_item_shipment_qty(v_item, FALSE) - public.order_item_shipment_qty(v_item, TRUE);
    v_cancelled := v_cancelled + COALESCE((SELECT SUM(c.quantity) FROM public.order_backorder_cancellations c WHERE c.order_item_id = v_item), 0)::INTEGER;
  END LOOP;
  v_status := CASE
    WHEN v_back = 0 THEN 'none'
    WHEN v_outstanding + v_planned > 0 AND v_sent > 0 THEN 'partially_fulfilled'
    WHEN v_outstanding + v_planned > 0 THEN 'open'
    WHEN v_sent = 0 THEN 'cancelled'
    WHEN v_cancelled > 0 THEN 'closed'
    ELSE 'fulfilled' END;
  RETURN jsonb_build_object('status', v_status, 'backordered', v_back, 'outstanding', v_outstanding, 'planned', v_planned,
                            'sent', v_sent, 'cancelled', v_cancelled);
END;
$$;

REVOKE ALL ON FUNCTION public.order_item_backordered_qty(UUID), public.order_item_shipment_qty(UUID, BOOLEAN),
  public.order_item_backorder_outstanding(UUID), public.order_item_fulfilled_qty(UUID), public.order_backorder_state(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_item_backordered_qty(UUID), public.order_item_shipment_qty(UUID, BOOLEAN),
  public.order_item_backorder_outstanding(UUID), public.order_backorder_state(UUID) TO service_role;
-- The reports run as the signed-in user and read the fulfilled quantity (same reasoning as order_item_supplied_qty).
GRANT EXECUTE ON FUNCTION public.order_item_fulfilled_qty(UUID) TO authenticated, service_role;
