-- Pharmacy orders audit remediation. Apply before deploying the matching client.
-- Additive, scoped readers; existing clients retain their old RPC. No business records changed.
BEGIN;
ALTER FUNCTION public.resolve_report_range(TEXT,TIMESTAMPTZ,TIMESTAMPTZ) STABLE;
ALTER FUNCTION public.resolve_report_range(TEXT,TIMESTAMPTZ,TIMESTAMPTZ) SET timezone TO 'Africa/Accra';
CREATE OR REPLACE FUNCTION public.list_pharmacy_orders_scoped(
  p_pharmacy_id UUID,
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
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type = 'pharmacy' AND (b.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), b.id))) THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy.';
  END IF;
  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN (
    WITH workspace AS (SELECT * FROM public.orders WHERE pharmacy_id = p_pharmacy_id), scoped AS (
      SELECT o.id, o.order_number, o.status, o.total_ghs, o.effective_total_ghs, o.created_at, o.pharmacy_id, o.settlement_method, o.is_credit_order, o.delivered_at,
        (o.status = 'delivered' AND now() <= COALESCE(o.delivered_at,o.updated_at) + interval '30 days') AS return_eligible,
        COALESCE(o.delivered_at,o.updated_at) + interval '30 days' AS return_deadline,
        o.payment_method, o.payment_status, o.purchase_category, o.wholesaler_id, w.name AS wholesaler_name,
        o.procurement_id, pr.reference AS procurement_reference,
        (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS item_count,
        (SELECT coalesce(sum(public.order_item_fulfilled_qty(oi.id)), 0) FROM public.order_items oi WHERE oi.order_id = o.id) AS unit_count
      FROM workspace o
      JOIN public.businesses w ON w.id = o.wholesaler_id
      LEFT JOIN public.procurements pr ON pr.id = o.procurement_id
      WHERE EXISTS (
        SELECT 1 FROM public.businesses pb
        WHERE pb.id = o.pharmacy_id AND pb.type = 'pharmacy'
          AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), pb.id))
      )
      AND (
        NULLIF(btrim(p_status), '') IS NULL
        OR (p_status = 'active' AND o.status::TEXT NOT IN ('delivered', 'cancelled'))
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
        CASE WHEN p_sort = 'highest' THEN COALESCE(effective_total_ghs,total_ghs) END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN COALESCE(effective_total_ghs,total_ghs) END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id
      OFFSET GREATEST(p_page - 1, 0) * LEAST(GREATEST(p_page_size, 1), 100)
      LIMIT LEAST(GREATEST(p_page_size, 1), 100)
    )
    SELECT jsonb_build_object(
      'total_count', (SELECT count(*) FROM scoped),
      'workspace_total', (SELECT count(*) FROM workspace),
      'counts', (SELECT jsonb_build_object('active', count(*) FILTER (WHERE status::text NOT IN ('delivered','cancelled')), 'awaiting',count(*) FILTER (WHERE payment_status::text = 'unpaid' AND status::text <> 'cancelled'), 'transit',count(*) FILTER (WHERE status::text = 'dispatched'), 'delivered',count(*) FILTER (WHERE status::text = 'delivered')) FROM workspace),
      'suppliers', (SELECT COALESCE(jsonb_agg(x ORDER BY x.name), '[]'::jsonb) FROM (SELECT DISTINCT b.id,b.name FROM workspace o JOIN public.businesses b ON b.id=o.wholesaler_id) x),
      'page', GREATEST(p_page, 1),
      'page_size', LEAST(GREATEST(p_page_size, 1), 100),
      'orders', COALESCE(jsonb_agg(to_jsonb(counted) - 'total_count' ORDER BY
        CASE WHEN p_sort = 'highest' THEN COALESCE(effective_total_ghs,total_ghs) END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN COALESCE(effective_total_ghs,total_ghs) END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id), '[]'::JSONB)
    ) FROM counted
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_pharmacy_order_scoped(p_pharmacy_id UUID,p_order_id UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY INVOKER SET search_path=public AS $$
SELECT jsonb_build_object('order',
 (public.get_pharmacy_order_detail(o.id)->'order') || jsonb_build_object('items',
  (SELECT COALESCE(jsonb_agg(to_jsonb(oi) || jsonb_build_object('catalog_details',
     nullif(concat_ws(' / ',mp.strength,mp.dosage_form,mp.pack_size),'')) ORDER BY oi.id),'[]'::jsonb)
   FROM public.order_items oi LEFT JOIN public.wholesaler_products wp ON wp.id=oi.product_id
   LEFT JOIN public.master_products mp ON mp.id=wp.product_id WHERE oi.order_id=o.id)),
 'pharmacy', jsonb_build_object('id',b.id,'name',b.name,'city',b.city,'region',b.region,
  'address',b.address,'phone',b.phone,'license_number',b.license_number,'public_email',b.public_email))
FROM public.orders o JOIN public.businesses b ON b.id=o.pharmacy_id
WHERE o.id=p_order_id AND o.pharmacy_id=p_pharmacy_id AND b.type='pharmacy'
 AND (b.owner_id=auth.uid() OR public.is_business_staff(auth.uid(),b.id));
$$;
REVOKE ALL ON FUNCTION public.list_pharmacy_orders_scoped(UUID,INTEGER,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_pharmacy_orders_scoped(UUID,INTEGER,INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,UUID,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.get_pharmacy_order_scoped(UUID,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pharmacy_order_scoped(UUID,UUID) TO authenticated;
COMMIT;
