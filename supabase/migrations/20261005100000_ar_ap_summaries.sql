-- Accounts Receivable (wholesaler) / Accounts Payable (pharmacy) summaries, phase 3 of the
-- procurement/credit/RFQ expansion. Both are read-only aggregates over the existing credit
-- ledger (credit_invoice_status, credit_ledger_entries) -- no new tables, matching how every
-- other report RPC in this codebase works.
--
-- Wording follows the brief's own phrasing for each side: the wholesaler view uses rolling
-- "within 7/30 days" windows from today; the pharmacy view uses calendar "this week"/"this month"
-- (Monday-start week, matching resolve_report_range's own this_week convention elsewhere).

CREATE OR REPLACE FUNCTION public.wholesaler_ar_summary(p_wholesaler_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this wholesaler''s receivables.';
  END IF;

  WITH invoices AS (
    SELECT o.id, o.pharmacy_id, p.name AS pharmacy_name, o.credit_due_date,
      s.invoice_ghs, s.outstanding_ghs, s.status
    FROM public.orders o
    JOIN public.businesses p ON p.id = o.pharmacy_id
    CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
    WHERE o.wholesaler_id = p_wholesaler_id AND o.is_credit_order
  ),
  open_invoices AS (
    SELECT * FROM invoices WHERE status NOT IN ('paid', 'written_off')
  ),
  by_pharmacy AS (
    SELECT pharmacy_id, pharmacy_name, SUM(outstanding_ghs) AS outstanding_ghs, COUNT(*) AS invoice_count
    FROM open_invoices
    GROUP BY pharmacy_id, pharmacy_name
    HAVING SUM(outstanding_ghs) > 0
  )
  SELECT jsonb_build_object(
    'total_credit_sales_ghs', COALESCE((SELECT SUM(invoice_ghs) FROM invoices), 0),
    'total_outstanding_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices), 0),
    'due_within_7_days_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
      WHERE credit_due_date BETWEEN current_date AND current_date + 7), 0),
    'due_within_30_days_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
      WHERE credit_due_date BETWEEN current_date AND current_date + 30), 0),
    'overdue_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices WHERE status = 'overdue'), 0),
    'collected_this_month_ghs', COALESCE((
      SELECT SUM(amount_ghs) FROM public.credit_ledger_entries
      WHERE wholesaler_id = p_wholesaler_id AND direction = 'credit' AND entry_type = 'payment'
        AND created_at >= date_trunc('month', now())
    ), 0),
    'invoice_count', (SELECT COUNT(*) FROM invoices),
    'outstanding_invoice_count', (SELECT COUNT(*) FROM open_invoices),
    'aging', jsonb_build_object(
      'current', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date IS NULL OR credit_due_date >= current_date), 0),
      'days_1_30', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date AND credit_due_date >= current_date - 30), 0),
      'days_31_60', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 30 AND credit_due_date >= current_date - 60), 0),
      'days_61_90', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 60 AND credit_due_date >= current_date - 90), 0),
      'days_90_plus', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 90), 0)
    ),
    'outstanding_by_pharmacy', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'pharmacy_id', pharmacy_id, 'pharmacy_name', pharmacy_name,
        'outstanding_ghs', outstanding_ghs, 'invoice_count', invoice_count
      ) ORDER BY outstanding_ghs DESC) FROM by_pharmacy
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.wholesaler_ar_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.wholesaler_ar_summary(UUID) TO authenticated;

CREATE OR REPLACE FUNCTION public.pharmacy_ap_summary(p_pharmacy_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
  v_week_end DATE;
  v_month_end DATE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s payables.';
  END IF;

  v_week_end := (date_trunc('week', now()) + interval '6 days')::DATE;
  v_month_end := (date_trunc('month', now()) + interval '1 month' - interval '1 day')::DATE;

  WITH invoices AS (
    SELECT o.id, o.wholesaler_id, w.name AS wholesaler_name, o.credit_due_date,
      s.invoice_ghs, s.outstanding_ghs, s.status
    FROM public.orders o
    JOIN public.businesses w ON w.id = o.wholesaler_id
    CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
    WHERE o.pharmacy_id = p_pharmacy_id AND o.is_credit_order
  ),
  open_invoices AS (
    SELECT * FROM invoices WHERE status NOT IN ('paid', 'written_off')
  ),
  by_wholesaler AS (
    SELECT wholesaler_id, wholesaler_name, SUM(outstanding_ghs) AS outstanding_ghs, COUNT(*) AS invoice_count
    FROM open_invoices
    GROUP BY wholesaler_id, wholesaler_name
    HAVING SUM(outstanding_ghs) > 0
  )
  SELECT jsonb_build_object(
    'total_supplier_debt_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices), 0),
    'due_this_week_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
      WHERE credit_due_date BETWEEN current_date AND v_week_end), 0),
    'due_this_month_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
      WHERE credit_due_date BETWEEN current_date AND v_month_end), 0),
    'overdue_ghs', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices WHERE status = 'overdue'), 0),
    'paid_this_month_ghs', COALESCE((
      SELECT SUM(amount_ghs) FROM public.credit_ledger_entries
      WHERE pharmacy_id = p_pharmacy_id AND direction = 'credit' AND entry_type = 'payment'
        AND created_at >= date_trunc('month', now())
    ), 0),
    'invoice_count', (SELECT COUNT(*) FROM invoices),
    'outstanding_invoice_count', (SELECT COUNT(*) FROM open_invoices),
    'aging', jsonb_build_object(
      'current', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date IS NULL OR credit_due_date >= current_date), 0),
      'days_1_30', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date AND credit_due_date >= current_date - 30), 0),
      'days_31_60', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 30 AND credit_due_date >= current_date - 60), 0),
      'days_61_90', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 60 AND credit_due_date >= current_date - 90), 0),
      'days_90_plus', COALESCE((SELECT SUM(outstanding_ghs) FROM open_invoices
        WHERE credit_due_date < current_date - 90), 0)
    ),
    'outstanding_by_wholesaler', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'wholesaler_id', wholesaler_id, 'wholesaler_name', wholesaler_name,
        'outstanding_ghs', outstanding_ghs, 'invoice_count', invoice_count
      ) ORDER BY outstanding_ghs DESC) FROM by_wholesaler
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.pharmacy_ap_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pharmacy_ap_summary(UUID) TO authenticated;
