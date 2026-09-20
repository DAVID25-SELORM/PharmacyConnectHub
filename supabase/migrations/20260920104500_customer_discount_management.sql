-- Owner/manager-only management API for wholesaler customer discounts.
CREATE OR REPLACE FUNCTION public.list_wholesaler_customer_discounts(p_wholesaler_id UUID)
RETURNS JSONB LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(d) - 'internal_note' ORDER BY b.name), '[]'::JSONB)
  FROM public.customer_discounts d
  JOIN public.businesses b ON b.id = d.pharmacy_id
  WHERE d.wholesaler_id = p_wholesaler_id
    AND (btrim(COALESCE(public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT, '')) IN ('owner','manager')
      OR EXISTS (SELECT 1 FROM public.businesses wb WHERE wb.id = p_wholesaler_id AND wb.owner_id = auth.uid()));
$$;

CREATE OR REPLACE FUNCTION public.upsert_customer_discount(
  p_wholesaler_id UUID, p_pharmacy_id UUID, p_discount_type TEXT,
  p_discount_percent NUMERIC DEFAULT NULL, p_discount_amount NUMERIC DEFAULT NULL,
  p_minimum_order_value NUMERIC DEFAULT 0, p_starts_at TIMESTAMPTZ DEFAULT now(),
  p_ends_at TIMESTAMPTZ DEFAULT NULL, p_internal_note TEXT DEFAULT NULL
)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid())
    OR public.get_staff_role(auth.uid(), p_wholesaler_id) IN ('owner','manager')) THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage discounts.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type = 'pharmacy') THEN
    RAISE EXCEPTION 'Pharmacy workspace not found.';
  END IF;
  UPDATE public.customer_discounts SET active = false, updated_at = now(), updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id AND active;
  INSERT INTO public.customer_discounts(wholesaler_id, pharmacy_id, discount_type, discount_percent, discount_amount,
    minimum_order_value, starts_at, ends_at, internal_note, created_by, updated_by)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_discount_type, p_discount_percent, p_discount_amount,
    p_minimum_order_value, p_starts_at, p_ends_at, p_internal_note, auth.uid(), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_customer_discount(p_discount_id UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE public.customer_discounts d SET active = false, updated_at = now(), updated_by = auth.uid()
  WHERE d.id = p_discount_id
    AND (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = d.wholesaler_id AND b.owner_id = auth.uid())
      OR public.get_staff_role(auth.uid(), d.wholesaler_id) IN ('owner','manager'));
  RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.list_wholesaler_customer_discounts(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_customer_discount(UUID, UUID, TEXT, NUMERIC, NUMERIC, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_customer_discount(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_customer_discounts(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_customer_discount(UUID, UUID, TEXT, NUMERIC, NUMERIC, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_customer_discount(UUID) TO authenticated;
