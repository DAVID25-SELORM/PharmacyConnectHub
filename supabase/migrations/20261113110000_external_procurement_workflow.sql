CREATE FUNCTION public.log_external_event(p_pharmacy UUID,p_purchase UUID,p_action TEXT,p_details JSONB DEFAULT '{}')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN
 INSERT INTO public.external_purchase_events(pharmacy_id,purchase_id,action,actor_id,details)
 VALUES(p_pharmacy,p_purchase,p_action,auth.uid(),p_details);
 -- Follow CRM privacy: commercial/contact details stay in the tenant-only history.
 PERFORM public.write_audit_log(p_action,'Pharmacy','external_purchase',p_purchase,'Private external procurement',
 '{}'::jsonb,_business_id=>p_pharmacy);
END $$;

CREATE FUNCTION public.configure_external_procurement(p_pharmacy_id UUID,p_collect_identity BOOLEAN,p_reviewer UUID DEFAULT NULL,p_enabled BOOLEAN DEFAULT true)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT EXISTS(
 SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND owner_id=auth.uid()) THEN
 RAISE EXCEPTION 'Only the pharmacy owner can configure reviewers.'; END IF;
 INSERT INTO public.external_procurement_settings VALUES(p_pharmacy_id,COALESCE(p_collect_identity,false))
 ON CONFLICT(pharmacy_id) DO UPDATE SET collect_identity=EXCLUDED.collect_identity;
 IF p_reviewer IS NOT NULL THEN
 IF p_enabled THEN
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND owner_id=p_reviewer)
 AND NOT public.is_business_staff(p_reviewer,p_pharmacy_id) THEN RAISE EXCEPTION 'Reviewer must be an active member of this pharmacy.'; END IF;
 INSERT INTO public.external_procurement_reviewers VALUES(p_pharmacy_id,p_reviewer,auth.uid(),now()) ON CONFLICT DO NOTHING;
 ELSE DELETE FROM public.external_procurement_reviewers WHERE pharmacy_id=p_pharmacy_id AND user_id=p_reviewer; END IF;
 END IF;
 PERFORM public.log_external_event(p_pharmacy_id,NULL,'EXTERNAL_POLICY_UPDATED',jsonb_build_object('reviewer',p_reviewer,'enabled',p_enabled,'collect_identity',p_collect_identity));
END $$;

CREATE FUNCTION public.save_external_contact(p_pharmacy_id UUID,p_kind TEXT,p_data JSONB,p_id UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_id UUID; v_identity BOOLEAN; v_phone TEXT:=NULLIF(btrim(p_data->>'phone'),''); BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized to manage procurement contacts.'; END IF;
 IF p_kind IS NULL OR p_kind NOT IN ('person','company') OR length(btrim(COALESCE(p_data->>'name',''))) NOT BETWEEN 2 AND 200 THEN RAISE EXCEPTION 'Choose a contact type and enter a name.'; END IF;
 SELECT collect_identity INTO v_identity FROM public.external_procurement_settings WHERE pharmacy_id=p_pharmacy_id;
 IF NOT COALESCE(v_identity,false) AND (NULLIF(p_data->>'identity_type','') IS NOT NULL OR NULLIF(p_data->>'identity_reference','') IS NOT NULL) THEN RAISE EXCEPTION 'Identity collection is disabled.'; END IF;
 -- Serialize contact matching without taking a business row lock used by foreign keys.
 PERFORM pg_advisory_xact_lock(hashtextextended('external-contact:'||p_pharmacy_id::text,0));
 IF p_kind='person' THEN
 IF v_phone IS NULL THEN RAISE EXCEPTION 'A contact phone is required.'; END IF;
 v_phone:=public.normalize_ghana_phone(v_phone);
 IF p_id IS NULL THEN
 SELECT id INTO v_id FROM public.pharmacy_crm_representatives WHERE pharmacy_id=p_pharmacy_id AND NOT archived
 AND (regexp_replace(phone,'[^0-9]','','g')=regexp_replace(v_phone,'[^0-9]','','g') OR (phone ~ '^0[0-9]{9}$' AND '+233'||substring(phone FROM 2)=v_phone)) AND lower(btrim(name))=lower(btrim(p_data->>'name')) LIMIT 1;
 IF v_id IS NOT NULL THEN RETURN v_id; END IF;
 INSERT INTO public.pharmacy_crm_representatives(pharmacy_id,name,rep_type,phone,email,notes,created_by,updated_by,alternate_phone,location,identity_type,identity_reference)
 VALUES(p_pharmacy_id,btrim(p_data->>'name'),'supplier',v_phone,NULLIF(p_data->>'email',''),p_data->>'notes',auth.uid(),auth.uid(),p_data->>'alternate_phone',p_data->>'location',p_data->>'identity_type',p_data->>'identity_reference') RETURNING id INTO v_id;
 ELSE
 UPDATE public.pharmacy_crm_representatives SET name=btrim(p_data->>'name'),phone=v_phone,email=p_data->>'email',notes=p_data->>'notes',
 alternate_phone=p_data->>'alternate_phone',location=p_data->>'location',updated_by=auth.uid(),updated_at=now(),
 identity_type=CASE WHEN v_identity THEN p_data->>'identity_type' ELSE identity_type END,
 identity_reference=CASE WHEN v_identity THEN p_data->>'identity_reference' ELSE identity_reference END
 WHERE id=p_id AND pharmacy_id=p_pharmacy_id RETURNING id INTO v_id;
 END IF;
 ELSE
 IF p_id IS NULL THEN
 SELECT id INTO v_id FROM public.pharmacy_crm_companies WHERE pharmacy_id=p_pharmacy_id AND NOT archived
 AND lower(btrim(name))=lower(btrim(p_data->>'name')) AND COALESCE(license_reference,'')=COALESCE(p_data->>'license_reference','') LIMIT 1;
 IF v_id IS NOT NULL THEN RETURN v_id; END IF;
 INSERT INTO public.pharmacy_crm_companies(pharmacy_id,name,company_type,phone,location,license_reference,notes,created_by,updated_by)
 VALUES(p_pharmacy_id,btrim(p_data->>'name'),'supplier',v_phone,p_data->>'location',p_data->>'license_reference',p_data->>'notes',auth.uid(),auth.uid()) RETURNING id INTO v_id;
 ELSE UPDATE public.pharmacy_crm_companies SET name=btrim(p_data->>'name'),phone=v_phone,location=p_data->>'location',license_reference=p_data->>'license_reference',notes=p_data->>'notes',updated_by=auth.uid(),updated_at=now()
 WHERE id=p_id AND pharmacy_id=p_pharmacy_id RETURNING id INTO v_id; END IF;
 END IF;
 IF v_id IS NULL THEN RAISE EXCEPTION 'Contact not found in this pharmacy.'; END IF;
 PERFORM public.log_external_event(p_pharmacy_id,NULL,CASE WHEN p_id IS NULL THEN 'EXTERNAL_SUPPLIER_CREATED' ELSE 'EXTERNAL_SUPPLIER_UPDATED' END,jsonb_build_object('contact_id',v_id,'kind',p_kind));
 RETURN v_id;
END $$;

CREATE FUNCTION public.external_procurement_context(p_pharmacy_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$ BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) THEN RAISE EXCEPTION 'Not authorized for this pharmacy.'; END IF;
 RETURN jsonb_build_object(
 'can_record',public.can_act_for_business(p_pharmacy_id,'process'),
 'can_review',public.can_review_external_purchase(p_pharmacy_id),
 'can_pay',public.can_view_accounting(p_pharmacy_id),
 'is_owner',EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND owner_id=auth.uid()),
 'collect_identity',COALESCE((SELECT collect_identity FROM public.external_procurement_settings WHERE pharmacy_id=p_pharmacy_id),false),
 'supplier_stats',COALESCE((SELECT jsonb_object_agg(x.supplier_id,jsonb_build_object('purchases',x.purchases,'spend',x.spend,'last_purchase',x.last_purchase,'unknown_sources',x.unknown_sources)) FROM
 (SELECT COALESCE(seller_contact_id,seller_company_id) supplier_id,count(*) purchases,sum(total_ghs) spend,max(purchase_date) last_purchase,count(*) FILTER(WHERE source_type='unknown') unknown_sources
 FROM public.external_purchases WHERE pharmacy_id=p_pharmacy_id AND COALESCE(seller_contact_id,seller_company_id) IS NOT NULL GROUP BY COALESCE(seller_contact_id,seller_company_id)) x),'{}'),
 'reviewers',COALESCE((SELECT jsonb_agg(user_id) FROM public.external_procurement_reviewers WHERE pharmacy_id=p_pharmacy_id),'[]'),
 'staff',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s.user_id,'name',COALESCE(p.full_name,s.user_id::text))) FROM public.business_staff s LEFT JOIN public.profiles p ON p.id=s.user_id WHERE s.business_id=p_pharmacy_id AND s.status='active'),'[]'),
 -- Procurement receives contact essentials, not the CRM's unrelated private interaction history.
 'people',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'phone',phone,'email',email,'location',location,'alternate_phone',alternate_phone)) FROM public.pharmacy_crm_representatives WHERE pharmacy_id=p_pharmacy_id AND NOT archived),'[]'),
 'companies',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'phone',phone,'location',location,'license_reference',license_reference)) FROM public.pharmacy_crm_companies WHERE pharmacy_id=p_pharmacy_id AND NOT archived),'[]'));
END $$;

CREATE FUNCTION public.save_external_purchase(p_pharmacy_id UUID,p_data JSONB,p_request_id UUID,p_id UUID DEFAULT NULL,p_version INTEGER DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_id UUID; v_old public.external_purchases%ROWTYPE; v_line JSONB; v_batch JSONB; v_item UUID;
 v_seller JSONB:='{}'; v_source JSONB:=COALESCE(p_data->'source','{}'); v_product JSONB; v_qty INTEGER; v_sum INTEGER;
 v_total NUMERIC:=0; v_hash TEXT:=md5(p_data::text); v_stock UUID; v_channel TEXT:=p_data->>'channel';
 v_person UUID:=NULLIF(p_data->>'seller_contact_id','')::uuid; v_company UUID:=NULLIF(p_data->>'seller_company_id','')::uuid;
 v_source_company UUID:=NULLIF(p_data->>'source_company_id','')::uuid; v_wholesaler UUID:=NULLIF(p_data->>'source_wholesaler_id','')::uuid;
BEGIN
 IF NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized to record purchases.'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'A request ID is required.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||p_pharmacy_id::text,0));
 IF p_id IS NULL THEN
 SELECT * INTO v_old FROM public.external_purchases WHERE pharmacy_id=p_pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN IF v_old.request_hash<>v_hash THEN RAISE EXCEPTION 'Request ID already used for different data.'; END IF; RETURN v_old.id; END IF;
 ELSE
 SELECT * INTO v_old FROM public.external_purchases WHERE id=p_id AND pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF NOT FOUND OR v_old.posted_at IS NOT NULL OR v_old.review_status IN ('approved','rejected') THEN RAISE EXCEPTION 'Purchase is not editable. Use a correction or return after posting.'; END IF;
 IF p_version IS DISTINCT FROM v_old.version THEN RAISE EXCEPTION 'Purchase changed. Reload before editing.'; END IF;
 IF EXISTS(SELECT 1 FROM public.external_purchase_returns r JOIN public.external_purchase_batches b ON b.id=r.batch_id JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p_id) THEN RAISE EXCEPTION 'Returned receipts cannot be rewritten.'; END IF;
 END IF;
 IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'items') NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Enter 1 to 200 product lines.'; END IF;
 IF (p_data->>'purchase_date')::date>current_date THEN RAISE EXCEPTION 'Purchase date cannot be in the future.'; END IF;
 IF v_person IS NOT NULL THEN
 SELECT jsonb_build_object('name',name,'phone',phone,'email',email,'location',location) INTO v_seller FROM public.pharmacy_crm_representatives WHERE id=v_person AND pharmacy_id=p_pharmacy_id AND NOT archived;
 IF NOT FOUND THEN RAISE EXCEPTION 'Contact not found in this pharmacy.'; END IF;
 ELSIF v_company IS NOT NULL THEN
 SELECT jsonb_build_object('name',name,'phone',phone,'license_reference',license_reference) INTO v_seller FROM public.pharmacy_crm_companies WHERE id=v_company AND pharmacy_id=p_pharmacy_id AND NOT archived;
 IF NOT FOUND THEN RAISE EXCEPTION 'Company not found in this pharmacy.'; END IF;
 END IF;
 IF v_source_company IS NOT NULL THEN
 SELECT v_source || jsonb_build_object('name',name,'phone',phone,'location',location,'license_reference',license_reference) INTO v_source FROM public.pharmacy_crm_companies WHERE id=v_source_company AND pharmacy_id=p_pharmacy_id AND NOT archived;
 IF NOT FOUND THEN RAISE EXCEPTION 'Original source not found in this pharmacy.'; END IF;
 END IF;
 IF p_data->>'source_type'='platform_wholesaler' THEN
 SELECT v_source || jsonb_build_object('name',name,'phone',phone,'location',city,'license_reference',license_number) INTO v_source FROM public.businesses WHERE id=v_wholesaler AND type='wholesaler' AND verification_status='approved';
 IF NOT FOUND THEN RAISE EXCEPTION 'Select an approved platform wholesaler.'; END IF;
 ELSE v_wholesaler:=NULL; END IF;
 IF p_data->>'source_type'='unknown' THEN v_source:='{}'; v_source_company:=NULL; END IF;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
 v_qty:=(v_line->>'quantity')::integer;
 IF v_qty IS NULL OR v_qty<=0 OR (v_line->>'unit_cost_ghs')::numeric IS NULL OR (v_line->>'unit_cost_ghs')::numeric<0 THEN RAISE EXCEPTION 'Enter a positive quantity and nonnegative cost.'; END IF;
 v_total:=v_total+v_qty*round((v_line->>'unit_cost_ghs')::numeric,2);
 END LOOP;
 IF p_id IS NULL THEN
 INSERT INTO public.external_purchases(pharmacy_id,purchase_date,channel,seller_contact_id,seller_company_id,source_company_id,seller_snapshot,source_snapshot,source_type,source_wholesaler_id,invoice_number,receipt_number,notes,total_ghs,payment_method,due_date,received_by,request_id,request_hash)
 VALUES(p_pharmacy_id,(p_data->>'purchase_date')::date,v_channel,v_person,v_company,v_source_company,v_seller,v_source,p_data->>'source_type',v_wholesaler,NULLIF(btrim(p_data->>'invoice_number'),''),p_data->>'receipt_number',p_data->>'notes',v_total,COALESCE(p_data->>'payment_method','cash'),NULLIF(p_data->>'due_date','')::date,auth.uid(),p_request_id,v_hash) RETURNING id INTO v_id;
 ELSE
 v_id:=p_id;
 IF v_total<COALESCE((SELECT sum(amount_ghs) FROM public.external_purchase_payments WHERE purchase_id=p_id),0) THEN RAISE EXCEPTION 'Reverse excess payments before reducing the purchase amount.'; END IF;
 DELETE FROM public.external_purchase_batches WHERE item_id IN (SELECT id FROM public.external_purchase_items WHERE purchase_id=p_id);
 DELETE FROM public.external_purchase_items WHERE purchase_id=p_id;
 UPDATE public.external_purchases SET purchase_date=(p_data->>'purchase_date')::date,channel=v_channel,seller_contact_id=v_person,seller_company_id=v_company,source_company_id=v_source_company,seller_snapshot=v_seller,source_snapshot=v_source,source_type=p_data->>'source_type',source_wholesaler_id=v_wholesaler,invoice_number=NULLIF(btrim(p_data->>'invoice_number'),''),receipt_number=p_data->>'receipt_number',notes=p_data->>'notes',total_ghs=v_total,payment_method=COALESCE(p_data->>'payment_method','cash'),due_date=NULLIF(p_data->>'due_date','')::date,review_status='draft',verification_status='unverified',reviewed_at=NULL,reviewed_by=NULL,review_notes=NULL,updated_at=now(),version=version+1 WHERE id=v_id;
 END IF;
 FOR v_line IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
 v_stock:=NULLIF(v_line->>'inventory_item_id','')::uuid;
 v_product:=v_line->'product';
 IF NULLIF(v_line->>'master_product_id','') IS NOT NULL THEN
 SELECT jsonb_build_object('name',name,'brand',brand_name,'generic_name',generic_name,'strength',strength,'form',dosage_form,'pack_size',pack_size,'manufacturer',manufacturer) || jsonb_build_object('registration',v_line#>>'{product,registration}','barcode',v_line#>>'{product,barcode}','notes',v_line#>>'{product,notes}') INTO v_product FROM public.master_products WHERE id=(v_line->>'master_product_id')::uuid AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'Catalogue product not found.'; END IF;
 END IF;
 IF NULLIF(btrim(v_product->>'name'),'') IS NULL THEN RAISE EXCEPTION 'Product name is required.'; END IF;
 IF v_stock IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.pharmacy_inventory_items WHERE id=v_stock AND pharmacy_id=p_pharmacy_id AND item_type='medicine' AND active) THEN RAISE EXCEPTION 'Inventory item not available in this pharmacy.'; END IF;
 INSERT INTO public.external_purchase_items(pharmacy_id,purchase_id,master_product_id,inventory_item_id,product_snapshot,quantity,unit_cost_ghs)
 VALUES(p_pharmacy_id,v_id,NULLIF(v_line->>'master_product_id','')::uuid,v_stock,v_product,(v_line->>'quantity')::integer,round((v_line->>'unit_cost_ghs')::numeric,2)) RETURNING id INTO v_item;
 IF jsonb_typeof(v_line->'batches') IS DISTINCT FROM 'array' OR jsonb_array_length(v_line->'batches') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Enter at least one receipt batch per line (unknown details are allowed before review).'; END IF;
 v_sum:=0;
 FOR v_batch IN SELECT value FROM jsonb_array_elements(v_line->'batches') LOOP
 v_qty:=(v_batch->>'quantity')::integer; v_sum:=v_sum+v_qty;
 INSERT INTO public.external_purchase_batches(pharmacy_id,item_id,batch_number,expiry_date,quantity,remaining)
 VALUES(p_pharmacy_id,v_item,NULLIF(btrim(v_batch->>'batch_number'),''),NULLIF(v_batch->>'expiry_date','')::date,v_qty,v_qty);
 END LOOP;
 IF v_sum IS DISTINCT FROM (v_line->>'quantity')::integer THEN RAISE EXCEPTION 'Batch quantities must equal the product quantity.'; END IF;
 END LOOP;
 PERFORM public.log_external_event(p_pharmacy_id,v_id,CASE WHEN p_id IS NULL THEN 'EXTERNAL_PURCHASE_CREATED' ELSE 'EXTERNAL_PURCHASE_UPDATED' END,jsonb_build_object('previous',CASE WHEN p_id IS NOT NULL THEN to_jsonb(v_old) END,'new',p_data));
 IF p_id IS NOT NULL AND v_old.source_snapshot IS DISTINCT FROM v_source THEN PERFORM public.log_external_event(p_pharmacy_id,v_id,'SOURCE_CHANGED',jsonb_build_object('previous',v_old.source_snapshot,'new',v_source)); END IF;
 RETURN v_id;
END $$;

CREATE FUNCTION public.external_document_action(p_purchase_id UUID,p_type TEXT,p_path TEXT,p_filename TEXT,p_remove_id UUID DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ DECLARE p public.external_purchases%ROWTYPE; BEGIN
 SELECT * INTO p FROM public.external_purchases WHERE id=p_purchase_id FOR UPDATE;
 IF NOT FOUND OR NOT public.can_access_external_procurement(p.pharmacy_id) OR NOT public.can_act_for_business(p.pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF p.posted_at IS NOT NULL OR p.review_status='rejected' THEN RAISE EXCEPTION 'Evidence is locked after posting or rejection.'; END IF;
 IF p_remove_id IS NOT NULL THEN
 UPDATE public.external_purchase_documents SET removed_at=now() WHERE id=p_remove_id AND purchase_id=p.id AND removed_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Document not found.'; END IF;
 ELSE
 IF split_part(p_path,'/',1)<>p.pharmacy_id::text OR split_part(p_path,'/',2)<>p.id::text
 OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='external-procurement' AND name=p_path) THEN RAISE EXCEPTION 'Upload the document to this purchase first.'; END IF;
 INSERT INTO public.external_purchase_documents(pharmacy_id,purchase_id,document_type,storage_path,filename,uploaded_by)
 VALUES(p.pharmacy_id,p.id,p_type,p_path,p_filename,auth.uid()) ON CONFLICT(storage_path) DO NOTHING;
 END IF;
 PERFORM public.log_external_event(p.pharmacy_id,p.id,CASE WHEN p_remove_id IS NULL THEN 'DOCUMENT_UPLOADED' ELSE 'DOCUMENT_REMOVED' END,jsonb_build_object('path',p_path,'document_id',p_remove_id));
END $$;

CREATE FUNCTION public.review_external_purchase(p_purchase_id UUID,p_decision TEXT,p_notes TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.external_purchases%ROWTYPE; v_item RECORD; v_batch RECORD; v_stock UUID; v_after INTEGER; v_verification TEXT; BEGIN
 SELECT * INTO p FROM public.external_purchases WHERE id=p_purchase_id FOR UPDATE;
 IF NOT FOUND OR NOT public.can_access_external_procurement(p.pharmacy_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
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
 UPDATE public.pharmacy_inventory_items SET stock=stock+v_batch.remaining WHERE id=v_stock RETURNING stock INTO v_after;
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

CREATE FUNCTION public.adjust_external_batch(p_batch_id UUID,p_quantity INTEGER,p_kind TEXT,p_reason TEXT,p_returned_to TEXT,p_date DATE,p_credit NUMERIC,p_request_id UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE b public.external_purchase_batches%ROWTYPE; i public.external_purchase_items%ROWTYPE; p public.external_purchases%ROWTYPE; r public.external_purchase_returns%ROWTYPE; v_after INTEGER; BEGIN
 SELECT * INTO b FROM public.external_purchase_batches WHERE id=p_batch_id;
 IF NOT FOUND OR NOT public.can_access_external_procurement(b.pharmacy_id) OR NOT public.can_review_external_purchase(b.pharmacy_id) THEN RAISE EXCEPTION 'An assigned active reviewer is required.'; END IF;
 SELECT * INTO i FROM public.external_purchase_items WHERE id=b.item_id;
 SELECT * INTO p FROM public.external_purchases WHERE id=i.purchase_id FOR UPDATE;
 SELECT * INTO b FROM public.external_purchase_batches WHERE id=p_batch_id FOR UPDATE;
 SELECT * INTO r FROM public.external_purchase_returns WHERE pharmacy_id=b.pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN
 IF r.batch_id<>p_batch_id OR r.quantity IS DISTINCT FROM p_quantity OR r.kind IS DISTINCT FROM p_kind OR r.reason IS DISTINCT FROM p_reason OR r.returned_to IS DISTINCT FROM p_returned_to OR r.returned_at IS DISTINCT FROM p_date OR r.credit_ghs IS DISTINCT FROM p_credit THEN RAISE EXCEPTION 'Request ID already used for different data.'; END IF; RETURN r.id; END IF;
 IF p_quantity IS NULL OR p_quantity<=0 OR p_quantity>b.remaining THEN RAISE EXCEPTION 'Quantity exceeds this batch balance.'; END IF;
 IF p_date IS NULL OR p_date<p.purchase_date OR p_date>current_date THEN RAISE EXCEPTION 'Choose a valid movement date.'; END IF;
 IF p_credit IS NULL OR p_credit<0 OR p_credit>round(p_quantity*i.unit_cost_ghs,2) THEN RAISE EXCEPTION 'Credit cannot exceed the returned cost.'; END IF;
 INSERT INTO public.external_purchase_returns(pharmacy_id,batch_id,quantity,reason,returned_to,returned_at,processed_by,kind,credit_ghs,request_id)
 VALUES(b.pharmacy_id,b.id,p_quantity,p_reason,p_returned_to,p_date,auth.uid(),p_kind,p_credit,p_request_id) RETURNING * INTO r;
 UPDATE public.external_purchase_batches SET remaining=remaining-p_quantity,returned=returned+p_quantity WHERE id=b.id;
 IF b.disposition='saleable' THEN
 UPDATE public.pharmacy_inventory_items SET stock=stock-p_quantity WHERE id=i.inventory_item_id RETURNING stock INTO v_after;
 INSERT INTO public.pharmacy_inventory_movements(item_id,pharmacy_id,kind,quantity_delta,stock_after,reason,note,created_by,external_batch_id,external_return_id)
 VALUES(i.inventory_item_id,b.pharmacy_id,'adjust',-p_quantity,v_after,'other',p_reason,auth.uid(),b.id,r.id);
 END IF;
 PERFORM public.log_external_event(b.pharmacy_id,p.id,'EXTERNAL_'||upper(p_kind),to_jsonb(r)); RETURN r.id;
END $$;

CREATE FUNCTION public.record_external_payment(p_purchase_id UUID,p_amount NUMERIC,p_method TEXT,p_reference TEXT,p_paid_at DATE,p_request_id UUID,p_reverses_id UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.external_purchases%ROWTYPE; r public.external_purchase_payments%ROWTYPE; v_id UUID; v_paid NUMERIC; v_credit NUMERIC; BEGIN
 SELECT * INTO p FROM public.external_purchases WHERE id=p_purchase_id FOR UPDATE;
 IF NOT FOUND OR NOT public.can_access_external_procurement(p.pharmacy_id) OR NOT public.can_view_accounting(p.pharmacy_id) THEN RAISE EXCEPTION 'Accounting permission is required.'; END IF;
 SELECT * INTO r FROM public.external_purchase_payments WHERE pharmacy_id=p.pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN
 IF r.purchase_id<>p.id OR r.amount_ghs IS DISTINCT FROM p_amount OR r.method IS DISTINCT FROM p_method OR r.reference IS DISTINCT FROM p_reference OR r.paid_at IS DISTINCT FROM p_paid_at OR r.reverses_id IS DISTINCT FROM p_reverses_id THEN RAISE EXCEPTION 'Request ID already used for different data.'; END IF; RETURN r.id; END IF;
 IF p_paid_at IS NULL OR p_paid_at>current_date THEN RAISE EXCEPTION 'Choose a valid payment date.'; END IF;
 IF p_reverses_id IS NOT NULL THEN
 SELECT * INTO r FROM public.external_purchase_payments WHERE id=p_reverses_id AND purchase_id=p.id AND amount_ghs>0;
 IF NOT FOUND OR p_amount IS DISTINCT FROM -r.amount_ghs THEN RAISE EXCEPTION 'Reverse the exact original payment amount.'; END IF;
 ELSE
 SELECT COALESCE(sum(amount_ghs),0) INTO v_paid FROM public.external_purchase_payments WHERE purchase_id=p.id;
 SELECT COALESCE(sum(ret.credit_ghs),0) INTO v_credit FROM public.external_purchase_returns ret JOIN public.external_purchase_batches b ON b.id=ret.batch_id JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.purchase_id=p.id;
 IF p_amount IS NULL OR p_amount<=0 OR round(p_amount,2)<>p_amount OR p_amount>p.total_ghs-v_paid-v_credit THEN RAISE EXCEPTION 'Payment must be positive and not exceed outstanding credit.'; END IF;
 END IF;
 INSERT INTO public.external_purchase_payments(pharmacy_id,purchase_id,amount_ghs,method,reference,paid_at,recorded_by,request_id,reverses_id)
 VALUES(p.pharmacy_id,p.id,p_amount,p_method,p_reference,p_paid_at,auth.uid(),p_request_id,p_reverses_id) RETURNING id INTO v_id;
 PERFORM public.log_external_event(p.pharmacy_id,p.id,'EXTERNAL_PAYMENT_RECORDED',jsonb_build_object('payment_id',v_id)); RETURN v_id;
END $$;

-- Legacy adjustments/imports may change unbatched stock, but cannot consume a traced lot.
CREATE FUNCTION public.guard_external_batch_balance() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN
 IF NEW.stock < COALESCE((SELECT sum(b.remaining) FROM public.external_purchase_batches b JOIN public.external_purchase_items i ON i.id=b.item_id WHERE i.inventory_item_id=NEW.id AND b.disposition='saleable'),0) THEN
 RAISE EXCEPTION 'This adjustment would consume traced external batches. Use the external procurement batch correction/return action.'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER external_batch_balance BEFORE UPDATE OF stock ON public.pharmacy_inventory_items FOR EACH ROW EXECUTE FUNCTION public.guard_external_batch_balance();

-- Explicit ACLs for every new RPC. Internal writers cannot be invoked by clients.
REVOKE ALL ON FUNCTION public.log_external_event(UUID,UUID,TEXT,JSONB),public.guard_external_batch_balance() FROM PUBLIC,anon,authenticated;
DO $$ DECLARE f RECORD; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN ('configure_external_procurement','save_external_contact','external_procurement_context','save_external_purchase','external_document_action','review_external_purchase','adjust_external_batch','record_external_payment') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f.sig);
 EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.sig);
 END LOOP;
END $$;
