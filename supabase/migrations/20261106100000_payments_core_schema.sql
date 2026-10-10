-- Online payments (Pay Now), phase P1: the provider-neutral core. Structures and the one function that records a verified payment
-- result. Nothing here is reachable by an end user, no screen and no checkout path uses it yet, and no existing order behaves
-- differently. See docs/pay-now-paystack-plan.md (sections 4 and 5).
--
--   payment_provider_events   one row per notification a provider sent us, stored before anything else is done with it. Unique per
--                             (provider, dedupe key), so a duplicate or retried notification is recognised. Provider-neutral and
--                             shared with future subscription payments (which will have their own attempt tables, never these).
--   order_payment_attempts    one row per try to pay an order online: our unique reference, the amount asked (cedis and the provider's
--                             minor unit), the outcome the provider verified. At most ONE attempt per order can be 'succeeded'.
--   order_payment_log         append-only: every decision about a payment and why.
--   apply_payment_result()    the only thing that marks an attempt, and an order, paid. Idempotent, under the order lock, service
--                             role only. It trusts nothing it is not given by a server-side verification with the provider:
--                             the caller verifies with the provider first, then passes the verified result in.
--
-- Everything is readable by platform admins only for now (the two parties read through checked functions in P2), and written only
-- by SECURITY DEFINER functions that only the service role may call.

-- ---------------------------------------------------------------------------
-- 1. Provider notifications
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_provider_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  dedupe_key TEXT NOT NULL CHECK (char_length(dedupe_key) BETWEEN 1 AND 300),
  event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 100),
  reference TEXT,
  mode TEXT NOT NULL CHECK (mode IN ('test', 'live')),
  payload JSONB NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at TIMESTAMPTZ,
  outcome TEXT,
  error TEXT,
  UNIQUE (provider, dedupe_key)
);
CREATE INDEX IF NOT EXISTS payment_provider_events_reference_idx ON public.payment_provider_events (provider, reference);
CREATE INDEX IF NOT EXISTS payment_provider_events_unprocessed_idx ON public.payment_provider_events (received_at) WHERE processed_at IS NULL;

-- A notification is never edited or deleted; only the processing fields are filled in afterwards.
CREATE OR REPLACE FUNCTION public.payment_provider_events_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payment notifications are append-only.'; END IF;
  IF (to_jsonb(NEW) - 'processed_at' - 'outcome' - 'error') IS DISTINCT FROM (to_jsonb(OLD) - 'processed_at' - 'outcome' - 'error') THEN
    RAISE EXCEPTION 'Payment notifications are append-only.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_payment_provider_events_protect ON public.payment_provider_events;
CREATE TRIGGER trg_payment_provider_events_protect BEFORE UPDATE OR DELETE ON public.payment_provider_events
  FOR EACH ROW EXECUTE FUNCTION public.payment_provider_events_protect();

-- ---------------------------------------------------------------------------
-- 2. Attempts to pay an order online
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_payment_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  provider TEXT NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{1,30}$'),
  mode TEXT NOT NULL CHECK (mode IN ('test', 'live')),
  reference TEXT NOT NULL CHECK (reference ~ '^[A-Za-z0-9.=-]{8,100}$'),
  amount_ghs NUMERIC(12,2) NOT NULL CHECK (amount_ghs > 0),
  amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
  currency TEXT NOT NULL DEFAULT 'GHS' CHECK (currency = 'GHS'),
  status TEXT NOT NULL DEFAULT 'initiated'
    CHECK (status IN ('initiated', 'pending', 'succeeded', 'failed', 'abandoned', 'expired', 'flagged')),
  provider_status TEXT,
  verified_amount_minor BIGINT,
  channel TEXT,
  fee_minor BIGINT,
  provider_transaction_id TEXT,
  authorization_url TEXT,
  access_code TEXT,
  initiated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  initiated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_at TIMESTAMPTZ,
  paid_at TIMESTAMPTZ,
  failure_reason TEXT,
  -- Money was received that this order cannot keep (the order was cancelled or expired, was already paid, or changed): to be refunded.
  refund_required BOOLEAN NOT NULL DEFAULT FALSE,
  flag_reason TEXT,
  UNIQUE (provider, reference),
  CHECK (amount_minor = round(amount_ghs * 100)),
  CHECK (status <> 'flagged' OR flag_reason IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS order_payment_attempts_order_idx ON public.order_payment_attempts (order_id, initiated_at);
-- An order is paid once: at most one of its attempts can be the one that paid it.
CREATE UNIQUE INDEX IF NOT EXISTS order_payment_attempts_one_success ON public.order_payment_attempts (order_id) WHERE status = 'succeeded' AND refund_required = FALSE;

-- What identifies an attempt never changes.
CREATE OR REPLACE FUNCTION public.order_payment_attempts_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payment attempts are never deleted.'; END IF;
  IF NEW.order_id <> OLD.order_id OR NEW.provider <> OLD.provider OR NEW.mode <> OLD.mode OR NEW.reference <> OLD.reference
     OR NEW.amount_ghs <> OLD.amount_ghs OR NEW.amount_minor <> OLD.amount_minor OR NEW.currency <> OLD.currency
     OR NEW.initiated_at <> OLD.initiated_at THEN
    RAISE EXCEPTION 'What was asked of the provider cannot be changed.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_order_payment_attempts_protect ON public.order_payment_attempts;
CREATE TRIGGER trg_order_payment_attempts_protect BEFORE UPDATE OR DELETE ON public.order_payment_attempts
  FOR EACH ROW EXECUTE FUNCTION public.order_payment_attempts_protect();

-- ---------------------------------------------------------------------------
-- 3. The log (append-only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_payment_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  attempt_id UUID REFERENCES public.order_payment_attempts(id) ON DELETE RESTRICT,
  provider_event_id UUID REFERENCES public.payment_provider_events(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL CHECK (char_length(kind) BETWEEN 1 AND 60),
  source TEXT NOT NULL CHECK (source IN ('webhook', 'verify', 'reconcile', 'system')),
  summary TEXT NOT NULL CHECK (char_length(summary) BETWEEN 1 AND 500),
  details JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS order_payment_log_order_idx ON public.order_payment_log (order_id, created_at);
CREATE OR REPLACE FUNCTION public.order_payment_log_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'The payment log is append-only.';
END;
$$;
DROP TRIGGER IF EXISTS trg_order_payment_log_append_only ON public.order_payment_log;
CREATE TRIGGER trg_order_payment_log_append_only BEFORE UPDATE OR DELETE ON public.order_payment_log
  FOR EACH ROW EXECUTE FUNCTION public.order_payment_log_append_only();

-- ---------------------------------------------------------------------------
-- 4. Access: platform admins read; nobody else, and nobody writes directly
-- ---------------------------------------------------------------------------
ALTER TABLE public.payment_provider_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_payment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_payment_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read payment provider events" ON public.payment_provider_events;
CREATE POLICY "Admins read payment provider events" ON public.payment_provider_events FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order payment attempts" ON public.order_payment_attempts;
CREATE POLICY "Admins read order payment attempts" ON public.order_payment_attempts FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read order payment log" ON public.order_payment_log;
CREATE POLICY "Admins read order payment log" ON public.order_payment_log FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.payment_provider_events, public.order_payment_attempts, public.order_payment_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.payment_provider_events, public.order_payment_log TO authenticated;
-- The provider's access code and authorization URL are server-only: even an admin reading the table through the API does not get
-- them, so the attempts table is readable column by column, without those two.
GRANT SELECT (id, order_id, provider, mode, reference, amount_ghs, amount_minor, currency, status, provider_status, verified_amount_minor,
              channel, fee_minor, provider_transaction_id, initiated_by, initiated_at, verified_at, paid_at, failure_reason,
              refund_required, flag_reason)
  ON public.order_payment_attempts TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Helpers
-- ---------------------------------------------------------------------------
-- Cedis to the provider's minor unit (pesewas), exactly.
CREATE OR REPLACE FUNCTION public.payment_minor_from_ghs(p_amount NUMERIC)
RETURNS BIGINT
LANGUAGE sql
IMMUTABLE
AS $$ SELECT round(p_amount * 100)::BIGINT $$;
REVOKE ALL ON FUNCTION public.payment_minor_from_ghs(NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payment_minor_from_ghs(NUMERIC) TO authenticated, service_role;
