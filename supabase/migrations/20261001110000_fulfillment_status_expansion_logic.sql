-- Fulfillment status expansion, part 2: trigger/RPC logic for the two new
-- statuses ('picking', 'ready_for_dispatch') added in the previous migration.
--
-- New chain: pending -> accepted -> picking -> packed -> ready_for_dispatch -> dispatched -> delivered
-- 'picking'/'ready_for_dispatch' are manual, wholesaler-button-driven transitions
-- (same UX pattern as every other status change today) -- no new automation.
-- Cancellation eligibility is intentionally left unchanged (pending/accepted only).

-- ---------------------------------------------------------------------------
-- Stamp the two new lifecycle timestamps, same pattern as the existing ones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_order_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.status IS DISTINCT FROM OLD.status THEN
    -- Stamp lifecycle timestamps
    IF NEW.status = 'accepted' AND NEW.accepted_at IS NULL THEN NEW.accepted_at := now(); END IF;
    IF NEW.status = 'picking' AND NEW.picking_started_at IS NULL THEN NEW.picking_started_at := now(); END IF;
    IF NEW.status = 'packed' AND NEW.packed_at IS NULL THEN NEW.packed_at := now(); END IF;
    IF NEW.status = 'ready_for_dispatch' AND NEW.ready_for_dispatch_at IS NULL THEN NEW.ready_for_dispatch_at := now(); END IF;
    IF NEW.status = 'dispatched' AND NEW.dispatched_at IS NULL THEN NEW.dispatched_at := now(); END IF;
    IF NEW.status = 'delivered' AND NEW.delivered_at IS NULL THEN NEW.delivered_at := now(); END IF;
    IF NEW.status = 'cancelled' AND NEW.cancelled_at IS NULL THEN NEW.cancelled_at := now(); END IF;

    INSERT INTO public.order_status_history(order_id, from_status, to_status, changed_by)
    VALUES (NEW.id, OLD.status, NEW.status, auth.uid());
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- Friendlier notification text for the two new statuses (previously fell
-- back to raw enum text via the ELSE branch -- not broken, just unpolished).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_order_status_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wholesaler TEXT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;
  BEGIN
    SELECT name INTO v_wholesaler FROM public.businesses WHERE id = NEW.wholesaler_id;
    PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'order_status', 'Order update',
      'Your order #' || NEW.order_number || ' from ' || COALESCE(v_wholesaler, 'your wholesaler') || ' is now ' ||
        CASE NEW.status::TEXT
          WHEN 'accepted' THEN 'accepted'
          WHEN 'picking' THEN 'being picked'
          WHEN 'packed' THEN 'packed and ready'
          WHEN 'ready_for_dispatch' THEN 'ready for dispatch'
          WHEN 'dispatched' THEN 'out for delivery'
          WHEN 'delivered' THEN 'delivered'
          WHEN 'cancelled' THEN 'cancelled'
          ELSE NEW.status::TEXT
        END || '.',
      '/pharmacy?tab=orders', jsonb_build_object('order_id', NEW.id, 'order_number', NEW.order_number, 'status', NEW.status));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_order_status_changed failed: %', SQLERRM;
  END;
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- wholesaler_report_overview: switch the 'pending_orders' KPI to the same
-- future-proof NOT IN (terminal states) pattern already used by the
-- pharmacy-side 'outstanding_orders' KPI, instead of enumerating non-terminal
-- statuses (which would otherwise need updating every time a status is added).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.wholesaler_report_overview(
  p_business_id UUID,
  p_range TEXT DEFAULT '30d',
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
  v_result JSONB;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid())
    OR public.is_business_staff(auth.uid(), p_business_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s reports.';
  END IF;

  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  SELECT jsonb_build_object(
    'from', v_from, 'to', v_to,
    'kpis', jsonb_build_object(
      'total_sales_ghs', COALESCE(SUM(o.total_ghs), 0),
      'total_orders', COUNT(*),
      'customers', COUNT(DISTINCT o.pharmacy_id),
      'units_sold', COALESCE((SELECT SUM(oi.quantity) FROM public.order_items oi JOIN public.orders o2 ON o2.id = oi.order_id WHERE o2.wholesaler_id = p_business_id AND o2.created_at >= v_from AND o2.created_at < v_to), 0),
      'discounts_given_ghs', COALESCE(SUM(o.discount_amount_ghs), 0),
      'avg_order_value_ghs', COALESCE(AVG(o.total_ghs), 0),
      'pending_orders', COUNT(*) FILTER (WHERE o.status::TEXT NOT IN ('delivered', 'cancelled'))
    ),
    'series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', d.bucket, 'orders', d.orders, 'sales_ghs', d.sales_ghs) ORDER BY d.bucket), '[]'::JSONB)
      FROM (
        SELECT date_trunc('day', o2.created_at) AS bucket, COUNT(*) AS orders, SUM(o2.total_ghs) AS sales_ghs
        FROM public.orders o2
        WHERE o2.wholesaler_id = p_business_id AND o2.created_at >= v_from AND o2.created_at < v_to
        GROUP BY 1
      ) d
    )
  )
  INTO v_result
  FROM public.orders o
  WHERE o.wholesaler_id = p_business_id AND o.created_at >= v_from AND o.created_at < v_to;

  RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- list_pharmacy_order_history: same NOT IN (terminal states) switch for the
-- 'active' status filter.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_pharmacy_order_history(
  p_page INTEGER DEFAULT 1,
  p_page_size INTEGER DEFAULT 20,
  p_search TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_payment_status TEXT DEFAULT NULL,
  p_sort TEXT DEFAULT 'newest',
  p_range TEXT DEFAULT NULL,
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_wholesaler_id UUID DEFAULT NULL,
  p_purchase_category TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  v_from TIMESTAMPTZ;
  v_to TIMESTAMPTZ;
BEGIN
  SELECT range_from, range_to INTO v_from, v_to FROM public.resolve_report_range(p_range, p_from, p_to);

  RETURN (
    WITH scoped AS (
      SELECT o.id, o.order_number, o.status, o.total_ghs, o.created_at,
        o.payment_method, o.payment_status, o.purchase_category, o.wholesaler_id, w.name AS wholesaler_name,
        o.procurement_id, pr.reference AS procurement_reference,
        (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS item_count,
        (SELECT coalesce(sum(oi.quantity), 0) FROM public.order_items oi WHERE oi.order_id = o.id) AS unit_count
      FROM public.orders o
      JOIN public.businesses w ON w.id = o.wholesaler_id
      LEFT JOIN public.procurements pr ON pr.id = o.procurement_id
      WHERE EXISTS (
        SELECT 1 FROM public.businesses pb
        WHERE pb.id = o.pharmacy_id AND pb.type = 'pharmacy'
          AND (pb.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), pb.id))
      )
      AND (
        NULLIF(btrim(p_status), '') IS NULL
        OR (p_status = 'active' AND o.status::TEXT NOT IN ('delivered', 'cancelled'))
        OR (p_status <> 'active' AND o.status::TEXT = p_status)
      )
      AND (NULLIF(btrim(p_payment_status), '') IS NULL OR o.payment_status::TEXT = p_payment_status)
      AND (
        NULLIF(btrim(p_purchase_category), '') IS NULL
        OR (p_purchase_category = 'unclassified' AND o.purchase_category IS NULL)
        OR o.purchase_category = p_purchase_category
      )
      AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
      AND o.created_at >= v_from AND o.created_at < v_to
      AND (
        NULLIF(btrim(p_search), '') IS NULL
        OR o.order_number ILIKE '%' || btrim(p_search) || '%'
        OR w.name ILIKE '%' || btrim(p_search) || '%'
        OR pr.reference ILIKE '%' || btrim(p_search) || '%'
        OR EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id AND oi.product_name ILIKE '%' || btrim(p_search) || '%')
      )
    ), counted AS (
      SELECT *, count(*) OVER () AS total_count FROM scoped
      ORDER BY
        CASE WHEN p_sort = 'highest' THEN total_ghs END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN total_ghs END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id
      OFFSET GREATEST(p_page - 1, 0) * LEAST(GREATEST(p_page_size, 1), 100)
      LIMIT LEAST(GREATEST(p_page_size, 1), 100)
    )
    SELECT jsonb_build_object(
      'total_count', COALESCE(max(total_count), 0),
      'page', GREATEST(p_page, 1),
      'page_size', LEAST(GREATEST(p_page_size, 1), 100),
      'orders', COALESCE(jsonb_agg(to_jsonb(counted) - 'total_count' ORDER BY
        CASE WHEN p_sort = 'highest' THEN total_ghs END DESC NULLS LAST,
        CASE WHEN p_sort = 'lowest' THEN total_ghs END ASC NULLS LAST,
        CASE WHEN p_sort = 'oldest' THEN created_at END ASC NULLS LAST,
        CASE WHEN p_sort NOT IN ('highest', 'lowest', 'oldest') THEN created_at END DESC NULLS LAST,
        id), '[]'::JSONB)
    ) FROM counted
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- confirm_order_picks: allow batch-pick confirmation during 'picking' too
-- (previously only 'accepted'/'packed'). Left permissive up to the point of
-- actual dispatch, matching the existing "re-confirm any time before it's
-- out the door" behaviour rather than narrowing it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_order_picks(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_item RECORD;
  v_batch RECORD;
  v_remaining INTEGER;
  v_take INTEGER;
  v_allocated INTEGER := 0;
  v_short INTEGER := 0;
  v_org TEXT;
BEGIN
  SELECT o.id, o.wholesaler_id, o.order_number, o.status::TEXT AS status INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND OR auth.uid() IS NULL OR NOT public.can_act_for_business(v_order.wholesaler_id, 'process') THEN
    RAISE EXCEPTION 'You do not have permission to confirm picks for this order.';
  END IF;
  IF v_order.status NOT IN ('accepted', 'picking', 'packed', 'ready_for_dispatch') THEN
    RAISE EXCEPTION 'Batches can only be confirmed before the order is dispatched.';
  END IF;

  PERFORM public._release_order_batches(p_order_id);

  FOR v_item IN SELECT oi.id, oi.product_id, oi.quantity FROM public.order_items oi WHERE oi.order_id = p_order_id ORDER BY oi.id LOOP
    v_remaining := v_item.quantity;
    FOR v_batch IN
      SELECT b.id, b.quantity_on_hand FROM public.product_batches b
      WHERE b.product_id = v_item.product_id AND b.quantity_on_hand > 0 AND b.expiry_date >= current_date
      ORDER BY b.expiry_date, b.id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(v_batch.quantity_on_hand, v_remaining);
      UPDATE public.product_batches SET quantity_on_hand = quantity_on_hand - v_take WHERE id = v_batch.id;
      INSERT INTO public.order_batch_allocations (order_id, order_item_id, batch_id, quantity) VALUES (p_order_id, v_item.id, v_batch.id, v_take);
      INSERT INTO public.batch_movements (batch_id, product_id, wholesaler_id, kind, quantity, order_id, created_by)
      VALUES (v_batch.id, v_item.product_id, v_order.wholesaler_id, 'allocated', v_take, p_order_id, auth.uid());
      v_remaining := v_remaining - v_take;
      v_allocated := v_allocated + v_take;
    END LOOP;
    v_short := v_short + GREATEST(v_remaining, 0);
  END LOOP;

  SELECT name INTO v_org FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.write_audit_log('Batches allocated', v_org, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('units_allocated', v_allocated, 'units_not_batched', v_short));
  RETURN jsonb_build_object('units_allocated', v_allocated, 'units_not_batched', v_short);
END;
$$;

-- ---------------------------------------------------------------------------
-- record_order_dispatch_details: allow entering delivery details starting
-- from 'picking' through 'dispatched' (previously 'accepted'/'packed'/'dispatched').
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_order_dispatch_details(
  p_order_id UUID,
  p_driver_name TEXT,
  p_driver_phone TEXT,
  p_reference TEXT,
  p_expected_at TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_name TEXT := NULLIF(btrim(COALESCE(p_driver_name, '')), '');
  v_phone TEXT := NULLIF(btrim(COALESCE(p_driver_phone, '')), '');
  v_ref TEXT := NULLIF(btrim(COALESCE(p_reference, '')), '');
  v_org TEXT;
BEGIN
  SELECT * INTO v_order FROM public._delivery_order_for_wholesaler(p_order_id);
  IF v_order.status NOT IN ('accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched') THEN
    RAISE EXCEPTION 'Delivery details can only be added before or during dispatch.';
  END IF;
  IF v_name IS NULL AND v_phone IS NULL AND v_ref IS NULL AND p_expected_at IS NULL THEN
    RAISE EXCEPTION 'Enter at least one delivery detail.';
  END IF;
  IF v_name IS NOT NULL AND char_length(v_name) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'The driver name must be 2 to 100 characters.'; END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^[0-9+()\- ]{5,30}$' THEN RAISE EXCEPTION 'Enter a valid phone number for the driver.'; END IF;
  IF v_ref IS NOT NULL AND char_length(v_ref) > 60 THEN RAISE EXCEPTION 'The delivery reference is too long (60 characters maximum).'; END IF;
  IF p_expected_at IS NOT NULL AND p_expected_at < v_order.created_at THEN
    RAISE EXCEPTION 'The expected delivery time cannot be before the order was placed.';
  END IF;

  INSERT INTO public.order_deliveries (order_id, driver_name, driver_phone, delivery_reference, expected_delivery_at, updated_by)
  VALUES (p_order_id, v_name, v_phone, v_ref, p_expected_at, auth.uid())
  ON CONFLICT (order_id) DO UPDATE
  SET driver_name = EXCLUDED.driver_name, driver_phone = EXCLUDED.driver_phone,
      delivery_reference = EXCLUDED.delivery_reference, expected_delivery_at = EXCLUDED.expected_delivery_at,
      updated_by = auth.uid();

  SELECT name INTO v_org FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.write_audit_log('Delivery details updated', v_org, 'order', p_order_id, v_order.order_number, '{}'::JSONB);
END;
$$;
