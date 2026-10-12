-- Additive private catalogue and document preparation. No stock or historic document updates.
BEGIN;
CREATE FUNCTION public.can_prepare_procurement(p_business_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.businesses WHERE id=p_business_id AND type::text IN ('pharmacy','wholesaler') AND verification_status='approved')
 AND public.can_act_for_business(p_business_id,'process');
$$;
REVOKE ALL ON FUNCTION public.can_prepare_procurement(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_prepare_procurement(uuid) TO authenticated;
CREATE TABLE public.business_procurement_catalogue (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id),
 master_product_id uuid REFERENCES public.master_products(id), data jsonb NOT NULL,
 identity_key text NOT NULL, archived boolean NOT NULL DEFAULT false, version integer NOT NULL DEFAULT 1,
 created_by uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(business_id,identity_key)
);
ALTER TABLE public.business_procurement_catalogue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_procurement_catalogue FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.business_procurement_catalogue TO authenticated;
CREATE POLICY "Read own procurement catalogue" ON public.business_procurement_catalogue FOR SELECT TO authenticated USING(public.can_prepare_procurement(business_id));
CREATE INDEX business_procurement_catalogue_lookup ON public.business_procurement_catalogue(business_id,archived,updated_at DESC);
CREATE FUNCTION public.save_procurement_medicine(p_business_id uuid,p_data jsonb,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL,p_archived boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result uuid; identity text; item record;
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Purchase processing permission required.'; END IF;
 IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' OR length(btrim(coalesce(p_data->>'name',''))) NOT BETWEEN 1 AND 300 OR length(p_data::text)>12000 THEN RAISE EXCEPTION 'Enter a valid product name and bounded details.'; END IF;
 IF coalesce(p_data->>'category','medicine') NOT IN ('medicine','consumable','equipment','other') OR coalesce(p_data->>'unit','packs') NOT IN ('packs','boxes','bottles','tubes','vials','ampoules','pieces') THEN RAISE EXCEPTION 'Choose a supported category and unit.'; END IF;
 IF coalesce(p_data->>'category','medicine')='medicine' AND (nullif(btrim(p_data->>'strength'),'') IS NULL OR nullif(btrim(p_data->>'dosage_form'),'') IS NULL OR nullif(btrim(p_data->>'pack_size'),'') IS NULL) THEN RAISE EXCEPTION 'Medicine strength, dosage form and presentation are required.'; END IF;
 -- Exact structured identity only. Similar names are never merged automatically.
 SELECT jsonb_agg(lower(regexp_replace(btrim(coalesce(p_data->>key,'')),'\s+',' ','g')) ORDER BY ord)::text INTO identity FROM unnest(ARRAY['name','brand_name','generic_name','strength','dosage_form','pack_size','manufacturer','product_code','unit']) WITH ORDINALITY AS a(key,ord);
 PERFORM pg_advisory_xact_lock(hashtextextended('procurement-catalogue:'||p_business_id::text,0));
 IF p_id IS NULL THEN
 SELECT id INTO result FROM public.business_procurement_catalogue WHERE business_id=p_business_id AND identity_key=identity;
 IF FOUND THEN
 IF (SELECT archived FROM public.business_procurement_catalogue WHERE id=result) THEN RAISE EXCEPTION 'This medicine is archived. Find it under Archived entries and restore it first.'; END IF;
 RETURN result; END IF;
 INSERT INTO public.business_procurement_catalogue(business_id,data,identity_key,created_by) VALUES(p_business_id,p_data,identity,auth.uid()) RETURNING id INTO result;
 ELSE
 UPDATE public.business_procurement_catalogue SET data=p_data,identity_key=identity,archived=coalesce(p_archived,false),version=version+1,updated_at=now()
 WHERE id=p_id AND business_id=p_business_id AND version=p_version RETURNING id INTO result;
 IF result IS NULL THEN RAISE EXCEPTION 'Catalogue entry changed or is unavailable. Reload first.'; END IF;
 END IF;
 PERFORM public.write_audit_log('PROCUREMENT_CATALOGUE_SAVED','Business','procurement_catalogue',result,'Private catalogue entry','{}'::jsonb,_business_id=>p_business_id);
 RETURN result;
END $$;
-- Search only identity values, never JSON field names or commercial data.
CREATE FUNCTION public.procurement_search_text(p_data jsonb) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=public AS $$
 SELECT lower(coalesce(p_data->>'name','')||' '||coalesce(p_data->>'generic_name','')||' '||coalesce(p_data->>'brand_name','')||' '||coalesce(p_data->>'strength','')||' '||coalesce(p_data->>'dosage_form','')||' '||coalesce(p_data->>'pack_size','')||' '||coalesce(p_data->>'manufacturer','')||' '||coalesce(p_data->>'product_code','')||' '||coalesce(p_data->>'ingredients','')||' '||coalesce(p_data->>'aliases',''));
$$;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
DO $$ DECLARE extension_schema text; BEGIN
 SELECT n.nspname INTO extension_schema FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace WHERE e.extname='pg_trgm';
 EXECUTE format('CREATE INDEX procurement_catalogue_search ON public.business_procurement_catalogue USING gin (public.procurement_search_text(data) %I.gin_trgm_ops)',extension_schema);
 EXECUTE format($index$CREATE INDEX procurement_master_search ON public.master_products USING gin ((lower(coalesce(name,'')||' '||coalesce(generic_name,'')||' '||coalesce(brand_name,'')||' '||coalesce(strength,'')||' '||coalesce(dosage_form,'')||' '||coalesce(pack_size,'')||' '||coalesce(manufacturer,'')||' '||coalesce(product_code,''))) %I.gin_trgm_ops) WHERE active$index$,extension_schema);
END $$;
CREATE FUNCTION public.search_procurement_catalogue(p_business_id uuid,p_query text DEFAULT '',p_scope text DEFAULT 'all',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE term text:=lower(btrim(coalesce(p_query,''))); pattern text;
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF p_scope IS NULL OR p_scope NOT IN ('all','business','recent','frequent','archived') THEN RAISE EXCEPTION 'Unknown catalogue source.'; END IF;
 pattern:='%'||replace(replace(replace(term, E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_')||'%';
 IF length(term)>200 THEN RAISE EXCEPTION 'Search is too long.'; END IF;
 IF length(term)=1 THEN RETURN '[]'::jsonb; END IF;
 RETURN (WITH entries AS (
 SELECT c.id,'business'::text source,c.data,c.archived,c.version,c.updated_at FROM public.business_procurement_catalogue c WHERE c.business_id=p_business_id AND (NOT c.archived OR p_scope='archived') AND (p_scope<>'archived' OR c.archived) AND (term='' OR public.procurement_search_text(c.data) LIKE pattern)
 UNION ALL
 SELECT m.id,'master',jsonb_build_object('name',m.name,'generic_name',m.generic_name,'brand_name',m.brand_name,'strength',m.strength,'dosage_form',m.dosage_form,'pack_size',m.pack_size,'manufacturer',m.manufacturer,'product_code',m.product_code,'unit','packs','category','medicine'),false,0,m.updated_at
 FROM public.master_products m WHERE m.active AND p_scope IN ('all','recent','frequent') AND (term='' OR lower(coalesce(m.name,'')||' '||coalesce(m.generic_name,'')||' '||coalesce(m.brand_name,'')||' '||coalesce(m.strength,'')||' '||coalesce(m.dosage_form,'')||' '||coalesce(m.pack_size,'')||' '||coalesce(m.manufacturer,'')||' '||coalesce(m.product_code,'')) LIKE pattern)
 ), usage AS (
 SELECT l->>'catalogue_id' id,count(*) frequency,max(o.created_at) recent FROM public.external_supply_orders o CROSS JOIN LATERAL jsonb_array_elements(o.data->'lines') l WHERE o.pharmacy_id=p_business_id GROUP BY l->>'catalogue_id'
 ), matches AS (
 SELECT e.*,coalesce(u.frequency,0) frequency,u.recent FROM entries e LEFT JOIN usage u ON u.id=e.id::text
 WHERE (p_scope NOT IN ('recent','frequent') OR u.id IS NOT NULL)
 ORDER BY (lower(e.data->>'name')=term) DESC,(e.source='business') DESC,
 CASE WHEN p_scope='frequent' THEN u.frequency END DESC NULLS LAST,
 CASE WHEN p_scope='recent' THEN u.recent END DESC NULLS LAST,e.data->>'name',e.id
 LIMIT 21 OFFSET greatest(0,least(coalesce(p_offset,0),10000))
 ) SELECT coalesce(jsonb_agg(to_jsonb(matches)),'[]'::jsonb) FROM matches);
END $$;
ALTER TABLE public.pharmacy_crm_companies ADD COLUMN IF NOT EXISTS procurement_email text, ADD COLUMN IF NOT EXISTS procurement_contact_person text;
CREATE FUNCTION public.procurement_suppliers(p_business_id uuid,p_query text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 RETURN (SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (SELECT id,name,phone,location,procurement_email email,procurement_contact_person contact_person,notes FROM public.pharmacy_crm_companies WHERE pharmacy_id=p_business_id AND NOT archived AND (coalesce(p_query,'')='' OR concat_ws(' ',name,phone,procurement_email) ILIKE '%'||left(p_query,200)||'%') ORDER BY name,id LIMIT 30) x);
END $$;
CREATE FUNCTION public.save_procurement_supplier(p_business_id uuid,p_data jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result uuid;
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF length(btrim(coalesce(p_data->>'name',''))) NOT BETWEEN 2 AND 200 OR length(p_data::text)>5000 THEN RAISE EXCEPTION 'Enter a supplier name and bounded contact details.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-contact:'||p_business_id::text,0));
 SELECT id INTO result FROM public.pharmacy_crm_companies WHERE pharmacy_id=p_business_id AND NOT archived AND lower(btrim(name))=lower(btrim(p_data->>'name')) AND coalesce(phone,'')=coalesce(p_data->>'phone','') AND coalesce(procurement_email,'')=coalesce(p_data->>'email','') LIMIT 1;
 IF result IS NOT NULL THEN RETURN result; END IF;
 INSERT INTO public.pharmacy_crm_companies(pharmacy_id,name,company_type,phone,location,procurement_email,procurement_contact_person,notes,created_by,updated_by) VALUES(p_business_id,btrim(p_data->>'name'),'supplier',p_data->>'phone',p_data->>'address',p_data->>'email',p_data->>'contact_person',p_data->>'notes',auth.uid(),auth.uid()) RETURNING id INTO result;
 PERFORM public.write_audit_log('PROCUREMENT_SUPPLIER_CREATED','Business','company',result,'Private procurement supplier','{}'::jsonb,_business_id=>p_business_id);
 RETURN result;
END $$;
CREATE POLICY "Business processors read own supply documents" ON public.external_supply_orders FOR SELECT TO authenticated USING(public.can_prepare_procurement(pharmacy_id));
CREATE POLICY "Business processors read own supply history" ON public.external_supply_order_events FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.external_supply_orders o WHERE o.id=order_id AND public.can_prepare_procurement(o.pharmacy_id)));
CREATE OR REPLACE FUNCTION public.save_external_supply_order(p_pharmacy_id uuid,p_data jsonb,p_request_id uuid,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.external_supply_orders%ROWTYPE; line jsonb; result uuid; source_id uuid:=NULLIF(p_data->>'source_request_id','')::uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_prepare_procurement(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') THEN RAISE EXCEPTION 'Purchase processing permission required.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||p_pharmacy_id::text,0));
 IF p_id IS NULL THEN
 SELECT * INTO o FROM public.external_supply_orders WHERE pharmacy_id=p_pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN IF o.request_hash<>md5(p_data::text) THEN RAISE EXCEPTION 'Request already used for different data.'; END IF; RETURN o.id; END IF;
 ELSE
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id AND pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF NOT FOUND OR o.status<>'draft' OR o.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Draft changed or already issued. Reload first.'; END IF;
 END IF;
 IF p_request_id IS NULL OR p_data->>'kind' IS NULL OR p_data->>'kind' NOT IN ('request','order') OR length(p_data->>'supplier')>200 THEN RAISE EXCEPTION 'Choose a document type and supplier.'; END IF;
 IF nullif(p_data->>'supplier_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_companies WHERE id=(p_data->>'supplier_id')::uuid AND pharmacy_id=p_pharmacy_id AND NOT archived) THEN RAISE EXCEPTION 'Supplier is unavailable in this business.'; END IF;
 IF length(COALESCE(p_data->>'notes',''))>2000 OR length(COALESCE(p_data->>'delivery_address',''))>1000 OR length(COALESCE(p_data->>'supplier_contact',''))>300 THEN RAISE EXCEPTION 'Contact, delivery or notes are too long.'; END IF;

 IF jsonb_typeof(p_data->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'lines') NOT BETWEEN 0 AND 200 THEN RAISE EXCEPTION 'Enter 1 to 200 items.'; END IF;
 IF length(p_data::text)>500000 THEN RAISE EXCEPTION 'Document is too large.'; END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(p_data->'lines') LOOP
 IF coalesce(line->>'unit','packs') NOT IN ('packs','boxes','bottles','tubes','vials','ampoules','pieces') THEN RAISE EXCEPTION 'Unsupported quantity unit.'; END IF;
 IF nullif(line->>'catalogue_id','') IS NOT NULL AND (
 (line->>'catalogue_source'='business' AND EXISTS(SELECT 1 FROM public.business_procurement_catalogue WHERE id=(line->>'catalogue_id')::uuid AND business_id=p_pharmacy_id AND NOT archived)) OR
 (line->>'catalogue_source'='master' AND EXISTS(SELECT 1 FROM public.master_products WHERE id=(line->>'catalogue_id')::uuid AND active))
 ) IS DISTINCT FROM true THEN RAISE EXCEPTION 'Catalogue selection is unavailable in this business.'; END IF;
 IF NULLIF(line->>'id','')::uuid IS NULL OR length(line->>'name')>300 OR length(COALESCE(line->>'specification',''))>1000 OR (line->>'quantity')::numeric IS NULL OR (line->>'quantity')::numeric NOT BETWEEN 1 AND 1000000 OR (line->>'quantity')::numeric<>trunc((line->>'quantity')::numeric) THEN RAISE EXCEPTION 'Each item needs an ID, name and positive whole pack quantity.'; END IF;
 IF line->>'unit_price' IS NOT NULL AND ((line->>'unit_price')::numeric<0 OR (line->>'unit_price')::numeric>=100000000 OR (line->>'unit_price')::numeric<>round((line->>'unit_price')::numeric,2)) THEN RAISE EXCEPTION 'Enter a valid price with at most two decimal places.'; END IF;
 END LOOP;
 IF (SELECT COALESCE(sum((value->>'quantity')::numeric*COALESCE((value->>'unit_price')::numeric,0)),0) FROM jsonb_array_elements(p_data->'lines'))>=1000000000000 THEN RAISE EXCEPTION 'Order total exceeds the supported purchase amount.'; END IF;
 IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p_data->'lines'))<>jsonb_array_length(p_data->'lines') THEN RAISE EXCEPTION 'Use unique item names and IDs; include strength and pack size in the name.'; END IF;
 IF source_id IS NOT NULL AND (p_data->>'kind'<>'order' OR NOT EXISTS(SELECT 1 FROM public.external_supply_orders WHERE id=source_id AND pharmacy_id=p_pharmacy_id AND kind='request' AND status IN ('issued','shared'))) THEN RAISE EXCEPTION 'Choose an issued request from this pharmacy.'; END IF;
 IF p_id IS NULL THEN
 INSERT INTO public.external_supply_orders(pharmacy_id,kind,data,source_request_id,request_id,request_hash,created_by) VALUES(p_pharmacy_id,p_data->>'kind',p_data,source_id,p_request_id,md5(p_data::text),auth.uid()) RETURNING id INTO result;
 ELSE
 result:=p_id; UPDATE public.external_supply_orders SET kind=p_data->>'kind',data=p_data,source_request_id=source_id,version=version+1 WHERE id=result;
 END IF;
 INSERT INTO public.external_supply_order_events(order_id,actor_id,action) VALUES(result,auth.uid(),CASE WHEN p_id IS NULL THEN 'created' ELSE 'draft_updated' END);
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.transition_external_supply_order(p_id uuid,p_version integer,p_action text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.external_supply_orders%ROWTYPE;
BEGIN
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_prepare_procurement(o.pharmacy_id) OR NOT public.can_act_for_business(o.pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||o.pharmacy_id::text,0));
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id FOR UPDATE;
 IF o.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Document changed. Reload first.'; END IF;
 IF NOT ((p_action='issued' AND o.status='draft') OR (p_action='shared' AND o.status='issued') OR (p_action='confirmed' AND o.kind='order' AND o.status='shared') OR (p_action='cancelled' AND o.status IN ('draft','issued','shared','confirmed'))) OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid document transition.'; END IF;
 IF p_action='issued' AND (nullif(btrim(o.data->>'supplier'),'') IS NULL OR jsonb_array_length(o.data->'lines')=0 OR EXISTS(SELECT 1 FROM jsonb_array_elements(o.data->'lines') l WHERE nullif(btrim(l->>'name'),'') IS NULL) OR nullif(o.data->>'required_date','')::date<current_date) THEN RAISE EXCEPTION 'Complete the supplier, medicine lines and delivery date before issuing.'; END IF;
 IF p_action='issued' AND (SELECT count(DISTINCT lower(btrim(value->>'name'))) FROM jsonb_array_elements(o.data->'lines'))<>jsonb_array_length(o.data->'lines') THEN RAISE EXCEPTION 'Use distinct item names, strength and pack size before issuing.'; END IF;
 IF p_action='issued' AND o.kind='order'  AND EXISTS(SELECT 1 FROM jsonb_array_elements(o.data->'lines') l WHERE l->>'unit_price' IS NULL) THEN RAISE EXCEPTION 'Purchase orders need an agreed unit price for every item.'; END IF;
 UPDATE public.external_supply_orders SET status=p_action,version=version+1,issuer=CASE WHEN p_action='issued' THEN public.document_identity(o.pharmacy_id) ELSE issuer END,issued_at=CASE WHEN p_action='issued' THEN now() ELSE issued_at END WHERE id=p_id;
 INSERT INTO public.external_supply_order_events(order_id,actor_id,action) VALUES(p_id,auth.uid(),p_action);
END $$;

REVOKE ALL ON FUNCTION public.save_procurement_medicine(uuid,jsonb,uuid,integer,boolean),public.search_procurement_catalogue(uuid,text,text,integer),public.procurement_suppliers(uuid,text),public.save_procurement_supplier(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_procurement_medicine(uuid,jsonb,uuid,integer,boolean),public.search_procurement_catalogue(uuid,text,text,integer),public.procurement_suppliers(uuid,text),public.save_procurement_supplier(uuid,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.save_external_purchase(p_pharmacy_id uuid,p_data jsonb,p_request_id uuid,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE oid uuid:=NULLIF(p_data->>'external_order_id','')::uuid; o public.external_supply_orders%ROWTYPE; old_receipt public.external_purchases%ROWTYPE; result uuid; line jsonb; planned jsonb; allocations jsonb:='[]'; used numeric;
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||p_pharmacy_id::text,0));
 SELECT * INTO old_receipt FROM public.external_purchases WHERE pharmacy_id=p_pharmacy_id AND (id=p_id OR (p_id IS NULL AND request_id=p_request_id));
 IF old_receipt.external_order_id IS NOT NULL AND oid IS DISTINCT FROM old_receipt.external_order_id THEN RAISE EXCEPTION 'A linked receipt cannot be detached or moved to another order.'; END IF;
 IF oid IS NOT NULL THEN
 SELECT * INTO o FROM public.external_supply_orders WHERE id=oid AND pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF NOT FOUND OR o.kind<>'order' OR o.status='draft' OR (o.status='cancelled' AND old_receipt.id IS NULL) THEN RAISE EXCEPTION 'Choose an issued, active purchase order in this pharmacy.'; END IF;
 IF jsonb_typeof(p_data->'items') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Receipt items required.'; END IF;
 IF (SELECT count(DISTINCT value->>'external_order_line_id') FROM jsonb_array_elements(p_data->'items'))<>jsonb_array_length(p_data->'items') THEN RAISE EXCEPTION 'Every receipt line must match a distinct order line.'; END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(p_data->'items') LOOP
 SELECT value INTO planned FROM jsonb_array_elements(o.data->'lines') WHERE value->>'id'=line->>'external_order_line_id';
 IF coalesce(planned->>'unit','packs') <> 'packs' THEN RAISE EXCEPTION 'This order uses non-pack units. Pack conversion is required before recording through the pack-based receiving workflow.'; END IF;
 IF planned IS NULL OR line#>>'{product,name}' IS DISTINCT FROM planned->>'name' OR NULLIF(line->>'master_product_id','') IS NOT NULL THEN RAISE EXCEPTION 'Keep the ordered medicine name for linked receipts; map it to inventory without replacing the catalogue identity.'; END IF;
 SELECT COALESCE(sum((a->>'quantity')::numeric),0) INTO used FROM public.external_purchases p CROSS JOIN LATERAL jsonb_array_elements(p.external_order_allocations) a WHERE p.external_order_id=oid AND p.id IS DISTINCT FROM old_receipt.id AND a->>'line_id'=planned->>'id';
 IF (line->>'quantity')::numeric IS NULL OR (line->>'quantity')::numeric+used>(planned->>'quantity')::numeric THEN RAISE EXCEPTION 'Received quantity exceeds the outstanding ordered quantity.'; END IF;
 IF o.status='cancelled' AND (line->>'quantity')::numeric>COALESCE((SELECT (a->>'quantity')::numeric FROM jsonb_array_elements(old_receipt.external_order_allocations) a WHERE a->>'line_id'=planned->>'id'),0) THEN RAISE EXCEPTION 'Cannot increase received quantity on a cancelled order.'; END IF;
 allocations:=allocations||jsonb_build_array(jsonb_build_object('line_id',planned->>'id','product_name',planned->>'name','quantity',(line->>'quantity')::integer));
 END LOOP;
 END IF;
 result:=public.save_external_purchase_before_orders(p_pharmacy_id,p_data,p_request_id,p_id,p_version);
 UPDATE public.external_purchases SET external_order_id=oid,external_order_allocations=allocations WHERE id=result;
 RETURN result;
END $$;

COMMIT;
