-- Online payments (Pay Now), phase P3 part 2: alerts, checking attempts with the provider, expiring unpaid online orders, the daily comparison and
-- the admin views. Everything here is called by the server (service role) or by platform admins; no pharmacy or wholesaler can call any of it.
-- Nothing changes while online payments are off: with no online orders and no attempts these functions find nothing to do.
-- See docs/pay-now-paystack-plan.md (section 14).

-- ---------------------------------------------------------------------------
-- 1. Alerts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._notify_platform_admins(p_title TEXT, p_body TEXT, p_metadata JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
  SELECT DISTINCT ur.user_id, 'payment_update', p_title, p_body, '/admin/payments', COALESCE(p_metadata, '{}'::JSONB)
  FROM public.user_roles ur WHERE ur.role = 'admin';
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING '_notify_platform_admins failed: %', SQLERRM;
END;
$$;
REVOKE ALL ON FUNCTION public._notify_platform_admins(TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;

-- One open alert per thing: a second report of the same problem only counts it again. A new alert tells the platform admins.
CREATE OR REPLACE FUNCTION public._raise_payment_alert(
  p_kind TEXT, p_severity TEXT, p_order_id UUID, p_attempt_id UUID, p_dedupe_key TEXT, p_summary TEXT, p_details JSONB DEFAULT '{}'::JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_new BOOLEAN;
BEGIN
  INSERT INTO public.payment_alerts(kind, severity, order_id, attempt_id, dedupe_key, summary, details)
  VALUES (p_kind, p_severity, p_order_id, p_attempt_id, p_dedupe_key, left(p_summary, 500), COALESCE(p_details, '{}'::JSONB))
  ON CONFLICT (dedupe_key) WHERE status = 'open'
  DO UPDATE SET occurrences = public.payment_alerts.occurrences + 1, last_seen_at = now(), details = EXCLUDED.details
  RETURNING id, (xmax = 0) INTO v_id, v_new;
  IF v_new THEN
    PERFORM public._notify_platform_admins(
      CASE p_severity WHEN 'critical' THEN 'Payment problem: action needed' ELSE 'Payment alert' END, left(p_summary, 300),
      jsonb_build_object('alert_id', v_id, 'order_id', p_order_id));
  END IF;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public._raise_payment_alert(TEXT, TEXT, UUID, UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;

-- For the server's jobs to report a problem that is not tied to one order (the provider cannot be reached, a comparison could not finish).
CREATE OR REPLACE FUNCTION public.report_payment_job_problem(p_kind TEXT, p_summary TEXT, p_details JSONB, p_dedupe_key TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_kind NOT IN ('provider_unreachable', 'expiry_blocked') THEN RAISE EXCEPTION 'Unknown kind of job problem.'; END IF;
  RETURN public._raise_payment_alert(p_kind, 'warning', NULL, NULL, p_dedupe_key, p_summary, p_details);
END;
$$;
REVOKE ALL ON FUNCTION public.report_payment_job_problem(TEXT, TEXT, JSONB, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_payment_job_problem(TEXT, TEXT, JSONB, TEXT) TO service_role;

-- A payment that needs a person (flagged, or money that must be refunded) always raises an alert, whichever path recorded it (webhook, verify,
-- reconciler); the pharmacy is told too, in words that promise nothing the system does not yet do.
CREATE OR REPLACE FUNCTION public.payment_attempt_alerts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_reason TEXT;
BEGIN
  SELECT o.order_number, o.pharmacy_id INTO v_order FROM public.orders o WHERE o.id = NEW.order_id;
  v_reason := replace(COALESCE(NEW.flag_reason, 'see the payment log'), '_', ' ');
  IF NEW.refund_required AND (TG_OP = 'INSERT' OR NOT OLD.refund_required) THEN
    PERFORM public._raise_payment_alert('refund_required', 'critical', NEW.order_id, NEW.id, 'refund:' || NEW.id,
      format('%s was received for order %s and must be refunded (%s).', public._amendment_money(NEW.amount_ghs), v_order.order_number, v_reason),
      jsonb_build_object('reference', NEW.reference, 'reason', NEW.flag_reason));
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'A payment needs attention',
      format('A payment of %s for order %s cannot be kept against that order (%s). Our team has been told and will arrange the refund. Please do not pay again.',
             public._amendment_money(NEW.amount_ghs), v_order.order_number, v_reason),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', NEW.order_id));
  ELSIF NEW.status = 'flagged' AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'flagged') THEN
    PERFORM public._raise_payment_alert('flagged_payment', 'critical', NEW.order_id, NEW.id, 'flagged:' || NEW.id,
      format('A verified payment for order %s was not applied (%s). A person must look at it.', v_order.order_number, v_reason),
      jsonb_build_object('reference', NEW.reference, 'reason', NEW.flag_reason, 'asked_minor', NEW.amount_minor, 'paid_minor', NEW.verified_amount_minor));
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'A payment needs attention',
      format('A payment for order %s could not be applied automatically. Our team has been told and will contact you. Please do not pay again.', v_order.order_number),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', NEW.order_id));
  END IF;
  -- A payment that was in doubt and is now applied closes the alerts that were waiting on it.
  IF NEW.status = 'succeeded' AND NOT NEW.refund_required THEN
    UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolution_note = 'Closed automatically: the payment was applied.'
    WHERE attempt_id = NEW.id AND status = 'open' AND kind IN ('paid_not_applied', 'flagged_payment');
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS trg_payment_attempt_alerts ON public.order_payment_attempts;
CREATE TRIGGER trg_payment_attempt_alerts AFTER INSERT OR UPDATE ON public.order_payment_attempts
  FOR EACH ROW EXECUTE FUNCTION public.payment_attempt_alerts();

-- ---------------------------------------------------------------------------
-- 2. The return page's check: throttled, and it never says an attempt was verified until the provider has answered
-- ---------------------------------------------------------------------------
-- Replaces the P2 version. Each attempt is handed out at most once every 3 seconds (the page asks every 4); an attempt whose turn is not yet
-- due is simply not listed, and "throttled" tells the caller so it can answer from the order's current state without calling the provider.
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
  RETURN jsonb_build_object('payment_status', v_order.payment_status, 'throttled', v_ids IS NULL AND v_all > 0, 'attempts', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('attempt_id', a.id, 'provider', a.provider, 'mode', a.mode, 'reference', a.reference) ORDER BY a.initiated_at DESC)
    FROM public.order_payment_attempts a WHERE a.id = ANY (COALESCE(v_ids, '{}'::UUID[]))), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.payment_attempts_to_check(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_attempts_to_check(UUID, UUID) TO service_role;

-- The provider answered (even "I have never heard of that reference"): the attempt counts as checked now.
CREATE OR REPLACE FUNCTION public.mark_attempt_checked(p_attempt_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ UPDATE public.order_payment_attempts SET last_checked_at = now(), check_count = check_count + 1 WHERE id = p_attempt_id $$;
REVOKE ALL ON FUNCTION public.mark_attempt_checked(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_attempt_checked(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. What the reconciler should ask the provider about
-- ---------------------------------------------------------------------------
-- Attempts that could still turn out to have been paid, oldest-checked first: open ones every few minutes, closed or abandoned ones (a customer can
-- still pay on a page that was left open) hourly, all of them for 48 hours after they were started. This includes attempts of cancelled orders,
-- which is how a late payment is noticed even when its notification never arrived.
CREATE OR REPLACE FUNCTION public.payment_attempts_due_for_check(p_limit INTEGER DEFAULT 25, p_min_age_seconds INTEGER DEFAULT 180, p_recheck_seconds INTEGER DEFAULT 240)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('attempt_id', t.id, 'provider', t.provider, 'mode', t.mode, 'reference', t.reference, 'order_id', t.order_id)
                            ORDER BY t.due_at), '[]'::JSONB)
  FROM (
    SELECT a.id, a.provider, a.mode, a.reference, a.order_id, COALESCE(a.last_checked_at, a.initiated_at) AS due_at
    FROM public.order_payment_attempts a
    WHERE a.status IN ('initiated', 'pending', 'expired', 'abandoned')
      AND a.initiated_at < now() - make_interval(secs => GREATEST(p_min_age_seconds, 0))
      AND a.initiated_at > now() - interval '48 hours'
      AND (a.last_checked_at IS NULL
           OR a.last_checked_at < now() - CASE WHEN a.status IN ('initiated', 'pending') THEN make_interval(secs => GREATEST(p_recheck_seconds, 30)) ELSE interval '1 hour' END)
    ORDER BY COALESCE(a.last_checked_at, a.initiated_at)
    LIMIT GREATEST(LEAST(p_limit, 100), 1)
  ) t
$$;
REVOKE ALL ON FUNCTION public.payment_attempts_due_for_check(INTEGER, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_attempts_due_for_check(INTEGER, INTEGER, INTEGER) TO service_role;

-- An attempt that has been open for 48 hours is closed for good (the provider's own pages do not stay payable that long).
CREATE OR REPLACE FUNCTION public.close_stale_payment_attempts(p_hours INTEGER DEFAULT 48)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  WITH closed AS (
    UPDATE public.order_payment_attempts SET status = 'expired'
    WHERE status IN ('initiated', 'pending') AND initiated_at < now() - make_interval(hours => GREATEST(p_hours, 1))
    RETURNING id, order_id
  ), logged AS (
    INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
    SELECT order_id, id, 'attempt_closed', 'reconcile', 'The attempt stayed open for too long and was closed.', '{}'::JSONB FROM closed RETURNING 1
  )
  SELECT count(*) INTO v_count FROM closed;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.close_stale_payment_attempts(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.close_stale_payment_attempts(INTEGER) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Expiring unpaid online orders (stock is released through the existing cancellation path)
-- ---------------------------------------------------------------------------
-- An online order that nobody paid is cancelled 30 minutes after the last payment attempt started (or after it was placed, if none was ever started),
-- and in any case 2 hours after it was placed. Under the order lock it is looked at again: still unpaid, still pending, no paying attempt. It is NEVER
-- expired while one of its attempts could still turn out to have been paid and has not been checked with the provider recently (15 minutes for an open
-- attempt, 70 for one that was closed): money that is in flight must be found first. Cancelling restores the stock through the same triggers as any cancellation, and the pharmacy is told.
CREATE OR REPLACE FUNCTION public.expire_unpaid_online_orders(p_limit INTEGER DEFAULT 50, p_window_minutes INTEGER DEFAULT 30, p_max_hours INTEGER DEFAULT 2)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_c RECORD;
  v_order RECORD;
  v_expired INTEGER := 0;
  v_blocked INTEGER := 0;
  v_name TEXT;
BEGIN
  FOR v_c IN
    SELECT o.id FROM public.orders o
    WHERE o.payment_method::TEXT = 'paystack' AND o.payment_status::TEXT = 'unpaid' AND o.status::TEXT = 'pending'
      AND (GREATEST(o.created_at, COALESCE((SELECT max(a.initiated_at) FROM public.order_payment_attempts a WHERE a.order_id = o.id), o.created_at))
             < now() - make_interval(mins => GREATEST(p_window_minutes, 1))
           OR o.created_at < now() - make_interval(hours => GREATEST(p_max_hours, 1)))
    ORDER BY o.created_at LIMIT GREATEST(LEAST(p_limit, 200), 1)
  LOOP
    SELECT o.id, o.order_number, o.pharmacy_id, o.wholesaler_id, o.status::TEXT AS status, o.payment_status::TEXT AS payment_status, o.payment_method::TEXT AS payment_method
    INTO v_order FROM public.orders o WHERE o.id = v_c.id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF v_order.payment_method <> 'paystack' OR v_order.payment_status <> 'unpaid' OR v_order.status <> 'pending' THEN CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM public.order_payment_attempts a WHERE a.order_id = v_order.id AND a.status = 'succeeded' AND NOT a.refund_required) THEN CONTINUE; END IF;

    IF EXISTS (SELECT 1 FROM public.order_payment_attempts a
               WHERE a.order_id = v_order.id AND a.initiated_at > now() - interval '48 hours'
                 AND ((a.status IN ('initiated', 'pending') AND (a.last_checked_at IS NULL OR a.last_checked_at < now() - interval '15 minutes'))
                      OR (a.status = 'expired' AND (a.last_checked_at IS NULL OR a.last_checked_at < now() - interval '70 minutes')))) THEN
      v_blocked := v_blocked + 1;
      PERFORM public._raise_payment_alert('expiry_blocked', 'info', v_order.id, NULL, 'expiry_blocked:' || v_order.id,
        format('Order %s is past its payment window but was not cancelled: its payment attempts have not been checked with the provider recently.', v_order.order_number),
        jsonb_build_object('order_number', v_order.order_number));
      CONTINUE;
    END IF;

    UPDATE public.order_payment_attempts SET status = 'expired' WHERE order_id = v_order.id AND status IN ('initiated', 'pending');
    UPDATE public.orders SET status = 'cancelled', cancelled_at = now(), cancellation_reason = 'The online payment was not completed in time.' WHERE id = v_order.id;
    INSERT INTO public.order_payment_log(order_id, kind, source, summary, details)
    VALUES (v_order.id, 'order_expired', 'reconcile', 'The order was cancelled because its online payment was not completed in time.', '{}'::JSONB);
    SELECT name INTO v_name FROM public.businesses WHERE id = v_order.pharmacy_id;
    PERFORM public.write_audit_log('Online order expired unpaid', v_name, 'order', v_order.id, v_order.order_number,
      jsonb_build_object('window_minutes', p_window_minutes), _business_id => v_order.pharmacy_id);
    PERFORM public.notify_business(v_order.pharmacy_id, ARRAY['owner', 'manager', 'cashier'], 'payment_update', 'Order cancelled: payment not completed',
      format('Order %s was cancelled because its online payment was not completed in time. Nothing was charged. You can place the order again.', v_order.order_number),
      '/pharmacy?tab=orders', jsonb_build_object('order_id', v_order.id));
    v_expired := v_expired + 1;
  END LOOP;
  RETURN jsonb_build_object('expired', v_expired, 'blocked', v_blocked);
END;
$$;
REVOKE ALL ON FUNCTION public.expire_unpaid_online_orders(INTEGER, INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_unpaid_online_orders(INTEGER, INTEGER, INTEGER) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. The daily comparison with the provider
-- ---------------------------------------------------------------------------
-- p_transactions is the provider's list for [p_from, p_to): [{reference, status, amount_minor, currency}]. Only references we generated
-- (dx-<mode>-...) are considered; anything else in the provider account is not ours to judge. Two passes:
--   p_final = false: classify. Anything the provider says was paid that we have not settled is returned in "to_verify" (the server verifies it
--     with the provider and applies it through apply_payment_result); differences that need a person raise alerts.
--   p_final = true: run after those were verified; whatever is STILL not settled raises "paid_not_applied".
-- p_complete says the list covers the whole window; "ours but missing at the provider" is only judged when it does.
CREATE OR REPLACE FUNCTION public.reconcile_provider_transactions(
  p_provider TEXT, p_mode TEXT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_transactions JSONB, p_complete BOOLEAN, p_final BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_t RECORD;
  v_a RECORD;
  v_to_verify TEXT[] := '{}';
  v_alerts INTEGER := 0;
  v_checked INTEGER := 0;
  v_prefix TEXT := 'dx-' || p_mode || '-%';
BEGIN
  IF jsonb_typeof(p_transactions) <> 'array' THEN RAISE EXCEPTION 'The provider list must be an array.'; END IF;
  IF p_mode NOT IN ('test', 'live') THEN RAISE EXCEPTION 'Unknown payment mode.'; END IF;

  -- Provider -> ours.
  FOR v_t IN
    SELECT x ->> 'reference' AS reference, x ->> 'status' AS status, (x ->> 'amount_minor')::BIGINT AS amount_minor, x ->> 'currency' AS currency
    FROM jsonb_array_elements(p_transactions) x WHERE (x ->> 'reference') LIKE v_prefix
  LOOP
    v_checked := v_checked + 1;
    SELECT a.id, a.order_id, a.status, a.amount_minor, a.verified_amount_minor, a.refund_required INTO v_a
    FROM public.order_payment_attempts a WHERE a.provider = p_provider AND a.reference = v_t.reference;
    IF NOT FOUND THEN
      IF v_t.status = 'success' THEN
        PERFORM public._raise_payment_alert('unknown_at_provider', 'critical', NULL, NULL, 'unknown:' || v_t.reference,
          format('The provider shows a successful payment with reference %s that this system has no record of.', v_t.reference),
          jsonb_build_object('reference', v_t.reference, 'amount_minor', v_t.amount_minor, 'currency', v_t.currency));
        v_alerts := v_alerts + 1;
      END IF;
      CONTINUE;
    END IF;
    IF v_t.status = 'success' THEN
      IF v_a.status IN ('succeeded', 'flagged') THEN
        IF v_t.amount_minor IS DISTINCT FROM COALESCE(v_a.verified_amount_minor, v_a.amount_minor) THEN
          PERFORM public._raise_payment_alert('amount_mismatch', 'critical', v_a.order_id, v_a.id, 'amount:' || v_a.id,
            format('The provider shows %s pesewas for reference %s; this system recorded %s.', v_t.amount_minor, v_t.reference, COALESCE(v_a.verified_amount_minor, v_a.amount_minor)),
            jsonb_build_object('reference', v_t.reference, 'provider_minor', v_t.amount_minor, 'ours_minor', COALESCE(v_a.verified_amount_minor, v_a.amount_minor)));
          v_alerts := v_alerts + 1;
        END IF;
      ELSIF NOT p_final THEN
        v_to_verify := v_to_verify || v_t.reference;
      ELSE
        PERFORM public._raise_payment_alert('paid_not_applied', 'critical', v_a.order_id, v_a.id, 'unapplied:' || v_a.id,
          format('The provider shows reference %s as paid but this system could not apply it (attempt is %s).', v_t.reference, v_a.status),
          jsonb_build_object('reference', v_t.reference, 'attempt_status', v_a.status));
        v_alerts := v_alerts + 1;
      END IF;
    ELSIF v_a.status = 'succeeded' AND NOT v_a.refund_required AND v_t.status IS DISTINCT FROM 'success' THEN
      PERFORM public._raise_payment_alert('status_mismatch', 'critical', v_a.order_id, v_a.id, 'status:' || v_a.id,
        format('This system has reference %s as paid but the provider shows it as %s.', v_t.reference, COALESCE(v_t.status, 'unknown')),
        jsonb_build_object('reference', v_t.reference, 'provider_status', v_t.status));
      v_alerts := v_alerts + 1;
    END IF;
  END LOOP;

  -- Ours -> provider (only when the list covers the whole window).
  IF p_complete AND p_final THEN
    FOR v_a IN
      SELECT a.id, a.order_id, a.reference FROM public.order_payment_attempts a
      WHERE a.provider = p_provider AND a.mode = p_mode AND a.status = 'succeeded' AND a.paid_at >= p_from AND a.paid_at < p_to
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_transactions) x WHERE x ->> 'reference' = a.reference)
    LOOP
      PERFORM public._raise_payment_alert('missing_at_provider', 'critical', v_a.order_id, v_a.id, 'missing:' || v_a.id,
        format('This system has reference %s as paid but it is not in the provider''s list for the period.', v_a.reference),
        jsonb_build_object('reference', v_a.reference, 'from', p_from, 'to', p_to));
      v_alerts := v_alerts + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('checked', v_checked, 'to_verify', to_jsonb(v_to_verify), 'alerts', v_alerts);
END;
$$;
REVOKE ALL ON FUNCTION public.reconcile_provider_transactions(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, JSONB, BOOLEAN, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_provider_transactions(TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, JSONB, BOOLEAN, BOOLEAN) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Platform admins
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.payment_user_is_admin(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT p_user_id IS NOT NULL AND public.has_role(p_user_id, 'admin') $$;
REVOKE ALL ON FUNCTION public.payment_user_is_admin(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_user_is_admin(UUID) TO service_role;

-- For an admin's "re-verify": the attempts of one order that could still be paid, newest first (no throttle: an admin asked).
CREATE OR REPLACE FUNCTION public.admin_attempts_to_reverify(p_admin_id UUID, p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.payment_user_is_admin(p_admin_id) THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('attempt_id', t.id, 'provider', t.provider, 'mode', t.mode, 'reference', t.reference) ORDER BY t.initiated_at DESC)
    FROM (SELECT a.id, a.provider, a.mode, a.reference, a.initiated_at FROM public.order_payment_attempts a
          WHERE a.order_id = p_order_id AND a.status <> 'succeeded' ORDER BY a.initiated_at DESC LIMIT 5) t), '[]'::JSONB);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_attempts_to_reverify(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_attempts_to_reverify(UUID, UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_payment_overview()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view payments.'; END IF;
  RETURN jsonb_build_object(
    'settings', (SELECT jsonb_build_object('enabled', s.online_enabled, 'mode', s.mode) FROM public.payments_settings s WHERE s.id),
    'counts', jsonb_build_object(
      'open_alerts', (SELECT count(*) FROM public.payment_alerts WHERE status = 'open'),
      'open_critical', (SELECT count(*) FROM public.payment_alerts WHERE status = 'open' AND severity = 'critical'),
      'refunds_required', (SELECT count(*) FROM public.order_payment_attempts WHERE refund_required),
      'awaiting_payment', (SELECT count(*) FROM public.orders WHERE payment_method::TEXT = 'paystack' AND payment_status::TEXT = 'unpaid' AND status::TEXT = 'pending'),
      'paid_24h', (SELECT count(*) FROM public.order_payment_attempts WHERE status = 'succeeded' AND paid_at > now() - interval '24 hours'),
      'paid_24h_ghs', (SELECT COALESCE(sum(amount_ghs), 0) FROM public.order_payment_attempts WHERE status = 'succeeded' AND NOT refund_required AND paid_at > now() - interval '24 hours')),
    'alerts', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.status DESC, x.created_at DESC) FROM (
      SELECT al.id, al.kind, al.severity, al.order_id, o.order_number, al.summary, al.status, al.occurrences, al.created_at, al.last_seen_at,
             al.resolved_at, al.resolution_note
      FROM public.payment_alerts al LEFT JOIN public.orders o ON o.id = al.order_id
      WHERE al.status = 'open' OR al.resolved_at > now() - interval '14 days'
      ORDER BY (al.status = 'open') DESC, al.created_at DESC LIMIT 100) x), '[]'::JSONB),
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

CREATE OR REPLACE FUNCTION public.admin_resolve_payment_alert(p_alert_id UUID, p_note TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_alert RECORD;
  v_note TEXT := btrim(COALESCE(p_note, ''));
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can resolve payment alerts.'; END IF;
  IF char_length(v_note) < 5 OR char_length(v_note) > 500 THEN RAISE EXCEPTION 'A note of 5 to 500 characters saying what was done is required.'; END IF;
  SELECT * INTO v_alert FROM public.payment_alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Alert not found.'; END IF;
  IF v_alert.status = 'resolved' THEN RETURN; END IF;
  UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolved_by = auth.uid(), resolution_note = v_note WHERE id = p_alert_id;
  PERFORM public.write_audit_log('Payment alert resolved', NULL, 'payment_alert', p_alert_id, v_alert.kind,
    jsonb_build_object('summary', v_alert.summary, 'note', v_note, 'order_id', v_alert.order_id));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_resolve_payment_alert(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_resolve_payment_alert(UUID, TEXT) TO authenticated;
