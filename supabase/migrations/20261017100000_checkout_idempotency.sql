-- Apply before deploying the API that calls this wrapper. Existing checkout logic is preserved.
CREATE TABLE public.marketplace_checkout_requests (
  pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
  request_id UUID NOT NULL,
  caller_id UUID NOT NULL REFERENCES auth.users(id),
  payload JSONB NOT NULL,
  order_count INTEGER,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (pharmacy_id, request_id)
);
ALTER TABLE public.marketplace_checkout_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marketplace_checkout_requests FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_marketplace_orders_once(
  _caller_id UUID, _pharmacy_id UUID, _request_id UUID, _items JSONB,
  _credit_wholesaler_ids UUID[] DEFAULT '{}', _settlement_methods JSONB DEFAULT '{}'
) RETURNS INTEGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_payload JSONB := jsonb_build_object('items', _items, 'credit', _credit_wholesaler_ids, 'settlement', _settlement_methods);
  v_request public.marketplace_checkout_requests%ROWTYPE;
  v_count INTEGER;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL OR _request_id IS NULL THEN
    RAISE EXCEPTION 'Caller, pharmacy and checkout request ID are required.';
  END IF;
  -- Recheck access on replay, including staff suspension and business approval.
  IF NOT EXISTS (
    SELECT 1 FROM public.businesses b WHERE b.id = _pharmacy_id
      AND b.type = 'pharmacy' AND b.verification_status = 'approved'
      AND (b.owner_id = _caller_id OR EXISTS (
        SELECT 1 FROM public.business_staff s WHERE s.business_id = b.id
          AND s.user_id = _caller_id AND s.status = 'active'
          AND s.role::TEXT IN ('owner', 'manager', 'cashier')
      ))
  ) THEN RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.'; END IF;

  INSERT INTO public.marketplace_checkout_requests(pharmacy_id, request_id, caller_id, payload)
  VALUES (_pharmacy_id, _request_id, _caller_id, v_payload)
  ON CONFLICT (pharmacy_id, request_id) DO NOTHING;
  -- A concurrent insert of the same key waits for the first transaction to finish.
  SELECT * INTO STRICT v_request FROM public.marketplace_checkout_requests
  WHERE pharmacy_id = _pharmacy_id AND request_id = _request_id FOR UPDATE;
  IF v_request.caller_id <> _caller_id OR v_request.payload IS DISTINCT FROM v_payload THEN
    RAISE EXCEPTION 'Checkout request ID already used for different data.';
  END IF;
  IF v_request.order_count IS NOT NULL THEN RETURN v_request.order_count; END IF;
  IF to_regclass('public.server_audit_context') IS NOT NULL THEN
    INSERT INTO public.server_audit_context(transaction_id, actor_id) VALUES(txid_current(), _caller_id);
  END IF;
  v_count := public.create_marketplace_orders(_caller_id, _pharmacy_id, _items,
    _credit_wholesaler_ids, TRUE, _settlement_methods);
  IF to_regclass('public.server_audit_context') IS NOT NULL THEN
    DELETE FROM public.server_audit_context WHERE transaction_id = txid_current();
  END IF;
  UPDATE public.marketplace_checkout_requests SET order_count = v_count
  WHERE pharmacy_id = _pharmacy_id AND request_id = _request_id;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.create_marketplace_orders_once(UUID, UUID, UUID, JSONB, UUID[], JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders_once(UUID, UUID, UUID, JSONB, UUID[], JSONB) TO service_role;
