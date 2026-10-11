-- Online payments (Pay Now), optional gap 2: a RETURN of goods on an order paid online can now be refunded to the customer's card or mobile money. Until now a resolved return
-- only ever reached the customer statement or the credit ledger. See docs/pay-now-paystack-plan.md (section 18).
--
--   * A wholesaler who resolves a return as "refund" on an order that was PAID ONLINE now creates a REFUND REQUEST for the value of the accepted units (reason "order_return").
--     It always waits for a platform administrator's approval, even with automatic refunds on (the wholesaler decides a return, as with a delivery credit). Resolving as "credit"
--     (a statement credit), "replacement" or "none" is unchanged. Cash and credit orders are unchanged.
--   * A return refund is a separate flow from the price of the order: it does NOT count as "money already returned against the price" in the order's balance, so it can never make an
--     order look as if the pharmacy owes a top-up, and a later price change never cancels it. (order_money and the netting in orders_effective_total_money are adjusted for this.)
--   * Refunds of one payment still can never add up to more than the payment received; if the refund cannot be placed in full, resolving the return as a refund is refused with a clear
--     message (the wholesaler can resolve it as a credit instead).

ALTER TABLE public.order_refunds DROP CONSTRAINT IF EXISTS order_refunds_reason_check;
ALTER TABLE public.order_refunds ADD CONSTRAINT order_refunds_reason_check
  CHECK (reason IN ('late_payment', 'double_payment', 'cancelled_after_payment', 'order_changed', 'amendment_reduction', 'delivery_credit', 'manual', 'order_return'));

-- The P4b balance, with return refunds left out (they are not a refund of the price).
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
                     WHERE a.order_id = o.id AND a.status = 'succeeded' AND NOT a.refund_required AND r.status = 'succeeded' AND r.reason <> 'order_return'), 0)::BIGINT AS refunded,
           COALESCE((SELECT sum(r.amount_minor) FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id
                     WHERE a.order_id = o.id AND a.status = 'succeeded' AND NOT a.refund_required AND r.status NOT IN ('failed', 'cancelled') AND r.reason <> 'order_return'), 0)::BIGINT AS alive
    FROM public.orders o WHERE o.id = p_order_id
  ) t
$$;
REVOKE ALL ON FUNCTION public.order_money(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_money(UUID) TO service_role;

-- Refunds the value of a resolved return on an order paid online (called by resolve_order_return; refuses rather than refund only part of it).
CREATE OR REPLACE FUNCTION public._refund_online_return(p_return_id UUID, p_order_id UUID, p_amount_ghs NUMERIC)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unplaced BIGINT;
  v_order_number TEXT;
BEGIN
  IF p_amount_ghs IS NULL OR p_amount_ghs <= 0 OR NOT public.order_is_online(p_order_id) THEN RETURN; END IF;
  SELECT o.order_number INTO v_order_number FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  v_unplaced := public._request_order_refund(p_order_id, round(p_amount_ghs * 100)::BIGINT, 'order_return', 'return:' || p_return_id);
  IF v_unplaced > 0 THEN
    RAISE EXCEPTION 'The payment for order % has only % left that can still be refunded, which is less than this return is worth (%). Resolve it as a credit instead, or ask the platform to settle the difference.',
      v_order_number, public._amendment_money((round(p_amount_ghs * 100)::BIGINT - v_unplaced) / 100.0), public._amendment_money(p_amount_ghs);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._refund_online_return(UUID, UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
