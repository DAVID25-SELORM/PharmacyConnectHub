-- RFQ phase 5, part 1: schema for richer quotes and line-level / split awards.
--
-- Quotes gain the commercial terms a pharmacy actually compares (delivery charge, lead time,
-- payment terms) and each quoted line gains a discount and a stored final unit price; the quoted
-- quantity may now be LESS than requested (the supplier's available quantity). Tax is deliberately
-- not modelled here: orders have no tax column, so a tax figure on a quote would never reach the
-- order it creates.
--
-- Awards move from "one quote wins" (rfqs.awarded_quote_id / awarded_order_id, singular) to an
-- rfq_awards child table, so one RFQ can award different lines to different suppliers and split a
-- line's quantity between suppliers. Those two legacy columns stay as they are (still filled for
-- the old award_rfq_quote RPC and for single-winner awards) -- nothing is dropped or rewritten.
--
-- Privacy is unchanged in kind: rfq_awards is readable by the RFQ's pharmacy and, row by row, only
-- by the wholesaler the row belongs to -- a losing supplier never sees who won or at what price.

ALTER TABLE public.rfq_quotes
  ADD COLUMN IF NOT EXISTS delivery_charge_ghs NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (delivery_charge_ghs >= 0),
  ADD COLUMN IF NOT EXISTS lead_time_days INTEGER CHECK (lead_time_days IS NULL OR lead_time_days >= 0),
  ADD COLUMN IF NOT EXISTS payment_terms TEXT CHECK (payment_terms IS NULL OR char_length(payment_terms) <= 200);

ALTER TABLE public.rfq_quote_items
  ADD COLUMN IF NOT EXISTS discount_percent NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_percent >= 0 AND discount_percent < 100),
  ADD COLUMN IF NOT EXISTS final_unit_price_ghs NUMERIC(10,2);

-- Existing quotes had no discount, so the final price is the quoted price.
UPDATE public.rfq_quote_items SET final_unit_price_ghs = unit_price_ghs WHERE final_unit_price_ghs IS NULL;
ALTER TABLE public.rfq_quote_items ALTER COLUMN final_unit_price_ghs SET NOT NULL;
ALTER TABLE public.rfq_quote_items ADD CONSTRAINT rfq_quote_items_final_price_positive CHECK (final_unit_price_ghs > 0);

CREATE TABLE IF NOT EXISTS public.rfq_awards (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  rfq_id UUID NOT NULL REFERENCES public.rfqs(id) ON DELETE CASCADE,
  rfq_item_id UUID NOT NULL REFERENCES public.rfq_items(id) ON DELETE RESTRICT,
  rfq_quote_id UUID NOT NULL REFERENCES public.rfq_quotes(id) ON DELETE RESTRICT,
  rfq_quote_item_id UUID NOT NULL REFERENCES public.rfq_quote_items(id) ON DELETE RESTRICT,
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price_ghs NUMERIC(10,2) NOT NULL CHECK (unit_price_ghs > 0),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (rfq_quote_item_id)
);
CREATE INDEX IF NOT EXISTS idx_rfq_awards_rfq ON public.rfq_awards(rfq_id);
CREATE INDEX IF NOT EXISTS idx_rfq_awards_wholesaler ON public.rfq_awards(wholesaler_id);

ALTER TABLE public.rfq_awards ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Can view rfq award row" ON public.rfq_awards FOR SELECT USING (
  public.can_view_rfq_party_row(rfq_id, wholesaler_id)
);
CREATE POLICY "Admins see all rfq awards" ON public.rfq_awards FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.rfq_awards FROM PUBLIC, anon;
GRANT SELECT ON public.rfq_awards TO authenticated;
