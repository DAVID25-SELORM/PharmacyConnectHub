-- Reports module, Phase 1 (platform, pharmacy, wholesaler).
--
-- Framework:
--   * public.resolve_report_range() turns a named range ('today'|'7d'|'30d'|'this_month'|
--     'last_month'|'this_quarter'|'this_year'|'custom') into concrete UTC bounds, shared by
--     every report RPC so "Last 7 days" etc. means the same thing everywhere.
--   * Aggregate reports (overview KPIs, sales-over-time, per-wholesaler/per-pharmacy/per-product
--     rollups) run entirely in SQL (GROUP BY) and return a row per bucket/business/product, not
--     a row per order — the result size is bounded by the number of businesses/products/days in
--     range, never by the number of orders, however large the order history grows.
--   * Record-level reports (pharmacy purchase list, wholesaler sales list) use the same
--     (created_at, id) keyset pagination as the platform Activity Log.
--   * Pharmacy/wholesaler RPCs are SECURITY INVOKER, STABLE, and re-check ownership/active staff
--     explicitly in addition to relying on existing RLS (same pattern as
--     list_pharmacy_order_history / list_wholesaler_order_queue).
--   * Platform RPCs are SECURITY INVOKER and check public.has_role(auth.uid(), 'admin')
--     explicitly, same as admin_list_activity / admin_platform_summary.
--
-- Not built here (no source data to report on honestly): expiry/batch tracking and an inventory
-- movement ledger — products.stock is a single running total with no batch/expiry columns and no
-- ledger table exists. The Inventory report below is a current-stock snapshot only.

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

REVOKE ALL ON FUNCTION public.resolve_report_range(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_report_range(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;

-- ===========================================================================
-- PLATFORM (admin) reports
-- ===========================================================================

-- Overview: KPI cards + a daily GMV/orders series for the range, in one round trip.
CREATE OR REPLACE FUNCTION public.admin_report_overview(
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
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
  v_result JSONB;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view platform reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  SELECT jsonb_build_object(
    'from', v_from, 'to', v_to,
    'kpis', jsonb_build_object(
      'gmv_ghs', COALESCE(SUM(o.total_ghs), 0),
      'orders_total', COUNT(*),
      'completed_orders', COUNT(*) FILTER (WHERE o.status = 'delivered'),
      'cancelled_orders', COUNT(*) FILTER (WHERE o.status = 'cancelled'),
      'avg_order_value_ghs', COALESCE(AVG(o.total_ghs), 0)
    )
  )
  INTO v_result
  FROM public.orders o
  WHERE o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_result
    || jsonb_build_object(
      'active_pharmacies', (SELECT COUNT(*) FROM public.businesses WHERE type = 'pharmacy' AND verification_status = 'approved'),
      'active_wholesalers', (SELECT COUNT(*) FROM public.businesses WHERE type = 'wholesaler' AND verification_status = 'approved'),
      'pending_businesses', (SELECT COUNT(*) FROM public.businesses WHERE verification_status = 'pending')
    )
    || jsonb_build_object(
      'series', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'bucket', d.bucket, 'orders', d.orders, 'gmv_ghs', d.gmv_ghs
        ) ORDER BY d.bucket), '[]'::JSONB)
        FROM (
          SELECT date_trunc('day', o.created_at) AS bucket, COUNT(*) AS orders, SUM(o.total_ghs) AS gmv_ghs
          FROM public.orders o
          WHERE o.created_at >= v_from AND o.created_at < v_to
          GROUP BY 1
        ) d
      )
    );
END;
$$;

-- Marketplace sales report: bucketed by day/week/month, filterable, one row per bucket.
CREATE OR REPLACE FUNCTION public.admin_report_sales(
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_group_by TEXT DEFAULT 'day',
  p_wholesaler_id UUID DEFAULT NULL,
  p_pharmacy_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL
)
RETURNS TABLE (
  bucket TIMESTAMPTZ,
  orders BIGINT,
  gross_ghs NUMERIC,
  discount_ghs NUMERIC,
  net_ghs NUMERIC,
  avg_order_value_ghs NUMERIC
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
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view platform reports.';
  END IF;
  IF p_group_by NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'group_by must be day, week or month.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    date_trunc(p_group_by, o.created_at),
    COUNT(*),
    COALESCE(SUM(COALESCE(o.subtotal_ghs, o.total_ghs)), 0),
    COALESCE(SUM(o.discount_amount_ghs), 0),
    COALESCE(SUM(o.total_ghs), 0),
    COALESCE(AVG(o.total_ghs), 0)
  FROM public.orders o
  WHERE o.created_at >= v_from AND o.created_at < v_to
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (p_pharmacy_id IS NULL OR o.pharmacy_id = p_pharmacy_id)
    AND (p_status IS NULL OR o.status::TEXT = p_status)
    AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status)
    AND (p_payment_method IS NULL OR o.payment_method::TEXT = p_payment_method)
  GROUP BY 1
  ORDER BY 1;
END;
$$;

-- Wholesaler performance: one row per wholesaler with orders in range, bounded by wholesaler count.
CREATE OR REPLACE FUNCTION public.admin_report_wholesaler_performance(
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  wholesaler_id UUID,
  wholesaler_name TEXT,
  orders BIGINT,
  sales_ghs NUMERIC,
  avg_order_value_ghs NUMERIC,
  customers BIGINT,
  items_sold BIGINT,
  cancelled_orders BIGINT
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
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view platform reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    b.id, b.name,
    COUNT(DISTINCT o.id),
    COALESCE(SUM(o.total_ghs), 0),
    COALESCE(AVG(o.total_ghs), 0),
    COUNT(DISTINCT o.pharmacy_id),
    COALESCE(SUM(oi.quantity), 0),
    COUNT(DISTINCT o.id) FILTER (WHERE o.status = 'cancelled')
  FROM public.businesses b
  JOIN public.orders o ON o.wholesaler_id = b.id AND o.created_at >= v_from AND o.created_at < v_to
  LEFT JOIN public.order_items oi ON oi.order_id = o.id
  WHERE b.type = 'wholesaler'
    AND (NULLIF(btrim(p_search), '') IS NULL OR b.name ILIKE '%' || btrim(p_search) || '%')
  GROUP BY b.id, b.name
  ORDER BY COALESCE(SUM(o.total_ghs), 0) DESC
  LIMIT v_limit;
END;
$$;

-- Pharmacy activity: one row per pharmacy with orders in range, bounded by pharmacy count.
CREATE OR REPLACE FUNCTION public.admin_report_pharmacy_activity(
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  pharmacy_id UUID,
  pharmacy_name TEXT,
  orders BIGINT,
  purchases_ghs NUMERIC,
  suppliers_used BIGINT,
  avg_basket_ghs NUMERIC,
  last_order_at TIMESTAMPTZ
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
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view platform reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    b.id, b.name,
    COUNT(*),
    COALESCE(SUM(o.total_ghs), 0),
    COUNT(DISTINCT o.wholesaler_id),
    COALESCE(AVG(o.total_ghs), 0),
    MAX(o.created_at)
  FROM public.businesses b
  JOIN public.orders o ON o.pharmacy_id = b.id AND o.created_at >= v_from AND o.created_at < v_to
  WHERE b.type = 'pharmacy'
    AND (NULLIF(btrim(p_search), '') IS NULL OR b.name ILIKE '%' || btrim(p_search) || '%')
  GROUP BY b.id, b.name
  ORDER BY COALESCE(SUM(o.total_ghs), 0) DESC
  LIMIT v_limit;
END;
$$;

-- Payments: summary counts/amounts + a bounded recent list (capped, not deep-paginated in phase 1).
CREATE OR REPLACE FUNCTION public.admin_report_payments(
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 200
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
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
  v_result JSONB;
BEGIN
  IF NOT public.has_role(auth.uid(), 'admin') THEN
    RAISE EXCEPTION 'Only platform admins can view platform reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  SELECT jsonb_build_object(
    'summary', jsonb_build_object(
      'paid_orders', COUNT(*) FILTER (WHERE o.payment_status = 'paid'),
      'paid_ghs', COALESCE(SUM(o.total_ghs) FILTER (WHERE o.payment_status = 'paid'), 0),
      'unpaid_orders', COUNT(*) FILTER (WHERE o.payment_status = 'unpaid'),
      'unpaid_ghs', COALESCE(SUM(o.total_ghs) FILTER (WHERE o.payment_status = 'unpaid'), 0),
      'failed_orders', COUNT(*) FILTER (WHERE o.payment_status = 'failed'),
      'refunded_orders', COUNT(*) FILTER (WHERE o.payment_status = 'refunded'),
      'cod_orders', COUNT(*) FILTER (WHERE o.payment_method = 'cod'),
      'paystack_orders', COUNT(*) FILTER (WHERE o.payment_method = 'paystack')
    )
  )
  INTO v_result
  FROM public.orders o
  WHERE o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_result || jsonb_build_object(
    'rows', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'order_id', x.id, 'order_number', x.order_number, 'created_at', x.created_at,
        'pharmacy_name', x.pharmacy_name, 'wholesaler_name', x.wholesaler_name,
        'payment_method', x.payment_method, 'total_ghs', x.total_ghs, 'payment_status', x.payment_status
      ) ORDER BY x.created_at DESC), '[]'::JSONB)
      FROM (
        SELECT o.id, o.order_number, o.created_at, ph.name AS pharmacy_name, wh.name AS wholesaler_name,
          o.payment_method, o.total_ghs, o.payment_status
        FROM public.orders o
        JOIN public.businesses ph ON ph.id = o.pharmacy_id
        JOIN public.businesses wh ON wh.id = o.wholesaler_id
        WHERE o.created_at >= v_from AND o.created_at < v_to
          AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status)
          AND (p_payment_method IS NULL OR o.payment_method::TEXT = p_payment_method)
        ORDER BY o.created_at DESC
        LIMIT v_limit
      ) x
    )
  );
END;
$$;

-- ===========================================================================
-- PHARMACY reports (scoped to a business the caller owns or actively staffs)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.pharmacy_report_overview(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
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
  v_result JSONB;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  SELECT jsonb_build_object(
    'from', v_from, 'to', v_to,
    'kpis', jsonb_build_object(
      'total_purchases_ghs', COALESCE(SUM(o.total_ghs), 0),
      'total_orders', COUNT(*),
      'delivered_orders', COUNT(*) FILTER (WHERE o.status = 'delivered'),
      'outstanding_orders', COUNT(*) FILTER (WHERE o.status NOT IN ('delivered', 'cancelled')),
      'total_discount_ghs', COALESCE(SUM(o.discount_amount_ghs), 0),
      'avg_order_value_ghs', COALESCE(AVG(o.total_ghs), 0)
    ),
    'series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', d.bucket, 'orders', d.orders, 'spend_ghs', d.spend_ghs) ORDER BY d.bucket), '[]'::JSONB)
      FROM (
        SELECT date_trunc('day', o2.created_at) AS bucket, COUNT(*) AS orders, SUM(o2.total_ghs) AS spend_ghs
        FROM public.orders o2
        WHERE o2.pharmacy_id = p_business_id AND o2.created_at >= v_from AND o2.created_at < v_to
        GROUP BY 1
      ) d
    )
  )
  INTO v_result
  FROM public.orders o
  WHERE o.pharmacy_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_result;
END;
$$;

-- Purchase / order history list: keyset pagination on (created_at, id), same shape as the
-- Activity Log. Doubles as the Payments view (payment_method/status are returned on every row).
CREATE OR REPLACE FUNCTION public.pharmacy_report_orders(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  order_number TEXT,
  created_at TIMESTAMPTZ,
  wholesaler_id UUID,
  wholesaler_name TEXT,
  item_count BIGINT,
  subtotal_ghs NUMERIC,
  discount_amount_ghs NUMERIC,
  total_ghs NUMERIC,
  status TEXT,
  payment_status TEXT,
  payment_method TEXT
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

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    o.id, o.order_number, o.created_at, o.wholesaler_id, w.name,
    (SELECT COUNT(*) FROM public.order_items oi WHERE oi.order_id = o.id),
    COALESCE(o.subtotal_ghs, o.total_ghs), o.discount_amount_ghs, o.total_ghs,
    o.status::TEXT, o.payment_status::TEXT, o.payment_method::TEXT
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  WHERE o.pharmacy_id = p_business_id
    AND o.created_at >= v_from AND o.created_at < v_to
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (p_status IS NULL OR o.status::TEXT = p_status)
    AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status)
    AND (p_payment_method IS NULL OR o.payment_method::TEXT = p_payment_method)
    AND (
      p_cursor_created_at IS NULL OR p_cursor_id IS NULL
      OR (o.created_at, o.id) < (p_cursor_created_at, p_cursor_id)
    )
  ORDER BY o.created_at DESC, o.id DESC
  LIMIT v_limit;
END;
$$;

-- Supplier spend: one row per wholesaler this pharmacy has ordered from, bounded by supplier count.
CREATE OR REPLACE FUNCTION public.pharmacy_report_supplier_spend(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  wholesaler_id UUID,
  wholesaler_name TEXT,
  orders BIGINT,
  spend_ghs NUMERIC,
  avg_order_value_ghs NUMERIC,
  discount_ghs NUMERIC,
  last_order_at TIMESTAMPTZ
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
    w.id, w.name,
    COUNT(*),
    COALESCE(SUM(o.total_ghs), 0),
    COALESCE(AVG(o.total_ghs), 0),
    COALESCE(SUM(o.discount_amount_ghs), 0),
    MAX(o.created_at)
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  WHERE o.pharmacy_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY w.id, w.name
  ORDER BY COALESCE(SUM(o.total_ghs), 0) DESC
  LIMIT 200;
END;
$$;

-- ===========================================================================
-- WHOLESALER reports (scoped to a business the caller owns or actively staffs)
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.wholesaler_report_overview(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
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
  v_result JSONB;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  SELECT jsonb_build_object(
    'from', v_from, 'to', v_to,
    'kpis', jsonb_build_object(
      'total_sales_ghs', COALESCE(SUM(o.total_ghs), 0),
      'total_orders', COUNT(*),
      'customers', COUNT(DISTINCT o.pharmacy_id),
      'units_sold', COALESCE((SELECT SUM(oi.quantity) FROM public.order_items oi JOIN public.orders o2 ON o2.id = oi.order_id WHERE o2.wholesaler_id = p_business_id AND o2.created_at >= v_from AND o2.created_at < v_to), 0),
      'discounts_given_ghs', COALESCE(SUM(o.discount_amount_ghs), 0),
      'avg_order_value_ghs', COALESCE(AVG(o.total_ghs), 0),
      'pending_orders', COUNT(*) FILTER (WHERE o.status IN ('pending', 'accepted', 'packed', 'dispatched'))
    ),
    'series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', d.bucket, 'orders', d.orders, 'sales_ghs', d.sales_ghs) ORDER BY d.bucket), '[]'::JSONB)
      FROM (
        SELECT date_trunc('day', o2.created_at) AS bucket, COUNT(*) AS orders, SUM(o2.total_ghs) AS sales_ghs
        FROM public.orders o2
        WHERE o2.wholesaler_id = p_business_id AND o2.created_at >= v_from AND o2.created_at < v_to
        GROUP BY 1
      ) d
    )
  )
  INTO v_result
  FROM public.orders o
  WHERE o.wholesaler_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_result;
END;
$$;

-- Sales list: keyset pagination, same shape/contract as pharmacy_report_orders.
CREATE OR REPLACE FUNCTION public.wholesaler_report_sales(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_pharmacy_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  order_number TEXT,
  created_at TIMESTAMPTZ,
  pharmacy_id UUID,
  pharmacy_name TEXT,
  item_count BIGINT,
  gross_ghs NUMERIC,
  discount_amount_ghs NUMERIC,
  net_ghs NUMERIC,
  status TEXT,
  payment_status TEXT
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
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    o.id, o.order_number, o.created_at, o.pharmacy_id, p.name,
    (SELECT COUNT(*) FROM public.order_items oi WHERE oi.order_id = o.id),
    COALESCE(o.subtotal_ghs, o.total_ghs), o.discount_amount_ghs, o.total_ghs,
    o.status::TEXT, o.payment_status::TEXT
  FROM public.orders o
  JOIN public.businesses p ON p.id = o.pharmacy_id
  WHERE o.wholesaler_id = p_business_id
    AND o.created_at >= v_from AND o.created_at < v_to
    AND (p_pharmacy_id IS NULL OR o.pharmacy_id = p_pharmacy_id)
    AND (p_status IS NULL OR o.status::TEXT = p_status)
    AND (p_payment_status IS NULL OR o.payment_status::TEXT = p_payment_status)
    AND (
      p_cursor_created_at IS NULL OR p_cursor_id IS NULL
      OR (o.created_at, o.id) < (p_cursor_created_at, p_cursor_id)
    )
  ORDER BY o.created_at DESC, o.id DESC
  LIMIT v_limit;
END;
$$;

-- Customers: one row per pharmacy that has ordered from this wholesaler, bounded by customer count.
CREATE OR REPLACE FUNCTION public.wholesaler_report_customers(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  pharmacy_id UUID,
  pharmacy_name TEXT,
  orders BIGINT,
  revenue_ghs NUMERIC,
  avg_order_value_ghs NUMERIC,
  discount_given_ghs NUMERIC,
  last_order_at TIMESTAMPTZ
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
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    p.id, p.name,
    COUNT(*),
    COALESCE(SUM(o.total_ghs), 0),
    COALESCE(AVG(o.total_ghs), 0),
    COALESCE(SUM(o.discount_amount_ghs), 0),
    MAX(o.created_at)
  FROM public.orders o
  JOIN public.businesses p ON p.id = o.pharmacy_id
  WHERE o.wholesaler_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY p.id, p.name
  ORDER BY COALESCE(SUM(o.total_ghs), 0) DESC
  LIMIT 200;
END;
$$;

-- Product sales: one row per product sold by this wholesaler in range, bounded by product count.
CREATE OR REPLACE FUNCTION public.wholesaler_report_products(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_limit INTEGER DEFAULT 100
)
RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  units_sold BIGINT,
  orders BIGINT,
  revenue_ghs NUMERIC,
  customers BIGINT,
  stock_remaining INTEGER
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
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN QUERY
  SELECT
    oi.product_id, oi.product_name,
    SUM(oi.quantity), COUNT(DISTINCT oi.order_id),
    SUM(oi.quantity * oi.unit_price_ghs), COUNT(DISTINCT o.pharmacy_id),
    MAX(pr.stock)
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  LEFT JOIN public.products pr ON pr.id = oi.product_id
  WHERE o.wholesaler_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to
  GROUP BY oi.product_id, oi.product_name
  ORDER BY SUM(oi.quantity * oi.unit_price_ghs) DESC
  LIMIT v_limit;
END;
$$;

-- Inventory snapshot: current stock only (no batch/expiry data exists to report on).
CREATE OR REPLACE FUNCTION public.wholesaler_report_inventory(
  p_business_id UUID,
  p_search TEXT DEFAULT NULL,
  p_low_stock_at_or_below INTEGER DEFAULT NULL
)
RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  stock INTEGER,
  price_ghs NUMERIC,
  stock_value_ghs NUMERIC,
  active BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  RETURN QUERY
  SELECT pr.id, pr.name, pr.category, pr.stock, pr.price_ghs, pr.stock * pr.price_ghs, pr.active
  FROM public.products pr
  WHERE pr.wholesaler_id = p_business_id
    AND (NULLIF(btrim(p_search), '') IS NULL OR pr.name ILIKE '%' || btrim(p_search) || '%')
    AND (p_low_stock_at_or_below IS NULL OR pr.stock <= p_low_stock_at_or_below)
  ORDER BY pr.stock ASC, pr.name ASC
  LIMIT 1000;
END;
$$;

-- ===========================================================================
-- Grants (each function also checks authorization itself; anon gets nothing)
-- ===========================================================================
REVOKE ALL ON FUNCTION public.admin_report_overview(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_report_sales(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_report_wholesaler_performance(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_report_pharmacy_activity(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_report_payments(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pharmacy_report_overview(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pharmacy_report_orders(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pharmacy_report_supplier_spend(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_report_overview(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_report_sales(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_report_customers(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_report_products(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_report_inventory(UUID, TEXT, INTEGER) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_report_overview(TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_report_sales(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_report_wholesaler_performance(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_report_pharmacy_activity(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_report_payments(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_overview(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_orders(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pharmacy_report_supplier_spend(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_report_overview(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_report_sales(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_report_customers(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_report_products(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_report_inventory(UUID, TEXT, INTEGER) TO authenticated;

-- ===========================================================================
-- Indexes for the filter/order shapes used above (orders already has
-- idx_orders_pharmacy / idx_orders_wholesaler / idx_orders_status from the base schema).
-- ===========================================================================
CREATE INDEX IF NOT EXISTS orders_pharmacy_created_id_idx ON public.orders (pharmacy_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS orders_wholesaler_created_id_idx ON public.orders (wholesaler_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS orders_created_at_idx ON public.orders (created_at);
CREATE INDEX IF NOT EXISTS order_items_product_idx ON public.order_items (product_id);
