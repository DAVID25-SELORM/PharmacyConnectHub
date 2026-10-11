BEGIN;
CREATE TABLE public.rfq_favourite_suppliers(pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),PRIMARY KEY(pharmacy_id,wholesaler_id));
ALTER TABLE public.rfq_favourite_suppliers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rfq_favourite_suppliers FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.rfq_favourite_suppliers TO authenticated;
CREATE POLICY own_favourites ON public.rfq_favourite_suppliers FOR SELECT TO authenticated USING(public.rfq_member(pharmacy_id));
CREATE FUNCTION public.set_rfq_favourite(p_pharmacy_id UUID,p_wholesaler_id UUID,p_favourite BOOLEAN) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT public.rfq_member(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND type='pharmacy') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_wholesaler_id AND type='wholesaler' AND verification_status='approved') THEN RAISE EXCEPTION 'Approved pharmacy and supplier required.'; END IF;
 IF p_favourite THEN INSERT INTO public.rfq_favourite_suppliers VALUES(p_pharmacy_id,p_wholesaler_id) ON CONFLICT DO NOTHING; ELSE DELETE FROM public.rfq_favourite_suppliers WHERE pharmacy_id=p_pharmacy_id AND wholesaler_id=p_wholesaler_id; END IF;
END $$;
CREATE FUNCTION public.rfq_supplier_options(p_pharmacy_id UUID,p_query TEXT DEFAULT '',p_mode TEXT DEFAULT 'all',p_products UUID[] DEFAULT '{}',p_offset INTEGER DEFAULT 0) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.rfq_member(p_pharmacy_id) THEN RAISE EXCEPTION 'Approved pharmacy membership required.'; END IF;
 SELECT COALESCE(jsonb_agg(x),'[]') INTO result FROM(SELECT b.id,b.name,
 EXISTS(SELECT 1 FROM public.rfq_favourite_suppliers f WHERE f.pharmacy_id=p_pharmacy_id AND f.wholesaler_id=b.id) favourite,
 (SELECT count(DISTINCT wp.product_id) FROM public.wholesaler_products wp JOIN public.products p ON p.id=wp.id WHERE wp.wholesaler_id=b.id AND p.active AND wp.product_id=ANY(p_products)) matching_catalogue_products
 ,(SELECT count(*) FROM public.orders o WHERE o.pharmacy_id=p_pharmacy_id AND o.wholesaler_id=b.id) previous_orders
 ,(SELECT count(*) FROM public.orders o WHERE o.pharmacy_id=p_pharmacy_id AND o.wholesaler_id=b.id AND o.status::text='delivered') delivered_orders
 ,(SELECT count(*) FROM public.orders o WHERE o.pharmacy_id=p_pharmacy_id AND o.wholesaler_id=b.id AND o.status::text='cancelled') cancelled_orders
 FROM public.businesses b WHERE b.type='wholesaler' AND b.verification_status='approved' AND b.name ILIKE '%'||COALESCE(p_query,'')||'%'
 AND (p_mode<>'previous' OR EXISTS(SELECT 1 FROM public.orders o WHERE o.pharmacy_id=p_pharmacy_id AND o.wholesaler_id=b.id AND o.status::text='delivered'))
 AND (p_mode<>'favourites' OR EXISTS(SELECT 1 FROM public.rfq_favourite_suppliers f WHERE f.pharmacy_id=p_pharmacy_id AND f.wholesaler_id=b.id))
 AND (p_mode<>'matching' OR EXISTS(SELECT 1 FROM public.wholesaler_products wp JOIN public.products p ON p.id=wp.id WHERE wp.wholesaler_id=b.id AND p.active AND wp.product_id=ANY(p_products)))
 ORDER BY b.name,b.id LIMIT 20 OFFSET GREATEST(p_offset,0)) x; RETURN result;
END $$;
CREATE FUNCTION public.rfq_order_cancelled() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g public.rfq_confirmation_groups%ROWTYPE; BEGIN
 IF NEW.rfq_confirmation_id IS NOT NULL AND NEW.status::text='cancelled' AND OLD.status IS DISTINCT FROM NEW.status THEN
 UPDATE public.rfq_confirmation_groups SET status='cancelled',reason='Linked order cancelled through order management.' WHERE id=NEW.rfq_confirmation_id RETURNING * INTO g;
 PERFORM public.rfq_event(g.rfq_id,g.wholesaler_id,'RFQ_ORDER_CANCELLED',jsonb_build_object('orderId',NEW.id));
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER rfq_order_cancelled AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.rfq_order_cancelled();
REVOKE ALL ON FUNCTION public.rfq_order_cancelled() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.rfq_platform_report(p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 25) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Administrator permission required.'; END IF;
 SELECT jsonb_build_object('rfqs',(SELECT count(*) FROM public.rfqs),'pharmacies',(SELECT count(DISTINCT pharmacy_id) FROM public.rfqs),
 'suppliers',(SELECT count(DISTINCT wholesaler_id) FROM public.rfq_quotes),'quotes',(SELECT count(*) FROM public.rfq_quotes),
 'orders',(SELECT count(*) FROM public.rfq_confirmation_groups WHERE order_id IS NOT NULL),'failed',(SELECT count(*) FROM public.rfq_confirmation_groups WHERE status='conversion_failed'),
 'cancelled',(SELECT count(*) FROM public.rfqs WHERE status='cancelled'),
 'rows',COALESCE((SELECT jsonb_agg(x) FROM(SELECT r.id,r.reference,r.title,r.status,r.created_at,(SELECT count(*) FROM public.rfq_confirmation_groups g WHERE g.rfq_id=r.id AND g.status='conversion_failed') failed_conversions FROM public.rfqs r ORDER BY r.created_at DESC,r.id LIMIT LEAST(GREATEST(p_limit,1),100) OFFSET GREATEST(p_offset,0)) x),'[]')) INTO result;
 RETURN result;
END $$;
-- Commercial RFQ headers must not expose legacy winner pointers to losing suppliers.
-- New enterprise headers never populate those fields. Legacy data is preserved.
REVOKE ALL ON FUNCTION public.set_rfq_favourite(UUID,UUID,BOOLEAN),public.rfq_supplier_options(UUID,TEXT,TEXT,UUID[],INTEGER),public.rfq_platform_report(INTEGER,INTEGER) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_rfq_favourite(UUID,UUID,BOOLEAN),public.rfq_supplier_options(UUID,TEXT,TEXT,UUID[],INTEGER),public.rfq_platform_report(INTEGER,INTEGER) TO authenticated;
COMMIT;
