-- Credit account statements for the Accounting workspace.
--
-- A statement is the credit ledger between ONE wholesaler and ONE pharmacy over a date range, read from
-- both sides (the wholesaler's accounts receivable, the pharmacy's accounts payable):
--     opening balance + charges - credits = closing balance
-- Charges (debits) are invoices, debit notes and reversals of credits; credits are payments, credit notes,
-- write-offs and reversals of charges. Every ledger entry is its own line with a running balance, so a
-- cancelled order shows its invoice and the credit note that released it, a reversed payment shows both
-- the payment and its reversal, and a write-off is visible as one. Nothing is netted away silently.
--
-- The balance is the TRUE running balance: an overpayment shows as a negative balance (credit held on
-- account) rather than being floored at zero as credit_exposure() does for limit checks.
--
-- Range rules: a line belongs to the range when its entry date (UTC date of created_at, the same date the
-- invoice register uses) is between p_from and p_to inclusive. Opening balance = every entry dated before
-- p_from. Lines are ordered by time, then charges before credits, then order number.
--
-- This is separate from the older "statement of account" (customer_statement), which covers all orders
-- including cash ones and does not show adjustments, write-offs or credit notes; that one is unchanged.
--
-- The ageing block is as of TODAY (what is overdue now), not as of p_to, because ageing is a property of
-- open invoices today; the response says so by naming it aging_as_of.
--
-- Access: can_view_accounting() only (wholesaler owner/manager/finance/accountant, pharmacy
-- owner/manager/accountant). The counterparty must be a business the caller has a credit relationship
-- with (ledger entries or credit terms), so a name cannot be probed for.

CREATE FUNCTION public.credit_counterparties(p_business_id UUID)
RETURNS TABLE(counterparty_id UUID, counterparty_name TEXT)
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
  SELECT cp.id, cp.name
  FROM public.businesses cp
  WHERE cp.id IN (
    SELECT CASE WHEN v_type = 'wholesaler' THEN e.pharmacy_id ELSE e.wholesaler_id END
    FROM public.credit_ledger_entries e
    WHERE (v_type = 'wholesaler' AND e.wholesaler_id = p_business_id)
       OR (v_type = 'pharmacy' AND e.pharmacy_id = p_business_id)
    UNION
    SELECT CASE WHEN v_type = 'wholesaler' THEN t.pharmacy_id ELSE t.wholesaler_id END
    FROM public.wholesaler_credit_terms t
    WHERE (v_type = 'wholesaler' AND t.wholesaler_id = p_business_id)
       OR (v_type = 'pharmacy' AND t.pharmacy_id = p_business_id)
  )
  ORDER BY cp.name, cp.id;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_counterparties(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.credit_counterparties(UUID) TO authenticated;

CREATE FUNCTION public.credit_account_statement(
  p_business_id UUID,
  p_counterparty_id UUID,
  p_from DATE,
  p_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_line_cap CONSTANT INTEGER := 2000;
  v_type TEXT;
  v_wh UUID;
  v_ph UUID;
  v_business RECORD;
  v_cp RECORD;
  v_opening NUMERIC(14,2);
  v_debits NUMERIC(14,2);
  v_credits NUMERIC(14,2);
  v_count BIGINT;
  v_today_balance NUMERIC(14,2);
  v_lines JSONB;
  v_aging JSONB;
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'Choose a valid date range for the statement.';
  END IF;
  IF p_to - p_from > 1830 THEN
    RAISE EXCEPTION 'A statement can cover at most five years.';
  END IF;

  SELECT b.id, b.name, b.type::TEXT AS type, b.city, b.region INTO v_business FROM public.businesses b WHERE b.id = p_business_id;
  v_type := v_business.type;
  IF NOT EXISTS (SELECT 1 FROM public.credit_counterparties(p_business_id) c WHERE c.counterparty_id = p_counterparty_id) THEN
    RAISE EXCEPTION 'Statement not found.';
  END IF;
  SELECT b.id, b.name, b.city, b.region INTO v_cp FROM public.businesses b WHERE b.id = p_counterparty_id;
  v_wh := CASE WHEN v_type = 'wholesaler' THEN p_business_id ELSE p_counterparty_id END;
  v_ph := CASE WHEN v_type = 'wholesaler' THEN p_counterparty_id ELSE p_business_id END;

  WITH pair AS (
    SELECT e.* FROM public.credit_ledger_entries e WHERE e.wholesaler_id = v_wh AND e.pharmacy_id = v_ph
  ), opening AS (
    SELECT COALESCE(SUM(CASE p.direction WHEN 'debit' THEN p.amount_ghs ELSE -p.amount_ghs END), 0) AS v
    FROM pair p WHERE p.created_at::DATE < p_from
  ), in_range AS (
    SELECT e.id, e.created_at, e.entry_type, e.direction, e.amount_ghs, e.note, e.order_id, o.order_number,
      pay.method, pay.reference, orig.entry_type AS reversed_type,
      row_number() OVER (
        ORDER BY e.created_at, CASE e.direction WHEN 'debit' THEN 0 ELSE 1 END, o.order_number NULLS LAST, e.id
      ) AS seq
    FROM pair e
    LEFT JOIN public.orders o ON o.id = e.order_id
    LEFT JOIN public.credit_payments pay ON pay.id = e.payment_id
    LEFT JOIN public.credit_ledger_entries orig ON orig.id = e.reverses_entry_id
    WHERE e.created_at::DATE BETWEEN p_from AND p_to
  ), totals AS (
    SELECT COALESCE(SUM(r.amount_ghs) FILTER (WHERE r.direction = 'debit'), 0) AS debits,
      COALESCE(SUM(r.amount_ghs) FILTER (WHERE r.direction = 'credit'), 0) AS credits,
      count(*) AS n
    FROM in_range r
  ), running AS (
    SELECT r.*, (SELECT v FROM opening)
      + SUM(CASE r.direction WHEN 'debit' THEN r.amount_ghs ELSE -r.amount_ghs END) OVER (ORDER BY r.seq ROWS UNBOUNDED PRECEDING) AS balance
    FROM in_range r
    ORDER BY r.seq
    LIMIT c_line_cap
  )
  SELECT (SELECT v FROM opening), (SELECT debits FROM totals), (SELECT credits FROM totals), (SELECT n FROM totals),
    (SELECT COALESCE(SUM(CASE p.direction WHEN 'debit' THEN p.amount_ghs ELSE -p.amount_ghs END), 0) FROM pair p),
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'date', x.created_at::DATE, 'entry_type', x.entry_type, 'order_id', x.order_id, 'order_number', x.order_number,
      'method', x.method, 'reference', x.reference, 'note', x.note, 'reversed_type', x.reversed_type,
      'debit', CASE WHEN x.direction = 'debit' THEN x.amount_ghs ELSE 0 END,
      'credit', CASE WHEN x.direction = 'credit' THEN x.amount_ghs ELSE 0 END,
      'balance', x.balance) ORDER BY x.seq) FROM running x), '[]'::JSONB)
  INTO v_opening, v_debits, v_credits, v_count, v_today_balance, v_lines;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('bucket', a.bucket, 'invoices', a.invoices, 'outstanding_ghs', a.outstanding_ghs)), '[]'::JSONB)
  INTO v_aging
  FROM public.credit_aging_summary(p_business_id, p_counterparty_id) a;

  RETURN jsonb_build_object(
    'side', v_type,
    'business', jsonb_build_object('id', v_business.id, 'name', v_business.name, 'city', v_business.city, 'region', v_business.region),
    'counterparty', jsonb_build_object('id', v_cp.id, 'name', v_cp.name, 'city', v_cp.city, 'region', v_cp.region),
    'from', p_from, 'to', p_to,
    'opening_balance', v_opening,
    'total_charges', v_debits,
    'total_credits', v_credits,
    'closing_balance', v_opening + v_debits - v_credits,
    'balance_today', v_today_balance,
    'line_count', v_count,
    'truncated', v_count > c_line_cap,
    'aging_as_of', current_date,
    'aging', v_aging,
    'lines', v_lines
  );
END;
$$;
REVOKE ALL ON FUNCTION public.credit_account_statement(UUID, UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.credit_account_statement(UUID, UUID, DATE, DATE) TO authenticated;
