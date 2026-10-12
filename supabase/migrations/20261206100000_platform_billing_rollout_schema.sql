-- Platform billing, Phase 6 (part 1): what the rollout needs to remember.
-- Additive and inert: nothing here changes how anyone is billed. Billing stays DISABLED until an administrator uses the activation checklist (part 2).
--
--   billing_settings.enforcement          what happens to a business that is suspended for an unpaid invoice: 'none' (warnings only, the default) or 'block_new_orders'.
--   billing_settings.notifications        which billing notices are sent and how early (the in-app notification bell; nothing is emailed).
--   billing_subscriptions.past_due_since / grace_extended_until
--                                         when the business first became overdue, and a grace period an administrator granted beyond the automatic one.
--   billing_notifications_sent            one row per notice ever sent, so the same event never produces the same notice twice.
--   billing_run_status                    when the scheduled billing run last ran and what it did (monitoring: a run that stops is noticed).

ALTER TABLE public.billing_settings
  ADD COLUMN IF NOT EXISTS enforcement TEXT NOT NULL DEFAULT 'none' CHECK (enforcement IN ('none', 'block_new_orders')),
  ADD COLUMN IF NOT EXISTS notifications JSONB NOT NULL DEFAULT '{
    "invoice_issued": true, "payment_received": true, "invoice_overdue": true, "trial_ending": true, "free_orders_low": true, "grace_ending": true, "suspended": true, "restored": true,
    "trial_days_before": [7, 1], "grace_days_before": 3, "free_orders_threshold": 1}'::JSONB CHECK (jsonb_typeof(notifications) = 'object');

-- When real billing was switched on through the activation checklist (never set by anything else). The rules about not looking back apply from then.
ALTER TABLE public.billing_settings ADD COLUMN IF NOT EXISTS live_since TIMESTAMPTZ;

ALTER TABLE public.billing_subscriptions
  ADD COLUMN IF NOT EXISTS past_due_since TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS grace_extended_until TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS public.billing_notifications_sent (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id UUID REFERENCES public.businesses(id) ON DELETE RESTRICT,
  event_key TEXT NOT NULL UNIQUE CHECK (char_length(event_key) BETWEEN 3 AND 300),
  event_type TEXT NOT NULL,
  recipients INTEGER NOT NULL DEFAULT 0 CHECK (recipients >= 0),
  sent_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS billing_notifications_sent_business_idx ON public.billing_notifications_sent (business_id, sent_at DESC);

CREATE TABLE IF NOT EXISTS public.billing_run_status (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  last_run_at TIMESTAMPTZ,
  runs BIGINT NOT NULL DEFAULT 0,
  last_result JSONB NOT NULL DEFAULT '{}'::JSONB
);
INSERT INTO public.billing_run_status (id) VALUES (TRUE) ON CONFLICT (id) DO NOTHING;

-- A notice record is never deleted or rewritten; the only thing filled in afterwards is how many people it reached.
CREATE OR REPLACE FUNCTION public.billing_notifications_sent_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'recipients') = (to_jsonb(OLD) - 'recipients') THEN RETURN NEW; END IF;
  RAISE EXCEPTION 'Billing records are never changed or deleted (%). Record a correction instead.', TG_TABLE_NAME;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_notifications_sent_append_only ON public.billing_notifications_sent;
CREATE TRIGGER trg_billing_notifications_sent_append_only BEFORE UPDATE OR DELETE ON public.billing_notifications_sent FOR EACH ROW EXECUTE FUNCTION public.billing_notifications_sent_guard();

ALTER TABLE public.billing_notifications_sent ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_run_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_notifications_sent, public.billing_run_status FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_notifications_sent, public.billing_run_status TO authenticated;
DROP POLICY IF EXISTS "Admins read billing notices sent" ON public.billing_notifications_sent;
CREATE POLICY "Admins read billing notices sent" ON public.billing_notifications_sent FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
DROP POLICY IF EXISTS "Admins read the billing run status" ON public.billing_run_status;
CREATE POLICY "Admins read the billing run status" ON public.billing_run_status FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
