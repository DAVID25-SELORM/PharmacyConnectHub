-- Pharmacy price history: what a pharmacy has paid for the same product over time, and who charged less.
--
-- This sits beside pharmacy_report_products (units, spend, suppliers, a simple average). It adds what
-- that report cannot say: whether the price moved, by how much, and whether another supplier was cheaper.
--
-- Rules (stated once, here):
--   * "Price paid" is order_items.unit_price_ghs, the unit price after any discount applied at checkout.
--     The detail also shows the list price (base_unit_price_ghs) so a discount is visible.
--   * Cancelled orders are excluded: a cancelled order is not a price anyone paid. (pharmacy_report_products
--     counts every order; that report is about what was ordered, this one is about prices.)
--   * "The same product" is matched across suppliers on name + brand + form + pack size, compared
--     case-insensitively and ignoring surrounding spaces (the same identity a supplier's own catalogue uses
--     to avoid duplicates). Products that do not match are simply not compared, never wrongly compared.
--   * "Change" compares the latest purchase in the range with the previous purchase of the same product
--     from the SAME supplier, looking back before the range if needed. Switching supplier is not a price
--     change. No earlier purchase from that supplier means no change is shown.
--   * "Cheaper elsewhere" compares the latest price paid to each supplier in the range, and is shown only
--     when another supplier's latest price is lower than the latest price paid. These are prices the
--     pharmacy actually paid, not a live catalogue price.
--   * Averages are weighted by quantity (total spend / total units).
--   * Choosing a single supplier narrows every figure to that supplier, so nothing is compared.
--
-- Access: the pharmacy's owner or active staff, like the other pharmacy reports. Everything is scoped to
-- p_business_id; no other business's orders are read.

CREATE FUNCTION public.pharmacy_price_history(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 100,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  sample_product_id UUID,
  product_name TEXT,
  brand TEXT,
  form TEXT,
  pack_size TEXT,
  purchases BIGINT,
  units BIGINT,
  spend_ghs NUMERIC,
  avg_paid_ghs NUMERIC,
  min_paid_ghs NUMERIC,
  max_paid_ghs NUMERIC,
  suppliers BIGINT,
  latest_paid_ghs NUMERIC,
  latest_at TIMESTAMPTZ,
  latest_supplier_id UUID,
  latest_supplier_name TEXT,
  previous_paid_ghs NUMERIC,
  change_pct NUMERIC,
  cheaper_paid_ghs NUMERIC,
  cheaper_supplier_name TEXT,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_search TEXT := NULLIF(lower(btrim(COALESCE(p_search, ''))), '');
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type::TEXT = 'pharmacy' AND b.owner_id = auth.uid())
    OR (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type::TEXT = 'pharmacy')
        AND public.is_business_staff(auth.uid(), p_business_id))
  ) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s reports.';
  END IF;
  IF p_purchase_category IS NOT NULL AND p_purchase_category NOT IN ('nhis', 'cash_private', 'other', 'unclassified') THEN
    RAISE EXCEPTION 'Invalid purchase category filter.';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN RAISE EXCEPTION 'The page size must be between 1 and 500.'; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset.'; END IF;
  SELECT r.range_from, r.range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to) r;

  RETURN QUERY
  WITH hist AS (
    -- Every non-cancelled purchase up to the end of the range. Purchases before the range are kept so the
    -- latest purchase can be compared with the one before it.
    SELECT oi.id AS item_id, oi.product_id AS pid, o.created_at AS at, o.wholesaler_id AS sid, w.name AS sname,
      oi.quantity AS qty, oi.unit_price_ghs AS paid, oi.product_name AS pname,
      p.brand AS pbrand, p.form AS pform, p.pack_size AS ppack,
      lower(btrim(p.name)) || '|' || COALESCE(lower(btrim(p.brand)), '') || '|' || COALESCE(lower(btrim(p.form)), '')
        || '|' || COALESCE(lower(btrim(p.pack_size)), '') AS pkey
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    JOIN public.products p ON p.id = oi.product_id
    JOIN public.businesses w ON w.id = o.wholesaler_id
    WHERE o.pharmacy_id = p_business_id
      AND o.status::TEXT <> 'cancelled'
      AND o.created_at < v_to
      AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
      AND (
        p_purchase_category IS NULL
        OR (p_purchase_category = 'unclassified' AND oi.purchase_category IS NULL)
        OR oi.purchase_category = p_purchase_category
      )
  ), ranked AS (
    SELECT h.*,
      lag(h.paid) OVER (PARTITION BY h.pkey, h.sid ORDER BY h.at, h.item_id) AS prev_paid
    FROM hist h
  ), inr AS (
    SELECT r.*, row_number() OVER (PARTITION BY r.pkey ORDER BY r.at DESC, r.item_id DESC) AS rn
    FROM ranked r
    WHERE r.at >= v_from
  ), agg AS (
    SELECT i.pkey, count(*) AS n, sum(i.qty) AS u, sum(round(i.paid * i.qty, 2)) AS spend,
      min(i.paid) AS lo, max(i.paid) AS hi, count(DISTINCT i.sid) AS sup
    FROM inr i GROUP BY i.pkey
  ), per_supplier AS (
    SELECT DISTINCT ON (i.pkey, i.sid) i.pkey, i.sid, i.sname, i.paid
    FROM inr i ORDER BY i.pkey, i.sid, i.at DESC, i.item_id DESC
  ), best AS (
    SELECT DISTINCT ON (s.pkey) s.pkey, s.sname, s.paid
    FROM per_supplier s ORDER BY s.pkey, s.paid ASC, s.sname
  )
  SELECT l.pid, l.pname, l.pbrand, l.pform, l.ppack,
    a.n, a.u::BIGINT, a.spend::NUMERIC, round(a.spend / NULLIF(a.u, 0), 2), a.lo, a.hi, a.sup,
    l.paid, l.at, l.sid, l.sname,
    l.prev_paid,
    CASE WHEN l.prev_paid > 0 THEN round((l.paid - l.prev_paid) / l.prev_paid * 100, 1) END,
    CASE WHEN a.sup > 1 AND b.paid < l.paid THEN b.paid END,
    CASE WHEN a.sup > 1 AND b.paid < l.paid THEN b.sname END,
    count(*) OVER ()
  FROM inr l
  JOIN agg a ON a.pkey = l.pkey
  JOIN best b ON b.pkey = l.pkey
  WHERE l.rn = 1
    AND (v_search IS NULL OR position(v_search IN lower(l.pname)) > 0 OR position(v_search IN lower(COALESCE(l.pbrand, ''))) > 0)
  ORDER BY a.spend DESC, l.pname, l.pid
  LIMIT p_limit OFFSET p_offset;
END;
$$;
REVOKE ALL ON FUNCTION public.pharmacy_price_history(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pharmacy_price_history(UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

-- ---------------------------------------------------------------------------
-- The purchases behind one row of the summary, newest first, with the change from the previous
-- purchase from the same supplier. p_product_id is the sample_product_id from the summary; the same
-- identity match applies, so purchases of that product from every supplier are returned.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.pharmacy_price_history_detail(
  p_business_id UUID,
  p_product_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 200
)
RETURNS TABLE (
  purchased_at TIMESTAMPTZ,
  order_id UUID,
  order_number TEXT,
  supplier_id UUID,
  supplier_name TEXT,
  quantity INTEGER,
  list_price_ghs NUMERIC,
  paid_ghs NUMERIC,
  purchase_category TEXT,
  order_status TEXT,
  previous_paid_ghs NUMERIC,
  change_pct NUMERIC,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_key TEXT;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type::TEXT = 'pharmacy' AND b.owner_id = auth.uid())
    OR (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type::TEXT = 'pharmacy')
        AND public.is_business_staff(auth.uid(), p_business_id))
  ) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s reports.';
  END IF;
  IF p_purchase_category IS NOT NULL AND p_purchase_category NOT IN ('nhis', 'cash_private', 'other', 'unclassified') THEN
    RAISE EXCEPTION 'Invalid purchase category filter.';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN RAISE EXCEPTION 'The page size must be between 1 and 500.'; END IF;
  SELECT r.range_from, r.range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to) r;
  SELECT lower(btrim(p.name)) || '|' || COALESCE(lower(btrim(p.brand)), '') || '|' || COALESCE(lower(btrim(p.form)), '')
      || '|' || COALESCE(lower(btrim(p.pack_size)), '')
    INTO v_key FROM public.products p WHERE p.id = p_product_id;
  IF v_key IS NULL THEN RAISE EXCEPTION 'Product not found.'; END IF;

  RETURN QUERY
  WITH hist AS (
    SELECT oi.id AS item_id, o.id AS oid, o.order_number AS onum, o.created_at AS at, o.status::TEXT AS ost,
      o.wholesaler_id AS sid, w.name AS sname, oi.quantity AS qty,
      COALESCE(oi.base_unit_price_ghs, oi.unit_price_ghs) AS listp, oi.unit_price_ghs AS paid, oi.purchase_category AS cat
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    JOIN public.products p ON p.id = oi.product_id
    JOIN public.businesses w ON w.id = o.wholesaler_id
    WHERE o.pharmacy_id = p_business_id
      AND o.status::TEXT <> 'cancelled'
      AND o.created_at < v_to
      AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
      AND (
        p_purchase_category IS NULL
        OR (p_purchase_category = 'unclassified' AND oi.purchase_category IS NULL)
        OR oi.purchase_category = p_purchase_category
      )
      AND lower(btrim(p.name)) || '|' || COALESCE(lower(btrim(p.brand)), '') || '|' || COALESCE(lower(btrim(p.form)), '')
        || '|' || COALESCE(lower(btrim(p.pack_size)), '') = v_key
  ), ranked AS (
    SELECT h.*, lag(h.paid) OVER (PARTITION BY h.sid ORDER BY h.at, h.item_id) AS prev_paid FROM hist h
  )
  SELECT r.at, r.oid, r.onum, r.sid, r.sname, r.qty, r.listp, r.paid, r.cat, r.ost, r.prev_paid,
    CASE WHEN r.prev_paid > 0 THEN round((r.paid - r.prev_paid) / r.prev_paid * 100, 1) END,
    count(*) OVER ()
  FROM ranked r
  WHERE r.at >= v_from
  ORDER BY r.at DESC, r.item_id DESC
  LIMIT p_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.pharmacy_price_history_detail(UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pharmacy_price_history_detail(UUID, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, UUID, TEXT, INTEGER) TO authenticated;
