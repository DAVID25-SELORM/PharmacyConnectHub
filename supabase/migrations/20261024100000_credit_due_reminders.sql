-- Credit due-date reminders (in-app notifications only).
--
-- Every credit invoice that is still owed is in at most one "reminder level", derived from its due date
-- and today (credit_reminder_kind):
--     due_soon    due in 1 to 3 days
--     due_today   due today
--     overdue_1   1 to 6 days past due
--     overdue_7   7 to 29 days past due
--     overdue_30  30 or more days past due
-- An invoice is announced ONCE per level (credit_reminders_sent). It is announced again only when it
-- reaches a more urgent level, so nobody is nagged daily. Invoices are skipped when they are paid,
-- cancelled, written off or disputed (the parties are already resolving a dispute). What is "still owed"
-- is the OUTSTANDING balance, so a part-paid invoice is reminded for what is left.
--
-- Who is told, one grouped notification per business per level (not one per invoice):
--     the pharmacy   every level                          owner + active manager / accountant
--     the wholesaler overdue levels only                  owner + active manager / finance / accountant
-- These are the same people who can open Accounting (can_view_accounting). Staff in other roles are not
-- notified. Suspended staff are not notified.
--
-- When it runs:
--   1. pg_cron, daily at 07:00 UTC, when the pg_cron extension is enabled (otherwise a NOTICE is raised
--      and nothing else changes), and
--   2. refresh_my_credit_reminders(): called when a finance user opens Accounting, at most once every
--      6 hours per business, so reminders still appear without any scheduler.
-- Runs are serialised with an advisory lock, so a cron run and a page-load run can never both announce
-- the same invoice. Not built: email / SMS / WhatsApp, per-user preferences, reminders to a customer
-- on a wholesaler's behalf.

CREATE TABLE public.credit_reminders_sent (
  order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('due_soon', 'due_today', 'overdue_1', 'overdue_7', 'overdue_30')),
  sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id, kind)
);

CREATE TABLE public.credit_reminder_runs (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  last_run_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.credit_reminders_sent ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_reminder_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read credit reminder log" ON public.credit_reminders_sent FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Admins read credit reminder runs" ON public.credit_reminder_runs FOR SELECT USING (public.has_role(auth.uid(), 'admin'));
REVOKE ALL ON public.credit_reminders_sent, public.credit_reminder_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.credit_reminders_sent, public.credit_reminder_runs TO authenticated;

CREATE FUNCTION public.credit_reminder_kind(p_due_date DATE, p_today DATE DEFAULT current_date)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_due_date IS NULL THEN NULL
    WHEN p_due_date - p_today BETWEEN 1 AND 3 THEN 'due_soon'
    WHEN p_due_date = p_today THEN 'due_today'
    WHEN p_today - p_due_date BETWEEN 1 AND 6 THEN 'overdue_1'
    WHEN p_today - p_due_date BETWEEN 7 AND 29 THEN 'overdue_7'
    WHEN p_today - p_due_date >= 30 THEN 'overdue_30'
    ELSE NULL
  END
$$;
REVOKE ALL ON FUNCTION public.credit_reminder_kind(DATE, DATE) FROM PUBLIC, anon, authenticated;

-- Core generator. p_business_id NULL = every business (cron). When given, only invoices where that business
-- is the wholesaler or the pharmacy are considered, and BOTH parties of those invoices are notified (an
-- invoice is announced once, to everyone entitled to hear about it). Returns how many notifications it created.
CREATE FUNCTION public.generate_credit_reminders(p_business_id UUID DEFAULT NULL)
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
  v_roles TEXT[];
  v_link TEXT;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('drugxone-credit-reminders'));
  CREATE TEMP TABLE IF NOT EXISTS tmp_credit_reminders (
    order_id UUID, wholesaler_id UUID, pharmacy_id UUID, wholesaler_name TEXT, pharmacy_name TEXT,
    order_number TEXT, due DATE, outstanding NUMERIC, kind TEXT
  ) ON COMMIT DROP;
  TRUNCATE tmp_credit_reminders;

  INSERT INTO tmp_credit_reminders
  SELECT o.id, o.wholesaler_id, o.pharmacy_id, w.name, ph.name, o.order_number, o.credit_due_date,
    s.outstanding_ghs, public.credit_reminder_kind(o.credit_due_date, current_date)
  FROM public.orders o
  JOIN public.businesses w ON w.id = o.wholesaler_id
  JOIN public.businesses ph ON ph.id = o.pharmacy_id
  CROSS JOIN LATERAL public.credit_invoice_status(o.id) s
  WHERE o.is_credit_order AND o.status::TEXT <> 'cancelled'
    AND o.credit_due_date IS NOT NULL AND o.credit_due_date <= current_date + 3
    AND (p_business_id IS NULL OR o.wholesaler_id = p_business_id OR o.pharmacy_id = p_business_id)
    AND s.outstanding_ghs > 0 AND s.status NOT IN ('paid', 'written_off', 'disputed')
    AND public.credit_reminder_kind(o.credit_due_date, current_date) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.credit_reminders_sent x
      WHERE x.order_id = o.id AND x.kind = public.credit_reminder_kind(o.credit_due_date, current_date)
    );

  FOR v_group IN
    SELECT t.pharmacy_id AS biz, 'pharmacy'::TEXT AS side, t.kind, COUNT(*) AS n, SUM(t.outstanding) AS total,
      string_agg(t.order_number || ' (' || t.wholesaler_name || ')', ', ' ORDER BY t.due, t.order_number) AS names
    FROM tmp_credit_reminders t GROUP BY t.pharmacy_id, t.kind
    UNION ALL
    SELECT t.wholesaler_id, 'wholesaler', t.kind, COUNT(*), SUM(t.outstanding),
      string_agg(t.order_number || ' (' || t.pharmacy_name || ')', ', ' ORDER BY t.due, t.order_number)
    FROM tmp_credit_reminders t WHERE t.kind IN ('overdue_1', 'overdue_7', 'overdue_30')
    GROUP BY t.wholesaler_id, t.kind
  LOOP
    v_title := CASE v_group.side || ':' || v_group.kind
      WHEN 'pharmacy:due_soon' THEN 'Credit payments due soon'
      WHEN 'pharmacy:due_today' THEN 'Credit payments due today'
      WHEN 'pharmacy:overdue_1' THEN 'Credit payments overdue'
      WHEN 'pharmacy:overdue_7' THEN 'Credit payments overdue by 7 days or more'
      WHEN 'pharmacy:overdue_30' THEN 'Credit payments overdue by 30 days or more'
      WHEN 'wholesaler:overdue_1' THEN 'Customer credit payments overdue'
      WHEN 'wholesaler:overdue_7' THEN 'Customer credit payments overdue by 7 days or more'
      ELSE 'Customer credit payments overdue by 30 days or more' END;
    v_body := v_group.n || CASE WHEN v_group.n = 1 THEN ' invoice' ELSE ' invoices' END
      || ', GHS ' || to_char(v_group.total, 'FM999,999,990.00') || ' outstanding: '
      || CASE WHEN char_length(v_group.names) > 160 THEN left(v_group.names, 157) || '...' ELSE v_group.names END;
    v_roles := CASE v_group.side WHEN 'pharmacy' THEN ARRAY['manager', 'accountant'] ELSE ARRAY['manager', 'finance', 'accountant'] END;
    v_link := CASE v_group.side WHEN 'pharmacy' THEN '/pharmacy/accounting' ELSE '/wholesaler/accounting' END;

    INSERT INTO public.notifications (user_id, type, title, body, link, metadata)
    SELECT DISTINCT r.uid, 'credit_reminder', v_title, v_body, v_link,
      jsonb_build_object('business_id', v_group.biz, 'kind', v_group.kind, 'invoices', v_group.n)
    FROM (
      SELECT b.owner_id AS uid FROM public.businesses b WHERE b.id = v_group.biz
      UNION
      SELECT bs.user_id FROM public.business_staff bs
      WHERE bs.business_id = v_group.biz AND bs.status = 'active' AND bs.role::TEXT = ANY (v_roles)
    ) r WHERE r.uid IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_created := v_created + v_rows;
  END LOOP;

  INSERT INTO public.credit_reminders_sent (order_id, kind)
  SELECT t.order_id, t.kind FROM tmp_credit_reminders t
  ON CONFLICT DO NOTHING;

  RETURN v_created;
END;
$$;
REVOKE ALL ON FUNCTION public.generate_credit_reminders(UUID) FROM PUBLIC, anon, authenticated;

-- Finance-user entry point for their own business, at most once every 6 hours.
CREATE FUNCTION public.refresh_my_credit_reminders(p_business_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_last TIMESTAMPTZ;
BEGIN
  IF NOT public.can_view_accounting(p_business_id) THEN
    RAISE EXCEPTION 'You do not have access to these accounts.';
  END IF;

  INSERT INTO public.credit_reminder_runs (business_id, last_run_at) VALUES (p_business_id, now() - interval '1 day')
  ON CONFLICT (business_id) DO NOTHING;
  SELECT last_run_at INTO v_last FROM public.credit_reminder_runs WHERE business_id = p_business_id FOR UPDATE;
  IF v_last > now() - interval '6 hours' THEN
    RETURN 'skipped';
  END IF;
  UPDATE public.credit_reminder_runs SET last_run_at = now() WHERE business_id = p_business_id;
  RETURN 'ran:' || public.generate_credit_reminders(p_business_id);
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_my_credit_reminders(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.refresh_my_credit_reminders(UUID) TO authenticated;

-- Daily schedule when pg_cron is available. Failure to schedule never fails the migration.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('drugxone-credit-reminders', '0 7 * * *', 'SELECT public.generate_credit_reminders(NULL)');
  ELSE
    RAISE NOTICE 'pg_cron is not enabled: credit reminders will only be generated when finance users open Accounting. Enable pg_cron in the Supabase dashboard and re-run this DO block to schedule them daily.';
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Could not schedule credit reminders with pg_cron: %', SQLERRM;
END $$;
