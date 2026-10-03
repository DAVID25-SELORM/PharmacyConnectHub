-- Phase 1: purchase classification.
--
-- Classification (WHY an item is bought: NHIS / Cash / Other) stays line-level on
-- order_items.purchase_category; the order and procurement values remain DERIVED from the lines
-- ('mixed' when they differ) and are never edited by hand. A mixed order stays ONE supplier order;
-- it is not split by classification. Payment method / credit are a separate concept (Phase 2+).
--
-- The stored value for Cash is 'cash_private' (unchanged -- six report functions and all history
-- depend on it); the UI labels it "Cash". Historical rows with NULL stay unclassified: they are
-- never assumed to be cash.
--
-- This migration:
--   1. create_marketplace_orders gains `_require_classification` (default FALSE, so every existing
--      caller and test keeps working). The API passes TRUE, so a real checkout cannot be submitted
--      with unclassified lines: "N item(s) still need a purchase classification."
--      Adding a parameter changes the signature, so the old 4-argument function is dropped first
--      (CREATE OR REPLACE would otherwise leave an ambiguous overload).
--   2. Every order created records an audit entry with its classification summary.
--   3. change_order_item_classification(): the only way to change a classification after the
--      order is placed. Owner / manager / accountant of the pharmacy only, reason required,
--      before/after audited, order and procurement categories re-derived in the same transaction.

DROP FUNCTION IF EXISTS public.create_marketplace_orders(UUID, UUID, JSONB, UUID[]);

CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _credit_wholesaler_ids UUID[] DEFAULT '{}',
  _require_classification BOOLEAN DEFAULT FALSE
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
  v_procurement_id UUID;
  v_order_category TEXT;
  v_procurement_category TEXT;
  v_order_number TEXT;
  v_unclassified INTEGER;
  v_actor_email TEXT;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN RAISE EXCEPTION 'caller_id and pharmacy_id are required.'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'At least one item is required.'; END IF;

  SELECT id, owner_id, type, verification_status, name INTO v_business FROM public.businesses WHERE id = _pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_business.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.'; END IF;
  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role INTO v_role FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id AND bs.user_id = _caller_id AND bs.status = 'active' LIMIT 1;
    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.'; END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (product_id UUID PRIMARY KEY, quantity INTEGER NOT NULL CHECK (quantity > 0), purchase_category TEXT) ON COMMIT DROP;
  INSERT INTO tmp_requested_items
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER, (array_agg(raw.category))[1]
  FROM (SELECT (item ->> 'productId')::UUID product_id, (item ->> 'quantity')::INTEGER quantity, NULLIF(btrim(item ->> 'category'), '') category FROM jsonb_array_elements(_items) item) raw
  WHERE raw.product_id IS NOT NULL AND raw.quantity > 0 GROUP BY raw.product_id;
  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN RAISE EXCEPTION 'Each item needs a valid productId and quantity.'; END IF;
  IF EXISTS (SELECT 1 FROM tmp_requested_items WHERE purchase_category IS NOT NULL AND purchase_category NOT IN ('nhis', 'cash_private', 'other')) THEN
    RAISE EXCEPTION 'Invalid purchase category.';
  END IF;
  -- A real checkout must classify every line (the API passes TRUE). Raised before any stock is
  -- reserved, so nothing is held when it fails.
  IF _require_classification THEN
    SELECT COUNT(*) INTO v_unclassified FROM tmp_requested_items WHERE purchase_category IS NULL;
    IF v_unclassified > 0 THEN
      RAISE EXCEPTION '% item(s) still need a purchase classification.', v_unclassified;
    END IF;
  END IF;
  IF (SELECT COUNT(*) FROM public.products p JOIN tmp_requested_items r ON r.product_id = p.id) <> v_requested_count THEN RAISE EXCEPTION 'One or more products could not be found.'; END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY, wholesaler_id UUID NOT NULL, product_name TEXT NOT NULL,
    base_unit_price_ghs NUMERIC(10,2) NOT NULL, unit_price_ghs NUMERIC(10,2) NOT NULL,
    discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0, quantity INTEGER NOT NULL CHECK (quantity > 0),
    specific_discount BOOLEAN NOT NULL DEFAULT FALSE, discount_source TEXT, purchase_category TEXT
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT p.id, p.name, p.price_ghs, p.stock, p.active, p.wholesaler_id, b.name wholesaler_name,
      b.verification_status wholesaler_status, r.quantity, r.purchase_category,
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
    INSERT INTO tmp_locked_products(product_id, wholesaler_id, product_name, base_unit_price_ghs, unit_price_ghs, quantity, purchase_category)
    VALUES (v_product.id, v_product.wholesaler_id, v_product.name, v_product.price_ghs, v_product.price_ghs, v_product.quantity, v_product.purchase_category);
  END LOOP;

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

  INSERT INTO public.procurements(pharmacy_id) VALUES (_pharmacy_id) RETURNING id INTO v_procurement_id;

  FOR v_wholesaler IN SELECT wholesaler_id FROM tmp_locked_products GROUP BY wholesaler_id LOOP
    SELECT SUM(base_unit_price_ghs * quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    SELECT d.* INTO v_discount FROM public.customer_discounts d
    WHERE d.wholesaler_id = v_wholesaler.wholesaler_id AND d.pharmacy_id = _pharmacy_id AND d.active
      AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now()) AND v_subtotal >= d.minimum_order_value
    ORDER BY d.starts_at DESC, d.created_at DESC LIMIT 1;
    v_has_discount := FOUND;

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

    -- Order-level purchase category, derived from this wholesaler's own slice of items: all-NULL
    -- stays NULL (unclassified, e.g. every pre-existing caller of this function), all-the-same
    -- non-null value wins outright, anything else (including a mix of classified/unclassified) is 'mixed'.
    SELECT CASE
      WHEN bool_and(purchase_category IS NULL) THEN NULL
      WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
      ELSE 'mixed'
    END INTO v_order_category FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date, procurement_id, purchase_category)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type WHEN v_specific_count > 0 THEN 'product' ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod', v_use_credit, v_due_date, v_procurement_id, v_order_category)
      RETURNING id, order_number INTO v_order_id, v_order_number;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    -- Audit the classification this order was submitted with (value and line count per class).
    SELECT email INTO v_actor_email FROM auth.users WHERE id = _caller_id;
    PERFORM public.write_audit_log(
      'Order classification recorded', v_business.name, 'order', v_order_id, v_order_number,
      jsonb_build_object(
        'purchase_category', v_order_category,
        'classification_required', _require_classification,
        'lines', (SELECT COUNT(*) FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id),
        'by_classification', COALESCE((
          SELECT jsonb_object_agg(COALESCE(t.purchase_category, 'unclassified'),
            jsonb_build_object('lines', t.line_count, 'value_ghs', t.line_value))
          FROM (
            SELECT purchase_category, COUNT(*) AS line_count, round(SUM(unit_price_ghs * quantity), 2) AS line_value
            FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id GROUP BY purchase_category
          ) t
        ), '{}'::JSONB)),
      _caller_id, v_actor_email, NULL, _pharmacy_id);

    IF v_use_credit THEN
      INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
      VALUES (v_wholesaler.wholesaler_id, _pharmacy_id, v_order_id, 'invoice', 'debit', v_goods + v_fee, _caller_id);
    END IF;

    v_order_count := v_order_count + 1;
  END LOOP;

  SELECT CASE
    WHEN bool_and(purchase_category IS NULL) THEN NULL
    WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
    ELSE 'mixed'
  END INTO v_procurement_category FROM tmp_locked_products;
  UPDATE public.procurements SET purchase_category = v_procurement_category WHERE id = v_procurement_id;

  RETURN v_order_count;
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN) TO service_role;

-- ---------------------------------------------------------------------------
-- Controlled change of a placed order line's classification.
--
-- A finalized classification drives NHIS vs Cash reporting, so it is not editable by ordinary
-- staff. Allowed: the pharmacy owner and active owner / manager / accountant staff. Required: a
-- reason (5-500 chars). Recorded: who, their role, line, before/after, reason and the order's
-- derived category before/after. Orders and procurements are re-derived in the same transaction.
-- Cancelled orders cannot be reclassified. Staff of other businesses (and non-members) just see
-- "not found", so existence is not disclosed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.change_order_item_classification(
  p_order_item_id UUID,
  p_new_classification TEXT,
  p_reason TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_item RECORD;
  v_order RECORD;
  v_owner UUID;
  v_pharmacy_name TEXT;
  v_role TEXT;
  v_is_member BOOLEAN;
  v_new_order_category TEXT;
  v_new_procurement_category TEXT;
  v_actor_email TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to change a purchase classification.'; END IF;
  IF p_new_classification IS NULL OR p_new_classification NOT IN ('nhis', 'cash_private', 'other') THEN
    RAISE EXCEPTION 'Invalid purchase classification.';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason of 5 to 500 characters is required to change a purchase classification.';
  END IF;

  SELECT oi.id, oi.order_id, oi.product_name, oi.quantity, oi.unit_price_ghs, oi.purchase_category
    INTO v_item FROM public.order_items oi WHERE oi.id = p_order_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order item not found.'; END IF;

  SELECT o.id, o.order_number, o.pharmacy_id, o.status, o.procurement_id, o.purchase_category
    INTO v_order FROM public.orders o WHERE o.id = v_item.order_id FOR UPDATE;

  SELECT b.owner_id, b.name INTO v_owner, v_pharmacy_name FROM public.businesses b WHERE b.id = v_order.pharmacy_id;
  v_is_member := v_owner = auth.uid() OR public.is_business_staff(auth.uid(), v_order.pharmacy_id);
  IF NOT v_is_member THEN RAISE EXCEPTION 'Order item not found.'; END IF;
  v_role := CASE WHEN v_owner = auth.uid() THEN 'owner' ELSE public.get_staff_role(auth.uid(), v_order.pharmacy_id)::TEXT END;
  IF v_role NOT IN ('owner', 'manager', 'accountant') THEN
    RAISE EXCEPTION 'Only the pharmacy owner, managers and accountants can change a purchase classification.';
  END IF;

  IF v_order.status = 'cancelled' THEN RAISE EXCEPTION 'A cancelled order cannot be reclassified.'; END IF;
  IF v_item.purchase_category IS NOT DISTINCT FROM p_new_classification THEN
    RAISE EXCEPTION 'This item is already classified that way.';
  END IF;

  UPDATE public.order_items SET purchase_category = p_new_classification WHERE id = v_item.id;

  SELECT CASE
    WHEN bool_and(purchase_category IS NULL) THEN NULL
    WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
    ELSE 'mixed'
  END INTO v_new_order_category FROM public.order_items WHERE order_id = v_order.id;
  UPDATE public.orders SET purchase_category = v_new_order_category WHERE id = v_order.id;

  IF v_order.procurement_id IS NOT NULL THEN
    SELECT CASE
      WHEN bool_and(oi.purchase_category IS NULL) THEN NULL
      WHEN COUNT(DISTINCT oi.purchase_category) = 1 AND bool_and(oi.purchase_category IS NOT NULL) THEN MIN(oi.purchase_category)
      ELSE 'mixed'
    END INTO v_new_procurement_category
    FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id WHERE o.procurement_id = v_order.procurement_id;
    UPDATE public.procurements SET purchase_category = v_new_procurement_category WHERE id = v_order.procurement_id;
  END IF;

  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    'Order classification changed', v_pharmacy_name, 'order', v_order.id, v_order.order_number,
    jsonb_build_object(
      'order_item_id', v_item.id,
      'product', v_item.product_name,
      'quantity', v_item.quantity,
      'line_value_ghs', round(v_item.unit_price_ghs * v_item.quantity, 2),
      'from', v_item.purchase_category,
      'to', p_new_classification,
      'order_category_from', v_order.purchase_category,
      'order_category_to', v_new_order_category,
      'reason', v_reason,
      'actor_role', v_role),
    auth.uid(), v_actor_email, NULL, v_order.pharmacy_id);
END;
$$;
REVOKE ALL ON FUNCTION public.change_order_item_classification(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_order_item_classification(UUID, TEXT, TEXT) TO authenticated;
