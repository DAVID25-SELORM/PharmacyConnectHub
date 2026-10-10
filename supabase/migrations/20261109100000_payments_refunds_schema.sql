-- Online payments (Pay Now), phase P4a part 1: the refund ledger. Money that must go back to a customer (a payment that arrived after the order was cancelled,
-- a second payment for the same order, an order cancelled after it was paid) is recorded here, approved, sent to the provider, and followed until the provider
-- says it was returned. Nothing here changes how any order behaves by itself, and no refund is sent while there are none to send.
-- See docs/pay-now-paystack-plan.md (section 15).
--
--   order_refunds                  one row per refund: which payment attempt is being refunded, how much, why, who approved it, where it stands. Unique per
--                                  source (for example "the refund for attempt X"), so the same reason can never refund the same money twice. A refund can
--                                  never exceed what the payment attempt actually received, counting every refund still alive for it.
--   payments_settings.auto_refunds whether refunds that are not in doubt (late, double and cancelled-after-paid payments) are approved automatically.
--                                  OFF by default: until an administrator turns it on, every refund waits for an administrator's approval.

ALTER TABLE public.payments_settings ADD COLUMN IF NOT EXISTS auto_refunds BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS public.order_refunds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  attempt_id UUID NOT NULL REFERENCES public.order_payment_attempts(id) ON DELETE RESTRICT,
  provider TEXT NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  mode TEXT NOT NULL CHECK (mode IN ('test', 'live')),
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs > 0),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  reason TEXT NOT NULL CHECK (reason IN ('late_payment', 'double_payment', 'cancelled_after_payment', 'order_changed', 'amendment_reduction', 'delivery_credit', 'manual')),
  source_key TEXT NOT NULL CHECK (char_length(source_key) BETWEEN 1 AND 200),
  status TEXT NOT NULL DEFAULT 'requested'
    CHECK (status IN ('requested', 'approved', 'submitting', 'processing', 'succeeded', 'failed', 'unknown', 'cancelled')),
  method TEXT NOT NULL DEFAULT 'provider' CHECK (method IN ('provider', 'manual')),
  provider_refund_id TEXT,
  provider_status TEXT,
  failure_reason TEXT CHECK (failure_reason IS NULL OR char_length(failure_reason) <= 500),
  note TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  requested_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_key),
  CHECK (amount_minor = round(amount_ghs * 100)),
  CHECK ((status = 'succeeded') = (completed_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS order_refunds_order_idx ON public.order_refunds (order_id, created_at);
CREATE INDEX IF NOT EXISTS order_refunds_attempt_idx ON public.order_refunds (attempt_id);
CREATE INDEX IF NOT EXISTS order_refunds_open_idx ON public.order_refunds (status, created_at) WHERE status IN ('requested', 'approved', 'submitting', 'processing', 'unknown', 'failed');

-- What the refund is for never changes; it is never deleted.
CREATE OR REPLACE FUNCTION public.order_refunds_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Refunds are never deleted.'; END IF;
  IF NEW.order_id <> OLD.order_id OR NEW.attempt_id <> OLD.attempt_id OR NEW.provider <> OLD.provider OR NEW.mode <> OLD.mode
     OR NEW.amount_ghs <> OLD.amount_ghs OR NEW.amount_minor <> OLD.amount_minor OR NEW.reason <> OLD.reason OR NEW.source_key <> OLD.source_key
     OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'What a refund is for cannot be changed.';
  END IF;
  IF OLD.status = 'succeeded' AND NEW.status <> 'succeeded' THEN RAISE EXCEPTION 'A refund that succeeded cannot be undone.'; END IF;
  IF OLD.status = 'cancelled' AND NEW.status <> 'cancelled' THEN RAISE EXCEPTION 'A cancelled refund cannot be revived; request a new one.'; END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_refunds_protect ON public.order_refunds;
CREATE TRIGGER trg_order_refunds_protect BEFORE UPDATE OR DELETE ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.order_refunds_protect();

-- The backstop: whatever calls it, refunds that are still alive for a payment can never add up to more than that payment received.
CREATE OR REPLACE FUNCTION public.order_refunds_cap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_received BIGINT;
  v_other BIGINT;
BEGIN
  IF NEW.status IN ('failed', 'cancelled') THEN RETURN NEW; END IF;
  SELECT COALESCE(a.verified_amount_minor, 0) INTO v_received FROM public.order_payment_attempts a WHERE a.id = NEW.attempt_id;
  SELECT COALESCE(sum(r.amount_minor), 0) INTO v_other FROM public.order_refunds r
  WHERE r.attempt_id = NEW.attempt_id AND r.id <> NEW.id AND r.status NOT IN ('failed', 'cancelled');
  IF v_other + NEW.amount_minor > v_received THEN
    RAISE EXCEPTION 'Refunds for this payment cannot add up to more than the payment received.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_refunds_cap ON public.order_refunds;
CREATE TRIGGER trg_order_refunds_cap BEFORE INSERT OR UPDATE ON public.order_refunds
  FOR EACH ROW EXECUTE FUNCTION public.order_refunds_cap();

ALTER TABLE public.order_refunds ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read order refunds" ON public.order_refunds;
CREATE POLICY "Admins read order refunds" ON public.order_refunds FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.order_refunds FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_refunds TO authenticated;

-- New kinds of alert: a refund that failed, one that is stuck or whose outcome is unknown, one the provider reports that this system did not send.
ALTER TABLE public.payment_alerts DROP CONSTRAINT IF EXISTS payment_alerts_kind_check;
ALTER TABLE public.payment_alerts ADD CONSTRAINT payment_alerts_kind_check CHECK (kind IN (
  'flagged_payment', 'refund_required', 'paid_not_applied', 'unknown_at_provider', 'missing_at_provider', 'status_mismatch', 'amount_mismatch',
  'provider_unreachable', 'expiry_blocked', 'refund_failed', 'refund_stuck', 'refund_unmatched'));
