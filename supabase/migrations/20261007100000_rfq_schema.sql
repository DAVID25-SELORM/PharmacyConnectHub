-- RFQ (Request for Quotation), part 1: schema. Phase 5 of the procurement/credit/RFQ expansion.
--
-- Design (confirmed with the business owner before building):
--   * Sealed bidding, forever: a wholesaler only ever sees its OWN quote for an RFQ. Even after
--     the pharmacy awards the RFQ, a losing wholesaler sees only that its quote was rejected --
--     never who won or at what price. Enforced at the RLS level below, not just in RPC logic, so
--     there is no code path that can leak it.
--   * Closed invitation, not a broadcast: the pharmacy picks which approved wholesalers may see
--     and quote on a given RFQ. A wholesaler that was not invited cannot see the RFQ exists.
--     rfq_invitees rows are themselves sealed the same way: a wholesaler sees only its own
--     invitation, never the rest of the invite list (no competitor-identity leak either).
--   * Awarding a quote is planned to auto-convert into a real order (mirroring
--     create_marketplace_orders' stock-lock discipline) -- that conversion RPC is a later phase;
--     this migration only adds the 'awarded_order_id' column it will populate.
--
-- All five tables are RPC-write-only (mutations always go through SECURITY DEFINER functions in
-- the next migration, matching the products/procurements precedent: "writes happen exclusively
-- inside a SECURITY DEFINER function, so there is no INSERT/UPDATE/DELETE policy for
-- authenticated"). Reads are plain RLS SELECT policies -- no wrapper RPC needed for listing/detail,
-- exactly like orders/order_items already work.

CREATE TABLE public.rfqs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reference TEXT NOT NULL UNIQUE DEFAULT ('RFQ-' || lpad((floor(random() * 900000) + 100000)::TEXT, 6, '0')),
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  notes TEXT,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'awarded', 'cancelled')),
  response_deadline TIMESTAMPTZ,
  awarded_quote_id UUID,
  awarded_order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_rfqs_pharmacy ON public.rfqs(pharmacy_id, created_at DESC);
CREATE TRIGGER trg_rfqs_updated BEFORE UPDATE ON public.rfqs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TABLE public.rfq_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_id UUID NOT NULL REFERENCES public.rfqs(id) ON DELETE CASCADE,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_rfq_items_rfq ON public.rfq_items(rfq_id);

CREATE TABLE public.rfq_invitees (
  rfq_id UUID NOT NULL REFERENCES public.rfqs(id) ON DELETE CASCADE,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  invited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (rfq_id, wholesaler_id)
);
CREATE INDEX idx_rfq_invitees_wholesaler ON public.rfq_invitees(wholesaler_id);

CREATE TABLE public.rfq_quotes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_id UUID NOT NULL REFERENCES public.rfqs(id) ON DELETE CASCADE,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted', 'withdrawn', 'accepted', 'rejected')),
  total_ghs NUMERIC(12,2) NOT NULL DEFAULT 0,
  delivery_notes TEXT,
  valid_until TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (rfq_id, wholesaler_id)
);
CREATE INDEX idx_rfq_quotes_rfq ON public.rfq_quotes(rfq_id);
CREATE INDEX idx_rfq_quotes_wholesaler ON public.rfq_quotes(wholesaler_id);
CREATE TRIGGER trg_rfq_quotes_updated BEFORE UPDATE ON public.rfq_quotes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.rfqs ADD CONSTRAINT rfqs_awarded_quote_fk
  FOREIGN KEY (awarded_quote_id) REFERENCES public.rfq_quotes(id) ON DELETE SET NULL;

CREATE TABLE public.rfq_quote_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_quote_id UUID NOT NULL REFERENCES public.rfq_quotes(id) ON DELETE CASCADE,
  rfq_item_id UUID NOT NULL REFERENCES public.rfq_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price_ghs NUMERIC(10,2) NOT NULL CHECK (unit_price_ghs > 0),
  line_total_ghs NUMERIC(12,2) NOT NULL,
  notes TEXT,
  UNIQUE (rfq_quote_id, rfq_item_id)
);
CREATE INDEX idx_rfq_quote_items_quote ON public.rfq_quote_items(rfq_quote_id);

-- ===========================================================================
-- RLS: reads only, gated per-table; no wholesaler-to-wholesaler visibility anywhere.
-- ===========================================================================
ALTER TABLE public.rfqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rfq_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rfq_invitees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rfq_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rfq_quote_items ENABLE ROW LEVEL SECURITY;

-- rfqs and rfq_invitees each need to read the OTHER table to decide visibility (an rfq is visible
-- to an invited wholesaler; an invitee row is visible to the rfq's pharmacy), which is a direct
-- cycle if each policy queries the other table through its own RLS. Both checks are instead done
-- inside SECURITY DEFINER helpers: as functions owned by the migration role, their internal reads
-- bypass RLS entirely (same reason is_business_staff/can_act_for_business never recurse), so the
-- cycle never actually executes.
CREATE OR REPLACE FUNCTION public.can_view_rfq(p_rfq_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.rfqs r
    JOIN public.businesses pb ON pb.id = r.pharmacy_id
    WHERE r.id = p_rfq_id
      AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), r.pharmacy_id))
  ) OR EXISTS (
    SELECT 1 FROM public.rfq_invitees ri
    JOIN public.businesses wb ON wb.id = ri.wholesaler_id
    WHERE ri.rfq_id = p_rfq_id
      AND (wb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), ri.wholesaler_id))
  );
$$;
REVOKE ALL ON FUNCTION public.can_view_rfq(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_rfq(UUID) TO authenticated;

-- Shared shape for rfq_invitees and rfq_quotes: both are "one row per (rfq, wholesaler)", visible
-- to the rfq's pharmacy (every row) or to that specific wholesaler (only its own row) -- never to
-- any other wholesaler. Also SECURITY DEFINER for the same recursion-avoidance reason.
CREATE OR REPLACE FUNCTION public.can_view_rfq_party_row(p_rfq_id UUID, p_wholesaler_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.rfqs r
    JOIN public.businesses pb ON pb.id = r.pharmacy_id
    WHERE r.id = p_rfq_id
      AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), r.pharmacy_id))
  ) OR EXISTS (
    SELECT 1 FROM public.businesses wb WHERE wb.id = p_wholesaler_id
      AND (wb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_wholesaler_id))
  );
$$;
REVOKE ALL ON FUNCTION public.can_view_rfq_party_row(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_rfq_party_row(UUID, UUID) TO authenticated;

CREATE POLICY "Can view rfq" ON public.rfqs FOR SELECT USING (
  public.can_view_rfq(id) OR public.has_role(auth.uid(), 'admin')
);
REVOKE ALL ON public.rfqs FROM PUBLIC, anon;
GRANT SELECT ON public.rfqs TO authenticated;

CREATE POLICY "View rfq_items if can view parent rfq" ON public.rfq_items FOR SELECT USING (
  public.can_view_rfq(rfq_id)
);
REVOKE ALL ON public.rfq_items FROM PUBLIC, anon;
GRANT SELECT ON public.rfq_items TO authenticated;

-- A wholesaler sees only ITS OWN invitation, never who else was invited (keeps the competitor
-- list sealed too, not just the prices). The pharmacy sees the full invite list.
CREATE POLICY "Can view rfq invitee row" ON public.rfq_invitees FOR SELECT USING (
  public.can_view_rfq_party_row(rfq_id, wholesaler_id)
);
REVOKE ALL ON public.rfq_invitees FROM PUBLIC, anon;
GRANT SELECT ON public.rfq_invitees TO authenticated;

-- The sealing guarantee: a quote is visible to the pharmacy that owns the parent RFQ (every
-- quote, so it can compare) and to the wholesaler that authored THAT SPECIFIC row -- never to
-- any other wholesaler, before or after award.
CREATE POLICY "Can view rfq quote row" ON public.rfq_quotes FOR SELECT USING (
  public.can_view_rfq_party_row(rfq_id, wholesaler_id)
);
CREATE POLICY "Admins see all rfq quotes" ON public.rfq_quotes FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.rfq_quotes FROM PUBLIC, anon;
GRANT SELECT ON public.rfq_quotes TO authenticated;

CREATE POLICY "View rfq_quote_items if can view parent quote" ON public.rfq_quote_items FOR SELECT USING (
  EXISTS (
    SELECT 1 FROM public.rfq_quotes q
    WHERE q.id = rfq_quote_id AND public.can_view_rfq_party_row(q.rfq_id, q.wholesaler_id)
  )
);
REVOKE ALL ON public.rfq_quote_items FROM PUBLIC, anon;
GRANT SELECT ON public.rfq_quote_items TO authenticated;
