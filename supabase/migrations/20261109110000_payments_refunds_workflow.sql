-- Online payments (Pay Now), phase P4a part 2: requesting, approving, sending and following refunds. Every function is called by the server (service role) or, for the
-- two read views, by signed-in people who may see the order; none can be called by a pharmacy or wholesaler to move money. Nothing happens while there are no refunds.
-- See docs/pay-now-paystack-plan.md (section 15).
--
-- A refund moves through:  requested -> approved -> submitting -> processing -> succeeded
--                          (failed: the provider refused it, can be retried or cancelled;  unknown: it is not known whether the provider received it, a person
--                           checks the provider's dashboard before anything is sent again;  cancelled)
-- Two rules matter most: (1) a refund is never sent twice for the same source (unique source key + only one worker can claim it), and (2) when it is not
-- certain that a request reached the provider it is NEVER retried automatically: a person looks first.

-- ---------------------------------------------------------------------------
-- 1. Requesting a refund (internal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._request_refund(
  p_attempt_id UUID, p_amount_minor BIGINT, p_reason TEXT, p_source_key TEXT, p_requested_by UUID, p_note TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_alive BIGINT;
  v_amount BIGINT;
  v_id UUID;
  v_auto BOOLEAN;
  v_status TEXT;
BEGIN
  SELECT a.id, a.order_id, a.provider, a.mode, a.status, a.refund_required, a.verified_amount_minor INTO v_a
  FROM public.order_payment_attempts a WHERE a.id = p_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  IF v_a.verified_amount_minor IS NULL OR NOT (v_a.status = 'succeeded' OR v_a.refund_required) THEN
    RAISE EXCEPTION 'Only a payment that was received can be refunded.';
  END IF;
  SELECT COALESCE(sum(r.amount_minor), 0) INTO v_alive FROM public.order_refunds r WHERE r.attempt_id = p_attempt_id AND r.status NOT IN ('failed', 'cancelled');
  v_amount := COALESCE(p_amount_minor, v_a.verified_amount_minor - v_alive);
  IF v_amount <= 0 THEN RETURN NULL; END IF;
  IF v_alive + v_amount > v_a.verified_amount_minor THEN RAISE EXCEPTION 'Refunds for this payment cannot add up to more than the payment received.'; END IF;
  SELECT s.auto_refunds INTO v_auto FROM public.payments_settings s WHERE s.id;
  v_status := CASE WHEN COALESCE(v_auto, FALSE) AND p_reason IN ('late_payment', 'double_payment', 'cancelled_after_payment', 'order_changed', 'amendment_reduction')
                   THEN 'approved' ELSE 'requested' END;
  INSERT INTO public.order_refunds(order_id, attempt_id, provider, mode, amount_ghs, amount_minor, reason, source_key, status, requested_by, note, approved_at)
  VALUES (v_a.order_id, p_attempt_id, v_a.provider, v_a.mode, v_amount / 100.0, v_amount, p_reason, p_source_key, v_status, p_requested_by,
          NULLIF(left(btrim(COALESCE(p_note, '')), 500), ''), CASE WHEN v_status = 'approved' THEN now() END)
  ON CONFLICT (source_key) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    SELECT r.id INTO v_id FROM public.order_refunds r WHERE r.source_key = p_source_key;
    RETURN v_id;
  END IF;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_a.order_id, p_attempt_id, 'refund_requested', 'system',
          format('A refund of %s was requested (%s)%s.', public._amendment_money(v_amount / 100.0), replace(p_reason, '_', ' '),
                 CASE WHEN v_status = 'approved' THEN ' and approved automatically' ELSE ', waiting for approval' END),
          jsonb_build_object('refund_id', v_id, 'reason', p_reason));
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._request_refund(UUID, BIGINT, TEXT, TEXT, UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- A payment that cannot stay (late, double, order cancelled after it was paid) asks for its full refund automatically, whichever path recorded it.
-- Whether that request is approved straight away or waits for an administrator is the platform's setting (payments_settings.auto_refunds, off by default).
CREATE OR REPLACE FUNCTION public.payment_attempt_refund_request()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.refund_required AND (TG_OP = 'INSERT' OR NOT OLD.refund_required) AND NEW.verified_amount_minor IS NOT NULL THEN
    BEGIN
      PERFORM public._request_refund(NEW.id, NULL,
        CASE NEW.flag_reason WHEN 'order_cancelled' THEN 'late_payment' WHEN 'already_paid' THEN 'double_payment'
                             WHEN 'order_cancelled_after_payment' THEN 'cancelled_after_payment' ELSE 'order_changed' END,
        'attempt:' || NEW.id || ':full', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      -- Recording the payment must never fail because a refund could not be requested; the "refund needed" alert is already raised.
      RAISE WARNING 'payment_attempt_refund_request failed: %', SQLERRM;
    END;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_payment_attempt_refund_request ON public.order_payment_attempts;
CREATE TRIGGER trg_payment_attempt_refund_request AFTER INSERT OR UPDATE ON public.order_payment_attempts
  FOR EACH ROW EXECUTE FUNCTION public.payment_attempt_refund_request();

-- ---------------------------------------------------------------------------
-- 2. Finishing and failing a refund (internal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._complete_refund(p_refund_id UUID, p_method TEXT, p_note TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_o RECORD;
  v_a RECORD;
  v_done BIGINT;
  v_name TEXT;
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found.'; END IF;
  IF v_r.status = 'succeeded' THEN RETURN FALSE; END IF;
  IF v_r.status = 'cancelled' THEN RAISE EXCEPTION 'A cancelled refund cannot be completed.'; END IF;
  SELECT o.id, o.order_number, o.pharmacy_id, o.status::TEXT AS status, o.payment_status::TEXT AS payment_status INTO v_o FROM public.orders o WHERE o.id = v_r.order_id FOR UPDATE;
  UPDATE public.order_refunds SET status = 'succeeded', completed_at = now(), failure_reason = NULL, method = COALESCE(p_method, method),
    note = COALESCE(NULLIF(left(btrim(COALESCE(p_note, '')), 500), ''), note) WHERE id = p_refund_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_r.order_id, v_r.attempt_id, 'refund_succeeded', 'system', format('A refund of %s was returned to the customer.', public._amendment_money(v_r.amount_ghs)),
          jsonb_build_object('refund_id', p_refund_id, 'method', COALESCE(p_method, v_r.method)));

  -- When everything the payment received has been returned, the alerts that were waiting for it are closed.
  SELECT a.id, a.verified_amount_minor INTO v_a FROM public.order_payment_attempts a WHERE a.id = v_r.attempt_id;
  SELECT COALESCE(sum(r.amount_minor), 0) INTO v_done FROM public.order_refunds r WHERE r.attempt_id = v_r.attempt_id AND r.status = 'succeeded';
  IF v_done >= COALESCE(v_a.verified_amount_minor, 0) THEN
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolution_note = 'Closed automatically: the payment was fully refunded.'
    WHERE attempt_id = v_r.attempt_id AND status = 'open' AND kind IN ('refund_required', 'refund_failed', 'refund_stuck', 'flagged_payment');
  END IF;

  -- An order that was paid, is cancelled, and has had all its money returned is "refunded".
  IF v_o.payment_status = 'paid' AND v_o.status = 'cancelled' AND NOT EXISTS (
       SELECT 1 FROM public.order_payment_attempts a
       WHERE a.order_id = v_r.order_id AND a.status = 'succeeded' AND NOT a.refund_required
         AND COALESCE(a.verified_amount_minor, 0) > COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded'), 0)) THEN
    PERFORM public._allow_order_total_change();
    UPDATE public.orders SET payment_status = 'refunded' WHERE id = v_r.order_id;
  END IF;

  SELECT name INTO v_name FROM public.businesses WHERE id = v_o.pharmacy_id;
  PERFORM public.notify_business(v_o.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Refund sent',
    format('%s was refunded for order %s. It can take several business days to reach your account.', public._amendment_money(v_r.amount_ghs), v_o.order_number),
    '/pharmacy?tab=orders', jsonb_build_object('order_id', v_r.order_id));
  PERFORM public.write_audit_log('Refund completed', v_name, 'refund', p_refund_id, v_o.order_number,
    jsonb_build_object('amount_ghs', v_r.amount_ghs, 'reason', v_r.reason, 'method', COALESCE(p_method, v_r.method)), _business_id => v_o.pharmacy_id);
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public._complete_refund(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._fail_refund(p_refund_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_number TEXT;
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND OR v_r.status IN ('succeeded', 'cancelled', 'failed') THEN RETURN; END IF;
  UPDATE public.order_refunds SET status = 'failed', failure_reason = left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 500) WHERE id = p_refund_id;
  SELECT order_number INTO v_number FROM public.orders WHERE id = v_r.order_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_r.order_id, v_r.attempt_id, 'refund_failed', 'system', 'A refund did not go through.', jsonb_build_object('refund_id', p_refund_id, 'reason', left(COALESCE(p_reason, ''), 300)));
  PERFORM public._raise_payment_alert('refund_failed', 'critical', v_r.order_id, v_r.attempt_id, 'refund_failed:' || p_refund_id,
    format('The refund of %s for order %s did not go through: %s', public._amendment_money(v_r.amount_ghs), v_number, COALESCE(NULLIF(left(btrim(COALESCE(p_reason, '')), 200), ''), 'no reason was given.')),
    jsonb_build_object('refund_id', p_refund_id));
END;
$$;
REVOKE ALL ON FUNCTION public._fail_refund(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._refund_unknown(p_refund_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_number TEXT;
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND OR v_r.status IN ('succeeded', 'cancelled', 'failed', 'unknown') THEN RETURN; END IF;
  UPDATE public.order_refunds SET status = 'unknown', failure_reason = left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 500) WHERE id = p_refund_id;
  SELECT order_number INTO v_number FROM public.orders WHERE id = v_r.order_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_r.order_id, v_r.attempt_id, 'refund_unknown', 'system', 'It is not known whether a refund reached the provider.', jsonb_build_object('refund_id', p_refund_id));
  PERFORM public._raise_payment_alert('refund_stuck', 'critical', v_r.order_id, v_r.attempt_id, 'refund_stuck:' || p_refund_id,
    format('The refund of %s for order %s may or may not have been sent (%s). Check the provider''s dashboard BEFORE sending it again.',
           public._amendment_money(v_r.amount_ghs), v_number, COALESCE(NULLIF(left(btrim(COALESCE(p_reason, '')), 200), ''), 'the outcome is unknown')),
    jsonb_build_object('refund_id', p_refund_id));
END;
$$;
REVOKE ALL ON FUNCTION public._refund_unknown(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Sending refunds (the server)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refunds_to_submit(p_limit INTEGER DEFAULT 10)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('refund_id', t.id) ORDER BY t.approved_at), '[]'::JSONB)
  FROM (SELECT r.id, r.approved_at FROM public.order_refunds r WHERE r.status = 'approved' AND r.method = 'provider'
        ORDER BY r.approved_at LIMIT GREATEST(LEAST(p_limit, 50), 1)) t
$$;
REVOKE ALL ON FUNCTION public.refunds_to_submit(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.refunds_to_submit(INTEGER) TO service_role;

-- Exactly one worker can take an approved refund: it becomes "submitting" and the details to send are returned; anyone else gets nothing.
CREATE OR REPLACE FUNCTION public.claim_refund_for_submission(p_refund_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_ref TEXT;
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE SKIP LOCKED;
  IF NOT FOUND OR v_r.status <> 'approved' OR v_r.method <> 'provider' THEN RETURN NULL; END IF;
  SELECT a.reference INTO v_ref FROM public.order_payment_attempts a WHERE a.id = v_r.attempt_id;
  UPDATE public.order_refunds SET status = 'submitting', submitted_at = now() WHERE id = p_refund_id;
  RETURN jsonb_build_object('refund_id', v_r.id, 'provider', v_r.provider, 'mode', v_r.mode, 'transaction_reference', v_ref,
                            'amount_minor', v_r.amount_minor, 'reason', v_r.reason);
END;
$$;
REVOKE ALL ON FUNCTION public.claim_refund_for_submission(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_refund_for_submission(UUID) TO service_role;

-- The provider accepted the request. It is now processing (the final outcome arrives later); a provider that already says "processed" or "failed" is believed.
CREATE OR REPLACE FUNCTION public.record_refund_submission(p_refund_id UUID, p_provider_refund_id TEXT, p_provider_status TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_status TEXT := lower(COALESCE(p_provider_status, ''));
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found.'; END IF;
  IF v_r.status NOT IN ('submitting', 'unknown') THEN RETURN v_r.status; END IF;
  UPDATE public.order_refunds SET provider_refund_id = COALESCE(left(NULLIF(p_provider_refund_id, ''), 100), provider_refund_id),
    provider_status = left(NULLIF(v_status, ''), 60), status = 'processing', failure_reason = NULL WHERE id = p_refund_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_r.order_id, v_r.attempt_id, 'refund_submitted', 'system', 'The refund was sent to the provider.', jsonb_build_object('refund_id', p_refund_id, 'provider_status', v_status));
  UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolution_note = 'Closed automatically: the provider has accepted the refund.'
  WHERE attempt_id = v_r.attempt_id AND status = 'open' AND kind = 'refund_stuck' AND dedupe_key = 'refund_stuck:' || p_refund_id;
  IF v_status = 'processed' THEN
    PERFORM public._complete_refund(p_refund_id, 'provider');
    RETURN 'succeeded';
  ELSIF v_status = 'failed' THEN
    PERFORM public._fail_refund(p_refund_id, 'The provider reported that the refund failed.');
    RETURN 'failed';
  END IF;
  RETURN 'processing';
END;
$$;
REVOKE ALL ON FUNCTION public.record_refund_submission(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_refund_submission(UUID, TEXT, TEXT) TO service_role;

-- The provider answered with an error. A DEFINITE refusal (it told us no) makes the refund "failed" and retryable; anything that leaves it uncertain
-- whether the request arrived (a timeout, a server error) makes it "unknown": it is never retried automatically.
CREATE OR REPLACE FUNCTION public.record_refund_rejection(p_refund_id UUID, p_reason TEXT, p_definite BOOLEAN)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  SELECT status INTO v_status FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found.'; END IF;
  IF v_status <> 'submitting' THEN RETURN v_status; END IF;
  IF p_definite THEN PERFORM public._fail_refund(p_refund_id, p_reason);
  ELSE PERFORM public._refund_unknown(p_refund_id, p_reason);
  END IF;
  RETURN (SELECT status FROM public.order_refunds WHERE id = p_refund_id);
END;
$$;
REVOKE ALL ON FUNCTION public.record_refund_rejection(UUID, TEXT, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_refund_rejection(UUID, TEXT, BOOLEAN) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. What the provider tells us about a refund (a signed notification)
-- ---------------------------------------------------------------------------
-- Matched by the transaction's reference (and the amount, when the provider gives one) to a refund that was sent. A notification for a refund this system did
-- not send (for example one made by hand in the provider's dashboard) is recorded as an alert for a person, never silently applied.
CREATE OR REPLACE FUNCTION public.apply_refund_event(
  p_provider TEXT, p_mode TEXT, p_transaction_reference TEXT, p_event_type TEXT, p_provider_refund_id TEXT, p_amount_minor BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_r RECORD;
BEGIN
  IF p_event_type NOT IN ('refund.pending', 'refund.processing', 'refund.processed', 'refund.failed', 'refund.needs-attention') THEN
    RETURN jsonb_build_object('outcome', 'ignored');
  END IF;
  SELECT a.id, a.order_id, a.mode INTO v_a FROM public.order_payment_attempts a WHERE a.provider = p_provider AND a.reference = p_transaction_reference;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome', 'unknown_reference');
  END IF;
  IF v_a.mode <> p_mode THEN RETURN jsonb_build_object('outcome', 'mode_mismatch'); END IF;
  SELECT r.* INTO v_r FROM public.order_refunds r
  WHERE r.attempt_id = v_a.id AND r.status IN ('submitting', 'processing', 'unknown') AND (p_amount_minor IS NULL OR r.amount_minor = p_amount_minor)
  ORDER BY r.submitted_at NULLS LAST, r.created_at LIMIT 1 FOR UPDATE;
  -- The provider's amount can be stated in other units than ours: if nothing matched by amount but exactly ONE refund of this payment is in flight,
  -- the notification can only be about that one.
  IF NOT FOUND AND p_amount_minor IS NOT NULL AND (SELECT count(*) FROM public.order_refunds r WHERE r.attempt_id = v_a.id AND r.status IN ('submitting', 'processing', 'unknown')) = 1 THEN
    SELECT r.* INTO v_r FROM public.order_refunds r WHERE r.attempt_id = v_a.id AND r.status IN ('submitting', 'processing', 'unknown') FOR UPDATE;
  END IF;
  IF NOT FOUND THEN
    -- A late repeat of an outcome already recorded is harmless.
    IF EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.attempt_id = v_a.id AND r.status IN ('succeeded', 'failed') AND (p_amount_minor IS NULL OR r.amount_minor = p_amount_minor)) THEN
      RETURN jsonb_build_object('outcome', 'already_recorded', 'order_id', v_a.order_id);
    END IF;
    PERFORM public._raise_payment_alert('refund_unmatched', 'warning', v_a.order_id, v_a.id, 'refund_unmatched:' || p_transaction_reference || ':' || p_event_type,
      format('The provider reports %s for reference %s, but this system has no refund in progress for it. If someone refunded it by hand, record that on the Payments screen.', p_event_type, p_transaction_reference),
      jsonb_build_object('event', p_event_type, 'amount_minor', p_amount_minor));
    RETURN jsonb_build_object('outcome', 'unmatched', 'order_id', v_a.order_id);
  END IF;
  IF p_provider_refund_id IS NOT NULL AND v_r.provider_refund_id IS NULL THEN
    UPDATE public.order_refunds SET provider_refund_id = left(p_provider_refund_id, 100) WHERE id = v_r.id;
  END IF;
  IF p_event_type IN ('refund.pending', 'refund.processing') THEN
    UPDATE public.order_refunds SET status = 'processing', provider_status = substr(p_event_type, 8), failure_reason = NULL WHERE id = v_r.id AND status IN ('submitting', 'unknown');
    RETURN jsonb_build_object('outcome', 'processing', 'refund_id', v_r.id, 'order_id', v_a.order_id);
  ELSIF p_event_type = 'refund.processed' THEN
    PERFORM public._complete_refund(v_r.id, 'provider');
    RETURN jsonb_build_object('outcome', 'succeeded', 'refund_id', v_r.id, 'order_id', v_a.order_id);
  ELSIF p_event_type = 'refund.failed' THEN
    PERFORM public._fail_refund(v_r.id, 'The provider reported that the refund failed. The amount is back with the platform.');
    RETURN jsonb_build_object('outcome', 'failed', 'refund_id', v_r.id, 'order_id', v_a.order_id);
  ELSE
    PERFORM public._refund_unknown(v_r.id, 'The provider needs more details (such as bank account details) to complete the refund.');
    RETURN jsonb_build_object('outcome', 'needs_attention', 'refund_id', v_r.id, 'order_id', v_a.order_id);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_refund_event(TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_refund_event(TEXT, TEXT, TEXT, TEXT, TEXT, BIGINT) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. What an administrator can do to a refund
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_refund_transition(p_admin_id UUID, p_refund_id UUID, p_action TEXT, p_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_note TEXT := btrim(COALESCE(p_note, ''));
  v_number TEXT;
  v_pharmacy UUID;
  v_name TEXT;
  v_new TEXT;
BEGIN
  IF NOT public.payment_user_is_admin(p_admin_id) THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  IF p_action NOT IN ('approve', 'cancel', 'retry', 'confirm_refunded', 'mark_failed') THEN RAISE EXCEPTION 'Unknown action.'; END IF;
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found.'; END IF;
  SELECT o.order_number, o.pharmacy_id INTO v_number, v_pharmacy FROM public.orders o WHERE o.id = v_r.order_id;
  IF p_action IN ('confirm_refunded', 'mark_failed') AND (char_length(v_note) < 5 OR char_length(v_note) > 500) THEN
    RAISE EXCEPTION 'A note of 5 to 500 characters saying what was checked is required.';
  END IF;

  IF p_action = 'approve' THEN
    IF v_r.status = 'approved' THEN RETURN jsonb_build_object('status', 'approved', 'needs_submission', TRUE); END IF;
    IF v_r.status <> 'requested' THEN RAISE EXCEPTION 'Only a refund that is waiting for approval can be approved (it is %).', v_r.status; END IF;
    UPDATE public.order_refunds SET status = 'approved', approved_by = p_admin_id, approved_at = now() WHERE id = p_refund_id;
    v_new := 'approved';
  ELSIF p_action = 'retry' THEN
    IF v_r.status <> 'failed' THEN RAISE EXCEPTION 'Only a refund that failed can be retried (it is %).', v_r.status; END IF;
    UPDATE public.order_refunds SET status = 'approved', approved_by = p_admin_id, approved_at = now(), failure_reason = NULL WHERE id = p_refund_id;
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolved_by = p_admin_id, resolution_note = 'Retried by an administrator.'
    WHERE status = 'open' AND dedupe_key = 'refund_failed:' || p_refund_id;
    v_new := 'approved';
  ELSIF p_action = 'cancel' THEN
    IF v_r.status NOT IN ('requested', 'approved', 'failed') THEN RAISE EXCEPTION 'A refund that is % cannot be cancelled.', v_r.status; END IF;
    UPDATE public.order_refunds SET status = 'cancelled', note = COALESCE(NULLIF(left(v_note, 500), ''), note) WHERE id = p_refund_id;
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolved_by = p_admin_id, resolution_note = 'The refund was cancelled by an administrator.'
    WHERE status = 'open' AND dedupe_key = 'refund_failed:' || p_refund_id;
    v_new := 'cancelled';
  ELSIF p_action = 'confirm_refunded' THEN
    IF v_r.status NOT IN ('requested', 'approved', 'submitting', 'processing', 'unknown', 'failed') THEN RAISE EXCEPTION 'A refund that is % cannot be confirmed.', v_r.status; END IF;
    PERFORM public._complete_refund(p_refund_id, 'manual', v_note);
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolved_by = p_admin_id, resolution_note = 'Confirmed as refunded by an administrator.'
    WHERE status = 'open' AND dedupe_key IN ('refund_failed:' || p_refund_id, 'refund_stuck:' || p_refund_id);
    v_new := 'succeeded';
  ELSE
    IF v_r.status NOT IN ('processing', 'unknown') THEN RAISE EXCEPTION 'Only a refund that is processing or unknown can be marked as failed (it is %).', v_r.status; END IF;
    PERFORM public._fail_refund_from_any(p_refund_id, v_note);
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolved_by = p_admin_id, resolution_note = 'Marked as failed by an administrator.'
    WHERE status = 'open' AND dedupe_key = 'refund_stuck:' || p_refund_id;
    v_new := 'failed';
  END IF;
  SELECT name INTO v_name FROM public.businesses WHERE id = v_pharmacy;
  PERFORM public.write_audit_log('Refund ' || p_action, v_name, 'refund', p_refund_id, v_number,
    jsonb_build_object('from', v_r.status, 'to', v_new, 'amount_ghs', v_r.amount_ghs, 'note', NULLIF(v_note, ''), 'admin_id', p_admin_id), _business_id => v_pharmacy);
  RETURN jsonb_build_object('status', v_new, 'needs_submission', v_new = 'approved');
END;
$$;
REVOKE ALL ON FUNCTION public.admin_refund_transition(UUID, UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_refund_transition(UUID, UUID, TEXT, TEXT) TO service_role;

-- "unknown" or "processing" -> failed (the administrator checked the provider and it was not sent): _fail_refund refuses 'unknown', so this one allows it.
CREATE OR REPLACE FUNCTION public._fail_refund_from_any(p_refund_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
BEGIN
  SELECT * INTO v_r FROM public.order_refunds WHERE id = p_refund_id FOR UPDATE;
  IF NOT FOUND OR v_r.status NOT IN ('processing', 'unknown') THEN RETURN; END IF;
  UPDATE public.order_refunds SET status = 'failed', failure_reason = left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 500) WHERE id = p_refund_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_r.order_id, v_r.attempt_id, 'refund_failed', 'system', 'An administrator confirmed that a refund was not sent.', jsonb_build_object('refund_id', p_refund_id));
END;
$$;
REVOKE ALL ON FUNCTION public._fail_refund_from_any(UUID, TEXT) FROM PUBLIC, anon, authenticated;

-- Refunds that have been sitting too long: waiting for approval, approved but not sent (is the reconciler running?), sent but not confirmed, or stuck mid-send.
CREATE OR REPLACE FUNCTION public.flag_stale_refunds(p_processing_hours INTEGER DEFAULT 240)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_r RECORD;
  v_n INTEGER := 0;
  v_number TEXT;
BEGIN
  -- A refund stuck mid-send for a quarter of an hour: a worker died after claiming it. Whether it reached the provider is unknown.
  FOR v_r IN SELECT id FROM public.order_refunds WHERE status = 'submitting' AND submitted_at < now() - interval '15 minutes' LOOP
    PERFORM public._refund_unknown(v_r.id, 'The refund was being sent when the system stopped; it is not known whether the provider received it.');
    v_n := v_n + 1;
  END LOOP;
  FOR v_r IN
    SELECT r.id, r.order_id, r.attempt_id, r.amount_ghs, r.status FROM public.order_refunds r
    WHERE (r.status = 'requested' AND r.created_at < now() - interval '24 hours')
       OR (r.status = 'approved' AND r.approved_at < now() - interval '2 hours')
       OR (r.status = 'processing' AND r.submitted_at < now() - make_interval(hours => GREATEST(p_processing_hours, 1)))
  LOOP
    SELECT order_number INTO v_number FROM public.orders WHERE id = v_r.order_id;
    PERFORM public._raise_payment_alert('refund_stuck', 'warning', v_r.order_id, v_r.attempt_id, 'refund_overdue:' || v_r.id || ':' || v_r.status,
      format('The refund of %s for order %s has been %s for too long.', public._amendment_money(v_r.amount_ghs), v_number,
             CASE v_r.status WHEN 'requested' THEN 'waiting for approval' WHEN 'approved' THEN 'approved but not sent (is the reconciler running?)' ELSE 'processing without confirmation' END),
      jsonb_build_object('refund_id', v_r.id, 'status', v_r.status));
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.flag_stale_refunds(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.flag_stale_refunds(INTEGER) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. What the screens see (replacing the P2 and P3 versions)
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
    'last_attempt', CASE WHEN v_last.status IS NULL THEN NULL ELSE jsonb_build_object(
      'status', v_last.status, 'at', v_last.initiated_at, 'reason', CASE WHEN v_side = 'pharmacy' THEN v_last.failure_reason ELSE NULL END,
      'channel', v_last.channel) END,
    'paid_ghs', COALESCE((SELECT sum(COALESCE(a.verified_amount_minor, 0)) FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.status = 'succeeded') / 100.0, 0),
    'refunded_ghs', COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.order_id = p_order_id AND r.status = 'succeeded') / 100.0, 0),
    -- True while money received for this order is still to be returned (a refund is needed and has not yet succeeded in full).
    'refund_required', EXISTS (SELECT 1 FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.refund_required
      AND COALESCE(a.verified_amount_minor, 0) > COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded'), 0)),
    'refunds', COALESCE((SELECT jsonb_agg(jsonb_build_object('amount_ghs', x.amount_ghs, 'status', x.status, 'reason', x.reason, 'created_at', x.created_at, 'completed_at', x.completed_at)
                                          ORDER BY x.created_at)
                         FROM public.order_refunds x WHERE x.order_id = p_order_id AND x.status <> 'cancelled'), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.order_payment_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_payment_summary(UUID) TO authenticated, service_role;

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
             al.resolved_at, al.resolution_note
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
             a.refund_required, a.channel, a.initiated_at, a.paid_at, a.last_checked_at, a.failure_reason
      FROM public.order_payment_attempts a JOIN public.orders o ON o.id = a.order_id
      LEFT JOIN public.businesses ph ON ph.id = o.pharmacy_id LEFT JOIN public.businesses wh ON wh.id = o.wholesaler_id
      ORDER BY a.initiated_at DESC LIMIT 60) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payment_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_payment_overview() TO authenticated;
