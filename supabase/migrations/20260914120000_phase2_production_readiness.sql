-- Forward-only Phase 2. Review phase2_read_only_review.sql before a future authorized rollout.
BEGIN;

-- Platform membership is authoritative. Preserve legacy records for manual review.
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID,_role public.app_role)
RETURNS BOOLEAN LANGUAGE SQL STABLE SECURITY DEFINER SET search_path=public AS $$
  SELECT CASE WHEN _role='admin' THEN EXISTS(SELECT 1 FROM public.platform_staff WHERE user_id=_user_id AND status='active')
    ELSE EXISTS(SELECT 1 FROM public.user_roles WHERE user_id=_user_id AND role=_role) END
$$;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON public.platform_staff,public.user_roles FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.phase2_platform_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Deactivate administrators through the controlled operation; owners cannot be removed.'; END IF;
  IF TG_OP='UPDATE' THEN
    IF ROW(NEW.id,NEW.user_id) IS DISTINCT FROM ROW(OLD.id,OLD.user_id) OR NEW.role<>OLD.role THEN
      RAISE EXCEPTION 'Platform membership identity and owner role are immutable.';
    END IF;
    IF OLD.role='owner' AND NEW.status<>'active' THEN RAISE EXCEPTION 'Protected owner must remain active.'; END IF;
    IF NEW.status='active' AND OLD.joined_at IS NULL AND OLD.role<>'owner' AND auth.uid() IS DISTINCT FROM NEW.user_id THEN
      RAISE EXCEPTION 'The invited account must accept platform membership.';
    END IF;
  END IF;
  IF NEW.status<>'inactive' AND (EXISTS(SELECT 1 FROM public.businesses WHERE owner_id=NEW.user_id)
    OR EXISTS(SELECT 1 FROM public.business_staff WHERE user_id=NEW.user_id AND status IN ('active','pending'))) THEN
    RAISE EXCEPTION 'Tenant and platform memberships must remain separate.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_platform_guard BEFORE INSERT OR UPDATE OR DELETE ON public.platform_staff
FOR EACH ROW EXECUTE FUNCTION public.phase2_platform_guard();
CREATE FUNCTION public.manage_platform_member(_user_id UUID,_status TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE p public.platform_staff%ROWTYPE; v_id UUID;
BEGIN
  IF NOT coalesce(public.is_platform_owner(auth.uid()),false) THEN RAISE EXCEPTION 'Only the platform owner can manage platform membership.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('platform-membership',0));
  SELECT * INTO p FROM public.platform_staff WHERE user_id=_user_id FOR UPDATE;
  IF FOUND THEN
    IF p.role='owner' THEN RAISE EXCEPTION 'Protected owner cannot be changed by invitations or role management.'; END IF;
    IF _status NOT IN ('active','inactive') OR _status IS NULL OR (p.joined_at IS NULL AND _status='active') THEN
      RAISE EXCEPTION 'Pending members must accept their invitation.';
    END IF;
    UPDATE public.platform_staff SET status=_status::public.staff_status WHERE id=p.id;
    RETURN p.id;
  END IF;
  IF _status IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'New platform membership must be pending.'; END IF;
  INSERT INTO public.platform_staff(user_id,role,status,invited_by) VALUES(_user_id,'admin','pending',auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END $$;
CREATE FUNCTION public.accept_platform_invitation() RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=auth.uid() AND email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'Verified account required.'; END IF;
  UPDATE public.platform_staff SET status='active',joined_at=now() WHERE user_id=auth.uid() AND status='pending' AND role='admin';
END $$;
REVOKE ALL ON FUNCTION public.manage_platform_member(UUID,TEXT),public.accept_platform_invitation(),public.phase2_platform_guard() FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.manage_platform_member(UUID,TEXT),public.accept_platform_invitation() TO authenticated;

-- Privileged audit insertion stays internal. Caller-supplied actor/email arguments are ignored.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON public.audit_logs FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.write_audit_log(_activity TEXT,_organization TEXT,_record_type TEXT,_record_id UUID,_record_label TEXT,
  _details JSONB DEFAULT '{}',_performed_by UUID DEFAULT auth.uid(),_performed_by_email TEXT DEFAULT public.current_actor_email(),
  _ip_address TEXT DEFAULT public.current_request_ip_address()) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE actor UUID;
BEGIN
  actor:=auth.uid();
  IF actor IS NULL THEN SELECT actor_id INTO actor FROM public.inventory_operation_context WHERE transaction_id=txid_current(); END IF;
  IF actor IS NULL THEN SELECT actor_id INTO actor FROM public.server_audit_context WHERE transaction_id=txid_current(); END IF;
  INSERT INTO public.audit_logs(activity,organization,performed_by,performed_by_email,record_type,record_id,record_label,details,ip_address)
  VALUES(_activity,_organization,actor,(SELECT email FROM auth.users WHERE id=actor),_record_type,_record_id,_record_label,coalesce(_details,'{}'),public.current_request_ip_address());
END $$;
REVOKE ALL ON FUNCTION public.write_audit_log(TEXT,TEXT,TEXT,UUID,TEXT,JSONB,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER phase2_audit_immutable BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
CREATE FUNCTION public.phase2_inventory_audit() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  INSERT INTO public.audit_logs(activity,organization,performed_by,performed_by_email,record_type,record_id,details)
  VALUES(NEW.movement_type,NEW.wholesaler_id::TEXT,NEW.actor_id,(SELECT email FROM auth.users WHERE id=NEW.actor_id),
    'inventory_movement',NEW.id,jsonb_build_object('order_id',NEW.order_id,'product_id',NEW.product_id,'delta',NEW.quantity_delta));
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_inventory_audit AFTER INSERT ON public.inventory_movements FOR EACH ROW EXECUTE FUNCTION public.phase2_inventory_audit();

-- Conservative identity v2: preserve punctuation, strength and all meaningful text.
DROP INDEX public.products_import_identity_idx;
CREATE OR REPLACE FUNCTION public.product_import_identity(name TEXT,brand TEXT,form TEXT,pack_size TEXT)
RETURNS TEXT LANGUAGE SQL IMMUTABLE SET search_path=public AS $$
  SELECT 'v2:'||jsonb_build_array(
    regexp_replace(lower(btrim(coalesce(name,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(brand,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(form,''))), '\s+', ' ', 'g'),
    regexp_replace(lower(btrim(coalesce(pack_size,''))), '\s+', ' ', 'g'))::TEXT
$$;
CREATE INDEX products_import_identity_idx ON public.products(wholesaler_id,public.product_import_identity(name,brand,form,pack_size));
CREATE FUNCTION public.phase2_identity_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
DECLARE identity TEXT;
BEGIN
  identity:=public.product_import_identity(NEW.name,NEW.brand,NEW.form,NEW.pack_size);
  IF TG_OP='UPDATE' AND identity=public.product_import_identity(OLD.name,OLD.brand,OLD.form,OLD.pack_size) THEN RETURN NEW; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.wholesaler_id::TEXT||identity,0));
  IF EXISTS(SELECT 1 FROM public.products p WHERE p.wholesaler_id=NEW.wholesaler_id AND p.id<>NEW.id
    AND public.product_import_identity(p.name,p.brand,p.form,p.pack_size)=identity) THEN
    RAISE EXCEPTION 'Product identity already exists or is ambiguous. Review existing products instead of creating a duplicate.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_identity_guard BEFORE INSERT OR UPDATE OF name,brand,form,pack_size ON public.products
FOR EACH ROW EXECUTE FUNCTION public.phase2_identity_guard();
CREATE FUNCTION public.phase2_offer_supplier_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.products p WHERE p.id=NEW.id AND p.wholesaler_id=NEW.wholesaler_id) THEN
    RAISE EXCEPTION 'Offer supplier must equal product supplier.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_offer_supplier_guard BEFORE INSERT OR UPDATE ON public.wholesaler_products
FOR EACH ROW EXECUTE FUNCTION public.phase2_offer_supplier_guard();
REVOKE INSERT,UPDATE,DELETE ON public.wholesaler_products,public.master_products FROM service_role;

-- Private immutable document versions. Existing versions are explicitly unreviewed.
ALTER TABLE public.license_documents ADD COLUMN version_id UUID NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN reviewed_by UUID, ADD COLUMN reviewed_at TIMESTAMPTZ, ADD COLUMN review_status TEXT NOT NULL DEFAULT 'pending';
CREATE TABLE public.license_document_versions (
  version_id UUID PRIMARY KEY, document_id UUID NOT NULL, business_id UUID NOT NULL,
  doc_type TEXT NOT NULL, storage_path TEXT NOT NULL, uploaded_at TIMESTAMPTZ NOT NULL,
  reviewed_by UUID, reviewed_at TIMESTAMPTZ, review_status TEXT NOT NULL
);
INSERT INTO public.license_document_versions SELECT version_id,id,business_id,doc_type,storage_path,uploaded_at,reviewed_by,reviewed_at,review_status FROM public.license_documents;
ALTER TABLE public.license_document_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.license_document_versions FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON public.license_document_versions TO authenticated;
CREATE POLICY version_reader ON public.license_document_versions FOR SELECT TO authenticated USING
  (public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=business_id AND b.owner_id=auth.uid()));
CREATE TRIGGER phase2_document_history_immutable BEFORE UPDATE OR DELETE ON public.license_document_versions
FOR EACH ROW EXECUTE FUNCTION public.phase1_inventory_history_immutable();
UPDATE storage.buckets SET public=false,file_size_limit=10485760,allowed_mime_types=ARRAY['application/pdf','image/jpeg','image/png'] WHERE id='licenses';
-- No overwrite/delete policies: each upload is a unique object; old evidence is retained.
DO $$ DECLARE p RECORD; BEGIN
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname='storage' AND tablename='objects' LOOP
    IF p.policyname IN ('Users upload own license docs','Users read own license docs','Admins read all license docs','Users delete own license docs') THEN
      EXECUTE format('DROP POLICY %I ON storage.objects',p.policyname);
    END IF;
  END LOOP;
END $$;
CREATE POLICY phase2_license_boundary ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
USING(bucket_id<>'licenses' OR public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b
  WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid() AND auth.uid()::TEXT=(storage.foldername(objects.name))[1]))
WITH CHECK(bucket_id<>'licenses' OR (auth.uid()::TEXT=(storage.foldername(objects.name))[1] AND EXISTS(SELECT 1 FROM public.businesses b
  WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())));
CREATE POLICY phase2_license_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='licenses' AND
  (public.has_role(auth.uid(),'admin') OR EXISTS(SELECT 1 FROM public.businesses b WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())));
CREATE POLICY phase2_license_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='licenses'
  AND auth.uid()::TEXT=(storage.foldername(objects.name))[1] AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id::TEXT=(storage.foldername(objects.name))[2] AND b.owner_id=auth.uid())
  AND name ~ '\.(pdf|png|jpg|jpeg)$');
CREATE POLICY phase2_license_no_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO authenticated USING(bucket_id<>'licenses');
CREATE POLICY phase2_license_no_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO authenticated USING(bucket_id<>'licenses');
REVOKE UPDATE ON public.license_documents FROM PUBLIC,anon,authenticated,service_role;
GRANT UPDATE(storage_path) ON public.license_documents TO authenticated;
CREATE FUNCTION public.phase2_document_guard() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF TG_OP='UPDATE' AND NEW.storage_path=OLD.storage_path THEN RETURN NEW; END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='licenses' AND o.name=NEW.storage_path
    AND (storage.foldername(o.name))[2]=NEW.business_id::TEXT) THEN RAISE EXCEPTION 'Document metadata requires an existing object in this business folder.'; END IF;
  NEW.version_id:=gen_random_uuid();NEW.uploaded_at:=now();NEW.reviewed_by:=NULL;NEW.reviewed_at:=NULL;NEW.review_status:='pending';
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_document_guard BEFORE INSERT OR UPDATE ON public.license_documents FOR EACH ROW EXECUTE FUNCTION public.phase2_document_guard();
CREATE FUNCTION public.phase2_document_audit() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  INSERT INTO public.license_document_versions VALUES(NEW.version_id,NEW.id,NEW.business_id,NEW.doc_type,NEW.storage_path,NEW.uploaded_at,NEW.reviewed_by,NEW.reviewed_at,NEW.review_status) ON CONFLICT DO NOTHING;
  PERFORM public.write_audit_log('Verification evidence changed',NEW.business_id::TEXT,'license_document',NEW.id,NEW.doc_type,
    jsonb_build_object('version_id',NEW.version_id,'review_status',NEW.review_status,'reviewer',NEW.reviewed_by,'reviewed_at',NEW.reviewed_at,'storage_path',NEW.storage_path));
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_document_audit AFTER INSERT OR UPDATE ON public.license_documents FOR EACH ROW EXECUTE FUNCTION public.phase2_document_audit();

-- Payment transition and durable receipt scheduling share one transaction.
CREATE TABLE public.receipt_outbox (
  order_id UUID PRIMARY KEY REFERENCES public.orders(id), status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending','sending','sent','failed','uncertain')),
  requested_by UUID NOT NULL, payload JSONB, attempts INTEGER NOT NULL DEFAULT 0,
  first_attempt_at TIMESTAMPTZ, lease_until TIMESTAMPTZ, claim_id UUID, sent_at TIMESTAMPTZ,
  provider_id TEXT, last_error TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.receipt_outbox ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.receipt_outbox FROM PUBLIC,anon,authenticated,service_role;
REVOKE UPDATE(receipt_sent_at,receipt_sent_to) ON public.orders FROM service_role;
CREATE OR REPLACE FUNCTION public.confirm_order_payment(_order_id UUID) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first.'; END IF;
  SELECT * INTO o FROM public.orders WHERE id=_order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=o.wholesaler_id AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=auth.uid() OR public.get_staff_role(auth.uid(),b.id) IN ('owner','manager','cashier'))) THEN RAISE EXCEPTION 'Order access denied.'; END IF;
  IF o.status<>'delivered' OR o.payment_method<>'cod' OR o.payment_status NOT IN ('unpaid','paid') THEN
    RAISE EXCEPTION 'Only delivered unpaid COD orders can be confirmed.';
  END IF;
  IF o.payment_status='unpaid' THEN
    UPDATE public.orders SET payment_status='paid',paid_at=now(),payment_confirmed_at=now(),payment_confirmed_by=auth.uid() WHERE id=_order_id;
  END IF;
  INSERT INTO public.receipt_outbox(order_id,requested_by,status,sent_at)
    VALUES(_order_id,auth.uid(),CASE WHEN o.receipt_sent_at IS NULL THEN 'pending' ELSE 'sent' END,o.receipt_sent_at) ON CONFLICT DO NOTHING;
  RETURN _order_id;
END $$;
CREATE FUNCTION public.claim_order_receipt(_order_id UUID,_caller_id UUID,_payload JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders%ROWTYPE; job public.receipt_outbox%ROWTYPE;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id=_order_id FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=o.wholesaler_id AND b.type='wholesaler' AND b.verification_status='approved'
    AND (b.owner_id=_caller_id OR public.get_staff_role(_caller_id,b.id) IN ('owner','manager','cashier'))) THEN RAISE EXCEPTION 'Receipt access denied.'; END IF;
  IF o.status<>'delivered' OR o.payment_status<>'paid' THEN RAISE EXCEPTION 'Receipt requires delivered paid order.'; END IF;
  INSERT INTO public.receipt_outbox(order_id,requested_by,status,sent_at) VALUES(o.id,_caller_id,
    CASE WHEN o.receipt_sent_at IS NULL THEN 'pending' ELSE 'sent' END,o.receipt_sent_at) ON CONFLICT DO NOTHING;
  SELECT * INTO job FROM public.receipt_outbox WHERE order_id=o.id FOR UPDATE;
  IF job.status='sent' THEN RETURN jsonb_build_object('status','sent'); END IF;
  IF job.lease_until>now() THEN RETURN jsonb_build_object('status','sending'); END IF;
  -- Provider keys expire after 24h. Unknown outcomes must not automatically resend outside that window.
  IF job.first_attempt_at<now()-interval '23 hours' THEN
    UPDATE public.receipt_outbox SET status='uncertain' WHERE order_id=o.id;
    RETURN jsonb_build_object('status','uncertain');
  END IF;
  UPDATE public.receipt_outbox SET status='sending',payload=coalesce(payload,_payload),attempts=attempts+1,
    first_attempt_at=coalesce(first_attempt_at,now()),lease_until=now()+interval '2 minutes',claim_id=gen_random_uuid()
    WHERE order_id=o.id RETURNING * INTO job;
  RETURN jsonb_build_object('status','claimed','claim_id',job.claim_id,'payload',job.payload);
END $$;
CREATE FUNCTION public.finish_order_receipt(_order_id UUID,_claim_id UUID,_provider_id TEXT,_error TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE job public.receipt_outbox%ROWTYPE;
BEGIN
  SELECT * INTO job FROM public.receipt_outbox WHERE order_id=_order_id FOR UPDATE;
  IF NOT FOUND OR job.claim_id IS DISTINCT FROM _claim_id OR job.status<>'sending' THEN RAISE EXCEPTION 'Receipt lease no longer owned.'; END IF;
  UPDATE public.receipt_outbox SET status=CASE WHEN _error IS NULL THEN 'sent' ELSE 'failed' END,
    sent_at=CASE WHEN _error IS NULL THEN now() END,provider_id=_provider_id,last_error=_error,lease_until=NULL WHERE order_id=_order_id;
  IF _error IS NULL THEN UPDATE public.orders SET receipt_sent_at=now(),receipt_sent_to=job.payload->>'toEmail' WHERE id=_order_id; END IF;
  INSERT INTO public.audit_logs(activity,performed_by,record_type,record_id,details)
    VALUES(CASE WHEN _error IS NULL THEN 'Receipt sent' ELSE 'Receipt retry required' END,job.requested_by,'order',_order_id,jsonb_build_object('provider_id',_provider_id));
END $$;
REVOKE ALL ON FUNCTION public.claim_order_receipt(UUID,UUID,JSONB),public.finish_order_receipt(UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_order_receipt(UUID,UUID,JSONB),public.finish_order_receipt(UUID,UUID,TEXT,TEXT) TO service_role;

-- Version-bound review; client must supply the evidence versions shown to the reviewer.
CREATE FUNCTION public.review_business_evidence(_business_id UUID,_status public.verification_status,_versions UUID[],_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE actual UUID[];
BEGIN
  IF NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Administrator required.'; END IF;
  PERFORM 1 FROM public.businesses WHERE id=_business_id FOR UPDATE;
  PERFORM 1 FROM public.license_documents WHERE business_id=_business_id FOR UPDATE;
  SELECT coalesce(array_agg(version_id ORDER BY version_id),'{}') INTO actual FROM public.license_documents WHERE business_id=_business_id;
  IF actual IS DISTINCT FROM ARRAY(SELECT unnest(coalesce(_versions,'{}'::UUID[])) ORDER BY 1) THEN RAISE EXCEPTION 'Evidence changed. Reload and review the current documents.'; END IF;
  IF _status NOT IN ('approved','rejected') OR (_status='rejected' AND nullif(btrim(_reason),'') IS NULL) THEN RAISE EXCEPTION 'Review decision and rejection reason required.'; END IF;
  IF EXISTS(SELECT 1 FROM public.license_documents d WHERE d.business_id=_business_id AND NOT EXISTS
    (SELECT 1 FROM storage.objects o WHERE o.bucket_id='licenses' AND o.name=d.storage_path)) THEN RAISE EXCEPTION 'Review blocked: evidence object is missing.'; END IF;
  UPDATE public.license_documents SET reviewed_by=auth.uid(),reviewed_at=now(),review_status=_status::TEXT WHERE business_id=_business_id;
  UPDATE public.businesses SET verification_status=_status,rejection_reason=CASE WHEN _status='rejected' THEN _reason ELSE NULL END WHERE id=_business_id;
END $$;
CREATE FUNCTION public.phase2_review_guard() RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public AS $$
BEGIN
  IF NEW.verification_status='approved' AND OLD.verification_status<>'approved' AND EXISTS
    (SELECT 1 FROM public.license_documents d WHERE d.business_id=NEW.id AND (d.review_status<>'approved' OR d.reviewed_by IS NULL OR d.reviewed_at IS NULL)) THEN
    RAISE EXCEPTION 'Current evidence must be reviewed before approval.';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER phase2_review_guard BEFORE UPDATE ON public.businesses FOR EACH ROW EXECUTE FUNCTION public.phase2_review_guard();
REVOKE ALL ON FUNCTION public.review_business_evidence(UUID,public.verification_status,UUID[],TEXT) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.review_business_evidence(UUID,public.verification_status,UUID[],TEXT) TO authenticated;

CREATE TABLE public.server_audit_context(transaction_id BIGINT PRIMARY KEY,actor_id UUID NOT NULL);
ALTER TABLE public.server_audit_context ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.server_audit_context FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.change_business_staff(_caller_id UUID,_business_id UUID,_user_id UUID,_role public.staff_role,_status public.staff_status,_invite BOOLEAN DEFAULT FALSE)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE member public.business_staff%ROWTYPE;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=_business_id AND
    (b.owner_id=_caller_id OR public.get_staff_role(_caller_id,b.id) IN ('owner','manager'))) THEN RAISE EXCEPTION 'Staff access denied.'; END IF;
  IF _role='owner' THEN RAISE EXCEPTION 'Owner membership is protected.'; END IF;
  IF _status<>'inactive' AND EXISTS(SELECT 1 FROM public.platform_staff WHERE user_id=_user_id AND status IN ('pending','active')) THEN RAISE EXCEPTION 'Platform and tenant membership conflict.'; END IF;
  INSERT INTO public.server_audit_context VALUES(txid_current(),_caller_id);
  SELECT * INTO member FROM public.business_staff WHERE business_id=_business_id AND user_id=_user_id FOR UPDATE;
  IF _invite THEN
    IF FOUND OR _status<>'pending' THEN RAISE EXCEPTION 'Invitation cannot overwrite existing membership.'; END IF;
    INSERT INTO public.business_staff(business_id,user_id,role,status,invited_by) VALUES(_business_id,_user_id,_role,'pending',_caller_id);
  ELSE
    IF NOT FOUND OR member.role='owner' THEN RAISE EXCEPTION 'Membership unavailable or protected.'; END IF;
    UPDATE public.business_staff SET role=_role,status=_status WHERE id=member.id;
  END IF;
  DELETE FROM public.server_audit_context WHERE transaction_id=txid_current();
END $$;
REVOKE ALL ON FUNCTION public.change_business_staff(UUID,UUID,UUID,public.staff_role,public.staff_status,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.change_business_staff(UUID,UUID,UUID,public.staff_role,public.staff_status,BOOLEAN) TO service_role;
-- Harden execution on all internal trigger helpers introduced here.
REVOKE ALL ON FUNCTION public.phase2_inventory_audit(),public.phase2_identity_guard(),public.phase2_offer_supplier_guard(),
  public.phase2_document_guard(),public.phase2_document_audit(),public.phase2_review_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.list_marketplace_catalogue()
RETURNS JSONB LANGUAGE SQL STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT coalesce(jsonb_agg(entry ORDER BY entry->>'name'), '[]'::JSONB) FROM (
    SELECT jsonb_build_object('id', m.id, 'name', m.name, 'generic_name', m.generic_name,
      'strength', m.strength, 'brand_name', m.brand_name, 'dosage_form', m.dosage_form,
      'pack_size', m.pack_size, 'category', c.name, 'offers', (
        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          'minimum_order_quantity', w.minimum_order_quantity, 'lead_time_days', w.lead_time_days,
          'wholesaler', jsonb_build_object('id', b.id, 'name', b.name, 'city', b.city, 'region', b.region, 'verification_status', b.verification_status)) ORDER BY p.price_ghs, p.id)
        FROM public.wholesaler_products w JOIN public.products p ON p.id = w.id
        JOIN public.businesses b ON b.id = w.wholesaler_id
        WHERE w.product_id = m.id AND w.wholesaler_id=p.wholesaler_id AND public.product_import_identity(m.name,m.brand_name,m.dosage_form,m.pack_size)=public.product_import_identity(p.name,p.brand,p.form,p.pack_size) AND w.active AND p.active AND b.verification_status = 'approved'
      )) entry
    FROM public.master_products m LEFT JOIN public.product_categories c ON c.id = m.category_id
    WHERE m.active AND auth.uid() IS NOT NULL
  ) catalogue WHERE entry->'offers' IS NOT NULL AND entry->'offers' <> 'null'::JSONB
$$;
REVOKE ALL ON FUNCTION public.list_marketplace_catalogue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_marketplace_catalogue() TO authenticated;

CREATE OR REPLACE FUNCTION public.preview_wholesaler_import(
  _business_id UUID, _products JSONB, _mode TEXT,
  _confirm_token TEXT DEFAULT NULL, _request_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_product public.products%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_price NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.product_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = _business_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'wholesaler' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved wholesaler account is required.';
  END IF;
  IF NOT (biz.owner_id = auth.uid() OR COALESCE(public.get_staff_role(auth.uid(), _business_id)::TEXT IN ('owner', 'manager'), FALSE)) THEN
    RAISE EXCEPTION 'Only owners and managers can import products.';
  END IF;
  IF _mode NOT IN ('replace', 'add', 'details') OR _mode IS NULL THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(_products) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected a product array.'; END IF;
  IF jsonb_array_length(_products) = 0 OR jsonb_array_length(_products) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 products at a time.';
  END IF;
  payload_hash := md5(_products::TEXT || _mode || _business_id::TEXT);
  IF _confirm_token IS NOT NULL THEN
    IF _request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    -- Serialize commits against imports, manual edits, and order stock updates.
    -- This short transaction lock also protects missing rows (new products).
    LOCK TABLE public.products IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.product_import_runs WHERE id = _request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.wholesaler_id <> _business_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(_products) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR nullif(btrim(item->>'name'), '') IS NULL
      OR coalesce(item->>'price_ghs', '') !~ '^[0-9]+([.][0-9]{1,2})?$'
      OR (item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$') THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Invalid name, price or stock.'));
      CONTINUE;
    END IF;
    input_price := (item->>'price_ghs')::NUMERIC;
    IF input_price <= 0 OR input_price > 99999999.99 OR COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Price or stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    identity_key := public.product_import_identity(item->>'name', item->>'brand', coalesce(nullif(item->>'form', ''), ''), item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated product identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);
    SELECT count(*) INTO matches FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing products match. Resolve the catalogue collision first.'));
      CONTINUE;
    END IF;
    SELECT * INTO old_product FROM public.products p WHERE p.wholesaler_id = _business_id
      AND public.product_import_identity(p.name, p.brand, p.form, p.pack_size) = identity_key;
    new_stock := CASE
      WHEN _mode = 'details' THEN coalesce(old_product.stock, 0)
      WHEN input_stock IS NULL THEN coalesce(old_product.stock, 0)
      WHEN _mode = 'add' THEN coalesce(old_product.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;
    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_product.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_product.id IS NULL THEN 'new' ELSE 'existing' END,
      'before', CASE WHEN old_product.id IS NULL THEN NULL ELSE to_jsonb(old_product) END,
      'price_before', old_product.price_ghs, 'price_after', input_price,
      'stock_before', old_product.stock, 'stock_after', new_stock,
      'product', item
    ));
  END LOOP;
  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', _mode);
  IF _confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF _confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  INSERT INTO public.inventory_operation_context(transaction_id,actor_id,movement_type,import_run_id,request_id)
    VALUES(txid_current(),auth.uid(),CASE WHEN _mode='add' THEN 'import_add' ELSE 'import_replace' END,_request_id,_request_id);
  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.products (wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, image_hue, active)
      VALUES (_business_id, item->>'name', nullif(btrim(item#>>'{product,brand}'), ''),
        coalesce(nullif(item#>>'{product,category}', ''), 'Other'), coalesce(nullif(item#>>'{product,form}', ''), ''),
        nullif(btrim(item#>>'{product,pack_size}'), ''), (item->>'price_after')::NUMERIC, (item->>'stock_after')::INTEGER,
        coalesce((item#>>'{product,image_hue}')::INTEGER, 200), TRUE) RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.products SET name = item->>'name', brand = nullif(btrim(item#>>'{product,brand}'), ''),
        category = coalesce(nullif(item#>>'{product,category}', ''), 'Other'), form = coalesce(nullif(item#>>'{product,form}', ''), ''),
        pack_size = nullif(btrim(item#>>'{product,pack_size}'), ''), price_ghs = (item->>'price_after')::NUMERIC,
        stock = (item->>'stock_after')::INTEGER, image_hue = coalesce((item#>>'{product,image_hue}')::INTEGER, 200)
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;
    PERFORM public.write_audit_log('Inventory imported', biz.name, 'product', saved_id, item->>'name',
      jsonb_build_object('request_id', _request_id, 'mode', _mode, 'before', item->'before',
        'after', (SELECT to_jsonb(p) FROM public.products p WHERE p.id = saved_id)));
  END LOOP;
  DELETE FROM public.inventory_operation_context WHERE transaction_id=txid_current();
  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.product_import_runs(id, wholesaler_id, created_by, payload_hash, result)
    VALUES (_request_id, _business_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

COMMIT;
