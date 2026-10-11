BEGIN;
-- Additive correction for already deployed RFQ operations.
CREATE OR REPLACE FUNCTION public.rfq_negotiate(p_rfq_id UUID,p_wholesaler_id UUID,p_version_id UUID,p_proposal JSONB) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v_id UUID; v_term TEXT; v_value TEXT; BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT public.rfq_member(r.pharmacy_id) OR NOT public.can_act_for_business(r.pharmacy_id,'manage') THEN RAISE EXCEPTION 'Pharmacy manager permission required.'; END IF;
 IF r.status NOT IN('open','partially_awarded') OR r.response_deadline<=now() THEN RAISE EXCEPTION 'Extend or reopen the quotation window before negotiating.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.rfq_quote_versions WHERE id=p_version_id AND rfq_id=r.id AND wholesaler_id=p_wholesaler_id) OR EXISTS(SELECT 1 FROM public.rfq_confirmation_groups WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id AND status IN('pending','conversion_failed','confirmed')) THEN RAISE EXCEPTION 'Only unawarded quotations can be negotiated.'; END IF;
 IF jsonb_typeof(p_proposal) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Proposal must be an object.'; END IF;
 IF (SELECT count(*) FROM jsonb_object_keys(p_proposal))<>1 OR NOT(p_proposal ?| ARRAY['price','quantity','delivery','credit','substitution']) OR length(p_proposal::text)>8000 THEN RAISE EXCEPTION 'Specify one requested price, quantity, delivery, credit or substitution change.'; END IF;
 SELECT key,p_proposal->>key INTO v_term,v_value FROM jsonb_object_keys(p_proposal) AS keys(key);
 IF v_value IS NULL OR jsonb_typeof(p_proposal->v_term) NOT IN ('string','number') THEN RAISE EXCEPTION 'Proposal value must be nonempty text or a number.'; END IF;
 IF (v_term='price' AND (v_value !~ '^[0-9]+(\.[0-9]{1,2})?$' OR v_value::numeric<=0))
 OR (v_term='quantity' AND (v_value !~ '^[1-9][0-9]*$' OR v_value::numeric>10000000))
 OR (v_term IN('delivery','credit','substitution') AND length(btrim(v_value)) NOT BETWEEN 1 AND 500) THEN RAISE EXCEPTION 'Enter a valid positive price/quantity or a concise delivery, credit or substitution request.'; END IF;
 INSERT INTO public.rfq_negotiations(rfq_id,wholesaler_id,quote_version_id,proposal,created_by) VALUES(r.id,p_wholesaler_id,p_version_id,p_proposal,auth.uid()) RETURNING id INTO v_id;
 PERFORM public.rfq_event(r.id,p_wholesaler_id,'NEGOTIATION_REQUESTED',jsonb_build_object('negotiationId',v_id));
 PERFORM public.notify_business(p_wholesaler_id,ARRAY['owner','manager','cashier'],'rfq_negotiation','Quotation negotiation requested',r.title,'/wholesaler/rfqs?rfq='||r.id);
 RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION public.rfq_respond_negotiation(p_id UUID,p_action TEXT,p_response TEXT,p_version_id UUID DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE n public.rfq_negotiations%ROWTYPE; r public.rfqs%ROWTYPE; BEGIN
 SELECT * INTO n FROM public.rfq_negotiations WHERE id=p_id;
 IF NOT FOUND OR NOT public.rfq_member(n.wholesaler_id) OR NOT public.can_act_for_business(n.wholesaler_id,'process') THEN RAISE EXCEPTION 'Supplier permission required.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=n.rfq_id FOR UPDATE;
 SELECT * INTO n FROM public.rfq_negotiations WHERE id=p_id FOR UPDATE;
 IF r.status NOT IN ('open','partially_awarded','evaluation') THEN RAISE EXCEPTION 'RFQ is closed for negotiation responses.'; END IF;
 IF n.status<>'requested' OR p_action IS NULL OR p_action NOT IN('accepted','rejected','countered') OR NULLIF(btrim(p_response),'') IS NULL THEN RAISE EXCEPTION 'Choose a response and explain the commercial outcome.'; END IF;
 IF p_action IN('accepted','countered') AND NOT EXISTS(SELECT 1 FROM public.rfq_quote_versions v JOIN public.rfq_quote_versions old ON old.id=n.quote_version_id WHERE v.id=p_version_id AND v.quote_id=old.quote_id AND v.version>old.version AND (v.snapshot->'quote'->>'valid_until')::timestamptz>now()) THEN RAISE EXCEPTION 'Submit a new valid quotation revision containing the agreed or counteroffered terms first.'; END IF;
 UPDATE public.rfq_negotiations SET status=p_action,response=p_response,response_version_id=p_version_id,responded_at=now() WHERE id=n.id;
 PERFORM public.rfq_event(r.id,n.wholesaler_id,'NEGOTIATION_'||upper(p_action),jsonb_build_object('negotiationId',n.id,'versionId',p_version_id));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager'],'rfq_negotiation_response','Supplier responded to negotiation',r.title,'/pharmacy/rfqs?rfq='||r.id);
END $$;

CREATE OR REPLACE FUNCTION public.rfq_document(p_rfq_id UUID,p_version_id UUID DEFAULT NULL,p_group_id UUID DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v public.rfq_quote_versions%ROWTYPE; g public.rfq_confirmation_groups%ROWTYPE; BEGIN
 IF NOT public.can_view_rfq(p_rfq_id) THEN RAISE EXCEPTION 'RFQ document unavailable.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id;
 IF p_version_id IS NOT NULL THEN SELECT * INTO v FROM public.rfq_quote_versions WHERE id=p_version_id AND rfq_id=r.id; IF NOT FOUND OR NOT public.can_view_rfq_party_row(r.id,v.wholesaler_id) THEN RAISE EXCEPTION 'Quotation document unavailable.'; END IF; END IF;
 IF p_group_id IS NOT NULL THEN SELECT * INTO g FROM public.rfq_confirmation_groups WHERE id=p_group_id AND rfq_id=r.id; IF NOT FOUND OR NOT public.can_view_rfq_party_row(r.id,g.wholesaler_id) THEN RAISE EXCEPTION 'Award document unavailable.'; END IF; END IF;
 IF g.id IS NOT NULL AND v.id IS NOT NULL AND g.quote_version_id IS DISTINCT FROM v.id THEN RAISE EXCEPTION 'Quotation does not match award.'; END IF;
 RETURN jsonb_build_object('issuer',(SELECT jsonb_build_object('id',b.id,'name',b.name,'address',to_jsonb(b)->>'address','city',to_jsonb(b)->>'city','region',to_jsonb(b)->>'region','phone',to_jsonb(b)->>'phone','public_email',to_jsonb(b)->>'public_email','license_number',to_jsonb(b)->>'license_number','branding',to_jsonb(br)-'business_id'-'created_at'-'updated_at') FROM public.businesses b LEFT JOIN public.business_document_branding br ON br.business_id=b.id WHERE b.id=CASE WHEN g.id IS NULL AND v.id IS NOT NULL THEN v.wholesaler_id ELSE r.pharmacy_id END),'rfq',to_jsonb(r)-'awarded_quote_id'-'awarded_order_id','pharmacy',(SELECT name FROM public.businesses WHERE id=r.pharmacy_id),
 'items',(SELECT jsonb_agg(i ORDER BY i.id) FROM public.rfq_items i WHERE rfq_id=r.id),'version',CASE WHEN v.id IS NOT NULL THEN to_jsonb(v) END,'award',CASE WHEN g.id IS NOT NULL THEN to_jsonb(g) END,
 'supplier',(SELECT name FROM public.businesses WHERE id=COALESCE(g.wholesaler_id,v.wholesaler_id)),
 'allocations',CASE WHEN g.id IS NOT NULL THEN (SELECT jsonb_agg(a) FROM public.rfq_allocations a WHERE group_id=g.id) END);
END $$;

COMMIT;
