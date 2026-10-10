-- Online payments (Pay Now), phase P4b part 1: a payment can now be a TOP-UP (an extra payment for an order that is already paid, when a price change makes it cost
-- more). Nothing here changes how any order behaves by itself. See docs/pay-now-paystack-plan.md (section 16).
--
--   order_payment_attempts.purpose   'order' (the payment that pays the order, as before) or 'top_up' (an extra payment for a price increase on a paid order).
--   One paying 'order' attempt per order, as before; any number of top-ups.

ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'order';
ALTER TABLE public.order_payment_attempts DROP CONSTRAINT IF EXISTS order_payment_attempts_purpose_check;
ALTER TABLE public.order_payment_attempts ADD CONSTRAINT order_payment_attempts_purpose_check CHECK (purpose IN ('order', 'top_up'));

-- An order is paid once; top-ups are extra, so only the paying 'order' attempt is limited to one.
DROP INDEX IF EXISTS public.order_payment_attempts_one_success;
CREATE UNIQUE INDEX order_payment_attempts_one_success ON public.order_payment_attempts (order_id)
  WHERE status = 'succeeded' AND refund_required = FALSE AND purpose = 'order';

-- What an attempt is for never changes (the P1 protection, with the purpose added).
CREATE OR REPLACE FUNCTION public.order_payment_attempts_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payment attempts are never deleted.'; END IF;
  IF NEW.order_id <> OLD.order_id OR NEW.provider <> OLD.provider OR NEW.mode <> OLD.mode OR NEW.reference <> OLD.reference
     OR NEW.amount_ghs <> OLD.amount_ghs OR NEW.amount_minor <> OLD.amount_minor OR NEW.currency <> OLD.currency
     OR NEW.initiated_at <> OLD.initiated_at OR NEW.purpose <> OLD.purpose THEN
    RAISE EXCEPTION 'What was asked of the provider cannot be changed.';
  END IF;
  RETURN NEW;
END;
$$;

GRANT SELECT (purpose) ON public.order_payment_attempts TO authenticated;
