-- Online payments (Pay Now), phase P2 part 1: the platform's own switch for online payments. Nothing changes for anyone while it is off
-- (and it is created off): checkout still refuses "Pay now", exactly as before. See docs/pay-now-paystack-plan.md.
--
--   payments_settings   a single row: whether online payments are enabled, and in which mode (test or live). The server environment
--                       (PAYMENTS_MODE and the key) is the other half: BOTH must agree before a payment can start. Changing it is a
--                       deliberate act in the SQL Editor (see docs/payments/switches/), never something a screen does.
--   online_payments_status()   what the screens may know: enabled or not, and the mode (so a test-mode banner can be shown).

CREATE TABLE IF NOT EXISTS public.payments_settings (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  online_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  mode TEXT NOT NULL DEFAULT 'test' CHECK (mode IN ('test', 'live')),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by TEXT
);
INSERT INTO public.payments_settings(id, online_enabled, mode) VALUES (TRUE, FALSE, 'test') ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.payments_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admins read payments settings" ON public.payments_settings;
CREATE POLICY "Admins read payments settings" ON public.payments_settings FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.payments_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.payments_settings TO authenticated;

CREATE OR REPLACE FUNCTION public.online_payments_enabled()
RETURNS BOOLEAN
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT COALESCE((SELECT online_enabled FROM public.payments_settings WHERE id), FALSE) $$;
REVOKE ALL ON FUNCTION public.online_payments_enabled() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_payments_enabled() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.online_payments_status()
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object('enabled', COALESCE((SELECT online_enabled FROM public.payments_settings WHERE id), FALSE),
                            'mode', COALESCE((SELECT mode FROM public.payments_settings WHERE id), 'test'))
$$;
REVOKE ALL ON FUNCTION public.online_payments_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.online_payments_status() TO authenticated, service_role;
