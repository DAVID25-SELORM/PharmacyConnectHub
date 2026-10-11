-- Internal rollup avoids multiplying money by the number of batches/documents.
CREATE VIEW public.external_purchase_balances AS
 SELECT p.*, COALESCE(pay.paid,0) AS paid_ghs, COALESCE(ret.credit,0) AS credit_ghs,
 p.total_ghs-COALESCE(pay.paid,0)-COALESCE(ret.credit,0) AS outstanding_ghs,
 CASE WHEN p.total_ghs-COALESCE(pay.paid,0)-COALESCE(ret.credit,0)<=0 THEN 'paid'
 WHEN COALESCE(pay.paid,0)>0 THEN 'part_paid' ELSE 'credit' END AS payment_status
 FROM public.external_purchases p
 LEFT JOIN LATERAL(SELECT sum(amount_ghs) paid FROM public.external_purchase_payments WHERE purchase_id=p.id) pay ON true
 LEFT JOIN LATERAL(SELECT sum(r.credit_ghs) credit FROM public.external_purchase_returns r
 JOIN public.external_purchase_batches b ON b.id=r.batch_id JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id) ret ON true;
REVOKE ALL ON public.external_purchase_balances FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.list_external_purchases(p_pharmacy_id UUID,p_filters JSONB DEFAULT '{}',p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 30)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_result JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized for this pharmacy.'; END IF;
 WITH filtered AS (
 SELECT p.*, (SELECT count(*) FROM public.external_purchase_documents d WHERE d.purchase_id=p.id AND d.removed_at IS NULL) document_count,
 (SELECT count(*) FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id AND b.disposition='quarantine' AND b.remaining>0) quarantine_batches
 FROM public.external_purchase_balances p WHERE p.pharmacy_id=p_pharmacy_id
 AND (NULLIF(p_filters->>'from','') IS NULL OR p.purchase_date>=(p_filters->>'from')::date)
 AND (NULLIF(p_filters->>'to','') IS NULL OR p.purchase_date<=(p_filters->>'to')::date)
 AND (NULLIF(p_filters->>'channel','') IS NULL OR p.channel=p_filters->>'channel')
 AND (NULLIF(p_filters->>'verification','') IS NULL OR p.verification_status=p_filters->>'verification')
 AND (NULLIF(p_filters->>'review','') IS NULL OR p.review_status=p_filters->>'review')
 AND (NULLIF(p_filters->>'payment','') IS NULL OR p.payment_status=p_filters->>'payment')
 AND (NULLIF(p_filters->>'supplier','') IS NULL OR p.seller_contact_id::text=p_filters->>'supplier' OR p.seller_company_id::text=p_filters->>'supplier')
 AND (NULLIF(p_filters->>'source','') IS NULL OR p.source_snapshot->>'name' ILIKE '%'||(p_filters->>'source')||'%')
 AND (NULLIF(p_filters->>'q','') IS NULL OR concat_ws(' ',p.reference,p.invoice_number,p.receipt_number,p.seller_snapshot->>'name',p.seller_snapshot->>'phone',p.source_snapshot->>'name',p.purchase_date::text) ILIKE '%'||(p_filters->>'q')||'%'
 OR EXISTS(SELECT 1 FROM public.external_purchase_items i LEFT JOIN public.external_purchase_batches b ON b.item_id=i.id WHERE i.purchase_id=p.id AND concat_ws(' ',i.product_snapshot->>'name',i.product_snapshot->>'manufacturer',b.batch_number) ILIKE '%'||(p_filters->>'q')||'%'))
 ), page AS(SELECT * FROM filtered ORDER BY purchase_date DESC,id DESC LIMIT LEAST(GREATEST(p_limit,1),200) OFFSET GREATEST(p_offset,0))
 SELECT jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(to_jsonb(page) ORDER BY purchase_date DESC,id DESC) FROM page),'[]'),
 'summary',(SELECT jsonb_build_object('count',count(*),'spend',COALESCE(sum(total_ghs),0),'outstanding',COALESCE(sum(GREATEST(outstanding_ghs,0)),0),
 'verified',count(*) FILTER(WHERE verification_status='verified'),'partially_verified',count(*) FILTER(WHERE verification_status='partially_verified'),
 'unverified',count(*) FILTER(WHERE verification_status='unverified'),'awaiting_review',count(*) FILTER(WHERE review_status='awaiting_review'),
 'quarantined',COALESCE(sum(quarantine_batches),0),'missing_documents',count(*) FILTER(WHERE document_count=0)) FROM filtered)) INTO v_result;
 RETURN v_result;
END $$;

CREATE FUNCTION public.get_external_purchase(p_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.external_purchase_balances%ROWTYPE; BEGIN
 SELECT * INTO p FROM public.external_purchase_balances WHERE id=p_id;
 IF NOT FOUND OR NOT public.can_access_external_procurement(p.pharmacy_id) THEN RAISE EXCEPTION 'Purchase not found or not authorized.'; END IF;
 RETURN to_jsonb(p)||jsonb_build_object(
 'received_name',(SELECT full_name FROM public.profiles WHERE id=p.received_by),
 'reviewed_name',(SELECT full_name FROM public.profiles WHERE id=p.reviewed_by),
 'items',COALESCE((SELECT jsonb_agg(to_jsonb(i)||jsonb_build_object('batches',(SELECT jsonb_agg(b ORDER BY b.id) FROM public.external_purchase_batches b WHERE b.item_id=i.id)) ORDER BY i.id) FROM public.external_purchase_items i WHERE i.purchase_id=p.id),'[]'),
 'documents',COALESCE((SELECT jsonb_agg(d ORDER BY d.uploaded_at) FROM public.external_purchase_documents d WHERE d.purchase_id=p.id AND d.removed_at IS NULL),'[]'),
 'events',COALESCE((SELECT jsonb_agg(e ORDER BY e.occurred_at,e.id) FROM public.external_purchase_events e WHERE e.purchase_id=p.id),'[]'),
 'payments',CASE WHEN public.can_view_accounting(p.pharmacy_id) THEN COALESCE((SELECT jsonb_agg(x ORDER BY x.created_at) FROM public.external_purchase_payments x WHERE x.purchase_id=p.id),'[]') ELSE '[]'::jsonb END,
 'returns',COALESCE((SELECT jsonb_agg(r ORDER BY r.created_at) FROM public.external_purchase_returns r JOIN public.external_purchase_batches b ON b.id=r.batch_id JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id),'[]'),
 'signals',jsonb_build_object(
 'missing_source',p.source_type='unknown',
 'missing_invoice',NOT EXISTS(SELECT 1 FROM public.external_purchase_documents WHERE purchase_id=p.id AND removed_at IS NULL AND document_type IN ('supplier_invoice','product_invoice','purchase_receipt')),
 'incomplete_batches',EXISTS(SELECT 1 FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id AND (b.batch_number IS NULL OR b.expiry_date IS NULL)),
 'expired_batches',EXISTS(SELECT 1 FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id AND b.expiry_date<=current_date AND b.remaining>0),
 'previous_unknown',(SELECT count(*) FROM public.external_purchases x WHERE x.pharmacy_id=p.pharmacy_id AND x.id<>p.id AND x.purchase_date<=p.purchase_date AND x.source_type='unknown' AND (x.seller_contact_id=p.seller_contact_id OR x.seller_company_id=p.seller_company_id)),
 'changed_source',EXISTS(SELECT 1 FROM public.external_purchases x WHERE x.pharmacy_id=p.pharmacy_id AND x.id<>p.id AND x.purchase_date<=p.purchase_date AND x.seller_contact_id=p.seller_contact_id AND x.source_snapshot->>'name' IS DISTINCT FROM p.source_snapshot->>'name'),
 'possible_duplicate',EXISTS(SELECT 1 FROM public.external_purchases x WHERE x.pharmacy_id=p.pharmacy_id AND x.id<>p.id AND x.invoice_number=p.invoice_number AND p.invoice_number IS NOT NULL AND x.purchase_date=p.purchase_date AND x.total_ghs=p.total_ghs AND x.seller_snapshot->>'name' IS NOT DISTINCT FROM p.seller_snapshot->>'name')));
END $$;

-- One row per purchase item, not per batch. Includes pending/quarantined external receipts
-- with explicit status; excludes external drafts/rejected and cancelled marketplace orders.
CREATE FUNCTION public.external_procurement_analytics(p_pharmacy_id UUID,p_from DATE DEFAULT NULL,p_to DATE DEFAULT NULL,p_query TEXT DEFAULT '',p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 100)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$ DECLARE v JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 WITH lines AS (
 SELECT p.id purchase_id,p.reference,p.purchase_date date,p.channel,p.seller_snapshot->>'name' seller,p.source_snapshot->>'name' source,
 i.product_snapshot->>'name' product,i.product_snapshot->>'manufacturer' manufacturer,i.quantity,
 COALESCE((SELECT sum(r.quantity) FROM public.external_purchase_returns r JOIN public.external_purchase_batches b ON b.id=r.batch_id WHERE b.item_id=i.id),0)::integer returned,
 i.unit_cost_ghs unit_cost,p.verification_status verification,p.review_status review,p.invoice_number invoice,
 (SELECT string_agg(COALESCE(b.batch_number,'Unknown'),' / ' ORDER BY b.id) FROM public.external_purchase_batches b WHERE b.item_id=i.id) batches,
 i.id line_id,i.master_product_id
 FROM public.external_purchases p JOIN public.external_purchase_items i ON i.purchase_id=p.id
 WHERE p.pharmacy_id=p_pharmacy_id AND p.review_status NOT IN ('draft','rejected')
 UNION ALL
 SELECT o.id,o.order_number,o.created_at::date,'marketplace',w.name,w.name,oi.product_name,NULL,
 public.order_item_fulfilled_qty(oi.id),COALESCE((SELECT sum(ri.quantity_accepted) FROM public.order_return_items ri JOIN public.order_returns ret ON ret.id=ri.return_id WHERE ri.order_item_id=oi.id AND ret.status='resolved'),0)::integer,
 public.order_item_effective_price(oi.id),'marketplace',o.status::text,o.order_number,NULL,oi.id,wp.product_id
 FROM public.orders o JOIN public.order_items oi ON oi.order_id=o.id JOIN public.businesses w ON w.id=o.wholesaler_id
 LEFT JOIN public.wholesaler_products wp ON wp.id=oi.product_id
 WHERE o.pharmacy_id=p_pharmacy_id AND o.status::text<>'cancelled'
 ), filtered AS (SELECT * FROM lines WHERE (p_from IS NULL OR date>=p_from) AND (p_to IS NULL OR date<=p_to)
 AND (COALESCE(p_query,'')='' OR concat_ws(' ',product,seller,source,batches,manufacturer,reference) ILIKE '%'||p_query||'%')),
 page AS(SELECT * FROM filtered ORDER BY date DESC,line_id DESC LIMIT LEAST(GREATEST(p_limit,1),200) OFFSET GREATEST(p_offset,0))
 SELECT jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(page ORDER BY date DESC,line_id DESC) FROM page),'[]'),
 'count',(SELECT count(*) FROM filtered),
 'channels',COALESCE((SELECT jsonb_agg(x) FROM (SELECT channel,sum(quantity) units,sum(returned) returned,sum(quantity*unit_cost) gross_cost,
 round(sum(quantity*unit_cost)/NULLIF(sum(quantity),0),2) weighted_average FROM filtered GROUP BY channel) x),'[]')) INTO v;
 RETURN v;
END $$;

DO $$ DECLARE f RECORD; BEGIN
 FOR f IN SELECT p.oid::regprocedure sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
 AND p.proname IN ('list_external_purchases','get_external_purchase','external_procurement_analytics') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f.sig);
 EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.sig);
 END LOOP;
END $$;
