-- Inventory intelligence for wholesalers.
--
-- Derived from current stock plus sales history (order_items of counted orders: not cancelled,
-- not refunded). There is no cost price, batch or expiry data yet, so:
--   * stock value is at SELLING price, not cost;
--   * expiry / batch alerts are not possible until batches exist.
--
-- Definitions (all computed in SQL, results paged):
--   velocity      = units sold in the last p_window_days (7..90, default 30) / window days
--   days_remaining = stock / velocity (NULL when nothing sold in the window)
--   status        = out_of_stock (stock = 0)
--                 | low_stock    (stock > 0 and days_remaining <= 14)
--                 | dead_stock   (stock > 0, no sales in the last 90 days, AND the product has been
--                                  listed for at least 90 days, so new products are never "dead")
--                 | ok
--   movement      = fast (top 20% by units sold among products that sold) | slow (bottom 20%)
--   suggested_reorder = a recommendation, not an order: units needed to reach a 30-day target
--                       cover at recent sales speed, for low/out-of-stock products that sell.
-- Access: the business owner, or active staff with the owner/manager role (same audience as the
-- Stock insights tab). Cashiers and assistants are denied by the database, not just hidden in the UI.
-- Every row also carries whole-catalogue summary numbers so the page needs a single call.

CREATE OR REPLACE FUNCTION public.wholesaler_inventory_insights(
  p_business_id UUID,
  p_window_days INTEGER DEFAULT 30,
  p_search TEXT DEFAULT NULL,
  p_filter TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  current_stock INTEGER,
  price_ghs NUMERIC,
  stock_value_ghs NUMERIC,
  units_sold_window BIGINT,
  units_sold_90d BIGINT,
  daily_velocity NUMERIC,
  days_remaining NUMERIC,
  status TEXT,
  movement TEXT,
  suggested_reorder INTEGER,
  total_products BIGINT,
  total_out_of_stock BIGINT,
  total_low_stock BIGINT,
  total_dead_stock BIGINT,
  total_stock_value_ghs NUMERIC,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_window INTEGER := LEAST(GREATEST(COALESCE(p_window_days, 30), 7), 90);
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  v_search TEXT := NULLIF(BTRIM(COALESCE(p_search, '')), '');
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler' AND b.owner_id = auth.uid())
    OR (public.is_business_staff(auth.uid(), p_business_id)
        AND public.get_staff_role(auth.uid(), p_business_id) IN ('owner', 'manager')
        AND EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler'))
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s inventory.';
  END IF;
  IF p_filter IS NOT NULL AND p_filter NOT IN ('out_of_stock', 'low_stock', 'dead_stock', 'fast', 'slow') THEN
    RAISE EXCEPTION 'Unknown inventory filter.';
  END IF;

  RETURN QUERY
  WITH sales AS (
    SELECT oi.product_id AS pid,
      SUM(oi.quantity) FILTER (WHERE o.created_at >= now() - make_interval(days => v_window)) AS u_window,
      SUM(oi.quantity) AS u_90
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    WHERE o.wholesaler_id = p_business_id
      AND o.created_at >= now() - interval '90 days'
      AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
    GROUP BY oi.product_id
  ),
  base AS (
    SELECT
      pr.id AS pid, pr.name AS pname, pr.category AS pcat, pr.stock AS pstock, pr.price_ghs AS pprice, pr.created_at AS pcreated,
      COALESCE(s.u_window, 0)::BIGINT AS u_window,
      COALESCE(s.u_90, 0)::BIGINT AS u_90
    FROM public.products pr
    LEFT JOIN sales s ON s.pid = pr.id
    WHERE pr.wholesaler_id = p_business_id AND pr.active
  ),
  scored AS (
    SELECT
      b.*,
      round(b.u_window::NUMERIC / v_window, 3) AS velocity,
      CASE WHEN b.u_window > 0 THEN round(b.pstock / (b.u_window::NUMERIC / v_window), 1) END AS days_left,
      CASE WHEN b.u_window > 0 THEN percent_rank() OVER (PARTITION BY (b.u_window > 0) ORDER BY b.u_window) END AS rank_sold
    FROM base b
  ),
  labelled AS (
    SELECT
      s.*,
      CASE
        WHEN s.pstock <= 0 THEN 'out_of_stock'
        WHEN s.days_left IS NOT NULL AND s.days_left <= 14 THEN 'low_stock'
        WHEN s.u_90 = 0 AND s.pcreated <= now() - interval '90 days' THEN 'dead_stock'
        ELSE 'ok'
      END AS st,
      CASE
        WHEN s.rank_sold IS NULL THEN NULL
        WHEN s.rank_sold >= 0.8 THEN 'fast'
        WHEN s.rank_sold <= 0.2 AND s.pstock > 0 THEN 'slow'
      END AS mv
    FROM scored s
  ),
  summary AS (
    SELECT
      l.*,
      COUNT(*) OVER () AS n_all,
      COUNT(*) FILTER (WHERE l.st = 'out_of_stock') OVER () AS n_out,
      COUNT(*) FILTER (WHERE l.st = 'low_stock') OVER () AS n_low,
      COUNT(*) FILTER (WHERE l.st = 'dead_stock') OVER () AS n_dead,
      COALESCE(SUM(l.pstock * l.pprice) OVER (), 0) AS v_all
    FROM labelled l
  ),
  filtered AS (
    SELECT sm.* FROM summary sm
    WHERE (v_search IS NULL OR sm.pname ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      AND (p_filter IS NULL OR sm.st = p_filter OR sm.mv = p_filter)
  )
  SELECT
    f.pid, f.pname, f.pcat, f.pstock, f.pprice, f.pstock * f.pprice,
    f.u_window, f.u_90, f.velocity, f.days_left, f.st, f.mv,
    CASE WHEN f.u_window > 0 AND f.st IN ('out_of_stock', 'low_stock')
      THEN GREATEST(CEIL(f.velocity * 30)::INTEGER - f.pstock, 0) END,
    f.n_all, f.n_out, f.n_low, f.n_dead, f.v_all,
    COUNT(*) OVER ()
  FROM filtered f
  ORDER BY
    CASE f.st WHEN 'out_of_stock' THEN 0 WHEN 'low_stock' THEN 1 WHEN 'dead_stock' THEN 2 ELSE 3 END,
    f.days_left NULLS LAST, f.pname
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.wholesaler_inventory_insights(UUID, INTEGER, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wholesaler_inventory_insights(UUID, INTEGER, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
