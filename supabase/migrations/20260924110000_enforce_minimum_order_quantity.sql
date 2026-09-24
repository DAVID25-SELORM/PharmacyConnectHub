-- Enforce each supplier's minimum order quantity inside the atomic checkout path.
-- Same function as before with one added check; prices and stock stay server-authoritative.
CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
  v_discount RECORD;
  v_subtotal NUMERIC;
  v_discount_total NUMERIC;
  v_has_discount BOOLEAN;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN RAISE EXCEPTION 'caller_id and pharmacy_id are required.'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'At least one item is required.'; END IF;

  SELECT id, owner_id, type, verification_status INTO v_business FROM public.businesses WHERE id = _pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_business.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.'; END IF;
  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role INTO v_role FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id AND bs.user_id = _caller_id AND bs.status = 'active' LIMIT 1;
    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.'; END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (product_id UUID PRIMARY KEY, quantity INTEGER NOT NULL CHECK (quantity > 0)) ON COMMIT DROP;
  INSERT INTO tmp_requested_items
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (SELECT (item ->> 'productId')::UUID product_id, (item ->> 'quantity')::INTEGER quantity FROM jsonb_array_elements(_items) item) raw
  WHERE raw.product_id IS NOT NULL AND raw.quantity > 0 GROUP BY raw.product_id;
  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN RAISE EXCEPTION 'Each item needs a valid productId and quantity.'; END IF;
  IF (SELECT COUNT(*) FROM public.products p JOIN tmp_requested_items r ON r.product_id = p.id) <> v_requested_count THEN RAISE EXCEPTION 'One or more products could not be found.'; END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY, wholesaler_id UUID NOT NULL, product_name TEXT NOT NULL,
    base_unit_price_ghs NUMERIC(10,2) NOT NULL, unit_price_ghs NUMERIC(10,2) NOT NULL,
    discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0, quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT p.id, p.name, p.price_ghs, p.stock, p.active, p.wholesaler_id, b.name wholesaler_name,
      b.verification_status wholesaler_status, r.quantity,
      COALESCE(wp.minimum_order_quantity, 1) AS min_qty
    FROM tmp_requested_items r JOIN public.products p ON p.id = r.product_id JOIN public.businesses b ON b.id = p.wholesaler_id
    LEFT JOIN public.wholesaler_products wp ON wp.id = p.id
    FOR UPDATE OF p
  LOOP
    IF NOT v_product.active THEN RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name; END IF;
    IF v_product.wholesaler_status <> 'approved' THEN RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name; END IF;
    IF v_product.stock <= 0 THEN RAISE EXCEPTION '% is currently out of stock.', v_product.name; END IF;
    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name; END IF;
    IF v_product.quantity < v_product.min_qty THEN RAISE EXCEPTION 'The minimum order for % is % unit(s).', v_product.name, v_product.min_qty; END IF;
    UPDATE public.products SET stock = stock - v_product.quantity WHERE id = v_product.id;
    INSERT INTO tmp_locked_products(product_id, wholesaler_id, product_name, base_unit_price_ghs, unit_price_ghs, quantity)
    VALUES (v_product.id, v_product.wholesaler_id, v_product.name, v_product.price_ghs, v_product.price_ghs, v_product.quantity);
  END LOOP;

  FOR v_wholesaler IN SELECT wholesaler_id FROM tmp_locked_products GROUP BY wholesaler_id LOOP
    SELECT SUM(base_unit_price_ghs * quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    SELECT d.* INTO v_discount FROM public.customer_discounts d
    WHERE d.wholesaler_id = v_wholesaler.wholesaler_id AND d.pharmacy_id = _pharmacy_id AND d.active
      AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now()) AND v_subtotal >= d.minimum_order_value
    ORDER BY d.starts_at DESC, d.created_at DESC LIMIT 1;
    v_has_discount := FOUND;

    IF v_has_discount THEN
      IF v_discount.discount_type = 'percentage' THEN
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2)) * quantity, 2)
        WHERE wholesaler_id = v_wholesaler.wholesaler_id;
      ELSE
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / NULLIF(v_subtotal, 0) * v_discount.discount_amount) / quantity, 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / NULLIF(v_subtotal, 0) * v_discount.discount_amount) / quantity, 2)) * quantity, 2)
        WHERE wholesaler_id = v_wholesaler.wholesaler_id;
      END IF;
    END IF;

    SELECT COALESCE(SUM(discount_amount_ghs), 0) INTO v_discount_total FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, total_ghs, payment_method)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_subtotal - v_discount_total, 'cod') RETURNING id INTO v_order_id;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) TO service_role;
