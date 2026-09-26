-- Expiry alerts for wholesaler batches.
--
-- generate_batch_expiry_alerts() looks at batches that still have stock and puts each one in its
-- current bucket: expired, within 30, within 60 or within 90 days. For every business it sends ONE
-- in-app notification per bucket covering the batches that entered that bucket since the last run.
-- A batch is only ever announced once per bucket (batch_expiry_alerts_sent), so re-running is safe
-- and a batch that gets closer to expiry produces a new, more urgent alert.
--
-- Two ways it runs:
--   1. pg_cron, daily at 06:00 UTC, when the pg_cron extension is enabled (scheduled below only if
--      the extension exists; otherwise a NOTICE is raised and nothing else changes).
--   2. refresh_my_expiry_alerts(): owners/managers trigger it for their own business when they open
--      the workspace, at most once every 6 hours. This works without any scheduler.
--
-- Recipients: business owner + active staff with the owner or manager role.

CREATE TABLE public.batch_expiry_alerts_sent (
  batch_id UUID NOT NULL REFERENCES public.product_batches(id) ON DELETE CASCADE,
  bucket TEXT NOT NULL CHECK (bucket IN ('expired', 'within_30', 'within_60', 'within_90')),
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (batch_id, bucket)
);

CREATE TABLE public.expiry_alert_runs (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  last_run_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.batch_expiry_alerts_sent ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expiry_alert_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read expiry alert log" ON public.batch_expiry_alerts_sent FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read expiry alert runs" ON public.expiry_alert_runs FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.batch_expiry_alerts_sent, public.expiry_alert_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.batch_expiry_alerts_sent, public.expiry_alert_runs TO authenticated;

-- Core generator. p_business_id NULL = every wholesaler (cron). Returns how many notifications it created.
CREATE OR REPLACE FUNCTION public.generate_batch_expiry_alerts(p_business_id UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_group RECORD;
  v_created INTEGER := 0;
  v_rows INTEGER;
  v_title TEXT;
  v_body TEXT;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS tmp_expiry_new (batch_id UUID, wholesaler_id UUID, bucket TEXT, product_name TEXT, batch_number TEXT, quantity INTEGER) ON COMMIT DROP;
  TRUNCATE tmp_expiry_new;

  INSERT INTO tmp_expiry_new
  SELECT b.id, b.wholesaler_id,
    CASE WHEN b.expiry_date < current_date THEN 'expired'
         WHEN b.expiry_date <= current_date + 30 THEN 'within_30'
         WHEN b.expiry_date <= current_date + 60 THEN 'within_60'
         ELSE 'within_90' END,
    p.name, b.batch_number, b.quantity_on_hand
  FROM public.product_batches b
  JOIN public.products p ON p.id = b.product_id
  WHERE b.quantity_on_hand > 0 AND b.expiry_date <= current_date + 90
    AND (p_business_id IS NULL OR b.wholesaler_id = p_business_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.batch_expiry_alerts_sent s
      WHERE s.batch_id = b.id AND s.bucket = CASE WHEN b.expiry_date < current_date THEN 'expired'
        WHEN b.expiry_date <= current_date + 30 THEN 'within_30' WHEN b.expiry_date <= current_date + 60 THEN 'within_60' ELSE 'within_90' END);

  FOR v_group IN
    SELECT n.wholesaler_id, n.bucket, COUNT(*) AS batches, SUM(n.quantity) AS units,
      string_agg(n.product_name || ' (' || n.batch_number || ')', ', ' ORDER BY n.product_name, n.batch_number) AS names
    FROM tmp_expiry_new n GROUP BY n.wholesaler_id, n.bucket
  LOOP
    v_title := CASE v_group.bucket
      WHEN 'expired' THEN 'Expired stock'
      WHEN 'within_30' THEN 'Stock expiring within 30 days'
      WHEN 'within_60' THEN 'Stock expiring within 60 days'
      ELSE 'Stock expiring within 90 days' END;
    v_body := v_group.batches || ' batch' || CASE WHEN v_group.batches = 1 THEN '' ELSE 'es' END || ' (' || v_group.units || ' units)'
      || CASE v_group.bucket WHEN 'expired' THEN ' ' || CASE WHEN v_group.batches = 1 THEN 'has' ELSE 'have' END || ' expired: '
                             ELSE ' ' || CASE WHEN v_group.batches = 1 THEN 'is' ELSE 'are' END || ' close to expiry: ' END
      || CASE WHEN char_length(v_group.names) > 160 THEN left(v_group.names, 157) || '...' ELSE v_group.names END;

    INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
    SELECT DISTINCT r.uid, 'expiry_alert', v_title, v_body, '/wholesaler?tab=batches',
      jsonb_build_object('business_id', v_group.wholesaler_id, 'bucket', v_group.bucket, 'batches', v_group.batches)
    FROM (
      SELECT b.owner_id AS uid FROM public.businesses b WHERE b.id = v_group.wholesaler_id
      UNION
      SELECT bs.user_id FROM public.business_staff bs
      WHERE bs.business_id = v_group.wholesaler_id AND bs.status = 'active' AND bs.role::TEXT IN ('owner', 'manager')
    ) r WHERE r.uid IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_created := v_created + v_rows;
  END LOOP;

  INSERT INTO public.batch_expiry_alerts_sent (batch_id, bucket)
  SELECT n.batch_id, n.bucket FROM tmp_expiry_new n
  ON CONFLICT DO NOTHING;

  RETURN v_created;
END;
$$;
REVOKE ALL ON FUNCTION public.generate_batch_expiry_alerts(UUID) FROM PUBLIC, anon, authenticated;

-- Owner/manager entry point for their own business, at most once every 6 hours.
CREATE OR REPLACE FUNCTION public.refresh_my_expiry_alerts(p_business_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_business_id, 'manage') THEN
    RAISE EXCEPTION 'You do not have permission to refresh expiry alerts for this business.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.type = 'wholesaler') THEN
    RAISE EXCEPTION 'Expiry alerts are only available for wholesalers.';
  END IF;

  INSERT INTO public.expiry_alert_runs (business_id, last_run_at) VALUES (p_business_id, now() - interval '1 day')
  ON CONFLICT (business_id) DO NOTHING;
  SELECT last_run_at INTO v_last FROM public.expiry_alert_runs WHERE business_id = p_business_id FOR UPDATE;
  IF v_last > now() - interval '6 hours' THEN
    RETURN 'skipped';
  END IF;
  UPDATE public.expiry_alert_runs SET last_run_at = now() WHERE business_id = p_business_id;
  RETURN 'ran:' || public.generate_batch_expiry_alerts(p_business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_my_expiry_alerts(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_my_expiry_alerts(UUID) TO authenticated;

-- Daily schedule when pg_cron is available. Failure to schedule never fails the migration.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('drugxone-batch-expiry-alerts', '0 6 * * *', 'SELECT public.generate_batch_expiry_alerts(NULL)');
  ELSE
    RAISE NOTICE 'pg_cron is not enabled: expiry alerts will only be generated when owners/managers open their workspace. Enable pg_cron in the Supabase dashboard and re-run this DO block to schedule them daily.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Could not schedule expiry alerts with pg_cron: %', SQLERRM;
END $$;
