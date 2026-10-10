-- Online payments (Pay Now), phase P2 part 3: starting a payment for an online order, and keeping an unpaid online order from being
-- accepted. Still switched off by default: begin_order_payment refuses while public.online_payments_enabled() is false.
--
--   begin_order_payment()           service role only; the caller is passed in and checked (pharmacy owner, manager or cashier). Under the
--                                   order lock: the order must be an online order, unpaid and not cancelled. Reuses a recent open attempt
--                                   for the same amount; otherwise expires the old open ones and records a new attempt (rate limited).
--   record_attempt_authorization()  stores the provider's checkout address on the attempt once the provider answered.
--   fail_payment_attempt()          marks an attempt failed when the provider could not be reached or refused to start it.
--   payment_attempts_to_check()     which attempts of an order should be asked about at the provider (the return page's verify).
--   order_payment_summary()         what either side of an order may see about its payment, without any provider secrets.
--   trg_block_accept_unpaid_online_order   a wholesaler cannot accept an online order that has not been paid (cancelling is allowed).

-- ---------------------------------------------------------------------------
-- 1. Who may pay for an order: the same people who may place it
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._payments_user_can_pay_for(p_user UUID, p_pharmacy_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.owner_id = p_user)
    OR (public.is_business_staff(p_user, p_pharmacy_id) AND public.get_staff_role(p_user, p_pharmacy_id)::TEXT IN ('owner', 'manager', 'cashier'))
  )
$$;
REVOKE ALL ON FUNCTION public._payments_user_can_pay_for(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._payments_user_can_pay_for(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Start (or resume) a payment
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.begin_order_payment(
  p_caller_id UUID,
  p_order_id UUID,
  p_provider TEXT,
  p_mode TEXT,
  p_reference TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_settings RECORD;
  v_amount NUMERIC(12,2);
  v_open RECORD;
  v_attempt_id UUID;
  v_recent INTEGER;
  v_expired INTEGER;
  v_email TEXT;
BEGIN
  IF p_caller_id IS NULL OR p_order_id IS NULL THEN RAISE EXCEPTION 'A signed-in user and an order are required.'; END IF;
  IF p_mode NOT IN ('test', 'live') THEN RAISE EXCEPTION 'Unknown payment mode.'; END IF;
  SELECT s.online_enabled, s.mode INTO v_settings FROM public.payments_settings s WHERE s.id;
  IF NOT COALESCE(v_settings.online_enabled, FALSE) THEN RAISE EXCEPTION 'Online payment is not available yet.'; END IF;
  IF v_settings.mode <> p_mode THEN RAISE EXCEPTION 'Online payment is not set up for this mode.'; END IF;

  SELECT o.id, o.order_number, o.status::TEXT AS status, o.pharmacy_id, o.wholesaler_id, o.payment_status::TEXT AS payment_status,
         o.payment_method::TEXT AS payment_method, o.total_ghs, o.effective_total_ghs
  INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public._payments_user_can_pay_for(p_caller_id, v_order.pharmacy_id) THEN
    RAISE EXCEPTION 'You do not have permission to pay for this order.';
  END IF;
  IF v_order.payment_method <> 'paystack' THEN RAISE EXCEPTION 'This order was not placed for online payment.'; END IF;
  IF v_order.status = 'cancelled' THEN RAISE EXCEPTION 'This order was cancelled and can no longer be paid.'; END IF;
  IF v_order.payment_status <> 'unpaid' THEN RAISE EXCEPTION 'This order is already paid.'; END IF;
  IF EXISTS (SELECT 1 FROM public.order_payment_attempts x WHERE x.order_id = p_order_id AND x.status = 'succeeded' AND x.refund_required = FALSE) THEN
    RAISE EXCEPTION 'This order is already paid.';
  END IF;
  v_amount := COALESCE(v_order.effective_total_ghs, v_order.total_ghs);
  IF v_amount IS NULL OR v_amount <= 0 THEN RAISE EXCEPTION 'This order has nothing to pay.'; END IF;

  -- A recent attempt that already has its checkout address, for the same amount and mode, is simply resumed.
  SELECT a.id, a.reference, a.amount_ghs, a.amount_minor, a.authorization_url INTO v_open
  FROM public.order_payment_attempts a
  WHERE a.order_id = p_order_id AND a.provider = p_provider AND a.mode = p_mode AND a.status IN ('initiated', 'pending')
    AND a.authorization_url IS NOT NULL AND a.amount_ghs = v_amount AND a.initiated_at > now() - interval '25 minutes'
  ORDER BY a.initiated_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    RETURN jsonb_build_object('reused', TRUE, 'attempt_id', v_open.id, 'reference', v_open.reference, 'amount_ghs', v_open.amount_ghs,
                              'amount_minor', v_open.amount_minor, 'authorization_url', v_open.authorization_url, 'order_number', v_order.order_number);
  END IF;

  SELECT count(*) INTO v_recent FROM public.order_payment_attempts a WHERE a.order_id = p_order_id AND a.initiated_at > now() - interval '1 hour';
  IF v_recent >= 6 THEN
    RAISE EXCEPTION 'Too many payment attempts for this order. Please wait a little before trying again.';
  END IF;

  -- Older open attempts are closed as expired. A payment that still arrives for one is verified and applied as usual.
  WITH closed AS (
    UPDATE public.order_payment_attempts SET status = 'expired'
    WHERE order_id = p_order_id AND status IN ('initiated', 'pending') RETURNING 1
  ) SELECT count(*) INTO v_expired FROM closed;

  SELECT email INTO v_email FROM auth.users WHERE id = p_caller_id;
  IF v_email IS NULL THEN RAISE EXCEPTION 'Your account has no email address, which online payment needs.'; END IF;

  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, initiated_by, initiated_at)
  VALUES (p_order_id, p_provider, p_mode, p_reference, v_amount, public.payment_minor_from_ghs(v_amount), p_caller_id, clock_timestamp())
  RETURNING id INTO v_attempt_id;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (p_order_id, v_attempt_id, 'attempt_started', 'system', format('A payment of %s was started.', public._amendment_money(v_amount)),
          jsonb_build_object('reference', p_reference, 'mode', p_mode, 'closed_older_attempts', v_expired));
  RETURN jsonb_build_object('reused', FALSE, 'attempt_id', v_attempt_id, 'reference', p_reference, 'amount_ghs', v_amount,
                            'amount_minor', public.payment_minor_from_ghs(v_amount), 'email', v_email, 'order_number', v_order.order_number);
END;
$$;
REVOKE ALL ON FUNCTION public.begin_order_payment(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_order_payment(UUID, UUID, TEXT, TEXT, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. The provider answered (or did not)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_attempt_authorization(p_attempt_id UUID, p_authorization_url TEXT, p_access_code TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
BEGIN
  -- Always https; plain http only for a loopback address (the local stand-in for the provider, which the server only accepts in test mode).
  IF p_authorization_url IS NULL OR p_authorization_url !~ '^(https://|http://(127[.]0[.]0[.]1|localhost)(:[0-9]+)?/)' THEN RAISE EXCEPTION 'The provider returned no secure checkout address.'; END IF;
  UPDATE public.order_payment_attempts SET authorization_url = p_authorization_url, access_code = p_access_code
  WHERE id = p_attempt_id AND status = 'initiated' AND authorization_url IS NULL RETURNING order_id INTO v_order_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_order_id, p_attempt_id, 'attempt_authorized', 'system', 'The provider accepted the payment and gave a checkout address.', '{}'::JSONB);
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.record_attempt_authorization(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_attempt_authorization(UUID, TEXT, TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.fail_payment_attempt(p_attempt_id UUID, p_reason TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
BEGIN
  UPDATE public.order_payment_attempts SET status = 'failed', failure_reason = left(NULLIF(btrim(COALESCE(p_reason, '')), ''), 300), verified_at = now()
  WHERE id = p_attempt_id AND status = 'initiated' AND authorization_url IS NULL RETURNING order_id INTO v_order_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  INSERT INTO public.order_payment_log(order_id, attempt_id, kind, source, summary, details)
  VALUES (v_order_id, p_attempt_id, 'attempt_not_started', 'system', 'The provider could not start the payment.',
          jsonb_build_object('reason', left(COALESCE(p_reason, ''), 300)));
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.fail_payment_attempt(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fail_payment_attempt(UUID, TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Which attempts to ask the provider about (the return page)
-- ---------------------------------------------------------------------------
-- Newest first, at most three, only those that could still turn out to have been paid, and only for people on the paying side.
CREATE OR REPLACE FUNCTION public.payment_attempts_to_check(p_caller_id UUID, p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
BEGIN
  SELECT o.pharmacy_id, o.payment_status::TEXT AS payment_status INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT public._payments_user_can_pay_for(p_caller_id, v_order.pharmacy_id) THEN
    RAISE EXCEPTION 'Order not found.';
  END IF;
  RETURN jsonb_build_object('payment_status', v_order.payment_status, 'attempts', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('provider', t.provider, 'mode', t.mode, 'reference', t.reference) ORDER BY t.initiated_at DESC)
    FROM (SELECT a.provider, a.mode, a.reference, a.initiated_at FROM public.order_payment_attempts a
          WHERE a.order_id = p_order_id AND a.status IN ('initiated', 'pending', 'expired', 'abandoned', 'failed')
            AND a.initiated_at > now() - interval '24 hours'
          ORDER BY a.initiated_at DESC LIMIT 3) t), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.payment_attempts_to_check(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_attempts_to_check(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. What a screen may show about an order's payment
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
  SELECT a.status, a.initiated_at, a.failure_reason, a.channel, a.refund_required INTO v_last
  FROM public.order_payment_attempts a WHERE a.order_id = p_order_id ORDER BY a.initiated_at DESC LIMIT 1;
  RETURN jsonb_build_object(
    'online', TRUE, 'side', v_side, 'order_number', v_order.order_number, 'order_status', v_order.status, 'payment_status', v_order.payment_status,
    'amount_ghs', COALESCE(v_order.effective_total_ghs, v_order.total_ghs), 'paid_at', v_order.paid_at,
    'awaiting_payment', v_order.payment_status = 'unpaid' AND v_order.status <> 'cancelled',
    'last_attempt', CASE WHEN v_last.status IS NULL THEN NULL ELSE jsonb_build_object(
      'status', v_last.status, 'at', v_last.initiated_at, 'reason', CASE WHEN v_side = 'pharmacy' THEN v_last.failure_reason ELSE NULL END,
      'channel', v_last.channel) END,
    'refund_required', COALESCE((SELECT bool_or(a.refund_required) FROM public.order_payment_attempts a WHERE a.order_id = p_order_id), FALSE));
END;
$$;
REVOKE ALL ON FUNCTION public.order_payment_summary(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_payment_summary(UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. An unpaid online order cannot be accepted (or progressed); cancelling it is still allowed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.block_accept_unpaid_online_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.payment_method::TEXT = 'paystack' AND NEW.payment_status::TEXT <> 'paid'
     AND NEW.status::TEXT NOT IN ('pending', 'cancelled') THEN
    RAISE EXCEPTION 'This order is waiting for the pharmacy''s online payment and cannot be accepted yet.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_block_accept_unpaid_online_order ON public.orders;
CREATE TRIGGER trg_block_accept_unpaid_online_order
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.block_accept_unpaid_online_order();
