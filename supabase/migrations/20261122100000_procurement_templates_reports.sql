-- Private reusable snapshot lists; marketplace reorder lists require master IDs and cannot hold these entries.
BEGIN;
CREATE TABLE public.procurement_templates (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), business_id uuid NOT NULL REFERENCES public.businesses(id), name text NOT NULL CHECK(length(btrim(name)) BETWEEN 1 AND 80), lines jsonb NOT NULL,
 version integer NOT NULL DEFAULT 1, archived boolean NOT NULL DEFAULT false, created_by uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(business_id,name)
);
ALTER TABLE public.procurement_templates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_templates FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.procurement_templates TO authenticated;
CREATE POLICY "Own business templates" ON public.procurement_templates FOR SELECT TO authenticated USING(public.can_prepare_procurement(business_id));
CREATE FUNCTION public.save_procurement_template(p_business_id uuid,p_name text,p_lines jsonb,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL,p_archived boolean DEFAULT false) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result uuid; item jsonb; sanitized jsonb:='[]';
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 80 OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 200 OR length(p_lines::text)>500000 THEN RAISE EXCEPTION 'Enter a list name and 1 to 200 items.'; END IF;
 FOR item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
 IF nullif(btrim(item->>'name'),'') IS NULL OR (item->>'quantity')::numeric IS NULL OR (item->>'quantity')::numeric NOT BETWEEN 1 AND 1000000 OR (item->>'quantity')::numeric<>trunc((item->>'quantity')::numeric) THEN RAISE EXCEPTION 'Template items need names and whole quantities.'; END IF;
 sanitized:=sanitized||jsonb_build_array(item||'{"unit_price":null}'::jsonb);
 END LOOP;
 PERFORM pg_advisory_xact_lock(hashtextextended('procurement-template:'||p_business_id::text,0));
 IF p_id IS NULL THEN
 SELECT id INTO result FROM public.procurement_templates WHERE business_id=p_business_id AND name=btrim(p_name) AND lines=sanitized AND NOT archived;
 IF FOUND THEN RETURN result; END IF;
 INSERT INTO public.procurement_templates(business_id,name,lines,created_by) VALUES(p_business_id,btrim(p_name),sanitized,auth.uid()) RETURNING id INTO result;
 ELSE
 UPDATE public.procurement_templates SET name=btrim(p_name),lines=sanitized,version=version+1,archived=coalesce(p_archived,false),updated_at=now() WHERE id=p_id AND business_id=p_business_id AND version=p_version RETURNING id INTO result;
 IF result IS NULL THEN RAISE EXCEPTION 'Template changed. Reload first.'; END IF;
 END IF;
 PERFORM public.write_audit_log('PROCUREMENT_TEMPLATE_SAVED','Business','procurement_template',result,'Private procurement template','{}'::jsonb,_business_id=>p_business_id);
 RETURN result;
END $$;
CREATE FUNCTION public.procurement_document_report(p_business_id uuid,p_from date DEFAULT NULL,p_to date DEFAULT NULL,p_query text DEFAULT '',p_offset integer DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public SET timezone='Africa/Accra' AS $$
BEGIN
 IF NOT public.can_prepare_procurement(p_business_id) THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from>p_to THEN RAISE EXCEPTION 'End date must be on or after start date.'; END IF;
 RETURN (SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (
 SELECT o.id,o.reference,o.kind,o.status,o.created_at,o.data->>'supplier' supplier,l->>'name' medicine,coalesce(l->>'unit','packs') unit,(l->>'quantity')::numeric ordered_quantity,(l->>'unit_price')::numeric unit_price,
 (SELECT coalesce(sum((a->>'quantity')::numeric),0) FROM public.external_purchases p CROSS JOIN LATERAL jsonb_array_elements(p.external_order_allocations) a WHERE p.pharmacy_id=p_business_id AND p.external_order_id=o.id AND a->>'line_id'=l->>'id') received_quantity
 FROM public.external_supply_orders o CROSS JOIN LATERAL jsonb_array_elements(o.data->'lines') l
 WHERE o.pharmacy_id=p_business_id AND (p_from IS NULL OR o.created_at>=p_from::timestamptz) AND (p_to IS NULL OR o.created_at<(p_to+1)::timestamptz)
 AND (coalesce(p_query,'')='' OR concat_ws(' ',o.reference,o.data->>'supplier',l->>'name') ILIKE '%'||left(p_query,200)||'%')
 ORDER BY o.created_at DESC,o.id,l->>'id' LIMIT 101 OFFSET greatest(0,least(coalesce(p_offset,0),100000))
 ) x);
END $$;
REVOKE ALL ON FUNCTION public.save_procurement_template(uuid,text,jsonb,uuid,integer,boolean),public.procurement_document_report(uuid,date,date,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_procurement_template(uuid,text,jsonb,uuid,integer,boolean),public.procurement_document_report(uuid,date,date,text,integer) TO authenticated;
COMMIT;
