-- Online payments (Pay Now), phase P3 part 1: what operating it needs. Alerts for anything a person must look at, and when each payment attempt was last
-- checked with the provider. Nothing here changes how any order behaves by itself; see docs/pay-now-paystack-plan.md (section 14).
--
--   payment_alerts   one row per thing that needs attention (a payment that could not be applied, money to refund, a difference found by the daily
--                    comparison, a provider that cannot be reached). Written only by server functions; platform admins read them and mark them resolved.
--   order_payment_attempts.last_checked_at / check_count   when the provider was last asked about the attempt (the return page and the reconciler both
--                    set it once the provider has answered): used to space the reconciler's checks, to throttle the return page, and to refuse to expire an order whose attempts have
--                    not been checked recently.

ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS last_checked_at TIMESTAMPTZ;
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS check_count INTEGER NOT NULL DEFAULT 0;
-- When the return page last asked to check (only to throttle it; unlike last_checked_at it says nothing about what the provider answered).
ALTER TABLE public.order_payment_attempts ADD COLUMN IF NOT EXISTS check_requested_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS order_payment_attempts_open_idx ON public.order_payment_attempts (initiated_at) WHERE status IN ('initiated', 'pending');

CREATE TABLE IF NOT EXISTS public.payment_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind TEXT NOT NULL CHECK (kind IN ('flagged_payment', 'refund_required', 'paid_not_applied', 'unknown_at_provider', 'missing_at_provider',
                                     'status_mismatch', 'amount_mismatch', 'provider_unreachable', 'expiry_blocked')),
  severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  order_id UUID REFERENCES public.orders(id) ON DELETE RESTRICT,
  attempt_id UUID REFERENCES public.order_payment_attempts(id) ON DELETE RESTRICT,
  dedupe_key TEXT NOT NULL CHECK (char_length(dedupe_key) BETWEEN 1 AND 200),
  summary TEXT NOT NULL CHECK (char_length(summary) BETWEEN 1 AND 500),
  details JSONB NOT NULL DEFAULT '{}'::JSONB,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  occurrences INTEGER NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution_note TEXT CHECK (resolution_note IS NULL OR char_length(resolution_note) <= 500),
  CHECK ((status = 'open') = (resolved_at IS NULL))
);
-- At most one OPEN alert per thing; a resolved one that comes back opens a new row.
CREATE UNIQUE INDEX IF NOT EXISTS payment_alerts_one_open ON public.payment_alerts (dedupe_key) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS payment_alerts_status_idx ON public.payment_alerts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS payment_alerts_order_idx ON public.payment_alerts (order_id);

-- What happened is never rewritten: only the "seen again" and "resolved" fields move, and an alert is never deleted.
CREATE OR REPLACE FUNCTION public.payment_alerts_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Payment alerts are never deleted.'; END IF;
  IF (to_jsonb(NEW) - 'occurrences' - 'last_seen_at' - 'details' - 'status' - 'resolved_at' - 'resolved_by' - 'resolution_note')
     IS DISTINCT FROM (to_jsonb(OLD) - 'occurrences' - 'last_seen_at' - 'details' - 'status' - 'resolved_at' - 'resolved_by' - 'resolution_note') THEN
    RAISE EXCEPTION 'What a payment alert says about the problem cannot be changed.';
  END IF;
  IF OLD.status = 'resolved' AND NEW.status = 'open' THEN RAISE EXCEPTION 'A resolved alert cannot be reopened; a new one is raised if the problem returns.'; END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_payment_alerts_protect ON public.payment_alerts;
CREATE TRIGGER trg_payment_alerts_protect BEFORE UPDATE OR DELETE ON public.payment_alerts
  FOR EACH ROW EXECUTE FUNCTION public.payment_alerts_protect();

ALTER TABLE public.payment_alerts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read payment alerts" ON public.payment_alerts;
CREATE POLICY "Admins read payment alerts" ON public.payment_alerts FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.payment_alerts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.payment_alerts TO authenticated;

-- The attempts table's column grant (P1) listed its columns one by one; the two new ones are readable by admins too.
GRANT SELECT (last_checked_at, check_count, check_requested_at) ON public.order_payment_attempts TO authenticated;
