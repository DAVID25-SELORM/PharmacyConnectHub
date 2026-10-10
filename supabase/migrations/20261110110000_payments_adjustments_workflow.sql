-- Online payments (Pay Now), phase P4b part 2: amendments on an order that was PAID ONLINE. One rule governs everything:
--
--     what the order costs now (its effective total)   versus   what has been paid for it and not been given back (paid, less refunds still alive)
--
-- If the order now costs LESS than that, the difference is refunded (a refund request, approved by an administrator unless automatic refunds are on; a delivery-problem
-- credit always waits for an administrator). If it costs MORE, the pharmacy must pay the difference (a top-up payment) before the order can be dispatched. The rule runs
-- in the database whenever an order's effective total changes, so it cannot be skipped by any screen. Nothing here changes a cash or credit order, or any order that
-- was not paid online. See docs/pay-now-paystack-plan.md (section 16).

-- ---------------------------------------------------------------------------
-- 1. The balance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_is_online(p_order_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT COALESCE((SELECT o.payment_method::TEXT = 'paystack' FROM public.orders o WHERE o.id = p_order_id), FALSE) $$;
REVOKE ALL ON FUNCTION public.order_is_online(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_is_online(UUID) TO authenticated, service_role;

-- Pesewas. required = what the order costs now; received = what the provider confirmed for it (payments that stay valid, top-ups included);
-- alive refunds = refunds of those payments that are not failed or cancelled; committed = received less alive refunds; balance = required less committed
-- (positive: the pharmacy owes more, negative: money is owed back).
CREATE OR REPLACE FUNCTION public.order_money(p_order_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object('required_minor', t.required, 'received_minor', t.received, 'refunded_minor', t.refunded, 'alive_refund_minor', t.alive,
                            'committed_minor', t.received - t.alive, 'balance_minor', t.required - (t.received - t.alive))
  FROM (
    SELECT round(COALESCE(o.effective_total_ghs, o.total_ghs) * 100)::BIGINT AS required,
           COALESCE((SELECT sum(a.verified_amount_minor) FROM public.order_payment_attempts a WHERE a.order_id = o.id AND a.status = 'succeeded' AND NOT a.refund_required), 0)::BIGINT AS received,
           COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id
                     WHERE a.order_id = o.id AND a.status = 'succeeded' AND NOT a.refund_required AND r.status = 'succeeded'), 0)::BIGINT AS refunded,
           COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id
                     WHERE a.order_id = o.id AND a.status = 'succeeded' AND NOT a.refund_required AND r.status NOT IN ('failed', 'cancelled')), 0)::BIGINT AS alive
    FROM public.orders o WHERE o.id = p_order_id
  ) t
$$;
REVOKE ALL ON FUNCTION public.order_money(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_money(UUID) TO service_role;

-- What the pharmacy still has to pay on a paid online order whose price rose (0 for every other order).
CREATE OR REPLACE FUNCTION public.order_topup_due_minor(p_order_id UUID)
RETURNS BIGINT
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN o.payment_method::TEXT = 'paystack' AND o.payment_status::TEXT = 'paid' AND o.status::TEXT <> 'cancelled'
              THEN GREATEST((public.order_money(o.id) ->> 'balance_minor')::BIGINT, 0) ELSE 0 END
  FROM public.orders o WHERE o.id = p_order_id
$$;
REVOKE ALL ON FUNCTION public.order_topup_due_minor(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_topup_due_minor(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Refunding what the order no longer costs
-- ---------------------------------------------------------------------------
-- Takes the amount from the order's payments, newest first (top-ups before the original payment), never more from one payment than it still has to give.
-- Returns what it could not place (0 when all of it was requested).
CREATE OR REPLACE FUNCTION public._request_order_refund(p_order_id UUID, p_amount_minor BIGINT, p_reason TEXT, p_source_key TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_left BIGINT := p_amount_minor;
  v_room BIGINT;
  v_take BIGINT;
BEGIN
  FOR v_a IN
    SELECT a.id, a.verified_amount_minor FROM public.order_payment_attempts a
    WHERE a.order_id = p_order_id AND a.status = 'succeeded' AND NOT a.refund_required AND a.verified_amount_minor IS NOT NULL
    ORDER BY a.paid_at DESC NULLS LAST, a.initiated_at DESC
  LOOP
    EXIT WHEN v_left <= 0;
    SELECT v_a.verified_amount_minor - COALESCE(sum(r.amount_minor), 0) INTO v_room FROM public.order_refunds r WHERE r.attempt_id = v_a.id AND r.status NOT IN ('failed', 'cancelled');
    v_take := LEAST(v_left, v_room);
    IF v_take > 0 THEN
      PERFORM public._request_refund(v_a.id, v_take, p_reason, p_source_key || ':' || v_a.id, NULL, NULL);
      v_left := v_left - v_take;
    END IF;
  END LOOP;
  RETURN v_left;
END;
$$;
REVOKE ALL ON FUNCTION public._request_order_refund(UUID, BIGINT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- Whenever the effective total of a paid online order changes, settle the difference.
CREATE OR REPLACE FUNCTION public.orders_effective_total_money()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_money JSONB := public.order_money(NEW.id);
  v_balance BIGINT := (v_money ->> 'balance_minor')::BIGINT;
  v_reason TEXT := CASE WHEN NULLIF(current_setting('drugxone.refund_reason', TRUE), '') = 'delivery_credit' THEN 'delivery_credit' ELSE 'amendment_reduction' END;
  v_unplaced BIGINT;
  v_r RECORD;
BEGIN
  -- Consumed: a later change in the same transaction is judged on its own.
  PERFORM set_config('drugxone.refund_reason', '', TRUE);
  -- A price that rises again first uses up refunds that have not been sent yet (cancelling them is better than refunding and charging again).
  IF v_balance > 0 THEN
    FOR v_r IN SELECT rf.id FROM public.order_refunds rf JOIN public.order_payment_attempts a ON a.id = rf.attempt_id
               WHERE a.order_id = NEW.id AND rf.status IN ('requested', 'approved') ORDER BY rf.created_at DESC
    LOOP
      EXIT WHEN v_balance <= 0;
      UPDATE public.order_refunds SET status = 'cancelled', note = 'Cancelled automatically: the order costs more again, so this refund is no longer due.'
      WHERE id = v_r.id AND status IN ('requested', 'approved');
      v_money := public.order_money(NEW.id);
      v_balance := (v_money ->> 'balance_minor')::BIGINT;
    END LOOP;
  END IF;
  IF v_balance < 0 THEN
    v_unplaced := public._request_order_refund(NEW.id, -v_balance, v_reason,
      'order:' || NEW.id || ':to:' || (v_money ->> 'required_minor') || ':from:' || (v_money ->> 'committed_minor'));
    INSERT INTO public.order_payment_log(order_id, kind, source, summary, details)
    VALUES (NEW.id, 'refund_for_change', 'system',
            format('The order now costs %s less than was paid; a refund of the difference was requested.', public._amendment_money((-v_balance - COALESCE(v_unplaced, 0)) / 100.0)),
            jsonb_build_object('reason', v_reason, 'balance_minor', v_balance, 'unplaced_minor', v_unplaced));
    IF v_unplaced > 0 THEN
      PERFORM public._raise_payment_alert('refund_required', 'critical', NEW.id, NULL, 'unplaced_refund:' || NEW.id,
        format('Order %s now costs %s less than was paid, but only part of that could be placed on a refund. A person must look at it.', NEW.order_number, public._amendment_money(-v_balance / 100.0)),
        jsonb_build_object('balance_minor', v_balance, 'unplaced_minor', v_unplaced));
    END IF;
  ELSIF v_balance > 0 THEN
    INSERT INTO public.order_payment_log(order_id, kind, source, summary, details)
    VALUES (NEW.id, 'topup_required', 'system',
            format('The order now costs %s more than was paid; the pharmacy must pay the difference before it is dispatched.', public._amendment_money(v_balance / 100.0)),
            jsonb_build_object('balance_minor', v_balance));
    PERFORM public.notify_business(NEW.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Payment needed for a price change',
      format('Order %s now costs %s more. Pay the difference online so the supplier can dispatch it.', NEW.order_number, public._amendment_money(v_balance / 100.0)),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', NEW.id));
    PERFORM public.notify_business(NEW.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Waiting for payment of a price change',
      format('Order %s: the pharmacy must pay %s more online before it can be dispatched.', NEW.order_number, public._amendment_money(v_balance / 100.0)),
      '/wholesaler?tab=orders', jsonb_build_object('order_id', NEW.id));
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_orders_effective_total_money ON public.orders;
CREATE TRIGGER trg_orders_effective_total_money
  AFTER UPDATE OF effective_total_ghs ON public.orders
  FOR EACH ROW WHEN (NEW.effective_total_ghs IS DISTINCT FROM OLD.effective_total_ghs AND NEW.payment_method::TEXT = 'paystack' AND NEW.payment_status::TEXT = 'paid')
  EXECUTE FUNCTION public.orders_effective_total_money();

-- ---------------------------------------------------------------------------
-- 3. Not dispatched until the extra payment is made; no back-orders on an online order (yet)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_dispatch_topup_due()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.order_topup_due_minor(NEW.id) > 0 THEN
    RAISE EXCEPTION 'A price change on this order must be paid online before it can be dispatched.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_block_dispatch_topup_due ON public.orders;
CREATE TRIGGER trg_block_dispatch_topup_due
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.status::TEXT IN ('dispatched', 'delivered') AND NEW.payment_method::TEXT = 'paystack')
  EXECUTE FUNCTION public.block_dispatch_topup_due();

-- Back-orders keep their own payment handling (a cash order is collected portion by portion): that does not fit an order paid in advance, so for now the pharmacy
-- can accept a shortage and have the rest cancelled (with a refund), or reject it.
CREATE OR REPLACE FUNCTION public.refuse_backorder_on_online_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.order_is_online(NEW.order_id) THEN
    RAISE EXCEPTION 'Back-ordering the rest is not available for an order paid online yet. Accept and cancel the rest (the difference is refunded), or reject the change.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_refuse_backorder_on_online_order ON public.order_amendments;
CREATE TRIGGER trg_refuse_backorder_on_online_order
  BEFORE UPDATE ON public.order_amendments
  FOR EACH ROW WHEN (NEW.response_choice = 'accept_backorder' AND OLD.response_choice IS DISTINCT FROM 'accept_backorder')
  EXECUTE FUNCTION public.refuse_backorder_on_online_order();

-- ---------------------------------------------------------------------------
-- 4. Starting a top-up payment (the server)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.begin_order_topup(p_caller_id UUID, p_order_id UUID, p_provider TEXT, p_mode TEXT, p_reference TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_settings RECORD;
  v_due BIGINT;
  v_open RECORD;
  v_attempt_id UUID;
  v_recent INTEGER;
  v_email TEXT;
BEGIN
  IF p_caller_id IS NULL OR p_order_id IS NULL THEN RAISE EXCEPTION 'A signed-in user and an order are required.'; END IF;
  IF p_mode NOT IN ('test', 'live') THEN RAISE EXCEPTION 'Unknown payment mode.'; END IF;
  SELECT s.online_enabled, s.mode INTO v_settings FROM public.payments_settings s WHERE s.id;
  IF NOT COALESCE(v_settings.online_enabled, FALSE) THEN RAISE EXCEPTION 'Online payment is not available yet.'; END IF;
  IF v_settings.mode <> p_mode THEN RAISE EXCEPTION 'Online payment is not set up for this mode.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.payment_status::TEXT AS payment_status, o.payment_method::TEXT AS payment_method
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public._payments_user_can_pay_for(p_caller_id, v_order.pharmacy_id) THEN RAISE EXCEPTION 'You do not have permission to pay for this order.'; END IF;
  IF v_order.payment_method <> 'paystack' THEN RAISE EXCEPTION 'This order was not placed for online payment.'; END IF;
  IF v_order.status = 'cancelled' THEN RAISE EXCEPTION 'This order was cancelled and can no longer be paid.'; END IF;
  IF v_order.payment_status <> 'paid' THEN RAISE EXCEPTION 'This order is not waiting for an extra payment.'; END IF;
  v_due := public.order_topup_due_minor(p_order_id);
  IF v_due <= 0 THEN RAISE EXCEPTION 'There is nothing more to pay on this order.'; END IF;

  SELECT a.id, a.reference, a.amount_ghs, a.amount_minor, a.authorization_url INTO v_open
  FROM public.order_payment_attempts a
  WHERE a.order_id = p_order_id AND a.purpose = 'top_up' AND a.provider = p_provider AND a.mode = p_mode AND a.status IN ('initiated', 'pending')
    AND a.authorization_url IS NOT NULL AND a.amount_minor = v_due AND a.initiated_at > now() - interval '25 minutes'
  ORDER BY a.initiated_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    RETURN jsonb_build_object('reused', TRUE, 'attempt_id', v_open.id, 'reference', v_open.reference, 'amount_ghs', v_open.amount_ghs,
                              'amount_minor', v_open.amount_minor, 'authorization_url', v_open.authorization_url, 'order_number', v_order.order_number);
  END IF;
  SELECT count(*) INTO v_recent FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.purpose = 'top_up' AND a.initiated_at > now() - interval '1 hour';
  IF v_recent >= 6 THEN RAISE EXCEPTION 'Too many payment attempts for this order. Please wait a little before trying again.'; END IF;
  UPDATE public.order_payment_attempts SET status = 'expired' WHERE order_id = p_order_id AND purpose = 'top_up' AND status IN ('initiated', 'pending');
  SELECT email INTO v_email FROM auth.users WHERE id = p_caller_id;
  IF v_email IS NULL THEN RAISE EXCEPTION 'Your account has no email address, which online payment needs.'; END IF;
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, initiated_by, initiated_at, purpose)
  VALUES (p_order_id, p_provider, p_mode, p_reference, v_due / 100.0, v_due, p_caller_id, clock_timestamp(), 'top_up') RETURNING id INTO v_attempt_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (p_order_id, v_attempt_id, 'attempt_started', 'system', format('An extra payment of %s was started.', public._amendment_money(v_due / 100.0)),
          jsonb_build_object('reference', p_reference, 'mode', p_mode, 'purpose', 'top_up'));
  RETURN jsonb_build_object('reused', FALSE, 'attempt_id', v_attempt_id, 'reference', p_reference, 'amount_ghs', v_due / 100.0, 'amount_minor', v_due,
                            'email', v_email, 'order_number', v_order.order_number);
END;
$$;
REVOKE ALL ON FUNCTION public.begin_order_topup(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_order_topup(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. A verified top-up (called by apply_payment_result for a top-up attempt; the order and the attempt are already locked)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._apply_topup_success(
  p_attempt_id UUID, p_order_id UUID, p_amount_minor BIGINT, p_currency TEXT, p_transaction_id TEXT, p_channel TEXT, p_fee_minor BIGINT, p_source TEXT, p_event_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_order RECORD;
  v_flag TEXT;
  v_due BIGINT;
  v_name TEXT;
BEGIN
  SELECT * INTO v_a FROM public.order_payment_attempts WHERE id = p_attempt_id;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.payment_status::TEXT AS payment_status, o.payment_method::TEXT AS payment_method
  INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  v_due := public.order_topup_due_minor(p_order_id);

  IF p_currency IS DISTINCT FROM v_a.currency THEN v_flag := 'currency_mismatch';
  ELSIF p_amount_minor IS DISTINCT FROM v_a.amount_minor THEN v_flag := 'amount_mismatch';
  ELSIF v_order.payment_method <> 'paystack' THEN v_flag := 'order_not_online';
  ELSIF v_order.status = 'cancelled' THEN
    UPDATE public.order_payment_attempts SET status = 'succeeded', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
      fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), paid_at = now(), refund_required = TRUE, flag_reason = 'order_cancelled' WHERE id = p_attempt_id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (p_order_id, p_attempt_id, p_event_id, 'late_payment', p_source, 'An extra payment arrived for an order that was already cancelled. It must be refunded.', jsonb_build_object('amount_minor', p_amount_minor));
    RETURN jsonb_build_object('outcome', 'late', 'attempt_id', p_attempt_id, 'order_id', p_order_id, 'order_paid', FALSE, 'refund_required', TRUE);
  ELSIF v_order.payment_status <> 'paid' THEN v_flag := 'order_not_payable';
  ELSIF v_due <= 0 THEN v_flag := 'already_paid';
  ELSIF v_due <> v_a.amount_minor THEN v_flag := 'order_total_changed';
  END IF;

  IF v_flag IS NOT NULL THEN
    UPDATE public.order_payment_attempts SET status = 'flagged', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
      fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), refund_required = TRUE, flag_reason = v_flag WHERE id = p_attempt_id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (p_order_id, p_attempt_id, p_event_id, 'payment_flagged', p_source,
            format('An extra payment was NOT applied: %s. It will be refunded unless a person decides otherwise.', replace(v_flag, '_', ' ')),
            jsonb_build_object('flag', v_flag, 'asked_minor', v_a.amount_minor, 'paid_minor', p_amount_minor, 'due_minor', v_due));
    RETURN jsonb_build_object('outcome', 'flagged', 'flag', v_flag, 'attempt_id', p_attempt_id, 'order_id', p_order_id, 'order_paid', FALSE, 'refund_required', TRUE);
  END IF;

  UPDATE public.order_payment_attempts SET status = 'succeeded', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
    fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), paid_at = now(), failure_reason = NULL WHERE id = p_attempt_id;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
  VALUES (p_order_id, p_attempt_id, p_event_id, 'topup_applied', p_source, format('An extra payment of %s was verified and applied.', public._amendment_money(v_a.amount_ghs)),
          jsonb_build_object('amount_minor', p_amount_minor, 'channel', p_channel, 'fee_minor', p_fee_minor));
  PERFORM public.record_order_event(p_order_id, 'payment_received', 'system', format('An extra payment of %s for a price change was received and verified.', public._amendment_money(v_a.amount_ghs)),
    jsonb_build_object('attempt_id', p_attempt_id, 'channel', p_channel, 'purpose', 'top_up'), NULL, NULL);
  PERFORM public.write_audit_log('Online top-up payment received', v_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('attempt_id', p_attempt_id, 'amount_ghs', v_a.amount_ghs, 'channel', p_channel, 'source', p_source), _business_id => v_order.pharmacy_id);
  PERFORM public.notify_business(v_order.wholesaler_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Price change paid',
    format('Order %s: the pharmacy paid the extra %s. It can be dispatched.', v_order.order_number, public._amendment_money(v_a.amount_ghs)),
    '/wholesaler?tab=orders', jsonb_build_object('order_id', p_order_id));
  RETURN jsonb_build_object('outcome', 'applied', 'attempt_id', p_attempt_id, 'order_id', p_order_id, 'order_paid', TRUE);
END;
$$;
REVOKE ALL ON FUNCTION public._apply_topup_success(UUID, UUID, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, UUID) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. The return page's check (replacing the P3 version): an order with an extra payment due is not "paid" yet
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.payment_attempts_to_check(p_caller_id UUID, p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_ids UUID[];
  v_all INTEGER;
BEGIN
  SELECT o.pharmacy_id, o.payment_status::TEXT AS payment_status INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT public._payments_user_can_pay_for(p_caller_id, v_order.pharmacy_id) THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  SELECT count(*) INTO v_all FROM (SELECT 1 FROM public.order_payment_attempts a
    WHERE a.order_id = p_order_id AND a.status IN ('initiated', 'pending', 'expired', 'abandoned', 'failed') AND a.initiated_at > now() - interval '24 hours' LIMIT 3) x;
  SELECT array_agg(t.id) INTO v_ids FROM (
    SELECT a.id FROM public.order_payment_attempts a
    WHERE a.order_id = p_order_id AND a.status IN ('initiated', 'pending', 'expired', 'abandoned', 'failed') AND a.initiated_at > now() - interval '24 hours'
      AND (a.check_requested_at IS NULL OR a.check_requested_at < now() - interval '3 seconds')
    ORDER BY a.initiated_at DESC LIMIT 3) t;
  IF v_ids IS NOT NULL THEN
    UPDATE public.order_payment_attempts SET check_requested_at = now() WHERE id = ANY (v_ids);
  END IF;
  RETURN jsonb_build_object('payment_status', v_order.payment_status, 'topup_due', public.order_topup_due_minor(p_order_id) > 0,
    'throttled', v_ids IS NULL AND v_all > 0, 'attempts', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('attempt_id', a.id, 'provider', a.provider, 'mode', a.mode, 'reference', a.reference) ORDER BY a.initiated_at DESC)
    FROM public.order_payment_attempts a WHERE a.id = ANY (COALESCE(v_ids, '{}'::UUID[]))), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.payment_attempts_to_check(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_attempts_to_check(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 7. A balance nobody has refunded
-- ---------------------------------------------------------------------------
-- A refund for a price or supply change may have been cancelled or failed for good, leaving the order costing less than was paid with no refund on the way.
-- This raises an alert for each such order; the administrator can then ask for the difference to be refunded (below).
CREATE OR REPLACE FUNCTION public.flag_unrefunded_balances()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_o RECORD;
  v_n INTEGER := 0;
BEGIN
  FOR v_o IN SELECT o.id, o.order_number, (public.order_money(o.id) ->> 'balance_minor')::BIGINT AS balance
             FROM public.orders o WHERE o.payment_method::TEXT = 'paystack' AND o.payment_status::TEXT = 'paid' AND o.status::TEXT <> 'cancelled' AND o.effective_total_ghs IS NOT NULL
  LOOP
    IF v_o.balance < 0 THEN
      PERFORM public._raise_payment_alert('refund_required', 'warning', v_o.id, NULL, 'unrefunded_balance:' || v_o.id,
        format('Order %s costs %s less than was paid and no refund is on the way for the difference.', v_o.order_number, public._amendment_money(-v_o.balance / 100.0)),
        jsonb_build_object('balance_minor', v_o.balance));
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.flag_unrefunded_balances() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.flag_unrefunded_balances() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_request_balance_refund(p_admin_id UUID, p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_money JSONB;
  v_balance BIGINT;
  v_order RECORD;
  v_unplaced BIGINT;
  v_name TEXT;
BEGIN
  IF NOT public.payment_user_is_admin(p_admin_id) THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.payment_method::TEXT AS payment_method, o.payment_status::TEXT AS payment_status
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_order.payment_method <> 'paystack' OR v_order.payment_status <> 'paid' THEN RAISE EXCEPTION 'Only an order that was paid online can have a refund requested here.'; END IF;
  v_money := public.order_money(p_order_id);
  v_balance := (v_money ->> 'balance_minor')::BIGINT;
  IF v_balance >= 0 THEN RAISE EXCEPTION 'This order does not cost less than was paid: there is nothing to refund.'; END IF;
  -- A fresh source each time: this is a person's decision, taken after the earlier request was cancelled or failed for good.
  v_unplaced := public._request_order_refund(p_order_id, -v_balance, 'manual', 'admin:' || p_order_id || ':' || gen_random_uuid());
  SELECT name INTO v_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  PERFORM public.write_audit_log('Refund requested for the difference', v_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('amount_minor', -v_balance, 'unplaced_minor', v_unplaced, 'admin_id', p_admin_id), _business_id => v_order.pharmacy_id);
  RETURN jsonb_build_object('requested_minor', -v_balance - v_unplaced, 'unplaced_minor', v_unplaced);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_request_balance_refund(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_request_balance_refund(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 8. What the screens see (replacing the P4a versions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_payment_summary(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_side TEXT;
  v_last RECORD;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.payment_status::TEXT AS payment_status,
         o.payment_method::TEXT AS payment_method, o.total_ghs, o.effective_total_ghs, o.paid_at
  INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF public.can_act_for_business(v_order.pharmacy_id, 'read') THEN v_side := 'pharmacy';
  ELSIF public.can_act_for_business(v_order.wholesaler_id, 'read') THEN v_side := 'wholesaler';
  ELSIF public.has_role(auth.uid(), 'admin') THEN v_side := 'admin';
  ELSE RAISE EXCEPTION 'Order not found.';
  END IF;
  IF v_order.payment_method <> 'paystack' THEN
    RETURN jsonb_build_object('online', FALSE, 'payment_status', v_order.payment_status, 'side', v_side);
  END IF;
  SELECT a.status, a.initiated_at, a.failure_reason, a.channel INTO v_last
  FROM public.order_payment_attempts a WHERE a.order_id = p_order_id ORDER BY a.initiated_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'online', TRUE, 'side', v_side, 'order_number', v_order.order_number, 'order_status', v_order.status, 'payment_status', v_order.payment_status,
    'amount_ghs', COALESCE(v_order.effective_total_ghs, v_order.total_ghs), 'paid_at', v_order.paid_at,
    'awaiting_payment', v_order.payment_status = 'unpaid' AND v_order.status <> 'cancelled',
    'topup_due_ghs', public.order_topup_due_minor(p_order_id) / 100.0,
    'last_attempt', CASE WHEN v_last.status IS NULL THEN NULL ELSE jsonb_build_object(
      'status', v_last.status, 'at', v_last.initiated_at, 'reason', CASE WHEN v_side = 'pharmacy' THEN v_last.failure_reason ELSE NULL END,
      'channel', v_last.channel) END,
    'paid_ghs', COALESCE((SELECT sum(COALESCE(a.verified_amount_minor, 0)) FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.status = 'succeeded') / 100.0, 0),
    'refunded_ghs', COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.order_id = p_order_id AND r.status = 'succeeded') / 100.0, 0),
    'refund_required', EXISTS (SELECT 1 FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.refund_required
      AND COALESCE(a.verified_amount_minor, 0) > COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded'), 0))
      OR (v_order.payment_status = 'paid' AND (public.order_money(p_order_id) ->> 'balance_minor')::BIGINT < 0),
    'refunds', COALESCE((SELECT jsonb_agg(jsonb_build_object('amount_ghs', x.amount_ghs, 'status', x.status, 'reason', x.reason, 'created_at', x.created_at, 'completed_at', x.completed_at)
                                          ORDER BY x.created_at)
                         FROM public.order_refunds x WHERE x.order_id = p_order_id AND x.status <> 'cancelled'), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.order_payment_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_payment_summary(UUID) TO authenticated, service_role;

-- The admin overview (replacing the P4a version): marks the alerts that are "an order costs less than was paid and no refund is on the way" (so the screen can offer the refund), and shows each attempt's purpose.
CREATE OR REPLACE FUNCTION public.admin_payment_overview()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view payments.'; END IF;
  RETURN jsonb_build_object(
    'settings', (SELECT jsonb_build_object('enabled', s.online_enabled, 'mode', s.mode, 'auto_refunds', s.auto_refunds) FROM public.payments_settings s WHERE s.id),
    'counts', jsonb_build_object(
      'open_alerts', (SELECT count(*) FROM public.payment_alerts WHERE status = 'open'),
      'open_critical', (SELECT count(*) FROM public.payment_alerts WHERE status = 'open' AND severity = 'critical'),
      'refunds_required', (SELECT count(*) FROM public.order_payment_attempts a WHERE a.refund_required
         AND COALESCE(a.verified_amount_minor, 0) > COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded'), 0)),
      'refunds_open', (SELECT count(*) FROM public.order_refunds WHERE status IN ('requested', 'approved', 'submitting', 'processing', 'unknown', 'failed')),
      'awaiting_payment', (SELECT count(*) FROM public.orders WHERE payment_method::TEXT = 'paystack' AND payment_status::TEXT = 'unpaid' AND status::TEXT = 'pending'),
      'paid_24h', (SELECT count(*) FROM public.order_payment_attempts WHERE status = 'succeeded' AND paid_at > now() - interval '24 hours'),
      'paid_24h_ghs', (SELECT COALESCE(sum(amount_ghs), 0) FROM public.order_payment_attempts WHERE status = 'succeeded' AND NOT refund_required AND paid_at > now() - interval '24 hours')),
    'alerts', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.status DESC, x.created_at DESC) FROM (
      SELECT al.id, al.kind, al.severity, al.order_id, o.order_number, al.summary, al.status, al.occurrences, al.created_at, al.last_seen_at,
             al.resolved_at, al.resolution_note,
             (al.dedupe_key LIKE 'unrefunded_balance:%') AS balance_refund_missing
      FROM public.payment_alerts al LEFT JOIN public.orders o ON o.id = al.order_id
      WHERE al.status = 'open' OR al.resolved_at > now() - interval '14 days'
      ORDER BY (al.status = 'open') DESC, al.created_at DESC LIMIT 100) x), '[]'::JSONB),
    'refunds', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (
      SELECT r.id, r.order_id, o.order_number, ph.name AS pharmacy, r.amount_ghs, r.reason, r.status, r.method, r.failure_reason, r.note,
             r.created_at, r.approved_at, r.submitted_at, r.completed_at, a.reference
      FROM public.order_refunds r JOIN public.orders o ON o.id = r.order_id JOIN public.order_payment_attempts a ON a.id = r.attempt_id
      LEFT JOIN public.businesses ph ON ph.id = o.pharmacy_id
      WHERE r.status IN ('requested', 'approved', 'submitting', 'processing', 'unknown', 'failed') OR r.created_at > now() - interval '30 days'
      ORDER BY (r.status IN ('requested', 'approved', 'submitting', 'processing', 'unknown', 'failed')) DESC, r.created_at DESC LIMIT 100) x), '[]'::JSONB),
    'attempts', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.initiated_at DESC) FROM (
      SELECT a.id, a.order_id, o.order_number, ph.name AS pharmacy, wh.name AS wholesaler, a.reference, a.mode, a.amount_ghs, a.status, a.flag_reason,
             a.refund_required, a.purpose, a.channel, a.initiated_at, a.paid_at, a.last_checked_at, a.failure_reason
      FROM public.order_payment_attempts a JOIN public.orders o ON o.id = a.order_id
      LEFT JOIN public.businesses ph ON ph.id = o.pharmacy_id LEFT JOIN public.businesses wh ON wh.id = o.wholesaler_id
      ORDER BY a.initiated_at DESC LIMIT 60) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_payment_overview() TO authenticated;
