-- Additive enterprise RFQ foundation. Previously awarded orders remain unchanged.
BEGIN;
ALTER TABLE public.rfqs DROP CONSTRAINT rfqs_status_check;
ALTER TABLE public.rfqs ADD CONSTRAINT rfqs_status_check CHECK(status IN ('draft','open','evaluation','partially_awarded','awarded','in_progress','completed','cancelled','expired'));
ALTER TABLE public.rfqs ADD COLUMN enterprise BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN revision INTEGER NOT NULL DEFAULT 1,
 ADD COLUMN delivery_location TEXT, ADD COLUMN expected_delivery_date DATE,
 ADD COLUMN payment_preference TEXT NOT NULL DEFAULT 'cod' CHECK(payment_preference IN ('cod','credit','bank_transfer','momo','cheque','other')),
 ADD COLUMN delivery_instructions TEXT, ADD COLUMN submitted_at TIMESTAMPTZ,
 ADD COLUMN updated_by UUID REFERENCES auth.users(id),
 ADD COLUMN closed_reason TEXT,
 ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private' CHECK(visibility IN('private','open'));
ALTER TABLE public.rfq_items ADD COLUMN master_product_id UUID REFERENCES public.master_products(id),
 ADD COLUMN specification JSONB NOT NULL DEFAULT '{}',
 ADD COLUMN unit TEXT NOT NULL DEFAULT 'pack' CHECK(unit IN ('pack','box','bottle','unit','carton')),
 ADD COLUMN minimum_shelf_life_days INTEGER NOT NULL DEFAULT 0 CHECK(minimum_shelf_life_days>=0),
 ADD COLUMN alternatives_allowed BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN partial_allowed BOOLEAN NOT NULL DEFAULT true,
 ADD COLUMN cold_chain_required BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN special_handling TEXT,
 ADD COLUMN cancelled_quantity INTEGER NOT NULL DEFAULT 0 CHECK(cancelled_quantity>=0 AND cancelled_quantity<=quantity);
ALTER TABLE public.rfq_invitees ADD COLUMN response_status TEXT NOT NULL DEFAULT 'invited' CHECK(response_status IN ('invited','accepted','declined','submitted')),
 ADD COLUMN viewed_at TIMESTAMPTZ, ADD COLUMN responded_at TIMESTAMPTZ, ADD COLUMN decline_reason TEXT;
ALTER TABLE public.rfq_quotes ADD COLUMN version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE public.rfq_quote_items ADD COLUMN alternative BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN offered_specification JSONB NOT NULL DEFAULT '{}',
 ADD COLUMN requested_units_per_offered_unit NUMERIC NOT NULL DEFAULT 1 CHECK(requested_units_per_offered_unit>0),
 ADD COLUMN expiry_date DATE,
 ADD COLUMN batch_number TEXT,
 ADD COLUMN expected_available_on DATE,
 ADD COLUMN cold_chain_supported BOOLEAN NOT NULL DEFAULT false,
 ADD COLUMN special_handling TEXT;

CREATE TABLE public.rfq_quote_versions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), quote_id UUID NOT NULL REFERENCES public.rfq_quotes(id),
 rfq_id UUID NOT NULL REFERENCES public.rfqs(id), wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
 version INTEGER NOT NULL CHECK(version>0), snapshot JSONB NOT NULL,
 reason TEXT NOT NULL, created_by UUID REFERENCES auth.users(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 UNIQUE(quote_id,version));
CREATE TABLE public.rfq_quote_drafts(
 rfq_id UUID REFERENCES public.rfqs(id), wholesaler_id UUID REFERENCES public.businesses(id),
 payload JSONB NOT NULL, revision INTEGER NOT NULL DEFAULT 1, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 PRIMARY KEY(rfq_id,wholesaler_id));
CREATE TABLE public.rfq_confirmation_groups(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), rfq_id UUID NOT NULL REFERENCES public.rfqs(id),
 quote_version_id UUID NOT NULL REFERENCES public.rfq_quote_versions(id), wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','confirmed','declined','cancelled','conversion_failed')),
 settlement_method TEXT NOT NULL CHECK(settlement_method IN ('cod','credit','bank_transfer','momo','cheque','other')),
 goods_ghs NUMERIC(12,2) NOT NULL CHECK(goods_ghs>0), delivery_ghs NUMERIC(12,2) NOT NULL CHECK(delivery_ghs>=0),
 order_id UUID UNIQUE REFERENCES public.orders(id), created_by UUID NOT NULL REFERENCES auth.users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), responded_at TIMESTAMPTZ, reason TEXT, last_error TEXT);
CREATE TABLE public.rfq_allocations(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), group_id UUID NOT NULL REFERENCES public.rfq_confirmation_groups(id),
 rfq_item_id UUID NOT NULL REFERENCES public.rfq_items(id), quote_item_id UUID NOT NULL,
 product_id UUID NOT NULL REFERENCES public.products(id), quantity INTEGER NOT NULL CHECK(quantity>0),
 requested_quantity NUMERIC NOT NULL CHECK(requested_quantity>0), unit_price_ghs NUMERIC(10,2) NOT NULL CHECK(unit_price_ghs>0),
 alternative_accepted BOOLEAN NOT NULL DEFAULT false, purchase_category TEXT NOT NULL CHECK(purchase_category IN ('nhis','cash_private','other')),
 UNIQUE(group_id,quote_item_id));
CREATE TABLE public.rfq_negotiations(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), rfq_id UUID NOT NULL REFERENCES public.rfqs(id),
 wholesaler_id UUID NOT NULL REFERENCES public.businesses(id), quote_version_id UUID REFERENCES public.rfq_quote_versions(id),
 proposal JSONB NOT NULL, status TEXT NOT NULL DEFAULT 'requested' CHECK(status IN ('requested','accepted','rejected','countered')),
 response TEXT, response_version_id UUID REFERENCES public.rfq_quote_versions(id),
 created_by UUID NOT NULL REFERENCES auth.users(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now(), responded_at TIMESTAMPTZ);
CREATE TABLE public.rfq_events(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), rfq_id UUID NOT NULL REFERENCES public.rfqs(id),
 wholesaler_id UUID REFERENCES public.businesses(id), action TEXT NOT NULL, details JSONB NOT NULL DEFAULT '{}',
 actor_id UUID REFERENCES auth.users(id), created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE public.rfq_requests(
 actor_id UUID NOT NULL REFERENCES auth.users(id), request_id UUID NOT NULL, payload_hash TEXT NOT NULL,
 result JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY(actor_id,request_id));
REVOKE ALL ON public.rfq_requests FROM PUBLIC,anon,authenticated;
ALTER TABLE public.rfq_requests ENABLE ROW LEVEL SECURITY;
CREATE INDEX ON public.rfqs(pharmacy_id,status,created_at DESC,id);
CREATE INDEX ON public.rfq_invitees(wholesaler_id,rfq_id);
CREATE INDEX ON public.rfq_confirmation_groups(rfq_id,status);
CREATE INDEX ON public.rfq_allocations(rfq_item_id);
CREATE INDEX ON public.rfq_events(rfq_id,created_at);
CREATE INDEX ON public.rfq_quote_versions(rfq_id,wholesaler_id,version DESC);

CREATE FUNCTION public.rfq_member(p_business_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p_business_id AND b.verification_status='approved'
 AND (b.owner_id=auth.uid() OR public.is_business_staff(auth.uid(),b.id)))
$$;
CREATE OR REPLACE FUNCTION public.can_view_rfq(p_rfq_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.rfqs r WHERE r.id=p_rfq_id AND (public.rfq_member(r.pharmacy_id)
 OR (r.status<>'draft' AND EXISTS(SELECT 1 FROM public.rfq_invitees i WHERE i.rfq_id=r.id AND public.rfq_member(i.wholesaler_id)))
 OR (r.enterprise AND r.visibility='open' AND r.status IN('open','partially_awarded') AND r.response_deadline>now()
   AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.type='wholesaler' AND b.verification_status='approved' AND public.rfq_member(b.id)))))
$$;
CREATE OR REPLACE FUNCTION public.can_view_rfq_party_row(p_rfq_id UUID,p_wholesaler_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT EXISTS(SELECT 1 FROM public.rfqs r WHERE r.id=p_rfq_id AND (public.rfq_member(r.pharmacy_id)
 OR (r.status<>'draft' AND public.rfq_member(p_wholesaler_id) AND EXISTS(SELECT 1 FROM public.rfq_invitees i WHERE i.rfq_id=r.id AND i.wholesaler_id=p_wholesaler_id))
 OR (r.enterprise AND r.visibility='open' AND r.status IN('open','partially_awarded') AND r.response_deadline>now()
   AND public.rfq_member(p_wholesaler_id) AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p_wholesaler_id AND b.type='wholesaler' AND b.verification_status='approved'))))
$$;
-- Remove blanket admin reads; investigations will have a dedicated audited operation.
DO $$ DECLARE p RECORD; BEGIN
 FOR p IN SELECT tablename,policyname FROM pg_policies WHERE schemaname='public' AND tablename IN('rfqs','rfq_items','rfq_invitees','rfq_quotes','rfq_quote_items','rfq_awards') AND (qual LIKE '%has_role%' OR policyname ILIKE '%admin%') LOOP
 EXECUTE format('DROP POLICY %I ON public.%I',p.policyname,p.tablename);
 END LOOP;
END $$;
CREATE POLICY enterprise_rfq_read ON public.rfqs FOR SELECT TO authenticated USING(public.can_view_rfq(id));
DO $$ DECLARE t TEXT; BEGIN
 FOREACH t IN ARRAY ARRAY['rfq_quote_versions','rfq_confirmation_groups','rfq_negotiations','rfq_events'] LOOP
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
 EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
 EXECUTE format('CREATE POLICY participant_read ON public.%I FOR SELECT TO authenticated USING(public.can_view_rfq_party_row(rfq_id,wholesaler_id))',t);
 END LOOP;
END $$;
ALTER TABLE public.rfq_quote_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rfq_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rfq_quote_drafts,public.rfq_allocations FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.rfq_quote_drafts,public.rfq_allocations TO authenticated;
CREATE POLICY supplier_draft_read ON public.rfq_quote_drafts FOR SELECT TO authenticated USING(public.rfq_member(wholesaler_id) AND public.can_view_rfq(rfq_id));
CREATE POLICY allocation_read ON public.rfq_allocations FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.rfq_confirmation_groups g WHERE g.id=group_id AND public.can_view_rfq_party_row(g.rfq_id,g.wholesaler_id)));

CREATE FUNCTION public.rfq_event(p_rfq_id UUID,p_wholesaler_id UUID,p_action TEXT,p_details JSONB DEFAULT '{}') RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 INSERT INTO public.rfq_events(rfq_id,wholesaler_id,action,details,actor_id) VALUES(p_rfq_id,p_wholesaler_id,p_action,p_details,auth.uid());
 PERFORM public.write_audit_log(p_action,'RFQ','rfq',p_rfq_id,'Private procurement event','{}',_business_id=>(SELECT pharmacy_id FROM public.rfqs WHERE id=p_rfq_id));
END $$;
REVOKE ALL ON FUNCTION public.rfq_event(UUID,UUID,TEXT,JSONB) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.rfq_member(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rfq_member(UUID) TO authenticated;

CREATE FUNCTION public.save_enterprise_rfq(p_pharmacy_id UUID,p_payload JSONB,p_request_id UUID,p_rfq_id UUID DEFAULT NULL,p_revision INTEGER DEFAULT NULL) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; x JSONB; m public.master_products%ROWTYPE; v_id UUID; v_hash TEXT; v_previous public.rfq_requests%ROWTYPE;
BEGIN
 IF NOT public.rfq_member(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND type='pharmacy') THEN RAISE EXCEPTION 'Approved pharmacy purchasing permission required.'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Request ID required.'; END IF;
 v_hash:=md5(jsonb_build_array('save',p_pharmacy_id,p_payload,p_rfq_id,p_revision)::text);
 PERFORM pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request_id::text,0));
 SELECT * INTO v_previous FROM public.rfq_requests WHERE actor_id=auth.uid() AND request_id=p_request_id;
 IF FOUND THEN IF v_previous.payload_hash<>v_hash THEN RAISE EXCEPTION 'Request ID reused with different data.'; END IF; RETURN (v_previous.result->>'id')::uuid; END IF;
 IF NULLIF(btrim(p_payload->>'title'),'') IS NULL OR jsonb_typeof(p_payload->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'A title and 1–500 medicine lines are required.'; END IF;
 IF jsonb_typeof(COALESCE(p_payload->'suppliers','[]')) IS DISTINCT FROM 'array' OR jsonb_array_length(COALESCE(p_payload->'suppliers','[]'))>100 THEN RAISE EXCEPTION 'Select up to 100 suppliers per RFQ.'; END IF;
 IF p_rfq_id IS NOT NULL THEN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR r.pharmacy_id<>p_pharmacy_id OR r.status<>'draft' OR r.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'Draft changed or cannot be edited. Reload it.'; END IF;
 v_id:=r.id;
 DELETE FROM public.rfq_items WHERE rfq_id=v_id;
 DELETE FROM public.rfq_invitees WHERE rfq_id=v_id;
 ELSE
 INSERT INTO public.rfqs(pharmacy_id,title,status,enterprise,created_by) VALUES(p_pharmacy_id,btrim(p_payload->>'title'),'draft',true,auth.uid()) RETURNING id INTO v_id;
 END IF;
 UPDATE public.rfqs SET title=btrim(p_payload->>'title'),notes=NULLIF(btrim(p_payload->>'notes'),''),
 response_deadline=NULLIF(p_payload->>'deadline','')::timestamptz,expected_delivery_date=NULLIF(p_payload->>'expectedDelivery','')::date,
 delivery_location=NULLIF(btrim(p_payload->>'deliveryLocation'),''),delivery_instructions=NULLIF(btrim(p_payload->>'deliveryInstructions'),''),
 payment_preference=COALESCE(NULLIF(p_payload->>'paymentPreference',''),'cod'),
 visibility=CASE WHEN p_payload->>'visibility'='open' THEN 'open' ELSE 'private' END,
 updated_by=auth.uid(),revision=revision+1 WHERE id=v_id;
 FOR x IN SELECT value FROM jsonb_array_elements(p_payload->'items') LOOP
 IF NULLIF(btrim(x->>'productName'),'') IS NULL OR COALESCE((x->>'quantity')::numeric,0)<=0 OR (x->>'quantity')::numeric<>trunc((x->>'quantity')::numeric) THEN RAISE EXCEPTION 'Every medicine needs a name and positive whole quantity.'; END IF;
 m:=NULL;
 IF NULLIF(x->>'masterProductId','') IS NOT NULL THEN SELECT * INTO m FROM public.master_products WHERE id=(x->>'masterProductId')::uuid AND active; IF NOT FOUND THEN RAISE EXCEPTION 'Selected catalogue medicine is unavailable.'; END IF; END IF;
 INSERT INTO public.rfq_items(rfq_id,product_name,quantity,notes,master_product_id,specification,unit,minimum_shelf_life_days,alternatives_allowed,partial_allowed,cold_chain_required,special_handling)
 VALUES(v_id,COALESCE(m.name,btrim(x->>'productName')),(x->>'quantity')::integer,NULLIF(btrim(x->>'notes'),''),m.id,
 CASE WHEN m.id IS NOT NULL THEN jsonb_build_object('generic',m.generic_name,'brand',m.brand_name,'strength',m.strength,'form',m.dosage_form,'pack',m.pack_size) ELSE COALESCE(x->'specification','{}') END,
 COALESCE(x->>'unit','pack'),COALESCE((x->>'shelfLifeDays')::integer,0),COALESCE((x->>'alternativesAllowed')::boolean,false),COALESCE((x->>'partialAllowed')::boolean,true),
 COALESCE((x->>'coldChainRequired')::boolean,false),NULLIF(btrim(x->>'specialHandling'),''));
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.rfq_items WHERE rfq_id=v_id GROUP BY COALESCE(master_product_id::text,lower(product_name)),unit,specification HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate medicine requirements: combine quantities or distinguish specifications.'; END IF;
 FOR x IN SELECT value FROM jsonb_array_elements(COALESCE(p_payload->'suppliers','[]')) LOOP
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=(x#>>'{}')::uuid AND type='wholesaler' AND verification_status='approved') THEN RAISE EXCEPTION 'Choose approved wholesalers only.'; END IF;
 INSERT INTO public.rfq_invitees(rfq_id,wholesaler_id) VALUES(v_id,(x#>>'{}')::uuid) ON CONFLICT DO NOTHING;
 END LOOP;
 PERFORM public.rfq_event(v_id,NULL,'RFQ_DRAFT_SAVED');
 INSERT INTO public.rfq_requests VALUES(auth.uid(),p_request_id,v_hash,jsonb_build_object('id',v_id),now());
 RETURN v_id;
END $$;

CREATE FUNCTION public.publish_enterprise_rfq(p_rfq_id UUID,p_revision INTEGER) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; v_invitee RECORD; BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT public.rfq_member(r.pharmacy_id) OR NOT public.can_act_for_business(r.pharmacy_id,'process') THEN RAISE EXCEPTION 'Purchasing permission required.'; END IF;
 IF r.status<>'draft' OR r.revision IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'Draft changed. Reload before publishing.'; END IF;
 IF r.response_deadline IS NULL OR r.response_deadline<=now() OR (r.expected_delivery_date IS NOT NULL AND r.expected_delivery_date<r.response_deadline::date) THEN RAISE EXCEPTION 'Choose a future deadline and delivery on or after that deadline.'; END IF;
 IF (r.visibility='private' AND NOT EXISTS(SELECT 1 FROM public.rfq_invitees WHERE rfq_id=r.id)) OR EXISTS(SELECT 1 FROM public.rfq_invitees i JOIN public.businesses b ON b.id=i.wholesaler_id WHERE i.rfq_id=r.id AND b.verification_status<>'approved') THEN RAISE EXCEPTION 'Invite at least one approved supplier for a private RFQ; remove suppliers no longer approved.'; END IF;
 UPDATE public.rfqs SET status='open',submitted_at=now(),updated_by=auth.uid(),revision=revision+1 WHERE id=r.id;
 FOR v_invitee IN SELECT wholesaler_id FROM public.rfq_invitees WHERE rfq_id=r.id LOOP
 PERFORM public.notify_business(v_invitee.wholesaler_id,ARRAY['owner','manager','cashier','warehouse'],'rfq_invitation','New RFQ invitation',r.title,'/wholesaler/rfqs?rfq='||r.id);
 END LOOP;
 PERFORM public.rfq_event(r.id,NULL,'RFQ_PUBLISHED');
END $$;

CREATE FUNCTION public.respond_rfq_invitation(p_rfq_id UUID,p_wholesaler_id UUID,p_action TEXT,p_reason TEXT DEFAULT NULL) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.rfqs%ROWTYPE; BEGIN
 SELECT * INTO r FROM public.rfqs WHERE id=p_rfq_id FOR UPDATE;
 IF NOT FOUND OR NOT public.rfq_member(p_wholesaler_id) OR NOT public.can_act_for_business(p_wholesaler_id,'process') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_wholesaler_id AND type='wholesaler' AND verification_status='approved') OR (NOT EXISTS(SELECT 1 FROM public.rfq_invitees WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id) AND NOT (r.enterprise AND r.visibility='open' AND r.status IN('open','partially_awarded') AND r.response_deadline>now())) OR r.status='draft' THEN RAISE EXCEPTION 'Invitation not available.'; END IF;
 IF p_action='view' THEN INSERT INTO public.rfq_invitees(rfq_id,wholesaler_id,viewed_at) VALUES(r.id,p_wholesaler_id,now()) ON CONFLICT(rfq_id,wholesaler_id) DO UPDATE SET viewed_at=COALESCE(rfq_invitees.viewed_at,now()); RETURN; END IF;
 IF p_action NOT IN ('accepted','declined') OR p_action IS NULL OR r.status NOT IN('open','partially_awarded') OR r.response_deadline<=now() THEN RAISE EXCEPTION 'Invitation is not accepting responses.'; END IF;
 IF p_action='declined' AND NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Decline reason required.'; END IF;
 INSERT INTO public.rfq_invitees(rfq_id,wholesaler_id) VALUES(r.id,p_wholesaler_id) ON CONFLICT(rfq_id,wholesaler_id) DO NOTHING;
 UPDATE public.rfq_invitees SET response_status=p_action,responded_at=now(),decline_reason=p_reason WHERE rfq_id=r.id AND wholesaler_id=p_wholesaler_id;
 PERFORM public.rfq_event(r.id,p_wholesaler_id,'INVITATION_'||upper(p_action),jsonb_build_object('reason',p_reason));
END $$;
REVOKE ALL ON FUNCTION public.save_enterprise_rfq(UUID,JSONB,UUID,UUID,INTEGER),public.publish_enterprise_rfq(UUID,INTEGER),public.respond_rfq_invitation(UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_enterprise_rfq(UUID,JSONB,UUID,UUID,INTEGER),public.publish_enterprise_rfq(UUID,INTEGER),public.respond_rfq_invitation(UUID,UUID,TEXT,TEXT) TO authenticated;
COMMIT;
