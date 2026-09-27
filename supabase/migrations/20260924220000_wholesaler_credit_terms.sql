-- Wholesaler credit terms: an approved credit limit and payment terms for one pharmacy.
--
-- One active agreement per (wholesaler, pharmacy). A pharmacy can ask, per wholesaler, to buy
-- "on credit" instead of paying on delivery; checkout only allows it when the wholesaler has an
-- active credit line for that pharmacy AND the order would not push the outstanding credit balance
-- (unpaid/failed credit orders, not cancelled) above the limit. The limit and outstanding amount are
-- both measured on the goods + delivery fee actually invoiced (after discounts), the same amount as
-- total_ghs. Settling a credit order reuses the existing "confirm payment" flow (api/orders/confirm-
-- payment.ts): once delivered, the wholesaler marks it paid exactly as they would a COD order, which
-- also reduces the outstanding balance. Statements already treat any unpaid order as a debit and any
-- paid order as a credit, regardless of payment method, so credit orders need no statement changes.
--
-- Not built: partial settlement, interest/late fees, automatic overdue reminders, credit for a
-- pharmacy that has no approved verification (blocked implicitly: checkout already requires that).

CREATE TABLE public.wholesaler_credit_terms (
  wholesaler_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  credit_limit_ghs NUMERIC(12,2) NOT NULL CHECK (credit_limit_ghs > 0 AND credit_limit_ghs <= 10000000),
  payment_terms_days INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days BETWEEN 1 AND 365),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  internal_note TEXT CHECK (internal_note IS NULL OR char_length(internal_note) <= 500),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (wholesaler_id, pharmacy_id)
);
CREATE TRIGGER trg_wholesaler_credit_terms_updated BEFORE UPDATE ON public.wholesaler_credit_terms
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.wholesaler_credit_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit terms" ON public.wholesaler_credit_terms FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.wholesaler_credit_terms FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.wholesaler_credit_terms TO authenticated;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS is_credit_order BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS credit_due_date DATE;
CREATE INDEX IF NOT EXISTS orders_credit_outstanding_idx
  ON public.orders (wholesaler_id, pharmacy_id) WHERE is_credit_order AND payment_status IN ('unpaid', 'failed');

CREATE OR REPLACE FUNCTION public.set_credit_terms(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_credit_limit NUMERIC,
  p_payment_terms_days INTEGER,
  p_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org TEXT;
  v_pharmacy TEXT;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  SELECT b.name INTO v_org FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.type::TEXT = 'wholesaler';
  IF v_org IS NULL THEN RAISE EXCEPTION 'Credit terms are only available for wholesalers.'; END IF;
  SELECT b.name INTO v_pharmacy FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type::TEXT = 'pharmacy';
  IF v_pharmacy IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF p_credit_limit IS NULL OR p_credit_limit <= 0 OR p_credit_limit > 10000000 THEN
    RAISE EXCEPTION 'The credit limit must be above GHS 0 and at most GHS 10,000,000.';
  END IF;
  IF p_payment_terms_days IS NULL OR p_payment_terms_days < 1 OR p_payment_terms_days > 365 THEN
    RAISE EXCEPTION 'Payment terms must be between 1 and 365 days.';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The note is too long (500 characters maximum).'; END IF;

  INSERT INTO public.wholesaler_credit_terms (wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days, active, internal_note, created_by, updated_by)
  VALUES (p_wholesaler_id, p_pharmacy_id, round(p_credit_limit, 2), p_payment_terms_days, TRUE, v_note, auth.uid(), auth.uid())
  ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE
  SET credit_limit_ghs = EXCLUDED.credit_limit_ghs, payment_terms_days = EXCLUDED.payment_terms_days,
      active = TRUE, internal_note = EXCLUDED.internal_note, updated_by = auth.uid();

  PERFORM public.write_audit_log('Credit terms updated', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object('credit_limit_ghs', p_credit_limit, 'payment_terms_days', p_payment_terms_days));
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_credit_terms(p_wholesaler_id UUID, p_pharmacy_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_org TEXT;
  v_pharmacy TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  UPDATE public.wholesaler_credit_terms SET active = FALSE, updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND active;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  PERFORM public.write_audit_log('Credit terms revoked', v_org, 'business', p_pharmacy_id, v_pharmacy, '{}'::JSONB);
  RETURN TRUE;
END;
$$;

-- Wholesaler view: every pharmacy with an active credit line, plus outstanding/available.
CREATE OR REPLACE FUNCTION public.list_wholesaler_credit_terms(p_wholesaler_id UUID)
RETURNS TABLE (
  pharmacy_id UUID,
  pharmacy_name TEXT,
  credit_limit_ghs NUMERIC,
  payment_terms_days INTEGER,
  outstanding_ghs NUMERIC,
  available_ghs NUMERIC,
  internal_note TEXT,
  updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may view credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.pharmacy_id, ph.name, c.credit_limit_ghs, c.payment_terms_days,
    COALESCE(o.outstanding, 0::NUMERIC(12,2)),
    c.credit_limit_ghs - COALESCE(o.outstanding, 0::NUMERIC(12,2)),
    c.internal_note, c.updated_at
  FROM public.wholesaler_credit_terms c
  JOIN public.businesses ph ON ph.id = c.pharmacy_id
  LEFT JOIN LATERAL (
    SELECT SUM(ord.total_ghs) AS outstanding FROM public.orders ord
    WHERE ord.wholesaler_id = c.wholesaler_id AND ord.pharmacy_id = c.pharmacy_id
      AND ord.is_credit_order AND ord.status <> 'cancelled' AND ord.payment_status IN ('unpaid', 'failed')
  ) o ON TRUE
  WHERE c.wholesaler_id = p_wholesaler_id AND c.active
  ORDER BY ph.name;
END;
$$;

-- Pharmacy view: this pharmacy's own credit line with one wholesaler (or every one it has).
CREATE OR REPLACE FUNCTION public.get_my_credit_terms(p_pharmacy_id UUID, p_wholesaler_id UUID DEFAULT NULL)
RETURNS TABLE (
  wholesaler_id UUID,
  credit_limit_ghs NUMERIC,
  payment_terms_days INTEGER,
  outstanding_ghs NUMERIC,
  available_ghs NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.wholesaler_id, c.credit_limit_ghs, c.payment_terms_days,
    COALESCE(o.outstanding, 0::NUMERIC(12,2)),
    c.credit_limit_ghs - COALESCE(o.outstanding, 0::NUMERIC(12,2))
  FROM public.wholesaler_credit_terms c
  LEFT JOIN LATERAL (
    SELECT SUM(ord.total_ghs) AS outstanding FROM public.orders ord
    WHERE ord.wholesaler_id = c.wholesaler_id AND ord.pharmacy_id = c.pharmacy_id
      AND ord.is_credit_order AND ord.status <> 'cancelled' AND ord.payment_status IN ('unpaid', 'failed')
  ) o ON TRUE
  WHERE c.pharmacy_id = p_pharmacy_id AND c.active
    AND (p_wholesaler_id IS NULL OR c.wholesaler_id = p_wholesaler_id);
END;
$$;

REVOKE ALL ON FUNCTION public.set_credit_terms(UUID, UUID, NUMERIC, INTEGER, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_credit_terms(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_wholesaler_credit_terms(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_credit_terms(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_credit_terms(UUID, UUID, NUMERIC, INTEGER, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_credit_terms(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_credit_terms(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_credit_terms(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Checkout: same function as before (order terms, minimum quantity, customer + product discounts,
-- stock reservation) plus an optional "pay on credit" per wholesaler.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_marketplace_orders(UUID, UUID, JSONB);

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _credit_wholesaler_ids UUID[] DEFAULT '{}'
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
  v_use_credit BOOLEAN;
  v_credit RECORD;
  v_credit_found BOOLEAN;
  v_credit_outstanding NUMERIC;
  v_due_date DATE;
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
    -- Credit: only when the pharmacy asked for it on this wholesaler AND the wholesaler has approved
    -- an active credit line. Locking the terms row serialises concurrent credit checkouts for this pair
    -- so two carts placed at once cannot both slip under the same limit.
    v_use_credit := v_wholesaler.wholesaler_id = ANY (COALESCE(_credit_wholesaler_ids, '{}'));
    v_due_date := NULL;
    IF v_use_credit THEN
      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active INTO v_credit
      FROM public.wholesaler_credit_terms c
      WHERE c.wholesaler_id = v_wholesaler.wholesaler_id AND c.pharmacy_id = _pharmacy_id
      FOR UPDATE;
      v_credit_found := FOUND AND v_credit.active;
      SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
      IF NOT v_credit_found THEN
        RAISE EXCEPTION '% has not approved credit for your pharmacy.', v_wholesaler_name;
      END IF;
      SELECT COALESCE(SUM(o.total_ghs), 0) INTO v_credit_outstanding
      FROM public.orders o
      WHERE o.wholesaler_id = v_wholesaler.wholesaler_id AND o.pharmacy_id = _pharmacy_id
        AND o.is_credit_order AND o.status <> 'cancelled' AND o.payment_status IN ('unpaid', 'failed');
      IF v_credit_outstanding + v_goods + v_fee > v_credit.credit_limit_ghs THEN
        RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
          v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_goods + v_fee, 'FM999,999,990.00');
      END IF;
      v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;
    END IF;

    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type WHEN v_specific_count > 0 THEN 'product' ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod', v_use_credit, v_due_date) RETURNING id INTO v_order_id;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    v_order_count := v_order_count + 1;
  END LOOP;
  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[]) TO service_role;
