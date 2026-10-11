BEGIN;
-- A protected, transaction-scoped adapter supplies negotiated prices to the CURRENT
-- checkout implementation. Clients cannot write context or choose authoritative totals.
CREATE TABLE public.rfq_checkout_context(transaction_id BIGINT PRIMARY KEY,group_id UUID NOT NULL REFERENCES public.rfq_confirmation_groups(id),order_id UUID);
ALTER TABLE public.rfq_checkout_context ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.rfq_checkout_context FROM PUBLIC,anon,authenticated;
ALTER TABLE public.orders ADD COLUMN rfq_confirmation_id UUID UNIQUE REFERENCES public.rfq_confirmation_groups(id);

CREATE FUNCTION public.rfq_link_checkout_order() RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g public.rfq_confirmation_groups%ROWTYPE; BEGIN
 SELECT cg.* INTO g FROM public.rfq_confirmation_groups cg JOIN public.rfq_checkout_context c ON c.group_id=cg.id WHERE c.transaction_id=txid_current();
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF NEW.wholesaler_id<>g.wholesaler_id OR NEW.pharmacy_id<>(SELECT pharmacy_id FROM public.rfqs WHERE id=g.rfq_id)
 OR NEW.total_ghs<>g.goods_ghs+g.delivery_ghs THEN RAISE EXCEPTION 'Checkout differs from confirmed award.'; END IF;
 NEW.rfq_confirmation_id:=g.id;
 NEW.notes:=concat_ws(E'\n',NEW.notes,'RFQ '||(SELECT reference FROM public.rfqs WHERE id=g.rfq_id),'Award '||g.id);
 UPDATE public.rfq_checkout_context SET order_id=NEW.id WHERE transaction_id=txid_current();
 RETURN NEW;
END $$;
CREATE TRIGGER rfq_link_checkout_order BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.rfq_link_checkout_order();
REVOKE ALL ON FUNCTION public.rfq_link_checkout_order() FROM PUBLIC,anon,authenticated;

DO $migration$
DECLARE d TEXT; old_price TEXT:='    v_goods := v_subtotal - v_discount_total;';
 old_fee TEXT:='    v_method := NULLIF(_settlement_methods ->> v_wholesaler.wholesaler_id::TEXT, '''');';
 price_patch TEXT:=$patch$
    -- Only a server-created confirmation context can supply negotiated prices.
    IF EXISTS(SELECT 1 FROM public.rfq_checkout_context WHERE transaction_id=txid_current()) THEN
      UPDATE tmp_locked_products t SET base_unit_price_ghs=a.unit_price_ghs,unit_price_ghs=a.unit_price_ghs,
        discount_amount_ghs=0,discount_source=NULL,specific_discount=false
      FROM (SELECT al.product_id,min(al.unit_price_ghs) unit_price_ghs,sum(al.quantity) quantity
        FROM public.rfq_allocations al JOIN public.rfq_checkout_context c ON c.group_id=al.group_id
        WHERE c.transaction_id=txid_current() GROUP BY al.product_id) a
      WHERE t.product_id=a.product_id AND t.quantity=a.quantity;
      IF EXISTS(SELECT 1 FROM tmp_locked_products t WHERE NOT EXISTS(
        SELECT 1 FROM public.rfq_allocations a JOIN public.rfq_checkout_context c ON c.group_id=a.group_id
        WHERE c.transaction_id=txid_current() AND a.product_id=t.product_id
        GROUP BY a.product_id HAVING sum(a.quantity)=t.quantity AND min(a.unit_price_ghs)=t.unit_price_ghs)) THEN
        RAISE EXCEPTION 'Award stock quantities or prices differ from checkout.';
      END IF;
      SELECT sum(unit_price_ghs*quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id=v_wholesaler.wholesaler_id;
      v_discount_total:=0; v_has_discount:=false; v_specific_count:=0;
    END IF;
$patch$;
 fee_patch TEXT:=$patch$
    IF EXISTS(SELECT 1 FROM public.rfq_checkout_context WHERE transaction_id=txid_current()) THEN
      SELECT g.delivery_ghs INTO v_fee FROM public.rfq_confirmation_groups g JOIN public.rfq_checkout_context c ON c.group_id=g.id
      WHERE c.transaction_id=txid_current() AND g.wholesaler_id=v_wholesaler.wholesaler_id;
      IF v_fee IS NULL THEN RAISE EXCEPTION 'Award supplier differs from checkout.'; END IF;
    END IF;
$patch$;
BEGIN
 d:=replace(pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure),E'\r','');
 IF (length(d)-length(replace(d,old_price,'')))/length(old_price)<>1 OR (length(d)-length(replace(d,old_fee,'')))/length(old_fee)<>1 THEN
 RAISE EXCEPTION 'Unexpected checkout body. Review before adding negotiated pricing; nothing changed.'; END IF;
 EXECUTE replace(replace(d,old_price,price_patch||old_price),old_fee,fee_patch||old_fee);
END $migration$;

CREATE FUNCTION public.confirm_rfq_award(p_group_id UUID,p_accept BOOLEAN,p_reason TEXT DEFAULT NULL) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE g public.rfq_confirmation_groups%ROWTYPE; r public.rfqs%ROWTYPE; v public.rfq_quote_versions%ROWTYPE; items JSONB; orderid UUID; failure TEXT;
BEGIN
 SELECT * INTO g FROM public.rfq_confirmation_groups WHERE id=p_group_id;
 IF NOT FOUND OR NOT public.rfq_member(g.wholesaler_id) OR NOT public.can_act_for_business(g.wholesaler_id,'process') THEN RAISE EXCEPTION 'Supplier confirmation permission required.'; END IF;
 SELECT * INTO r FROM public.rfqs WHERE id=g.rfq_id FOR UPDATE;
 SELECT * INTO g FROM public.rfq_confirmation_groups WHERE id=p_group_id FOR UPDATE;
 IF p_accept IS NULL THEN RAISE EXCEPTION 'Acceptance choice required.'; END IF;
 IF g.status='confirmed' AND p_accept THEN RETURN jsonb_build_object('orderId',g.order_id,'status',g.status); END IF;
 IF g.status='declined' AND NOT p_accept THEN RETURN jsonb_build_object('status',g.status); END IF;
 IF g.status NOT IN('pending','conversion_failed') OR r.status IN('cancelled','completed') THEN RAISE EXCEPTION 'Award is no longer awaiting confirmation.'; END IF;
 IF NOT p_accept THEN
 IF NULLIF(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Decline reason required.'; END IF;
 UPDATE public.rfq_confirmation_groups SET status='declined',reason=p_reason,responded_at=now() WHERE id=g.id;
 PERFORM public.rfq_event(r.id,g.wholesaler_id,'AWARD_DECLINED',jsonb_build_object('groupId',g.id,'reason',p_reason));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager'],'rfq_award_declined','Supplier declined award',r.title,'/pharmacy/rfqs?rfq='||r.id);
 RETURN jsonb_build_object('status','declined');
 END IF;
 SELECT * INTO v FROM public.rfq_quote_versions WHERE id=g.quote_version_id;
 -- Subtransaction rolls back every stock, order and credit effect on failure while
 -- preserving a durable, retryable conversion error on the award.
 BEGIN
 IF (v.snapshot->'quote'->>'valid_until')::timestamptz<=now() THEN RAISE EXCEPTION 'Quotation expired. Decline this award and request a new quotation.'; END IF;
 IF EXISTS(SELECT 1 FROM public.rfq_allocations a JOIN public.rfq_items i ON i.id=a.rfq_item_id JOIN LATERAL jsonb_array_elements(v.snapshot->'items') x ON x->>'id'=a.quote_item_id::text WHERE a.group_id=g.id AND (x->>'expiry_date')::date<=GREATEST(current_date,COALESCE(r.expected_delivery_date,current_date))+i.minimum_shelf_life_days) THEN RAISE EXCEPTION 'Award no longer meets shelf-life requirements.'; END IF;
 SELECT jsonb_agg(jsonb_build_object('productId',product_id,'quantity',quantity,'category',category)) INTO items FROM
 (SELECT product_id,sum(quantity) quantity,min(purchase_category) category FROM public.rfq_allocations WHERE group_id=g.id GROUP BY product_id) x;
 -- The supplier responds in a different session from the buyer who proposed
 -- the award. Revalidate that buyer actor before the trusted checkout adapter
 -- passes their identity into the existing order engine.
 IF NOT EXISTS(SELECT 1 FROM public.businesses b WHERE b.id=r.pharmacy_id AND b.verification_status='approved'
   AND (b.owner_id=g.created_by OR EXISTS(SELECT 1 FROM public.business_staff s WHERE s.business_id=b.id
     AND s.user_id=g.created_by AND s.status='active' AND s.role IN('owner','manager','cashier')))) THEN
   RAISE EXCEPTION 'The pharmacy purchaser who proposed this award is no longer authorized. Ask an active manager to create a new award.';
 END IF;
 -- Lock inventory in a deterministic order before the existing engine takes its locks.
 PERFORM 1 FROM public.products WHERE id IN(SELECT product_id FROM public.rfq_allocations WHERE group_id=g.id) ORDER BY id FOR UPDATE;
 INSERT INTO public.rfq_checkout_context(transaction_id,group_id) VALUES(txid_current(),g.id);
 PERFORM public.create_marketplace_orders(g.created_by,r.pharmacy_id,items,'{}',true,jsonb_build_object(g.wholesaler_id::text,g.settlement_method));
 SELECT order_id INTO orderid FROM public.rfq_checkout_context WHERE transaction_id=txid_current();
 IF orderid IS NULL THEN RAISE EXCEPTION 'Checkout did not link an order.'; END IF;
 DELETE FROM public.rfq_checkout_context WHERE transaction_id=txid_current();
 UPDATE public.rfq_confirmation_groups SET status='confirmed',order_id=orderid,responded_at=now(),last_error=NULL WHERE id=g.id;
 UPDATE public.rfqs SET status='in_progress',revision=revision+1 WHERE id=r.id;
 PERFORM public.rfq_event(r.id,g.wholesaler_id,'RFQ_ORDER_CREATED',jsonb_build_object('groupId',g.id,'orderId',orderid));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager','cashier'],'rfq_order_created','RFQ order created',r.title,'/pharmacy?tab=orders');
 EXCEPTION WHEN OTHERS THEN
 GET STACKED DIAGNOSTICS failure=MESSAGE_TEXT;
 UPDATE public.rfq_confirmation_groups SET status='conversion_failed',last_error=failure WHERE id=g.id;
 PERFORM public.rfq_event(r.id,g.wholesaler_id,'ORDER_CONVERSION_FAILED',jsonb_build_object('groupId',g.id,'error',failure));
 RETURN jsonb_build_object('status','conversion_failed','error',failure);
 END;
 RETURN jsonb_build_object('status','confirmed','orderId',orderid);
END $$;
REVOKE ALL ON FUNCTION public.confirm_rfq_award(UUID,BOOLEAN,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirm_rfq_award(UUID,BOOLEAN,TEXT) TO authenticated;
COMMIT;
