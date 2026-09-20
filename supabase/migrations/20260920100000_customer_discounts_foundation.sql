-- Foundation for wholesaler-specific pharmacy discounts.
-- Checkout snapshot columns are populated by the follow-up checkout migration.
CREATE TABLE public.customer_discounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  discount_type TEXT NOT NULL DEFAULT 'percentage' CHECK (discount_type IN ('percentage', 'fixed')),
  discount_percent NUMERIC(5,2) CHECK (discount_percent > 0 AND discount_percent <= 100),
  discount_amount NUMERIC(10,2) CHECK (discount_amount > 0),
  minimum_order_value NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (minimum_order_value >= 0),
  starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ends_at TIMESTAMPTZ,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  internal_note TEXT,
  created_by UUID REFERENCES auth.users(id),
  updated_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR ends_at > starts_at),
  CHECK ((discount_type = 'percentage' AND discount_percent IS NOT NULL AND discount_amount IS NULL)
      OR (discount_type = 'fixed' AND discount_amount IS NOT NULL AND discount_percent IS NULL))
);

CREATE UNIQUE INDEX customer_discounts_one_active_pair
  ON public.customer_discounts(wholesaler_id, pharmacy_id) WHERE active;
CREATE INDEX customer_discounts_effective_lookup
  ON public.customer_discounts(wholesaler_id, pharmacy_id, active, starts_at, ends_at);

ALTER TABLE public.customer_discounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Wholesaler owners and managers manage discounts"
  ON public.customer_discounts FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND (b.owner_id = auth.uid()
          OR (public.is_business_staff(auth.uid(), b.id)
            AND public.get_staff_role(auth.uid(), b.id) IN ('owner', 'manager')))
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = wholesaler_id
        AND (b.owner_id = auth.uid()
          OR (public.is_business_staff(auth.uid(), b.id)
            AND public.get_staff_role(auth.uid(), b.id) IN ('owner', 'manager')))
    )
  );
-- Do not expose internal_note through direct pharmacy table reads. Pharmacies
-- use the restricted RPC below, which returns only customer-facing fields.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS subtotal_ghs NUMERIC(10,2);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS discount_type TEXT;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS discount_rate NUMERIC(10,2);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS base_unit_price_ghs NUMERIC(10,2);
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0;

REVOKE ALL ON public.customer_discounts FROM PUBLIC;
GRANT SELECT ON public.customer_discounts TO authenticated;
GRANT ALL ON public.customer_discounts TO service_role;

CREATE OR REPLACE FUNCTION public.get_my_customer_discount(p_wholesaler_id UUID)
RETURNS TABLE (
  id UUID,
  wholesaler_id UUID,
  pharmacy_id UUID,
  discount_type TEXT,
  discount_percent NUMERIC,
  discount_amount NUMERIC,
  minimum_order_value NUMERIC,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  active BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT d.id, d.wholesaler_id, d.pharmacy_id, d.discount_type,
    d.discount_percent, d.discount_amount, d.minimum_order_value,
    d.starts_at, d.ends_at, d.active
  FROM public.customer_discounts d
  WHERE d.wholesaler_id = p_wholesaler_id
    AND d.active
    AND EXISTS (
      SELECT 1 FROM public.businesses b
      WHERE b.id = d.pharmacy_id AND b.owner_id = auth.uid() AND b.type = 'pharmacy'
    );
$$;

REVOKE ALL ON FUNCTION public.get_my_customer_discount(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_customer_discount(UUID) TO authenticated;
