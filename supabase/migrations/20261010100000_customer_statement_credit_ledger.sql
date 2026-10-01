-- Fixes the known limitation documented in 20261003110000_credit_ledger_logic.sql: customer_statement()
-- derived its "payment" line from orders.payment_status = 'paid' (all-or-nothing), so a credit
-- order with a partial payment recorded via record_credit_payment() still showed as fully
-- outstanding until paid off completely.
--
-- Fix: for credit orders (is_credit_order), pull real payment lines directly from
-- credit_ledger_entries instead -- every partial or full payment, and any reversal of one, each as
-- its own line with the ledger's own direction carrying the sign. Cash (non-credit) orders are
-- untouched: they never get ledger entries, so they keep the original payment_status-based line.
--
-- The 'order' debit line still comes from orders.total_ghs directly (unchanged) -- NOT from the
-- ledger's own 'invoice' entry, which this migration deliberately excludes, to avoid double-
-- counting the same debt twice.
--
-- Deliberately out of scope: adjustments, write-offs, and credit/debit notes are not surfaced as
-- their own statement lines here. The frontend's StatementLine.kind type is a fixed
-- "order" | "payment" | "return" union (src/lib/statement.ts); widening it to label every ledger
-- entry type distinctly is a separate, not-yet-requested enhancement. This fix targets exactly the
-- documented gap -- payments -- not a general ledger-to-statement redesign.
--
-- Also changes SECURITY INVOKER to SECURITY DEFINER: credit_ledger_entries' own RLS only allows
-- admins to SELECT it directly (every other read already goes through a SECURITY DEFINER RPC --
-- see get_credit_invoice/list_credit_invoices). customer_statement already does its own explicit
-- owner-or-staff check before touching any data, so this is safe; without it, the new ledger-based
-- lines would silently return zero rows for every non-admin caller -- the exact caller this
-- function exists for.

CREATE OR REPLACE FUNCTION public.customer_statement(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c_line_cap CONSTANT INTEGER := 2000;
  v_wholesaler RECORD;
  v_pharmacy RECORD;
  v_opening NUMERIC;
  v_debits NUMERIC;
  v_credits NUMERIC;
  v_lines JSONB;
  v_line_count BIGINT;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
    RAISE EXCEPTION 'Choose a valid date range for the statement.';
  END IF;

  SELECT id, name, city, region, owner_id INTO v_wholesaler FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  SELECT id, name, city, region, owner_id INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_wholesaler.id IS NULL OR v_pharmacy.id IS NULL THEN RAISE EXCEPTION 'Statement not found.'; END IF;

  IF NOT (
    v_wholesaler.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_wholesaler_id)
    OR v_pharmacy.owner_id = auth.uid() OR public.is_business_staff(auth.uid(), p_pharmacy_id)
  ) THEN
    RAISE EXCEPTION 'You do not have access to this statement.';
  END IF;

  WITH ledger AS (
    SELECT o.created_at AS at, 'order'::TEXT AS kind, 'debit'::TEXT AS direction, o.id AS order_id, o.order_number,
      o.total_ghs AS amount, o.discount_amount_ghs AS discount
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status <> 'refunded'
    UNION ALL
    -- Cash (non-credit) orders: unchanged, a single full-amount line once marked paid.
    SELECT COALESCE(o.paid_at, o.payment_confirmed_at, o.created_at), 'payment', 'credit', o.id, o.order_number,
      o.total_ghs, 0::NUMERIC
    FROM public.orders o
    WHERE o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.payment_status = 'paid' AND NOT o.is_credit_order
    UNION ALL
    -- Credit orders: real payments (partial or full), straight from the ledger -- a partial
    -- payment shows up immediately instead of the order looking fully outstanding until it's paid
    -- off completely. Reversals of a payment are included too (e.g. a wrongly-recorded payment
    -- undone); reversals of anything else are not, since this fix doesn't surface those other
    -- entry types in the first place.
    SELECT e.created_at, 'payment', e.direction, e.order_id, o.order_number, e.amount_ghs, 0::NUMERIC
    FROM public.credit_ledger_entries e
    JOIN public.orders o ON o.id = e.order_id
    WHERE e.wholesaler_id = p_wholesaler_id AND e.pharmacy_id = p_pharmacy_id
      AND o.status <> 'cancelled' AND o.is_credit_order
      AND (
        e.entry_type = 'payment'
        OR (e.entry_type = 'reversal' AND EXISTS (
          SELECT 1 FROM public.credit_ledger_entries orig
          WHERE orig.id = e.reverses_entry_id AND orig.entry_type = 'payment'
        ))
      )
    UNION ALL
    SELECT c.resolved_at, 'return', 'credit', c.order_id, c.return_number, c.amount_ghs, 0::NUMERIC
    FROM public.statement_return_credits(p_wholesaler_id, p_pharmacy_id) c
  ),
  opening AS (
    SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END), 0) AS v
    FROM ledger WHERE at < p_from
  ),
  in_range AS (SELECT * FROM ledger WHERE at >= p_from AND at < p_to),
  totals AS (
    SELECT COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0) AS debits,
      COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0) AS credits,
      COUNT(*) AS n
    FROM in_range
  ),
  running AS (
    SELECT r.*, (SELECT v FROM opening) + SUM(CASE WHEN r.direction = 'debit' THEN r.amount ELSE -r.amount END)
      OVER (ORDER BY r.at, r.kind, r.order_number ROWS UNBOUNDED PRECEDING) AS balance
    FROM in_range r
    ORDER BY r.at, r.kind, r.order_number
    LIMIT c_line_cap
  )
  SELECT
    (SELECT v FROM opening), (SELECT debits FROM totals), (SELECT credits FROM totals), (SELECT n FROM totals),
    COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'date', x.at, 'kind', x.kind, 'order_id', x.order_id, 'order_number', x.order_number,
      'debit', CASE WHEN x.direction = 'debit' THEN x.amount ELSE 0 END,
      'credit', CASE WHEN x.direction = 'credit' THEN x.amount ELSE 0 END,
      'discount', x.discount, 'balance', x.balance) ORDER BY x.at, x.kind, x.order_number) FROM running x), '[]'::JSONB)
  INTO v_opening, v_debits, v_credits, v_line_count, v_lines;

  RETURN jsonb_build_object(
    'wholesaler', jsonb_build_object('id', v_wholesaler.id, 'name', v_wholesaler.name, 'city', v_wholesaler.city, 'region', v_wholesaler.region),
    'pharmacy', jsonb_build_object('id', v_pharmacy.id, 'name', v_pharmacy.name, 'city', v_pharmacy.city, 'region', v_pharmacy.region),
    'from', p_from, 'to', p_to,
    'opening_balance', v_opening,
    'total_debits', v_debits,
    'total_credits', v_credits,
    'closing_balance', v_opening + v_debits - v_credits,
    'line_count', v_line_count,
    'truncated', v_line_count > c_line_cap,
    'lines', v_lines
  );
END;
$$;

REVOKE ALL ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_statement(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
