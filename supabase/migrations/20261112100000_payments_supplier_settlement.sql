-- Online payments (Pay Now), optional gap 1: a supplier sees its OWN settlement status and what online payments have reached it. Read-only; nothing here moves money or changes
-- any other behaviour.
--
--   supplier_settlement_overview(p_wholesaler_id, p_from, p_to)   for the supplier's owner, managers and finance/accounting staff only: whether its settlement account is ready,
--       the bank's last four digits (never more), and the payments received in the period with the platform's share, refunds and what should settle. An estimate before Paystack's
--       own fees, for comparing with the supplier's Paystack settlement report. Never shows anyone else's data, a provider code or a failure reason.
CREATE OR REPLACE FUNCTION public.supplier_settlement_overview(p_wholesaler_id UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_s RECORD;
  v_account JSONB;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to continue.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.type = 'wholesaler') THEN RAISE EXCEPTION 'Supplier not found.'; END IF;
  IF NOT (EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid())
          OR (public.is_business_staff(auth.uid(), p_wholesaler_id) AND public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT IN ('owner', 'manager', 'finance', 'accountant'))) THEN
    RAISE EXCEPTION 'You do not have permission to see this supplier''s online payments.';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to - p_from > interval '400 days' THEN RAISE EXCEPTION 'Choose a period that ends after it starts (at most 400 days).'; END IF;
  SELECT s.online_enabled, s.mode, s.split_mode INTO v_s FROM public.payments_settings s WHERE s.id;

  SELECT jsonb_build_object('status', a.status, 'bank_code', a.settlement_bank_code, 'last4', a.account_last4, 'business_name', a.business_name)
  INTO v_account FROM public.supplier_payout_accounts a
  WHERE a.wholesaler_id = p_wholesaler_id AND a.provider = 'paystack' AND a.mode = v_s.mode
  ORDER BY (a.status = 'active') DESC, (a.status = 'pending') DESC, a.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'online_enabled', COALESCE(v_s.online_enabled, FALSE), 'mode', v_s.mode, 'split_mode', v_s.split_mode,
    -- ready: customers can pay this supplier online right now (no account is needed while the platform's own account takes everything, in test mode)
    'ready', public.payout_account_ready(p_wholesaler_id, 'paystack', v_s.mode),
    'account', v_account,
    'summary', (SELECT jsonb_build_object(
        'payments', count(*),
        'received_ghs', COALESCE(round(sum(a.verified_amount_minor) / 100.0, 2), 0),
        'platform_share_ghs', COALESCE(round(sum(a.split_charge_minor) / 100.0, 2), 0),
        'refunded_ghs', COALESCE(round(sum((SELECT COALESCE(sum(r.amount_minor), 0) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded')) / 100.0, 2), 0),
        'to_settle_ghs', COALESCE(round((sum(a.verified_amount_minor) - COALESCE(sum(a.split_charge_minor), 0)
            - sum((SELECT COALESCE(sum(r.amount_minor), 0) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded'))) / 100.0, 2), 0))
      FROM public.order_payment_attempts a JOIN public.orders o ON o.id = a.order_id
      WHERE o.wholesaler_id = p_wholesaler_id AND a.mode = v_s.mode AND a.status = 'succeeded' AND a.paid_at >= p_from AND a.paid_at < p_to),
    'recent', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.paid_at DESC) FROM (
        SELECT o.order_number, a.paid_at, round(a.verified_amount_minor / 100.0, 2) AS amount_ghs, round(COALESCE(a.split_charge_minor, 0) / 100.0, 2) AS platform_share_ghs,
               round((SELECT COALESCE(sum(r.amount_minor), 0) FROM public.order_refunds r WHERE r.attempt_id = a.id AND r.status = 'succeeded') / 100.0, 2) AS refunded_ghs, a.purpose
        FROM public.order_payment_attempts a JOIN public.orders o ON o.id = a.order_id
        WHERE o.wholesaler_id = p_wholesaler_id AND a.mode = v_s.mode AND a.status = 'succeeded' AND a.paid_at >= p_from AND a.paid_at < p_to
        ORDER BY a.paid_at DESC LIMIT 20) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.supplier_settlement_overview(UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.supplier_settlement_overview(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated, service_role;
