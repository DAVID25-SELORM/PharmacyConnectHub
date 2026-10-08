-- Order amendments, Phase 2 part 1: schema for partial fulfilment (a wholesaler proposes to supply less than was
-- ordered; the pharmacy decides). Structures and two read helpers only: no existing function is touched here and no
-- order behaves differently until the workflow functions of part 3 are used. See
-- docs/order-amendments-and-partial-fulfilment.md.
--
--   order_amendments           one proposal per row: who proposed, why, the totals before/after, and the pharmacy's answer.
--                              At most ONE open proposal per order (partial unique index). Idempotent by (order_id, request_id).
--   order_amendment_lines      the per-product detail of a proposal: ordered / before / proposed supply / shortage / stock treatment.
--   order_amendment_messages   the clarification conversation (append-only).
--   order_stock_movements      every stock effect an accepted amendment causes. UNIQUE per (amendment, line, kind), so a
--                              movement can never be applied twice, and cancellation uses it to avoid restoring twice.
--   order_item_supplied_qty()  what the wholesaler is committed to supply on the order for a line today.
--   order_amendment_stock_taken()  units of a product already released/written off for an order by accepted amendments.
--
-- Everything is written only by SECURITY DEFINER functions; the tables themselves are readable by platform admins only.

-- ---------------------------------------------------------------------------
-- 1. Proposals
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_amendments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  version INTEGER NOT NULL CHECK (version >= 1),
  kind TEXT NOT NULL CHECK (kind IN ('partial_fulfilment', 'price_change')),
  status TEXT NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed', 'clarification_requested', 'accepted', 'rejected', 'withdrawn')),
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 3 AND 500),
  proposed_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  proposed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  response_choice TEXT CHECK (response_choice IS NULL OR response_choice IN
    ('accept_cancel_remaining', 'accept_backorder', 'reject', 'request_clarification', 'withdrawn', 'order_cancelled')),
  response_note TEXT CHECK (response_note IS NULL OR char_length(response_note) <= 500),
  responded_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  responded_at TIMESTAMPTZ,
  original_total_ghs NUMERIC(12,2) NOT NULL CHECK (original_total_ghs >= 0),
  proposed_total_ghs NUMERIC(12,2) NOT NULL CHECK (proposed_total_ghs >= 0),
  delta_ghs NUMERIC(12,2) NOT NULL,
  stock_mode TEXT NOT NULL DEFAULT 'none' CHECK (stock_mode IN ('none', 'evidence')),
  applied_at TIMESTAMPTZ,
  request_id UUID NOT NULL,
  reminder_sent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (order_id, version),
  UNIQUE (order_id, request_id),
  CHECK ((status = 'accepted') = (applied_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS order_amendments_one_open_per_order
  ON public.order_amendments (order_id) WHERE status IN ('proposed', 'clarification_requested');
CREATE INDEX IF NOT EXISTS order_amendments_order_idx ON public.order_amendments (order_id, version);

-- The credit ledger markers added in phase 1 now point at a real table.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'credit_ledger_entries_amendment_fk') THEN
    ALTER TABLE public.credit_ledger_entries
      ADD CONSTRAINT credit_ledger_entries_amendment_fk FOREIGN KEY (amendment_id) REFERENCES public.order_amendments(id) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_events_amendment_fk') THEN
    ALTER TABLE public.order_events
      ADD CONSTRAINT order_events_amendment_fk FOREIGN KEY (amendment_id) REFERENCES public.order_amendments(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Proposal lines (one per order line; unchanged lines have shortage 0)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_amendment_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  amendment_id UUID NOT NULL REFERENCES public.order_amendments(id) ON DELETE RESTRICT,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL,
  product_name TEXT NOT NULL,
  ordered_qty INTEGER NOT NULL CHECK (ordered_qty > 0),
  prior_supplied_qty INTEGER NOT NULL CHECK (prior_supplied_qty >= 0),
  supplied_qty INTEGER NOT NULL CHECK (supplied_qty >= 0),
  short_qty INTEGER NOT NULL CHECK (short_qty >= 0),
  unit_price_ghs NUMERIC(12,2) NOT NULL CHECK (unit_price_ghs >= 0),
  stock_treatment TEXT NOT NULL DEFAULT 'none' CHECK (stock_treatment IN ('none', 'release', 'write_off')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 300),
  UNIQUE (amendment_id, order_item_id),
  CHECK (supplied_qty + short_qty = prior_supplied_qty),
  CHECK (prior_supplied_qty <= ordered_qty),
  CHECK (short_qty > 0 OR stock_treatment = 'none')
);
CREATE INDEX IF NOT EXISTS order_amendment_lines_item_idx ON public.order_amendment_lines (order_item_id);

-- ---------------------------------------------------------------------------
-- 3. Clarification conversation
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_amendment_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  amendment_id UUID NOT NULL REFERENCES public.order_amendments(id) ON DELETE RESTRICT,
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  author_side TEXT NOT NULL CHECK (author_side IN ('wholesaler', 'pharmacy')),
  author_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  message TEXT NOT NULL CHECK (char_length(btrim(message)) BETWEEN 1 AND 500),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS order_amendment_messages_idx ON public.order_amendment_messages (amendment_id, created_at);

-- ---------------------------------------------------------------------------
-- 4. Stock effects of accepted amendments
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_stock_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  amendment_id UUID NOT NULL REFERENCES public.order_amendments(id) ON DELETE RESTRICT,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL CHECK (kind IN ('shortage_release', 'shortage_write_off')),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  stock_effect INTEGER NOT NULL,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (amendment_id, order_item_id, kind),
  CHECK ((kind = 'shortage_release' AND stock_effect = quantity) OR (kind = 'shortage_write_off' AND stock_effect = 0))
);
CREATE INDEX IF NOT EXISTS order_stock_movements_order_product_idx ON public.order_stock_movements (order_id, product_id);

-- Append-only: a recorded amendment is never edited or deleted. The only change allowed on a proposal is its own
-- state machine (status, response fields), enforced by the workflow functions; the lines, messages and stock
-- movements never change once written.
CREATE OR REPLACE FUNCTION public.order_amendment_history_is_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'Order amendment records are append-only.';
END;
$$;
DROP TRIGGER IF EXISTS trg_order_amendment_lines_append_only ON public.order_amendment_lines;
CREATE TRIGGER trg_order_amendment_lines_append_only BEFORE UPDATE OR DELETE ON public.order_amendment_lines
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();
DROP TRIGGER IF EXISTS trg_order_amendment_messages_append_only ON public.order_amendment_messages;
CREATE TRIGGER trg_order_amendment_messages_append_only BEFORE UPDATE OR DELETE ON public.order_amendment_messages
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();
DROP TRIGGER IF EXISTS trg_order_stock_movements_append_only ON public.order_stock_movements;
CREATE TRIGGER trg_order_stock_movements_append_only BEFORE UPDATE OR DELETE ON public.order_stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();

CREATE OR REPLACE FUNCTION public.order_amendments_protect_record()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Order amendment records are append-only.'; END IF;
  IF (to_jsonb(NEW) - 'status' - 'response_choice' - 'response_note' - 'responded_by' - 'responded_at' - 'applied_at' - 'reminder_sent_at')
     IS DISTINCT FROM
     (to_jsonb(OLD) - 'status' - 'response_choice' - 'response_note' - 'responded_by' - 'responded_at' - 'applied_at' - 'reminder_sent_at')
  THEN
    RAISE EXCEPTION 'A proposal cannot be edited after it is made; withdraw it and propose again.';
  END IF;
  IF OLD.status IN ('accepted', 'rejected', 'withdrawn') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'This proposal has already been answered.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_amendments_protect ON public.order_amendments;
CREATE TRIGGER trg_order_amendments_protect BEFORE UPDATE OR DELETE ON public.order_amendments
  FOR EACH ROW EXECUTE FUNCTION public.order_amendments_protect_record();

-- ---------------------------------------------------------------------------
-- 5. Access: admins read directly; everyone else goes through the checked RPCs of part 3.
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_amendments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_amendment_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_amendment_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_stock_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read order amendments" ON public.order_amendments;
CREATE POLICY "Admins read order amendments" ON public.order_amendments FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order amendment lines" ON public.order_amendment_lines;
CREATE POLICY "Admins read order amendment lines" ON public.order_amendment_lines FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order amendment messages" ON public.order_amendment_messages;
CREATE POLICY "Admins read order amendment messages" ON public.order_amendment_messages FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order stock movements" ON public.order_stock_movements;
CREATE POLICY "Admins read order stock movements" ON public.order_stock_movements FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_amendments, public.order_amendment_lines, public.order_amendment_messages, public.order_stock_movements
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_amendments, public.order_amendment_lines, public.order_amendment_messages, public.order_stock_movements
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------
-- What the wholesaler is committed to supply on the order for this line: the quantity ordered, less whatever accepted
-- amendments took off it. An order that was never amended returns exactly its ordered quantity.
CREATE OR REPLACE FUNCTION public.order_item_supplied_qty(p_order_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT oi.quantity - COALESCE((
    SELECT SUM(l.short_qty)::INTEGER
    FROM public.order_amendment_lines l JOIN public.order_amendments a ON a.id = l.amendment_id
    WHERE l.order_item_id = oi.id AND a.status = 'accepted'
  ), 0)
  FROM public.order_items oi WHERE oi.id = p_order_item_id
$$;
REVOKE ALL ON FUNCTION public.order_item_supplied_qty(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_item_supplied_qty(UUID) TO service_role;

-- Units of one product that accepted amendments have already taken back (released) or written off for an order.
CREATE OR REPLACE FUNCTION public.order_amendment_stock_taken(p_order_id UUID, p_product_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(m.quantity), 0)::INTEGER FROM public.order_stock_movements m
  WHERE m.order_id = p_order_id AND m.product_id = p_product_id
$$;
REVOKE ALL ON FUNCTION public.order_amendment_stock_taken(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_amendment_stock_taken(UUID, UUID) TO service_role;

-- Does this order's stock deduction have verified evidence (production's order_stock_deductions)? Orders placed before
-- the evidence existed ("legacy" orders) have none, and amendments never write stock for them.
CREATE OR REPLACE FUNCTION public.order_has_stock_evidence(p_order_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has BOOLEAN := FALSE;
BEGIN
  IF to_regclass('public.order_stock_deductions') IS NOT NULL AND to_regclass('public.inventory_operation_context') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.order_stock_deductions WHERE order_id = $1)' INTO v_has USING p_order_id;
  END IF;
  RETURN v_has;
END;
$$;
REVOKE ALL ON FUNCTION public.order_has_stock_evidence(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_has_stock_evidence(UUID) TO service_role;
