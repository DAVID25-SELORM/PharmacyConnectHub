-- Order amendments, Phase 5 part 1: delivery reconciliation (schema and helpers; nothing behaves differently yet).
--
-- After a delivery (the main shipment or a back-order shipment) the pharmacy records what it actually received, line by line:
-- received, missing, damaged or rejected, with a reason. That is a CLAIM. It moves no stock and posts no financial entry by
-- itself. The wholesaler's owner or manager verifies it and decides, per discrepancy, what happens: credit the goods, take them
-- back through the existing returns workflow, or reject the claim. Only then does anything change.
--
--   order_delivery_reports           one claim per delivery (live ones are unique), with its status
--   order_delivery_report_lines      what was expected / received / missing / damaged / rejected per product (immutable)
--   order_delivery_report_decisions  the wholesaler's decision per discrepancy (immutable), with the amount credited or the
--                                    return that was opened
--
-- Idempotency markers: the credit ledger gains delivery_report_id and return_id, each unique per entry type, so a claim or a
-- return can never post its credit note twice.

-- ---------------------------------------------------------------------------
-- 1. Reports, lines, decisions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_delivery_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  shipment_id UUID REFERENCES public.order_shipments(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'resolved', 'disputed', 'withdrawn', 'received_in_full')),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  delivered_at TIMESTAMPTZ NOT NULL,
  submitted_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  request_id UUID NOT NULL,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ,
  resolution_note TEXT CHECK (resolution_note IS NULL OR char_length(resolution_note) <= 500),
  credit_total_ghs NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (credit_total_ghs >= 0),
  withdrawn_at TIMESTAMPTZ,
  UNIQUE (order_id, request_id)
);
-- One live claim per delivery: while it waits, and once it is settled. A withdrawn or disputed claim leaves room for a new one.
CREATE UNIQUE INDEX IF NOT EXISTS order_delivery_reports_one_live
  ON public.order_delivery_reports (order_id, COALESCE(shipment_id, '00000000-0000-0000-0000-000000000000'::UUID))
  WHERE status IN ('submitted', 'resolved', 'received_in_full');
CREATE INDEX IF NOT EXISTS order_delivery_reports_order_idx ON public.order_delivery_reports (order_id, submitted_at);

CREATE TABLE IF NOT EXISTS public.order_delivery_report_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID NOT NULL REFERENCES public.order_delivery_reports(id) ON DELETE RESTRICT,
  order_item_id UUID NOT NULL REFERENCES public.order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL,
  product_name TEXT NOT NULL,
  unit_price_ghs NUMERIC(12,2) NOT NULL CHECK (unit_price_ghs >= 0),
  expected_qty INTEGER NOT NULL CHECK (expected_qty > 0),
  received_qty INTEGER NOT NULL CHECK (received_qty >= 0),
  missing_qty INTEGER NOT NULL CHECK (missing_qty >= 0),
  damaged_qty INTEGER NOT NULL CHECK (damaged_qty >= 0),
  rejected_qty INTEGER NOT NULL CHECK (rejected_qty >= 0),
  reason TEXT CHECK (reason IS NULL OR char_length(btrim(reason)) BETWEEN 3 AND 300),
  UNIQUE (report_id, order_item_id),
  CHECK (received_qty + missing_qty + damaged_qty + rejected_qty = expected_qty),
  CHECK ((missing_qty + damaged_qty + rejected_qty = 0) OR reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.order_delivery_report_decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID NOT NULL REFERENCES public.order_delivery_reports(id) ON DELETE RESTRICT,
  line_id UUID NOT NULL REFERENCES public.order_delivery_report_lines(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL CHECK (kind IN ('missing', 'damaged', 'rejected')),
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  outcome TEXT NOT NULL CHECK (outcome IN ('credit', 'return', 'reject')),
  amount_ghs NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_ghs >= 0),
  return_id UUID REFERENCES public.order_returns(id) ON DELETE RESTRICT,
  UNIQUE (line_id, kind),
  CHECK ((outcome = 'return') = (return_id IS NOT NULL)),
  CHECK (outcome = 'credit' OR amount_ghs = 0)
);

ALTER TABLE public.order_returns ADD COLUMN IF NOT EXISTS delivery_report_id UUID REFERENCES public.order_delivery_reports(id) ON DELETE RESTRICT;
ALTER TABLE public.credit_ledger_entries ADD COLUMN IF NOT EXISTS delivery_report_id UUID REFERENCES public.order_delivery_reports(id) ON DELETE RESTRICT;
ALTER TABLE public.credit_ledger_entries ADD COLUMN IF NOT EXISTS return_id UUID REFERENCES public.order_returns(id) ON DELETE RESTRICT;
CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_delivery_report_entry_unique
  ON public.credit_ledger_entries (delivery_report_id, entry_type) WHERE delivery_report_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS credit_ledger_return_entry_unique
  ON public.credit_ledger_entries (return_id, entry_type) WHERE return_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Immutability and access
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_delivery_reports_protect_record()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Delivery reports are append-only.'; END IF;
  IF (to_jsonb(NEW) - 'status' - 'resolved_by' - 'resolved_at' - 'resolution_note' - 'credit_total_ghs' - 'withdrawn_at')
     IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'resolved_by' - 'resolved_at' - 'resolution_note' - 'credit_total_ghs' - 'withdrawn_at')
  THEN
    RAISE EXCEPTION 'A delivery report cannot be edited after it is submitted; withdraw it and submit another.';
  END IF;
  IF OLD.status <> 'submitted' AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'This delivery report is already %.', OLD.status;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_delivery_reports_protect ON public.order_delivery_reports;
CREATE TRIGGER trg_order_delivery_reports_protect BEFORE UPDATE OR DELETE ON public.order_delivery_reports
  FOR EACH ROW EXECUTE FUNCTION public.order_delivery_reports_protect_record();
DROP TRIGGER IF EXISTS trg_order_delivery_report_lines_append_only ON public.order_delivery_report_lines;
CREATE TRIGGER trg_order_delivery_report_lines_append_only BEFORE UPDATE OR DELETE ON public.order_delivery_report_lines
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();
DROP TRIGGER IF EXISTS trg_order_delivery_report_decisions_append_only ON public.order_delivery_report_decisions;
CREATE TRIGGER trg_order_delivery_report_decisions_append_only BEFORE UPDATE OR DELETE ON public.order_delivery_report_decisions
  FOR EACH ROW EXECUTE FUNCTION public.order_amendment_history_is_append_only();

ALTER TABLE public.order_delivery_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_delivery_report_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_delivery_report_decisions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read delivery reports" ON public.order_delivery_reports;
CREATE POLICY "Admins read delivery reports" ON public.order_delivery_reports FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read delivery report lines" ON public.order_delivery_report_lines;
CREATE POLICY "Admins read delivery report lines" ON public.order_delivery_report_lines FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read delivery report decisions" ON public.order_delivery_report_decisions;
CREATE POLICY "Admins read delivery report decisions" ON public.order_delivery_report_decisions FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_delivery_reports, public.order_delivery_report_lines, public.order_delivery_report_decisions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_delivery_reports, public.order_delivery_report_lines, public.order_delivery_report_decisions TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Units that are spoken for by a delivery claim
-- ---------------------------------------------------------------------------
-- Units of a line that a returns request must not claim a second time: everything a still-undecided report points at (missing,
-- damaged, rejected), plus what a settled report credited. Units a report sent into the returns workflow are counted there,
-- and rejected claims free their units again.
CREATE OR REPLACE FUNCTION public.order_item_reconciled_qty(p_order_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (
    COALESCE((SELECT SUM(l.missing_qty + l.damaged_qty + l.rejected_qty)
              FROM public.order_delivery_report_lines l JOIN public.order_delivery_reports r ON r.id = l.report_id
              WHERE l.order_item_id = p_order_item_id AND r.status = 'submitted'), 0)
    + COALESCE((SELECT SUM(d.quantity)
                FROM public.order_delivery_report_decisions d
                JOIN public.order_delivery_report_lines l ON l.id = d.line_id
                JOIN public.order_delivery_reports r ON r.id = d.report_id
                WHERE l.order_item_id = p_order_item_id AND r.status = 'resolved' AND d.outcome = 'credit'), 0)
  )::INTEGER
$$;
REVOKE ALL ON FUNCTION public.order_item_reconciled_qty(UUID) FROM PUBLIC, anon, authenticated;
-- The returns functions run as the signed-in user's definer wrappers, but keep it callable like its siblings.
GRANT EXECUTE ON FUNCTION public.order_item_reconciled_qty(UUID) TO authenticated, service_role;
