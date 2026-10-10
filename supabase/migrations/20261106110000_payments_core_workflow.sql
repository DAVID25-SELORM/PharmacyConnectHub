-- Online payments (Pay Now), phase P1: the functions of the provider-neutral core. All are callable by the service role only (the
-- server endpoints); nothing here is reachable by a signed-in user. See docs/pay-now-paystack-plan.md (section 4.3).
--
--   record_payment_provider_event()   store a notification BEFORE anything else is done with it; recognises a duplicate.
--   finish_payment_provider_event()   record what was done with it.
--   apply_payment_result()            the only way an attempt, and an order, becomes paid. The caller has ALREADY verified the result
--                                     with the provider (a webhook is only ever a hint to go and verify). It is idempotent and takes
--                                     the order lock first, then the attempt.
--
-- apply_payment_result decides, in this order, and never marks an order paid unless every check holds:
--   unknown reference                      -> nothing to do
--   test/live mode differs from the attempt -> refused, nothing changes
--   already succeeded or flagged           -> duplicate, nothing changes
--   provider says failed / abandoned / pending -> the attempt records it; the order is untouched
--   provider says success:
--     wrong currency or wrong amount       -> flagged (not paid): a person must look at it
--     the order is not an online order     -> flagged
--     the order's total changed since the attempt was made -> flagged, refund required
--     the order was cancelled (or expired)  -> the money is recorded as received, refund required (a late payment)
--     the order is already paid             -> flagged, refund required (a double payment)
--     otherwise                            -> attempt succeeded, order paid, timeline, audit, notifications.

-- ---------------------------------------------------------------------------
-- 1. Notifications
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_payment_provider_event(
  p_provider TEXT, p_dedupe_key TEXT, p_event_type TEXT, p_reference TEXT, p_mode TEXT, p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_row RECORD;
BEGIN
  INSERT INTO public.payment_provider_events(provider, dedupe_key, event_type, reference, mode, payload)
  VALUES (p_provider, p_dedupe_key, p_event_type, NULLIF(btrim(COALESCE(p_reference, '')), ''), p_mode, p_payload)
  ON CONFLICT (provider, dedupe_key) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    RETURN jsonb_build_object('event_id', v_id, 'duplicate', FALSE, 'already_processed', FALSE);
  END IF;
  SELECT e.id, e.processed_at, e.outcome INTO v_row FROM public.payment_provider_events e WHERE e.provider = p_provider AND e.dedupe_key = p_dedupe_key;
  RETURN jsonb_build_object('event_id', v_row.id, 'duplicate', TRUE, 'already_processed', v_row.processed_at IS NOT NULL AND COALESCE(v_row.outcome, '') <> 'error',
                            'outcome', v_row.outcome);
END;
$$;
REVOKE ALL ON FUNCTION public.record_payment_provider_event(TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_payment_provider_event(TEXT, TEXT, TEXT, TEXT, TEXT, JSONB) TO service_role;

CREATE OR REPLACE FUNCTION public.finish_payment_provider_event(p_event_id UUID, p_outcome TEXT, p_error TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.payment_provider_events SET processed_at = now(), outcome = left(p_outcome, 60), error = left(p_error, 500) WHERE id = p_event_id
$$;
REVOKE ALL ON FUNCTION public.finish_payment_provider_event(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_payment_provider_event(UUID, TEXT, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. The one function that records a verified result
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_payment_result(
  p_provider TEXT,
  p_mode TEXT,
  p_reference TEXT,
  p_provider_status TEXT,
  p_amount_minor BIGINT,
  p_currency TEXT,
  p_transaction_id TEXT DEFAULT NULL,
  p_channel TEXT DEFAULT NULL,
  p_fee_minor BIGINT DEFAULT NULL,
  p_source TEXT DEFAULT 'verify',
  p_event_id UUID DEFAULT NULL,
  p_failure_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_order RECORD;
  v_a RECORD;
  v_flag TEXT;
  v_refund BOOLEAN := FALSE;
  v_name TEXT;
  v_source TEXT := CASE WHEN p_source IN ('webhook', 'verify', 'reconcile', 'system') THEN p_source ELSE 'system' END;
BEGIN
  SELECT a.order_id INTO v_order_id FROM public.order_payment_attempts a WHERE a.provider = p_provider AND a.reference = p_reference;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome', 'unknown_reference');
  END IF;

  -- Lock order: the order first, then the attempt (the same order every payment function uses).
  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.payment_status::TEXT AS payment_status,
         o.payment_method::TEXT AS payment_method, o.total_ghs, o.effective_total_ghs
  INTO v_order FROM public.orders o WHERE o.id = v_order_id FOR UPDATE;
  SELECT * INTO v_a FROM public.order_payment_attempts a WHERE a.provider = p_provider AND a.reference = p_reference FOR UPDATE;

  IF v_a.mode <> p_mode THEN
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (v_order_id, v_a.id, p_event_id, 'mode_mismatch', v_source,
            format('A %s-mode result arrived for a %s-mode attempt and was refused.', p_mode, v_a.mode), jsonb_build_object('reference', p_reference));
    RETURN jsonb_build_object('outcome', 'mode_mismatch', 'attempt_id', v_a.id, 'order_id', v_order_id);
  END IF;

  -- Something already settled: a repeat changes nothing.
  IF v_a.status IN ('succeeded', 'flagged') THEN
    RETURN jsonb_build_object('outcome', 'duplicate', 'attempt_id', v_a.id, 'order_id', v_order_id, 'order_paid', v_order.payment_status = 'paid');
  END IF;

  -- ----- not a success ---------------------------------------------------------------------------------------------------
  IF p_provider_status IN ('failed', 'abandoned') THEN
    UPDATE public.order_payment_attempts SET status = p_provider_status, provider_status = p_provider_status, verified_at = now(),
      failure_reason = COALESCE(left(NULLIF(btrim(p_failure_reason), ''), 300), failure_reason) WHERE id = v_a.id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (v_order_id, v_a.id, p_event_id, 'payment_' || p_provider_status, v_source,
            format('The provider reports the payment attempt as %s.', p_provider_status), jsonb_build_object('reason', left(p_failure_reason, 300)));
    RETURN jsonb_build_object('outcome', p_provider_status, 'attempt_id', v_a.id, 'order_id', v_order_id);
  END IF;
  IF p_provider_status = 'pending' THEN
    IF v_a.status = 'initiated' THEN
      UPDATE public.order_payment_attempts SET status = 'pending', provider_status = 'pending' WHERE id = v_a.id;
    END IF;
    RETURN jsonb_build_object('outcome', 'pending', 'attempt_id', v_a.id, 'order_id', v_order_id);
  END IF;
  IF p_provider_status IS DISTINCT FROM 'success' THEN
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (v_order_id, v_a.id, p_event_id, 'status_ignored', v_source, 'The provider reported a status this system does not act on.',
            jsonb_build_object('provider_status', left(COALESCE(p_provider_status, ''), 60)));
    RETURN jsonb_build_object('outcome', 'ignored', 'attempt_id', v_a.id, 'order_id', v_order_id);
  END IF;

  -- ----- the provider says success: every check must hold -------------------------------------------------------------------
  IF p_currency IS DISTINCT FROM v_a.currency THEN
    v_flag := 'currency_mismatch';
  ELSIF p_amount_minor IS DISTINCT FROM v_a.amount_minor THEN
    v_flag := 'amount_mismatch';
  ELSIF v_order.payment_method <> 'paystack' THEN
    v_flag := 'order_not_online';
  ELSIF v_a.amount_ghs <> COALESCE(v_order.effective_total_ghs, v_order.total_ghs) THEN
    v_flag := 'order_total_changed'; v_refund := TRUE;
  ELSIF v_order.status = 'cancelled' THEN
    -- Money arrived for an order that no longer exists in practice: keep the facts, require a refund, never revive the order.
    UPDATE public.order_payment_attempts SET status = 'succeeded', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
      fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), paid_at = now(), refund_required = TRUE,
      flag_reason = 'order_cancelled' WHERE id = v_a.id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (v_order_id, v_a.id, p_event_id, 'late_payment', v_source,
            'A verified payment arrived for an order that was already cancelled. It must be refunded.', jsonb_build_object('amount_minor', p_amount_minor));
    RETURN jsonb_build_object('outcome', 'late', 'attempt_id', v_a.id, 'order_id', v_order_id, 'order_paid', FALSE, 'refund_required', TRUE);
  ELSIF v_order.payment_status = 'paid' OR EXISTS (SELECT 1 FROM public.order_payment_attempts x WHERE x.order_id = v_order_id AND x.status = 'succeeded' AND x.refund_required = FALSE) THEN
    v_flag := 'already_paid'; v_refund := TRUE;
  ELSIF v_order.payment_status <> 'unpaid' THEN
    v_flag := 'order_not_payable';
  END IF;

  IF v_flag IS NOT NULL THEN
    UPDATE public.order_payment_attempts SET status = 'flagged', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
      fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), refund_required = v_refund, flag_reason = v_flag WHERE id = v_a.id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
    VALUES (v_order_id, v_a.id, p_event_id, 'payment_flagged', v_source,
            format('A verified payment was NOT applied: %s. A person must look at it.', replace(v_flag, '_', ' ')),
            jsonb_build_object('flag', v_flag, 'asked_minor', v_a.amount_minor, 'paid_minor', p_amount_minor, 'currency', p_currency, 'refund_required', v_refund));
    RETURN jsonb_build_object('outcome', 'flagged', 'flag', v_flag, 'attempt_id', v_a.id, 'order_id', v_order_id, 'order_paid', v_order.payment_status = 'paid',
                              'refund_required', v_refund);
  END IF;

  -- ----- apply ------------------------------------------------------------------------------------------------------------
  UPDATE public.order_payment_attempts SET status = 'succeeded', provider_status = 'success', verified_amount_minor = p_amount_minor, channel = p_channel,
    fee_minor = p_fee_minor, provider_transaction_id = p_transaction_id, verified_at = now(), paid_at = now(), failure_reason = NULL WHERE id = v_a.id;
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET payment_status = 'paid', paid_at = now(), payment_confirmed_at = now(), paystack_reference = v_a.reference WHERE id = v_order_id;

  SELECT name INTO v_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, provider_event_id, kind, source, summary, details)
  VALUES (v_order_id, v_a.id, p_event_id, 'payment_applied', v_source, format('Online payment of %s verified and applied.', public._amendment_money(v_a.amount_ghs)),
          jsonb_build_object('amount_minor', p_amount_minor, 'channel', p_channel, 'fee_minor', p_fee_minor));
  PERFORM public.record_order_event(v_order_id, 'payment_received', 'system',
    format('Online payment of %s was received and verified.', public._amendment_money(v_a.amount_ghs)),
    jsonb_build_object('attempt_id', v_a.id, 'channel', p_channel), NULL, NULL);
  PERFORM public.write_audit_log('Online payment received', v_name, 'order', v_order_id, v_order.order_number,
    jsonb_build_object('attempt_id', v_a.id, 'amount_ghs', v_a.amount_ghs, 'channel', p_channel, 'source', v_source), _business_id => v_order.pharmacy_id);
  RETURN jsonb_build_object('outcome', 'applied', 'attempt_id', v_a.id, 'order_id', v_order_id, 'order_paid', TRUE);
END;
$$;
REVOKE ALL ON FUNCTION public.apply_payment_result(TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_payment_result(TEXT, TEXT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT, BIGINT, TEXT, UUID, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Cancelling an order that was paid online never keeps the money silently
-- ---------------------------------------------------------------------------
-- If an online order is cancelled after a verified payment was applied (or while one is being applied), the attempt that paid it is
-- marked refund_required, with a log entry, so the refund process (P4) and the admin alerts (P3) can never miss it. The order's own
-- cancellation is not blocked here: stock must still be restored by the existing cancellation path.
CREATE OR REPLACE FUNCTION public.flag_refund_when_paid_online_order_cancelled()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
BEGIN
  FOR v_a IN SELECT a.id FROM public.order_payment_attempts a WHERE a.order_id = NEW.id AND a.status = 'succeeded' AND NOT a.refund_required LOOP
    UPDATE public.order_payment_attempts SET refund_required = TRUE, flag_reason = COALESCE(flag_reason, 'order_cancelled_after_payment') WHERE id = v_a.id;
    INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
    VALUES (NEW.id, v_a.id, 'refund_required', 'system', 'The order was cancelled after it had been paid online. The payment must be refunded.', '{}'::JSONB);
  END LOOP;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_flag_refund_when_paid_online_order_cancelled ON public.orders;
CREATE TRIGGER trg_flag_refund_when_paid_online_order_cancelled
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (NEW.status::TEXT = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.flag_refund_when_paid_online_order_cancelled();
