-- Wholesaler customer CRM and customer statements.
--
-- There is no payments/credits/returns ledger yet, so figures are derived from orders only:
--   * a "counted" order is one that is not cancelled and not refunded;
--   * a counted order is a DEBIT (its total) on the day it was placed;
--   * a counted order with payment_status = 'paid' is also a CREDIT (its total) on the day
--     payment was confirmed (paid_at, else payment_confirmed_at, else created_at);
--   * outstanding = counted orders that are unpaid or failed.
-- When credit terms / returns are added later, they become extra ledger lines here.
--
-- All three RPCs are SECURITY INVOKER (RLS still applies) and re-check access explicitly.
-- Aggregation happens in SQL; results are bounded (paged customers, capped statement lines).

CREATE INDEX IF NOT EXISTS orders_wholesaler_pharmacy_created_idx
  ON public.orders (wholesaler_id, pharmacy_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Customer list with segments
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wholesaler_customers(
  p_business_id UUID,
  p_search TEXT DEFAULT NULL,
  p_segment TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  pharmacy_id UUID,
  pharmacy_name TEXT,
  city TEXT,
  region TEXT,
  orders BIGINT,
  revenue_ghs NUMERIC,
  avg_order_value_ghs NUMERIC,
  outstanding_ghs NUMERIC,
  first_order_at TIMESTAMPTZ,
  last_order_at TIMESTAMPTZ,
  has_discount BOOLEAN,
  segments TEXT[],
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  v_search TEXT := NULLIF(BTRIM(COALESCE(p_search, '')), '');
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler' AND b.owner_id = auth.uid())
    OR (public.is_business_staff(auth.uid(), p_business_id)
        AND EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler'))
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s customers.';
  END IF;
  IF p_segment IS NOT NULL AND p_segment NOT IN ('new', 'active', 'high_value', 'dormant', 'discount') THEN
    RAISE EXCEPTION 'Unknown customer segment.';
  END IF;

  RETURN QUERY
  WITH agg AS (
    SELECT
      o.pharmacy_id AS pid,
      COUNT(*) AS n_orders,
      COALESCE(SUM(o.total_ghs), 0) AS revenue,
      COALESCE(SUM(o.total_ghs) FILTER (WHERE o.payment_status IN ('unpaid', 'failed')), 0) AS outstanding,
      MIN(o.created_at) AS first_at,
      MAX(o.created_at) AS last_at
    FROM public.orders o
    WHERE o.wholesaler_id = p_business_id AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
    GROUP BY o.pharmacy_id
  ),
  disc AS (
    SELECT DISTINCT d.pharmacy_id AS pid
    FROM public.customer_discounts d
    WHERE d.wholesaler_id = p_business_id AND d.active AND d.starts_at <= now()
      AND (d.ends_at IS NULL OR d.ends_at > now())
  ),
  ids AS (SELECT pid FROM agg UNION SELECT pid FROM disc),
  base AS (
    SELECT
      i.pid,
      COALESCE(a.n_orders, 0) AS n_orders,
      COALESCE(a.revenue, 0) AS revenue,
      COALESCE(a.outstanding, 0) AS outstanding,
      a.first_at, a.last_at,
      (d.pid IS NOT NULL) AS has_disc,
      CASE WHEN COALESCE(a.revenue, 0) > 0
        THEN percent_rank() OVER (ORDER BY COALESCE(a.revenue, 0)) END AS rev_rank
    FROM ids i
    LEFT JOIN agg a ON a.pid = i.pid
    LEFT JOIN disc d ON d.pid = i.pid
  ),
  seg AS (
    SELECT
      b.*,
      array_remove(ARRAY[
        CASE WHEN b.first_at >= now() - interval '30 days' THEN 'new' END,
        CASE WHEN b.last_at >= now() - interval '60 days' THEN 'active' END,
        CASE WHEN b.last_at < now() - interval '60 days' THEN 'dormant' END,
        CASE WHEN b.rev_rank >= 0.8 THEN 'high_value' END,
        CASE WHEN b.has_disc THEN 'discount' END
      ], NULL) AS segs
    FROM base b
  ),
  filtered AS (
    SELECT s.*, p.name AS pname, p.city AS pcity, p.region AS pregion
    FROM seg s
    JOIN public.businesses p ON p.id = s.pid
    WHERE (p_segment IS NULL OR p_segment = ANY (s.segs))
      AND (v_search IS NULL OR p.name ILIKE '%' || replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_') || '%')
  )
  SELECT
    f.pid, f.pname, f.pcity, f.pregion,
    f.n_orders, f.revenue,
    CASE WHEN f.n_orders > 0 THEN round(f.revenue / f.n_orders, 2) ELSE 0 END,
    f.outstanding, f.first_at, f.last_at, f.has_disc, f.segs,
    COUNT(*) OVER ()
  FROM filtered f
  ORDER BY f.revenue DESC, f.pname
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- ---------------------------------------------------------------------------
-- One customer: totals, top products, recent orders, current discount
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wholesaler_customer_detail(
  p_business_id UUID,
  p_pharmacy_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_pharmacy RECORD;
  v_result JSONB;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler' AND b.owner_id = auth.uid())
    OR (public.is_business_staff(auth.uid(), p_business_id)
        AND EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler'))
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s customers.';
  END IF;

  SELECT p.id, p.name, p.city, p.region, p.public_email INTO v_pharmacy
  FROM public.businesses p WHERE p.id = p_pharmacy_id AND p.type = 'pharmacy';
  IF NOT FOUND THEN RAISE EXCEPTION 'Customer not found.'; END IF;

  SELECT jsonb_build_object(
    'pharmacy', jsonb_build_object('id', v_pharmacy.id, 'name', v_pharmacy.name, 'city', v_pharmacy.city,
      'region', v_pharmacy.region, 'email', v_pharmacy.public_email),
    'top_products', COALESCE((
      SELECT jsonb_agg(t ORDER BY t.units DESC) FROM (
        SELECT oi.product_name, SUM(oi.quantity)::BIGINT AS units, COUNT(DISTINCT o.id) AS orders,
          SUM(oi.quantity * oi.unit_price_ghs) AS spend_ghs
        FROM public.orders o JOIN public.order_items oi ON oi.order_id = o.id
        WHERE o.wholesaler_id = p_business_id AND o.pharmacy_id = p_pharmacy_id
          AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
        GROUP BY oi.product_name ORDER BY SUM(oi.quantity) DESC LIMIT 10
      ) t), '[]'::jsonb),
    'recent_orders', COALESCE((
      SELECT jsonb_agg(r ORDER BY r.created_at DESC) FROM (
        SELECT o.id, o.order_number, o.status, o.payment_status, o.total_ghs, o.created_at
        FROM public.orders o WHERE o.wholesaler_id = p_business_id AND o.pharmacy_id = p_pharmacy_id
        ORDER BY o.created_at DESC, o.id DESC LIMIT 10
      ) r), '[]'::jsonb),
    'discount', (
      SELECT jsonb_build_object('discount_type', d.discount_type, 'discount_percent', d.discount_percent,
        'discount_amount', d.discount_amount, 'minimum_order_value', d.minimum_order_value, 'ends_at', d.ends_at)
      FROM public.customer_discounts d
      WHERE d.wholesaler_id = p_business_id AND d.pharmacy_id = p_pharmacy_id AND d.active
        AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now())
      LIMIT 1)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Statement of account between one wholesaler and one pharmacy
-- p_from inclusive, p_to exclusive. Visible to both sides, identical for both.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.customer_statement(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  c_line_cap CONSTANT INTEGER := 2000;
  v_wholesaler RECORD;
  v_pharmacy RECORD;
  v_opening NUMERIC;
  v_debits NUMERIC;
  v_credits NUMERIC;
  v_lines JSONB;
  v_line_count BIGINT;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
    RAISE EXCEPTION 'Choose a valid date range for the statement.';
  END IF;

  SELECT id, name, city, region, owner_id INTO v_wholesaler FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  SELECT id, name, city, region, owner_id INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_wholesaler.id IS NULL OR v_pharmacy.id IS NULL THEN RAISE EXCEPTION 'Statement not found.'; END IF;

  IF NOT (
    v_wholesaler.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_wholesaler_id)
    OR v_pharmacy.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_pharmacy_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this statement.';
  END IF;

  WITH ledger AS (
    SELECT o.created_at AS at, 'order'::TEXT AS kind, o.id AS order_id, o.order_number,
      o.total_ghs AS amount, o.discount_amount_ghs AS discount
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
    UNION ALL
    SELECT COALESCE(o.paid_at, o.payment_confirmed_at, o.created_at), 'payment', o.id, o.order_number,
      o.total_ghs, 0::NUMERIC
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status = 'paid'
  ),
  opening AS (
    SELECT COALESCE(SUM(CASE WHEN kind = 'order' THEN amount ELSE -amount END), 0) AS v
    FROM ledger WHERE at < p_from
  ),
  in_range AS (SELECT * FROM ledger WHERE at >= p_from AND at < p_to),
  totals AS (
    SELECT COALESCE(SUM(amount) FILTER (WHERE kind = 'order'), 0) AS debits,
      COALESCE(SUM(amount) FILTER (WHERE kind = 'payment'), 0) AS credits,
      COUNT(*) AS n
    FROM in_range
  ),
  running AS (
    SELECT r.*, (SELECT v FROM opening) + SUM(CASE WHEN r.kind = 'order' THEN r.amount ELSE -r.amount END)
      OVER (ORDER BY r.at, r.kind, r.order_number ROWS UNBOUNDED PRECEDING) AS balance
    FROM in_range r
    ORDER BY r.at, r.kind, r.order_number
    LIMIT c_line_cap
  )
  SELECT
    (SELECT v FROM opening), (SELECT debits FROM totals), (SELECT credits FROM totals), (SELECT n FROM totals),
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'date', x.at, 'kind', x.kind, 'order_id', x.order_id, 'order_number', x.order_number,
      'debit', CASE WHEN x.kind = 'order' THEN x.amount ELSE 0 END,
      'credit', CASE WHEN x.kind = 'payment' THEN x.amount ELSE 0 END,
      'discount', x.discount, 'balance', x.balance) ORDER BY x.at, x.kind, x.order_number) FROM running x), '[]'::jsonb)
  INTO v_opening, v_debits, v_credits, v_line_count, v_lines;

  RETURN jsonb_build_object(
    'wholesaler', jsonb_build_object('id', v_wholesaler.id, 'name', v_wholesaler.name, 'city', v_wholesaler.city, 'region', v_wholesaler.region),
    'pharmacy', jsonb_build_object('id', v_pharmacy.id, 'name', v_pharmacy.name, 'city', v_pharmacy.city, 'region', v_pharmacy.region),
    'from', p_from, 'to', p_to,
    'opening_balance', v_opening,
    'total_debits', v_debits,
    'total_credits', v_credits,
    'closing_balance', v_opening + v_debits - v_credits,
    'line_count', v_line_count,
    'truncated', v_line_count > c_line_cap,
    'lines', v_lines
  );
END;
$$;

REVOKE ALL ON FUNCTION public.wholesaler_customers(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.wholesaler_customer_detail(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wholesaler_customers(UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.wholesaler_customer_detail(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
