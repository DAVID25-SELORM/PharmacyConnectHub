-- Pharmacy-owned representative relationships. CRM is private to pharmacy owners/managers.
CREATE FUNCTION public.can_manage_pharmacy_crm(p_pharmacy_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=p_pharmacy_id AND b.type::text='pharmacy' AND b.verification_status='approved') AND public.can_act_for_business(p_pharmacy_id,'manage')
$$;
REVOKE ALL ON FUNCTION public.can_manage_pharmacy_crm(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_manage_pharmacy_crm(UUID) TO authenticated;

CREATE TABLE public.pharmacy_crm_representatives (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 name TEXT NOT NULL CHECK(char_length(btrim(name)) BETWEEN 1 AND 200), rep_type TEXT NOT NULL DEFAULT 'sales' CHECK(rep_type IN ('medical','sales','supplier','other')), job_title TEXT, phone TEXT, whatsapp TEXT, email TEXT, territory TEXT, preferred_contact TEXT NOT NULL DEFAULT 'phone' CHECK(preferred_contact IN ('phone','whatsapp','email','other')), notes TEXT, status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','inactive')));

CREATE TABLE public.pharmacy_crm_companies (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 name TEXT NOT NULL CHECK(char_length(btrim(name)) BETWEEN 1 AND 200), company_type TEXT NOT NULL DEFAULT 'wholesaler' CHECK(company_type IN ('wholesaler','manufacturer','supplier','other')), wholesaler_id UUID REFERENCES public.businesses(id), notes TEXT);

CREATE TABLE public.pharmacy_crm_rep_companies (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 rep_id UUID NOT NULL, company_id UUID NOT NULL, designated BOOLEAN NOT NULL DEFAULT false, FOREIGN KEY(pharmacy_id,rep_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id), FOREIGN KEY(pharmacy_id,company_id) REFERENCES public.pharmacy_crm_companies(pharmacy_id,id));

CREATE TABLE public.pharmacy_crm_rep_products (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 rep_id UUID NOT NULL, master_product_id UUID REFERENCES public.master_products(id), label TEXT NOT NULL CHECK(char_length(btrim(label)) BETWEEN 1 AND 300), brand TEXT, FOREIGN KEY(pharmacy_id,rep_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id));

CREATE TABLE public.pharmacy_crm_interactions (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 rep_id UUID NOT NULL, occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(), staff_user_id UUID NOT NULL REFERENCES auth.users(id), interaction_type TEXT NOT NULL DEFAULT 'visit' CHECK(interaction_type IN ('visit','call','email','whatsapp','other')), purpose TEXT NOT NULL CHECK(char_length(btrim(purpose)) BETWEEN 1 AND 500), products_discussed TEXT, samples_received TEXT, price_list_received BOOLEAN NOT NULL DEFAULT false, quotation_discussed BOOLEAN NOT NULL DEFAULT false, notes TEXT, FOREIGN KEY(pharmacy_id,rep_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id));

CREATE TABLE public.pharmacy_crm_followups (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 rep_id UUID NOT NULL, interaction_id UUID, task TEXT NOT NULL CHECK(char_length(btrim(task)) BETWEEN 1 AND 500), due_at TIMESTAMPTZ NOT NULL, assigned_to UUID REFERENCES auth.users(id), status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','completed','cancelled')), completed_at TIMESTAMPTZ, completed_by UUID REFERENCES auth.users(id), notes TEXT, FOREIGN KEY(pharmacy_id,rep_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id), FOREIGN KEY(pharmacy_id,interaction_id) REFERENCES public.pharmacy_crm_interactions(pharmacy_id,id));

CREATE TABLE public.pharmacy_crm_procurement_links (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL, updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
 archived BOOLEAN NOT NULL DEFAULT false, UNIQUE(pharmacy_id,id),
 rep_id UUID NOT NULL, order_id UUID REFERENCES public.orders(id), rfq_id UUID REFERENCES public.rfqs(id), quote_id UUID REFERENCES public.rfq_quotes(id), notes TEXT, CHECK(num_nonnulls(order_id,rfq_id,quote_id)=1), FOREIGN KEY(pharmacy_id,rep_id) REFERENCES public.pharmacy_crm_representatives(pharmacy_id,id));

CREATE UNIQUE INDEX crm_rep_company_unique ON public.pharmacy_crm_rep_companies(pharmacy_id,rep_id,company_id) WHERE NOT archived;
CREATE UNIQUE INDEX crm_company_designated ON public.pharmacy_crm_rep_companies(pharmacy_id,company_id) WHERE designated AND NOT archived;
CREATE UNIQUE INDEX crm_company_supplier_unique ON public.pharmacy_crm_companies(pharmacy_id,wholesaler_id) WHERE wholesaler_id IS NOT NULL AND NOT archived;
CREATE INDEX crm_followup_due ON public.pharmacy_crm_followups(pharmacy_id,status,due_at) WHERE NOT archived;
CREATE INDEX crm_visit_rep ON public.pharmacy_crm_interactions(pharmacy_id,rep_id,occurred_at DESC);
-- Full private history is not stored in the broader business Audit Centre.
CREATE TABLE public.pharmacy_crm_activity (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 record_id UUID NOT NULL, rep_id UUID, entity TEXT NOT NULL, action TEXT NOT NULL,
 actor_id UUID REFERENCES auth.users(id) ON DELETE SET NULL, occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 before_data JSONB, after_data JSONB
);
CREATE INDEX crm_activity_rep ON public.pharmacy_crm_activity(pharmacy_id,rep_id,occurred_at DESC);
CREATE FUNCTION public.audit_pharmacy_crm_change() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_rep UUID;
BEGIN
 v_rep:=CASE WHEN TG_TABLE_NAME='pharmacy_crm_representatives' THEN NEW.id ELSE NULLIF(to_jsonb(NEW)->>'rep_id','')::UUID END;
 INSERT INTO public.pharmacy_crm_activity(pharmacy_id,record_id,rep_id,entity,action,actor_id,before_data,after_data)
 VALUES(NEW.pharmacy_id,NEW.id,v_rep,TG_TABLE_NAME,TG_OP,auth.uid(),CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) END,to_jsonb(NEW));
 -- Metadata only: no names, contact details or notes leak into the general audit log.
 PERFORM public.write_audit_log('CRM record '||lower(TG_OP),'Pharmacy','crm',NEW.id,'Private CRM record',jsonb_build_object('entity',TG_TABLE_NAME),_business_id=>NEW.pharmacy_id);
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.audit_pharmacy_crm_change() FROM PUBLIC,anon,authenticated;
ALTER TABLE public.pharmacy_crm_representatives ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_representatives FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_representatives TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_representatives FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_representatives_tenant ON public.pharmacy_crm_representatives(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_representatives FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_companies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_companies FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_companies TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_companies FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_companies_tenant ON public.pharmacy_crm_companies(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_companies FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_rep_companies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_rep_companies FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_rep_companies TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_rep_companies FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_rep_companies_tenant ON public.pharmacy_crm_rep_companies(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_rep_companies FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_rep_products ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_rep_products FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_rep_products TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_rep_products FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_rep_products_tenant ON public.pharmacy_crm_rep_products(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_rep_products FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_interactions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_interactions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_interactions TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_interactions FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_interactions_tenant ON public.pharmacy_crm_interactions(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_interactions FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_followups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_followups FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_followups TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_followups FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_followups_tenant ON public.pharmacy_crm_followups(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_followups FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_procurement_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_procurement_links FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_procurement_links TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_procurement_links FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_procurement_links_tenant ON public.pharmacy_crm_procurement_links(pharmacy_id,id);
CREATE TRIGGER crm_audit AFTER INSERT OR UPDATE ON public.pharmacy_crm_procurement_links FOR EACH ROW EXECUTE FUNCTION public.audit_pharmacy_crm_change();
ALTER TABLE public.pharmacy_crm_activity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pharmacy_crm_activity FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.pharmacy_crm_activity TO authenticated;
CREATE POLICY crm_read ON public.pharmacy_crm_activity FOR SELECT TO authenticated USING(public.can_manage_pharmacy_crm(pharmacy_id));
CREATE INDEX pharmacy_crm_activity_tenant ON public.pharmacy_crm_activity(pharmacy_id,id);

-- One allowlisted mutation endpoint; tenant, identity and audit fields cannot be supplied by clients.
CREATE FUNCTION public.save_pharmacy_crm(p_pharmacy_id UUID,p_entity TEXT,p_data JSONB,p_id UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_table TEXT; v_id UUID:=COALESCE(p_id,gen_random_uuid()); v_old JSONB; v_doc JSONB; v_fields TEXT; v_assign TEXT; v_rep UUID; v_company UUID; v_ref UUID;
BEGIN
 IF NOT public.can_manage_pharmacy_crm(p_pharmacy_id) THEN RAISE EXCEPTION 'Only this pharmacy owner or manager may manage CRM.'; END IF;
 IF p_entity NOT IN ('representatives','companies','rep_companies','rep_products','interactions','followups','procurement_links') OR p_entity IS NULL THEN RAISE EXCEPTION 'Invalid CRM entity.'; END IF;
 IF p_data IS NULL OR jsonb_typeof(p_data)<>'object' OR octet_length(p_data::text)>65536 THEN RAISE EXCEPTION 'Invalid or oversized record.'; END IF;
 v_table:='pharmacy_crm_'||p_entity;
 IF p_id IS NOT NULL THEN
  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE pharmacy_id=$1 AND id=$2 FOR UPDATE',v_table) INTO v_old USING p_pharmacy_id,p_id;
  IF v_old IS NULL THEN RAISE EXCEPTION 'CRM record not found in this pharmacy.'; END IF;
 END IF;
 v_doc:=COALESCE(v_old,'{}'::jsonb)||(p_data-ARRAY['id','pharmacy_id','created_at','updated_at','created_by','updated_by','completed_at','completed_by']);
 v_rep:=NULLIF(v_doc->>'rep_id','')::UUID;
 IF v_rep IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_representatives WHERE pharmacy_id=p_pharmacy_id AND id=v_rep AND NOT archived) THEN RAISE EXCEPTION 'Choose an unarchived representative in this pharmacy.'; END IF;
 IF p_entity='companies' AND NULLIF(v_doc->>'wholesaler_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=(v_doc->>'wholesaler_id')::UUID AND type::text='wholesaler') THEN RAISE EXCEPTION 'Choose a registered wholesaler.'; END IF;
 IF p_entity='rep_companies' THEN
  v_company:=(v_doc->>'company_id')::UUID;
  IF NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_companies WHERE pharmacy_id=p_pharmacy_id AND id=v_company AND NOT archived) THEN RAISE EXCEPTION 'Choose a company in this pharmacy.'; END IF;
 END IF;
 IF p_entity='interactions' THEN
  v_ref:=COALESCE(NULLIF(v_doc->>'staff_user_id','')::UUID,auth.uid());
  IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND owner_id=v_ref) AND NOT EXISTS(SELECT 1 FROM public.business_staff WHERE user_id=v_ref AND business_id=p_pharmacy_id AND status='active') THEN RAISE EXCEPTION 'Staff member must belong to this pharmacy.'; END IF;
  v_doc:=v_doc||jsonb_build_object('staff_user_id',v_ref,'occurred_at',COALESCE(v_doc->>'occurred_at',now()::text),'interaction_type',COALESCE(v_doc->>'interaction_type','visit'),'price_list_received',COALESCE((v_doc->>'price_list_received')::boolean,false),'quotation_discussed',COALESCE((v_doc->>'quotation_discussed')::boolean,false));
 END IF;
 IF p_entity='followups' THEN
  v_ref:=NULLIF(v_doc->>'assigned_to','')::UUID;
  IF v_ref IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND owner_id=v_ref) AND NOT EXISTS(SELECT 1 FROM public.business_staff WHERE user_id=v_ref AND business_id=p_pharmacy_id AND status='active') THEN RAISE EXCEPTION 'Assignee must belong to this pharmacy.'; END IF;
  IF NULLIF(v_doc->>'interaction_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_interactions WHERE id=(v_doc->>'interaction_id')::UUID AND pharmacy_id=p_pharmacy_id AND rep_id=v_rep) THEN RAISE EXCEPTION 'Interaction must belong to this representative.'; END IF;
  v_doc:=v_doc||jsonb_build_object('status',COALESCE(v_doc->>'status','pending'));
  IF v_doc->>'status'='completed' THEN v_doc:=v_doc||jsonb_build_object('completed_at',COALESCE(v_old->>'completed_at',now()::text),'completed_by',COALESCE(NULLIF(v_old->>'completed_by','')::UUID,auth.uid()));
  ELSE v_doc:=v_doc||jsonb_build_object('completed_at',NULL,'completed_by',NULL); END IF;
 END IF;
 IF p_entity='procurement_links' THEN
  IF NULLIF(v_doc->>'order_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.orders WHERE id=(v_doc->>'order_id')::UUID AND pharmacy_id=p_pharmacy_id) THEN RAISE EXCEPTION 'Order belongs to another pharmacy.'; END IF;
  IF NULLIF(v_doc->>'rfq_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.rfqs WHERE id=(v_doc->>'rfq_id')::UUID AND pharmacy_id=p_pharmacy_id) THEN RAISE EXCEPTION 'RFQ belongs to another pharmacy.'; END IF;
  IF NULLIF(v_doc->>'quote_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.rfq_quotes q JOIN public.rfqs r ON r.id=q.rfq_id WHERE q.id=(v_doc->>'quote_id')::UUID AND r.pharmacy_id=p_pharmacy_id) THEN RAISE EXCEPTION 'Quote belongs to another pharmacy.'; END IF;
 END IF;
 IF p_entity='representatives' THEN v_doc:=v_doc||jsonb_build_object('status',COALESCE(v_doc->>'status','active'),'rep_type',COALESCE(v_doc->>'rep_type','sales'),'preferred_contact',COALESCE(v_doc->>'preferred_contact','phone')); END IF;
 IF p_entity='companies' THEN v_doc:=v_doc||jsonb_build_object('company_type',COALESCE(v_doc->>'company_type','wholesaler')); END IF;
 IF p_entity='rep_companies' THEN v_doc:=v_doc||jsonb_build_object('designated',COALESCE((v_doc->>'designated')::boolean,false)); END IF;
 v_doc:=v_doc||jsonb_build_object('id',v_id,'pharmacy_id',p_pharmacy_id,'created_at',COALESCE(v_old->>'created_at',now()::text),'updated_at',now(),'created_by',COALESCE(NULLIF(v_old->>'created_by','')::UUID,auth.uid()),'updated_by',auth.uid(),'archived',COALESCE((v_doc->>'archived')::boolean,false));
 SELECT string_agg(quote_ident(attname),',' ORDER BY attnum),string_agg(format('%I=EXCLUDED.%I',attname,attname),',' ORDER BY attnum) INTO v_fields,v_assign FROM pg_attribute WHERE attrelid=('public.'||v_table)::regclass AND attnum>0 AND NOT attisdropped;
 EXECUTE format('INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I,$1) ON CONFLICT(id) DO UPDATE SET %s',v_table,v_fields,v_fields,v_table,v_assign) USING v_doc;
 IF p_entity IN ('representatives','companies') AND COALESCE((v_doc->>'archived')::boolean,false) THEN
  UPDATE public.pharmacy_crm_rep_companies SET designated=false,updated_at=now(),updated_by=auth.uid()
  WHERE pharmacy_id=p_pharmacy_id AND designated AND CASE WHEN p_entity='representatives' THEN rep_id=v_id ELSE company_id=v_id END;
 END IF;
 IF p_entity='interactions' AND p_id IS NULL AND NULLIF(p_data->>'followup_due_at','') IS NOT NULL THEN
  PERFORM public.save_pharmacy_crm(p_pharmacy_id,'followups',jsonb_build_object('rep_id',v_rep,'interaction_id',v_id,'task',COALESCE(NULLIF(p_data->>'followup_task',''),v_doc->>'purpose'),'due_at',p_data->>'followup_due_at'));
 END IF;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.save_pharmacy_crm(UUID,TEXT,JSONB,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pharmacy_crm(UUID,TEXT,JSONB,UUID) TO authenticated;
