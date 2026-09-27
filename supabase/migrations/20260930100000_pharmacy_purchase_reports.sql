-- Pharmacy purchase reports (Core / NHIS / Cash-Private), built on top of the purchase
-- classification and procurement grouping shipped in the previous two migrations.
--
-- Deliberately a single item-level RPC rather than three separate ones: filtering the same table
-- by p_purchase_category = 'nhis' (or 'cash_private', or NULL for "all") already satisfies every
-- documented requirement -
--   - a fully-NHIS order: every one of its items is 'nhis', so all of them match the NHIS filter;
--   - a Mixed order: only its NHIS-tagged lines match, its Cash-tagged lines do not - so the NHIS
--     report correctly excludes Cash/Private lines from a Mixed order, and vice versa;
-- with no special-casing needed. "mixed" is never an item-level value (see the previous
-- migration), so it is not a valid filter value here - only nhis / cash_private / other /
-- unclassified are.
--
-- No double-counting risk: totals are summed directly over order_items (the atomic unit), never
-- over a procurement or order total repeated per line, and order_count uses
-- COUNT(DISTINCT order_id).

CREATE OR REPLACE FUNCTION public.pharmacy_report_purchases(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  created_at TIMESTAMPTZ,
  order_id UUID,
  order_number TEXT,
  procurement_reference TEXT,
  wholesaler_id UUID,
  wholesaler_name TEXT,
  product_name TEXT,
  quantity INTEGER,
  unit_price_ghs NUMERIC,
  line_total_ghs NUMERIC,
  purchase_category TEXT,
  status TEXT,
  payment_status TEXT,
  receipt_sent_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
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
    oi.id, o.created_at, o.id, o.order_number, pr.reference,
    o.wholesaler_id, w.name,
    oi.product_name, oi.quantity, oi.unit_price_ghs,
    round(oi.unit_price_ghs * oi.quantity, 2),
    oi.purchase_category, o.status::TEXT, o.payment_status::TEXT, o.receipt_sent_at
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.businesses w ON w.id = o.wholesaler_id
  LEFT JOIN public.procurements pr ON pr.id = o.procurement_id
  WHERE o.pharmacy_id = p_business_id
    AND o.created_at >= v_from AND o.created_at < v_to
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (
      p_purchase_category IS NULL
      OR (p_purchase_category = 'unclassified' AND oi.purchase_category IS NULL)
      OR oi.purchase_category = p_purchase_category
    )
    AND (p_status IS NULL OR o.status::TEXT = p_status)
    AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status)
    AND (
      p_cursor_created_at IS NULL OR p_cursor_id IS NULL
      OR (o.created_at, oi.id) < (p_cursor_created_at, p_cursor_id)
    )
  ORDER BY o.created_at DESC, oi.id DESC
  LIMIT v_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.pharmacy_report_purchases_summary(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL
)
RETURNS TABLE (
  total_value_ghs NUMERIC,
  nhis_value_ghs NUMERIC,
  cash_private_value_ghs NUMERIC,
  other_value_ghs NUMERIC,
  unclassified_value_ghs NUMERIC,
  order_count BIGINT,
  item_quantity BIGINT,
  line_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category = 'nhis'), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category = 'cash_private'), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category = 'other'), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category IS NULL), 0),
    COUNT(DISTINCT o.id),
    COALESCE(SUM(oi.quantity), 0),
    COUNT(*)
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.pharmacy_id = p_business_id
    AND o.created_at >= v_from AND o.created_at < v_to
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (p_status IS NULL OR o.status::TEXT = p_status)
    AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status);
END;
$$;

REVOKE ALL ON FUNCTION public.pharmacy_report_purchases(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pharmacy_report_purchases_summary(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_purchases(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_purchases_summary(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT) TO authenticated;
