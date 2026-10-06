-- Accounting overview: everything the finance part of the dashboard shows, in one call, from the database.
--
-- Until now the dashboard fetched every outstanding invoice and did its own totals and aging in the browser,
-- with its own four buckets, while the Accounting registers and the Credit tabs aged in the database with
-- five. This is the single source for the dashboard: the same invoices, the same outstanding balances and the
-- same aging rule (credit_aging_bucket) as the Accounting registers.
--
-- What is counted: credit invoices still owed (outstanding > 0, not cancelled, not written off), on the
-- OUTSTANDING balance. Disputed invoices are included (they are still owed) and also reported separately.
--   overdue    = past its due date today (every aging bucket except 'current')
--   due_soon   = due from today up to and including 7 days ahead (not yet overdue)
--   top_overdue = the counterparties owing (or owed) the most overdue money, largest first
--   payments_30d = payments recorded in the last 30 days (count and total)
--   on_account = money paid that is not matched to any invoice, summed over the counterparties where it is
--                positive (it reduces what is really owed; it is NOT netted into the invoice figures above)
--
-- Access: can_view_accounting() only (wholesaler owner/manager/finance/accountant, pharmacy
-- owner/manager/accountant), the same gate as the registers.

CREATE FUNCTION public.accounting_overview(p_business_id UUID, p_top INTEGER DEFAULT 5)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type TEXT;
  v_result JSONB;
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;
  IF p_top IS NULL OR p_top < 1 OR p_top > 20 THEN
    RAISE EXCEPTION 'The list size must be between 1 and 20.';
  END IF;
  SELECT b.type::TEXT INTO v_type FROM public.businesses b WHERE b.id = p_business_id;

  WITH inv AS (
    SELECT o.id, cp.id AS cp_id, cp.name AS cp_name, o.credit_due_date AS due, s.outstanding_ghs AS amt, s.status AS st,
      public.credit_aging_bucket(o.credit_due_date, current_date) AS bucket
    FROM public.orders o
    JOIN public.businesses cp ON cp.id = CASE WHEN v_type = 'wholesaler' THEN o.pharmacy_id ELSE o.wholesaler_id END
    CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
    WHERE o.is_credit_order AND o.status::TEXT <> 'cancelled'
      AND ((v_type = 'wholesaler' AND o.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND o.pharmacy_id = p_business_id))
      AND s.outstanding_ghs > 0 AND s.status NOT IN ('paid', 'written_off')
  ), by_party AS (
    SELECT i.cp_id, i.cp_name, sum(i.amt) AS overdue, count(*) AS invoices, max(current_date - i.due) AS oldest_days
    FROM inv i WHERE i.bucket <> 'current' GROUP BY i.cp_id, i.cp_name
  ), pay AS (
    SELECT count(*) AS n, COALESCE(sum(p.amount_ghs), 0) AS total
    FROM public.credit_payments p
    WHERE ((v_type = 'wholesaler' AND p.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND p.pharmacy_id = p_business_id))
      AND p.paid_at >= now() - interval '30 days'
  ), acct AS (
    SELECT COALESCE(sum(x.bal), 0) AS total, count(*) AS parties FROM (
      SELECT sum(CASE e.direction WHEN 'credit' THEN e.amount_ghs ELSE -e.amount_ghs END) AS bal
      FROM public.credit_ledger_entries e
      WHERE ((v_type = 'wholesaler' AND e.wholesaler_id = p_business_id) OR (v_type = 'pharmacy' AND e.pharmacy_id = p_business_id))
        AND e.order_id IS NULL
      GROUP BY CASE WHEN v_type = 'wholesaler' THEN e.pharmacy_id ELSE e.wholesaler_id END
      HAVING sum(CASE e.direction WHEN 'credit' THEN e.amount_ghs ELSE -e.amount_ghs END) > 0
    ) x
  )
  SELECT jsonb_build_object(
    'side', v_type,
    'as_of', current_date,
    'outstanding_ghs', COALESCE((SELECT sum(amt) FROM inv), 0),
    'invoice_count', (SELECT count(*) FROM inv),
    'overdue_ghs', COALESCE((SELECT sum(amt) FROM inv WHERE bucket <> 'current'), 0),
    'overdue_count', (SELECT count(*) FROM inv WHERE bucket <> 'current'),
    'due_soon_ghs', COALESCE((SELECT sum(amt) FROM inv WHERE due >= current_date AND due <= current_date + 7), 0),
    'due_soon_count', (SELECT count(*) FROM inv WHERE due >= current_date AND due <= current_date + 7),
    'disputed_ghs', COALESCE((SELECT sum(amt) FROM inv WHERE st = 'disputed'), 0),
    'disputed_count', (SELECT count(*) FROM inv WHERE st = 'disputed'),
    'aging', (
      SELECT jsonb_agg(jsonb_build_object('bucket', k.bucket, 'invoices', COALESCE(a.n, 0), 'outstanding_ghs', COALESCE(a.total, 0)) ORDER BY k.ord)
      FROM (VALUES ('current', 1), ('d1_30', 2), ('d31_60', 3), ('d61_90', 4), ('d90_plus', 5)) k(bucket, ord)
      LEFT JOIN (SELECT bucket, count(*) AS n, sum(amt) AS total FROM inv GROUP BY bucket) a ON a.bucket = k.bucket
    ),
    'top_overdue', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('counterparty_id', t.cp_id, 'counterparty_name', t.cp_name,
        'overdue_ghs', t.overdue, 'invoices', t.invoices, 'oldest_days_overdue', t.oldest_days) ORDER BY t.overdue DESC, t.cp_name, t.cp_id)
      FROM (SELECT * FROM by_party ORDER BY overdue DESC, cp_name, cp_id LIMIT p_top) t
    ), '[]'::JSONB),
    'payments_30d', jsonb_build_object('count', (SELECT n FROM pay), 'total_ghs', (SELECT total FROM pay)),
    'on_account', jsonb_build_object('total_ghs', (SELECT total FROM acct), 'parties', (SELECT parties FROM acct))
  ) INTO v_result;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.accounting_overview(UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accounting_overview(UUID, INTEGER) TO authenticated;
