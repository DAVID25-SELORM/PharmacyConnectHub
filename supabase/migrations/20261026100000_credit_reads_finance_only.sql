-- The older Credit-tab readers become finance-only.
--
-- list_credit_invoices, get_credit_invoice, wholesaler_ar_summary and pharmacy_ap_summary were open to any
-- active staff (can_act_for_business(..., 'read')): a cashier, an assistant or a warehouse user could read every
-- credit invoice, balance and payment through them. They now require can_view_accounting(), the same gate as the
-- Accounting registers, statements and overview:
--     wholesaler: owner, manager, finance, accountant
--     pharmacy:   owner, manager, accountant
-- (A pharmacy cannot have a finance role at all: a trigger limits warehouse/finance staff to wholesalers.)
--
-- Nothing else about these functions changes. They are patched IN PLACE from their live definitions, replacing
-- only the permission check, so whatever else production has in them is preserved. Each fragment must match
-- exactly once or the whole migration stops and changes nothing. Re-running it is safe: a function that is
-- already patched is skipped.
--
-- Not changed: record_credit_payment and the other writers have their own, tighter checks. Credit terms and
-- the order's own settlement fields are unaffected, so placing and viewing orders works as before.

DO $$
DECLARE
  v_patches JSONB := jsonb_build_object(
    'public.list_credit_invoices(uuid,uuid,text)', jsonb_build_array(
      jsonb_build_array('public.can_act_for_business(p_wholesaler_id, ''read'')', 'public.can_view_accounting(p_wholesaler_id)'),
      jsonb_build_array('public.can_act_for_business(p_pharmacy_id, ''read'')', 'public.can_view_accounting(p_pharmacy_id)')),
    'public.get_credit_invoice(uuid)', jsonb_build_array(
      jsonb_build_array('public.can_act_for_business(v_order.pharmacy_id, ''read'')', 'public.can_view_accounting(v_order.pharmacy_id)'),
      jsonb_build_array('public.can_act_for_business(v_order.wholesaler_id, ''read'')', 'public.can_view_accounting(v_order.wholesaler_id)')),
    'public.wholesaler_ar_summary(uuid)', jsonb_build_array(
      jsonb_build_array('public.can_act_for_business(p_wholesaler_id, ''read'')', 'public.can_view_accounting(p_wholesaler_id)')),
    'public.pharmacy_ap_summary(uuid)', jsonb_build_array(
      jsonb_build_array('public.can_act_for_business(p_pharmacy_id, ''read'')', 'public.can_view_accounting(p_pharmacy_id)'))
  );
  v_sig TEXT;
  v_pairs JSONB;
  v_pair JSONB;
  v_def TEXT;
  v_old TEXT;
  v_new TEXT;
  v_count INTEGER;
  v_applied INTEGER;
BEGIN
  FOR v_sig, v_pairs IN SELECT key, value FROM jsonb_each(v_patches) LOOP
    -- Normalise line endings so the match does not depend on how the migration was pasted.
    v_def := replace(pg_get_functiondef(v_sig::regprocedure), E'\r', '');
    v_applied := 0;
    FOR v_pair IN SELECT value FROM jsonb_array_elements(v_pairs) LOOP
      v_old := v_pair->>0;
      v_new := v_pair->>1;
      v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
      IF v_count = 1 THEN
        v_def := replace(v_def, v_old, v_new);
        v_applied := v_applied + 1;
      ELSIF v_count = 0 AND position(v_new IN v_def) > 0 THEN
        NULL; -- already patched
      ELSE
        RAISE EXCEPTION 'Cannot patch %: expected to find "%" exactly once, found % time(s). Nothing was changed.', v_sig, v_old, v_count;
      END IF;
    END LOOP;
    IF v_applied > 0 THEN
      EXECUTE v_def;
    END IF;
  END LOOP;
END $$;
