BEGIN;
CREATE FUNCTION public.save_enterprise_quote(p_rfq_id UUID,p_wholesaler_id UUID,p_payload JSONB,p_submit BOOLEAN,p_version INTEGER,p_request_id UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; q public.rfq_quotes%ROWTYPE; ri public.rfq_items%ROWTYPE; x JSONB; offered RECORD;
 v_id UUID; v_qty INTEGER; v_price NUMERIC; v_discount NUMERIC; v_final NUMERIC; v_ratio NUMERIC; v_alt BOOLEAN; v_expiry DATE;
 v_total NUMERIC:=0; v_hash TEXT; prev public.rfq_requests%ROWTYPE; v_order_discount NUMERIC;
BEGIN
 IF p_request_id IS NULL OR p_submit IS NULL THEN RAISE EXCEPTION 'Request ID and submission choice required.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT r.enterprise OR NOT public.rfq_member(p_wholesaler_id) OR NOT public.can_act_for_business(p_wholesaler_id,'process') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_wholesaler_id AND type='wholesaler' AND verification_status='approved') OR (NOT EXISTS(SELECT 1 FROM public.rfq_invitees WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id) AND NOT (r.visibility='open' AND r.status IN('open','partially_awarded') AND r.response_deadline>now())) THEN RAISE EXCEPTION 'Supplier quotation permission required.'; END IF;
 v_hash:=md5(jsonb_build_array('quote',p_rfq_id,p_wholesaler_id,p_payload,p_submit,p_version)::text);
 SELECT * INTO prev FROM public.rfq_requests WHERE actor_id=auth.uid() AND request_id=p_request_id;
 IF FOUND THEN IF prev.payload_hash<>v_hash THEN RAISE EXCEPTION 'Request ID reused with different data.'; END IF; RETURN (prev.result->>'id')::uuid; END IF;
 IF r.status NOT IN('open','partially_awarded') OR r.response_deadline<=now() THEN RAISE EXCEPTION 'RFQ is closed to quotations.'; END IF;
 IF EXISTS(SELECT 1 FROM public.rfq_confirmation_groups WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id AND status IN('pending','conversion_failed','confirmed')) THEN RAISE EXCEPTION 'Awarded quotation terms are locked.'; END IF;
 SELECT * INTO q FROM public.rfq_quotes WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id;
 IF COALESCE(q.version,0) IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Quotation changed. Reload before saving.'; END IF;
 IF NOT p_submit THEN
 INSERT INTO public.rfq_quote_drafts(rfq_id,wholesaler_id,payload) VALUES(r.id,p_wholesaler_id,p_payload)
 ON CONFLICT(rfq_id,wholesaler_id) DO UPDATE SET payload=EXCLUDED.payload,revision=rfq_quote_drafts.revision+1,updated_at=now();
 RETURN q.id;
 END IF;
 IF jsonb_typeof(p_payload->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Quote 1–500 lines.'; END IF;
 IF NULLIF(p_payload->>'validUntil','') IS NULL OR (p_payload->>'validUntil')::timestamptz<=now() THEN RAISE EXCEPTION 'Future quotation validity required.'; END IF;
 IF q.id IS NOT NULL AND NULLIF(btrim(p_payload->>'reason'),'') IS NULL THEN RAISE EXCEPTION 'Revision reason required.'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(p_payload->'items'))<>(SELECT count(DISTINCT el.value->>'rfqItemId') FROM jsonb_array_elements(p_payload->'items') el) THEN RAISE EXCEPTION 'Duplicate quotation line.'; END IF;
 INSERT INTO public.rfq_invitees(rfq_id,wholesaler_id) VALUES(r.id,p_wholesaler_id) ON CONFLICT(rfq_id,wholesaler_id) DO NOTHING;
 v_order_discount:=COALESCE((p_payload->>'orderDiscountPercent')::numeric,0);
 IF v_order_discount<0 OR v_order_discount>=100 THEN RAISE EXCEPTION 'Order discount must be from 0 to less than 100 percent.'; END IF;
 INSERT INTO public.rfq_quotes(rfq_id,wholesaler_id,status,valid_until,total_ghs,delivery_charge_ghs,lead_time_days,payment_terms,delivery_notes,version)
 VALUES(r.id,p_wholesaler_id,'submitted',(p_payload->>'validUntil')::timestamptz,0,COALESCE((p_payload->>'deliveryCharge')::numeric,0),NULLIF(p_payload->>'leadTimeDays','')::integer,NULLIF(p_payload->>'paymentTerms',''),NULLIF(p_payload->>'deliveryNotes',''),1)
 ON CONFLICT(rfq_id,wholesaler_id) DO UPDATE SET status='submitted',valid_until=EXCLUDED.valid_until,delivery_charge_ghs=EXCLUDED.delivery_charge_ghs,
 lead_time_days=EXCLUDED.lead_time_days,payment_terms=EXCLUDED.payment_terms,delivery_notes=EXCLUDED.delivery_notes,version=rfq_quotes.version+1,submitted_at=now() RETURNING * INTO q;
 DELETE FROM public.rfq_quote_items WHERE rfq_quote_id=q.id;
 FOR x IN SELECT value FROM jsonb_array_elements(p_payload->'items') LOOP
 SELECT * INTO ri FROM public.rfq_items WHERE id=(x->>'rfqItemId')::uuid AND rfq_id=r.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Invalid requested line.'; END IF;
 SELECT p.*,wp.product_id master_id,mp.generic_name,mp.brand_name,mp.strength,mp.dosage_form,mp.pack_size INTO offered FROM public.products p
 LEFT JOIN public.wholesaler_products wp ON wp.id=p.id LEFT JOIN public.master_products mp ON mp.id=wp.product_id
 WHERE p.id=(x->>'productId')::uuid AND p.wholesaler_id=p_wholesaler_id AND p.active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Choose your active catalogue product.'; END IF;
 IF COALESCE((x->>'quantity')::numeric,0)<>trunc(COALESCE((x->>'quantity')::numeric,0)) THEN RAISE EXCEPTION 'Offered quantity must be whole units.'; END IF;
 v_qty:=(x->>'quantity')::integer; v_price:=round((x->>'unitPriceGhs')::numeric,2); v_discount:=COALESCE((x->>'discountPercent')::numeric,0);
 v_ratio:=COALESCE((x->>'conversion')::numeric,1); v_alt:=COALESCE((x->>'alternative')::boolean,false); v_expiry:=NULLIF(x->>'expiryDate','')::date;
 IF length(COALESCE(x->>'batchNumber',''))>100 OR length(COALESCE(x->>'specialHandling',''))>500 THEN RAISE EXCEPTION 'Batch number or handling note is too long.'; END IF;
 IF v_qty IS NULL OR v_qty<=0 OR v_ratio<=0 OR v_qty*v_ratio>ri.quantity OR (NOT ri.partial_allowed AND v_qty*v_ratio<>ri.quantity) THEN RAISE EXCEPTION 'Offered quantity does not satisfy the requested quantity/partial policy.'; END IF;
 IF v_price IS NULL OR v_price<=0 OR v_discount<0 OR v_discount>=100 THEN RAISE EXCEPTION 'Invalid unit price or discount.'; END IF;
 IF (ri.master_product_id IS DISTINCT FROM offered.master_id OR v_ratio<>1) AND NOT v_alt THEN RAISE EXCEPTION 'Different or unmatched medicine identity requires an explicit alternative proposal.'; END IF;
 IF v_alt AND NOT ri.alternatives_allowed THEN RAISE EXCEPTION 'Alternatives are not permitted on this line.'; END IF;
 IF v_expiry IS NULL OR v_expiry<=GREATEST(current_date,COALESCE(r.expected_delivery_date,current_date))+ri.minimum_shelf_life_days THEN RAISE EXCEPTION 'Provide expiry satisfying the requested shelf life at expected delivery.'; END IF;
 IF ri.cold_chain_required AND NOT COALESCE((x->>'coldChainSupported')::boolean,false) THEN RAISE EXCEPTION 'This requirement needs a supplier-confirmed cold chain.'; END IF;
 v_final:=round(round(v_price*(1-v_discount/100),2)*(1-v_order_discount/100),2);
 IF v_final<=0 THEN RAISE EXCEPTION 'Discounted unit price must be positive.'; END IF;
 INSERT INTO public.rfq_quote_items(rfq_quote_id,rfq_item_id,product_id,quantity,unit_price_ghs,discount_percent,final_unit_price_ghs,line_total_ghs,notes,alternative,offered_specification,requested_units_per_offered_unit,expiry_date,batch_number,expected_available_on,cold_chain_supported,special_handling)
 VALUES(q.id,ri.id,offered.id,v_qty,v_price,v_discount,v_final,v_final*v_qty,x->>'notes',v_alt,
 jsonb_build_object('name',offered.name,'masterProductId',offered.master_id,'generic',offered.generic_name,'brand',offered.brand_name,'strength',offered.strength,'form',offered.dosage_form,'pack',offered.pack_size,'stockAtSubmission',offered.stock,'stockObservedAt',now()),v_ratio,v_expiry,NULLIF(btrim(x->>'batchNumber'),''),NULLIF(x->>'expectedAvailableOn','')::date,COALESCE((x->>'coldChainSupported')::boolean,false),NULLIF(btrim(x->>'specialHandling'),''));
 v_total:=v_total+v_final*v_qty;
 END LOOP;
 UPDATE public.rfq_quotes SET total_ghs=v_total WHERE id=q.id RETURNING * INTO q;
 INSERT INTO public.rfq_quote_versions(quote_id,rfq_id,wholesaler_id,version,snapshot,reason,created_by)
 VALUES(q.id,r.id,p_wholesaler_id,q.version,jsonb_build_object('quote',to_jsonb(q),'items',(SELECT jsonb_agg(i ORDER BY i.id) FROM public.rfq_quote_items i WHERE rfq_quote_id=q.id),'orderDiscountPercent',v_order_discount,'taxTreatment','Prices include applicable taxes; no separate tax added','currency','GHS'),COALESCE(NULLIF(btrim(p_payload->>'reason'),''),'Initial quotation'),auth.uid()) RETURNING id INTO v_id;
 DELETE FROM public.rfq_quote_drafts WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id;
 UPDATE public.rfq_invitees SET response_status='submitted',responded_at=now() WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id;
 PERFORM public.rfq_event(r.id,p_wholesaler_id,'QUOTE_SUBMITTED',jsonb_build_object('version',q.version,'versionId',v_id));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager','cashier'],'rfq_quote_received','Quotation received',r.title,'/pharmacy/rfqs?rfq='||r.id);
 INSERT INTO public.rfq_requests VALUES(auth.uid(),p_request_id,v_hash,jsonb_build_object('id',v_id),now());
 RETURN v_id;
END $$;

CREATE FUNCTION public.propose_rfq_awards(p_rfq_id UUID,p_allocations JSONB,p_settlement_method TEXT,p_request_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v public.rfq_quote_versions%ROWTYPE; ri public.rfq_items%ROWTYPE; x JSONB; line JSONB;
 g UUID; groups JSONB:='[]'; v_qty INTEGER; v_requested NUMERIC; used NUMERIC; offered_used NUMERIC; prev public.rfq_requests%ROWTYPE; v_hash TEXT;
BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT r.enterprise OR NOT public.rfq_member(r.pharmacy_id) OR NOT public.can_act_for_business(r.pharmacy_id,'manage') THEN RAISE EXCEPTION 'Approved pharmacy manager permission required.'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Request ID required.'; END IF;
 v_hash:=md5(jsonb_build_array('award',p_rfq_id,p_allocations,p_settlement_method)::text);
 SELECT * INTO prev FROM public.rfq_requests WHERE actor_id=auth.uid() AND request_id=p_request_id;
 IF FOUND THEN IF prev.payload_hash<>v_hash THEN RAISE EXCEPTION 'Request ID reused with different data.'; END IF; RETURN prev.result; END IF;
 IF r.status NOT IN('open','evaluation','partially_awarded','in_progress') THEN RAISE EXCEPTION 'RFQ cannot receive awards.'; END IF;
 IF jsonb_typeof(p_allocations) IS DISTINCT FROM 'array' OR jsonb_array_length(p_allocations) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Select 1–500 allocations.'; END IF;
 FOR v IN SELECT qv.* FROM public.rfq_quote_versions qv WHERE qv.id IN(SELECT (a->>'versionId')::uuid FROM jsonb_array_elements(p_allocations) a) ORDER BY qv.wholesaler_id LOOP
 IF v.rfq_id<>r.id OR NOT EXISTS(SELECT 1 FROM public.rfq_quotes q WHERE q.id=v.quote_id AND q.version=v.version AND q.status='submitted') OR (v.snapshot->'quote'->>'valid_until')::timestamptz<=now() THEN RAISE EXCEPTION 'Quotation changed, withdrawn or expired. Review the current version.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=v.wholesaler_id AND verification_status='approved') THEN RAISE EXCEPTION 'Supplier is no longer approved.'; END IF;
 INSERT INTO public.rfq_confirmation_groups(rfq_id,quote_version_id,wholesaler_id,settlement_method,goods_ghs,delivery_ghs,created_by)
 VALUES(r.id,v.id,v.wholesaler_id,p_settlement_method,1,(v.snapshot->'quote'->>'delivery_charge_ghs')::numeric,auth.uid()) RETURNING id INTO g;
 FOR x IN SELECT value FROM jsonb_array_elements(p_allocations) WHERE (value->>'versionId')::uuid=v.id LOOP
 SELECT value INTO line FROM jsonb_array_elements(v.snapshot->'items') WHERE value->>'id'=x->>'quoteItemId';
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown quotation line.'; END IF;
 SELECT * INTO ri FROM public.rfq_items WHERE id=(line->>'rfq_item_id')::uuid AND rfq_id=r.id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown medicine requirement.'; END IF;
 IF COALESCE((x->>'quantity')::numeric,0)<=0 OR (x->>'quantity')::numeric<>trunc((x->>'quantity')::numeric) THEN RAISE EXCEPTION 'Select positive whole offered units.'; END IF;
 v_qty:=(x->>'quantity')::integer; v_requested:=v_qty*(line->>'requested_units_per_offered_unit')::numeric;
 IF v_requested<>trunc(v_requested) THEN RAISE EXCEPTION 'Conversion must allocate whole requested units.'; END IF;
 SELECT COALESCE(sum(a.requested_quantity),0) INTO used FROM public.rfq_allocations a JOIN public.rfq_confirmation_groups cg ON cg.id=a.group_id WHERE a.rfq_item_id=ri.id AND cg.status IN('pending','conversion_failed','confirmed');
 SELECT COALESCE(sum(a.quantity),0) INTO offered_used FROM public.rfq_allocations a JOIN public.rfq_confirmation_groups cg ON cg.id=a.group_id WHERE a.quote_item_id=(line->>'id')::uuid AND cg.status IN('pending','conversion_failed','confirmed');
 IF used+v_requested+ri.cancelled_quantity>ri.quantity OR offered_used+v_qty>(line->>'quantity')::integer THEN RAISE EXCEPTION 'Allocation exceeds remaining requested or quoted quantity.'; END IF;
 IF NOT ri.partial_allowed AND v_requested<>ri.quantity THEN RAISE EXCEPTION 'This requirement does not permit a partial award.'; END IF;
 IF (line->>'alternative')::boolean AND NOT COALESCE((x->>'acceptAlternative')::boolean,false) THEN RAISE EXCEPTION 'Explicitly accept the alternative specification and unit conversion.'; END IF;
 IF (line->>'expiry_date')::date<=GREATEST(current_date,COALESCE(r.expected_delivery_date,current_date))+ri.minimum_shelf_life_days THEN RAISE EXCEPTION 'Quotation no longer meets shelf life.'; END IF;
 INSERT INTO public.rfq_allocations(group_id,rfq_item_id,quote_item_id,product_id,quantity,requested_quantity,unit_price_ghs,alternative_accepted,purchase_category)
 VALUES(g,ri.id,(line->>'id')::uuid,(line->>'product_id')::uuid,v_qty,v_requested,(line->>'final_unit_price_ghs')::numeric,COALESCE((x->>'acceptAlternative')::boolean,false),x->>'category');
 END LOOP;
 -- Checkout groups a product once; do not collapse differing prices/classifications silently.
 IF EXISTS(SELECT 1 FROM public.rfq_allocations WHERE group_id=g GROUP BY product_id HAVING count(DISTINCT unit_price_ghs)>1 OR count(DISTINCT purchase_category)>1) THEN RAISE EXCEPTION 'The same stock product must use one price and classification within an award.'; END IF;
 UPDATE public.rfq_confirmation_groups SET goods_ghs=(SELECT sum(quantity*unit_price_ghs) FROM public.rfq_allocations WHERE group_id=g) WHERE id=g;
 IF EXISTS(SELECT 1 FROM public.wholesaler_order_terms t JOIN public.rfq_confirmation_groups cg ON cg.wholesaler_id=t.wholesaler_id WHERE cg.id=g AND cg.goods_ghs<t.min_order_value_ghs) THEN RAISE EXCEPTION 'Allocated goods do not meet supplier minimum order value.'; END IF;
 groups:=groups||jsonb_build_array(g);
 PERFORM public.rfq_event(r.id,v.wholesaler_id,'AWARD_PROPOSED',jsonb_build_object('groupId',g,'versionId',v.id));
 PERFORM public.notify_business(v.wholesaler_id,ARRAY['owner','manager','cashier','warehouse'],'rfq_award','Award awaiting confirmation',r.title,'/wholesaler/rfqs?rfq='||r.id);
 END LOOP;
 IF (SELECT count(*) FROM public.rfq_allocations WHERE group_id IN(SELECT (value#>>'{}')::uuid FROM jsonb_array_elements(groups)))<>jsonb_array_length(p_allocations) THEN RAISE EXCEPTION 'Unknown quotation version.'; END IF;
 UPDATE public.rfqs SET status='partially_awarded',revision=revision+1,updated_by=auth.uid() WHERE id=r.id;
 INSERT INTO public.rfq_requests VALUES(auth.uid(),p_request_id,v_hash,groups,now());
 RETURN groups;
END $$;

-- Prevent legacy RPCs bypassing the new confirmation/version workflow; old RFQs retain compatibility.
DO $$ DECLARE sig TEXT; d TEXT; needle TEXT:=E'BEGIN\n'; BEGIN
 FOREACH sig IN ARRAY ARRAY['public.award_rfq_lines(uuid,jsonb,boolean)','public.award_rfq_quote(uuid,uuid,boolean)','public.submit_rfq_quote(uuid,uuid,jsonb,text,timestamptz,numeric,integer,text)','public.withdraw_rfq_quote(uuid,uuid)','public.cancel_rfq(uuid)'] LOOP
 d:=replace(pg_get_functiondef(sig::regprocedure),E'\r','');
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'Unexpected legacy RFQ function body: %',sig; END IF;
 d:=overlay(d placing needle||E'  IF EXISTS(SELECT 1 FROM public.rfqs WHERE id=p_rfq_id AND enterprise) THEN RAISE EXCEPTION ''Use the enterprise RFQ workflow.''; END IF;\n' from strpos(d,needle) for length(needle));
 EXECUTE d;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.save_enterprise_quote(UUID,UUID,JSONB,BOOLEAN,INTEGER,UUID),public.propose_rfq_awards(UUID,JSONB,TEXT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_enterprise_quote(UUID,UUID,JSONB,BOOLEAN,INTEGER,UUID),public.propose_rfq_awards(UUID,JSONB,TEXT,UUID) TO authenticated;
COMMIT;
