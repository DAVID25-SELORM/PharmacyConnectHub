-- Summary-first pharmacy order history and lazy detail loading.
-- Both functions are SECURITY INVOKER and repeat the ownership check so URL or
-- order-id manipulation cannot cross pharmacy boundaries.
CREATE OR REPLACE FUNCTION public.list_pharmacy_order_history(
  p_page INTEGER DEFAULT 1,
  p_page_size INTEGER DEFAULT 20,
  p_search TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'newest'
)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH scoped AS (
    SELECT o.id, o.order_number, o.status, o.total_ghs, o.created_at,
      o.payment_method, o.payment_status, w.name AS wholesaler_name,
      (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS item_count,
      (SELECT coalesce(sum(oi.quantity), 0) FROM public.order_items oi WHERE oi.order_id = o.id) AS unit_count
    FROM public.orders o
    JOIN public.businesses w ON w.id = o.wholesaler_id
    WHERE EXISTS (
      SELECT 1 FROM public.businesses pb
      WHERE pb.id = o.pharmacy_id AND pb.owner_id = auth.uid() AND pb.type = 'pharmacy'
    )
    AND (NULLIF(btrim(p_status), '') IS NULL OR o.status::TEXT = p_status)
    AND (NULLIF(btrim(p_payment_status), '') IS NULL OR o.payment_status::TEXT = p_payment_status)
    AND (
      NULLIF(btrim(p_search), '') IS NULL
      OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      OR w.name ILIKE '%' || btrim(p_search) || '%'
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
  ) FROM counted;
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
      'items', COALESCE((SELECT jsonb_agg(to_jsonb(oi) ORDER BY oi.id) FROM public.order_items oi WHERE oi.order_id = o.id), '[]'::JSONB)
    )
  )
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  WHERE o.id = p_order_id
    AND EXISTS (
      SELECT 1 FROM public.businesses pb
      WHERE pb.id = o.pharmacy_id AND pb.owner_id = auth.uid() AND pb.type = 'pharmacy'
    );
$$;

REVOKE ALL ON FUNCTION public.list_pharmacy_order_history(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pharmacy_order_detail(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pharmacy_order_history(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pharmacy_order_detail(UUID) TO authenticated;
