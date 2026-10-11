-- Deploy before the matching client/API. No historical transaction backfill.
BEGIN;
CREATE TABLE public.document_branding_assets (
 path text PRIMARY KEY, business_id uuid NOT NULL REFERENCES public.businesses(id),
 uploaded_by uuid REFERENCES auth.users(id), byte_size integer NOT NULL CHECK(byte_size BETWEEN 1 AND 2097152),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.document_branding_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id),
 actor_id uuid REFERENCES auth.users(id), action text NOT NULL, details jsonb NOT NULL DEFAULT '{}',
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.document_branding_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_branding_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.document_branding_assets, public.document_branding_events FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.document_branding_assets, public.document_branding_events TO service_role;
GRANT SELECT ON public.document_branding_events TO authenticated;
CREATE FUNCTION public.can_manage_document_branding(p_business_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND public.can_act_for_business(p_business_id,'manage');
$$;
REVOKE ALL ON FUNCTION public.can_manage_document_branding(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_manage_document_branding(uuid) TO authenticated;
CREATE POLICY "Managers read branding history" ON public.document_branding_events FOR SELECT TO authenticated
 USING(public.can_manage_document_branding(business_id));

-- Only the validated server upload endpoint writes logo objects. Referenced objects are retained.
DROP POLICY IF EXISTS "Business managers upload document logos" ON storage.objects;
DROP POLICY IF EXISTS "Business managers replace document logos" ON storage.objects;
DROP POLICY IF EXISTS "Business managers remove document logos" ON storage.objects;
CREATE POLICY "Validated logo writes only" ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
 USING(bucket_id <> 'business-document-logos') WITH CHECK(bucket_id <> 'business-document-logos');

-- Guard all settings writers, including the legacy RPC. Existing protected values remain readable.
CREATE FUNCTION public.guard_document_branding() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF TG_OP='INSERT' THEN
   IF NEW.payment_instructions IS NOT NULL OR NEW.signatory_name IS NOT NULL OR NEW.signatory_title IS NOT NULL THEN
     RAISE EXCEPTION 'Payment and signature configuration requires a separate authorized workflow.';
   END IF;
 ELSE
   IF NEW.payment_instructions IS DISTINCT FROM OLD.payment_instructions OR NEW.signatory_name IS DISTINCT FROM OLD.signatory_name OR NEW.signatory_title IS DISTINCT FROM OLD.signatory_title THEN
     RAISE EXCEPTION 'Payment and signature configuration requires a separate authorized workflow.';
   END IF;
 END IF;
 IF COALESCE(NEW.display_name,'') ~ '[<>]' OR COALESCE(NEW.footer_note,'') ~ '[<>]' THEN RAISE EXCEPTION 'Use plain text without markup.'; END IF;
 IF NEW.logo_path IS NOT NULL AND (TG_OP='INSERT' OR NEW.logo_path IS DISTINCT FROM OLD.logo_path) AND NOT EXISTS(
   SELECT 1 FROM public.document_branding_assets a WHERE a.path=NEW.logo_path AND a.business_id=NEW.business_id
 ) THEN RAISE EXCEPTION 'Upload a validated logo for this business first.'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guard_document_branding BEFORE INSERT OR UPDATE ON public.business_document_branding FOR EACH ROW EXECUTE FUNCTION public.guard_document_branding();
CREATE FUNCTION public.audit_document_branding() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 INSERT INTO public.document_branding_events(business_id,actor_id,action,details)
 VALUES(NEW.business_id,auth.uid(),'branding_saved',jsonb_build_object('previous',CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD)-'payment_instructions' ELSE NULL END,'current',to_jsonb(NEW)-'payment_instructions'));
 RETURN NEW;
END $$;
CREATE TRIGGER audit_document_branding AFTER INSERT OR UPDATE ON public.business_document_branding FOR EACH ROW EXECUTE FUNCTION public.audit_document_branding();

-- Presentation-only entry point preserves protected legacy fields.
CREATE FUNCTION public.save_document_presentation(p_business_id uuid,p_display_name text,p_logo_path text,p_accent_color text,p_show_license boolean,p_show_secondary_contact boolean,p_footer_note text)
RETURNS public.business_document_branding LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE existing public.business_document_branding;
BEGIN
 IF NOT public.can_manage_document_branding(p_business_id) THEN RAISE EXCEPTION 'Business manager permission is required.'; END IF;
 SELECT * INTO existing FROM public.business_document_branding WHERE business_id=p_business_id FOR UPDATE;
 IF existing.business_id IS NOT NULL THEN
 UPDATE public.business_document_branding SET display_name=NULLIF(btrim(p_display_name),''),logo_path=NULLIF(btrim(p_logo_path),''),accent_color=p_accent_color,show_license=COALESCE(p_show_license,true),show_secondary_contact=COALESCE(p_show_secondary_contact,true),footer_note=NULLIF(btrim(p_footer_note),'') WHERE business_id=p_business_id RETURNING * INTO existing;
 RETURN existing;
 END IF;
 RETURN public.save_business_document_branding(p_business_id,p_display_name,p_logo_path,p_accent_color,p_show_license,p_show_secondary_contact,p_footer_note);
END $$;
REVOKE ALL ON FUNCTION public.save_document_presentation(uuid,text,text,text,boolean,boolean,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_document_presentation(uuid,text,text,text,boolean,boolean,text) TO authenticated;

CREATE TABLE public.document_identity_snapshots (
 document_kind text NOT NULL, document_id uuid NOT NULL, issuer_id uuid NOT NULL REFERENCES public.businesses(id),
 recipient_id uuid REFERENCES public.businesses(id), identity jsonb NOT NULL,
 template_version text NOT NULL DEFAULT 'classic-v1', captured_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(document_kind,document_id)
);
ALTER TABLE public.document_identity_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.document_identity_snapshots FROM PUBLIC,anon,authenticated;
-- Reads are exposed through transaction-authorized readers; no client snapshot mutations.
CREATE FUNCTION public.document_identity(p_business_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT jsonb_build_object('id',b.id,'name',b.name,'address',b.address,'city',b.city,'region',b.region,'phone',b.phone,'public_email',b.public_email,'license_number',b.license_number,
 'branding',COALESCE(to_jsonb(br)-'business_id'-'created_at'-'updated_at','{}'::jsonb))
 FROM public.businesses b LEFT JOIN public.business_document_branding br ON br.business_id=b.id WHERE b.id=p_business_id;
$$;
REVOKE ALL ON FUNCTION public.document_identity(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.capture_order_document_identity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF TG_OP='INSERT' THEN
 INSERT INTO public.document_identity_snapshots(document_kind,document_id,issuer_id,recipient_id,identity)
 VALUES('pharmacy',NEW.id,NEW.pharmacy_id,NEW.wholesaler_id,public.document_identity(NEW.pharmacy_id)),
 ('invoice',NEW.id,NEW.wholesaler_id,NEW.pharmacy_id,public.document_identity(NEW.wholesaler_id)) ON CONFLICT DO NOTHING;
 END IF;
 IF NEW.status::text='dispatched' AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
 INSERT INTO public.document_identity_snapshots(document_kind,document_id,issuer_id,recipient_id,identity)
 VALUES('delivery',NEW.id,NEW.wholesaler_id,NEW.pharmacy_id,public.document_identity(NEW.wholesaler_id)) ON CONFLICT DO NOTHING;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER capture_order_document_identity AFTER INSERT OR UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.capture_order_document_identity();
CREATE FUNCTION public.get_order_document_identity(p_order_id uuid,p_kind text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders; snapshot jsonb; bid uuid;
BEGIN
 SELECT * INTO o FROM public.orders WHERE id=p_order_id;
 IF o.id IS NULL OR auth.uid() IS NULL OR NOT(public.can_act_for_business(o.pharmacy_id,'read') OR public.can_act_for_business(o.wholesaler_id,'read')) THEN RAISE EXCEPTION 'Order access required.'; END IF;
 IF p_kind NOT IN('pharmacy','invoice','delivery','pick-pack') THEN RAISE EXCEPTION 'Unsupported document.'; END IF;
 SELECT identity INTO snapshot FROM public.document_identity_snapshots WHERE document_id=o.id AND document_kind=p_kind;
 bid:=CASE WHEN p_kind='pharmacy' THEN o.pharmacy_id ELSE o.wholesaler_id END;
 RETURN jsonb_build_object('issuer',COALESCE(snapshot,public.document_identity(bid)),'historical',snapshot IS NOT NULL,'template_version','classic-v1');
END $$;
REVOKE ALL ON FUNCTION public.get_order_document_identity(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_order_document_identity(uuid,text) TO authenticated;

CREATE FUNCTION public.capture_rfq_document_identity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE bid uuid; kind text;
BEGIN
 IF TG_TABLE_NAME='rfqs' THEN
   IF NEW.submitted_at IS NULL OR (TG_OP='UPDATE' AND OLD.submitted_at IS NOT NULL) THEN RETURN NEW; END IF;
   bid:=NEW.pharmacy_id; kind:='rfq';
 ELSIF TG_TABLE_NAME='rfq_quote_versions' THEN bid:=NEW.wholesaler_id; kind:='quotation';
 ELSE SELECT pharmacy_id INTO bid FROM public.rfqs WHERE id=NEW.rfq_id; kind:='award';
 END IF;
 INSERT INTO public.document_identity_snapshots(document_kind,document_id,issuer_id,identity)
 VALUES(kind,NEW.id,bid,public.document_identity(bid)) ON CONFLICT DO NOTHING;
 RETURN NEW;
END $$;
CREATE TRIGGER capture_rfq_identity AFTER INSERT OR UPDATE OF submitted_at ON public.rfqs FOR EACH ROW EXECUTE FUNCTION public.capture_rfq_document_identity();
CREATE TRIGGER capture_quote_identity AFTER INSERT ON public.rfq_quote_versions FOR EACH ROW EXECUTE FUNCTION public.capture_rfq_document_identity();
CREATE TRIGGER capture_award_identity AFTER INSERT ON public.rfq_confirmation_groups FOR EACH ROW EXECUTE FUNCTION public.capture_rfq_document_identity();
ALTER FUNCTION public.rfq_document(uuid,uuid,uuid) RENAME TO rfq_document_before_branding;
REVOKE ALL ON FUNCTION public.rfq_document_before_branding(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.rfq_document(p_rfq_id uuid,p_version_id uuid DEFAULT NULL,p_group_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE result jsonb; saved jsonb; kind text; did uuid;
BEGIN
 result:=public.rfq_document_before_branding(p_rfq_id,p_version_id,p_group_id);
 kind:=CASE WHEN p_group_id IS NOT NULL THEN 'award' WHEN p_version_id IS NOT NULL THEN 'quotation' ELSE 'rfq' END;
 did:=COALESCE(p_group_id,p_version_id,p_rfq_id);
 SELECT identity INTO saved FROM public.document_identity_snapshots WHERE document_kind=kind AND document_id=did;
 RETURN result || jsonb_build_object('issuer',COALESCE(saved,result->'issuer'),'historical',saved IS NOT NULL);
END $$;
REVOKE ALL ON FUNCTION public.rfq_document(uuid,uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfq_document(uuid,uuid,uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.guard_document_branding(),public.audit_document_branding(),public.capture_order_document_identity(),public.capture_rfq_document_identity() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_business_document_identity(p_business_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT public.can_read_business_document_branding(p_business_id) THEN RAISE EXCEPTION 'Business access required.'; END IF;
 RETURN public.document_identity(p_business_id);
END $$;
REVOKE ALL ON FUNCTION public.get_business_document_identity(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_business_document_identity(uuid) TO authenticated;
-- Receipt preparation freezes identity once, without changing payment or receipt delivery state.
CREATE FUNCTION public.prepare_receipt_document_identity(p_order_id uuid,p_collection_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.orders; result jsonb; did uuid; kind text; sent timestamptz;
BEGIN
 SELECT * INTO o FROM public.orders WHERE id=p_order_id;
 IF o.id IS NULL THEN RAISE EXCEPTION 'Order unavailable.'; END IF;
 did:=COALESCE(p_collection_id,o.id); kind:=CASE WHEN p_collection_id IS NULL THEN 'receipt' ELSE 'collection_receipt' END;
 sent:=o.receipt_sent_at;
 IF p_collection_id IS NOT NULL THEN
   SELECT receipt_sent_at INTO sent FROM public.order_collections WHERE id=p_collection_id AND order_id=o.id;
   IF NOT FOUND THEN RAISE EXCEPTION 'Receipt collection does not belong to this order.'; END IF;
 END IF;
 IF sent IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.document_identity_snapshots WHERE document_kind=kind AND document_id=did) THEN RETURN public.document_identity(o.wholesaler_id) || jsonb_build_object('legacy_branding',true); END IF;
 INSERT INTO public.document_identity_snapshots(document_kind,document_id,issuer_id,recipient_id,identity)
 VALUES(kind,did,o.wholesaler_id,o.pharmacy_id,public.document_identity(o.wholesaler_id)) ON CONFLICT DO NOTHING;
 SELECT identity INTO result FROM public.document_identity_snapshots WHERE document_kind=kind AND document_id=did;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.prepare_receipt_document_identity(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_receipt_document_identity(uuid,uuid) TO service_role;
COMMIT;
