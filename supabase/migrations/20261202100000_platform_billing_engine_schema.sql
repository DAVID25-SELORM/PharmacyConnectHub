-- Platform billing, Phase 2 part 1: the schema changes the ENGINE needs. Additive and safe: the billing tables are empty in production and billing is disabled.
--   * A shadow period and a real period may start at the same moment (shadow and real are separate worlds), so the uniqueness of a period includes the shadow flag.
--   * A period's billable total can go below zero in one period when a later change lowers an order that was assessed in an earlier period, so that check goes.
--   * A fee adjustment on an order that was free has its own outcome ('free_adjustment'): no money, and it consumes no free order.
--   * Shadow free-order numbers are unique too (each simulated number is used once).
--   * billing_engine_queue: a delivery whose billing could not be calculated (it never blocks the delivery) is recorded here and retried.

ALTER TABLE public.billing_periods DROP CONSTRAINT IF EXISTS billing_periods_business_id_period_start_key;
ALTER TABLE public.billing_periods DROP CONSTRAINT IF EXISTS billing_periods_business_id_period_start_shadow_key;
ALTER TABLE public.billing_periods ADD CONSTRAINT billing_periods_business_id_period_start_shadow_key UNIQUE (business_id, period_start, shadow);
ALTER TABLE public.billing_periods DROP CONSTRAINT IF EXISTS billing_periods_billable_gmv_check;

ALTER TABLE public.order_billing_assessments DROP CONSTRAINT IF EXISTS order_billing_assessments_outcome_check;
ALTER TABLE public.order_billing_assessments ADD CONSTRAINT order_billing_assessments_outcome_check
  CHECK (outcome IN ('exempt', 'excluded', 'below_minimum', 'free_onboarding', 'free_monthly', 'chargeable', 'free_adjustment'));

CREATE UNIQUE INDEX IF NOT EXISTS order_billing_onboarding_seq_shadow_idx ON public.order_billing_assessments (grant_id, free_seq) WHERE free_source = 'onboarding' AND shadow;
CREATE UNIQUE INDEX IF NOT EXISTS order_billing_monthly_seq_shadow_idx ON public.order_billing_assessments (period_id, free_seq) WHERE free_source = 'monthly' AND shadow;

CREATE TABLE IF NOT EXISTS public.billing_engine_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  kind TEXT NOT NULL CHECK (kind IN ('assess', 'change')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error TEXT,
  last_attempt_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (order_id, kind)
);
CREATE INDEX IF NOT EXISTS billing_engine_queue_status_idx ON public.billing_engine_queue (status, created_at);

ALTER TABLE public.billing_engine_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.billing_engine_queue FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.billing_engine_queue TO authenticated;
DROP POLICY IF EXISTS "Admins read the billing queue" ON public.billing_engine_queue;
CREATE POLICY "Admins read the billing queue" ON public.billing_engine_queue FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
