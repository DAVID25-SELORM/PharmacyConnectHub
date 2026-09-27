-- Product-specific customer discounts.
--
-- A wholesaler can give one pharmacy a percentage off ONE product, optionally only from a minimum
-- quantity ("10 cartons -> 15%"), with an optional date window. Rules:
--   * for each order line the best applicable rule wins (highest percentage, then highest minimum
--     quantity); a rule applies when it is active, inside its dates and the line quantity reaches its
--     minimum quantity;
--   * a product-specific rule REPLACES the pharmacy's general customer discount on that line (even if
--     it is smaller), so a wholesaler can say "5% on everything, but 10% on Zuriplex";
--   * the general discount is then worked out over the lines WITHOUT a product rule (a fixed-amount
--     general discount is shared out over those lines only and never exceeds their value);
--   * the general discount's own minimum order value is still tested against the whole cart.
--   * order_items.discount_source records 'product' or 'customer'; orders.discount_type is 'product'
--     when only product rules applied.
-- Owner/manager only to manage; pharmacies read their own rules (without internal notes). Percentages
-- are limited to 90% to catch typing mistakes. Not built: rules for all pharmacies at once, fixed-amount
-- product prices, rules by category.

CREATE TABLE public.product_discounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  discount_percent NUMERIC(5,2) NOT NULL CHECK (discount_percent > 0 AND discount_percent <= 90),
  min_quantity INTEGER NOT NULL DEFAULT 1 CHECK (min_quantity BETWEEN 1 AND 100000),
  starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ends_at TIMESTAMPTZ,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  internal_note TEXT CHECK (internal_note IS NULL OR char_length(internal_note) <= 500),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
CREATE UNIQUE INDEX product_discounts_one_active_rule
  ON public.product_discounts (wholesaler_id, pharmacy_id, product_id, min_quantity) WHERE active;
CREATE INDEX product_discounts_lookup ON public.product_discounts (pharmacy_id, product_id) WHERE active;
CREATE INDEX product_discounts_wholesaler ON public.product_discounts (wholesaler_id, active, created_at DESC);
CREATE TRIGGER trg_product_discounts_updated BEFORE UPDATE ON public.product_discounts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.product_discounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read product discounts" ON public.product_discounts FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.product_discounts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.product_discounts TO authenticated;

ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS discount_source TEXT CHECK (discount_source IS NULL OR discount_source IN ('customer', 'product'));

CREATE OR REPLACE FUNCTION public.upsert_product_discount(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_product_id UUID,
  p_percent NUMERIC,
  p_min_quantity INTEGER DEFAULT 1,
  p_starts_at TIMESTAMPTZ DEFAULT now(),
  p_ends_at TIMESTAMPTZ DEFAULT NULL,
  p_note TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_org TEXT;
  v_pharmacy TEXT;
  v_product TEXT;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_start TIMESTAMPTZ := COALESCE(p_starts_at, now());
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage discounts.';
  END IF;
  SELECT b.name INTO v_org FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.type::TEXT = 'wholesaler';
  IF v_org IS NULL THEN RAISE EXCEPTION 'Product discounts are only available for wholesalers.'; END IF;
  SELECT b.name INTO v_pharmacy FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type::TEXT = 'pharmacy';
  IF v_pharmacy IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  SELECT p.name INTO v_product FROM public.products p WHERE p.id = p_product_id AND p.wholesaler_id = p_wholesaler_id;
  IF v_product IS NULL THEN RAISE EXCEPTION 'Choose one of your own products.'; END IF;
  IF p_percent IS NULL OR p_percent <= 0 OR p_percent > 90 THEN RAISE EXCEPTION 'The discount must be above 0%% and at most 90%%.'; END IF;
  IF p_min_quantity IS NULL OR p_min_quantity < 1 OR p_min_quantity > 100000 THEN RAISE EXCEPTION 'The minimum quantity must be between 1 and 100,000.'; END IF;
  IF p_ends_at IS NOT NULL AND p_ends_at <= v_start THEN RAISE EXCEPTION 'The end date must be after the start date.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The note is too long (500 characters maximum).'; END IF;

  UPDATE public.product_discounts SET active = FALSE, updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND product_id = p_product_id
    AND min_quantity = p_min_quantity AND active;

  INSERT INTO public.product_discounts (wholesaler_id, pharmacy_id, product_id, discount_percent, min_quantity, starts_at, ends_at, internal_note, created_by, updated_by)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_product_id, round(p_percent, 2), p_min_quantity, v_start, p_ends_at, v_note, auth.uid(), auth.uid())
  RETURNING id INTO v_id;

  PERFORM public.write_audit_log('Product discount set', v_org, 'product_discount', v_id, v_product || ' -> ' || v_pharmacy,
    jsonb_build_object('percent', p_percent, 'min_quantity', p_min_quantity));
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_product_discount(p_discount_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rule public.product_discounts%ROWTYPE;
  v_org TEXT;
BEGIN
  SELECT * INTO v_rule FROM public.product_discounts WHERE id = p_discount_id FOR UPDATE;
  IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_act_for_business(v_rule.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to change this discount.';
  END IF;
  IF NOT v_rule.active THEN RETURN FALSE; END IF;
  UPDATE public.product_discounts SET active = FALSE, updated_by = auth.uid() WHERE id = p_discount_id;
  SELECT name INTO v_org FROM public.businesses WHERE id = v_rule.wholesaler_id;
  PERFORM public.write_audit_log('Product discount removed', v_org, 'product_discount', p_discount_id, NULL, '{}'::JSONB);
  RETURN TRUE;
END;
$$;

-- Wholesaler view (owner/manager): active rules by default, with names and list prices.
CREATE OR REPLACE FUNCTION public.list_wholesaler_product_discounts(
  p_wholesaler_id UUID,
  p_include_inactive BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
  id UUID,
  pharmacy_id UUID,
  pharmacy_name TEXT,
  product_id UUID,
  product_name TEXT,
  list_price_ghs NUMERIC,
  discount_percent NUMERIC,
  min_quantity INTEGER,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  active BOOLEAN,
  internal_note TEXT,
  total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may view discounts.';
  END IF;
  RETURN QUERY
  SELECT d.id, d.pharmacy_id, ph.name, d.product_id, pr.name, pr.price_ghs, d.discount_percent, d.min_quantity,
    d.starts_at, d.ends_at, d.active, d.internal_note, COUNT(*) OVER ()
  FROM public.product_discounts d
  JOIN public.businesses ph ON ph.id = d.pharmacy_id
  JOIN public.products pr ON pr.id = d.product_id
  WHERE d.wholesaler_id = p_wholesaler_id AND (p_include_inactive OR d.active)
  ORDER BY d.active DESC, ph.name, pr.name, d.min_quantity
  LIMIT v_limit OFFSET v_offset;
END;
$$;

-- Pharmacy view: the rules that apply to this pharmacy right now (no internal notes).
CREATE OR REPLACE FUNCTION public.list_my_product_discounts(p_pharmacy_id UUID)
RETURNS TABLE (
  product_id UUID,
  wholesaler_id UUID,
  discount_percent NUMERIC,
  min_quantity INTEGER,
  ends_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s discounts.';
  END IF;
  RETURN QUERY
  SELECT d.product_id, d.wholesaler_id, d.discount_percent, d.min_quantity, d.ends_at
  FROM public.product_discounts d
  WHERE d.pharmacy_id = p_pharmacy_id AND d.active AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now())
  ORDER BY d.product_id, d.min_quantity
  LIMIT 2000;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_product_discount(UUID, UUID, UUID, NUMERIC, INTEGER, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.deactivate_product_discount(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_wholesaler_product_discounts(UUID, BOOLEAN, INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_my_product_discounts(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_product_discount(UUID, UUID, UUID, NUMERIC, INTEGER, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_product_discount(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_product_discounts(UUID, BOOLEAN, INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_product_discounts(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Checkout: same function as before (order terms, minimum quantity, customer discounts, stock
-- reservation) plus product-specific discounts.
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
  v_general_base NUMERIC;
  v_specific_count INTEGER;
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
    discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0, quantity INTEGER NOT NULL CHECK (quantity > 0),
    specific_discount BOOLEAN NOT NULL DEFAULT FALSE, discount_source TEXT
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

  -- Product-specific discounts for this pharmacy. For each line the best rule that applies (active, in its
  -- date window, minimum quantity reached) wins, and it REPLACES the general customer discount on that line.
  UPDATE tmp_locked_products t
  SET unit_price_ghs = round(t.base_unit_price_ghs * (1 - r.pct / 100), 2),
      discount_amount_ghs = round((t.base_unit_price_ghs - round(t.base_unit_price_ghs * (1 - r.pct / 100), 2)) * t.quantity, 2),
      specific_discount = TRUE,
      discount_source = 'product'
  FROM (
    SELECT DISTINCT ON (x.product_id) x.product_id, d.discount_percent AS pct
    FROM tmp_locked_products x
    JOIN public.product_discounts d
      ON d.product_id = x.product_id AND d.wholesaler_id = x.wholesaler_id AND x.quantity >= d.min_quantity
    WHERE d.pharmacy_id = _pharmacy_id AND d.active AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now())
    ORDER BY x.product_id, d.discount_percent DESC, d.min_quantity DESC, d.created_at DESC
  ) r
  WHERE r.product_id = t.product_id;

  FOR v_wholesaler IN SELECT wholesaler_id FROM tmp_locked_products GROUP BY wholesaler_id LOOP
    SELECT SUM(base_unit_price_ghs * quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    SELECT d.* INTO v_discount FROM public.customer_discounts d
    WHERE d.wholesaler_id = v_wholesaler.wholesaler_id AND d.pharmacy_id = _pharmacy_id AND d.active
      AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now()) AND v_subtotal >= d.minimum_order_value
    ORDER BY d.starts_at DESC, d.created_at DESC LIMIT 1;
    v_has_discount := FOUND;

    -- The general discount is shared out over the lines that do NOT have a product-specific rule.
    SELECT COALESCE(SUM(base_unit_price_ghs * quantity) FILTER (WHERE NOT specific_discount), 0), COUNT(*) FILTER (WHERE specific_discount)
      INTO v_general_base, v_specific_count
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    IF v_has_discount AND v_general_base = 0 THEN v_has_discount := FALSE; END IF;

    IF v_has_discount THEN
      IF v_discount.discount_type = 'percentage' THEN
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
      ELSE
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
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
      CASE WHEN v_has_discount THEN v_discount.discount_type WHEN v_specific_count > 0 THEN 'product' ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod') RETURNING id INTO v_order_id;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) TO service_role;
