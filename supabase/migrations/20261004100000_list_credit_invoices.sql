-- Credit ledger, part 3: the one read RPC the payment-recording UI needs that didn't exist yet --
-- a browsable list of an wholesaler's (or pharmacy's) credit invoices with their computed status.
-- get_credit_invoice (phase 2) already gives ONE invoice's full detail; this gives the list you
-- pick one FROM. Same dual-sided access pattern as get_credit_invoice: either side may call it,
-- scoped to whichever business id(s) they can actually act for.

CREATE OR REPLACE FUNCTION public.list_credit_invoices(
  p_wholesaler_id UUID DEFAULT NULL,
  p_pharmacy_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL -- NULL = all; one of the 7 computed statuses; or 'outstanding' = not paid/written_off
)
RETURNS TABLE (
  order_id UUID,
  order_number TEXT,
  wholesaler_id UUID,
  wholesaler_name TEXT,
  pharmacy_id UUID,
  pharmacy_name TEXT,
  created_at TIMESTAMPTZ,
  due_date DATE,
  invoice_ghs NUMERIC,
  paid_ghs NUMERIC,
  outstanding_ghs NUMERIC,
  status TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_wholesaler_id IS NULL AND p_pharmacy_id IS NULL THEN
    RAISE EXCEPTION 'Specify a wholesaler or a pharmacy to list credit invoices for.';
  END IF;
  IF auth.uid() IS NULL OR NOT (
    (p_wholesaler_id IS NOT NULL AND public.can_act_for_business(p_wholesaler_id, 'read'))
    OR (p_pharmacy_id IS NOT NULL AND public.can_act_for_business(p_pharmacy_id, 'read'))
  ) THEN
    RAISE EXCEPTION 'You do not have access to these credit invoices.';
  END IF;
  IF p_status IS NOT NULL AND p_status NOT IN
    ('not_due', 'partially_paid', 'paid', 'due_today', 'overdue', 'written_off', 'disputed', 'outstanding')
  THEN
    RAISE EXCEPTION 'Invalid status filter.';
  END IF;

  RETURN QUERY
  SELECT o.id, o.order_number, o.wholesaler_id, w.name, o.pharmacy_id, p.name,
    o.created_at, o.credit_due_date, s.invoice_ghs, s.paid_ghs, s.outstanding_ghs, s.status
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  JOIN public.businesses p ON p.id = o.pharmacy_id
  CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
  WHERE o.is_credit_order
    AND (p_wholesaler_id IS NULL OR o.wholesaler_id = p_wholesaler_id)
    AND (p_pharmacy_id IS NULL OR o.pharmacy_id = p_pharmacy_id)
    AND (
      p_status IS NULL
      OR (p_status = 'outstanding' AND s.status NOT IN ('paid', 'written_off'))
      OR s.status = p_status
    )
  ORDER BY o.credit_due_date NULLS LAST, o.created_at DESC
  LIMIT 500;
END;
$$;
REVOKE ALL ON FUNCTION public.list_credit_invoices(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_credit_invoices(UUID, UUID, TEXT) TO authenticated;
