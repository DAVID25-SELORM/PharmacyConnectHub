-- Order history filters for the pharmacy "My Orders" list: date range, supplier, purchase
-- category, and procurement-reference search (folded into the existing search box rather than a
-- separate field, matching how order number / wholesaler name / product name search already
-- works). All filtering stays server-side (this RPC is already keyset/offset-paginated).
--
-- Also fixes an access gap found while touching this code: list_pharmacy_order_history and
-- get_pharmacy_order_detail only ever checked the business OWNER (pb.owner_id = auth.uid()),
-- never active staff - unlike every other pharmacy-report RPC in this codebase (see
-- pharmacy_report_orders / pharmacy_report_supplier_spend), which also allow
-- is_business_staff(...). A pharmacy manager/cashier/assistant could place and process orders but
-- not see the order history or open an order's detail. Widened to match the established pattern;
-- no new role gains order-history access, this just brings pharmacy staff in line with what
-- reports already allow them.

-- Reused by reports too: adds a calendar-week option alongside the existing rolling 7d/30d ones.
CREATE OR REPLACE FUNCTION public.resolve_report_range(
  p_range TEXT,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS TABLE (range_from TIMESTAMPTZ, range_to TIMESTAMPTZ)
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
BEGIN
  CASE p_range
    WHEN 'today' THEN
      RETURN QUERY SELECT date_trunc('day', now()), now();
    WHEN 'this_week' THEN
      RETURN QUERY SELECT date_trunc('week', now()), now();
    WHEN '7d' THEN
      RETURN QUERY SELECT now() - interval '7 days', now();
    WHEN '30d' THEN
      RETURN QUERY SELECT now() - interval '30 days', now();
    WHEN 'this_month' THEN
      RETURN QUERY SELECT date_trunc('month', now()), now();
    WHEN 'last_month' THEN
      RETURN QUERY SELECT
        date_trunc('month', now()) - interval '1 month',
        date_trunc('month', now());
    WHEN 'this_quarter' THEN
      RETURN QUERY SELECT date_trunc('quarter', now()), now();
    WHEN 'this_year' THEN
      RETURN QUERY SELECT date_trunc('year', now()), now();
    WHEN 'custom' THEN
      IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'A custom range needs both a start and an end date.';
      END IF;
      IF p_from > p_to THEN
        RAISE EXCEPTION 'The start date must be before the end date.';
      END IF;
      RETURN QUERY SELECT p_from, p_to;
    ELSE
      -- No range = all time.
      RETURN QUERY SELECT '-infinity'::TIMESTAMPTZ, now();
  END CASE;
END;
$$;

DROP FUNCTION IF EXISTS public.list_pharmacy_order_history(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.list_pharmacy_order_history(
  p_page INTEGER DEFAULT 1,
  p_page_size INTEGER DEFAULT 20,
  p_search TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'newest',
  p_range TEXT DEFAULT NULL,
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
BEGIN
  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN (
    WITH scoped AS (
      SELECT o.id, o.order_number, o.status, o.total_ghs, o.created_at,
        o.payment_method, o.payment_status, o.purchase_category, o.wholesaler_id, w.name AS wholesaler_name,
        o.procurement_id, pr.reference AS procurement_reference,
        (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS item_count,
        (SELECT coalesce(sum(oi.quantity), 0) FROM public.order_items oi WHERE oi.order_id = o.id) AS unit_count
      FROM public.orders o
      JOIN public.businesses w ON w.id = o.wholesaler_id
      LEFT JOIN public.procurements pr ON pr.id = o.procurement_id
      WHERE EXISTS (
        SELECT 1 FROM public.businesses pb
        WHERE pb.id = o.pharmacy_id AND pb.type = 'pharmacy'
          AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), pb.id))
      )
      AND (
        NULLIF(btrim(p_status), '') IS NULL
        OR (p_status = 'active' AND o.status::TEXT IN ('pending', 'accepted', 'packed', 'dispatched'))
        OR (p_status <> 'active' AND o.status::TEXT = p_status)
      )
      AND (NULLIF(btrim(p_payment_status), '') IS NULL OR o.payment_status::TEXT = p_payment_status)
      AND (
        NULLIF(btrim(p_purchase_category), '') IS NULL
        OR (p_purchase_category = 'unclassified' AND o.purchase_category IS NULL)
        OR o.purchase_category = p_purchase_category
      )
      AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
      AND o.created_at >= v_from AND o.created_at < v_to
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
        OR w.name ILIKE '%' || btrim(p_search) || '%'
        OR pr.reference ILIKE '%' || btrim(p_search) || '%'
        OR EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id AND oi.product_name ILIKE '%' || btrim(p_search) || '%')
      )
    ), counted AS (
      SELECT *, count(*) OVER () AS total_count FROM scoped
      ORDER BY
        CASE WHEN p_sort = 'highest' THEN total_ghs END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN total_ghs END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id
      OFFSET GREATEST(p_page - 1, 0) * LEAST(GREATEST(p_page_size, 1), 100)
      LIMIT LEAST(GREATEST(p_page_size, 1), 100)
    )
    SELECT jsonb_build_object(
      'total_count', COALESCE(max(total_count), 0),
      'page', GREATEST(p_page, 1),
      'page_size', LEAST(GREATEST(p_page_size, 1), 100),
      'orders', COALESCE(jsonb_agg(to_jsonb(counted) - 'total_count' ORDER BY
        CASE WHEN p_sort = 'highest' THEN total_ghs END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN total_ghs END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id), '[]'::JSONB)
    ) FROM counted
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_pharmacy_order_detail(p_order_id UUID)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
      'wholesaler', jsonb_build_object('name', w.name, 'city', w.city, 'region', w.region),
      'procurement_reference', pr.reference,
      'items', COALESCE((SELECT jsonb_agg(to_jsonb(oi) ORDER BY oi.id) FROM public.order_items oi WHERE oi.order_id = o.id), '[]'::JSONB)
    )
  )
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  LEFT JOIN public.procurements pr ON pr.id = o.procurement_id
  WHERE o.id = p_order_id
    AND EXISTS (
      SELECT 1 FROM public.businesses pb
      WHERE pb.id = o.pharmacy_id AND pb.type = 'pharmacy'
        AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), pb.id))
    );
$$;

REVOKE ALL ON FUNCTION public.list_pharmacy_order_history(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pharmacy_order_detail(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pharmacy_order_history(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pharmacy_order_detail(UUID) TO authenticated;
