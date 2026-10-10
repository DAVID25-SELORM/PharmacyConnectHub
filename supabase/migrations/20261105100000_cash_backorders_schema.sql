-- Order amendments, Phase 3b part 1: back-orders on cash (pay on delivery) orders. Each portion of such an order is collected and
-- receipted on its own: the main delivery as today, and every back-order shipment once it is delivered. Structures and read helpers
-- only: no existing function is touched here, and no order behaves differently until the workflow of part 3 is used. See
-- docs/order-amendments-and-partial-fulfilment.md.
--
--   order_collections      one row per portion of a cash order that has been collected: shipment_id NULL is the main delivery.
--                          Append-only (only the receipt columns are filled in afterwards). Written only by confirm_cash_collection().
--                          A portion is paid exactly when it has a row.
--   order_has_cash_portions(order)   a cash order whose rest was accepted as a back-order: its portions are collected one by one.
--   order_main_total(order)          what the main delivery is worth: the effective total less the shipments already dispatched
--                                    (each net of any delivery problem credited on it).
--
-- The order's own payment_status stays an aggregate (paid = the main delivery and every dispatched shipment are collected), so the
-- reports that already read it keep working; for a credit order it is the ledger that records partial payments.

CREATE TABLE IF NOT EXISTS public.order_collections (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  shipment_id UUID REFERENCES public.order_shipments(id) ON DELETE RESTRICT,
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs >= 0),
  confirmed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  confirmed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  receipt_sent_at TIMESTAMPTZ,
  receipt_sent_to TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- One collection per portion: the main delivery (no shipment) once, and each shipment once.
CREATE UNIQUE INDEX IF NOT EXISTS order_collections_main_unique ON public.order_collections (order_id) WHERE shipment_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS order_collections_shipment_unique ON public.order_collections (shipment_id) WHERE shipment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS order_collections_order_idx ON public.order_collections (order_id);

-- Append-only: a recorded collection is never edited or deleted. Only the two receipt columns may be filled in afterwards.
CREATE OR REPLACE FUNCTION public.order_collections_protect_record()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Collections are append-only.'; END IF;
  IF (to_jsonb(NEW) - 'receipt_sent_at' - 'receipt_sent_to') IS DISTINCT FROM (to_jsonb(OLD) - 'receipt_sent_at' - 'receipt_sent_to') THEN
    RAISE EXCEPTION 'Collections are append-only.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_collections_protect ON public.order_collections;
CREATE TRIGGER trg_order_collections_protect BEFORE UPDATE OR DELETE ON public.order_collections
  FOR EACH ROW EXECUTE FUNCTION public.order_collections_protect_record();

-- Access: admins read directly; the two parties read through the checked functions of part 3.
ALTER TABLE public.order_collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read order collections" ON public.order_collections;
CREATE POLICY "Admins read order collections" ON public.order_collections FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_collections FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_collections TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_has_cash_portions(p_order_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND NOT o.is_credit_order)
     AND EXISTS (SELECT 1 FROM public.order_amendments a
                 WHERE a.order_id = p_order_id AND a.status = 'accepted' AND a.response_choice = 'accept_backorder')
$$;
REVOKE ALL ON FUNCTION public.order_has_cash_portions(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_has_cash_portions(UUID) TO authenticated, service_role;

-- What a back-order shipment is worth to collect: its amount less any delivery problem the wholesaler has credited on it.
CREATE OR REPLACE FUNCTION public.order_shipment_net(p_shipment_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.amount_ghs - COALESCE((
    SELECT SUM(r.credit_total_ghs) FROM public.order_delivery_reports r WHERE r.shipment_id = s.id AND r.status = 'resolved'), 0)
  FROM public.order_shipments s WHERE s.id = p_shipment_id
$$;
REVOKE ALL ON FUNCTION public.order_shipment_net(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_shipment_net(UUID) TO authenticated, service_role;

-- What the shipments that have gone out are worth altogether, net of credits.
CREATE OR REPLACE FUNCTION public.order_shipments_net(p_order_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(public.order_shipment_net(s.id)), 0)
  FROM public.order_shipments s WHERE s.order_id = p_order_id AND s.status IN ('dispatched', 'delivered')
$$;
REVOKE ALL ON FUNCTION public.order_shipments_net(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_shipments_net(UUID) TO authenticated, service_role;

-- What the main delivery is worth now: the order's effective total less the shipments that have gone out (each net of its own
-- credits, so a credit on a shipment never reduces what the main delivery owes).
CREATE OR REPLACE FUNCTION public.order_main_total(p_order_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(o.effective_total_ghs, o.total_ghs) - public.order_shipments_net(o.id)
  FROM public.orders o WHERE o.id = p_order_id
$$;
REVOKE ALL ON FUNCTION public.order_main_total(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_main_total(UUID) TO authenticated, service_role;
