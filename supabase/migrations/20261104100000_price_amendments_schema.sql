-- Order amendments, Phase 4 part 1: schema for price amendments (the wholesaler proposes new unit prices on an order that has
-- not been dispatched yet; only the pharmacy's explicit approval applies them). Structures and two read helpers only: no
-- existing function is touched here and no order behaves differently until the workflow functions of part 3 are used. See
-- docs/order-amendments-and-partial-fulfilment.md.
--
--   * A price amendment is a row of order_amendments with kind = 'price_change' (the table, its statuses, its one-open-proposal
--     rule and its append-only protection already exist), and one order_amendment_lines row per product whose price changes.
--   * order_amendment_lines.proposed_unit_price_ghs   the new unit price; the existing unit_price_ghs column keeps the price at
--                                                      the time of the proposal. A price line never changes a quantity.
--   * order_item_effective_price(order_item)           the unit price now in force for an order line: the latest accepted price
--                                                      amendment's price, otherwise the price as placed. order_items itself is
--                                                      never edited (production's guard makes historical lines immutable).
--   * order_amendments.response_choice                 also accepts 'accept_price'.
-- The credit ledger needs nothing new: a decrease is one credit note and an increase one debit note, both tagged with
-- amendment_id, and the existing unique index (amendment_id, entry_type) makes either happen at most once per amendment.

-- ---------------------------------------------------------------------------
-- 1. The pharmacy's answer to a price proposal
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_amendments DROP CONSTRAINT IF EXISTS order_amendments_response_choice_check;
ALTER TABLE public.order_amendments ADD CONSTRAINT order_amendments_response_choice_check
  CHECK (response_choice IS NULL OR response_choice IN
    ('accept_cancel_remaining', 'accept_backorder', 'accept_price', 'reject', 'request_clarification', 'withdrawn', 'order_cancelled'));

-- ---------------------------------------------------------------------------
-- 2. The proposed price on a line
-- ---------------------------------------------------------------------------
ALTER TABLE public.order_amendment_lines ADD COLUMN IF NOT EXISTS proposed_unit_price_ghs NUMERIC(12,2);
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_amendment_lines_price_line_check') THEN
    ALTER TABLE public.order_amendment_lines ADD CONSTRAINT order_amendment_lines_price_line_check
      CHECK (
        proposed_unit_price_ghs IS NULL
        OR (proposed_unit_price_ghs > 0 AND proposed_unit_price_ghs <> unit_price_ghs AND short_qty = 0 AND stock_treatment = 'none')
      );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. The price in force
-- ---------------------------------------------------------------------------
-- An order line's unit price today. For a line no price amendment has touched this is exactly order_items.unit_price_ghs, so
-- every reader that adopts it behaves identically for orders without a price amendment.
CREATE OR REPLACE FUNCTION public.order_item_effective_price(p_order_item_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT l.proposed_unit_price_ghs
     FROM public.order_amendment_lines l JOIN public.order_amendments a ON a.id = l.amendment_id
     WHERE l.order_item_id = oi.id AND a.kind = 'price_change' AND a.status = 'accepted' AND l.proposed_unit_price_ghs IS NOT NULL
     ORDER BY a.version DESC LIMIT 1),
    oi.unit_price_ghs)
  FROM public.order_items oi WHERE oi.id = p_order_item_id
$$;
REVOKE ALL ON FUNCTION public.order_item_effective_price(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_item_effective_price(UUID) TO authenticated, service_role;
