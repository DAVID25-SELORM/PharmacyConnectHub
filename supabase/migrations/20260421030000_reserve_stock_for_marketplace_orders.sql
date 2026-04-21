-- Reserve wholesaler stock atomically when marketplace orders are created.
-- This prevents partial orders and reduces overselling between pharmacy and wholesaler flows.

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
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'caller_id and pharmacy_id are required.';
  END IF;

  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required.';
  END IF;

  SELECT id, owner_id, type, verification_status
  INTO v_business
  FROM public.businesses
  WHERE id = _pharmacy_id;

  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;

  IF v_business.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.';
  END IF;

  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role
    INTO v_role
    FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id
      AND bs.user_id = _caller_id
      AND bs.status = 'active'
    LIMIT 1;

    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN
      RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.';
    END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (
    product_id UUID PRIMARY KEY,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  INSERT INTO tmp_requested_items (product_id, quantity)
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER
  FROM (
    SELECT
      (item ->> 'productId')::UUID AS product_id,
      (item ->> 'quantity')::INTEGER AS quantity
    FROM jsonb_array_elements(_items) item
  ) raw
  WHERE raw.product_id IS NOT NULL
    AND raw.quantity > 0
  GROUP BY raw.product_id;

  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN
    RAISE EXCEPTION 'Each item needs a valid productId and quantity.';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM public.products p
    JOIN tmp_requested_items r ON r.product_id = p.id
  ) <> v_requested_count THEN
    RAISE EXCEPTION 'One or more products could not be found.';
  END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY,
    wholesaler_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    unit_price_ghs NUMERIC NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0)
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT
      p.id,
      p.name,
      p.price_ghs,
      p.stock,
      p.active,
      p.wholesaler_id,
      b.name AS wholesaler_name,
      b.verification_status AS wholesaler_status,
      r.quantity
    FROM tmp_requested_items r
    JOIN public.products p ON p.id = r.product_id
    JOIN public.businesses b ON b.id = p.wholesaler_id
    FOR UPDATE OF p
  LOOP
    IF NOT v_product.active THEN
      RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name;
    END IF;

    IF v_product.wholesaler_status <> 'approved' THEN
      RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name;
    END IF;

    IF v_product.stock <= 0 THEN
      RAISE EXCEPTION '% is currently out of stock.', v_product.name;
    END IF;

    IF v_product.stock < v_product.quantity THEN
      RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name;
    END IF;

    UPDATE public.products
    SET stock = stock - v_product.quantity
    WHERE id = v_product.id;

    INSERT INTO tmp_locked_products (
      product_id,
      wholesaler_id,
      product_name,
      unit_price_ghs,
      quantity
    )
    VALUES (
      v_product.id,
      v_product.wholesaler_id,
      v_product.name,
      v_product.price_ghs,
      v_product.quantity
    );
  END LOOP;

  FOR v_wholesaler IN
    SELECT
      wholesaler_id,
      SUM(unit_price_ghs * quantity) AS total_ghs
    FROM tmp_locked_products
    GROUP BY wholesaler_id
  LOOP
    INSERT INTO public.orders (
      pharmacy_id,
      wholesaler_id,
      total_ghs,
      payment_method
    )
    VALUES (
      _pharmacy_id,
      v_wholesaler.wholesaler_id,
      v_wholesaler.total_ghs,
      'cod'
    )
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_items (
      order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    )
    SELECT
      v_order_id,
      product_id,
      product_name,
      quantity,
      unit_price_ghs
    FROM tmp_locked_products
    WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    v_order_count := v_order_count + 1;
  END LOOP;

  RETURN v_order_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_stock_for_cancelled_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.products p
  SET stock = p.stock + oi.quantity
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id
    AND oi.product_id = p.id;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restore_stock_on_order_cancel ON public.orders;
CREATE TRIGGER trg_restore_stock_on_order_cancel
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.restore_stock_for_cancelled_order();

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.restore_stock_for_cancelled_order() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB) TO service_role;
