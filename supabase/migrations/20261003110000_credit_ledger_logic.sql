-- Credit ledger, part 2: status computation, RPCs, legacy-flow mirroring, checkout hook, backfill.
--
-- Two payment paths now coexist, both feeding the same ledger:
--   1. The existing "Confirm payment received" button (api/orders/confirm-payment.ts) - unchanged,
--      still a simple full-settlement action. A trigger mirrors it into a ledger 'payment' entry
--      sized to whatever is still outstanding (not blindly total_ghs), so it stays correct even if
--      the order was already partially paid via path 2.
--   2. record_credit_payment() - the new granular path: partial payments, one payment across many
--      invoices, one invoice from many payments (the brief's §7 requirement).
-- Both paths keep orders.payment_status in sync ('paid' once the ledger balance reaches zero) so
-- every existing UI/report that reads payment_status directly keeps working unchanged.
--
-- Known limitation (documented, not hidden): customer_statement() still derives its "payment" line
-- from orders.payment_status = 'paid' rather than from credit_ledger_entries directly. A credit
-- order with a partial payment recorded via record_credit_payment() will still show as fully
-- outstanding on the statement until it's paid in full. Wiring customer_statement to the ledger
-- directly is follow-up work, not done in this pass.

-- ---------------------------------------------------------------------------
-- 1. credit_invoice_status: internal helper (not directly callable by clients), the single place
--    that turns ledger entries + due date + dispute flag into the brief's 7-state status.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.credit_invoice_status(p_order_id UUID)
RETURNS TABLE (invoice_ghs NUMERIC, paid_ghs NUMERIC, outstanding_ghs NUMERIC, status TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_invoice_total NUMERIC(12,2);
  v_debits NUMERIC(12,2);
  v_credits NUMERIC(12,2);
  v_outstanding NUMERIC(12,2);
  v_has_write_off BOOLEAN;
BEGIN
  SELECT o.total_ghs, o.credit_due_date, o.credit_disputed_at, o.is_credit_order INTO v_order
  FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN
    RETURN;
  END IF;

  -- invoice_total is the 'invoice'-entry total specifically, not every debit -- a reversed
  -- payment posts as a debit too (to undo the earlier credit), and using the raw debit sum here
  -- would make a fully-reversed payment look like a partial payment forever after (outstanding
  -- would sit below the inflated "total debited" figure even though nothing was ever effectively
  -- paid). Comparing outstanding against invoice_total instead of a raw "any credits posted?"
  -- check keeps partially_paid reversal-safe.
  SELECT COALESCE(SUM(amount_ghs) FILTER (WHERE entry_type = 'invoice'), 0),
    COALESCE(SUM(amount_ghs) FILTER (WHERE direction = 'debit'), 0),
    COALESCE(SUM(amount_ghs) FILTER (WHERE direction = 'credit'), 0),
    bool_or(entry_type = 'write_off')
  INTO v_invoice_total, v_debits, v_credits, v_has_write_off
  FROM public.credit_ledger_entries WHERE order_id = p_order_id;

  v_outstanding := GREATEST(v_debits - v_credits, 0);

  RETURN QUERY SELECT
    v_invoice_total, GREATEST(v_invoice_total - v_outstanding, 0), v_outstanding,
    CASE
      WHEN v_has_write_off THEN 'written_off'
      WHEN v_order.credit_disputed_at IS NOT NULL THEN 'disputed'
      WHEN v_outstanding <= 0 THEN 'paid'
      WHEN v_outstanding < v_invoice_total THEN 'partially_paid'
      WHEN v_order.credit_due_date IS NULL THEN 'not_due'
      WHEN v_order.credit_due_date < current_date THEN 'overdue'
      WHEN v_order.credit_due_date = current_date THEN 'due_today'
      ELSE 'not_due'
    END;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_invoice_status(UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. get_credit_invoice: one invoice's full detail (header + status + every ledger line).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_credit_invoice(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_status RECORD;
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id, o.total_ghs, o.created_at,
    o.credit_due_date, o.credit_disputed_at, o.credit_dispute_reason, o.is_credit_order
  INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN RAISE EXCEPTION 'Credit invoice not found.'; END IF;
  IF NOT (public.can_act_for_business(v_order.pharmacy_id, 'read') OR public.can_act_for_business(v_order.wholesaler_id, 'read')) THEN
    RAISE EXCEPTION 'You do not have access to this invoice.';
  END IF;

  SELECT * INTO v_status FROM public.credit_invoice_status(p_order_id);

  SELECT jsonb_build_object(
    'order_id', v_order.id, 'order_number', v_order.order_number,
    'pharmacy_id', v_order.pharmacy_id, 'wholesaler_id', v_order.wholesaler_id,
    'created_at', v_order.created_at,
    'invoice_ghs', v_status.invoice_ghs, 'paid_ghs', v_status.paid_ghs, 'outstanding_ghs', v_status.outstanding_ghs,
    'status', v_status.status, 'due_date', v_order.credit_due_date,
    'disputed_at', v_order.credit_disputed_at, 'dispute_reason', v_order.credit_dispute_reason,
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', e.id, 'entry_type', e.entry_type, 'direction', e.direction, 'amount_ghs', e.amount_ghs,
        'note', e.note, 'created_at', e.created_at, 'payment_id', e.payment_id, 'reverses_entry_id', e.reverses_entry_id
      ) ORDER BY e.created_at, e.id) FROM public.credit_ledger_entries e WHERE e.order_id = p_order_id
    ), '[]'::JSONB)
  ) INTO v_result;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_credit_invoice(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_credit_invoice(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. record_credit_payment: the granular payment path. owner/manager/finance/accountant only
--    (not cashier/warehouse/assistant - matches the brief's "Record payments: Yes" for accountant
--    and finance's existing purpose). Locks every order it touches (FOR UPDATE) before checking
--    outstanding balance, so a concurrent "Confirm payment received" click or a second payment
--    recording can never both act on a stale balance for the same order.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_credit_payment(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_amount NUMERIC,
  p_method TEXT,
  p_reference TEXT DEFAULT NULL,
  p_paid_at TIMESTAMPTZ DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_proof_url TEXT DEFAULT NULL,
  p_allocations JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_payment_id UUID;
  v_alloc RECORD;
  v_alloc_sum NUMERIC(12,2) := 0;
  v_order RECORD;
  v_status RECORD;
  v_entry_id UUID;
  v_unallocated NUMERIC(12,2);
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_paid_at TIMESTAMPTZ := COALESCE(p_paid_at, now());
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid()) INTO v_is_owner;
  v_role := public.get_staff_role(auth.uid(), p_wholesaler_id);
  IF NOT v_is_owner AND (v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'finance', 'accountant')) THEN
    RAISE EXCEPTION 'You do not have permission to record payments for this wholesaler.';
  END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  IF v_wholesaler_name IS NULL THEN RAISE EXCEPTION 'Wholesaler workspace not found.'; END IF;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_pharmacy_name IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter a payment amount greater than zero.'; END IF;
  IF p_method IS NULL OR p_method NOT IN ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'online', 'other') THEN
    RAISE EXCEPTION 'Choose a valid payment method.';
  END IF;
  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN RAISE EXCEPTION 'Invalid allocation list.'; END IF;

  -- Validate the allocation total against the payment amount BEFORE writing anything.
  SELECT COALESCE(SUM(round((x ->> 'amount')::NUMERIC, 2)), 0) INTO v_alloc_sum
  FROM jsonb_array_elements(p_allocations) x;
  IF v_alloc_sum > round(p_amount, 2) THEN
    RAISE EXCEPTION 'Allocations (GHS %) cannot exceed the payment amount (GHS %).',
      to_char(v_alloc_sum, 'FM999,999,990.00'), to_char(p_amount, 'FM999,999,990.00');
  END IF;

  INSERT INTO public.credit_payments (wholesaler_id, pharmacy_id, amount_ghs, method, reference, paid_at, recorded_by, proof_url, notes)
  VALUES (p_wholesaler_id, p_pharmacy_id, round(p_amount, 2), p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''), v_paid_at, auth.uid(), p_proof_url, NULLIF(btrim(COALESCE(p_notes, '')), ''))
  RETURNING id INTO v_payment_id;

  FOR v_alloc IN
    SELECT (x ->> 'order_id')::UUID AS order_id, round((x ->> 'amount')::NUMERIC, 2) AS amount
    FROM jsonb_array_elements(p_allocations) x
  LOOP
    IF v_alloc.order_id IS NULL OR v_alloc.amount IS NULL OR v_alloc.amount <= 0 THEN
      RAISE EXCEPTION 'Each allocation needs a valid order and a positive amount.';
    END IF;

    SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.payment_status INTO v_order
    FROM public.orders o WHERE o.id = v_alloc.order_id FOR UPDATE;
    IF NOT FOUND OR v_order.wholesaler_id <> p_wholesaler_id OR v_order.pharmacy_id <> p_pharmacy_id OR NOT v_order.is_credit_order THEN
      RAISE EXCEPTION 'Order % is not a credit order between these two businesses.', v_alloc.order_id;
    END IF;

    SELECT * INTO v_status FROM public.credit_invoice_status(v_alloc.order_id);
    IF v_alloc.amount > v_status.outstanding_ghs THEN
      RAISE EXCEPTION 'Allocation of GHS % exceeds the outstanding balance of GHS % on order %.',
        to_char(v_alloc.amount, 'FM999,999,990.00'), to_char(v_status.outstanding_ghs, 'FM999,999,990.00'), v_alloc.order_id;
    END IF;

    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, created_by)
    VALUES (p_wholesaler_id, p_pharmacy_id, v_alloc.order_id, 'payment', 'credit', v_alloc.amount, v_payment_id, auth.uid())
    RETURNING id INTO v_entry_id;

    INSERT INTO public.credit_payment_allocations (payment_id, order_id, amount_ghs, ledger_entry_id)
    VALUES (v_payment_id, v_alloc.order_id, v_alloc.amount, v_entry_id);

    IF v_alloc.amount >= v_status.outstanding_ghs AND v_order.payment_status <> 'paid' THEN
      UPDATE public.orders SET payment_status = 'paid', paid_at = COALESCE(paid_at, v_paid_at),
        payment_confirmed_at = now(), payment_confirmed_by = auth.uid()
      WHERE id = v_alloc.order_id;
    END IF;
  END LOOP;

  v_unallocated := round(p_amount, 2) - v_alloc_sum;
  IF v_unallocated > 0 THEN
    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, created_by, note)
    VALUES (p_wholesaler_id, p_pharmacy_id, NULL, 'payment', 'credit', v_unallocated, v_payment_id, auth.uid(), 'Unallocated credit on account.');
  END IF;

  PERFORM public.write_audit_log('Credit payment recorded', v_wholesaler_name, 'business', p_pharmacy_id, v_pharmacy_name,
    jsonb_build_object('payment_id', v_payment_id, 'amount_ghs', p_amount, 'method', p_method, 'allocated_ghs', v_alloc_sum, 'unallocated_ghs', v_unallocated));

  RETURN jsonb_build_object('payment_id', v_payment_id, 'amount_ghs', p_amount, 'allocated_ghs', v_alloc_sum, 'unallocated_ghs', v_unallocated);
END;
$$;
REVOKE ALL ON FUNCTION public.record_credit_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_credit_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, JSONB) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. record_credit_adjustment: manual corrections (adjustment/credit_note/debit_note). owner/
--    manager only -- financial corrections are the most sensitive write in this migration.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_credit_adjustment(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_order_id UUID,
  p_entry_type TEXT,
  p_direction TEXT,
  p_amount NUMERIC,
  p_note TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may record ledger adjustments.';
  END IF;
  IF p_entry_type NOT IN ('adjustment', 'credit_note', 'debit_note') THEN
    RAISE EXCEPTION 'Invalid adjustment type.';
  END IF;
  IF p_direction NOT IN ('debit', 'credit') THEN RAISE EXCEPTION 'Invalid direction.'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount greater than zero.'; END IF;
  IF v_note IS NULL THEN RAISE EXCEPTION 'A reason is required for a ledger adjustment.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The reason is too long (500 characters maximum).'; END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  IF v_wholesaler_name IS NULL THEN RAISE EXCEPTION 'Wholesaler workspace not found.'; END IF;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_pharmacy_name IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;

  IF p_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id AND o.is_credit_order
  ) THEN
    RAISE EXCEPTION 'Order is not a credit order between these two businesses.';
  END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_order_id, p_entry_type, p_direction, round(p_amount, 2), auth.uid(), v_note)
  RETURNING id INTO v_entry_id;

  PERFORM public.write_audit_log('Credit ledger adjustment recorded', v_wholesaler_name, 'business', p_pharmacy_id, v_pharmacy_name,
    jsonb_build_object('entry_id', v_entry_id, 'entry_type', p_entry_type, 'direction', p_direction, 'amount_ghs', p_amount, 'order_id', p_order_id, 'reason', v_note));

  RETURN v_entry_id;
END;
$$;
REVOKE ALL ON FUNCTION public.record_credit_adjustment(UUID, UUID, UUID, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_credit_adjustment(UUID, UUID, UUID, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. write_off_credit_invoice: zeroes out whatever is still outstanding with a 'write_off' credit
--    entry (never deletes/edits history). owner/manager only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.write_off_credit_invoice(p_order_id UUID, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_status RECORD;
  v_entry_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.order_number INTO v_order
  FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN RAISE EXCEPTION 'Credit invoice not found.'; END IF;
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may write off a credit invoice.';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to write off an invoice.'; END IF;

  SELECT * INTO v_status FROM public.credit_invoice_status(p_order_id);
  IF v_status.outstanding_ghs <= 0 THEN RAISE EXCEPTION 'This invoice has no outstanding balance to write off.'; END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note)
  VALUES (v_order.wholesaler_id, v_order.pharmacy_id, p_order_id, 'write_off', 'credit', v_status.outstanding_ghs, auth.uid(), v_reason)
  RETURNING id INTO v_entry_id;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  PERFORM public.write_audit_log('Credit invoice written off', v_wholesaler_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('amount_ghs', v_status.outstanding_ghs, 'reason', v_reason));

  RETURN v_entry_id;
END;
$$;
REVOKE ALL ON FUNCTION public.write_off_credit_invoice(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.write_off_credit_invoice(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. reverse_credit_ledger_entry: the §41-mandated correction mechanism. Never touches the
--    original row -- inserts an opposite-direction entry linked back to it. owner/manager only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reverse_credit_ledger_entry(p_entry_id UUID, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_new_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT * INTO v_entry FROM public.credit_ledger_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ledger entry not found.'; END IF;
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(v_entry.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may reverse a ledger entry.';
  END IF;
  IF v_entry.entry_type = 'reversal' THEN RAISE EXCEPTION 'A reversal entry cannot itself be reversed.'; END IF;
  IF EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE reverses_entry_id = p_entry_id) THEN
    RAISE EXCEPTION 'This entry has already been reversed.';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to reverse a ledger entry.'; END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, reverses_entry_id, created_by, note)
  VALUES (v_entry.wholesaler_id, v_entry.pharmacy_id, v_entry.order_id, 'reversal',
    CASE v_entry.direction WHEN 'debit' THEN 'credit' ELSE 'debit' END,
    v_entry.amount_ghs, v_entry.payment_id, p_entry_id, auth.uid(), v_reason)
  RETURNING id INTO v_new_id;

  -- If the reversal reopens an order's balance, its payment_status needs to reflect that again.
  IF v_entry.order_id IS NOT NULL THEN
    UPDATE public.orders o SET payment_status = 'unpaid', paid_at = NULL, payment_confirmed_at = NULL, payment_confirmed_by = NULL
    WHERE o.id = v_entry.order_id AND o.payment_status = 'paid'
      AND (SELECT outstanding_ghs FROM public.credit_invoice_status(v_entry.order_id)) > 0;
  END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_entry.wholesaler_id;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_entry.pharmacy_id;
  PERFORM public.write_audit_log('Credit ledger entry reversed', v_wholesaler_name, 'business', v_entry.pharmacy_id, v_pharmacy_name,
    jsonb_build_object('original_entry_id', p_entry_id, 'reversal_entry_id', v_new_id, 'amount_ghs', v_entry.amount_ghs, 'reason', v_reason));

  RETURN v_new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.reverse_credit_ledger_entry(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_credit_ledger_entry(UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. set_credit_invoice_dispute: a hold flag independent of the ledger (a fully-outstanding
--    invoice can be disputed with zero money movement). owner/manager/accountant.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_credit_invoice_dispute(p_order_id UUID, p_disputed BOOLEAN, p_reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.order_number INTO v_order
  FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN RAISE EXCEPTION 'Credit invoice not found.'; END IF;

  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.wholesaler_id AND b.owner_id = auth.uid()) INTO v_is_owner;
  v_role := public.get_staff_role(auth.uid(), v_order.wholesaler_id);
  IF NOT v_is_owner AND (v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'accountant')) THEN
    RAISE EXCEPTION 'You do not have permission to dispute this invoice.';
  END IF;
  IF p_disputed AND v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to mark an invoice disputed.'; END IF;

  UPDATE public.orders SET
    credit_disputed_at = CASE WHEN p_disputed THEN now() ELSE NULL END,
    credit_dispute_reason = CASE WHEN p_disputed THEN v_reason ELSE NULL END
  WHERE id = p_order_id;

  PERFORM public.write_audit_log(
    CASE WHEN p_disputed THEN 'Credit invoice disputed' ELSE 'Credit invoice dispute cleared' END,
    (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id), 'order', p_order_id, v_order.order_number,
    jsonb_build_object('reason', v_reason));
END;
$$;
REVOKE ALL ON FUNCTION public.set_credit_invoice_dispute(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_credit_invoice_dispute(UUID, BOOLEAN, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Mirror the legacy "Confirm payment received" flow into the ledger. Tops up to whatever is
--    still outstanding (not a blind total_ghs credit), so it self-corrects for orders that
--    already had partial payments recorded via record_credit_payment.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mirror_legacy_credit_payment_to_ledger()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_outstanding NUMERIC(12,2);
BEGIN
  IF NEW.is_credit_order AND NEW.payment_status = 'paid' AND OLD.payment_status IS DISTINCT FROM 'paid' THEN
    SELECT outstanding_ghs INTO v_outstanding FROM public.credit_invoice_status(NEW.id);
    IF v_outstanding IS NOT NULL AND v_outstanding > 0 THEN
      INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note)
      VALUES (NEW.wholesaler_id, NEW.pharmacy_id, NEW.id, 'payment', 'credit', v_outstanding, NEW.payment_confirmed_by,
        'Recorded via the order''s Confirm Payment action.');
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mirror_legacy_credit_payment ON public.orders;
CREATE TRIGGER trg_mirror_legacy_credit_payment
  AFTER UPDATE ON public.orders
  FOR EACH ROW WHEN (NEW.is_credit_order) EXECUTE FUNCTION public.mirror_legacy_credit_payment_to_ledger();

-- ---------------------------------------------------------------------------
-- 9. Checkout hook: every new credit order gets its 'invoice' ledger entry the moment it's
--    created, instead of relying on the backfill for anything going forward. Same signature as
--    the current function, so CREATE OR REPLACE is sufficient (no DROP needed).
--
--    IMPORTANT: this must be built on top of the LATEST prior version of this function
--    (20260928100000_purchase_classification_and_procurements.sql, which added procurement_id/
--    purchase_category), not the earlier 20260924220000 credit-terms version. An earlier pass of
--    this migration mistakenly based this CREATE OR REPLACE on the older version, which would
--    have silently reverted procurement grouping and purchase-category tagging for every future
--    order -- caught via the full local regression sweep (purchase-classification.sql), not by
--    review alone. Fixed here; see that test file's "procurement was still created" check.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_marketplace_orders(
  _caller_id UUID,
  _pharmacy_id UUID,
  _items JSONB,
  _credit_wholesaler_ids UUID[] DEFAULT '{}'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business RECORD;
  v_role public.staff_role;
  v_requested_count INTEGER;
  v_product RECORD;
  v_wholesaler RECORD;
  v_order_count INTEGER := 0;
  v_order_id UUID;
  v_discount RECORD;
  v_subtotal NUMERIC;
  v_discount_total NUMERIC;
  v_has_discount BOOLEAN;
  v_terms RECORD;
  v_terms_found BOOLEAN;
  v_goods NUMERIC;
  v_fee NUMERIC;
  v_wholesaler_name TEXT;
  v_general_base NUMERIC;
  v_specific_count INTEGER;
  v_use_credit BOOLEAN;
  v_credit RECORD;
  v_credit_found BOOLEAN;
  v_credit_outstanding NUMERIC;
  v_due_date DATE;
  v_procurement_id UUID;
  v_order_category TEXT;
  v_procurement_category TEXT;
BEGIN
  IF _caller_id IS NULL OR _pharmacy_id IS NULL THEN RAISE EXCEPTION 'caller_id and pharmacy_id are required.'; END IF;
  IF _items IS NULL OR jsonb_typeof(_items) <> 'array' OR jsonb_array_length(_items) = 0 THEN RAISE EXCEPTION 'At least one item is required.'; END IF;

  SELECT id, owner_id, type, verification_status INTO v_business FROM public.businesses WHERE id = _pharmacy_id;
  IF NOT FOUND OR v_business.type <> 'pharmacy' THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_business.verification_status <> 'approved' THEN RAISE EXCEPTION 'Your pharmacy must be verified before placing orders.'; END IF;
  IF v_business.owner_id <> _caller_id THEN
    SELECT bs.role INTO v_role FROM public.business_staff bs
    WHERE bs.business_id = _pharmacy_id AND bs.user_id = _caller_id AND bs.status = 'active' LIMIT 1;
    IF v_role IS NULL OR v_role NOT IN ('owner', 'manager', 'cashier') THEN RAISE EXCEPTION 'You do not have permission to place orders for this pharmacy.'; END IF;
  END IF;

  CREATE TEMP TABLE tmp_requested_items (product_id UUID PRIMARY KEY, quantity INTEGER NOT NULL CHECK (quantity > 0), purchase_category TEXT) ON COMMIT DROP;
  INSERT INTO tmp_requested_items
  SELECT raw.product_id, SUM(raw.quantity)::INTEGER, (array_agg(raw.category))[1]
  FROM (SELECT (item ->> 'productId')::UUID product_id, (item ->> 'quantity')::INTEGER quantity, NULLIF(btrim(item ->> 'category'), '') category FROM jsonb_array_elements(_items) item) raw
  WHERE raw.product_id IS NOT NULL AND raw.quantity > 0 GROUP BY raw.product_id;
  SELECT COUNT(*) INTO v_requested_count FROM tmp_requested_items;
  IF v_requested_count = 0 THEN RAISE EXCEPTION 'Each item needs a valid productId and quantity.'; END IF;
  IF EXISTS (SELECT 1 FROM tmp_requested_items WHERE purchase_category IS NOT NULL AND purchase_category NOT IN ('nhis', 'cash_private', 'other')) THEN
    RAISE EXCEPTION 'Invalid purchase category.';
  END IF;
  IF (SELECT COUNT(*) FROM public.products p JOIN tmp_requested_items r ON r.product_id = p.id) <> v_requested_count THEN RAISE EXCEPTION 'One or more products could not be found.'; END IF;

  CREATE TEMP TABLE tmp_locked_products (
    product_id UUID PRIMARY KEY, wholesaler_id UUID NOT NULL, product_name TEXT NOT NULL,
    base_unit_price_ghs NUMERIC(10,2) NOT NULL, unit_price_ghs NUMERIC(10,2) NOT NULL,
    discount_amount_ghs NUMERIC(10,2) NOT NULL DEFAULT 0, quantity INTEGER NOT NULL CHECK (quantity > 0),
    specific_discount BOOLEAN NOT NULL DEFAULT FALSE, discount_source TEXT, purchase_category TEXT
  ) ON COMMIT DROP;

  FOR v_product IN
    SELECT p.id, p.name, p.price_ghs, p.stock, p.active, p.wholesaler_id, b.name wholesaler_name,
      b.verification_status wholesaler_status, r.quantity, r.purchase_category,
      COALESCE(wp.minimum_order_quantity, 1) AS min_qty
    FROM tmp_requested_items r JOIN public.products p ON p.id = r.product_id JOIN public.businesses b ON b.id = p.wholesaler_id
    LEFT JOIN public.wholesaler_products wp ON wp.id = p.id
    FOR UPDATE OF p
  LOOP
    IF NOT v_product.active THEN RAISE EXCEPTION '% is no longer active in the marketplace.', v_product.name; END IF;
    IF v_product.wholesaler_status <> 'approved' THEN RAISE EXCEPTION '% is no longer approved for marketplace orders.', v_product.wholesaler_name; END IF;
    IF v_product.stock <= 0 THEN RAISE EXCEPTION '% is currently out of stock.', v_product.name; END IF;
    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION 'Only % unit(s) of % are currently available.', v_product.stock, v_product.name; END IF;
    IF v_product.quantity < v_product.min_qty THEN RAISE EXCEPTION 'The minimum order for % is % unit(s).', v_product.name, v_product.min_qty; END IF;
    UPDATE public.products SET stock = stock - v_product.quantity WHERE id = v_product.id;
    INSERT INTO tmp_locked_products(product_id, wholesaler_id, product_name, base_unit_price_ghs, unit_price_ghs, quantity, purchase_category)
    VALUES (v_product.id, v_product.wholesaler_id, v_product.name, v_product.price_ghs, v_product.price_ghs, v_product.quantity, v_product.purchase_category);
  END LOOP;

  UPDATE tmp_locked_products t
  SET unit_price_ghs = round(t.base_unit_price_ghs * (1 - r.pct / 100), 2),
      discount_amount_ghs = round((t.base_unit_price_ghs - round(t.base_unit_price_ghs * (1 - r.pct / 100), 2)) * t.quantity, 2),
      specific_discount = TRUE,
      discount_source = 'product'
  FROM (
    SELECT DISTINCT ON (x.product_id) x.product_id, d.discount_percent AS pct
    FROM tmp_locked_products x
    JOIN public.product_discounts d
      ON d.product_id = x.product_id AND d.wholesaler_id = x.wholesaler_id AND x.quantity >= d.min_quantity
    WHERE d.pharmacy_id = _pharmacy_id AND d.active AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now())
    ORDER BY x.product_id, d.discount_percent DESC, d.min_quantity DESC, d.created_at DESC
  ) r
  WHERE r.product_id = t.product_id;

  INSERT INTO public.procurements(pharmacy_id) VALUES (_pharmacy_id) RETURNING id INTO v_procurement_id;

  FOR v_wholesaler IN SELECT wholesaler_id FROM tmp_locked_products GROUP BY wholesaler_id LOOP
    SELECT SUM(base_unit_price_ghs * quantity) INTO v_subtotal FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    SELECT d.* INTO v_discount FROM public.customer_discounts d
    WHERE d.wholesaler_id = v_wholesaler.wholesaler_id AND d.pharmacy_id = _pharmacy_id AND d.active
      AND d.starts_at <= now() AND (d.ends_at IS NULL OR d.ends_at > now()) AND v_subtotal >= d.minimum_order_value
    ORDER BY d.starts_at DESC, d.created_at DESC LIMIT 1;
    v_has_discount := FOUND;

    SELECT COALESCE(SUM(base_unit_price_ghs * quantity) FILTER (WHERE NOT specific_discount), 0), COUNT(*) FILTER (WHERE specific_discount)
      INTO v_general_base, v_specific_count
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;
    IF v_has_discount AND v_general_base = 0 THEN v_has_discount := FALSE; END IF;

    IF v_has_discount THEN
      IF v_discount.discount_type = 'percentage' THEN
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs * (1 - v_discount.discount_percent / 100), 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
      ELSE
        UPDATE tmp_locked_products SET unit_price_ghs = round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2),
          discount_amount_ghs = round((base_unit_price_ghs - round(base_unit_price_ghs - ((base_unit_price_ghs * quantity) / v_general_base * LEAST(v_discount.discount_amount, v_general_base)) / quantity, 2)) * quantity, 2),
          discount_source = 'customer'
        WHERE wholesaler_id = v_wholesaler.wholesaler_id AND NOT specific_discount;
      END IF;
    END IF;

    SELECT COALESCE(SUM(discount_amount_ghs), 0) INTO v_discount_total FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    v_goods := v_subtotal - v_discount_total;
    SELECT t.min_order_value_ghs, t.delivery_fee_ghs, t.free_delivery_threshold_ghs INTO v_terms
    FROM public.wholesaler_order_terms t WHERE t.wholesaler_id = v_wholesaler.wholesaler_id;
    v_terms_found := FOUND;
    v_fee := 0;
    IF v_terms_found THEN
      IF v_terms.min_order_value_ghs > 0 AND v_goods < v_terms.min_order_value_ghs THEN
        SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
        RAISE EXCEPTION '% requires a minimum order of GHS % (your order with them is GHS %).',
          v_wholesaler_name, to_char(v_terms.min_order_value_ghs, 'FM999,999,990.00'), to_char(v_goods, 'FM999,999,990.00');
      END IF;
      IF v_terms.delivery_fee_ghs > 0
         AND NOT (v_terms.free_delivery_threshold_ghs IS NOT NULL AND v_goods >= v_terms.free_delivery_threshold_ghs) THEN
        v_fee := v_terms.delivery_fee_ghs;
      END IF;
    END IF;
    v_use_credit := v_wholesaler.wholesaler_id = ANY (COALESCE(_credit_wholesaler_ids, '{}'));
    v_due_date := NULL;
    IF v_use_credit THEN
      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active INTO v_credit
      FROM public.wholesaler_credit_terms c
      WHERE c.wholesaler_id = v_wholesaler.wholesaler_id AND c.pharmacy_id = _pharmacy_id
      FOR UPDATE;
      v_credit_found := FOUND AND v_credit.active;
      SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_wholesaler.wholesaler_id;
      IF NOT v_credit_found THEN
        RAISE EXCEPTION '% has not approved credit for your pharmacy.', v_wholesaler_name;
      END IF;
      SELECT COALESCE(SUM(o.total_ghs), 0) INTO v_credit_outstanding
      FROM public.orders o
      WHERE o.wholesaler_id = v_wholesaler.wholesaler_id AND o.pharmacy_id = _pharmacy_id
        AND o.is_credit_order AND o.status <> 'cancelled' AND o.payment_status IN ('unpaid', 'failed');
      IF v_credit_outstanding + v_goods + v_fee > v_credit.credit_limit_ghs THEN
        RAISE EXCEPTION 'Using credit with % would exceed your approved limit of GHS % (you currently owe GHS %, this order is GHS %).',
          v_wholesaler_name, to_char(v_credit.credit_limit_ghs, 'FM999,999,990.00'), to_char(v_credit_outstanding, 'FM999,999,990.00'), to_char(v_goods + v_fee, 'FM999,999,990.00');
      END IF;
      v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;
    END IF;

    -- Order-level purchase category, derived from this wholesaler's own slice of items: all-NULL
    -- stays NULL (unclassified, e.g. every pre-existing caller of this function), all-the-same
    -- non-null value wins outright, anything else (including a mix of classified/unclassified) is 'mixed'.
    SELECT CASE
      WHEN bool_and(purchase_category IS NULL) THEN NULL
      WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
      ELSE 'mixed'
    END INTO v_order_category FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_type, discount_rate, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order, credit_due_date, procurement_id, purchase_category)
    VALUES (_pharmacy_id, v_wholesaler.wholesaler_id, v_subtotal,
      CASE WHEN v_has_discount THEN v_discount.discount_type WHEN v_specific_count > 0 THEN 'product' ELSE NULL END,
      CASE WHEN v_has_discount THEN COALESCE(v_discount.discount_percent, v_discount.discount_amount) ELSE NULL END,
      v_discount_total, v_fee, v_goods + v_fee, 'cod', v_use_credit, v_due_date, v_procurement_id, v_order_category) RETURNING id INTO v_order_id;
    INSERT INTO public.order_items(order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category)
    SELECT v_order_id, product_id, product_name, quantity, base_unit_price_ghs, unit_price_ghs, discount_amount_ghs, discount_source, purchase_category
    FROM tmp_locked_products WHERE wholesaler_id = v_wholesaler.wholesaler_id;

    IF v_use_credit THEN
      INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by)
      VALUES (v_wholesaler.wholesaler_id, _pharmacy_id, v_order_id, 'invoice', 'debit', v_goods + v_fee, _caller_id);
    END IF;

    v_order_count := v_order_count + 1;
  END LOOP;

  SELECT CASE
    WHEN bool_and(purchase_category IS NULL) THEN NULL
    WHEN COUNT(DISTINCT purchase_category) = 1 AND bool_and(purchase_category IS NOT NULL) THEN MIN(purchase_category)
    ELSE 'mixed'
  END INTO v_procurement_category FROM tmp_locked_products;
  UPDATE public.procurements SET purchase_category = v_procurement_category WHERE id = v_procurement_id;

  RETURN v_order_count;
END;
$$;
REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 10. Backfill: give every EXISTING credit order its 'invoice' entry (and its 'payment' entry if
--    already paid), so the ledger covers full history, not just orders placed from here on.
--    Idempotent (WHERE NOT EXISTS), safe to re-run.
-- ---------------------------------------------------------------------------
INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_at, note)
SELECT o.wholesaler_id, o.pharmacy_id, o.id, 'invoice', 'debit', o.total_ghs, o.created_at, 'Backfilled from order history.'
FROM public.orders o
WHERE o.is_credit_order
  AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries e WHERE e.order_id = o.id AND e.entry_type = 'invoice');

INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_at, note)
SELECT o.wholesaler_id, o.pharmacy_id, o.id, 'payment', 'credit', o.total_ghs,
  COALESCE(o.paid_at, o.payment_confirmed_at, o.created_at), 'Backfilled from order history.'
FROM public.orders o
WHERE o.is_credit_order AND o.payment_status = 'paid'
  AND NOT EXISTS (SELECT 1 FROM public.credit_ledger_entries e WHERE e.order_id = o.id AND e.entry_type IN ('payment', 'write_off'));
