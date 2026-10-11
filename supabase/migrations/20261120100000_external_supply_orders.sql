-- Pre-receipt procurement. Manual sharing only; no marketplace order or inventory mutation.
BEGIN;
CREATE TABLE public.external_supply_orders (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), pharmacy_id uuid NOT NULL REFERENCES public.businesses(id),
 reference text NOT NULL DEFAULT ('EPO-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
 kind text NOT NULL CHECK(kind IN ('request','order')), status text NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','issued','shared','confirmed','cancelled')),
 data jsonb NOT NULL, issuer jsonb, source_request_id uuid REFERENCES public.external_supply_orders(id),
 request_id uuid NOT NULL, request_hash text NOT NULL, version integer NOT NULL DEFAULT 1,
 created_by uuid NOT NULL REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(), issued_at timestamptz,
 UNIQUE(pharmacy_id,request_id), UNIQUE(pharmacy_id,id)
);
CREATE TABLE public.external_supply_order_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), order_id uuid NOT NULL REFERENCES public.external_supply_orders(id),
 actor_id uuid NOT NULL REFERENCES auth.users(id), action text NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.external_supply_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.external_supply_order_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.external_supply_orders,public.external_supply_order_events FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.external_supply_orders,public.external_supply_order_events TO authenticated;
CREATE POLICY "Read own procurement plans" ON public.external_supply_orders FOR SELECT TO authenticated USING(public.can_access_external_procurement(pharmacy_id));
CREATE POLICY "Read own procurement plan history" ON public.external_supply_order_events FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.external_supply_orders o WHERE o.id=order_id AND public.can_access_external_procurement(o.pharmacy_id)));
ALTER TABLE public.external_purchases ADD COLUMN external_order_id uuid REFERENCES public.external_supply_orders(id), ADD COLUMN external_order_allocations jsonb NOT NULL DEFAULT '[]';
CREATE INDEX external_receipts_order ON public.external_purchases(external_order_id);

CREATE FUNCTION public.save_external_supply_order(p_pharmacy_id uuid,p_data jsonb,p_request_id uuid,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.external_supply_orders%ROWTYPE; line jsonb; result uuid; source_id uuid:=NULLIF(p_data->>'source_request_id','')::uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_access_external_procurement(p_pharmacy_id) OR NOT public.can_act_for_business(p_pharmacy_id,'process') THEN RAISE EXCEPTION 'Purchase processing permission required.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||p_pharmacy_id::text,0));
 IF p_id IS NULL THEN
 SELECT * INTO o FROM public.external_supply_orders WHERE pharmacy_id=p_pharmacy_id AND request_id=p_request_id;
 IF FOUND THEN IF o.request_hash<>md5(p_data::text) THEN RAISE EXCEPTION 'Request already used for different data.'; END IF; RETURN o.id; END IF;
 ELSE
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id AND pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF NOT FOUND OR o.status<>'draft' OR o.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Draft changed or already issued. Reload first.'; END IF;
 END IF;
 IF p_request_id IS NULL OR p_data->>'kind' IS NULL OR p_data->>'kind' NOT IN ('request','order') OR NULLIF(btrim(p_data->>'supplier'),'') IS NULL OR length(p_data->>'supplier')>200 THEN RAISE EXCEPTION 'Choose a document type and supplier.'; END IF;
 IF length(COALESCE(p_data->>'notes',''))>2000 OR length(COALESCE(p_data->>'delivery_address',''))>1000 OR length(COALESCE(p_data->>'supplier_contact',''))>300 THEN RAISE EXCEPTION 'Contact, delivery or notes are too long.'; END IF;
 IF NULLIF(p_data->>'required_date','')::date<current_date THEN RAISE EXCEPTION 'Required date cannot be in the past.'; END IF;
 IF jsonb_typeof(p_data->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_data->'lines') NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Enter 1 to 200 items.'; END IF;
 FOR line IN SELECT value FROM jsonb_array_elements(p_data->'lines') LOOP
 IF NULLIF(line->>'id','')::uuid IS NULL OR NULLIF(btrim(line->>'name'),'') IS NULL OR length(line->>'name')>300 OR length(COALESCE(line->>'specification',''))>1000 OR (line->>'quantity')::numeric IS NULL OR (line->>'quantity')::numeric NOT BETWEEN 1 AND 1000000 OR (line->>'quantity')::numeric<>trunc((line->>'quantity')::numeric) THEN RAISE EXCEPTION 'Each item needs an ID, name and positive whole pack quantity.'; END IF;
 IF line->>'unit_price' IS NOT NULL AND ((line->>'unit_price')::numeric<0 OR (line->>'unit_price')::numeric>=100000000 OR (line->>'unit_price')::numeric<>round((line->>'unit_price')::numeric,2)) THEN RAISE EXCEPTION 'Enter a valid price with at most two decimal places.'; END IF;
 END LOOP;
 IF (SELECT COALESCE(sum((value->>'quantity')::numeric*COALESCE((value->>'unit_price')::numeric,0)),0) FROM jsonb_array_elements(p_data->'lines'))>=1000000000000 THEN RAISE EXCEPTION 'Order total exceeds the supported purchase amount.'; END IF;
 IF (SELECT count(DISTINCT value->>'id') FROM jsonb_array_elements(p_data->'lines'))<>jsonb_array_length(p_data->'lines') OR (SELECT count(DISTINCT lower(btrim(value->>'name'))) FROM jsonb_array_elements(p_data->'lines'))<>jsonb_array_length(p_data->'lines') THEN RAISE EXCEPTION 'Use unique item names and IDs; include strength and pack size in the name.'; END IF;
 IF source_id IS NOT NULL AND (p_data->>'kind'<>'order' OR NOT EXISTS(SELECT 1 FROM public.external_supply_orders WHERE id=source_id AND pharmacy_id=p_pharmacy_id AND kind='request' AND status IN ('issued','shared'))) THEN RAISE EXCEPTION 'Choose an issued request from this pharmacy.'; END IF;
 IF p_id IS NULL THEN
 INSERT INTO public.external_supply_orders(pharmacy_id,kind,data,source_request_id,request_id,request_hash,created_by) VALUES(p_pharmacy_id,p_data->>'kind',p_data,source_id,p_request_id,md5(p_data::text),auth.uid()) RETURNING id INTO result;
 ELSE
 result:=p_id; UPDATE public.external_supply_orders SET kind=p_data->>'kind',data=p_data,source_request_id=source_id,version=version+1 WHERE id=result;
 END IF;
 INSERT INTO public.external_supply_order_events(order_id,actor_id,action) VALUES(result,auth.uid(),CASE WHEN p_id IS NULL THEN 'created' ELSE 'draft_updated' END);
 RETURN result;
END $$;

CREATE FUNCTION public.transition_external_supply_order(p_id uuid,p_version integer,p_action text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE o public.external_supply_orders%ROWTYPE;
BEGIN
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id;
 IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_access_external_procurement(o.pharmacy_id) OR NOT public.can_act_for_business(o.pharmacy_id,'process') THEN RAISE EXCEPTION 'Not authorized.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('external-purchase:'||o.pharmacy_id::text,0));
 SELECT * INTO o FROM public.external_supply_orders WHERE id=p_id FOR UPDATE;
 IF o.version IS DISTINCT FROM p_version THEN RAISE EXCEPTION 'Document changed. Reload first.'; END IF;
 IF NOT ((p_action='issued' AND o.status='draft') OR (p_action='shared' AND o.status='issued') OR (p_action='confirmed' AND o.kind='order' AND o.status='shared') OR (p_action='cancelled' AND o.status IN ('draft','issued','shared','confirmed'))) OR p_action IS NULL THEN RAISE EXCEPTION 'Invalid document transition.'; END IF;
 IF p_action='issued' AND o.kind='order' AND EXISTS(SELECT 1 FROM jsonb_array_elements(o.data->'lines') l WHERE l->>'unit_price' IS NULL) THEN RAISE EXCEPTION 'Purchase orders need an agreed unit price for every item.'; END IF;
 UPDATE public.external_supply_orders SET status=p_action,version=version+1,issuer=CASE WHEN p_action='issued' THEN public.document_identity(o.pharmacy_id) ELSE issuer END,issued_at=CASE WHEN p_action='issued' THEN now() ELSE issued_at END WHERE id=p_id;
 INSERT INTO public.external_supply_order_events(order_id,actor_id,action) VALUES(p_id,auth.uid(),p_action);
END $$;

-- Reuse the existing receipt transaction and keep linkage/quantity checks atomic with it.
ALTER FUNCTION public.save_external_purchase(uuid,jsonb,uuid,uuid,integer) RENAME TO save_external_purchase_before_orders;
REVOKE ALL ON FUNCTION public.save_external_purchase_before_orders(uuid,jsonb,uuid,uuid,integer) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.save_external_purchase(p_pharmacy_id uuid,p_data jsonb,p_request_id uuid,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL)
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
REVOKE ALL ON FUNCTION public.save_external_supply_order(uuid,jsonb,uuid,uuid,integer),public.transition_external_supply_order(uuid,integer,text),public.save_external_purchase(uuid,jsonb,uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_external_supply_order(uuid,jsonb,uuid,uuid,integer),public.transition_external_supply_order(uuid,integer,text),public.save_external_purchase(uuid,jsonb,uuid,uuid,integer) TO authenticated;
COMMIT;
