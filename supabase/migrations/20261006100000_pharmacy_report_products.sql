-- Pharmacy-side product purchase analytics: the buyer-side mirror of wholesaler_report_products.
-- Groups a pharmacy's order_items by product across every order regardless of status (matching
-- wholesaler_report_products' own convention of counting all orders, not just delivered ones -
-- this is a "what do we buy" report, not a fulfilment report). No new tables; same
-- owner-or-active-staff access check as every other pharmacy_report_* RPC, and the same
-- p_purchase_category filter values as pharmacy_report_purchases (NULL/'nhis'/'cash_private'/
-- 'other'/'unclassified').

CREATE OR REPLACE FUNCTION public.pharmacy_report_products(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  units_purchased BIGINT,
  orders BIGINT,
  spend_ghs NUMERIC,
  suppliers BIGINT,
  avg_unit_price_ghs NUMERIC,
  last_purchased_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s reports.';
  END IF;

  IF p_purchase_category IS NOT NULL AND p_purchase_category NOT IN ('nhis', 'cash_private', 'other', 'unclassified') THEN
    RAISE EXCEPTION 'Invalid purchase category filter.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    oi.product_id, oi.product_name,
    SUM(oi.quantity), COUNT(DISTINCT oi.order_id),
    SUM(round(oi.unit_price_ghs * oi.quantity, 2)),
    COUNT(DISTINCT o.wholesaler_id),
    round(AVG(oi.unit_price_ghs), 2),
    MAX(o.created_at)
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.pharmacy_id = p_business_id
    AND o.created_at >= v_from AND o.created_at < v_to
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (
      p_purchase_category IS NULL
      OR (p_purchase_category = 'unclassified' AND oi.purchase_category IS NULL)
      OR oi.purchase_category = p_purchase_category
    )
  GROUP BY oi.product_id, oi.product_name
  ORDER BY SUM(round(oi.quantity * oi.unit_price_ghs, 2)) DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.pharmacy_report_products(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_products(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, INTEGER) TO authenticated;
