-- Delivery-based credit due dates.
--
-- Until now a credit invoice fell due N days after the ORDER date. A wholesaler can now choose, per customer, to
-- start the payment clock on DELIVERY instead:
--     order_date     (default, unchanged)  due = order date + terms
--     delivery_date  due = delivery date + terms; until the order is delivered there is NO due date
-- The choice lives on the customer's credit terms (wholesaler_credit_terms.due_basis) and is copied onto each
-- order when it is placed (orders.credit_due_basis), so changing it later affects only NEW orders: invoices
-- already issued keep the rule they were issued under.
--
-- How it works, for every way a credit order can be created (checkout and RFQ awards alike):
--   * a BEFORE INSERT trigger looks at the pair's terms; for delivery_date it records the basis and the
--     terms in days on the order and leaves the due date empty;
--   * a BEFORE UPDATE trigger sets the due date the moment the order becomes 'delivered':
--     delivery date + the order's terms in days (30 if, exceptionally, no terms were recorded), and writes an
--     audit entry;
--   * checkout itself is patched so its own audit entry says the due date is not set yet.
-- Everything downstream already copes with an empty due date: it is not overdue and sits in the "current"
-- aging bucket, the registers show a dash, and no reminder fires until a due date exists. A cancelled order
-- simply never gets one.
--
-- Also here: set_credit_due_basis() (owner/manager of the wholesaler, audited, tells the pharmacy) and the two
-- credit-terms readers, which now return due_basis.

ALTER TABLE public.wholesaler_credit_terms ADD COLUMN IF NOT EXISTS due_basis TEXT NOT NULL DEFAULT 'order_date';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS credit_due_basis TEXT NOT NULL DEFAULT 'order_date';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wholesaler_credit_terms_due_basis_check') THEN
    ALTER TABLE public.wholesaler_credit_terms ADD CONSTRAINT wholesaler_credit_terms_due_basis_check
      CHECK (due_basis IN ('order_date', 'delivery_date'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_credit_due_basis_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_credit_due_basis_check
      CHECK (credit_due_basis IN ('order_date', 'delivery_date'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1. New credit orders under a delivery-based customer: record the basis, keep the terms, leave the due date empty.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.apply_credit_due_basis()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_basis TEXT;
  v_days INTEGER;
BEGIN
  IF NEW.is_credit_order IS NOT TRUE THEN
    RETURN NEW;
  END IF;
  SELECT t.due_basis, t.payment_terms_days INTO v_basis, v_days
  FROM public.wholesaler_credit_terms t
  WHERE t.wholesaler_id = NEW.wholesaler_id AND t.pharmacy_id = NEW.pharmacy_id;
  IF FOUND AND v_basis = 'delivery_date' THEN
    NEW.credit_due_basis := 'delivery_date';
    NEW.credit_terms_days := COALESCE(
      NEW.credit_terms_days,
      CASE WHEN NEW.credit_due_date IS NOT NULL THEN NEW.credit_due_date - current_date END,
      v_days);
    NEW.credit_due_date := NULL;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.apply_credit_due_basis() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_apply_credit_due_basis
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.apply_credit_due_basis();

-- ---------------------------------------------------------------------------
-- 2. The due date is set when the order is delivered. (Named to sort after orders_status_change, which stamps
--    delivered_at; now() is used if it is somehow still empty.)
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.set_credit_due_on_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_credit_order IS TRUE AND NEW.credit_due_basis = 'delivery_date' AND NEW.credit_due_date IS NULL
     AND NEW.status::TEXT = 'delivered' AND OLD.status::TEXT IS DISTINCT FROM 'delivered' THEN
    NEW.credit_due_date := COALESCE(NEW.delivered_at, now())::DATE + COALESCE(NEW.credit_terms_days, 30);
    BEGIN
      PERFORM public.write_audit_log(
        'Credit due date set on delivery', (SELECT name FROM public.businesses WHERE id = NEW.wholesaler_id),
        'order', NEW.id, NEW.order_number,
        jsonb_build_object('due_date', NEW.credit_due_date, 'terms_days', COALESCE(NEW.credit_terms_days, 30),
          'delivered_on', COALESCE(NEW.delivered_at, now())::DATE, 'basis', 'delivery_date'),
        auth.uid(), NULL, NULL, NEW.wholesaler_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'set_credit_due_on_delivery audit failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.set_credit_due_on_delivery() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_set_credit_due_on_delivery
  BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.set_credit_due_on_delivery();

-- ---------------------------------------------------------------------------
-- 3. The wholesaler chooses the basis per customer. Affects new orders only.
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.set_credit_due_basis(p_wholesaler_id UUID, p_pharmacy_id UUID, p_basis TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_line RECORD;
  v_org TEXT;
  v_pharmacy TEXT;
  v_role TEXT;
  v_actor_email TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may manage credit terms.';
  END IF;
  IF p_basis IS NULL OR p_basis NOT IN ('order_date', 'delivery_date') THEN
    RAISE EXCEPTION 'Invalid due-date basis.';
  END IF;
  SELECT * INTO v_line FROM public.wholesaler_credit_terms
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id FOR UPDATE;
  IF NOT FOUND OR NOT v_line.active THEN RAISE EXCEPTION 'No active credit line for this pharmacy.'; END IF;
  IF v_line.due_basis = p_basis THEN RAISE EXCEPTION 'The due date already starts from the %.', replace(p_basis, '_', ' '); END IF;

  UPDATE public.wholesaler_credit_terms SET due_basis = p_basis, updated_by = auth.uid()
  WHERE wholesaler_id = p_wholesaler_id AND pharmacy_id = p_pharmacy_id;

  SELECT name INTO v_org FROM public.businesses WHERE id = p_wholesaler_id;
  SELECT name INTO v_pharmacy FROM public.businesses WHERE id = p_pharmacy_id;
  v_role := CASE WHEN EXISTS (SELECT 1 FROM public.businesses WHERE id = p_wholesaler_id AND owner_id = auth.uid())
    THEN 'owner' ELSE public.get_staff_role(auth.uid(), p_wholesaler_id)::TEXT END;
  SELECT email INTO v_actor_email FROM auth.users WHERE id = auth.uid();
  PERFORM public.write_audit_log(
    'Credit due-date basis changed', v_org, 'business', p_pharmacy_id, v_pharmacy,
    jsonb_build_object('from', v_line.due_basis, 'to', p_basis, 'terms_days', v_line.payment_terms_days,
      'applies_to', 'new orders only', 'actor_role', v_role),
    auth.uid(), v_actor_email, NULL, p_wholesaler_id);

  BEGIN
    PERFORM public.notify_business(p_pharmacy_id, ARRAY['owner', 'manager', 'accountant'], 'credit_status',
      'Credit payment terms changed',
      v_org || ': new credit orders are now due ' || v_line.payment_terms_days || ' days after '
        || CASE p_basis WHEN 'delivery_date' THEN 'delivery' ELSE 'the order date' END
        || '. Invoices already issued keep their due dates.',
      '/pharmacy?tab=credit', jsonb_build_object('wholesaler_id', p_wholesaler_id, 'due_basis', p_basis));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'set_credit_due_basis notification failed: %', SQLERRM;
  END;
END;
$$;
REVOKE ALL ON FUNCTION public.set_credit_due_basis(UUID, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_credit_due_basis(UUID, UUID, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. The two readers also return due_basis (appended; everything else is as it was).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.list_wholesaler_credit_terms(UUID);
CREATE FUNCTION public.list_wholesaler_credit_terms(p_wholesaler_id UUID)
RETURNS TABLE(
  pharmacy_id UUID, pharmacy_name TEXT, credit_limit_ghs NUMERIC, payment_terms_days INTEGER,
  outstanding_ghs NUMERIC, available_ghs NUMERIC, internal_note TEXT, updated_at TIMESTAMPTZ,
  status TEXT, status_reason TEXT, status_changed_at TIMESTAMPTZ,
  override_max_order_ghs NUMERIC, override_expires_at TIMESTAMPTZ, override_reason TEXT,
  starts_on DATE, scheduled_credit_limit_ghs NUMERIC, scheduled_payment_terms_days INTEGER,
  scheduled_effective_date DATE, scheduled_note TEXT, due_basis TEXT
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
    e.starts_on, e.scheduled_credit_limit_ghs, e.scheduled_payment_terms_days, e.scheduled_effective_date, e.scheduled_note,
    c.due_basis
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
  starts_on DATE, scheduled_credit_limit_ghs NUMERIC, scheduled_payment_terms_days INTEGER, scheduled_effective_date DATE,
  due_basis TEXT
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
    e.starts_on, e.scheduled_credit_limit_ghs, e.scheduled_payment_terms_days, e.scheduled_effective_date,
    c.due_basis
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

-- ---------------------------------------------------------------------------
-- 5. Checkout: patched IN PLACE from its live definition so everything else in it (stock deductions, the
--    production order guard, credit-limit locks) is preserved. Only the due date and its audit entry change.
--    Each fragment must match exactly once, otherwise nothing is changed. Safe to re-run.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_sig TEXT := 'public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)';
  v_def TEXT;
  v_pairs TEXT[][] := ARRAY[
    -- ('I' || 'NTO' is split on purpose: the Supabase SQL Editor mistakes the text SELECT ... INTO inside a string
    -- for a table-creating statement and asks about row security.)
    ARRAY['c.status, c.effective_date I' || 'NTO v_credit',
          'c.status, c.effective_date, c.due_basis I' || 'NTO v_credit'],
    ARRAY['v_due_date := (now() + make_interval(days => v_credit.payment_terms_days))::DATE;',
          'v_due_date := CASE WHEN v_credit.due_basis = ''delivery_date'' THEN NULL ELSE (now() + make_interval(days => v_credit.payment_terms_days))::DATE END;'],
    ARRAY['''terms_days'', v_terms_days);',
          '''terms_days'', v_terms_days,' || E'\n' || '        ''due_basis'', v_credit.due_basis);']
  ];
  i INTEGER;
  v_old TEXT;
  v_new TEXT;
  v_count INTEGER;
  v_applied INTEGER := 0;
BEGIN
  v_def := replace(pg_get_functiondef(v_sig::regprocedure), E'\r', '');
  FOR i IN 1 .. array_length(v_pairs, 1) LOOP
    v_old := v_pairs[i][1];
    v_new := v_pairs[i][2];
    v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    IF v_count = 1 THEN
      v_def := replace(v_def, v_old, v_new);
      v_applied := v_applied + 1;
    ELSIF v_count = 0 AND position(v_new IN v_def) > 0 THEN
      NULL; -- already patched
    ELSE
      RAISE EXCEPTION 'Cannot patch %: expected to find fragment % exactly once, found % time(s). Nothing was changed.', v_sig, i, v_count;
    END IF;
  END LOOP;
  IF v_applied > 0 THEN
    EXECUTE v_def;
  END IF;
END $$;
