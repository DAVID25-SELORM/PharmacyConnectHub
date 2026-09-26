-- Delivery details and simple proof of delivery (Phase 1).
--   * Wholesaler records who is delivering (driver name/phone), a delivery reference and the
--     expected delivery time while the order is accepted/packed/dispatched.
--   * Once dispatched (or delivered) the wholesaler records proof of delivery: who received the
--     goods and when, plus an optional note. Signature/photo/OTP are NOT part of this phase.
--   * Both sides can read it; only the wholesaler (owner/manager/cashier) can write it.
--
-- Stored in its own table so the orders table is not widened. RLS is on with an admin-only
-- SELECT policy; all reads/writes for users go through SECURITY DEFINER functions that check
-- the caller. This does not change the order status: status still moves through the existing
-- order actions, and delivered_at on orders is unchanged.

CREATE TABLE public.order_deliveries (
  order_id UUID PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  driver_name TEXT CHECK (driver_name IS NULL OR char_length(driver_name) BETWEEN 2 AND 100),
  driver_phone TEXT CHECK (driver_phone IS NULL OR char_length(driver_phone) BETWEEN 5 AND 30),
  delivery_reference TEXT CHECK (delivery_reference IS NULL OR char_length(delivery_reference) BETWEEN 1 AND 60),
  expected_delivery_at TIMESTAMPTZ,
  received_by_name TEXT CHECK (received_by_name IS NULL OR char_length(received_by_name) BETWEEN 2 AND 100),
  received_at TIMESTAMPTZ,
  delivery_note TEXT CHECK (delivery_note IS NULL OR char_length(delivery_note) <= 500),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((received_by_name IS NULL) = (received_at IS NULL))
);

CREATE TRIGGER trg_order_deliveries_updated BEFORE UPDATE ON public.order_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.order_deliveries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read deliveries" ON public.order_deliveries FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_deliveries FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_deliveries TO authenticated;

-- Read: either side of the order (any active staff).
CREATE OR REPLACE FUNCTION public.get_order_delivery(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_result JSONB;
BEGIN
  SELECT o.id, o.pharmacy_id, o.wholesaler_id INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF auth.uid() IS NULL OR NOT FOUND
     OR NOT (public.can_act_for_business(v_order.pharmacy_id, 'read') OR public.can_act_for_business(v_order.wholesaler_id, 'read')) THEN
    RAISE EXCEPTION 'You do not have access to this order.';
  END IF;

  SELECT jsonb_build_object(
    'driver_name', d.driver_name, 'driver_phone', d.driver_phone, 'delivery_reference', d.delivery_reference,
    'expected_delivery_at', d.expected_delivery_at, 'received_by_name', d.received_by_name,
    'received_at', d.received_at, 'delivery_note', d.delivery_note, 'updated_at', d.updated_at)
  INTO v_result FROM public.order_deliveries d WHERE d.order_id = p_order_id;
  RETURN COALESCE(v_result, '{}'::JSONB);
END;
$$;

-- Write helper: the caller must be able to process orders for the order's wholesaler.
CREATE OR REPLACE FUNCTION public._delivery_order_for_wholesaler(p_order_id UUID)
RETURNS TABLE (id UUID, wholesaler_id UUID, status TEXT, created_at TIMESTAMPTZ, order_number TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT o.id, o.wholesaler_id, o.status::TEXT, o.created_at, o.order_number
  FROM public.orders o WHERE o.id = p_order_id AND public.can_act_for_business(o.wholesaler_id, 'process');
  IF NOT FOUND THEN RAISE EXCEPTION 'You do not have permission to update this order.'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._delivery_order_for_wholesaler(UUID) FROM PUBLIC, anon, authenticated;

-- Wholesaler: who is delivering, reference, expected time.
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
  IF v_order.status NOT IN ('accepted', 'packed', 'dispatched') THEN
    RAISE EXCEPTION 'Delivery details can only be added to accepted, packed or dispatched orders.';
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

-- Wholesaler: proof of delivery (who received it, and when).
CREATE OR REPLACE FUNCTION public.record_order_proof_of_delivery(
  p_order_id UUID,
  p_received_by TEXT,
  p_received_at TIMESTAMPTZ,
  p_note TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_by TEXT := NULLIF(btrim(COALESCE(p_received_by, '')), '');
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_org TEXT;
BEGIN
  SELECT * INTO v_order FROM public._delivery_order_for_wholesaler(p_order_id);
  IF v_order.status NOT IN ('dispatched', 'delivered') THEN
    RAISE EXCEPTION 'Proof of delivery can only be recorded once the order is dispatched.';
  END IF;
  IF v_by IS NULL OR char_length(v_by) NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'Enter the name of the person who received the goods (2 to 100 characters).'; END IF;
  IF p_received_at IS NULL THEN RAISE EXCEPTION 'Enter when the goods were received.'; END IF;
  IF p_received_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The received time cannot be in the future.'; END IF;
  IF p_received_at < v_order.created_at THEN RAISE EXCEPTION 'The received time cannot be before the order was placed.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The note is too long (500 characters maximum).'; END IF;

  INSERT INTO public.order_deliveries (order_id, received_by_name, received_at, delivery_note, updated_by)
  VALUES (p_order_id, v_by, p_received_at, v_note, auth.uid())
  ON CONFLICT (order_id) DO UPDATE
  SET received_by_name = EXCLUDED.received_by_name, received_at = EXCLUDED.received_at,
      delivery_note = EXCLUDED.delivery_note, updated_by = auth.uid();

  SELECT name INTO v_org FROM public.businesses WHERE id = v_order.wholesaler_id;
  PERFORM public.write_audit_log('Proof of delivery recorded', v_org, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('received_by', v_by));
END;
$$;

REVOKE ALL ON FUNCTION public.get_order_delivery(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_order_dispatch_details(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_order_proof_of_delivery(UUID, TEXT, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_order_delivery(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_order_dispatch_details(UUID, TEXT, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_order_proof_of_delivery(UUID, TEXT, TIMESTAMPTZ, TEXT) TO authenticated;
