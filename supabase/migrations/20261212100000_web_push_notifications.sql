-- Opt-in Web Push subscriptions for phone and computer alerts.
CREATE TABLE IF NOT EXISTS public.push_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON public.push_subscriptions(user_id);
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_subscriptions FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_subscriptions TO authenticated;
CREATE POLICY push_subscriptions_owner ON public.push_subscriptions FOR ALL TO authenticated
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE TABLE IF NOT EXISTS public.push_notification_deliveries (
  notification_id UUID NOT NULL REFERENCES public.notifications(id) ON DELETE CASCADE,
  subscription_id UUID NOT NULL REFERENCES public.push_subscriptions(id) ON DELETE CASCADE,
  delivered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (notification_id, subscription_id)
);
REVOKE ALL ON public.push_notification_deliveries FROM PUBLIC, anon, authenticated;
