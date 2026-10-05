-- Accounting registers: one aging rule, one access rule, server-side filtered registers.
--
-- Aging (exact rules). "Days past due" = today - due date, applied to the OUTSTANDING balance of an
-- invoice (never its original amount), and only to invoices that are still owed (outstanding > 0,
-- not cancelled, not written off):
--     current   due date is today or later (or there is none)      past due = 0 or negative
--     d1_30     1 to 30 days past due
--     d31_60    31 to 60 days past due
--     d61_90    61 to 90 days past due
--     d90_plus  91 or more days past due
-- So an invoice due 30 days ago is d1_30; 31 days ago is d31_60; 90 days ago is d61_90; 91 is d90_plus.
-- A GHS 10,000 invoice with GHS 8,000 paid that is 45 days past due contributes GHS 2,000 to d31_60.
-- Users never choose a bucket for an invoice; it is always derived from the due date and today.
--
-- Access: these registers are for finance roles only. Wholesaler: owner, manager, finance, accountant.
-- Pharmacy: owner, manager, accountant. The business must be approved; staff must be active. The
-- older invoice lists (list_credit_invoices etc.) are open to any staff and are not changed here.
-- A counterparty filter can only narrow the caller's own rows, never reach another business's.

CREATE FUNCTION public.credit_aging_bucket(p_due_date DATE, p_today DATE DEFAULT current_date)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_due_date IS NULL OR p_due_date >= p_today THEN 'current'
    WHEN p_today - p_due_date <= 30 THEN 'd1_30'
    WHEN p_today - p_due_date <= 60 THEN 'd31_60'
    WHEN p_today - p_due_date <= 90 THEN 'd61_90'
    ELSE 'd90_plus'
  END
$$;
GRANT EXECUTE ON FUNCTION public.credit_aging_bucket(DATE, DATE) TO authenticated;

CREATE FUNCTION public.can_view_accounting(p_business_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.businesses b
    WHERE b.id = p_business_id AND b.verification_status = 'approved'
      AND (
        b.owner_id = auth.uid()
        OR EXISTS (
          SELECT 1 FROM public.business_staff s
          WHERE s.business_id = b.id AND s.user_id = auth.uid() AND s.status = 'active'
            AND s.role::TEXT = ANY (CASE b.type::TEXT
              WHEN 'wholesaler' THEN ARRAY['owner', 'manager', 'finance', 'accountant']
              ELSE ARRAY['owner', 'manager', 'accountant'] END)
        )
      )
  )
$$;
REVOKE ALL ON FUNCTION public.can_view_accounting(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_accounting(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Invoice register (receivables for a wholesaler, payables for a pharmacy).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.credit_invoice_register(
  p_business_id UUID,
  p_counterparty_id UUID DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_bucket TEXT DEFAULT NULL,
  p_invoice_from DATE DEFAULT NULL,
  p_invoice_to DATE DEFAULT NULL,
  p_due_from DATE DEFAULT NULL,
  p_due_to DATE DEFAULT NULL,
  p_min_outstanding NUMERIC DEFAULT NULL,
  p_max_outstanding NUMERIC DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 200,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
  order_id UUID, order_number TEXT, counterparty_id UUID, counterparty_name TEXT,
  invoice_date DATE, due_date DATE, invoice_ghs NUMERIC, paid_ghs NUMERIC, outstanding_ghs NUMERIC,
  status TEXT, days_overdue INTEGER, aging_bucket TEXT, total_count BIGINT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type TEXT;
  v_search TEXT := NULLIF(lower(btrim(COALESCE(p_search, ''))), '');
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;
  SELECT b.type::TEXT INTO v_type FROM public.businesses b WHERE b.id = p_business_id;
  IF p_status IS NOT NULL AND p_status NOT IN
    ('not_due', 'partially_paid', 'paid', 'due_today', 'overdue', 'written_off', 'disputed', 'cancelled', 'outstanding') THEN
    RAISE EXCEPTION 'Invalid status filter.';
  END IF;
  IF p_bucket IS NOT NULL AND p_bucket NOT IN ('current', 'd1_30', 'd31_60', 'd61_90', 'd90_plus') THEN
    RAISE EXCEPTION 'Invalid aging bucket.';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 2000 THEN RAISE EXCEPTION 'The page size must be between 1 and 2000.'; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset.'; END IF;

  RETURN QUERY
  WITH base AS (
    SELECT o.id AS oid, o.order_number AS onum, cp.id AS cp_id, cp.name AS cp_name,
      o.created_at::DATE AS inv_date, o.credit_due_date AS due,
      s.invoice_ghs AS inv_amt, s.paid_ghs AS paid_amt, s.outstanding_ghs AS out_amt,
      CASE WHEN o.status = 'cancelled' THEN 'cancelled' ELSE s.status END AS st
    FROM public.orders o
    JOIN public.businesses cp ON cp.id = CASE WHEN v_type = 'wholesaler' THEN o.pharmacy_id ELSE o.wholesaler_id END
    CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
    WHERE o.is_credit_order
      AND ((v_type = 'wholesaler' AND o.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND o.pharmacy_id = p_business_id))
      AND (p_counterparty_id IS NULL OR cp.id = p_counterparty_id)
  ), shaped AS (
    SELECT b.*,
      (b.out_amt > 0 AND b.st NOT IN ('paid', 'written_off', 'cancelled')) AS owed
    FROM base b
  ), filtered AS (
    SELECT sh.*,
      CASE WHEN sh.owed THEN GREATEST(current_date - sh.due, 0) ELSE NULL END AS days_late,
      CASE WHEN sh.owed THEN public.credit_aging_bucket(sh.due, current_date) ELSE NULL END AS bucket
    FROM shaped sh
    WHERE (p_status IS NULL
        OR (p_status = 'outstanding' AND sh.owed)
        OR sh.st = p_status)
      AND (p_invoice_from IS NULL OR sh.inv_date >= p_invoice_from)
      AND (p_invoice_to IS NULL OR sh.inv_date <= p_invoice_to)
      AND (p_due_from IS NULL OR sh.due >= p_due_from)
      AND (p_due_to IS NULL OR sh.due <= p_due_to)
      AND (p_min_outstanding IS NULL OR sh.out_amt >= p_min_outstanding)
      AND (p_max_outstanding IS NULL OR sh.out_amt <= p_max_outstanding)
      AND (v_search IS NULL OR position(v_search IN lower(sh.onum)) > 0 OR position(v_search IN lower(sh.cp_name)) > 0)
  )
  SELECT f.oid, f.onum, f.cp_id, f.cp_name, f.inv_date, f.due, f.inv_amt, f.paid_amt, f.out_amt, f.st,
    f.days_late::INTEGER, f.bucket, count(*) OVER ()
  FROM filtered f
  WHERE p_bucket IS NULL OR f.bucket = p_bucket
  ORDER BY f.due ASC NULLS LAST, f.inv_date DESC, f.onum
  LIMIT p_limit OFFSET p_offset;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_invoice_register(UUID, UUID, TEXT, TEXT, DATE, DATE, DATE, DATE, NUMERIC, NUMERIC, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.credit_invoice_register(UUID, UUID, TEXT, TEXT, DATE, DATE, DATE, DATE, NUMERIC, NUMERIC, TEXT, INTEGER, INTEGER) TO authenticated;

-- ---------------------------------------------------------------------------
-- Aging summary: all five buckets, always (zero where nothing is owed).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.credit_aging_summary(p_business_id UUID, p_counterparty_id UUID DEFAULT NULL)
RETURNS TABLE(bucket TEXT, invoices BIGINT, outstanding_ghs NUMERIC)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type TEXT;
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;
  SELECT b.type::TEXT INTO v_type FROM public.businesses b WHERE b.id = p_business_id;
  RETURN QUERY
  SELECT k.bucket, COALESCE(a.n, 0), COALESCE(a.total, 0::NUMERIC)::NUMERIC(12,2)
  FROM (VALUES ('current', 1), ('d1_30', 2), ('d31_60', 3), ('d61_90', 4), ('d90_plus', 5)) k(bucket, ord)
  LEFT JOIN (
    SELECT public.credit_aging_bucket(o.credit_due_date, current_date) AS bucket, count(*) AS n, sum(s.outstanding_ghs) AS total
    FROM public.orders o
    CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
    WHERE o.is_credit_order AND o.status <> 'cancelled'
      AND ((v_type = 'wholesaler' AND o.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND o.pharmacy_id = p_business_id))
      AND (p_counterparty_id IS NULL OR p_counterparty_id = CASE WHEN v_type = 'wholesaler' THEN o.pharmacy_id ELSE o.wholesaler_id END)
      AND s.outstanding_ghs > 0 AND s.status NOT IN ('paid', 'written_off')
    GROUP BY 1
  ) a ON a.bucket = k.bucket
  ORDER BY k.ord;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_aging_summary(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.credit_aging_summary(UUID, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- Payment register: what was paid, how it was allocated, what is still unallocated, what was reversed.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.list_credit_payments(
  p_business_id UUID,
  p_counterparty_id UUID DEFAULT NULL,
  p_from DATE DEFAULT NULL,
  p_to DATE DEFAULT NULL,
  p_method TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 200,
  p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
  payment_id UUID, paid_at TIMESTAMPTZ, counterparty_id UUID, counterparty_name TEXT,
  amount_ghs NUMERIC, method TEXT, reference TEXT, notes TEXT, recorded_by_email TEXT,
  allocated_ghs NUMERIC, unallocated_ghs NUMERIC, reversed_ghs NUMERIC, allocation_count INTEGER,
  has_proof BOOLEAN, total_count BIGINT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type TEXT;
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;
  SELECT b.type::TEXT INTO v_type FROM public.businesses b WHERE b.id = p_business_id;
  IF p_method IS NOT NULL AND p_method NOT IN ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'online', 'other') THEN
    RAISE EXCEPTION 'Invalid payment method.';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 2000 THEN RAISE EXCEPTION 'The page size must be between 1 and 2000.'; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset.'; END IF;

  RETURN QUERY
  SELECT p.id, p.paid_at, cp.id, cp.name, p.amount_ghs, p.method, p.reference, p.notes, u.email::TEXT,
    COALESCE(a.allocated, 0)::NUMERIC(12,2),
    GREATEST(p.amount_ghs - COALESCE(a.allocated, 0), 0)::NUMERIC(12,2),
    COALESCE(r.reversed, 0)::NUMERIC(12,2),
    COALESCE(a.n, 0)::INTEGER,
    (p.proof_url IS NOT NULL),
    count(*) OVER ()
  FROM public.credit_payments p
  JOIN public.businesses cp ON cp.id = CASE WHEN v_type = 'wholesaler' THEN p.pharmacy_id ELSE p.wholesaler_id END
  LEFT JOIN auth.users u ON u.id = p.recorded_by
  LEFT JOIN LATERAL (
    SELECT sum(al.amount_ghs) AS allocated, count(*) AS n FROM public.credit_payment_allocations al WHERE al.payment_id = p.id
  ) a ON TRUE
  LEFT JOIN LATERAL (
    SELECT sum(rv.amount_ghs) AS reversed
    FROM public.credit_ledger_entries rv
    WHERE rv.entry_type = 'reversal'
      AND rv.reverses_entry_id IN (SELECT e.id FROM public.credit_ledger_entries e WHERE e.payment_id = p.id AND e.entry_type = 'payment')
  ) r ON TRUE
  WHERE ((v_type = 'wholesaler' AND p.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND p.pharmacy_id = p_business_id))
    AND (p_counterparty_id IS NULL OR cp.id = p_counterparty_id)
    AND (p_from IS NULL OR p.paid_at::DATE >= p_from)
    AND (p_to IS NULL OR p.paid_at::DATE <= p_to)
    AND (p_method IS NULL OR p.method = p_method)
  ORDER BY p.paid_at DESC, p.id
  LIMIT p_limit OFFSET p_offset;
END;
$$;
REVOKE ALL ON FUNCTION public.list_credit_payments(UUID, UUID, DATE, DATE, TEXT, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_credit_payments(UUID, UUID, DATE, DATE, TEXT, INTEGER, INTEGER) TO authenticated;
