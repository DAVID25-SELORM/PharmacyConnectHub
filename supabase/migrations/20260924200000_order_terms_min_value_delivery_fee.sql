-- Wholesaler order terms: minimum order value and delivery fee (with optional free-delivery threshold).
--
--   * min_order_value_ghs: an order to this wholesaler must be worth at least this much for goods
--     AFTER customer discounts. Checkout rejects the whole cart (nothing is reserved) otherwise.
--   * delivery_fee_ghs: added to each order to this wholesaler, unless the goods total (after
--     discounts) reaches free_delivery_threshold_ghs. Stored on the order (orders.delivery_fee_ghs)
--     and included in total_ghs, so statements, receipts and payments use the fee-inclusive total.
--   * Terms are read by pharmacies at checkout time only through the functions below; both rules
--     are enforced in create_marketplace_orders, never trusted from the client.
--
-- Not built: per-region delivery fees, fees by weight/volume, terms per customer.
-- Sales reports count total_ghs, so delivery fees are included in reported order totals.

CREATE TABLE public.wholesaler_order_terms (
  wholesaler_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  min_order_value_ghs NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (min_order_value_ghs >= 0 AND min_order_value_ghs <= 1000000),
  delivery_fee_ghs NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee_ghs >= 0 AND delivery_fee_ghs <= 10000),
  free_delivery_threshold_ghs NUMERIC(12,2) CHECK (free_delivery_threshold_ghs IS NULL OR (free_delivery_threshold_ghs > 0 AND free_delivery_threshold_ghs <= 10000000)),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_wholesaler_order_terms_updated BEFORE UPDATE ON public.wholesaler_order_terms
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
ALTER TABLE public.wholesaler_order_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read order terms" ON public.wholesaler_order_terms FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.wholesaler_order_terms FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.wholesaler_order_terms TO authenticated;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS delivery_fee_ghs NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (delivery_fee_ghs >= 0);

-- Owner/manager of the wholesaler sets terms. Passing NULL for the threshold removes free delivery.
CREATE OR REPLACE FUNCTION public.set_order_terms(
  p_wholesaler_id UUID,
  p_min_order_value NUMERIC,
  p_delivery_fee NUMERIC,
  p_free_delivery_threshold NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org TEXT;
  v_type TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to change order terms for this business.';
  END IF;
  SELECT b.name, b.type::TEXT INTO v_org, v_type FROM public.businesses b WHERE b.id = p_wholesaler_id;
  IF v_type IS DISTINCT FROM 'wholesaler' THEN RAISE EXCEPTION 'Order terms are only available for wholesalers.'; END IF;
  IF p_min_order_value IS NULL OR p_min_order_value < 0 OR p_min_order_value > 1000000 THEN
    RAISE EXCEPTION 'The minimum order must be between GHS 0 and GHS 1,000,000.';
  END IF;
  IF p_delivery_fee IS NULL OR p_delivery_fee < 0 OR p_delivery_fee > 10000 THEN
    RAISE EXCEPTION 'The delivery fee must be between GHS 0 and GHS 10,000.';
  END IF;
  IF p_free_delivery_threshold IS NOT NULL AND (p_free_delivery_threshold <= 0 OR p_free_delivery_threshold > 10000000) THEN
    RAISE EXCEPTION 'The free-delivery amount must be above zero.';
  END IF;
  IF p_free_delivery_threshold IS NOT NULL AND p_delivery_fee = 0 THEN
    RAISE EXCEPTION 'Set a delivery fee before setting a free-delivery amount.';
  END IF;
  IF p_free_delivery_threshold IS NOT NULL AND p_free_delivery_threshold < p_min_order_value THEN
    RAISE EXCEPTION 'The free-delivery amount cannot be lower than the minimum order.';
  END IF;

  INSERT INTO public.wholesaler_order_terms (wholesaler_id, min_order_value_ghs, delivery_fee_ghs, free_delivery_threshold_ghs, updated_by)
  VALUES (p_wholesaler_id, round(p_min_order_value, 2), round(p_delivery_fee, 2), round(p_free_delivery_threshold, 2), auth.uid())
  ON CONFLICT (wholesaler_id) DO UPDATE
  SET min_order_value_ghs = EXCLUDED.min_order_value_ghs, delivery_fee_ghs = EXCLUDED.delivery_fee_ghs,
      free_delivery_threshold_ghs = EXCLUDED.free_delivery_threshold_ghs, updated_by = auth.uid();

  PERFORM public.write_audit_log('Order terms updated', v_org, 'business', p_wholesaler_id, v_org,
    jsonb_build_object('min_order_value_ghs', p_min_order_value, 'delivery_fee_ghs', p_delivery_fee,
                       'free_delivery_threshold_ghs', p_free_delivery_threshold));
END;
$$;

-- Terms of approved wholesalers are marketplace information: any signed-in user can read them
-- (pharmacies see them in the cart, wholesalers see their own). Businesses without terms return no row.
CREATE OR REPLACE FUNCTION public.list_order_terms(p_wholesaler_ids UUID[] DEFAULT NULL)
RETURNS TABLE (wholesaler_id UUID, min_order_value_ghs NUMERIC, delivery_fee_ghs NUMERIC, free_delivery_threshold_ghs NUMERIC)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to view order terms.'; END IF;
  RETURN QUERY
  SELECT t.wholesaler_id, t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs
  FROM public.wholesaler_order_terms t
  JOIN public.businesses b ON b.id = t.wholesaler_id
  WHERE b.verification_status::TEXT = 'approved'
    AND (p_wholesaler_ids IS NULL OR t.wholesaler_id = ANY (p_wholesaler_ids))
  LIMIT 500;
END;
$$;

REVOKE ALL ON FUNCTION public.set_order_terms(UUID, NUMERIC, NUMERIC, NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_order_terms(UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_terms(UUID, NUMERIC, NUMERIC, NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_order_terms(UUID[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Checkout: same function as before (customer discounts, minimum order QUANTITY, stock reservation)
-- plus the order terms above.
-- ---------------------------------------------------------------------------
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
  v_terms RECORD;
  v_terms_found BOOLEAN;
  v_goods NUMERIC;
  v_fee NUMERIC;
  v_wholesaler_name TEXT;
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

    -- Wholesaler order terms: minimum order (on the amount payable for goods, after discounts) and delivery fee.
    v_goods := v_subtotal - v_discount_total;
    SELECT t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs INTO v_terms
    FROM public.wholesaler_order_terms t WHERE t.wholesaler_id = v_wholesaler.wholesaler_id;
    v_terms_found := FOUND;
    v_fee := 0;
    IF v_terms_found THEN
      IF v_terms.min_order_value_ghs > 0 AND v_goods < v_terms.min_order_value_ghs THEN
        SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
        RAISE EXCEPTION '% requires a minimum order of GHS % (your order with them is GHS %).',
          v_wholesaler_name, to_char(v_terms.min_order_value_ghs, 'FM999,999,990.00'), to_char(v_goods, 'FM999,999,990.00');
      END IF;
      IF v_terms.delivery_fee_ghs > 0
         AND NOT (v_terms.free_delivery_threshold_ghs IS NOT NULL AND v_goods >= v_terms.free_delivery_threshold_ghs) THEN
        v_fee := v_terms.delivery_fee_ghs;
      END IF;
    END IF;
    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod') RETURNING id INTO v_order_id;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) TO service_role;
