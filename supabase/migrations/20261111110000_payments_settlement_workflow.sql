-- Online payments (Pay Now), phase P5 part 2: settlement and going live. Nothing changes while the settings keep their defaults (no split, no cap), except that the
-- readiness checks exist. See docs/pay-now-paystack-plan.md (section 17).
--
--   prepare_attempt_for_provider()     the LAST check before a payment is sent to the provider (server only): the per-order cap, that the supplier can receive money online,
--                                       and what the payment is split with. Written onto the attempt once. A payment is not given a checkout address without it (when a split or a cap is set).
--   begin_payout_account / finish_payout_account / admin_set_payout_account_status / admin_payout_accounts
--                                       a supplier's settlement account at the provider (an administrator's act; the full account number is never stored).
--   suppliers_ready_for_online_payment  which of these suppliers can take an online payment right now (checkout shows and enforces it).
--   payments_live_blockers / payments_readiness   what stands between the platform and live money; and the guard on payments_settings that refuses to switch live on while any
--                                       of it stands.
--   record_reconciler_run               the reconciler says it ran (so the readiness check can see the scheduler is alive).
--   _request_refund                     (replaced) a refund of a split payment is not approved automatically until a person has confirmed how Paystack takes it.
--   admin_settlement_report             per supplier: what came in, what went to the platform, what was refunded, and what should settle to the supplier.

-- ---------------------------------------------------------------------------
-- 1. Can this supplier take an online payment?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.payout_account_ready(p_wholesaler_id UUID, p_provider TEXT, p_mode TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN COALESCE((SELECT s.split_mode FROM public.payments_settings s WHERE s.id), 'none') = 'none' THEN TRUE
              ELSE EXISTS (SELECT 1 FROM public.supplier_payout_accounts a
                           WHERE a.wholesaler_id = p_wholesaler_id AND a.provider = p_provider AND a.mode = p_mode AND a.status = 'active') END
$$;
REVOKE ALL ON FUNCTION public.payout_account_ready(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payout_account_ready(UUID, TEXT, TEXT) TO service_role;

-- Checkout asks this to decide which suppliers can be paid online (it only answers about suppliers; it reveals nothing about their accounts).
CREATE OR REPLACE FUNCTION public.suppliers_ready_for_online_payment(p_wholesaler_ids UUID[])
RETURNS UUID[]
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_mode TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to continue.'; END IF;
  SELECT s.mode INTO v_mode FROM public.payments_settings s WHERE s.id;
  RETURN COALESCE((SELECT array_agg(w.id) FROM public.businesses w
                   WHERE w.id = ANY (COALESCE(p_wholesaler_ids, ARRAY[]::UUID[])) AND w.type = 'wholesaler'
                     AND public.payout_account_ready(w.id, 'paystack', COALESCE(v_mode, 'test'))), ARRAY[]::UUID[]);
END;
$$;
REVOKE ALL ON FUNCTION public.suppliers_ready_for_online_payment(UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.suppliers_ready_for_online_payment(UUID[]) TO authenticated, service_role;

-- What the screens may know (the P2 version, with the cap added).
CREATE OR REPLACE FUNCTION public.online_payments_status()
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object('enabled', COALESCE((SELECT online_enabled FROM public.payments_settings WHERE id), FALSE),
                            'mode', COALESCE((SELECT mode FROM public.payments_settings WHERE id), 'test'),
                            'max_order_ghs', (SELECT max_order_ghs FROM public.payments_settings WHERE id))
$$;
REVOKE ALL ON FUNCTION public.online_payments_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_payments_status() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The last check before the provider
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prepare_attempt_for_provider(p_attempt_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
  v_s RECORD;
  v_wholesaler UUID;
  v_code TEXT;
  v_charge BIGINT;
BEGIN
  SELECT a.id, a.order_id, a.provider, a.mode, a.status, a.amount_ghs, a.amount_minor, a.prepared_at, a.split_subaccount, a.split_charge_minor, a.split_bearer
  INTO v_a FROM public.order_payment_attempts a WHERE a.id = p_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  -- Already prepared (a retry of the same request): the same answer, nothing recomputed.
  IF v_a.prepared_at IS NOT NULL THEN
    RETURN CASE WHEN v_a.split_subaccount IS NULL THEN jsonb_build_object('split', FALSE)
                ELSE jsonb_build_object('split', TRUE, 'subaccount', v_a.split_subaccount, 'charge_minor', v_a.split_charge_minor, 'bearer', v_a.split_bearer) END;
  END IF;
  IF v_a.status <> 'initiated' THEN RAISE EXCEPTION 'This payment can no longer be started.'; END IF;
  SELECT s.split_mode, s.platform_fee_bps, s.fee_bearer, s.max_order_ghs INTO v_s FROM public.payments_settings s WHERE s.id;

  IF v_s.max_order_ghs IS NOT NULL AND v_a.amount_ghs > v_s.max_order_ghs THEN
    RAISE EXCEPTION 'This payment is above the limit for online payments (%). Please arrange another way to pay this order.', public._amendment_money(v_s.max_order_ghs);
  END IF;

  IF v_s.split_mode = 'subaccount' THEN
    SELECT o.wholesaler_id INTO v_wholesaler FROM public.orders o WHERE o.id = v_a.order_id;
    SELECT a.provider_subaccount_code INTO v_code FROM public.supplier_payout_accounts a
    WHERE a.wholesaler_id = v_wholesaler AND a.provider = v_a.provider AND a.mode = v_a.mode AND a.status = 'active';
    IF v_code IS NULL THEN RAISE EXCEPTION 'This supplier cannot receive online payments yet. Please arrange another way to pay this order.'; END IF;
    -- The platform's share, in whole pesewas, rounded down (never takes more than the rate).
    v_charge := floor(v_a.amount_minor * v_s.platform_fee_bps / 10000.0)::BIGINT;
    UPDATE public.order_payment_attempts SET split_subaccount = v_code, split_charge_minor = v_charge, split_bearer = v_s.fee_bearer, prepared_at = clock_timestamp()
    WHERE id = p_attempt_id;
    RETURN jsonb_build_object('split', TRUE, 'subaccount', v_code, 'charge_minor', v_charge, 'bearer', v_s.fee_bearer);
  END IF;

  UPDATE public.order_payment_attempts SET prepared_at = clock_timestamp() WHERE id = p_attempt_id;
  RETURN jsonb_build_object('split', FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.prepare_attempt_for_provider(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_attempt_for_provider(UUID) TO service_role;

-- The P2 function, with one added rule: while a split or a cap is set, a payment that did not pass the last check is not given a checkout address.
CREATE OR REPLACE FUNCTION public.record_attempt_authorization(p_attempt_id UUID, p_authorization_url TEXT, p_access_code TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_id UUID;
  v_prepared TIMESTAMPTZ;
  v_s RECORD;
BEGIN
  IF p_authorization_url IS NULL OR p_authorization_url !~ '^(https://|http://(127[.]0[.]0[.]1|localhost)(:[0-9]+)?/)' THEN RAISE EXCEPTION 'The provider returned no secure checkout address.'; END IF;
  SELECT a.prepared_at INTO v_prepared FROM public.order_payment_attempts a WHERE a.id = p_attempt_id;
  SELECT s.split_mode, s.max_order_ghs INTO v_s FROM public.payments_settings s WHERE s.id;
  IF v_prepared IS NULL AND (COALESCE(v_s.split_mode, 'none') <> 'none' OR v_s.max_order_ghs IS NOT NULL) THEN
    RAISE EXCEPTION 'This payment has not been checked against the platform''s limits and settlement settings.';
  END IF;
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

-- ---------------------------------------------------------------------------
-- 3. Payout accounts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.begin_payout_account(
  p_admin_id UUID, p_wholesaler_id UUID, p_mode TEXT, p_business_name TEXT, p_bank_code TEXT, p_account_last4 TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  IF NOT public.payment_user_is_admin(p_admin_id) THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  IF p_mode NOT IN ('test', 'live') THEN RAISE EXCEPTION 'Unknown payment mode.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.type = 'wholesaler') THEN RAISE EXCEPTION 'Supplier not found.'; END IF;
  -- A request that never got an answer does not block a new one for ever.
  UPDATE public.supplier_payout_accounts SET status = 'failed', failure_reason = 'No answer was recorded from the provider. Check the provider''s dashboard before trying again.'
  WHERE wholesaler_id = p_wholesaler_id AND provider = 'paystack' AND mode = p_mode AND status = 'pending' AND created_at < now() - interval '10 minutes';
  IF EXISTS (SELECT 1 FROM public.supplier_payout_accounts a WHERE a.wholesaler_id = p_wholesaler_id AND a.provider = 'paystack' AND a.mode = p_mode AND a.status IN ('pending', 'active')) THEN
    RAISE EXCEPTION 'This supplier already has a settlement account for this mode. Switch it off first to replace it.';
  END IF;
  INSERT INTO public.supplier_payout_accounts(wholesaler_id, provider, mode, business_name, settlement_bank_code, account_last4, created_by)
  VALUES (p_wholesaler_id, 'paystack', p_mode, btrim(p_business_name), p_bank_code, p_account_last4, p_admin_id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.begin_payout_account(UUID, UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.begin_payout_account(UUID, UUID, TEXT, TEXT, TEXT, TEXT) TO service_role;

CREATE OR REPLACE FUNCTION public.finish_payout_account(p_id UUID, p_subaccount_code TEXT, p_failure TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
BEGIN
  IF p_subaccount_code IS NOT NULL THEN
    UPDATE public.supplier_payout_accounts SET status = 'active', provider_subaccount_code = p_subaccount_code, failure_reason = NULL
    WHERE id = p_id AND status IN ('pending', 'failed') RETURNING status INTO v_status;
  ELSE
    UPDATE public.supplier_payout_accounts SET status = 'failed', failure_reason = left(COALESCE(NULLIF(btrim(p_failure), ''), 'The provider did not create the account.'), 500)
    WHERE id = p_id AND status = 'pending' RETURNING status INTO v_status;
  END IF;
  IF v_status IS NULL THEN RAISE EXCEPTION 'That settlement account is not waiting for an answer.'; END IF;
  RETURN v_status;
END;
$$;
REVOKE ALL ON FUNCTION public.finish_payout_account(UUID, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finish_payout_account(UUID, TEXT, TEXT) TO service_role;

-- Switch an account off (new payments for that supplier are refused; payments already made are untouched) or back on.
CREATE OR REPLACE FUNCTION public.admin_set_payout_account_status(p_admin_id UUID, p_id UUID, p_active BOOLEAN)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_a RECORD;
BEGIN
  IF NOT public.payment_user_is_admin(p_admin_id) THEN RAISE EXCEPTION 'Only platform administrators can do this.'; END IF;
  SELECT a.id, a.wholesaler_id, a.provider, a.mode, a.status, a.provider_subaccount_code INTO v_a FROM public.supplier_payout_accounts a WHERE a.id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Settlement account not found.'; END IF;
  IF p_active THEN
    IF v_a.status <> 'inactive' OR v_a.provider_subaccount_code IS NULL THEN RAISE EXCEPTION 'Only a switched-off account can be switched back on.'; END IF;
    IF EXISTS (SELECT 1 FROM public.supplier_payout_accounts x WHERE x.wholesaler_id = v_a.wholesaler_id AND x.provider = v_a.provider AND x.mode = v_a.mode AND x.status IN ('pending', 'active')) THEN
      RAISE EXCEPTION 'This supplier already has another settlement account for this mode.';
    END IF;
    UPDATE public.supplier_payout_accounts SET status = 'active' WHERE id = p_id;
    RETURN 'active';
  END IF;
  IF v_a.status NOT IN ('active', 'pending') THEN RAISE EXCEPTION 'That account is not in use.'; END IF;
  UPDATE public.supplier_payout_accounts SET status = CASE WHEN v_a.provider_subaccount_code IS NULL THEN 'failed' ELSE 'inactive' END,
         failure_reason = CASE WHEN v_a.provider_subaccount_code IS NULL THEN 'Switched off before the provider answered.' ELSE failure_reason END
  WHERE id = p_id;
  RETURN CASE WHEN v_a.provider_subaccount_code IS NULL THEN 'failed' ELSE 'inactive' END;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_set_payout_account_status(UUID, UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_payout_account_status(UUID, UUID, BOOLEAN) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_payout_accounts()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view settlement accounts.'; END IF;
  RETURN jsonb_build_object(
    'settings', (SELECT jsonb_build_object('mode', s.mode, 'split_mode', s.split_mode, 'platform_fee_bps', s.platform_fee_bps, 'fee_bearer', s.fee_bearer,
                                             'max_order_ghs', s.max_order_ghs, 'split_refunds_confirmed', s.split_refunds_confirmed)
                 FROM public.payments_settings s WHERE s.id),
    'suppliers', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'wholesaler_id', w.id, 'name', w.name,
        'accounts', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'mode', a.mode, 'status', a.status, 'business_name', a.business_name,
                                'bank_code', a.settlement_bank_code, 'last4', a.account_last4, 'failure_reason', a.failure_reason, 'created_at', a.created_at)
                                ORDER BY a.created_at DESC)
                               FROM (SELECT * FROM public.supplier_payout_accounts x WHERE x.wholesaler_id = w.id ORDER BY x.created_at DESC LIMIT 6) a), '[]'::JSONB))
        ORDER BY w.name) FROM public.businesses w WHERE w.type = 'wholesaler'), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_payout_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_payout_accounts() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The reconciler says it ran
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_reconciler_run(p_job TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_job = 'frequent' THEN UPDATE public.payments_settings SET reconciler_frequent_at = clock_timestamp() WHERE id;
  ELSIF p_job = 'daily' THEN UPDATE public.payments_settings SET reconciler_daily_at = clock_timestamp() WHERE id;
  ELSE RAISE EXCEPTION 'Unknown job.';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.record_reconciler_run(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_reconciler_run(TEXT) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. What stands between the platform and live money
-- ---------------------------------------------------------------------------
-- Each item: key, whether it must be met to go live, whether it is met, and a plain sentence.
CREATE OR REPLACE FUNCTION public.payments_live_items(s public.payments_settings)
RETURNS TABLE (item_key TEXT, blocking BOOLEAN, ok BOOLEAN, detail TEXT)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT 'split_on', TRUE, s.split_mode = 'subaccount', 'Each payment is split so the supplier''s share settles to the supplier''s own account (split mode is "subaccount").'
  UNION ALL SELECT 'cap_set', TRUE, s.max_order_ghs IS NOT NULL, 'A limit for one online payment is set (the pilot''s low cap).'
  UNION ALL SELECT 'reconciler_alive', TRUE, s.reconciler_frequent_at IS NOT NULL AND s.reconciler_frequent_at > now() - interval '30 minutes',
    'The reconciler ran in the last 30 minutes (so unpaid orders expire, payments are checked and refunds are sent).'
  UNION ALL SELECT 'live_payout_account', TRUE, EXISTS (SELECT 1 FROM public.supplier_payout_accounts a WHERE a.mode = 'live' AND a.status = 'active'),
    'At least one supplier has an active LIVE settlement account.'
  UNION ALL SELECT 'split_refunds_confirmed', TRUE, s.split_refunds_confirmed,
    'Paystack has confirmed in writing how a refund of a split payment is taken, and a person has recorded that.'
  UNION ALL SELECT 'no_critical_alerts', TRUE, NOT EXISTS (SELECT 1 FROM public.payment_alerts al WHERE al.status = 'open' AND al.severity = 'critical'),
    'There is no open critical payment alert.'
  UNION ALL SELECT 'daily_comparison_ran', FALSE, s.reconciler_daily_at IS NOT NULL AND s.reconciler_daily_at > now() - interval '26 hours',
    'The daily comparison with the provider ran in the last day.'
  UNION ALL SELECT 'no_unknown_refunds', FALSE, NOT EXISTS (SELECT 1 FROM public.order_refunds r WHERE r.status = 'unknown'),
    'No refund is in doubt (sent, but not known to have been received).'
$$;
REVOKE ALL ON FUNCTION public.payments_live_items(public.payments_settings) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payments_live_items(public.payments_settings) TO service_role;

CREATE OR REPLACE FUNCTION public.payments_readiness()
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s public.payments_settings;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view payment readiness.'; END IF;
  SELECT * INTO s FROM public.payments_settings WHERE id;
  RETURN jsonb_build_object(
    'mode', s.mode, 'online_enabled', s.online_enabled,
    'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('key', i.item_key, 'blocking', i.blocking, 'ok', i.ok, 'detail', i.detail) ORDER BY i.blocking DESC, i.ok, i.item_key)
                       FROM public.payments_live_items(s) i), '[]'::JSONB),
    'ready_for_live', NOT EXISTS (SELECT 1 FROM public.payments_live_items(s) i WHERE i.blocking AND NOT i.ok));
END;
$$;
REVOKE ALL ON FUNCTION public.payments_readiness() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payments_readiness() TO authenticated, service_role;

-- The guard: switching online payments ON in live mode needs every blocking item met. While it is on in live mode, the split and the cap cannot be removed
-- (switch online payments off first). Turning anything OFF is never blocked, and the reconciler's own timestamps never trip it.
CREATE OR REPLACE FUNCTION public.payments_settings_live_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_missing TEXT;
  v_was_live BOOLEAN := (TG_OP = 'UPDATE' AND OLD.online_enabled AND OLD.mode = 'live');
BEGIN
  IF NOT (NEW.online_enabled AND NEW.mode = 'live') THEN RETURN NEW; END IF;
  IF NOT v_was_live THEN
    SELECT string_agg(i.item_key, ', ' ORDER BY i.item_key) INTO v_missing FROM public.payments_live_items(NEW) i WHERE i.blocking AND NOT i.ok;
    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'Live payments cannot be switched on yet. Not met: %. See the readiness check on the Payments screen.', v_missing;
    END IF;
  ELSIF NEW.split_mode <> 'subaccount' OR NEW.max_order_ghs IS NULL THEN
    RAISE EXCEPTION 'While live payments are on, the split and the payment limit cannot be removed. Switch online payments off first.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_payments_settings_live_guard ON public.payments_settings;
CREATE TRIGGER trg_payments_settings_live_guard BEFORE INSERT OR UPDATE ON public.payments_settings
  FOR EACH ROW EXECUTE FUNCTION public.payments_settings_live_guard();

-- ---------------------------------------------------------------------------
-- 6. A refund of a split payment waits for a person until Paystack's behaviour is confirmed
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
  v_split_confirmed BOOLEAN;
  v_status TEXT;
BEGIN
  SELECT a.id, a.order_id, a.provider, a.mode, a.status, a.refund_required, a.verified_amount_minor, a.split_subaccount INTO v_a
  FROM public.order_payment_attempts a WHERE a.id = p_attempt_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  IF v_a.verified_amount_minor IS NULL OR NOT (v_a.status = 'succeeded' OR v_a.refund_required) THEN
    RAISE EXCEPTION 'Only a payment that was received can be refunded.';
  END IF;
  SELECT COALESCE(sum(r.amount_minor), 0) INTO v_alive FROM public.order_refunds r WHERE r.attempt_id = p_attempt_id AND r.status NOT IN ('failed', 'cancelled');
  v_amount := COALESCE(p_amount_minor, v_a.verified_amount_minor - v_alive);
  IF v_amount <= 0 THEN RETURN NULL; END IF;
  IF v_alive + v_amount > v_a.verified_amount_minor THEN RAISE EXCEPTION 'Refunds for this payment cannot add up to more than the payment received.'; END IF;
  SELECT s.auto_refunds, s.split_refunds_confirmed INTO v_auto, v_split_confirmed FROM public.payments_settings s WHERE s.id;
  v_status := CASE WHEN COALESCE(v_auto, FALSE) AND p_reason IN ('late_payment', 'double_payment', 'cancelled_after_payment', 'order_changed', 'amendment_reduction')
                        AND (v_a.split_subaccount IS NULL OR COALESCE(v_split_confirmed, FALSE))
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

-- ---------------------------------------------------------------------------
-- 7. The settlement report
-- ---------------------------------------------------------------------------
-- For comparing with the provider's settlement reports. Payments are those RECEIVED in the period; refunds are those against those payments. The "to settle" figure is
-- before the provider's own fees and is an estimate: how the provider treats refunds and fees on a split payment is confirmed by the provider's own report, not by this one.
CREATE OR REPLACE FUNCTION public.admin_settlement_report(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_mode TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Only platform administrators can view settlement.'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RAISE EXCEPTION 'Choose a period that ends after it starts.'; END IF;
  RETURN jsonb_build_object(
    'from', p_from, 'to', p_to,
    'suppliers', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.name) FROM (
      SELECT w.id AS wholesaler_id, w.name, a.mode, count(*) AS payments,
             round(sum(a.verified_amount_minor) / 100.0, 2) AS received_ghs,
             round(COALESCE(sum(a.split_charge_minor), 0) / 100.0, 2) AS platform_share_ghs,
             round(COALESCE(sum(a.verified_amount_minor) FILTER (WHERE a.split_subaccount IS NULL), 0) / 100.0, 2) AS not_split_ghs,
             round(COALESCE(sum((SELECT COALESCE(sum(r.amount_minor), 0) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded')), 0) / 100.0, 2) AS refunded_ghs,
             round((COALESCE(sum(a.verified_amount_minor), 0) - COALESCE(sum(a.split_charge_minor), 0)
                    - COALESCE(sum((SELECT COALESCE(sum(r.amount_minor), 0) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded')), 0)) / 100.0, 2) AS to_settle_ghs
      FROM public.order_payment_attempts a JOIN public.orders o ON o.id = a.order_id JOIN public.businesses w ON w.id = o.wholesaler_id
      WHERE a.status = 'succeeded' AND a.paid_at >= p_from AND a.paid_at < p_to AND (p_mode IS NULL OR a.mode = p_mode)
      GROUP BY w.id, w.name, a.mode) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_settlement_report(TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_settlement_report(TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO authenticated, service_role;
