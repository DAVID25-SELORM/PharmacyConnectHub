-- Require the displayed revision for every review action; evidence participates in revisioning.
DROP FUNCTION public.review_external_purchase(UUID,TEXT,TEXT);
CREATE OR REPLACE FUNCTION public.review_external_purchase(p_purchase_id UUID,p_decision TEXT,p_notes TEXT DEFAULT NULL,p_version INTEGER DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.external_purchases%ROWTYPE; v_item RECORD; v_batch RECORD; v_stock UUID; v_after INTEGER; v_verification TEXT; BEGIN
 SELECT * INTO p FROM public.external_purchases WHERE id=p_purchase_id FOR UPDATE;
 IF NOT FOUND OR NOT public.can_access_external_procurement(p.pharmacy_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF p_version IS DISTINCT FROM p.version THEN RAISE EXCEPTION 'Purchase or evidence changed. Reload and review the current revision.'; END IF;
 IF p_decision IS NULL OR p_decision NOT IN ('submit','approved','quarantined','rejected','needs_information') THEN RAISE EXCEPTION 'Invalid review decision.'; END IF;
 IF p_decision='submit' THEN
 IF NOT public.can_act_for_business(p.pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized to submit.'; END IF;
 IF p.posted_at IS NOT NULL OR p.review_status='rejected' THEN RAISE EXCEPTION 'Purchase is locked.'; END IF;
 UPDATE public.external_purchases SET review_status=CASE WHEN source_type='unknown' THEN 'quarantined' ELSE 'awaiting_review' END,
 verification_status=CASE WHEN source_type='unknown' THEN 'unverified' ELSE 'partially_verified' END,
 review_notes=CASE WHEN source_type='unknown' THEN 'Original source could not be established.' END,version=version+1,updated_at=now() WHERE id=p.id;
 PERFORM public.log_external_event(p.pharmacy_id,p.id,'PURCHASE_SUBMITTED_FOR_REVIEW'); RETURN;
 END IF;
 IF NOT public.can_review_external_purchase(p.pharmacy_id) THEN RAISE EXCEPTION 'An assigned active reviewer is required.'; END IF;
 IF p_decision='approved' AND p.posted_at IS NOT NULL THEN RETURN; END IF;
 IF p.posted_at IS NOT NULL OR p.review_status IN ('draft','rejected') THEN RAISE EXCEPTION 'Submit the purchase before review; posted/rejected records are locked.'; END IF;
 IF NULLIF(btrim(p_notes),'') IS NULL THEN RAISE EXCEPTION 'Review notes are required.'; END IF;
 IF p_decision='approved' THEN
 IF p.source_type='unknown' OR NULLIF(btrim(p.source_snapshot->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Original source must be established before approval.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.external_purchase_documents WHERE purchase_id=p.id AND removed_at IS NULL AND document_type IN ('supplier_invoice','product_invoice','purchase_receipt')) THEN RAISE EXCEPTION 'Supporting invoice or purchase receipt is required.'; END IF;
 IF EXISTS(SELECT 1 FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id AND (b.batch_number IS NULL OR b.expiry_date IS NULL OR b.expiry_date<=current_date)) THEN RAISE EXCEPTION 'Every batch needs a number and future expiry date.'; END IF;
 -- Lock all existing inventory in deterministic order, then post each source lot once.
 PERFORM 1 FROM public.pharmacy_inventory_items WHERE pharmacy_id=p.pharmacy_id ORDER BY id FOR UPDATE;
 FOR v_item IN SELECT * FROM public.external_purchase_items WHERE purchase_id=p.id ORDER BY id LOOP
 v_stock:=v_item.inventory_item_id;
 IF v_stock IS NULL THEN
 SELECT id INTO v_stock FROM public.pharmacy_inventory_items WHERE pharmacy_id=p.pharmacy_id AND item_type='medicine'
 AND public.product_import_identity(name,brand,form,pack_size)=public.product_import_identity(v_item.product_snapshot->>'name',v_item.product_snapshot->>'brand',v_item.product_snapshot->>'form',v_item.product_snapshot->>'pack_size');
 IF v_stock IS NOT NULL THEN RAISE EXCEPTION 'An existing inventory item matches %. Edit the draft and explicitly select it before approval.',v_item.product_snapshot->>'name'; END IF;
 INSERT INTO public.pharmacy_inventory_items(pharmacy_id,name,brand,form,pack_size,generic_name,strength,manufacturer,barcode,unit_cost_ghs)
 VALUES(p.pharmacy_id,v_item.product_snapshot->>'name',v_item.product_snapshot->>'brand',v_item.product_snapshot->>'form',v_item.product_snapshot->>'pack_size',v_item.product_snapshot->>'generic_name',v_item.product_snapshot->>'strength',v_item.product_snapshot->>'manufacturer',v_item.product_snapshot->>'barcode',v_item.unit_cost_ghs) RETURNING id INTO v_stock;
 UPDATE public.external_purchase_items SET inventory_item_id=v_stock WHERE id=v_item.id;
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pharmacy_inventory_items WHERE id=v_stock AND pharmacy_id=p.pharmacy_id AND active) THEN RAISE EXCEPTION 'Inventory item is inactive or belongs to another pharmacy.'; END IF;
 FOR v_batch IN SELECT * FROM public.external_purchase_batches WHERE item_id=v_item.id ORDER BY id FOR UPDATE LOOP
 IF v_batch.remaining>0 THEN
 UPDATE public.pharmacy_inventory_items SET unit_cost_ghs=round((stock*COALESCE(unit_cost_ghs,v_item.unit_cost_ghs)+v_batch.remaining*v_item.unit_cost_ghs)/NULLIF(stock+v_batch.remaining,0),4), stock=stock+v_batch.remaining WHERE id=v_stock RETURNING stock INTO v_after;
 UPDATE public.external_purchase_batches SET disposition='saleable' WHERE id=v_batch.id;
 INSERT INTO public.pharmacy_inventory_movements(item_id,pharmacy_id,kind,quantity_delta,stock_after,note,created_by,external_batch_id)
 VALUES(v_stock,p.pharmacy_id,'receive',v_batch.remaining,v_after,p.reference,auth.uid(),v_batch.id);
 END IF;
 END LOOP;
 END LOOP;
 v_verification:='verified';
 PERFORM public.log_external_event(p.pharmacy_id,p.id,'INVENTORY_POSTED');
 ELSE
 v_verification:=CASE WHEN p_decision='rejected' THEN 'rejected' WHEN p.source_type='unknown' THEN 'unverified' WHEN p_decision='quarantined' THEN 'quarantined' ELSE 'partially_verified' END;
 UPDATE public.external_purchase_batches SET disposition=CASE WHEN p_decision='rejected' THEN 'rejected' ELSE 'quarantine' END WHERE item_id IN(SELECT id FROM public.external_purchase_items WHERE purchase_id=p.id);
 END IF;
 UPDATE public.external_purchases SET review_status=p_decision,verification_status=v_verification,reviewed_by=auth.uid(),reviewed_at=now(),review_notes=p_notes,
 posted_at=CASE WHEN p_decision='approved' THEN now() END,updated_at=now(),version=version+1 WHERE id=p.id;
 PERFORM public.log_external_event(p.pharmacy_id,p.id,'PURCHASE_'||upper(p_decision),jsonb_build_object('previous',p.review_status,'verification',v_verification,'notes',p_notes));
 PERFORM public.log_external_event(p.pharmacy_id,p.id,'VERIFICATION_STATUS_CHANGED',jsonb_build_object('previous',p.verification_status,'new',v_verification));
END $$;


REVOKE ALL ON FUNCTION public.review_external_purchase(UUID,TEXT,TEXT,INTEGER) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_external_purchase(UUID,TEXT,TEXT,INTEGER) TO authenticated;
CREATE FUNCTION public.revise_external_evidence() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 UPDATE public.external_purchases SET version=version+1,updated_at=now() WHERE id=NEW.purchase_id;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.revise_external_evidence() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER revise_external_evidence AFTER INSERT OR UPDATE ON public.external_purchase_documents FOR EACH ROW EXECUTE FUNCTION public.revise_external_evidence();

-- Consumption is distinct from supplier returns and preserves the receipt's original quantity.
ALTER TABLE public.external_purchase_batches ADD COLUMN consumed INTEGER NOT NULL DEFAULT 0 CHECK(consumed>=0);
ALTER TABLE public.external_purchase_batches ADD CONSTRAINT external_batch_consumed_balance CHECK(remaining+returned+consumed<=quantity);
CREATE FUNCTION public.consume_external_batch(p_batch_id UUID,p_quantity INTEGER,p_reason TEXT,p_request_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE lot public.external_purchase_batches%ROWTYPE; line public.external_purchase_items%ROWTYPE;
 receipt public.external_purchases%ROWTYPE; previous_event public.external_purchase_events%ROWTYPE;
 hash TEXT:=md5(jsonb_build_array('consume',p_batch_id,p_quantity,p_reason)::text); after_stock INTEGER;
BEGIN
 SELECT * INTO lot FROM public.external_purchase_batches WHERE id=p_batch_id;
 IF NOT FOUND OR NOT public.can_access_external_procurement(lot.pharmacy_id) OR NOT public.can_act_for_business(lot.pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized to consume stock.'; END IF;
 SELECT * INTO line FROM public.external_purchase_items WHERE id=lot.item_id;
 SELECT * INTO receipt FROM public.external_purchases WHERE id=line.purchase_id FOR UPDATE;
 SELECT * INTO lot FROM public.external_purchase_batches WHERE id=p_batch_id FOR UPDATE;
 SELECT * INTO previous_event FROM public.external_purchase_events WHERE pharmacy_id=lot.pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN IF previous_event.request_hash IS DISTINCT FROM hash THEN RAISE EXCEPTION 'Request ID already used for different data.'; END IF; RETURN; END IF;
 IF p_request_id IS NULL OR p_quantity IS NULL OR p_quantity<=0 OR p_quantity>lot.remaining OR NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Enter an available quantity, reason and request ID.'; END IF;
 IF receipt.posted_at IS NULL OR lot.disposition<>'saleable' OR lot.expiry_date IS NULL OR lot.expiry_date<=current_date THEN RAISE EXCEPTION 'Only released, unexpired stock can be consumed.'; END IF;
 UPDATE public.external_purchase_batches SET remaining=remaining-p_quantity,consumed=consumed+p_quantity WHERE id=lot.id;
 UPDATE public.pharmacy_inventory_items SET stock=stock-p_quantity WHERE id=line.inventory_item_id RETURNING stock INTO after_stock;
 INSERT INTO public.pharmacy_inventory_movements(item_id,pharmacy_id,kind,quantity_delta,stock_after,reason,note,created_by,external_batch_id)
 VALUES(line.inventory_item_id,lot.pharmacy_id,'adjust',-p_quantity,after_stock,'other',p_reason,auth.uid(),lot.id);
 INSERT INTO public.external_purchase_events(pharmacy_id,purchase_id,action,actor_id,details,request_id,request_hash)
 VALUES(lot.pharmacy_id,receipt.id,'BATCH_CONSUMED',auth.uid(),jsonb_build_object('batch_id',lot.id,'quantity',p_quantity,'reason',p_reason),p_request_id,hash);
 PERFORM public.write_audit_log('External batch consumed','Pharmacy','external_purchase',receipt.id,'Private external procurement','{}',_business_id=>lot.pharmacy_id);
END $$;
REVOKE ALL ON FUNCTION public.consume_external_batch(UUID,INTEGER,TEXT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.consume_external_batch(UUID,INTEGER,TEXT,UUID) TO authenticated;

DROP FUNCTION public.external_procurement_analytics(UUID,DATE,DATE,TEXT,INTEGER,INTEGER);
CREATE FUNCTION public.external_procurement_analytics(p_pharmacy_id UUID,p_from DATE DEFAULT NULL,p_to DATE DEFAULT NULL,p_query TEXT DEFAULT '',p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 100,p_filters JSONB DEFAULT '{}')
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$ DECLARE v JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 WITH lines AS (
 SELECT p.id purchase_id,p.reference,p.purchase_date date,p.channel,p.seller_snapshot->>'name' seller,p.source_snapshot->>'name' source,
 i.product_snapshot->>'name' product,i.product_snapshot->>'manufacturer' manufacturer,i.quantity,
 COALESCE((SELECT sum(r.quantity) FROM public.external_purchase_returns r JOIN public.external_purchase_batches b ON b.id=r.batch_id WHERE b.item_id=i.id AND r.kind='return'),0)::integer returned,
 i.unit_cost_ghs unit_cost,p.verification_status verification,p.review_status review,p.invoice_number invoice,
 (SELECT string_agg(COALESCE(b.batch_number,'Unknown'),' / ' ORDER BY b.id) FROM public.external_purchase_batches b WHERE b.item_id=i.id) batches,
 i.id line_id,i.master_product_id,
 COALESCE('master:'||i.master_product_id::text,'inventory:'||i.inventory_item_id::text,'local:'||md5((i.product_snapshot - 'notes' - 'registration' - 'barcode')::text)) product_key,
 COALESCE(p.seller_company_id::text,p.seller_contact_id::text,p.id::text) supplier_key
 FROM public.external_purchases p JOIN public.external_purchase_items i ON i.purchase_id=p.id
 WHERE p.pharmacy_id=p_pharmacy_id AND p.review_status NOT IN ('draft','rejected')
 UNION ALL
 SELECT o.id,o.order_number,o.created_at::date,'marketplace',w.name,w.name,oi.product_name,mp.manufacturer,
 public.order_item_fulfilled_qty(oi.id),COALESCE((SELECT sum(ri.quantity_accepted) FROM public.order_return_items ri JOIN public.order_returns ret ON ret.id=ri.return_id WHERE ri.order_item_id=oi.id AND ret.status='resolved'),0)::integer,
 public.order_item_effective_price(oi.id),'marketplace',o.status::text,o.order_number,NULL,oi.id,wp.product_id,COALESCE('master:'||wp.product_id::text,'marketplace:'||oi.product_id::text),w.id::text
 FROM public.orders o JOIN public.order_items oi ON oi.order_id=o.id JOIN public.businesses w ON w.id=o.wholesaler_id
 LEFT JOIN public.wholesaler_products wp ON wp.id=oi.product_id
 LEFT JOIN public.master_products mp ON mp.id=wp.product_id
 WHERE o.pharmacy_id=p_pharmacy_id AND o.status::text<>'cancelled'
 ), filtered AS (SELECT * FROM lines WHERE (p_from IS NULL OR date>=p_from) AND (p_to IS NULL OR date<=p_to)
 AND (NULLIF(p_filters->>'product','') IS NULL OR product ILIKE '%'||(p_filters->>'product')||'%')
 AND (NULLIF(p_filters->>'manufacturer','') IS NULL OR manufacturer ILIKE '%'||(p_filters->>'manufacturer')||'%')
 AND (NULLIF(p_filters->>'minimum_price','') IS NULL OR unit_cost>=(p_filters->>'minimum_price')::numeric)
 AND (NULLIF(p_filters->>'maximum_price','') IS NULL OR unit_cost<=(p_filters->>'maximum_price')::numeric)
 AND (COALESCE(p_query,'')='' OR concat_ws(' ',product,seller,source,batches,manufacturer,reference) ILIKE '%'||p_query||'%')),
 page AS(SELECT * FROM filtered ORDER BY date DESC,line_id DESC LIMIT LEAST(GREATEST(p_limit,1),200) OFFSET GREATEST(p_offset,0))
 SELECT jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(page ORDER BY date DESC,line_id DESC) FROM page),'[]'),
 'count',(SELECT count(*) FROM filtered),
 'products',COALESCE((SELECT jsonb_agg(x ORDER BY product,seller) FROM (
 SELECT product_key,supplier_key,max(product) product,max(seller) seller,channel,sum(quantity) units,
 round(sum(quantity*unit_cost)/NULLIF(sum(quantity),0),2) weighted_average,
 min(unit_cost) minimum_price,max(unit_cost) maximum_price,
 (array_agg(unit_cost ORDER BY date DESC,line_id DESC))[1] last_price,max(date) last_purchase
 FROM filtered WHERE quantity>0 GROUP BY product_key,supplier_key,channel) x),'[]'),
 'channels',COALESCE((SELECT jsonb_agg(x) FROM (SELECT channel,sum(quantity) units,sum(returned) returned,sum(quantity*unit_cost) gross_cost FROM filtered GROUP BY channel) x),'[]')) INTO v;
 RETURN v;
END $$;


CREATE OR REPLACE FUNCTION public.list_external_purchases(p_pharmacy_id UUID,p_filters JSONB DEFAULT '{}',p_offset INTEGER DEFAULT 0,p_limit INTEGER DEFAULT 30)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_result JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized for this pharmacy.'; END IF;
 WITH filtered AS (
 SELECT p.*, (SELECT count(*) FROM public.external_purchase_documents d WHERE d.purchase_id=p.id AND d.removed_at IS NULL) document_count,
 (SELECT count(*) FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id AND b.disposition='quarantine' AND b.remaining>0) quarantine_batches
 FROM public.external_purchase_balances p WHERE p.pharmacy_id=p_pharmacy_id
 AND (NULLIF(p_filters->>'from','') IS NULL OR p.purchase_date>=(p_filters->>'from')::date)
 AND (NULLIF(p_filters->>'to','') IS NULL OR p.purchase_date<=(p_filters->>'to')::date)
 AND (NOT (p_filters ?| array['product','manufacturer','minimum_price','maximum_price']) OR EXISTS(
 SELECT 1 FROM public.external_purchase_items i WHERE i.purchase_id=p.id
 AND (NULLIF(p_filters->>'product','') IS NULL OR i.product_snapshot->>'name' ILIKE '%'||(p_filters->>'product')||'%')
 AND (NULLIF(p_filters->>'manufacturer','') IS NULL OR i.product_snapshot->>'manufacturer' ILIKE '%'||(p_filters->>'manufacturer')||'%')
 AND (NULLIF(p_filters->>'minimum_price','') IS NULL OR i.unit_cost_ghs>=(p_filters->>'minimum_price')::numeric)
 AND (NULLIF(p_filters->>'maximum_price','') IS NULL OR i.unit_cost_ghs<=(p_filters->>'maximum_price')::numeric)))
 AND (NULLIF(p_filters->>'channel','') IS NULL OR p.channel=p_filters->>'channel')
 AND (NULLIF(p_filters->>'verification','') IS NULL OR p.verification_status=p_filters->>'verification')
 AND (NULLIF(p_filters->>'review','') IS NULL OR p.review_status=p_filters->>'review')
 AND (NULLIF(p_filters->>'payment','') IS NULL OR (p_filters->>'payment'='outstanding' AND p.outstanding_ghs>0) OR p.payment_status=p_filters->>'payment')
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


-- Consolidated read model; payment ledgers remain separate because external contacts are not platform businesses.
CREATE FUNCTION public.procurement_payables(p_pharmacy_id UUID) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_view_accounting(p_pharmacy_id) THEN RAISE EXCEPTION 'Accounting permission is required.'; END IF;
 WITH external AS (SELECT * FROM public.external_purchase_balances WHERE pharmacy_id=p_pharmacy_id AND review_status NOT IN ('draft','rejected')),
 market AS (SELECT * FROM public.credit_aging_summary(p_pharmacy_id)),
 aging AS (SELECT m.bucket,m.outstanding_ghs marketplace_ghs,COALESCE(sum(GREATEST(e.outstanding_ghs,0)),0) external_ghs
 FROM market m LEFT JOIN external e ON public.credit_aging_bucket(e.due_date,current_date)=m.bucket GROUP BY m.bucket,m.outstanding_ghs)
 SELECT jsonb_build_object('aging',(SELECT jsonb_agg(a) FROM aging a),
 'marketplace_total',(SELECT COALESCE(sum(outstanding_ghs),0) FROM market),
 'external_total',(SELECT COALESCE(sum(GREATEST(outstanding_ghs,0)),0) FROM external),
 'supplier_credit',(SELECT COALESCE(sum(GREATEST(-outstanding_ghs,0)),0) FROM external),
 'suppliers',COALESCE((SELECT jsonb_agg(s) FROM (SELECT COALESCE(seller_company_id::text,seller_contact_id::text,id::text) supplier_id,
 max(seller_snapshot->>'name') supplier,count(*) invoices,sum(total_ghs) purchased,sum(paid_ghs) paid,sum(credit_ghs) credited,sum(outstanding_ghs) outstanding
 FROM external GROUP BY COALESCE(seller_company_id::text,seller_contact_id::text,id::text)) s),'[]')) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_payables(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_payables(UUID) TO authenticated;

CREATE FUNCTION public.external_workspace_summary(p_filters JSONB DEFAULT '{}') RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'summary',public.list_external_purchases(b.id,p_filters,0,1)->'summary') ORDER BY b.name),'[]') INTO result
 FROM public.businesses b WHERE b.type='pharmacy' AND public.can_access_external_procurement(b.id);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.external_workspace_summary(JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.external_workspace_summary(JSONB) TO authenticated;
CREATE FUNCTION public.external_supplier_profile(p_pharmacy_id UUID,p_supplier_id UUID) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 WITH receipts AS (SELECT * FROM public.external_purchase_balances WHERE pharmacy_id=p_pharmacy_id AND (seller_contact_id=p_supplier_id OR seller_company_id=p_supplier_id)),
 lines AS (SELECT i.* FROM public.external_purchase_items i JOIN receipts p ON p.id=i.purchase_id)
 SELECT jsonb_build_object(
 'sources',COALESCE((SELECT jsonb_agg(s) FROM (SELECT source_snapshot->>'name' source,source_type,count(*) purchases,max(purchase_date) latest FROM receipts GROUP BY source_snapshot->>'name',source_type) s),'[]'),
 'products',COALESCE((SELECT jsonb_agg(x) FROM (SELECT product_snapshot->>'name' product,sum(quantity) quantity,sum(quantity*unit_cost_ghs) cost FROM lines GROUP BY product_snapshot->>'name') x),'[]'),
 'documents',COALESCE((SELECT jsonb_agg(d) FROM (SELECT p.reference,p.id purchase_id,d.filename,d.document_type FROM receipts p JOIN public.external_purchase_documents d ON d.purchase_id=p.id WHERE d.removed_at IS NULL ORDER BY d.uploaded_at DESC LIMIT 100) d),'[]'),
 'balance',CASE WHEN public.can_view_accounting(p_pharmacy_id) THEN (SELECT COALESCE(sum(outstanding_ghs),0) FROM receipts WHERE review_status NOT IN ('draft','rejected')) END) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.external_supplier_profile(UUID,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.external_supplier_profile(UUID,UUID) TO authenticated;

REVOKE ALL ON FUNCTION public.external_procurement_analytics(UUID,DATE,DATE,TEXT,INTEGER,INTEGER,JSONB) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.external_procurement_analytics(UUID,DATE,DATE,TEXT,INTEGER,INTEGER,JSONB) TO authenticated;
CREATE FUNCTION public.external_supplier_statement(p_pharmacy_id UUID,p_supplier_id UUID) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result JSONB; BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_view_accounting(p_pharmacy_id) THEN RAISE EXCEPTION 'Accounting permission is required.'; END IF;
 WITH receipts AS (SELECT * FROM public.external_purchases WHERE pharmacy_id=p_pharmacy_id AND (seller_company_id=p_supplier_id OR seller_contact_id=p_supplier_id) AND review_status NOT IN ('draft','rejected')),
 entries AS (
 SELECT p.purchase_date date,p.created_at recorded_at,p.id entry_id,p.reference,'purchase' kind,p.total_ghs debit,0::numeric credit FROM receipts p
 UNION ALL SELECT x.paid_at,x.created_at,x.id,p.reference,CASE WHEN x.amount_ghs<0 THEN 'payment reversal' ELSE 'payment' END,0,x.amount_ghs FROM public.external_purchase_payments x JOIN receipts p ON p.id=x.purchase_id
 UNION ALL SELECT r.returned_at,r.created_at,r.id,p.reference,'supplier credit',0,r.credit_ghs FROM public.external_purchase_returns r JOIN public.external_purchase_batches b ON b.id=r.batch_id JOIN public.external_purchase_items i ON i.id=b.item_id JOIN receipts p ON p.id=i.purchase_id WHERE r.credit_ghs<>0),
 statement AS (SELECT *,sum(debit-credit) OVER(ORDER BY date,recorded_at,entry_id ROWS UNBOUNDED PRECEDING) balance FROM entries)
 SELECT COALESCE(jsonb_agg(s ORDER BY date,recorded_at,entry_id),'[]') INTO result FROM statement s; RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.external_supplier_statement(UUID,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.external_supplier_statement(UUID,UUID) TO authenticated;
