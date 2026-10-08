-- Order amendments, Phase 1 (foundation). Adds structures only; nothing in the order, stock or credit
-- behaviour changes and no existing function is touched. See docs/order-amendments-and-partial-fulfilment.md.
--
--   1. orders.effective_total_ghs     the total to use once an order has been amended. NULL = not amended, so every
--                                      reader can use COALESCE(effective_total_ghs, total_ghs). orders.total_ghs stays
--                                      exactly as placed (production's legacy guard makes it immutable).
--   2. order_events                   an append-only activity log for an order: who did what, when, on which side.
--   3. order_timeline(order)          one chronological view of an order: placement, every status change and every
--                                      event, readable by the two parties only.
--   4. credit_ledger_entries.amendment_id / shipment_id
--                                      idempotency markers for later phases: at most ONE credit note and ONE debit note
--                                      per amendment, and ONE invoice entry per back-order shipment, enforced by the
--                                      database so a retry can never post a duplicate financial document.
--   5. record_order_event(), order_effective_total()
--                                      internal helpers for the later phases (not callable by users).

-- ---------------------------------------------------------------------------
-- 1. Effective total
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS effective_total_ghs NUMERIC(12,2);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_effective_total_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_effective_total_check
      CHECK (effective_total_ghs IS NULL OR effective_total_ghs >= 0);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.order_effective_total(p_order_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(o.effective_total_ghs, o.total_ghs) FROM public.orders o WHERE o.id = p_order_id
$$;
REVOKE ALL ON FUNCTION public.order_effective_total(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The order activity log (append-only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 60),
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_side TEXT NOT NULL CHECK (actor_side IN ('wholesaler', 'pharmacy', 'system')),
  amendment_id UUID,
  shipment_id UUID,
  summary TEXT NOT NULL CHECK (char_length(summary) BETWEEN 1 AND 500),
  details JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS order_events_order_idx ON public.order_events (order_id, created_at, id);

ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Parties read their order's events" ON public.order_events;
CREATE POLICY "Parties read their order's events" ON public.order_events FOR SELECT USING (
  public.has_role(auth.uid(), 'admin')
  OR EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_events.order_id
      AND (
        EXISTS (SELECT 1 FROM public.businesses b WHERE b.id IN (o.pharmacy_id, o.wholesaler_id) AND b.owner_id = auth.uid())
        OR EXISTS (
          SELECT 1 FROM public.business_staff s
          WHERE s.business_id IN (o.pharmacy_id, o.wholesaler_id) AND s.user_id = auth.uid() AND s.status = 'active'
        )
      )
  )
);
REVOKE ALL ON public.order_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_events TO authenticated;

CREATE OR REPLACE FUNCTION public.order_events_are_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Order events are append-only.';
END;
$$;
DROP TRIGGER IF EXISTS trg_order_events_append_only ON public.order_events;
CREATE TRIGGER trg_order_events_append_only
  BEFORE UPDATE OR DELETE ON public.order_events
  FOR EACH ROW EXECUTE FUNCTION public.order_events_are_append_only();

-- The only way events are written: called by the SECURITY DEFINER functions of the later phases, inside the same
-- transaction as the change they describe. The actor is the signed-in user; the side is decided by the caller.
CREATE OR REPLACE FUNCTION public.record_order_event(
  p_order_id UUID,
  p_event_type TEXT,
  p_actor_side TEXT,
  p_summary TEXT,
  p_details JSONB DEFAULT '{}'::JSONB,
  p_amendment_id UUID DEFAULT NULL,
  p_shipment_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  INSERT INTO public.order_events(order_id, event_type, actor_user_id, actor_side, amendment_id, shipment_id, summary, details)
  VALUES (p_order_id, p_event_type, auth.uid(), p_actor_side, p_amendment_id, p_shipment_id, p_summary, COALESCE(p_details, '{}'::JSONB))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.record_order_event(UUID, TEXT, TEXT, TEXT, JSONB, UUID, UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. One chronological timeline per order, for the two parties only.
--    Actors: your own side's people are shown by email; the other side is shown by business name (their staff's
--    personal details are not shared across the two organisations). Nothing from the credit ledger appears here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_timeline(p_order_id UUID)
RETURNS TABLE(
  at TIMESTAMPTZ, source TEXT, event_type TEXT, actor_side TEXT, actor_label TEXT, summary TEXT, details JSONB
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_my_side TEXT;
  v_pharmacy_name TEXT;
  v_wholesaler_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.pharmacy_id, o.wholesaler_id, o.order_number, o.created_at INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;

  IF EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.wholesaler_id AND b.owner_id = auth.uid())
     OR EXISTS (SELECT 1 FROM public.business_staff s WHERE s.business_id = v_order.wholesaler_id AND s.user_id = auth.uid() AND s.status = 'active') THEN
    v_my_side := 'wholesaler';
  ELSIF EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.pharmacy_id AND b.owner_id = auth.uid())
     OR EXISTS (SELECT 1 FROM public.business_staff s WHERE s.business_id = v_order.pharmacy_id AND s.user_id = auth.uid() AND s.status = 'active') THEN
    v_my_side := 'pharmacy';
  ELSIF public.has_role(auth.uid(), 'admin') THEN
    v_my_side := 'admin';
  ELSE
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;

  RETURN QUERY
  WITH raw AS (
    SELECT v_order.created_at AS at, 'order'::TEXT AS source, 'placed'::TEXT AS event_type, 'pharmacy'::TEXT AS side,
      NULL::UUID AS uid, ('Order ' || v_order.order_number || ' placed')::TEXT AS summary, '{}'::JSONB AS details, 0 AS ord
    UNION ALL
    SELECT h.created_at, 'status', 'status_changed',
      CASE
        WHEN h.changed_by IS NULL THEN 'system'
        WHEN EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.wholesaler_id AND b.owner_id = h.changed_by)
          OR EXISTS (SELECT 1 FROM public.business_staff s WHERE s.business_id = v_order.wholesaler_id AND s.user_id = h.changed_by) THEN 'wholesaler'
        WHEN EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.pharmacy_id AND b.owner_id = h.changed_by)
          OR EXISTS (SELECT 1 FROM public.business_staff s WHERE s.business_id = v_order.pharmacy_id AND s.user_id = h.changed_by) THEN 'pharmacy'
        ELSE 'system' END,
      h.changed_by,
      CASE WHEN h.from_status IS NULL THEN 'Status set to ' || replace(h.to_status::TEXT, '_', ' ')
           ELSE 'Status changed from ' || replace(h.from_status::TEXT, '_', ' ') || ' to ' || replace(h.to_status::TEXT, '_', ' ') END,
      jsonb_strip_nulls(jsonb_build_object('from', h.from_status, 'to', h.to_status, 'note', h.note)), 1
    FROM public.order_status_history h WHERE h.order_id = p_order_id
    UNION ALL
    SELECT e.created_at, 'event', e.event_type, e.actor_side, e.actor_user_id, e.summary, e.details, 2
    FROM public.order_events e WHERE e.order_id = p_order_id
  )
  SELECT r.at, r.source, r.event_type, r.side,
    CASE
      WHEN r.side = 'system' OR r.uid IS NULL THEN CASE r.side WHEN 'pharmacy' THEN v_pharmacy_name WHEN 'wholesaler' THEN v_wholesaler_name ELSE 'System' END
      WHEN r.side = v_my_side OR v_my_side = 'admin' THEN COALESCE((SELECT u.email::TEXT FROM auth.users u WHERE u.id = r.uid), 'A team member')
      WHEN r.side = 'pharmacy' THEN v_pharmacy_name
      ELSE v_wholesaler_name END,
    r.summary, r.details
  FROM raw r
  ORDER BY r.at, r.ord, r.event_type;
END;
$$;
REVOKE ALL ON FUNCTION public.order_timeline(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_timeline(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Idempotency markers on the credit ledger (columns only; the tables they will reference arrive in later phases)
-- ---------------------------------------------------------------------------
ALTER TABLE public.credit_ledger_entries ADD COLUMN IF NOT EXISTS amendment_id UUID;
ALTER TABLE public.credit_ledger_entries ADD COLUMN IF NOT EXISTS shipment_id UUID;
CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_amendment_entry_unique
  ON public.credit_ledger_entries (amendment_id, entry_type) WHERE amendment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_shipment_invoice_unique
  ON public.credit_ledger_entries (shipment_id) WHERE shipment_id IS NOT NULL AND entry_type = 'invoice';
