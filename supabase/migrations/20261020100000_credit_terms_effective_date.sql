-- Future effective date for credit terms.
--
-- A wholesaler can approve a credit line that STARTS on a future date, or schedule a change to an
-- existing line (new limit and/or payment terms) that takes effect on a future date. Until that date
-- arrives the current terms stay in force. Dates are calendar dates in the database's time zone
-- (Ghana is GMT with no daylight saving, so the database date is the Ghana date).
--
-- Model (one row per wholesaler/pharmacy pair, as before):
--   effective_date            NULL or in the past = the line is in force; in the future = not started yet
--   pending_*                 at most one scheduled change (limit, terms days, date, note), replaced if
--                             rescheduled, cleared when cancelled or when it takes effect
-- A scheduled change is applied lazily and exactly once, under the credit-line lock, the first time
-- the line is used after its date (checkout or granting an override). Readers do not wait for that:
-- credit_effective_terms() reports the terms that apply TODAY whether or not the row was rewritten
-- yet, so every screen, and the checkout, agree.
--
-- Existing functions are PATCHED in place, never replaced wholesale, because the deployed versions
-- (checkout especially) carry production-only safeguards. Each fragment must match exactly once;
-- otherwise the migration fails closed and changes nothing.

ALTER TABLE public.wholesaler_credit_terms
  ADD COLUMN IF NOT EXISTS effective_date DATE,
  ADD COLUMN IF NOT EXISTS pending_credit_limit_ghs NUMERIC(12,2),
  ADD COLUMN IF NOT EXISTS pending_payment_terms_days INTEGER,
  ADD COLUMN IF NOT EXISTS pending_effective_date DATE,
  ADD COLUMN IF NOT EXISTS pending_note TEXT,
  ADD COLUMN IF NOT EXISTS pending_set_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS pending_set_at TIMESTAMPTZ;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wholesaler_credit_terms_pending_check') THEN
    ALTER TABLE public.wholesaler_credit_terms ADD CONSTRAINT wholesaler_credit_terms_pending_check CHECK (
      (pending_effective_date IS NULL) = (pending_credit_limit_ghs IS NULL)
      AND (pending_effective_date IS NULL) = (pending_payment_terms_days IS NULL)
      AND (pending_credit_limit_ghs IS NULL OR (pending_credit_limit_ghs > 0 AND pending_credit_limit_ghs <= 10000000))
      AND (pending_payment_terms_days IS NULL OR pending_payment_terms_days BETWEEN 1 AND 365)
      AND (pending_note IS NULL OR char_length(pending_note) <= 500));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- The terms that apply today (without writing anything).
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.credit_effective_terms(p_wholesaler_id UUID, p_pharmacy_id UUID)
RETURNS TABLE(
  credit_limit_ghs NUMERIC, payment_terms_days INTEGER, in_force BOOLEAN, starts_on DATE,
  scheduled_credit_limit_ghs NUMERIC, scheduled_payment_terms_days INTEGER, scheduled_effective_date DATE, scheduled_note TEXT
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    CASE WHEN c.pending_effective_date <= current_date THEN c.pending_credit_limit_ghs ELSE c.credit_limit_ghs END,
    CASE WHEN c.pending_effective_date <= current_date THEN c.pending_payment_terms_days ELSE c.payment_terms_days END,
    (c.effective_date IS NULL OR c.effective_date <= current_date),
    CASE WHEN c.effective_date > current_date THEN c.effective_date END,
    CASE WHEN c.pending_effective_date > current_date THEN c.pending_credit_limit_ghs END,
    CASE WHEN c.pending_effective_date > current_date THEN c.pending_payment_terms_days END,
    CASE WHEN c.pending_effective_date > current_date THEN c.pending_effective_date END,
    CASE WHEN c.pending_effective_date > current_date THEN c.pending_note END
  FROM public.wholesaler_credit_terms c
  WHERE c.wholesaler_id = p_wholesaler_id AND c.pharmacy_id = p_pharmacy_id
$$;
REVOKE ALL ON FUNCTION public.credit_effective_terms(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.credit_effective_terms(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- Apply a scheduled change whose date has arrived (internal; idempotent). Takes the credit-line lock.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.credit_apply_due_terms(p_wholesaler_id UUID, p_pharmacy_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v RECORD;
  v_org TEXT;
  v_pharmacy TEXT;
BEGIN
  SELECT * INTO v FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  IF NOT FOUND OR v.pending_effective_date IS NULL OR v.pending_effective_date > current_date THEN
    RETURN FALSE;
  END IF;

  UPDATE public.wholesaler_credit_terms
  SET credit_limit_ghs = pending_credit_limit_ghs,
      payment_terms_days = pending_payment_terms_days,
      internal_note = COALESCE(pending_note, internal_note),
      pending_credit_limit_ghs = NULL, pending_payment_terms_days = NULL, pending_effective_date = NULL,
      pending_note = NULL, pending_set_by = NULL, pending_set_at = NULL,
      updated_by = v.pending_set_by
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  PERFORM public.write_audit_log(
    'Credit terms change took effect', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object(
      'effective_date', v.pending_effective_date,
      'from_credit_limit_ghs', v.credit_limit_ghs, 'to_credit_limit_ghs', v.pending_credit_limit_ghs,
      'from_payment_terms_days', v.payment_terms_days, 'to_payment_terms_days', v.pending_payment_terms_days,
      'scheduled_by', v.pending_set_by, 'scheduled_at', v.pending_set_at),
    NULL, NULL, NULL, p_wholesaler_id);
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.credit_apply_due_terms(UUID, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.credit_apply_due_terms(UUID, UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- Schedule: a line that starts in the future, or a change to a running line from a future date.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.schedule_credit_terms(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_credit_limit NUMERIC,
  p_payment_terms_days INTEGER,
  p_effective_date DATE,
  p_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_org TEXT;
  v_pharmacy TEXT;
  v_line RECORD;
  v_role TEXT;
  v_actor_email TEXT;
  v_new_line BOOLEAN := FALSE;
  v_limit NUMERIC := round(p_credit_limit, 2);
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  SELECT b.name INTO v_org FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.type::TEXT = 'wholesaler';
  IF v_org IS NULL THEN RAISE EXCEPTION 'Credit terms are only available for wholesalers.'; END IF;
  SELECT b.name INTO v_pharmacy FROM public.businesses b WHERE b.id = p_pharmacy_id AND b.type::TEXT = 'pharmacy';
  IF v_pharmacy IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;
  IF v_limit IS NULL OR v_limit <= 0 OR v_limit > 10000000 THEN
    RAISE EXCEPTION 'The credit limit must be above GHS 0 and at most GHS 10,000,000.';
  END IF;
  IF p_payment_terms_days IS NULL OR p_payment_terms_days < 1 OR p_payment_terms_days > 365 THEN
    RAISE EXCEPTION 'Payment terms must be between 1 and 365 days.';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The note is too long (500 characters maximum).'; END IF;
  IF p_effective_date IS NULL OR p_effective_date <= current_date THEN
    RAISE EXCEPTION 'The effective date must be in the future. To change terms now, save them without a date.';
  END IF;
  IF p_effective_date > current_date + 365 THEN
    RAISE EXCEPTION 'The effective date can be at most one year ahead.';
  END IF;

  PERFORM public.credit_apply_due_terms(p_wholesaler_id, p_pharmacy_id);
  SELECT * INTO v_line FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;

  IF NOT FOUND THEN
    -- A brand-new line that starts in the future.
    INSERT INTO public.wholesaler_credit_terms (wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days, active, internal_note, created_by, updated_by, effective_date)
    VALUES (p_wholesaler_id, p_pharmacy_id, v_limit, p_payment_terms_days, TRUE, v_note, auth.uid(), auth.uid(), p_effective_date);
    v_new_line := TRUE;
  ELSIF NOT v_line.active OR (v_line.effective_date IS NOT NULL AND v_line.effective_date > current_date) THEN
    -- A closed line being re-approved, or a line that has not started yet being rescheduled: the new
    -- terms and start date simply replace what was there (nothing is in force to protect).
    UPDATE public.wholesaler_credit_terms
    SET credit_limit_ghs = v_limit, payment_terms_days = p_payment_terms_days, active = TRUE, status = 'active',
        status_reason = NULL, internal_note = v_note, effective_date = p_effective_date, updated_by = auth.uid(),
        pending_credit_limit_ghs = NULL, pending_payment_terms_days = NULL, pending_effective_date = NULL,
        pending_note = NULL, pending_set_by = NULL, pending_set_at = NULL
    WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;
    v_new_line := TRUE;
  ELSE
    -- A running line: keep today's terms in force and schedule the change (replacing any earlier one).
    UPDATE public.wholesaler_credit_terms
    SET pending_credit_limit_ghs = v_limit, pending_payment_terms_days = p_payment_terms_days,
        pending_effective_date = p_effective_date, pending_note = v_note,
        pending_set_by = auth.uid(), pending_set_at = now(), updated_by = auth.uid()
    WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;
  END IF;

  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    CASE WHEN v_new_line THEN 'Credit line scheduled to start' ELSE 'Credit terms change scheduled' END,
    v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object(
      'effective_date', p_effective_date, 'credit_limit_ghs', v_limit, 'payment_terms_days', p_payment_terms_days,
      'current_credit_limit_ghs', CASE WHEN v_new_line THEN NULL ELSE v_line.credit_limit_ghs END,
      'current_payment_terms_days', CASE WHEN v_new_line THEN NULL ELSE v_line.payment_terms_days END,
      'replaced_scheduled_date', CASE WHEN v_new_line THEN NULL ELSE v_line.pending_effective_date END,
      'note', v_note, 'actor_role', v_role),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);

  BEGIN
    PERFORM public.notify_business(p_pharmacy_id, ARRAY['owner', 'manager', 'accountant'], 'credit_terms_scheduled',
      CASE WHEN v_new_line THEN 'Credit account scheduled' ELSE 'Credit terms change scheduled' END,
      v_org || CASE WHEN v_new_line THEN ' will open a credit account for you from ' ELSE ' will change your credit terms from ' END
        || to_char(p_effective_date, 'DD Mon YYYY') || ': limit GHS ' || to_char(v_limit, 'FM999,999,990.00')
        || ', ' || p_payment_terms_days || '-day terms.',
      '/pharmacy?tab=credit', jsonb_build_object('wholesaler_id', p_wholesaler_id, 'effective_date', p_effective_date));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'schedule_credit_terms notification failed: %', SQLERRM;
  END;
END;
$$;
REVOKE ALL ON FUNCTION public.schedule_credit_terms(UUID, UUID, NUMERIC, INTEGER, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.schedule_credit_terms(UUID, UUID, NUMERIC, INTEGER, DATE, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Cancel a scheduled change, or a line that has not started yet.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.cancel_scheduled_credit_terms(p_wholesaler_id UUID, p_pharmacy_id UUID, p_reason TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := btrim(COALESCE(p_reason, ''));
  v_line RECORD;
  v_org TEXT;
  v_pharmacy TEXT;
  v_role TEXT;
  v_actor_email TEXT;
  v_was_new_line BOOLEAN;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  IF char_length(v_reason) < 5 OR char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'A reason of 5 to 500 characters is required to cancel a scheduled credit change.';
  END IF;
  PERFORM public.credit_apply_due_terms(p_wholesaler_id, p_pharmacy_id);
  SELECT * INTO v_line FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  v_was_new_line := FOUND AND v_line.active AND v_line.effective_date IS NOT NULL AND v_line.effective_date > current_date;
  IF NOT FOUND OR (NOT v_was_new_line AND v_line.pending_effective_date IS NULL) THEN
    RAISE EXCEPTION 'There is nothing scheduled to cancel for this pharmacy.';
  END IF;

  IF v_was_new_line THEN
    UPDATE public.wholesaler_credit_terms SET active = FALSE, effective_date = NULL, updated_by = auth.uid()
    WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;
  ELSE
    UPDATE public.wholesaler_credit_terms
    SET pending_credit_limit_ghs = NULL, pending_payment_terms_days = NULL, pending_effective_date = NULL,
        pending_note = NULL, pending_set_by = NULL, pending_set_at = NULL, updated_by = auth.uid()
    WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;
  END IF;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    'Credit scheduled change cancelled', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object(
      'was', CASE WHEN v_was_new_line THEN 'line not yet started' ELSE 'scheduled terms change' END,
      'effective_date', CASE WHEN v_was_new_line THEN v_line.effective_date ELSE v_line.pending_effective_date END,
      'credit_limit_ghs', CASE WHEN v_was_new_line THEN v_line.credit_limit_ghs ELSE v_line.pending_credit_limit_ghs END,
      'payment_terms_days', CASE WHEN v_was_new_line THEN v_line.payment_terms_days ELSE v_line.pending_payment_terms_days END,
      'reason', v_reason, 'actor_role', v_role),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_scheduled_credit_terms(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_scheduled_credit_terms(UUID, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- Patch existing functions in place (fail closed unless each fragment matches exactly once).
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.patch_function(p_signature TEXT, p_old TEXT[], p_new TEXT[]) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  definition TEXT;
  hits INTEGER;
  i INTEGER;
  old_text TEXT;
BEGIN
  definition := replace(pg_get_functiondef(p_signature::regprocedure), E'\r', '');
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    old_text := replace(p_old[i], E'\r', '');
    hits := (length(definition) - length(replace(definition, old_text, ''))) / length(old_text);
    IF hits <> 1 THEN
      RAISE EXCEPTION 'Unexpected % body (a fragment matched % times, expected 1); inspect before patching. Fragment starts: %',
        p_signature, hits, left(old_text, 80);
    END IF;
  END LOOP;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    definition := replace(definition, replace(p_old[i], E'\r', ''), replace(p_new[i], E'\r', ''));
  END LOOP;
  EXECUTE definition;
END $$;

DO $migration$
BEGIN
  -- Checkout: apply a due scheduled change under the credit-line lock, refuse a line that hasn't started.
  IF strpos(pg_get_functiondef('public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure), 'credit_apply_due_terms') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)',
      ARRAY[
        E'      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active, c.status INTO v_credit\n',
        E'      IF v_credit.status = ''suspended'' THEN\n'],
      ARRAY[
        E'      PERFORM public.credit_apply_due_terms(v_wholesaler.wholesaler_id, _pharmacy_id);\n      SELECT c.credit_limit_ghs, c.payment_terms_days, c.active, c.status, c.effective_date INTO v_credit\n',
        E'      IF v_credit.effective_date IS NOT NULL AND v_credit.effective_date > current_date THEN\n        RAISE EXCEPTION ''Credit with % starts on %. Choose another payment method.'', v_wholesaler_name, to_char(v_credit.effective_date, ''DD Mon YYYY'');\n      END IF;\n      IF v_credit.status = ''suspended'' THEN\n'] );
  END IF;

  -- Immediate approval: starts now, so clear any future start date.
  IF strpos(pg_get_functiondef('public.set_credit_terms(uuid,uuid,numeric,integer,text)'::regprocedure), 'effective_date = NULL') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.set_credit_terms(uuid,uuid,numeric,integer,text)',
      ARRAY[E'      active = TRUE, internal_note = EXCLUDED.internal_note, updated_by = auth.uid();'],
      ARRAY[E'      active = TRUE, internal_note = EXCLUDED.internal_note, updated_by = auth.uid(), effective_date = NULL;']);
  END IF;

  -- Closing a line also drops anything scheduled on it.
  IF strpos(pg_get_functiondef('public.revoke_credit_terms(uuid,uuid)'::regprocedure), 'pending_effective_date') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.revoke_credit_terms(uuid,uuid)',
      ARRAY[E'  UPDATE public.wholesaler_credit_terms SET active = FALSE, updated_by = auth.uid()\n'],
      ARRAY[E'  UPDATE public.wholesaler_credit_terms SET active = FALSE, updated_by = auth.uid(), effective_date = NULL,\n    pending_credit_limit_ghs = NULL, pending_payment_terms_days = NULL, pending_effective_date = NULL,\n    pending_note = NULL, pending_set_by = NULL, pending_set_at = NULL\n']);
  END IF;

  -- An override is judged against the terms that apply today, and not on a line that hasn't started.
  IF strpos(pg_get_functiondef('public.grant_credit_override(uuid,uuid,numeric,integer,text)'::regprocedure), 'credit_apply_due_terms') = 0 THEN
    PERFORM pg_temp.patch_function(
      'public.grant_credit_override(uuid,uuid,numeric,integer,text)',
      ARRAY[
        E'  SELECT * INTO v_line FROM public.wholesaler_credit_terms\n',
        E'  IF NOT FOUND OR NOT v_line.active THEN RAISE EXCEPTION ''No active credit line for this pharmacy.''; END IF;\n'],
      ARRAY[
        E'  PERFORM public.credit_apply_due_terms(p_wholesaler_id, p_pharmacy_id);\n  SELECT * INTO v_line FROM public.wholesaler_credit_terms\n',
        E'  IF NOT FOUND OR NOT v_line.active THEN RAISE EXCEPTION ''No active credit line for this pharmacy.''; END IF;\n  IF v_line.effective_date IS NOT NULL AND v_line.effective_date > current_date THEN\n    RAISE EXCEPTION ''Credit for this pharmacy has not started yet (it starts on %).'', to_char(v_line.effective_date, ''DD Mon YYYY'');\n  END IF;\n']);
  END IF;
END;
$migration$;

REVOKE ALL ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_marketplace_orders(UUID, UUID, JSONB, UUID[], BOOLEAN, JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- Readers: report the terms that apply today plus anything scheduled.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_wholesaler_credit_terms(UUID);
CREATE FUNCTION public.list_wholesaler_credit_terms(p_wholesaler_id UUID)
RETURNS TABLE(
  pharmacy_id UUID, pharmacy_name TEXT, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, internal_note TEXT, updated_at TIMESTAMPTZ,
  status TEXT, status_reason TEXT, status_changed_at TIMESTAMPTZ,
  override_max_order_ghs NUMERIC, override_expires_at TIMESTAMPTZ, override_reason TEXT,
  starts_on DATE, scheduled_credit_limit_ghs NUMERIC, scheduled_payment_terms_days INTEGER,
  scheduled_effective_date DATE, scheduled_note TEXT
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may view credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.pharmacy_id, ph.name, e.credit_limit_ghs, e.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(e.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    c.internal_note, c.updated_at, c.status, c.status_reason, c.status_changed_at,
    ov.max_order_ghs, ov.expires_at, ov.reason,
    e.starts_on, e.scheduled_credit_limit_ghs, e.scheduled_payment_terms_days, e.scheduled_effective_date, e.scheduled_note
  FROM public.wholesaler_credit_terms c
  JOIN public.businesses ph ON ph.id = c.pharmacy_id
  CROSS JOIN LATERAL public.credit_effective_terms(c.wholesaler_id, c.pharmacy_id) e
  LEFT JOIN public.credit_overrides ov ON ov.wholesaler_id = c.wholesaler_id AND ov.pharmacy_id = c.pharmacy_id
    AND ov.status = 'active' AND ov.expires_at > now()
  WHERE c.wholesaler_id = p_wholesaler_id AND c.active
  ORDER BY ph.name;
END;
$$;
REVOKE ALL ON FUNCTION public.list_wholesaler_credit_terms(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_wholesaler_credit_terms(UUID) TO authenticated;

DROP FUNCTION IF EXISTS public.get_my_credit_terms(UUID, UUID);
CREATE FUNCTION public.get_my_credit_terms(p_pharmacy_id UUID, p_wholesaler_id UUID DEFAULT NULL)
RETURNS TABLE(
  wholesaler_id UUID, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, status TEXT,
  override_max_order_ghs NUMERIC, override_expires_at TIMESTAMPTZ,
  starts_on DATE, scheduled_credit_limit_ghs NUMERIC, scheduled_payment_terms_days INTEGER, scheduled_effective_date DATE
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id, 'read') THEN
    RAISE EXCEPTION 'You do not have access to this pharmacy''s credit terms.';
  END IF;
  RETURN QUERY
  SELECT c.wholesaler_id, e.credit_limit_ghs, e.payment_terms_days,
    public.credit_exposure(c.wholesaler_id, c.pharmacy_id),
    GREATEST(e.credit_limit_ghs - public.credit_exposure(c.wholesaler_id, c.pharmacy_id), 0::NUMERIC),
    CASE WHEN e.in_force THEN c.status ELSE 'scheduled' END,
    ov.max_order_ghs, ov.expires_at,
    e.starts_on, e.scheduled_credit_limit_ghs, e.scheduled_payment_terms_days, e.scheduled_effective_date
  FROM public.wholesaler_credit_terms c
  CROSS JOIN LATERAL public.credit_effective_terms(c.wholesaler_id, c.pharmacy_id) e
  LEFT JOIN public.credit_overrides ov ON ov.wholesaler_id = c.wholesaler_id AND ov.pharmacy_id = c.pharmacy_id
    AND ov.status = 'active' AND ov.expires_at > now()
  WHERE c.pharmacy_id = p_pharmacy_id AND c.active
    AND (p_wholesaler_id IS NULL OR c.wholesaler_id = p_wholesaler_id);
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_credit_terms(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_terms(UUID, UUID) TO authenticated;
