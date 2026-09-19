-- Secure, summary-first order queue for wholesaler dashboards.
-- RLS remains the source of authorization; the owner check below makes the
-- intended scope explicit even if policies are changed later.
CREATE OR REPLACE FUNCTION public.list_wholesaler_order_queue(
  p_page INTEGER DEFAULT 1,
  p_page_size INTEGER DEFAULT 20,
  p_search TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'oldest'
)
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
  WITH scoped AS (
    SELECT o.*, b.name AS pharmacy_name, b.city AS pharmacy_city
    FROM public.orders o
    JOIN public.businesses b ON b.id = o.pharmacy_id
    WHERE EXISTS (
      SELECT 1 FROM public.businesses wb
      WHERE wb.id = o.wholesaler_id AND wb.owner_id = auth.uid() AND wb.type = 'wholesaler'
    )
    AND (NULLIF(btrim(p_status), '') IS NULL OR o.status::TEXT = p_status)
    AND (
      NULLIF(btrim(p_search), '') IS NULL
      OR o.order_number ILIKE '%' || btrim(p_search) || '%'
      OR b.name ILIKE '%' || btrim(p_search) || '%'
      OR b.city ILIKE '%' || btrim(p_search) || '%'
    )
  ), counted AS (
    SELECT *, count(*) OVER () AS total_count
    FROM scoped
    ORDER BY
      CASE WHEN p_sort = 'highest' THEN total_ghs END DESC NULLS LAST,
      CASE WHEN p_sort = 'lowest' THEN total_ghs END ASC NULLS LAST,
      CASE WHEN p_sort = 'pharmacy' THEN pharmacy_name END ASC NULLS LAST,
      CASE WHEN p_sort = 'newest' THEN created_at END DESC NULLS LAST,
      CASE WHEN p_sort NOT IN ('highest', 'lowest', 'pharmacy', 'newest') THEN created_at END ASC NULLS LAST,
      id
    OFFSET GREATEST(p_page - 1, 0) * LEAST(GREATEST(p_page_size, 1), 100)
    LIMIT LEAST(GREATEST(p_page_size, 1), 100)
  )
  SELECT jsonb_build_object(
    'total_count', COALESCE(max(total_count), 0),
    'page', GREATEST(p_page, 1),
    'page_size', LEAST(GREATEST(p_page_size, 1), 100),
    'orders', COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', id,
        'order_number', order_number,
        'status', status,
        'total_ghs', total_ghs,
        'created_at', created_at,
        'payment_method', payment_method,
        'payment_status', payment_status,
        'pharmacy', jsonb_build_object('name', pharmacy_name, 'city', pharmacy_city)
      ) ORDER BY created_at ASC, id
    ), '[]'::JSONB)
  )
  FROM counted;
$$;

REVOKE ALL ON FUNCTION public.list_wholesaler_order_queue(INTEGER, INTEGER, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_order_queue(INTEGER, INTEGER, TEXT, TEXT, TEXT) TO authenticated;
