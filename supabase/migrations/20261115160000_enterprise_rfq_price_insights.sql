BEGIN;
CREATE FUNCTION public.rfq_price_insights(p_pharmacy_id UUID,p_query TEXT DEFAULT '',p_offset INTEGER DEFAULT 0) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.rfq_member(p_pharmacy_id) THEN RAISE EXCEPTION 'Approved pharmacy membership required.'; END IF;
 WITH medicines AS(SELECT i.master_product_id,max(i.product_name) medicine,count(*) requests,sum(i.quantity) requested
 FROM public.rfq_items i JOIN public.rfqs r ON r.id=i.rfq_id WHERE r.pharmacy_id=p_pharmacy_id AND r.status<>'draft' AND i.master_product_id IS NOT NULL AND i.product_name ILIKE '%'||COALESCE(p_query,'')||'%'
 GROUP BY i.master_product_id ORDER BY count(*) DESC,i.master_product_id LIMIT 25 OFFSET GREATEST(p_offset,0)),
 report AS(SELECT m.*,historical.price historical_unit_price,historical.date historical_purchase_date,historical.supplier historical_supplier,
 latest.price awarded_unit_price,latest.quantity awarded_quantity,latest.reference award_reference,
 CASE WHEN historical.price IS NOT NULL AND latest.price IS NOT NULL THEN round((historical.price-latest.price)*latest.quantity,2) END historical_price_difference_ghs,
 'Previous delivered purchase of the same canonical product; unit-price comparison excludes delivery and is not realized savings.' baseline
 FROM medicines m LEFT JOIN LATERAL(SELECT a.unit_price_ghs price,a.quantity,r.reference,g.created_at
 FROM public.rfq_allocations a JOIN public.rfq_confirmation_groups g ON g.id=a.group_id JOIN public.rfqs r ON r.id=g.rfq_id JOIN public.wholesaler_products wp ON wp.id=a.product_id
 WHERE r.pharmacy_id=p_pharmacy_id AND wp.product_id=m.master_product_id AND g.status='confirmed' ORDER BY g.created_at DESC,g.id DESC LIMIT 1) latest ON true
 LEFT JOIN LATERAL(SELECT public.order_item_effective_price(oi.id) price,o.created_at::date date,b.name supplier
 FROM public.order_items oi JOIN public.orders o ON o.id=oi.order_id JOIN public.wholesaler_products wp ON wp.id=oi.product_id JOIN public.businesses b ON b.id=o.wholesaler_id
 WHERE o.pharmacy_id=p_pharmacy_id AND o.status::text='delivered' AND wp.product_id=m.master_product_id AND o.created_at<COALESCE(latest.created_at,now())
 ORDER BY o.created_at DESC,oi.id DESC LIMIT 1) historical ON true)
 SELECT COALESCE(jsonb_agg(report),'[]') INTO result FROM report; RETURN result;
END $$;
CREATE FUNCTION public.rfq_credit_comparison(p_rfq_id UUID) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE pharmacy UUID; result JSONB; BEGIN
 SELECT pharmacy_id INTO pharmacy FROM public.rfqs WHERE id=p_rfq_id;
 IF pharmacy IS NULL OR NOT public.rfq_member(pharmacy) OR NOT public.can_view_accounting(pharmacy) THEN RAISE EXCEPTION 'Buyer accounting permission required.'; END IF;
 SELECT COALESCE(jsonb_agg(x),'[]') INTO result FROM(SELECT i.wholesaler_id,c.payment_terms_days,
 CASE WHEN c.active AND c.status='active' THEN GREATEST(c.credit_limit_ghs-public.credit_exposure(i.wholesaler_id,pharmacy),0) ELSE 0 END available_ghs,
 CASE WHEN c.wholesaler_id IS NULL THEN 'not_approved' WHEN NOT c.active THEN 'inactive' ELSE c.status END status
 FROM public.rfq_invitees i LEFT JOIN public.wholesaler_credit_terms c ON c.wholesaler_id=i.wholesaler_id AND c.pharmacy_id=pharmacy WHERE i.rfq_id=p_rfq_id) x;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.rfq_price_insights(UUID,TEXT,INTEGER),public.rfq_credit_comparison(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfq_price_insights(UUID,TEXT,INTEGER),public.rfq_credit_comparison(UUID) TO authenticated;
COMMIT;
