-- Holds support recall investigations after approval; stock and lot disposition move together.
ALTER TABLE public.external_purchase_events ADD COLUMN request_id UUID, ADD COLUMN request_hash TEXT;
CREATE UNIQUE INDEX external_event_request ON public.external_purchase_events(pharmacy_id,request_id) WHERE request_id IS NOT NULL;
CREATE FUNCTION public.hold_external_batch(p_batch_id UUID,p_hold BOOLEAN,p_reason TEXT,p_request_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE lot public.external_purchase_batches%ROWTYPE; line public.external_purchase_items%ROWTYPE;
 receipt public.external_purchases%ROWTYPE; previous_event public.external_purchase_events%ROWTYPE;
 hash TEXT:=md5(jsonb_build_array(p_batch_id,p_hold,p_reason)::text); after_stock INTEGER; delta INTEGER;
BEGIN
 SELECT * INTO lot FROM public.external_purchase_batches WHERE id=p_batch_id;
 IF NOT FOUND OR NOT public.can_review_external_purchase(lot.pharmacy_id) THEN RAISE EXCEPTION 'An assigned active reviewer is required.'; END IF;
 SELECT * INTO line FROM public.external_purchase_items WHERE id=lot.item_id;
 SELECT * INTO receipt FROM public.external_purchases WHERE id=line.purchase_id FOR UPDATE;
 SELECT * INTO lot FROM public.external_purchase_batches WHERE id=p_batch_id FOR UPDATE;
 SELECT * INTO previous_event FROM public.external_purchase_events WHERE pharmacy_id=lot.pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN IF previous_event.request_hash<>hash THEN RAISE EXCEPTION 'Request ID already used for different data.'; END IF; RETURN; END IF;
 IF p_hold IS NULL OR p_request_id IS NULL OR NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'A decision, reason and request ID are required.'; END IF;
 IF receipt.posted_at IS NULL OR lot.disposition='rejected' THEN RAISE EXCEPTION 'Use purchase review before first release.'; END IF;
 IF NOT p_hold AND (lot.expiry_date IS NULL OR lot.expiry_date<=current_date OR receipt.source_type='unknown') THEN RAISE EXCEPTION 'An expired or unverified lot cannot be released.'; END IF;
 delta:=CASE WHEN p_hold AND lot.disposition='saleable' THEN -lot.remaining WHEN NOT p_hold AND lot.disposition='quarantine' THEN lot.remaining ELSE 0 END;
 IF delta<0 THEN UPDATE public.external_purchase_batches SET disposition='quarantine' WHERE id=lot.id; END IF;
 IF delta<>0 THEN
 UPDATE public.pharmacy_inventory_items SET stock=stock+delta WHERE id=line.inventory_item_id RETURNING stock INTO after_stock;
 INSERT INTO public.pharmacy_inventory_movements(item_id,pharmacy_id,kind,quantity_delta,stock_after,reason,note,created_by,external_batch_id)
 VALUES(line.inventory_item_id,lot.pharmacy_id,'adjust',delta,after_stock,'other',p_reason,auth.uid(),lot.id);
 END IF;
 UPDATE public.external_purchase_batches SET disposition=CASE WHEN p_hold THEN 'quarantine' ELSE 'saleable' END WHERE id=lot.id;
 UPDATE public.external_purchases SET review_status=CASE WHEN EXISTS(SELECT 1 FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=receipt.id AND b.disposition='quarantine' AND b.remaining>0) THEN 'quarantined' ELSE 'approved' END,
 review_notes=p_reason,reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now(),version=version+1 WHERE id=receipt.id;
 UPDATE public.external_purchases SET verification_status=CASE WHEN review_status='quarantined' THEN 'quarantined' ELSE 'verified' END WHERE id=receipt.id;
 INSERT INTO public.external_purchase_events(pharmacy_id,purchase_id,action,actor_id,details,request_id,request_hash)
 VALUES(lot.pharmacy_id,receipt.id,CASE WHEN p_hold THEN 'BATCH_QUARANTINED' ELSE 'BATCH_RELEASED' END,auth.uid(),jsonb_build_object('batch_id',lot.id,'reason',p_reason,'delta',delta),p_request_id,hash);
 PERFORM public.write_audit_log('External batch disposition changed','Pharmacy','external_purchase',receipt.id,'Private external procurement','{}',_business_id=>lot.pharmacy_id);
END $$;
REVOKE ALL ON FUNCTION public.hold_external_batch(UUID,BOOLEAN,TEXT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.hold_external_batch(UUID,BOOLEAN,TEXT,UUID) TO authenticated;

CREATE FUNCTION public.external_history_immutable() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$ BEGIN
 RAISE EXCEPTION 'External procurement history is append-only. Record a reversal or correction.';
END $$;
CREATE TRIGGER external_payments_immutable BEFORE UPDATE OR DELETE ON public.external_purchase_payments FOR EACH ROW EXECUTE FUNCTION public.external_history_immutable();
CREATE TRIGGER external_returns_immutable BEFORE UPDATE OR DELETE ON public.external_purchase_returns FOR EACH ROW EXECUTE FUNCTION public.external_history_immutable();
CREATE TRIGGER external_events_immutable BEFORE UPDATE OR DELETE ON public.external_purchase_events FOR EACH ROW EXECUTE FUNCTION public.external_history_immutable();
REVOKE ALL ON FUNCTION public.external_history_immutable() FROM PUBLIC,anon,authenticated;
