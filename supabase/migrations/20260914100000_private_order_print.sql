-- Read-only print projection. No public endpoint and no stock/lifecycle mutation.
BEGIN;
-- Additive snapshot for NEW order items only; never backfill historical facts from today's catalogue.
ALTER TABLE public.order_items ADD COLUMN product_details JSONB;
CREATE FUNCTION public.snapshot_order_print_details()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  SELECT jsonb_build_object('brand',p.brand,'generic_name',m.generic_name,'strength',m.strength,
    'dosage_form',p.form,'pack_size',p.pack_size) INTO NEW.product_details
  FROM public.products p LEFT JOIN public.wholesaler_products w ON w.id=p.id
    LEFT JOIN public.master_products m ON m.id=w.product_id
  WHERE p.id=NEW.product_id;
  RETURN NEW;
END $$;
CREATE TRIGGER print_snapshot_details BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_print_details();
REVOKE ALL ON FUNCTION public.snapshot_order_print_details() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_order_print(_business_id UUID, _order_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE context public.businesses%ROWTYPE; purchase public.orders%ROWTYPE; result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501'; END IF;
  SELECT * INTO context FROM public.businesses WHERE id = _business_id;
  IF NOT FOUND OR NOT (context.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), context.id)) THEN
    RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO purchase FROM public.orders WHERE id = _order_id;
  IF NOT FOUND OR NOT ((context.type = 'pharmacy' AND purchase.pharmacy_id = context.id)
    OR (context.type = 'wholesaler' AND purchase.wholesaler_id = context.id)) THEN
    RAISE EXCEPTION 'Order access denied.' USING ERRCODE = '42501';
  END IF;
  -- Explicit projection excludes account credentials, private verification contacts, IDs and internal metadata.
  -- Names, prices and available details come only from historical order-item values.
  -- Older unsnapshotted details remain absent; no present-day catalogue fallback.
  SELECT jsonb_build_object(
    'order_number',purchase.order_number,'created_at',purchase.created_at,'status',purchase.status,
    'payment_status',purchase.payment_status,'payment_method',purchase.payment_method,
    'total_ghs',purchase.total_ghs::TEXT,'notes',purchase.notes,
    'buyer',jsonb_build_object('name',buyer.name,'phone',buyer.phone,'email',buyer.public_email,
      'address',buyer.address,'city',buyer.city,'region',buyer.region,'location_description',buyer.location_description),
    'seller',jsonb_build_object('name',seller.name,'phone',seller.phone,'email',seller.public_email,
      'address',seller.address,'city',seller.city,'region',seller.region,'location_description',seller.location_description),
    'items',coalesce((SELECT jsonb_agg(jsonb_build_object('product_name',i.product_name,
      'quantity',i.quantity,'unit_price_ghs',i.unit_price_ghs::TEXT,
      'brand',i.product_details->>'brand','generic_name',i.product_details->>'generic_name',
      'strength',i.product_details->>'strength','dosage_form',i.product_details->>'dosage_form','pack_size',i.product_details->>'pack_size',
      'line_subtotal_ghs',(i.quantity*i.unit_price_ghs)::TEXT) ORDER BY i.id)
      FROM public.order_items i WHERE i.order_id=purchase.id),'[]'::JSONB)
  ) INTO result FROM public.businesses buyer CROSS JOIN public.businesses seller
    WHERE buyer.id=purchase.pharmacy_id AND seller.id=purchase.wholesaler_id;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_order_print(UUID,UUID) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_order_print(UUID,UUID) TO authenticated;

-- Correct future platform-audit labels without rewriting historical events or migrations.
CREATE OR REPLACE FUNCTION public.audit_platform_staff_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  staff_email TEXT;
BEGIN
  SELECT email INTO staff_email FROM auth.users WHERE id = COALESCE(NEW.user_id, OLD.user_id);

  IF TG_OP = 'INSERT' THEN
    PERFORM public.write_audit_log(
      'Platform staff invited',
      'DrugXone',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object('role', NEW.role, 'status', NEW.status)
    );
    RETURN NEW;
  END IF;

  IF NEW.role IS DISTINCT FROM OLD.role OR NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.write_audit_log(
      'Platform staff updated',
      'DrugXone',
      'platform_staff',
      NEW.id,
      COALESCE(staff_email, NEW.user_id::TEXT),
      jsonb_build_object(
        'from_role', OLD.role,
        'to_role', NEW.role,
        'from_status', OLD.status,
        'to_status', NEW.status
      )
    );
  END IF;

  RETURN NEW;
END;
$$;
COMMIT;
