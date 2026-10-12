-- Explicit receiving conversion. Ordered quantities and inventory packs remain distinct.
BEGIN;
CREATE OR REPLACE FUNCTION public.save_external_purchase(p_pharmacy_id uuid,p_data jsonb,p_request_id uuid,p_id uuid DEFAULT NULL,p_version integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE oid uuid:=NULLIF(p_data->>'external_order_id','')::uuid; o public.external_supply_orders%ROWTYPE; old_receipt public.external_purchases%ROWTYPE; result uuid; line jsonb; planned jsonb; allocations jsonb:='[]'; used numeric; factor numeric; ordered_qty numeric; prior_factor numeric; ordered_unit text;
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
 ordered_unit:=coalesce(planned->>'unit','packs');
 factor:=CASE WHEN ordered_unit='packs' THEN 1 ELSE (line->>'external_packs_per_unit')::numeric END;
 IF factor IS NULL OR factor NOT BETWEEN 1 AND 1000000 OR factor<>trunc(factor) THEN RAISE EXCEPTION 'Confirm a positive whole number of inventory packs per ordered unit.'; END IF;
 ordered_qty:=(line->>'quantity')::numeric/factor;
 IF ordered_qty IS NULL OR ordered_qty NOT BETWEEN 1 AND 1000000 OR ordered_qty<>trunc(ordered_qty) THEN RAISE EXCEPTION 'Received inventory packs must equal a positive whole number of ordered units.'; END IF;
 IF ordered_unit<>'packs' AND (line->>'external_order_unit') IS DISTINCT FROM ordered_unit THEN RAISE EXCEPTION 'Receipt unit must match the issued order.'; END IF;
 SELECT (a->>'packs_per_unit')::numeric INTO prior_factor FROM public.external_purchases p CROSS JOIN LATERAL jsonb_array_elements(p.external_order_allocations) a WHERE p.external_order_id=oid AND a->>'line_id'=planned->>'id' AND a->>'packs_per_unit' IS NOT NULL LIMIT 1;
 IF prior_factor IS NOT NULL AND prior_factor<>factor THEN RAISE EXCEPTION 'Use the pack conversion already recorded for this order line.'; END IF;
 IF planned IS NULL OR line#>>'{product,name}' IS DISTINCT FROM planned->>'name' OR NULLIF(line->>'master_product_id','') IS NOT NULL THEN RAISE EXCEPTION 'Keep the ordered medicine name for linked receipts; map it to inventory without replacing the catalogue identity.'; END IF;
 SELECT COALESCE(sum((a->>'quantity')::numeric),0) INTO used FROM public.external_purchases p CROSS JOIN LATERAL jsonb_array_elements(p.external_order_allocations) a WHERE p.external_order_id=oid AND p.id IS DISTINCT FROM old_receipt.id AND a->>'line_id'=planned->>'id';
 IF (line->>'quantity')::numeric IS NULL OR ordered_qty+used>(planned->>'quantity')::numeric THEN RAISE EXCEPTION 'Received quantity exceeds the outstanding ordered quantity.'; END IF;
 IF o.status='cancelled' AND ordered_qty>COALESCE((SELECT (a->>'quantity')::numeric FROM jsonb_array_elements(old_receipt.external_order_allocations) a WHERE a->>'line_id'=planned->>'id'),0) THEN RAISE EXCEPTION 'Cannot increase received quantity on a cancelled order.'; END IF;
 allocations:=allocations||jsonb_build_array(jsonb_build_object('line_id',planned->>'id','product_name',planned->>'name','quantity',ordered_qty::integer,'unit',ordered_unit,'packs_per_unit',factor,'inventory_packs',(line->>'quantity')::integer));
 END LOOP;
 END IF;
 result:=public.save_external_purchase_before_orders(p_pharmacy_id,p_data,p_request_id,p_id,p_version);
 UPDATE public.external_purchases SET external_order_id=oid,external_order_allocations=allocations WHERE id=result;
 RETURN result;
END $$;

COMMIT;
