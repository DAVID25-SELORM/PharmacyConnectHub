BEGIN;
CREATE TABLE public.rfq_attachments(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),rfq_id UUID NOT NULL REFERENCES public.rfqs(id),
 wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),filename TEXT NOT NULL,
 storage_path TEXT NOT NULL UNIQUE,created_by UUID NOT NULL REFERENCES auth.users(id),created_at TIMESTAMPTZ NOT NULL DEFAULT now());
ALTER TABLE public.rfq_attachments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rfq_attachments FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.rfq_attachments TO authenticated;
CREATE POLICY rfq_attachment_read ON public.rfq_attachments FOR SELECT TO authenticated USING(public.can_view_rfq_party_row(rfq_id,wholesaler_id));
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('rfq-evidence','rfq-evidence',false,10485760,ARRAY['application/pdf','image/jpeg','image/png']) ON CONFLICT(id) DO NOTHING;
CREATE FUNCTION public.rfq_storage_access(p_name TEXT,p_write BOOLEAN DEFAULT false) RETURNS BOOLEAN LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE rid UUID; wid UUID; BEGIN
 IF array_length(string_to_array(p_name,'/'),1)<>3 THEN RETURN false; END IF;
 BEGIN rid:=split_part(p_name,'/',1)::uuid;wid:=split_part(p_name,'/',2)::uuid; EXCEPTION WHEN invalid_text_representation THEN RETURN false; END;
 IF p_write THEN RETURN public.rfq_member(wid) AND public.can_act_for_business(wid,'process') AND EXISTS(SELECT 1 FROM public.rfq_invitees i JOIN public.rfqs r ON r.id=i.rfq_id WHERE i.rfq_id=rid AND i.wholesaler_id=wid AND r.status IN('open','partially_awarded') AND r.response_deadline>now()); END IF;
 RETURN EXISTS(SELECT 1 FROM public.rfq_attachments a WHERE a.storage_path=p_name AND public.can_view_rfq_party_row(a.rfq_id,a.wholesaler_id));
END $$;
CREATE POLICY rfq_evidence_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='rfq-evidence' AND public.rfq_storage_access(name));
CREATE POLICY rfq_evidence_upload ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='rfq-evidence' AND public.rfq_storage_access(name,true));
CREATE FUNCTION public.register_rfq_attachment(p_rfq_id UUID,p_wholesaler_id UUID,p_path TEXT,p_filename TEXT) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result UUID; BEGIN
 PERFORM 1 FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT public.rfq_storage_access(p_path,true) OR split_part(p_path,'/',1)<>p_rfq_id::text OR split_part(p_path,'/',2)<>p_wholesaler_id::text THEN RAISE EXCEPTION 'Supplier upload permission required.'; END IF;
 IF NULLIF(btrim(p_filename),'') IS NULL OR length(p_filename)>250 OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='rfq-evidence' AND name=p_path) THEN RAISE EXCEPTION 'Upload a valid file first.'; END IF;
 INSERT INTO public.rfq_attachments(rfq_id,wholesaler_id,filename,storage_path,created_by) VALUES(p_rfq_id,p_wholesaler_id,p_filename,p_path,auth.uid()) ON CONFLICT(storage_path) DO UPDATE SET storage_path=EXCLUDED.storage_path RETURNING id INTO result;
 RETURN result;
END $$;
CREATE TABLE public.rfq_reminder_receipts(rfq_id UUID NOT NULL REFERENCES public.rfqs(id),wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),deadline TIMESTAMPTZ NOT NULL,PRIMARY KEY(rfq_id,wholesaler_id,deadline));
ALTER TABLE public.rfq_reminder_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rfq_reminder_receipts FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.refresh_rfq_reminders(p_business_id UUID) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r RECORD; affected INTEGER; total INTEGER:=0; BEGIN
 IF NOT public.rfq_member(p_business_id) THEN RAISE EXCEPTION 'Approved workspace membership required.'; END IF;
 FOR r IN SELECT q.id,q.title,q.response_deadline,i.wholesaler_id FROM public.rfqs q JOIN public.rfq_invitees i ON i.rfq_id=q.id
 WHERE (q.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id) AND q.status IN('open','partially_awarded') AND q.response_deadline>now() AND q.response_deadline<=now()+interval '24 hours' AND i.response_status<>'declined' LOOP
 INSERT INTO public.rfq_reminder_receipts VALUES(r.id,r.wholesaler_id,r.response_deadline) ON CONFLICT DO NOTHING;
 GET DIAGNOSTICS affected=ROW_COUNT;
 IF affected>0 THEN
 PERFORM public.notify_business(r.wholesaler_id,ARRAY['owner','manager','cashier','warehouse'],'rfq_deadline','RFQ deadline within 24 hours',r.title,'/wholesaler/rfqs?rfq='||r.id);
 total:=total+1;
 END IF;
 END LOOP; RETURN total;
END $$;
CREATE FUNCTION public.rfq_document(p_rfq_id UUID,p_version_id UUID DEFAULT NULL,p_group_id UUID DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v public.rfq_quote_versions%ROWTYPE; g public.rfq_confirmation_groups%ROWTYPE; BEGIN
 IF NOT public.can_view_rfq(p_rfq_id) THEN RAISE EXCEPTION 'RFQ document unavailable.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id;
 IF p_version_id IS NOT NULL THEN SELECT * INTO v FROM public.rfq_quote_versions WHERE id=p_version_id AND rfq_id=r.id; IF NOT FOUND OR NOT public.can_view_rfq_party_row(r.id,v.wholesaler_id) THEN RAISE EXCEPTION 'Quotation document unavailable.'; END IF; END IF;
 IF p_group_id IS NOT NULL THEN SELECT * INTO g FROM public.rfq_confirmation_groups WHERE id=p_group_id AND rfq_id=r.id; IF NOT FOUND OR NOT public.can_view_rfq_party_row(r.id,g.wholesaler_id) THEN RAISE EXCEPTION 'Award document unavailable.'; END IF; END IF;
 RETURN jsonb_build_object('rfq',to_jsonb(r)-'awarded_quote_id'-'awarded_order_id','pharmacy',(SELECT name FROM public.businesses WHERE id=r.pharmacy_id),
 'items',(SELECT jsonb_agg(i ORDER BY i.id) FROM public.rfq_items i WHERE rfq_id=r.id),'version',CASE WHEN v.id IS NOT NULL THEN to_jsonb(v) END,'award',CASE WHEN g.id IS NOT NULL THEN to_jsonb(g) END,
 'supplier',(SELECT name FROM public.businesses WHERE id=COALESCE(g.wholesaler_id,v.wholesaler_id)),
 'allocations',CASE WHEN g.id IS NOT NULL THEN (SELECT jsonb_agg(a) FROM public.rfq_allocations a WHERE group_id=g.id) END);
END $$;
CREATE FUNCTION public.rfq_purchase_history(p_pharmacy_id UUID,p_query TEXT DEFAULT '',p_offset INTEGER DEFAULT 0) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.rfq_member(p_pharmacy_id) THEN RAISE EXCEPTION 'Approved pharmacy membership required.'; END IF;
 SELECT COALESCE(jsonb_agg(x),'[]') INTO result FROM(SELECT wp.product_id master_product_id,oi.product_name,max(o.created_at) last_purchase,sum(oi.quantity) quantity
 FROM public.orders o JOIN public.order_items oi ON oi.order_id=o.id JOIN public.wholesaler_products wp ON wp.id=oi.product_id
 WHERE o.pharmacy_id=p_pharmacy_id AND o.status::text='delivered' AND oi.product_name ILIKE '%'||COALESCE(p_query,'')||'%'
 GROUP BY wp.product_id,oi.product_name ORDER BY max(o.created_at) DESC LIMIT 25 OFFSET GREATEST(p_offset,0)) x;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.rfq_storage_access(TEXT,BOOLEAN),public.register_rfq_attachment(UUID,UUID,TEXT,TEXT),public.refresh_rfq_reminders(UUID),public.rfq_document(UUID,UUID,UUID),public.rfq_purchase_history(UUID,TEXT,INTEGER) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfq_storage_access(TEXT,BOOLEAN),public.register_rfq_attachment(UUID,UUID,TEXT,TEXT),public.refresh_rfq_reminders(UUID),public.rfq_document(UUID,UUID,UUID),public.rfq_purchase_history(UUID,TEXT,INTEGER) TO authenticated;
COMMIT;
