BEGIN;
CREATE FUNCTION public.rfq_transition(p_rfq_id UUID,p_action TEXT,p_revision INTEGER,p_reason TEXT DEFAULT NULL,p_deadline TIMESTAMPTZ DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v_invitee RECORD; BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT r.enterprise OR NOT public.rfq_member(r.pharmacy_id) OR NOT public.can_act_for_business(r.pharmacy_id,'manage') THEN RAISE EXCEPTION 'Pharmacy manager permission required.'; END IF;
 IF r.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'RFQ changed. Reload before proceeding.'; END IF;
 IF r.status IN('cancelled','completed') THEN RAISE EXCEPTION 'RFQ is closed.'; END IF;
 IF p_action='extend' THEN
 IF p_deadline IS NULL OR p_deadline<=GREATEST(now(),r.response_deadline) OR r.status NOT IN('open','evaluation','expired','partially_awarded') THEN RAISE EXCEPTION 'Choose a later future deadline for an active RFQ.'; END IF;
 UPDATE public.rfqs SET response_deadline=p_deadline,status=CASE WHEN r.status IN('evaluation','expired') THEN 'open' ELSE status END WHERE id=r.id;
 ELSIF p_action='evaluate' AND r.status='open' THEN UPDATE public.rfqs SET status='evaluation' WHERE id=r.id;
 ELSIF p_action='cancel_remaining' THEN
 IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Reason required.'; END IF;
 UPDATE public.rfq_items i SET cancelled_quantity=i.quantity-COALESCE((SELECT sum(a.requested_quantity) FROM public.rfq_allocations a JOIN public.rfq_confirmation_groups g ON g.id=a.group_id LEFT JOIN public.orders o ON o.id=g.order_id WHERE a.rfq_item_id=i.id AND (g.status IN('pending','conversion_failed') OR (g.status='confirmed' AND o.status::text<>'cancelled'))),0) WHERE i.rfq_id=r.id;
 ELSIF p_action='cancel' THEN
 IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Cancellation reason required.'; END IF;
 IF EXISTS(SELECT 1 FROM public.rfq_confirmation_groups WHERE rfq_id=r.id AND status='confirmed') THEN RAISE EXCEPTION 'Resolve existing orders through order management, then close remaining requirements.'; END IF;
 UPDATE public.rfq_confirmation_groups SET status='cancelled',reason=p_reason WHERE rfq_id=r.id AND status IN('pending','conversion_failed');
 UPDATE public.rfqs SET status='cancelled',closed_reason=p_reason WHERE id=r.id;
 ELSIF p_action='complete' THEN
 IF EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g JOIN public.order_returns ret ON ret.order_id=g.order_id WHERE g.rfq_id=r.id AND ret.status NOT IN('resolved','rejected','cancelled'))
 OR EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g JOIN public.order_delivery_reports dr ON dr.order_id=g.order_id WHERE g.rfq_id=r.id AND dr.status IN('submitted','disputed'))
 OR EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g JOIN public.order_shipments s ON s.order_id=g.order_id WHERE g.rfq_id=r.id AND s.status NOT IN('delivered','cancelled'))
 OR EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g JOIN public.order_items oi ON oi.order_id=g.order_id WHERE g.rfq_id=r.id AND g.status='confirmed' AND public.order_item_backorder_outstanding(oi.id)>0) THEN RAISE EXCEPTION 'Resolve returns, shipments and outstanding backorders first.'; END IF;
 IF EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g LEFT JOIN public.orders o ON o.id=g.order_id WHERE g.rfq_id=r.id AND (g.status IN('pending','conversion_failed') OR (g.status='confirmed' AND o.status::text NOT IN('delivered','cancelled')))) THEN RAISE EXCEPTION 'Resolve every pending award and linked order first.'; END IF;
 IF EXISTS(SELECT 1 FROM public.rfq_items i WHERE i.rfq_id=r.id AND i.quantity>i.cancelled_quantity+COALESCE((SELECT sum(a.requested_quantity) FROM public.rfq_allocations a JOIN public.rfq_confirmation_groups g ON g.id=a.group_id JOIN public.orders o ON o.id=g.order_id WHERE a.rfq_item_id=i.id AND g.status='confirmed' AND o.status::text='delivered'),0)) THEN RAISE EXCEPTION 'Unresolved requested quantities remain. Explicitly close remaining requirements.'; END IF;
 UPDATE public.rfqs SET status='completed',closed_reason=p_reason WHERE id=r.id;
 ELSE RAISE EXCEPTION 'Invalid RFQ transition.'; END IF;
 UPDATE public.rfqs SET revision=revision+1,updated_by=auth.uid() WHERE id=r.id;
 PERFORM public.rfq_event(r.id,NULL,'RFQ_'||upper(p_action),jsonb_build_object('reason',p_reason,'deadline',p_deadline));
 FOR v_invitee IN SELECT wholesaler_id FROM public.rfq_invitees WHERE rfq_id=r.id LOOP
 PERFORM public.notify_business(v_invitee.wholesaler_id,ARRAY['owner','manager','cashier'],'rfq_updated','RFQ updated',r.reference||': '||replace(p_action,'_',' '),'/wholesaler/rfqs?rfq='||r.id);
 END LOOP;
END $$;

CREATE FUNCTION public.rfq_negotiate(p_rfq_id UUID,p_wholesaler_id UUID,p_version_id UUID,p_proposal JSONB) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v_id UUID; v_term TEXT; v_value TEXT; BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT public.rfq_member(r.pharmacy_id) OR NOT public.can_act_for_business(r.pharmacy_id,'manage') THEN RAISE EXCEPTION 'Pharmacy manager permission required.'; END IF;
 IF r.status NOT IN('open','partially_awarded') OR r.response_deadline<=now() THEN RAISE EXCEPTION 'Extend or reopen the quotation window before negotiating.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.rfq_quote_versions WHERE id=p_version_id AND rfq_id=r.id AND wholesaler_id=p_wholesaler_id) OR EXISTS(SELECT 1 FROM public.rfq_confirmation_groups WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id AND status IN('pending','conversion_failed','confirmed')) THEN RAISE EXCEPTION 'Only unawarded quotations can be negotiated.'; END IF;
 IF jsonb_typeof(p_proposal) IS DISTINCT FROM 'object' OR jsonb_object_length(p_proposal)<>1 OR NOT(p_proposal ?| ARRAY['price','quantity','delivery','credit','substitution']) OR length(p_proposal::text)>8000 THEN RAISE EXCEPTION 'Specify one requested price, quantity, delivery, credit or substitution change.'; END IF;
 SELECT key,p_proposal->>key INTO v_term,v_value FROM jsonb_object_keys(p_proposal) AS keys(key);
 IF (v_term='price' AND (v_value !~ '^[0-9]+(\.[0-9]{1,2})?$' OR v_value::numeric<=0))
 OR (v_term='quantity' AND (v_value !~ '^[1-9][0-9]*$' OR v_value::numeric>10000000))
 OR (v_term IN('delivery','credit','substitution') AND length(btrim(v_value)) NOT BETWEEN 1 AND 500) THEN RAISE EXCEPTION 'Enter a valid positive price/quantity or a concise delivery, credit or substitution request.'; END IF;
 INSERT INTO public.rfq_negotiations(rfq_id,wholesaler_id,quote_version_id,proposal,created_by) VALUES(r.id,p_wholesaler_id,p_version_id,p_proposal,auth.uid()) RETURNING id INTO v_id;
 PERFORM public.rfq_event(r.id,p_wholesaler_id,'NEGOTIATION_REQUESTED',jsonb_build_object('negotiationId',v_id));
 PERFORM public.notify_business(p_wholesaler_id,ARRAY['owner','manager','cashier'],'rfq_negotiation','Quotation negotiation requested',r.title,'/wholesaler/rfqs?rfq='||r.id);
 RETURN v_id;
END $$;
CREATE FUNCTION public.rfq_respond_negotiation(p_id UUID,p_action TEXT,p_response TEXT,p_version_id UUID DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE n public.rfq_negotiations%ROWTYPE; r public.rfqs%ROWTYPE; BEGIN
 SELECT * INTO n FROM public.rfq_negotiations WHERE id=p_id;
 IF NOT FOUND OR NOT public.rfq_member(n.wholesaler_id) OR NOT public.can_act_for_business(n.wholesaler_id,'process') THEN RAISE EXCEPTION 'Supplier permission required.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=n.rfq_id FOR UPDATE;
 SELECT * INTO n FROM public.rfq_negotiations WHERE id=p_id FOR UPDATE;
 IF n.status<>'requested' OR p_action IS NULL OR p_action NOT IN('accepted','rejected','countered') OR NULLIF(btrim(p_response),'') IS NULL THEN RAISE EXCEPTION 'Choose a response and explain the commercial outcome.'; END IF;
 IF p_action IN('accepted','countered') AND NOT EXISTS(SELECT 1 FROM public.rfq_quote_versions v JOIN public.rfq_quote_versions old ON old.id=n.quote_version_id WHERE v.id=p_version_id AND v.quote_id=old.quote_id AND v.version>old.version AND (v.snapshot->'quote'->>'valid_until')::timestamptz>now()) THEN RAISE EXCEPTION 'Submit a new valid quotation revision containing the agreed or counteroffered terms first.'; END IF;
 UPDATE public.rfq_negotiations SET status=p_action,response=p_response,response_version_id=p_version_id,responded_at=now() WHERE id=n.id;
 PERFORM public.rfq_event(r.id,n.wholesaler_id,'NEGOTIATION_'||upper(p_action),jsonb_build_object('negotiationId',n.id,'versionId',p_version_id));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager'],'rfq_negotiation_response','Supplier responded to negotiation',r.title,'/pharmacy/rfqs?rfq='||r.id);
END $$;

CREATE FUNCTION public.list_enterprise_rfqs(p_business_id UUID,p_filters JSONB DEFAULT '{}',p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 25) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.rfq_member(p_business_id) THEN RAISE EXCEPTION 'Approved workspace membership required.'; END IF;
 WITH visible AS(SELECT r.*,CASE WHEN r.status='open' AND r.response_deadline<=now() THEN 'evaluation' ELSE r.status END display_status,
 (SELECT count(*) FROM public.rfq_quotes q WHERE q.rfq_id=r.id AND q.status='submitted' AND (r.pharmacy_id=p_business_id OR q.wholesaler_id=p_business_id)) quote_count
 FROM public.rfqs r WHERE r.pharmacy_id=p_business_id OR (r.status<>'draft' AND EXISTS(SELECT 1 FROM public.rfq_invitees i WHERE i.rfq_id=r.id AND i.wholesaler_id=p_business_id))
 OR (r.enterprise AND r.visibility='open' AND r.status IN('open','partially_awarded') AND r.response_deadline>now() AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p_business_id AND b.type='wholesaler' AND b.verification_status='approved'))),
 filtered AS(SELECT * FROM visible WHERE (COALESCE(p_filters->>'q','')='' OR concat_ws(' ',reference,title) ILIKE '%'||(p_filters->>'q')||'%')
 AND (COALESCE(p_filters->>'status','')='' OR display_status=p_filters->>'status')
 AND (NULLIF(p_filters->>'from','') IS NULL OR created_at::date>=(p_filters->>'from')::date)
 AND (NULLIF(p_filters->>'to','') IS NULL OR created_at::date<=(p_filters->>'to')::date)
 AND (NULLIF(p_filters->>'supplier','') IS NULL OR EXISTS(SELECT 1 FROM public.rfq_invitees i WHERE i.rfq_id=visible.id AND i.wholesaler_id::text=p_filters->>'supplier' AND (visible.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)))),
 page AS(SELECT * FROM filtered ORDER BY CASE WHEN p_filters->>'sort'='deadline' THEN response_deadline END ASC,created_at DESC,id DESC LIMIT LEAST(GREATEST(p_limit,1),100) OFFSET GREATEST(p_offset,0))
 SELECT jsonb_build_object('count',(SELECT count(*) FROM filtered),'rows',COALESCE((SELECT jsonb_agg(to_jsonb(p)-'awarded_quote_id'-'awarded_order_id') FROM page p),'[]')) INTO result;
 RETURN result;
END $$;

CREATE FUNCTION public.rfq_procurement_report(p_business_id UUID,p_from DATE DEFAULT NULL,p_to DATE DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.rfq_member(p_business_id) THEN RAISE EXCEPTION 'Approved workspace membership required.'; END IF;
 WITH rs AS(SELECT * FROM public.rfqs r WHERE (r.pharmacy_id=p_business_id OR (r.status<>'draft' AND EXISTS(SELECT 1 FROM public.rfq_invitees i WHERE i.rfq_id=r.id AND i.wholesaler_id=p_business_id))) AND (p_from IS NULL OR r.created_at::date>=p_from) AND (p_to IS NULL OR r.created_at::date<=p_to)),
 qs AS(SELECT q.* FROM public.rfq_quotes q JOIN rs ON rs.id=q.rfq_id WHERE rs.pharmacy_id=p_business_id OR q.wholesaler_id=p_business_id),
 gs AS(SELECT g.*,o.status::text order_status,o.total_ghs FROM public.rfq_confirmation_groups g JOIN rs ON rs.id=g.rfq_id LEFT JOIN public.orders o ON o.id=g.order_id WHERE rs.pharmacy_id=p_business_id OR g.wholesaler_id=p_business_id)
 SELECT jsonb_build_object('rfqs',(SELECT count(*) FROM rs),'completed',(SELECT count(*) FROM rs WHERE status='completed'),
 'invitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id),
 'viewedInvitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.viewed_at IS NOT NULL AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)),
 'acceptedInvitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.response_status='accepted' AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)),
 'declinedInvitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.response_status='declined' AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)),
 'submittedInvitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.response_status='submitted' AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)),
 'pendingInvitations',(SELECT count(*) FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.response_status='invited' AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id)),
 'quotes',(SELECT count(*) FROM qs),'submittedQuotes',(SELECT count(*) FROM qs WHERE status='submitted'),'orders',(SELECT count(*) FROM gs WHERE order_id IS NOT NULL),
 'conversionFailures',(SELECT count(*) FROM gs WHERE status='conversion_failed'),'declinedAwards',(SELECT count(*) FROM gs WHERE status='declined'),
 'confirmedAwards',(SELECT count(*) FROM gs WHERE status='confirmed'),
 'submittedQuotesNotAwarded',(SELECT count(*) FROM qs q WHERE q.status='submitted' AND NOT EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g WHERE g.rfq_id=q.rfq_id AND g.wholesaler_id=q.wholesaler_id AND g.status IN('pending','conversion_failed','confirmed'))),
 'awardWinRatePercent',(SELECT CASE WHEN count(*)=0 THEN NULL ELSE round(100.0*count(*) FILTER(WHERE EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g WHERE g.rfq_id=q.rfq_id AND g.wholesaler_id=q.wholesaler_id AND g.status='confirmed'))/count(*),1) END FROM qs q WHERE q.status='submitted'),
 'declineReasons',COALESCE((SELECT jsonb_agg(d ORDER BY (d->>'count')::integer DESC) FROM(SELECT jsonb_build_object('reason',i.decline_reason,'count',count(*)) d FROM public.rfq_invitees i JOIN rs ON rs.id=i.rfq_id WHERE i.response_status='declined' AND NULLIF(btrim(i.decline_reason),'') IS NOT NULL AND (rs.pharmacy_id=p_business_id OR i.wholesaler_id=p_business_id) GROUP BY i.decline_reason) grouped_reasons),'[]'),
 'requestedProducts',COALESCE((SELECT jsonb_agg(x ORDER BY requests DESC) FROM(SELECT i.master_product_id,i.product_name,count(*) requests,sum(i.quantity) requested FROM public.rfq_items i JOIN rs ON rs.id=i.rfq_id WHERE rs.pharmacy_id=p_business_id GROUP BY i.master_product_id,i.product_name ORDER BY count(*) DESC LIMIT 50) x),'[]'),
 'orderedValue',(SELECT COALESCE(sum(total_ghs),0) FROM gs WHERE order_status<>'cancelled'),
 'creditValue',(SELECT COALESCE(sum(total_ghs),0) FROM gs WHERE settlement_method='credit' AND order_status<>'cancelled'),
 'averageResponseHours',(SELECT round(avg(extract(epoch FROM(q.submitted_at-i.invited_at))/3600)::numeric,2) FROM qs q JOIN public.rfq_invitees i ON i.rfq_id=q.rfq_id AND i.wholesaler_id=q.wholesaler_id),
 'suppliers',COALESCE((SELECT jsonb_agg(s) FROM(SELECT g.wholesaler_id,b.name,count(*) FILTER(WHERE g.status='confirmed') orders,count(*) FILTER(WHERE g.order_status='delivered') delivered,count(*) FILTER(WHERE g.order_status='cancelled') cancelled,COALESCE(sum(g.total_ghs) FILTER(WHERE g.order_status<>'cancelled'),0) spend FROM gs g JOIN public.businesses b ON b.id=g.wholesaler_id GROUP BY g.wholesaler_id,b.name ORDER BY spend DESC LIMIT 100) s),'[]')) INTO result;
 RETURN result;
END $$;

CREATE FUNCTION public.investigate_rfq(p_rfq_id UUID,p_reason TEXT) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(),'admin') OR length(btrim(COALESCE(p_reason,'')))<10 THEN RAISE EXCEPTION 'Administrator permission and a specific investigation reason required.'; END IF;
 PERFORM public.write_audit_log('RFQ commercial investigation','Platform','rfq',p_rfq_id,'Restricted commercial records',jsonb_build_object('reason',p_reason));
 RETURN jsonb_build_object('rfq',(SELECT to_jsonb(r) FROM public.rfqs r WHERE id=p_rfq_id),'events',COALESCE((SELECT jsonb_agg(e ORDER BY created_at) FROM public.rfq_events e WHERE rfq_id=p_rfq_id),'[]'),'versions',COALESCE((SELECT jsonb_agg(v) FROM public.rfq_quote_versions v WHERE rfq_id=p_rfq_id),'[]'),'awards',COALESCE((SELECT jsonb_agg(g) FROM public.rfq_confirmation_groups g WHERE rfq_id=p_rfq_id),'[]'));
END $$;
REVOKE ALL ON FUNCTION public.rfq_transition(UUID,TEXT,INTEGER,TEXT,TIMESTAMPTZ),public.rfq_negotiate(UUID,UUID,UUID,JSONB),public.rfq_respond_negotiation(UUID,TEXT,TEXT,UUID),public.list_enterprise_rfqs(UUID,JSONB,INTEGER,INTEGER),public.rfq_procurement_report(UUID,DATE,DATE),public.investigate_rfq(UUID,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfq_transition(UUID,TEXT,INTEGER,TEXT,TIMESTAMPTZ),public.rfq_negotiate(UUID,UUID,UUID,JSONB),public.rfq_respond_negotiation(UUID,TEXT,TEXT,UUID),public.list_enterprise_rfqs(UUID,JSONB,INTEGER,INTEGER),public.rfq_procurement_report(UUID,DATE,DATE),public.investigate_rfq(UUID,TEXT) TO authenticated;
COMMIT;
