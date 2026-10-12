-- Platform billing, Phase 4 (part 2): issuing invoices, recording payments, and reading them.
-- Needs 20261204100000_platform_billing_invoices_schema.sql. Nothing here runs by itself while billing is DISABLED or in SHADOW: invoices are issued only for REAL periods, and real
-- periods exist only while billing is ACTIVE (which cannot be switched on yet). The fee calculation is not touched, except that an invoiced period is now final: a late entry for it
-- (a delivery that is assessed after its period was invoiced, or a later change in an order's value) lands in the period that contains the moment, never in the invoiced one.

-- ---------------------------------------------------------------------------
-- 1. An invoiced period is final
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.billing_periods_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'A billing period is never deleted.'; END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.business_id <> OLD.business_id OR NEW.period_start <> OLD.period_start OR NEW.period_end <> OLD.period_end OR NEW.shadow <> OLD.shadow
       OR NEW.subscription_id IS DISTINCT FROM OLD.subscription_id OR NEW.currency <> OLD.currency THEN
      RAISE EXCEPTION 'A billing period''s business, dates and kind never change.';
    END IF;
    -- Once a real period has been invoiced or closed it is final: only how much of it is paid, and its status, may move on (never back to open).
    IF OLD.status <> 'open' AND NOT OLD.shadow THEN
      IF (NEW.subscription_amount, NEW.transaction_fees_amount, NEW.debits_amount, NEW.credits_amount, NEW.billable_gmv, NEW.eligible_orders, NEW.free_onboarding_orders, NEW.free_monthly_orders,
          NEW.chargeable_orders, NEW.fees_before_cap)
         IS DISTINCT FROM
         (OLD.subscription_amount, OLD.transaction_fees_amount, OLD.debits_amount, OLD.credits_amount, OLD.billable_gmv, OLD.eligible_orders, OLD.free_onboarding_orders, OLD.free_monthly_orders,
          OLD.chargeable_orders, OLD.fees_before_cap) THEN
        RAISE EXCEPTION 'An invoiced billing period is final: its figures cannot change. Late entries belong in the current period.';
      END IF;
      IF NEW.status = 'open' THEN RAISE EXCEPTION 'An invoiced billing period cannot be reopened.'; END IF;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
  END IF;
  IF EXISTS (SELECT 1 FROM public.billing_periods p WHERE p.business_id = NEW.business_id AND p.shadow = NEW.shadow AND p.period_start < NEW.period_end AND p.period_end > NEW.period_start) THEN
    RAISE EXCEPTION 'Billing periods for one business cannot overlap.';
  END IF;
  RETURN NEW;
END;
$$;

-- Defence in depth: no ledger entry and no assessment can be written into a real period that has been invoiced or closed.
CREATE OR REPLACE FUNCTION public.billing_period_must_be_open()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
  v_shadow BOOLEAN;
BEGIN
  IF NEW.period_id IS NULL THEN RETURN NEW; END IF;
  SELECT p.status, p.shadow INTO v_status, v_shadow FROM public.billing_periods p WHERE p.id = NEW.period_id;
  IF FOUND AND NOT v_shadow AND v_status <> 'open' THEN
    RAISE EXCEPTION 'This billing period is already invoiced or closed: new entries belong in the current period.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_billing_ledger_period_open ON public.billing_ledger_entries;
CREATE TRIGGER trg_billing_ledger_period_open BEFORE INSERT ON public.billing_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.billing_period_must_be_open();
DROP TRIGGER IF EXISTS trg_billing_assessments_period_open ON public.order_billing_assessments;
CREATE TRIGGER trg_billing_assessments_period_open BEFORE INSERT ON public.order_billing_assessments FOR EACH ROW EXECUTE FUNCTION public.billing_period_must_be_open();

CREATE OR REPLACE FUNCTION public._billing_ensure_period(p_sub public.billing_subscriptions, p_at TIMESTAMPTZ, p_shadow BOOLEAN)
RETURNS public.billing_periods
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_interval INTEGER := COALESCE((public.billing_resolve_terms(p_sub.business_id, p_sub.billing_starts_at) ->> 'billing_interval_months')::INTEGER, 1);
  b RECORD;
  v_p public.billing_periods%ROWTYPE;
  v_terms JSONB;
  v_amount NUMERIC(12,2);
  v_waived BOOLEAN;
  v_why TEXT;
BEGIN
  SELECT * INTO b FROM public.billing_period_bounds(p_sub.period_anchor_at, v_interval, p_at);
  SELECT * INTO v_p FROM public.billing_periods p WHERE p.business_id = p_sub.business_id AND p.period_start = b.period_start AND p.shadow = p_shadow;
  IF FOUND THEN
    -- A real period that has been invoiced (or closed) is final: a late entry for it lands in the period that contains now.
    IF NOT p_shadow AND v_p.status <> 'open' AND p_at < now() THEN RETURN public._billing_ensure_period(p_sub, now(), p_shadow); END IF;
    RETURN v_p;
  END IF;
  v_terms := public.billing_resolve_terms(p_sub.business_id, b.period_start);
  IF v_terms IS NULL THEN RAISE EXCEPTION 'No billing terms were in force at the start of this period.'; END IF;
  INSERT INTO public.billing_periods(business_id, subscription_id, period_start, period_end, shadow, currency)
  VALUES (p_sub.business_id, p_sub.id, b.period_start, b.period_end, p_shadow, v_terms ->> 'currency') RETURNING * INTO v_p;
  v_amount := COALESCE((v_terms ->> 'subscription_amount')::NUMERIC, 0);
  v_waived := p_sub.billing_paused OR (p_sub.trial_end IS NOT NULL AND b.period_start < p_sub.trial_end);
  v_why := CASE WHEN p_sub.billing_paused THEN 'Billing is paused' WHEN v_waived THEN 'Free trial' END;
  INSERT INTO public.billing_ledger_entries(business_id, period_id, entry_type, shadow, currency, charged_amount, source, idempotency_key, reason, metadata)
  VALUES (p_sub.business_id, v_p.id, 'subscription_charge', p_shadow, v_terms ->> 'currency', CASE WHEN v_waived THEN 0 ELSE v_amount END, 'engine',
          'sub:' || v_p.id, v_why, jsonb_build_object('plan_amount', v_amount, 'waived', v_waived, 'plan_code', v_terms ->> 'plan_code', 'plan_version', v_terms -> 'plan_version'));
  UPDATE public.billing_periods SET subscription_amount = CASE WHEN v_waived THEN 0 ELSE v_amount END WHERE id = v_p.id RETURNING * INTO v_p;
  RETURN v_p;
END;
$$;

-- Period opening now fills a month that was skipped.
CREATE OR REPLACE FUNCTION public.billing_open_periods(p_now TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_platform TEXT;
  v_sub public.billing_subscriptions%ROWTYPE;
  v_id UUID;
  v_mode TEXT;
  v_shadow BOOLEAN;
  v_at TIMESTAMPTZ;
  v_last TIMESTAMPTZ;
  v_first TIMESTAMPTZ;
  v_p public.billing_periods%ROWTYPE;
  v_before INTEGER;
  v_created INTEGER := 0;
  n INTEGER;
BEGIN
  SELECT s.mode INTO v_platform FROM public.billing_settings s WHERE s.id;
  IF COALESCE(v_platform, 'disabled') = 'disabled' THEN RETURN 0; END IF;
  FOR v_id IN SELECT s.id FROM public.billing_subscriptions s WHERE s.billing_starts_at <= p_now ORDER BY s.id LOOP
    BEGIN
      SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.id = v_id FOR UPDATE;
      v_mode := public._billing_base_mode(v_sub.billing_mode, v_platform);
      CONTINUE WHEN v_mode = 'disabled';
      v_shadow := v_mode = 'shadow';
      -- Start from the first month that has no period yet (a month can be skipped when a later month's order was assessed before the run reached it), so every month gets its subscription charge.
      SELECT min(p.period_start) INTO v_first FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow;
      IF v_first IS NULL OR v_first > v_sub.billing_starts_at THEN
        v_at := v_sub.billing_starts_at;
      ELSE
        SELECT min(p.period_end) INTO v_at FROM public.billing_periods p
        WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow
          AND NOT EXISTS (SELECT 1 FROM public.billing_periods n WHERE n.business_id = p.business_id AND n.shadow = p.shadow AND n.period_start = p.period_end);
      END IF;
      n := 0;
      WHILE v_at <= p_now AND n < 36 AND (v_sub.ended_at IS NULL OR v_at < v_sub.ended_at) LOOP
        SELECT count(*) INTO v_before FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow;
        v_p := public._billing_ensure_period(v_sub, v_at, v_shadow);
        IF (SELECT count(*) FROM public.billing_periods p WHERE p.business_id = v_sub.business_id AND p.shadow = v_shadow) > v_before THEN v_created := v_created + 1; END IF;
        v_at := v_p.period_end;
        n := n + 1;
      END LOOP;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'billing could not open periods for subscription %: %', v_id, SQLERRM;
    END;
  END LOOP;
  RETURN v_created;
END;
$$;

-- The engine checks keep their own function; billing_reconcile() (below) adds the invoice checks to them.
CREATE OR REPLACE FUNCTION public._billing_reconcile_engine()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 'delivered_order_not_assessed'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', x.order_id, 'delivered_at', x.delivered_at)) FILTER (WHERE x.rn <= 5), '[]'::JSONB)
  FROM (SELECT u.order_id, u.delivered_at, row_number() OVER () rn FROM public._billing_unassessed_orders() u) x;
  RETURN QUERY
  SELECT 'duplicate_primary_assessment'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', d.order_id, 'shadow', d.shadow, 'n', d.n)) FILTER (WHERE d.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.order_id, a.shadow, count(*) n, row_number() OVER () rn FROM public.order_billing_assessments a WHERE a.kind = 'primary' GROUP BY a.order_id, a.shadow HAVING count(*) > 1) d;
  RETURN QUERY
  SELECT 'assessment_business_differs_from_order'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('assessment_id', m.id, 'order_id', m.order_id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.id, a.order_id, row_number() OVER () rn FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id <> o.wholesaler_id) m;
  RETURN QUERY
  SELECT 'period_transaction_fees_differ_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.transaction_fees_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.transaction_fees_amount, COALESCE((SELECT sum(e.charged_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id AND e.entry_type = 'transaction_fee'), 0) l, row_number() OVER () rn
        FROM public.billing_periods p) m WHERE m.transaction_fees_amount <> m.l;
  RETURN QUERY
  SELECT 'period_credits_differ_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.credits_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.credits_amount, COALESCE((SELECT sum(e.credit_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id), 0) l, row_number() OVER () rn FROM public.billing_periods p) m WHERE m.credits_amount <> m.l;
  RETURN QUERY
  SELECT 'period_subscription_differs_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period', m.subscription_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.subscription_amount, COALESCE((SELECT sum(e.charged_amount) FROM public.billing_ledger_entries e WHERE e.period_id = p.id AND e.entry_type = 'subscription_charge'), 0) l, row_number() OVER () rn
        FROM public.billing_periods p) m WHERE m.subscription_amount <> m.l;
  RETURN QUERY
  SELECT 'period_counters_differ_from_assessments'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, row_number() OVER () rn FROM public.billing_periods p
        WHERE p.eligible_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome IN ('free_onboarding', 'free_monthly', 'chargeable'))
           OR p.free_onboarding_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'free_onboarding')
           OR p.free_monthly_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'free_monthly')
           OR p.chargeable_orders <> (SELECT count(*) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND a.outcome = 'chargeable')) m;
  RETURN QUERY
  SELECT 'assessment_charge_differs_from_ledger'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('assessment_id', m.id, 'charged', m.charged_amount, 'ledger', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT a.id, a.charged_amount,
               COALESCE((SELECT sum(e.charged_amount - e.credit_amount) FROM public.billing_ledger_entries e WHERE e.assessment_id = a.id AND e.entry_type IN ('transaction_fee', 'refund')), 0) l, row_number() OVER () rn
        FROM public.order_billing_assessments a) m WHERE m.charged_amount <> m.l;
  RETURN QUERY
  SELECT 'free_order_numbers_not_contiguous'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('scope', m.scope, 'shadow', m.shadow, 'used', m.n, 'highest', m.hi)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT COALESCE(a.grant_id::TEXT, a.period_id::TEXT) scope, a.shadow, count(*) n, max(a.free_seq) hi, row_number() OVER () rn FROM public.order_billing_assessments a
        WHERE a.free_source IS NOT NULL AND a.kind = 'primary' GROUP BY COALESCE(a.grant_id::TEXT, a.period_id::TEXT), a.shadow, a.free_source HAVING count(*) <> max(a.free_seq)) m;
  RETURN QUERY
  SELECT 'onboarding_grant_overused'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('grant_id', m.id, 'granted', m.quantity, 'used', m.n)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT g.id, g.quantity, row_number() OVER () rn, (SELECT max(c.n) FROM (SELECT count(*) n FROM public.order_billing_assessments a WHERE a.grant_id = g.id AND a.free_source = 'onboarding' GROUP BY a.shadow) c) n
        FROM public.billing_allowance_grants g) m WHERE m.n > m.quantity;
  RETURN QUERY
  SELECT 'period_fees_exceed_the_cap'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'fees', m.transaction_fees_amount, 'cap', m.cap)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.transaction_fees_amount, row_number() OVER () rn,
               (SELECT min((a.terms_snapshot ->> 'transaction_fee_cycle_cap')::NUMERIC) FROM public.order_billing_assessments a WHERE a.period_id = p.id AND a.kind = 'primary' AND (a.terms_snapshot ->> 'transaction_fee_cycle_cap') IS NOT NULL) cap
        FROM public.billing_periods p) m WHERE m.cap IS NOT NULL AND m.transaction_fees_amount > m.cap;
  RETURN QUERY
  SELECT 'billing_queue_stuck'::TEXT, 'warning'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('order_id', m.order_id, 'kind', m.kind, 'status', m.status, 'attempts', m.attempts, 'error', m.last_error)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT q.order_id, q.kind, q.status, q.attempts, q.last_error, row_number() OVER () rn FROM public.billing_engine_queue q
        WHERE q.status = 'failed' OR (q.status = 'pending' AND q.created_at < now() - interval '1 hour')) m;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_reconcile_engine() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_reconcile_engine() TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- What an invoice's status is, from what is owed, what is paid and the due date.
CREATE OR REPLACE FUNCTION public._billing_invoice_status(p_total NUMERIC, p_paid NUMERIC, p_due_at TIMESTAMPTZ, p_now TIMESTAMPTZ)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN p_paid >= p_total THEN 'paid' WHEN p_due_at < p_now THEN 'overdue' WHEN p_paid > 0 THEN 'partially_paid' ELSE 'issued' END
$$;
REVOKE ALL ON FUNCTION public._billing_invoice_status(NUMERIC, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;

-- Credit left over from closed periods whose credits were larger than their charges, minus what later invoices have already used. Derived, never stored.
CREATE OR REPLACE FUNCTION public._billing_available_credit(p_business_id UUID)
RETURNS NUMERIC
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT sum(-p.amount_due) FROM public.billing_periods p WHERE p.business_id = p_business_id AND NOT p.shadow AND p.status = 'closed' AND p.amount_due < 0), 0)
       - COALESCE((SELECT sum(i.credit_brought_forward) FROM public.billing_invoices i WHERE i.business_id = p_business_id), 0)
$$;
REVOKE ALL ON FUNCTION public._billing_available_credit(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_available_credit(UUID) TO service_role;

-- Brings an invoice and its period in line with the payments recorded for it (the payments are the truth; the paid amount and the statuses are derived). The caller holds the invoice's lock.
CREATE OR REPLACE FUNCTION public._billing_sync_invoice(p_invoice_id UUID, p_now TIMESTAMPTZ DEFAULT now())
RETURNS public.billing_invoices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_i public.billing_invoices%ROWTYPE;
  v_paid NUMERIC(12,2);
  v_status TEXT;
BEGIN
  SELECT * INTO v_i FROM public.billing_invoices i WHERE i.id = p_invoice_id;
  SELECT COALESCE(sum(CASE WHEN y.kind = 'payment' THEN y.amount ELSE -y.amount END), 0) INTO v_paid FROM public.billing_payments y WHERE y.invoice_id = p_invoice_id;
  v_status := public._billing_invoice_status(v_i.total_amount, v_paid, v_i.due_at, p_now);
  UPDATE public.billing_invoices SET amount_paid = v_paid, status = v_status,
         paid_at = CASE WHEN v_status = 'paid' THEN COALESCE(v_i.paid_at, p_now) ELSE NULL END
   WHERE id = p_invoice_id RETURNING * INTO v_i;
  UPDATE public.billing_periods SET amount_paid = v_i.amount_paid + v_i.credit_brought_forward,
         status = CASE v_i.status WHEN 'paid' THEN 'paid' WHEN 'overdue' THEN 'overdue' WHEN 'partially_paid' THEN 'partially_paid' ELSE 'invoiced' END
   WHERE id = v_i.period_id;
  RETURN v_i;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_sync_invoice(UUID, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_sync_invoice(UUID, TIMESTAMPTZ) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Issuing invoices
-- ---------------------------------------------------------------------------
-- Issues an invoice for every REAL period that ended more than the configured delay ago, once. A period with nothing to pay is closed without an invoice. Credit left over from an earlier
-- period is applied first. Each period is its own transaction block: one business's problem never stops the others. Only runs while billing is ACTIVE.
CREATE OR REPLACE FUNCTION public.billing_issue_invoices(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_set public.billing_settings%ROWTYPE;
  v_row RECORD;
  v_p public.billing_periods%ROWTYPE;
  v_sub_id UUID;
  v_b RECORD;
  v_terms JSONB;
  v_plan TEXT;
  v_due NUMERIC(12,2);
  v_bf NUMERIC(12,2);
  v_n BIGINT;
  v_inv public.billing_invoices%ROWTYPE;
  v_line INTEGER;
  v_label TEXT;
  v_sum NUMERIC(12,2);
  v_rest NUMERIC(12,2);
  v_cnt INTEGER;
  e RECORD;
  v_issued INTEGER := 0;
  v_closed INTEGER := 0;
  v_failed INTEGER := 0;
BEGIN
  SELECT * INTO v_set FROM public.billing_settings s WHERE s.id;
  IF v_set.mode <> 'active' THEN RETURN jsonb_build_object('skipped', 'not_active'); END IF;
  FOR v_row IN SELECT p.id, p.business_id FROM public.billing_periods p
               WHERE NOT p.shadow AND p.status = 'open' AND p.period_end <= p_now - make_interval(hours => v_set.invoice_delay_hours)
               ORDER BY p.period_end, p.id LIMIT 500 LOOP
    BEGIN
      -- The same lock order as the engine: the subscription, then the period. An assessment racing this waits, then lands in the current period (the guard below refuses this one).
      SELECT s.id INTO v_sub_id FROM public.billing_subscriptions s WHERE s.business_id = v_row.business_id FOR UPDATE;
      SELECT * INTO v_p FROM public.billing_periods p WHERE p.id = v_row.id FOR UPDATE;
      CONTINUE WHEN v_p.status <> 'open';
      v_due := v_p.subscription_amount + v_p.transaction_fees_amount + v_p.debits_amount - v_p.credits_amount;
      IF v_due <= 0 THEN
        UPDATE public.billing_periods SET status = 'closed' WHERE id = v_p.id;
        v_closed := v_closed + 1;
        CONTINUE;
      END IF;
      SELECT bz.id, bz.name, bz.type::TEXT AS type, bz.license_number, bz.address, bz.city, bz.region, bz.phone, bz.public_email INTO v_b FROM public.businesses bz WHERE bz.id = v_p.business_id;
      v_terms := public.billing_resolve_terms(v_p.business_id, v_p.period_start);
      SELECT pl.name INTO v_plan FROM public.billing_plans pl WHERE pl.id = (v_terms ->> 'plan_id')::UUID;
      v_bf := LEAST(GREATEST(public._billing_available_credit(v_p.business_id), 0), v_due);
      UPDATE public.billing_settings SET last_invoice_number = last_invoice_number + 1 WHERE id RETURNING last_invoice_number INTO v_n;
      v_label := to_char(v_p.period_start AT TIME ZONE v_set.timezone, 'FMDD Mon YYYY') || ' – ' || to_char((v_p.period_end AT TIME ZONE v_set.timezone) - interval '1 day', 'FMDD Mon YYYY');

      INSERT INTO public.billing_invoices(invoice_number, business_id, period_id, currency, period_start, period_end, issued_at, due_at, subscription_amount, transaction_fees_amount, debits_amount,
        credits_amount, credit_brought_forward, status, paid_at, summary, issuer, customer)
      VALUES ('DXB-' || to_char(p_now AT TIME ZONE v_set.timezone, 'YYYY') || '-' || lpad(v_n::TEXT, 6, '0'), v_p.business_id, v_p.id, v_p.currency, v_p.period_start, v_p.period_end, p_now,
        p_now + make_interval(days => v_set.payment_terms_days), v_p.subscription_amount, v_p.transaction_fees_amount, v_p.debits_amount, v_p.credits_amount, v_bf,
        CASE WHEN v_due - v_bf = 0 THEN 'paid' ELSE 'issued' END, CASE WHEN v_due - v_bf = 0 THEN p_now END,
        jsonb_build_object('plan_name', v_plan, 'plan_code', v_terms ->> 'plan_code', 'period_label', v_label, 'business_type', v_b.type,
          'eligible_orders', CASE WHEN v_b.type = 'wholesaler' THEN v_p.eligible_orders END, 'free_onboarding_orders', CASE WHEN v_b.type = 'wholesaler' THEN v_p.free_onboarding_orders END,
          'free_monthly_orders', CASE WHEN v_b.type = 'wholesaler' THEN v_p.free_monthly_orders END, 'chargeable_orders', CASE WHEN v_b.type = 'wholesaler' THEN v_p.chargeable_orders END,
          'billable_gmv', CASE WHEN v_b.type = 'wholesaler' THEN v_p.billable_gmv END, 'fees_before_cap', CASE WHEN v_b.type = 'wholesaler' THEN v_p.fees_before_cap END,
          'transaction_fee_percentage', CASE WHEN v_b.type = 'wholesaler' THEN (v_terms ->> 'transaction_fee_percentage')::NUMERIC END,
          'transaction_fee_cycle_cap', CASE WHEN v_b.type = 'wholesaler' THEN (v_terms ->> 'transaction_fee_cycle_cap')::NUMERIC END),
        v_set.issuer,
        jsonb_build_object('business_id', v_b.id, 'name', v_b.name, 'type', v_b.type, 'license_number', v_b.license_number, 'address', v_b.address, 'city', v_b.city, 'region', v_b.region,
          'phone', v_b.phone, 'email', v_b.public_email))
      RETURNING * INTO v_inv;

      v_line := 0;
      IF v_p.subscription_amount > 0 THEN
        v_line := v_line + 1;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount, metadata)
        VALUES (v_inv.id, v_line, 'subscription', 'Subscription: ' || COALESCE(v_plan, 'plan') || ' (' || v_label || ')', v_p.subscription_amount, jsonb_build_object('plan_code', v_terms ->> 'plan_code'));
      END IF;
      IF v_p.transaction_fees_amount > 0 THEN
        v_line := v_line + 1;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount, metadata)
        VALUES (v_inv.id, v_line, 'transaction_fees',
                'Platform transaction fees (' || v_p.chargeable_orders || CASE WHEN v_p.chargeable_orders = 1 THEN ' chargeable order' ELSE ' chargeable orders' END || ' of ' || v_p.eligible_orders || ' eligible)',
                v_p.transaction_fees_amount, jsonb_build_object('eligible_orders', v_p.eligible_orders, 'chargeable_orders', v_p.chargeable_orders, 'billable_gmv', v_p.billable_gmv,
                'fees_before_cap', v_p.fees_before_cap));
      END IF;
      v_sum := 0;
      FOR e IN SELECT x.id, x.charged_amount, x.reason FROM public.billing_ledger_entries x
               WHERE x.period_id = v_p.id AND NOT x.shadow AND x.entry_type = 'manual_debit' AND x.charged_amount > 0 ORDER BY x.created_at, x.id LOOP
        v_line := v_line + 1; v_sum := v_sum + e.charged_amount;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount, metadata) VALUES (v_inv.id, v_line, 'other_charge', COALESCE(e.reason, 'Other charge'), e.charged_amount, jsonb_build_object('ledger_entry_id', e.id));
      END LOOP;
      v_rest := v_p.debits_amount - v_sum;
      IF v_rest <> 0 THEN
        v_line := v_line + 1;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount) VALUES (v_inv.id, v_line, 'other_charge', 'Other charges', v_rest);
      END IF;
      v_sum := 0;
      SELECT COALESCE(sum(x.credit_amount), 0), count(*) INTO v_rest, v_cnt FROM public.billing_ledger_entries x WHERE x.period_id = v_p.id AND NOT x.shadow AND x.entry_type = 'refund' AND x.credit_amount > 0;
      IF v_rest > 0 THEN
        v_line := v_line + 1; v_sum := v_sum + v_rest;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount, metadata)
        VALUES (v_inv.id, v_line, 'fee_credit', 'Platform fee credits: ' || v_cnt || CASE WHEN v_cnt = 1 THEN ' order' ELSE ' orders' END || ' changed in value after delivery', -v_rest, jsonb_build_object('entries', v_cnt));
      END IF;
      FOR e IN SELECT x.id, x.credit_amount, x.reason, x.entry_type FROM public.billing_ledger_entries x
               WHERE x.period_id = v_p.id AND NOT x.shadow AND x.entry_type <> 'refund' AND x.credit_amount > 0 ORDER BY x.created_at, x.id LOOP
        v_line := v_line + 1; v_sum := v_sum + e.credit_amount;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount, metadata)
        VALUES (v_inv.id, v_line, 'credit', COALESCE(e.reason, 'Credit'), -e.credit_amount, jsonb_build_object('ledger_entry_id', e.id, 'entry_type', e.entry_type));
      END LOOP;
      v_rest := v_p.credits_amount - v_sum;
      IF v_rest <> 0 THEN
        v_line := v_line + 1;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount) VALUES (v_inv.id, v_line, 'credit', 'Other credits', -v_rest);
      END IF;
      IF v_bf > 0 THEN
        v_line := v_line + 1;
        INSERT INTO public.billing_invoice_lines(invoice_id, line_no, kind, description, amount) VALUES (v_inv.id, v_line, 'credit_brought_forward', 'Credit brought forward from earlier periods', -v_bf);
      END IF;
      IF (SELECT COALESCE(sum(l.amount), 0) FROM public.billing_invoice_lines l WHERE l.invoice_id = v_inv.id) <> v_inv.total_amount THEN
        RAISE EXCEPTION 'The invoice lines do not add up to the invoice total.';
      END IF;

      PERFORM public._billing_sync_invoice(v_inv.id, p_now);
      PERFORM public.write_audit_log('Billing invoice issued', v_b.name, 'billing_invoice', v_inv.id, v_inv.invoice_number,
        jsonb_build_object('total', v_inv.total_amount, 'period_start', v_p.period_start, 'period_end', v_p.period_end, 'credit_brought_forward', v_bf),
        _performed_by => NULL, _performed_by_email => NULL, _ip_address => NULL, _business_id => v_p.business_id);
      v_issued := v_issued + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'billing could not invoice period %: %', v_row.id, SQLERRM;
    END;
  END LOOP;
  RETURN jsonb_build_object('invoices_issued', v_issued, 'periods_closed_without_invoice', v_closed, 'failed', v_failed);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_issue_invoices(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_issue_invoices(TIMESTAMPTZ) TO service_role;

-- Marks invoices that are past their due date and still owe money as overdue (and their periods). Nothing is restricted by this: grace periods and enforcement are a later phase.
CREATE OR REPLACE FUNCTION public.billing_mark_overdue(p_now TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_n INTEGER := 0;
BEGIN
  FOR v_id IN SELECT i.id FROM public.billing_invoices i WHERE i.status IN ('issued', 'partially_paid') AND i.due_at < p_now AND i.outstanding_amount > 0 ORDER BY i.due_at, i.id LOOP
    BEGIN
      PERFORM 1 FROM public.billing_invoices i WHERE i.id = v_id FOR UPDATE;
      PERFORM public._billing_sync_invoice(v_id, p_now);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'billing could not mark invoice % overdue: %', v_id, SQLERRM;
    END;
  END LOOP;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public.billing_mark_overdue(TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_mark_overdue(TIMESTAMPTZ) TO service_role;

-- The scheduled run now also issues invoices and ages unpaid ones.
CREATE OR REPLACE FUNCTION public.billing_run_scheduled(p_now TIMESTAMPTZ DEFAULT now())
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_states INTEGER;
  v_periods INTEGER;
  v_queue JSONB;
  v_catch JSONB;
  v_inv JSONB;
  v_over INTEGER;
BEGIN
  IF COALESCE((SELECT s.mode FROM public.billing_settings s WHERE s.id), 'disabled') = 'disabled' THEN RETURN jsonb_build_object('skipped', 'disabled'); END IF;
  v_states := public.billing_advance_states(p_now);
  v_periods := public.billing_open_periods(p_now);
  v_queue := public.billing_process_queue(100);
  v_catch := public.billing_catch_up(200);
  v_inv := public.billing_issue_invoices(p_now);
  v_over := public.billing_mark_overdue(p_now);
  RETURN jsonb_build_object('states_advanced', v_states, 'periods_opened', v_periods, 'queue', v_queue, 'catch_up', v_catch, 'invoices', v_inv, 'marked_overdue', v_over);
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Payments (administrator only; nothing here touches how a fee is calculated)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_billing_record_payment(
  p_invoice_id UUID, p_amount NUMERIC, p_method TEXT, p_reference TEXT, p_received_at TIMESTAMPTZ, p_note TEXT, p_reason TEXT, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_i public.billing_invoices%ROWTYPE;
  v_old public.billing_payments%ROWTYPE;
  v_pay public.billing_payments%ROWTYPE;
  v_key TEXT := COALESCE(NULLIF(btrim(p_idempotency_key), ''), 'pay:' || gen_random_uuid());
  v_name TEXT;
  v_ref TEXT := NULLIF(btrim(COALESCE(p_reference, '')), '');
BEGIN
  IF p_invoice_id IS NULL THEN RAISE EXCEPTION 'Choose the invoice this payment is for.'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN RAISE EXCEPTION 'Enter the amount received as a positive amount with at most two decimals.'; END IF;
  IF p_method IS NULL OR p_method NOT IN ('bank_transfer', 'mobile_money', 'cash', 'cheque', 'card', 'other') THEN RAISE EXCEPTION 'Choose how the payment was made.'; END IF;
  IF p_received_at IS NULL OR p_received_at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'Enter the date the payment was received (it cannot be in the future).'; END IF;
  SELECT * INTO v_i FROM public.billing_invoices i WHERE i.id = p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice not found.'; END IF;
  -- The same request sent again (a double click, a retry) returns the first answer and records nothing more.
  SELECT * INTO v_old FROM public.billing_payments y WHERE y.idempotency_key = v_key;
  IF FOUND THEN
    IF v_old.invoice_id <> p_invoice_id OR v_old.amount <> p_amount THEN RAISE EXCEPTION 'This request key was already used for a different payment.'; END IF;
    RETURN jsonb_build_object('payment_id', v_old.id, 'replayed', TRUE, 'invoice_status', v_i.status, 'outstanding', v_i.outstanding_amount);
  END IF;
  IF p_amount > v_i.outstanding_amount THEN
    RAISE EXCEPTION 'This payment is more than the balance of this invoice (% outstanding). Record at most the balance.', v_i.outstanding_amount;
  END IF;
  BEGIN
    INSERT INTO public.billing_payments(invoice_id, business_id, kind, amount, currency, method, provider, reference, received_at, note, reason, idempotency_key, recorded_by)
    VALUES (v_i.id, v_i.business_id, 'payment', p_amount, v_i.currency, p_method, 'manual', v_ref, p_received_at, NULLIF(btrim(COALESCE(p_note, '')), ''), v_reason, v_key, auth.uid())
    RETURNING * INTO v_pay;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'A payment with this reference was already recorded for this payment method.';
  END;
  v_i := public._billing_sync_invoice(v_i.id, now());
  SELECT name INTO v_name FROM public.businesses WHERE id = v_i.business_id;
  PERFORM public.write_audit_log('Billing payment recorded', v_name, 'billing_payment', v_pay.id, v_i.invoice_number,
    jsonb_build_object('amount', p_amount, 'method', p_method, 'reference', v_ref, 'received_at', p_received_at, 'reason', v_reason, 'invoice_status', v_i.status, 'outstanding', v_i.outstanding_amount),
    _business_id => v_i.business_id);
  RETURN jsonb_build_object('payment_id', v_pay.id, 'replayed', FALSE, 'invoice_status', v_i.status, 'outstanding', v_i.outstanding_amount);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_record_payment(UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_record_payment(UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_reverse_payment(p_payment_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_y public.billing_payments%ROWTYPE;
  v_i public.billing_invoices%ROWTYPE;
  v_rev public.billing_payments%ROWTYPE;
  v_name TEXT;
BEGIN
  SELECT * INTO v_y FROM public.billing_payments y WHERE y.id = p_payment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  SELECT * INTO v_i FROM public.billing_invoices i WHERE i.id = v_y.invoice_id FOR UPDATE;
  IF v_y.kind <> 'payment' THEN RAISE EXCEPTION 'Only a payment can be reversed.'; END IF;
  IF EXISTS (SELECT 1 FROM public.billing_payments r WHERE r.reverses_payment_id = v_y.id) THEN RAISE EXCEPTION 'This payment has already been reversed.'; END IF;
  INSERT INTO public.billing_payments(invoice_id, business_id, kind, amount, currency, method, provider, received_at, reason, reverses_payment_id, idempotency_key, recorded_by)
  VALUES (v_y.invoice_id, v_y.business_id, 'reversal', v_y.amount, v_y.currency, v_y.method, v_y.provider, now(), v_reason, v_y.id, 'rev:' || v_y.id, auth.uid())
  RETURNING * INTO v_rev;
  v_i := public._billing_sync_invoice(v_i.id, now());
  SELECT name INTO v_name FROM public.businesses WHERE id = v_i.business_id;
  PERFORM public.write_audit_log('Billing payment reversed', v_name, 'billing_payment', v_rev.id, v_i.invoice_number,
    jsonb_build_object('amount', v_y.amount, 'method', v_y.method, 'reference', v_y.reference, 'reverses', v_y.id, 'reason', v_reason, 'invoice_status', v_i.status, 'outstanding', v_i.outstanding_amount),
    _business_id => v_i.business_id);
  RETURN jsonb_build_object('reversal_id', v_rev.id, 'invoice_status', v_i.status, 'outstanding', v_i.outstanding_amount);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_reverse_payment(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_reverse_payment(UUID, TEXT) TO authenticated, service_role;

-- The terms of invoicing and who the invoice comes from (shown on every invoice, and copied onto it when it is issued).
CREATE OR REPLACE FUNCTION public.admin_billing_set_invoice_settings(p_payment_terms_days INTEGER, p_invoice_delay_hours INTEGER, p_issuer JSONB, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public._billing_admin_reason(p_reason);
  v_old public.billing_settings%ROWTYPE;
  v_k TEXT;
  v_issuer JSONB := '{}'::JSONB;
BEGIN
  IF p_payment_terms_days IS NULL OR p_payment_terms_days NOT BETWEEN 0 AND 120 THEN RAISE EXCEPTION 'Payment terms must be between 0 and 120 days.'; END IF;
  IF p_invoice_delay_hours IS NULL OR p_invoice_delay_hours NOT BETWEEN 0 AND 720 THEN RAISE EXCEPTION 'The invoice delay must be between 0 and 720 hours.'; END IF;
  IF p_issuer IS NULL OR jsonb_typeof(p_issuer) <> 'object' THEN RAISE EXCEPTION 'The issuer details must be an object.'; END IF;
  FOR v_k IN SELECT jsonb_object_keys(p_issuer) LOOP
    IF v_k NOT IN ('name', 'address', 'email', 'phone', 'website', 'payment_instructions', 'tax_note') THEN RAISE EXCEPTION 'Unknown issuer detail: %.', v_k; END IF;
    IF jsonb_typeof(p_issuer -> v_k) <> 'string' OR char_length(p_issuer ->> v_k) > 500 THEN RAISE EXCEPTION 'The issuer detail % must be text of at most 500 characters.', v_k; END IF;
    IF btrim(p_issuer ->> v_k) <> '' THEN v_issuer := v_issuer || jsonb_build_object(v_k, btrim(p_issuer ->> v_k)); END IF;
  END LOOP;
  IF char_length(COALESCE(v_issuer ->> 'name', '')) < 2 THEN RAISE EXCEPTION 'The issuer needs a name.'; END IF;
  SELECT * INTO v_old FROM public.billing_settings s WHERE s.id FOR UPDATE;
  UPDATE public.billing_settings SET payment_terms_days = p_payment_terms_days, invoice_delay_hours = p_invoice_delay_hours, issuer = v_issuer, updated_by = auth.uid()::TEXT WHERE id;
  PERFORM public.write_audit_log('Billing invoice settings changed', 'DrugXOne', 'billing_settings', NULL, 'Invoice settings',
    jsonb_build_object('reason', v_reason, 'before', jsonb_build_object('payment_terms_days', v_old.payment_terms_days, 'invoice_delay_hours', v_old.invoice_delay_hours, 'issuer', v_old.issuer),
                       'after', jsonb_build_object('payment_terms_days', p_payment_terms_days, 'invoice_delay_hours', p_invoice_delay_hours, 'issuer', v_issuer)));
  RETURN jsonb_build_object('payment_terms_days', p_payment_terms_days, 'invoice_delay_hours', p_invoice_delay_hours, 'issuer', v_issuer);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_set_invoice_settings(INTEGER, INTEGER, JSONB, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_set_invoice_settings(INTEGER, INTEGER, JSONB, TEXT) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Reading invoices (read-only)
-- ---------------------------------------------------------------------------
-- One invoice with its lines, payments and (for a wholesaler) the orders billed in its period. The caller has already checked who is asking.
CREATE OR REPLACE FUNCTION public._billing_invoice_json(p_invoice_id UUID, p_admin BOOLEAN)
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', i.id, 'invoice_number', i.invoice_number, 'business_id', i.business_id, 'business_name', i.customer ->> 'name', 'business_type', i.customer ->> 'type', 'currency', i.currency,
    'period_start', i.period_start, 'period_end', i.period_end, 'issued_at', i.issued_at, 'due_at', i.due_at,
    'subscription_amount', i.subscription_amount, 'transaction_fees_amount', i.transaction_fees_amount, 'debits_amount', i.debits_amount, 'credits_amount', i.credits_amount,
    'credit_brought_forward', i.credit_brought_forward, 'total_amount', i.total_amount, 'amount_paid', i.amount_paid, 'outstanding_amount', i.outstanding_amount,
    'status', i.status, 'paid_at', i.paid_at, 'summary', i.summary, 'issuer', i.issuer, 'customer', i.customer,
    'lines', COALESCE((SELECT jsonb_agg(jsonb_build_object('line_no', l.line_no, 'kind', l.kind, 'description', l.description, 'amount', l.amount) ORDER BY l.line_no)
                       FROM public.billing_invoice_lines l WHERE l.invoice_id = i.id), '[]'::JSONB),
    'payments', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', y.id, 'kind', y.kind, 'amount', y.amount, 'method', y.method, 'reference', y.reference, 'received_at', y.received_at,
                            'note', CASE WHEN p_admin THEN y.note END, 'reason', CASE WHEN y.kind = 'reversal' THEN y.reason END, 'reverses_payment_id', y.reverses_payment_id, 'recorded_at', y.recorded_at,
                            'recorded_by_email', CASE WHEN p_admin THEN (SELECT u.email FROM auth.users u WHERE u.id = y.recorded_by) END,
                            'reversed', EXISTS (SELECT 1 FROM public.billing_payments r WHERE r.reverses_payment_id = y.id)) ORDER BY y.recorded_at, y.id)
                         FROM public.billing_payments y WHERE y.invoice_id = i.id), '[]'::JSONB),
    'orders', CASE WHEN i.customer ->> 'type' <> 'wholesaler' THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.assessed_at, x.order_number) FROM (
        SELECT o.order_number, a.delivered_at, a.assessed_at, a.kind, a.adjustment_seq, a.billable_gmv, a.outcome, a.free_source, a.free_seq, a.percentage, a.fee_after_limits, a.cap_adjustment, a.charged_amount
        FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.period_id = i.period_id AND NOT a.shadow ORDER BY a.assessed_at LIMIT 500) x), '[]'::JSONB) END)
  FROM public.billing_invoices i WHERE i.id = p_invoice_id
$$;
REVOKE ALL ON FUNCTION public._billing_invoice_json(UUID, BOOLEAN) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.billing_my_invoices(p_business_id UUID, p_limit INTEGER DEFAULT 24, p_offset INTEGER DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 24), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF NOT public.billing_user_can_view(p_business_id) THEN RAISE EXCEPTION 'You do not have permission to see this business''s billing.'; END IF;
  RETURN jsonb_build_object(
    'count', (SELECT count(*) FROM public.billing_invoices i WHERE i.business_id = p_business_id),
    'outstanding_total', COALESCE((SELECT sum(i.outstanding_amount) FROM public.billing_invoices i WHERE i.business_id = p_business_id), 0),
    'overdue_total', COALESCE((SELECT sum(i.outstanding_amount) FROM public.billing_invoices i WHERE i.business_id = p_business_id AND i.status = 'overdue'), 0),
    'paid_total', COALESCE((SELECT sum(i.amount_paid) FROM public.billing_invoices i WHERE i.business_id = p_business_id), 0),
    'credit_available', GREATEST(public._billing_available_credit(p_business_id), 0),
    'invoices', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.period_start DESC, x.issued_at DESC, x.invoice_number DESC) FROM (
        SELECT i.id, i.invoice_number, i.period_start, i.period_end, i.issued_at, i.due_at, i.total_amount, i.amount_paid, i.outstanding_amount, i.status, i.currency
        FROM public.billing_invoices i WHERE i.business_id = p_business_id ORDER BY i.period_start DESC, i.issued_at DESC, i.invoice_number DESC LIMIT v_limit OFFSET v_offset) x), '[]'::JSONB),
    'payments', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.received_at DESC) FROM (
        SELECT y.id, i.invoice_number, y.kind, y.amount, y.method, y.reference, y.received_at, y.currency
        FROM public.billing_payments y JOIN public.billing_invoices i ON i.id = y.invoice_id WHERE y.business_id = p_business_id ORDER BY y.received_at DESC, y.recorded_at DESC LIMIT 50) x), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.billing_my_invoices(UUID, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_my_invoices(UUID, INTEGER, INTEGER) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.billing_my_invoice(p_invoice_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_b UUID;
BEGIN
  SELECT i.business_id INTO v_b FROM public.billing_invoices i WHERE i.id = p_invoice_id;
  IF NOT FOUND OR NOT public.billing_user_can_view(v_b) THEN RAISE EXCEPTION 'Invoice not found.'; END IF;
  RETURN public._billing_invoice_json(p_invoice_id, FALSE);
END;
$$;
REVOKE ALL ON FUNCTION public.billing_my_invoice(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.billing_my_invoice(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_invoices(
  p_status TEXT DEFAULT NULL, p_business_type TEXT DEFAULT NULL, p_search TEXT DEFAULT NULL, p_from TIMESTAMPTZ DEFAULT NULL, p_to TIMESTAMPTZ DEFAULT NULL,
  p_limit INTEGER DEFAULT 25, p_offset INTEGER DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 25), 1), 100);
  v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
  v_search TEXT := NULLIF(btrim(COALESCE(p_search, '')), '');
BEGIN
  PERFORM public._billing_admin_only();
  IF p_status IS NOT NULL AND p_status NOT IN ('issued', 'partially_paid', 'paid', 'overdue') THEN RAISE EXCEPTION 'Unknown invoice status.'; END IF;
  IF p_business_type IS NOT NULL AND p_business_type NOT IN ('pharmacy', 'wholesaler') THEN RAISE EXCEPTION 'Unknown business type.'; END IF;
  RETURN (
    WITH f AS (
      SELECT i.* FROM public.billing_invoices i
      WHERE (p_status IS NULL OR i.status = p_status) AND (p_business_type IS NULL OR i.customer ->> 'type' = p_business_type)
        AND (p_from IS NULL OR i.issued_at >= p_from) AND (p_to IS NULL OR i.issued_at < p_to)
        AND (v_search IS NULL OR i.invoice_number ILIKE '%' || v_search || '%' OR (i.customer ->> 'name') ILIKE '%' || v_search || '%'))
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM f),
      'totals', jsonb_build_object('invoiced', COALESCE((SELECT sum(total_amount) FROM f), 0), 'paid', COALESCE((SELECT sum(amount_paid) FROM f), 0),
                                   'outstanding', COALESCE((SELECT sum(outstanding_amount) FROM f), 0), 'overdue', COALESCE((SELECT sum(outstanding_amount) FROM f WHERE status = 'overdue'), 0)),
      'invoices', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.issued_at DESC, x.period_start DESC, x.invoice_number DESC) FROM (
          SELECT g.id, g.invoice_number, g.business_id, g.customer ->> 'name' AS business_name, g.customer ->> 'type' AS business_type, g.period_start, g.period_end, g.issued_at, g.due_at,
                 g.total_amount, g.amount_paid, g.outstanding_amount, g.status, g.currency
          FROM f g ORDER BY g.issued_at DESC, g.period_start DESC, g.invoice_number DESC LIMIT v_limit OFFSET v_offset) x), '[]'::JSONB)));
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_invoices(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_invoices(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTEGER, INTEGER) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_billing_invoice_detail(p_invoice_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._billing_admin_only();
  IF NOT EXISTS (SELECT 1 FROM public.billing_invoices i WHERE i.id = p_invoice_id) THEN RAISE EXCEPTION 'Invoice not found.'; END IF;
  RETURN public._billing_invoice_json(p_invoice_id, TRUE);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_billing_invoice_detail(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_billing_invoice_detail(UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Reconciliation of invoices and payments
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_reconcile_invoices()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT 'invoice_lines_differ_from_total'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number, 'total', m.total_amount, 'lines', m.l)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, i.total_amount, COALESCE((SELECT sum(l.amount) FROM public.billing_invoice_lines l WHERE l.invoice_id = i.id), 0) l, row_number() OVER () rn FROM public.billing_invoices i) m
  WHERE m.total_amount <> m.l;
  RETURN QUERY
  SELECT 'invoice_differs_from_its_period'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, row_number() OVER () rn FROM public.billing_invoices i JOIN public.billing_periods p ON p.id = i.period_id
        WHERE p.shadow OR p.business_id <> i.business_id OR p.subscription_amount <> i.subscription_amount OR p.transaction_fees_amount <> i.transaction_fees_amount
           OR p.debits_amount <> i.debits_amount OR p.credits_amount <> i.credits_amount) m;
  RETURN QUERY
  SELECT 'invoice_paid_differs_from_payments'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number, 'invoice_paid', m.amount_paid, 'payments', m.s)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, i.amount_paid, COALESCE((SELECT sum(CASE WHEN y.kind = 'payment' THEN y.amount ELSE -y.amount END) FROM public.billing_payments y WHERE y.invoice_id = i.id), 0) s, row_number() OVER () rn
        FROM public.billing_invoices i) m WHERE m.amount_paid <> m.s;
  RETURN QUERY
  SELECT 'period_paid_or_status_differs_from_invoice'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number, 'period_status', m.pstatus, 'invoice_status', m.istatus)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, p.status pstatus, i.status istatus, row_number() OVER () rn FROM public.billing_invoices i JOIN public.billing_periods p ON p.id = i.period_id
        WHERE p.amount_paid <> i.amount_paid + i.credit_brought_forward
           OR p.status <> CASE i.status WHEN 'paid' THEN 'paid' WHEN 'overdue' THEN 'overdue' WHEN 'partially_paid' THEN 'partially_paid' ELSE 'invoiced' END) m;
  RETURN QUERY
  SELECT 'payment_exceeds_invoice_or_reversal_differs'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('payment_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT y.id, row_number() OVER () rn FROM public.billing_payments y
        WHERE (y.kind = 'reversal' AND NOT EXISTS (SELECT 1 FROM public.billing_payments o WHERE o.id = y.reverses_payment_id AND o.kind = 'payment' AND o.amount = y.amount AND o.invoice_id = y.invoice_id))
           OR y.business_id <> (SELECT i.business_id FROM public.billing_invoices i WHERE i.id = y.invoice_id)
           OR (SELECT sum(CASE WHEN z.kind = 'payment' THEN z.amount ELSE -z.amount END) FROM public.billing_payments z WHERE z.invoice_id = y.invoice_id) > (SELECT i.total_amount FROM public.billing_invoices i WHERE i.id = y.invoice_id)) m;
  RETURN QUERY
  SELECT 'entries_added_to_an_invoiced_period'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number, 'entry_id', m.id)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, e.id, row_number() OVER () rn FROM public.billing_invoices i JOIN public.billing_ledger_entries e ON e.period_id = i.period_id AND e.created_at > i.issued_at) m;
  RETURN QUERY
  SELECT 'invoice_numbers_have_a_gap'::TEXT, 'critical'::TEXT, CASE WHEN c.n = s.last_invoice_number AND (c.n = 0 OR c.hi = c.n) THEN 0 ELSE 1 END, jsonb_build_object('invoices', c.n, 'counter', s.last_invoice_number, 'highest', c.hi)
  FROM (SELECT count(*) n, COALESCE(max(substring(i.invoice_number FROM '[0-9]+$')::BIGINT), 0) hi FROM public.billing_invoices i) c, public.billing_settings s WHERE s.id;
  RETURN QUERY
  SELECT 'credit_used_more_than_available'::TEXT, 'critical'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('business_id', m.business_id, 'available', m.a)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT b.business_id, public._billing_available_credit(b.business_id) a, row_number() OVER () rn FROM (SELECT DISTINCT i.business_id FROM public.billing_invoices i WHERE i.credit_brought_forward > 0) b) m WHERE m.a < 0;
  RETURN QUERY
  SELECT 'period_not_invoiced_when_it_should_be'::TEXT, 'warning'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('period_id', m.id, 'period_end', m.period_end)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT p.id, p.period_end, row_number() OVER () rn FROM public.billing_periods p, public.billing_settings s
        WHERE s.id AND s.mode = 'active' AND NOT p.shadow AND p.status = 'open' AND p.period_end < now() - make_interval(hours => s.invoice_delay_hours) - interval '2 days') m;
  RETURN QUERY
  SELECT 'invoice_overdue_but_not_marked'::TEXT, 'warning'::TEXT, count(*)::INTEGER, COALESCE(jsonb_agg(jsonb_build_object('invoice', m.invoice_number)) FILTER (WHERE m.rn <= 5), '[]'::JSONB)
  FROM (SELECT i.invoice_number, row_number() OVER () rn FROM public.billing_invoices i WHERE i.outstanding_amount > 0 AND i.status <> 'overdue' AND i.due_at < now() - interval '1 hour') m;
END;
$$;
REVOKE ALL ON FUNCTION public._billing_reconcile_invoices() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._billing_reconcile_invoices() TO service_role;

-- The reconciliation now covers invoices and payments as well as the engine.
CREATE OR REPLACE FUNCTION public.billing_reconcile()
RETURNS TABLE (check_name TEXT, severity TEXT, finding_count INTEGER, details JSONB)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM public._billing_reconcile_engine() UNION ALL SELECT * FROM public._billing_reconcile_invoices()
$$;
REVOKE ALL ON FUNCTION public.billing_reconcile() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_reconcile() TO service_role;

-- ---------------------------------------------------------------------------
-- 7. The administrator reports now show invoices, payments and the four separate money numbers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._billing_flavor_summary(p_shadow BOOLEAN, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_ids UUID[])
RETURNS JSONB
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH l AS (SELECT e.entry_type, e.charged_amount, e.credit_amount FROM public.billing_ledger_entries e WHERE e.shadow = p_shadow AND e.business_id = ANY (p_ids) AND e.created_at >= p_from AND e.created_at < p_to),
       a AS (SELECT x.kind, x.outcome, x.billable_gmv FROM public.order_billing_assessments x WHERE x.shadow = p_shadow AND x.business_id = ANY (p_ids) AND x.assessed_at >= p_from AND x.assessed_at < p_to),
       i AS (SELECT n.total_amount, n.outstanding_amount, n.status, n.issued_at FROM public.billing_invoices n WHERE NOT p_shadow AND n.business_id = ANY (p_ids)),
       y AS (SELECT CASE WHEN z.kind = 'payment' THEN z.amount ELSE -z.amount END AS amt FROM public.billing_payments z
             WHERE NOT p_shadow AND z.business_id = ANY (p_ids) AND z.received_at >= p_from AND z.received_at < p_to),
       p AS (SELECT q.amount_due FROM public.billing_periods q WHERE NOT p_shadow AND q.shadow = FALSE AND q.status = 'open' AND q.business_id = ANY (p_ids)),
       t AS (SELECT
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'subscription_charge'), 0) AS subs,
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'transaction_fee'), 0) AS fees,
               COALESCE((SELECT sum(charged_amount) FROM l WHERE entry_type = 'manual_debit'), 0) AS debits,
               COALESCE((SELECT sum(credit_amount) FROM l), 0) AS credits,
               COALESCE((SELECT sum(billable_gmv) FROM a WHERE outcome IN ('free_onboarding', 'free_monthly', 'chargeable', 'free_adjustment')), 0) AS gmv,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome IN ('free_onboarding', 'free_monthly', 'chargeable')) AS eligible,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome IN ('free_onboarding', 'free_monthly')) AS free_orders,
               (SELECT count(*) FROM a WHERE kind = 'primary' AND outcome = 'chargeable') AS chargeable)
  SELECT jsonb_build_object(
    'subscription_revenue', t.subs, 'transaction_fee_revenue', t.fees, 'other_debits', t.debits, 'credits', t.credits, 'accrued_revenue', t.subs + t.fees + t.debits - t.credits,
    'eligible_gmv', t.gmv, 'eligible_orders', t.eligible, 'free_orders', t.free_orders, 'chargeable_orders', t.chargeable,
    'free_order_share_percent', CASE WHEN t.eligible > 0 THEN round(t.free_orders * 100.0 / t.eligible, 2) END,
    'take_rate_percent', CASE WHEN t.gmv > 0 THEN round(t.fees * 100 / t.gmv, 4) END,
    -- Four different things, never one number: accrued (above), invoiced (issued in the period), collected (payments received in the period, less reversals), and what is still owed on invoices.
    'invoiced', COALESCE((SELECT sum(total_amount) FROM i WHERE issued_at >= p_from AND issued_at < p_to), 0),
    'collected', COALESCE((SELECT sum(amt) FROM y), 0),
    'outstanding', COALESCE((SELECT sum(outstanding_amount) FROM i), 0),
    'overdue', COALESCE((SELECT sum(outstanding_amount) FROM i WHERE status = 'overdue'), 0),
    'not_yet_invoiced', COALESCE((SELECT sum(amount_due) FROM p WHERE amount_due > 0), 0))
  FROM t
$$;

CREATE OR REPLACE FUNCTION public.admin_billing_business_detail(p_business_id UUID, p_flavor TEXT DEFAULT 'real')
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_shadow BOOLEAN;
  v_b RECORD;
  v_sub public.billing_subscriptions%ROWTYPE;
BEGIN
  PERFORM public._billing_admin_only();
  IF p_flavor NOT IN ('real', 'shadow') THEN RAISE EXCEPTION 'Choose real or shadow.'; END IF;
  v_shadow := p_flavor = 'shadow';
  SELECT bz.id, bz.name, bz.type::TEXT AS type, bz.license_number INTO v_b FROM public.businesses bz WHERE bz.id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.'; END IF;
  SELECT * INTO v_sub FROM public.billing_subscriptions s WHERE s.business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('business', to_jsonb(v_b), 'has_subscription', FALSE); END IF;
  RETURN jsonb_build_object(
    'business', to_jsonb(v_b), 'has_subscription', TRUE, 'flavor', p_flavor, 'effective_mode', public.billing_effective_mode(p_business_id),
    'subscription', to_jsonb(v_sub), 'terms_now', public.billing_resolve_terms(p_business_id, GREATEST(now(), v_sub.billing_starts_at)),
    'terms_history', COALESCE((SELECT jsonb_agg(jsonb_build_object('effective_from', t.effective_from, 'plan_code', pl.code, 'plan_version', v.version, 'overrides', t.overrides, 'reason', t.reason) ORDER BY t.effective_from DESC)
                               FROM public.billing_subscription_terms t JOIN public.billing_plan_versions v ON v.id = t.plan_version_id JOIN public.billing_plans pl ON pl.id = v.plan_id WHERE t.subscription_id = v_sub.id), '[]'::JSONB),
    'grants', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', g.id, 'quantity', g.quantity, 'source', g.source, 'reason', g.reason, 'created_at', g.created_at, 'expires_at', g.expires_at,
                          'used', (SELECT count(*) FROM public.order_billing_assessments a WHERE a.grant_id = g.id AND a.shadow = v_shadow)) ORDER BY g.created_at)
                        FROM public.billing_allowance_grants g WHERE g.business_id = p_business_id), '[]'::JSONB),
    'periods', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.period_start DESC) FROM (SELECT p.id, p.period_start, p.period_end, p.status, p.subscription_amount, p.transaction_fees_amount, p.debits_amount, p.credits_amount,
                          p.amount_due, p.amount_paid, p.outstanding_amount, p.billable_gmv, p.eligible_orders, p.free_onboarding_orders, p.free_monthly_orders, p.chargeable_orders, p.fees_before_cap
                          FROM public.billing_periods p WHERE p.business_id = p_business_id AND p.shadow = v_shadow ORDER BY p.period_start DESC LIMIT 24) x), '[]'::JSONB),
    'assessments', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.assessed_at DESC) FROM (SELECT o.order_number, a.assessed_at, a.delivered_at, a.kind, a.adjustment_seq, a.billable_gmv, a.outcome, a.free_source, a.free_seq,
                          a.percentage, a.calculated_fee, a.fee_after_limits, a.cap_adjustment, a.charged_amount, a.rule_version
                          FROM public.order_billing_assessments a JOIN public.orders o ON o.id = a.order_id WHERE a.business_id = p_business_id AND a.shadow = v_shadow ORDER BY a.assessed_at DESC LIMIT 50) x), '[]'::JSONB),
    'ledger', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT e.created_at, e.entry_type, e.gross_amount, e.percentage, e.calculated_fee, e.charged_amount, e.credit_amount, e.reason, e.source
                          FROM public.billing_ledger_entries e WHERE e.business_id = p_business_id AND e.shadow = v_shadow ORDER BY e.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'audit', COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) FROM (SELECT l.created_at, l.activity, l.performed_by_email, l.details
                          FROM public.audit_logs l WHERE l.business_id = p_business_id AND (l.activity LIKE 'Billing%' OR l.activity LIKE 'Order billing%') ORDER BY l.created_at DESC LIMIT 50) x), '[]'::JSONB),
    'invoices', CASE WHEN v_shadow THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.issued_at DESC) FROM (
                          SELECT i.id, i.invoice_number, i.period_start, i.period_end, i.issued_at, i.due_at, i.total_amount, i.amount_paid, i.outstanding_amount, i.status
                          FROM public.billing_invoices i WHERE i.business_id = p_business_id ORDER BY i.issued_at DESC LIMIT 24) x), '[]'::JSONB) END,
    'payments', CASE WHEN v_shadow THEN '[]'::JSONB ELSE COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.recorded_at DESC) FROM (
                          SELECT y.id, i.invoice_number, y.kind, y.amount, y.method, y.reference, y.received_at, y.recorded_at, y.reason
                          FROM public.billing_payments y JOIN public.billing_invoices i ON i.id = y.invoice_id WHERE y.business_id = p_business_id ORDER BY y.recorded_at DESC LIMIT 50) x), '[]'::JSONB) END,
    'credit_available', GREATEST(public._billing_available_credit(p_business_id), 0),
    'queue', COALESCE((SELECT jsonb_agg(jsonb_build_object('order_id', q.order_id, 'kind', q.kind, 'status', q.status, 'attempts', q.attempts, 'error', q.last_error))
                       FROM public.billing_engine_queue q JOIN public.orders o ON o.id = q.order_id WHERE o.wholesaler_id = p_business_id AND q.status <> 'done'), '[]'::JSONB));
END;
$$;
