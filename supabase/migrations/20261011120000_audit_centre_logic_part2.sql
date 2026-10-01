-- Audit Centre, part 3: business_id on the credit-ledger and product-import write_audit_log call
-- sites (they already logged; they just couldn't be filtered per-business), plus list_audit_log,
-- the read RPC the Audit Centre UI calls. Each function below is rebuilt on its exact current body
-- (re-read fresh from its own source migration immediately before writing this file) -- only the
-- write_audit_log call itself gains a trailing _business_id argument; nothing else changes.
-- Business attribution follows "whoever's staff performed the action": every one of these five
-- credit-ledger functions is gated to the wholesaler side (owner/manager/finance/accountant, or
-- owner/manager only for the more sensitive ones), so business_id is always the wholesaler.

CREATE OR REPLACE FUNCTION public.record_credit_payment(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_amount NUMERIC,
  p_method TEXT,
  p_reference TEXT DEFAULT NULL,
  p_paid_at TIMESTAMPTZ DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_proof_url TEXT DEFAULT NULL,
  p_allocations JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_payment_id UUID;
  v_alloc RECORD;
  v_alloc_sum NUMERIC(12,2) := 0;
  v_order RECORD;
  v_status RECORD;
  v_entry_id UUID;
  v_unallocated NUMERIC(12,2);
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_paid_at TIMESTAMPTZ := COALESCE(p_paid_at, now());
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_wholesaler_id AND b.owner_id = auth.uid()) INTO v_is_owner;
  v_role := public.get_staff_role(auth.uid(), p_wholesaler_id);
  IF NOT v_is_owner AND (v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'finance', 'accountant')) THEN
    RAISE EXCEPTION 'You do not have permission to record payments for this wholesaler.';
  END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  IF v_wholesaler_name IS NULL THEN RAISE EXCEPTION 'Wholesaler workspace not found.'; END IF;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_pharmacy_name IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter a payment amount greater than zero.'; END IF;
  IF p_method IS NULL OR p_method NOT IN ('cash', 'bank_transfer', 'mobile_money', 'cheque', 'online', 'other') THEN
    RAISE EXCEPTION 'Choose a valid payment method.';
  END IF;
  IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN RAISE EXCEPTION 'Invalid allocation list.'; END IF;

  -- Validate the allocation total against the payment amount BEFORE writing anything.
  SELECT COALESCE(SUM(round((x ->> 'amount')::NUMERIC, 2)), 0) INTO v_alloc_sum
  FROM jsonb_array_elements(p_allocations) x;
  IF v_alloc_sum > round(p_amount, 2) THEN
    RAISE EXCEPTION 'Allocations (GHS %) cannot exceed the payment amount (GHS %).',
      to_char(v_alloc_sum, 'FM999,999,990.00'), to_char(p_amount, 'FM999,999,990.00');
  END IF;

  INSERT INTO public.credit_payments (wholesaler_id, pharmacy_id, amount_ghs, method, reference, paid_at, recorded_by, proof_url, notes)
  VALUES (p_wholesaler_id, p_pharmacy_id, round(p_amount, 2), p_method,
    NULLIF(btrim(COALESCE(p_reference, '')), ''), v_paid_at, auth.uid(), p_proof_url, NULLIF(btrim(COALESCE(p_notes, '')), ''))
  RETURNING id INTO v_payment_id;

  FOR v_alloc IN
    SELECT (x ->> 'order_id')::UUID AS order_id, round((x ->> 'amount')::NUMERIC, 2) AS amount
    FROM jsonb_array_elements(p_allocations) x
  LOOP
    IF v_alloc.order_id IS NULL OR v_alloc.amount IS NULL OR v_alloc.amount <= 0 THEN
      RAISE EXCEPTION 'Each allocation needs a valid order and a positive amount.';
    END IF;

    SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.payment_status INTO v_order
    FROM public.orders o WHERE o.id = v_alloc.order_id FOR UPDATE;
    IF NOT FOUND OR v_order.wholesaler_id <> p_wholesaler_id OR v_order.pharmacy_id <> p_pharmacy_id OR NOT v_order.is_credit_order THEN
      RAISE EXCEPTION 'Order % is not a credit order between these two businesses.', v_alloc.order_id;
    END IF;

    SELECT * INTO v_status FROM public.credit_invoice_status(v_alloc.order_id);
    IF v_alloc.amount > v_status.outstanding_ghs THEN
      RAISE EXCEPTION 'Allocation of GHS % exceeds the outstanding balance of GHS % on order %.',
        to_char(v_alloc.amount, 'FM999,999,990.00'), to_char(v_status.outstanding_ghs, 'FM999,999,990.00'), v_alloc.order_id;
    END IF;

    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, created_by)
    VALUES (p_wholesaler_id, p_pharmacy_id, v_alloc.order_id, 'payment', 'credit', v_alloc.amount, v_payment_id, auth.uid())
    RETURNING id INTO v_entry_id;

    INSERT INTO public.credit_payment_allocations (payment_id, order_id, amount_ghs, ledger_entry_id)
    VALUES (v_payment_id, v_alloc.order_id, v_alloc.amount, v_entry_id);

    IF v_alloc.amount >= v_status.outstanding_ghs AND v_order.payment_status <> 'paid' THEN
      UPDATE public.orders SET payment_status = 'paid', paid_at = COALESCE(paid_at, v_paid_at),
        payment_confirmed_at = now(), payment_confirmed_by = auth.uid()
      WHERE id = v_alloc.order_id;
    END IF;
  END LOOP;

  v_unallocated := round(p_amount, 2) - v_alloc_sum;
  IF v_unallocated > 0 THEN
    INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, created_by, note)
    VALUES (p_wholesaler_id, p_pharmacy_id, NULL, 'payment', 'credit', v_unallocated, v_payment_id, auth.uid(), 'Unallocated credit on account.');
  END IF;

  PERFORM public.write_audit_log('Credit payment recorded', v_wholesaler_name, 'business', p_pharmacy_id, v_pharmacy_name,
    jsonb_build_object('payment_id', v_payment_id, 'amount_ghs', p_amount, 'method', p_method, 'allocated_ghs', v_alloc_sum, 'unallocated_ghs', v_unallocated),
    _business_id => p_wholesaler_id);

  RETURN jsonb_build_object('payment_id', v_payment_id, 'amount_ghs', p_amount, 'allocated_ghs', v_alloc_sum, 'unallocated_ghs', v_unallocated);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_credit_adjustment(
  p_wholesaler_id UUID,
  p_pharmacy_id UUID,
  p_order_id UUID,
  p_entry_type TEXT,
  p_direction TEXT,
  p_amount NUMERIC,
  p_note TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may record ledger adjustments.';
  END IF;
  IF p_entry_type NOT IN ('adjustment', 'credit_note', 'debit_note') THEN
    RAISE EXCEPTION 'Invalid adjustment type.';
  END IF;
  IF p_direction NOT IN ('debit', 'credit') THEN RAISE EXCEPTION 'Invalid direction.'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter an amount greater than zero.'; END IF;
  IF v_note IS NULL THEN RAISE EXCEPTION 'A reason is required for a ledger adjustment.'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN RAISE EXCEPTION 'The reason is too long (500 characters maximum).'; END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = p_wholesaler_id AND type = 'wholesaler';
  IF v_wholesaler_name IS NULL THEN RAISE EXCEPTION 'Wholesaler workspace not found.'; END IF;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = p_pharmacy_id AND type = 'pharmacy';
  IF v_pharmacy_name IS NULL THEN RAISE EXCEPTION 'Pharmacy workspace not found.'; END IF;

  IF p_order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders o WHERE o.id = p_order_id AND o.wholesaler_id = p_wholesaler_id AND o.pharmacy_id = p_pharmacy_id AND o.is_credit_order
  ) THEN
    RAISE EXCEPTION 'Order is not a credit order between these two businesses.';
  END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note)
  VALUES (p_wholesaler_id, p_pharmacy_id, p_order_id, p_entry_type, p_direction, round(p_amount, 2), auth.uid(), v_note)
  RETURNING id INTO v_entry_id;

  PERFORM public.write_audit_log('Credit ledger adjustment recorded', v_wholesaler_name, 'business', p_pharmacy_id, v_pharmacy_name,
    jsonb_build_object('entry_id', v_entry_id, 'entry_type', p_entry_type, 'direction', p_direction, 'amount_ghs', p_amount, 'order_id', p_order_id, 'reason', v_note),
    _business_id => p_wholesaler_id);

  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.write_off_credit_invoice(p_order_id UUID, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_status RECORD;
  v_entry_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.order_number INTO v_order
  FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN RAISE EXCEPTION 'Credit invoice not found.'; END IF;
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(v_order.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may write off a credit invoice.';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to write off an invoice.'; END IF;

  SELECT * INTO v_status FROM public.credit_invoice_status(p_order_id);
  IF v_status.outstanding_ghs <= 0 THEN RAISE EXCEPTION 'This invoice has no outstanding balance to write off.'; END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, created_by, note)
  VALUES (v_order.wholesaler_id, v_order.pharmacy_id, p_order_id, 'write_off', 'credit', v_status.outstanding_ghs, auth.uid(), v_reason)
  RETURNING id INTO v_entry_id;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_order.wholesaler_id;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_order.pharmacy_id;
  PERFORM public.write_audit_log('Credit invoice written off', v_wholesaler_name, 'order', p_order_id, v_order.order_number,
    jsonb_build_object('amount_ghs', v_status.outstanding_ghs, 'reason', v_reason),
    _business_id => v_order.wholesaler_id);

  RETURN v_entry_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.reverse_credit_ledger_entry(p_entry_id UUID, p_reason TEXT)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry RECORD;
  v_new_id UUID;
  v_wholesaler_name TEXT;
  v_pharmacy_name TEXT;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT * INTO v_entry FROM public.credit_ledger_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ledger entry not found.'; END IF;
  IF auth.uid() IS NULL OR NOT public.can_act_for_business(v_entry.wholesaler_id, 'manage') THEN
    RAISE EXCEPTION 'Only wholesaler owners and managers may reverse a ledger entry.';
  END IF;
  IF v_entry.entry_type = 'reversal' THEN RAISE EXCEPTION 'A reversal entry cannot itself be reversed.'; END IF;
  IF EXISTS (SELECT 1 FROM public.credit_ledger_entries WHERE reverses_entry_id = p_entry_id) THEN
    RAISE EXCEPTION 'This entry has already been reversed.';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to reverse a ledger entry.'; END IF;

  INSERT INTO public.credit_ledger_entries (wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, payment_id, reverses_entry_id, created_by, note)
  VALUES (v_entry.wholesaler_id, v_entry.pharmacy_id, v_entry.order_id, 'reversal',
    CASE v_entry.direction WHEN 'debit' THEN 'credit' ELSE 'debit' END,
    v_entry.amount_ghs, v_entry.payment_id, p_entry_id, auth.uid(), v_reason)
  RETURNING id INTO v_new_id;

  -- If the reversal reopens an order's balance, its payment_status needs to reflect that again.
  IF v_entry.order_id IS NOT NULL THEN
    UPDATE public.orders o SET payment_status = 'unpaid', paid_at = NULL, payment_confirmed_at = NULL, payment_confirmed_by = NULL
    WHERE o.id = v_entry.order_id AND o.payment_status = 'paid'
      AND (SELECT outstanding_ghs FROM public.credit_invoice_status(v_entry.order_id)) > 0;
  END IF;

  SELECT name INTO v_wholesaler_name FROM public.businesses WHERE id = v_entry.wholesaler_id;
  SELECT name INTO v_pharmacy_name FROM public.businesses WHERE id = v_entry.pharmacy_id;
  PERFORM public.write_audit_log('Credit ledger entry reversed', v_wholesaler_name, 'business', v_entry.pharmacy_id, v_pharmacy_name,
    jsonb_build_object('original_entry_id', p_entry_id, 'reversal_entry_id', v_new_id, 'amount_ghs', v_entry.amount_ghs, 'reason', v_reason),
    _business_id => v_entry.wholesaler_id);

  RETURN v_new_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_credit_invoice_dispute(p_order_id UUID, p_disputed BOOLEAN, p_reason TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT o.id, o.wholesaler_id, o.pharmacy_id, o.is_credit_order, o.order_number INTO v_order
  FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND OR NOT v_order.is_credit_order THEN RAISE EXCEPTION 'Credit invoice not found.'; END IF;

  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = v_order.wholesaler_id AND b.owner_id = auth.uid()) INTO v_is_owner;
  v_role := public.get_staff_role(auth.uid(), v_order.wholesaler_id);
  IF NOT v_is_owner AND (v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'accountant')) THEN
    RAISE EXCEPTION 'You do not have permission to dispute this invoice.';
  END IF;
  IF p_disputed AND v_reason IS NULL THEN RAISE EXCEPTION 'A reason is required to mark an invoice disputed.'; END IF;

  UPDATE public.orders SET
    credit_disputed_at = CASE WHEN p_disputed THEN now() ELSE NULL END,
    credit_dispute_reason = CASE WHEN p_disputed THEN v_reason ELSE NULL END
  WHERE id = p_order_id;

  PERFORM public.write_audit_log(
    CASE WHEN p_disputed THEN 'Credit invoice disputed' ELSE 'Credit invoice dispute cleared' END,
    (SELECT name FROM public.businesses WHERE id = v_order.wholesaler_id), 'order', p_order_id, v_order.order_number,
    jsonb_build_object('reason', v_reason), _business_id => v_order.wholesaler_id);
END;
$$;

REVOKE ALL ON FUNCTION public.record_credit_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_credit_payment(UUID, UUID, NUMERIC, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT, JSONB) TO authenticated;
REVOKE ALL ON FUNCTION public.record_credit_adjustment(UUID, UUID, UUID, TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_credit_adjustment(UUID, UUID, UUID, TEXT, TEXT, NUMERIC, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.write_off_credit_invoice(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.write_off_credit_invoice(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.reverse_credit_ledger_entry(UUID, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reverse_credit_ledger_entry(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.set_credit_invoice_dispute(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_credit_invoice_dispute(UUID, BOOLEAN, TEXT) TO authenticated;

-- ---------------------------------------------------------------------------
-- preview_pharmacy_inventory_import -- unchanged except the write_audit_log call gains a trailing
-- _business_id argument.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.preview_pharmacy_inventory_import(
  p_pharmacy_id UUID,
  p_items JSONB,
  p_mode TEXT,
  p_confirm_token TEXT DEFAULT NULL,
  p_request_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  biz public.businesses%ROWTYPE;
  old_item public.pharmacy_inventory_items%ROWTYPE;
  item JSONB;
  plan JSONB := '[]';
  problems JSONB := '[]';
  seen TEXT[] := '{}';
  identity_key TEXT;
  matches INTEGER;
  new_stock BIGINT;
  input_stock BIGINT;
  input_cost NUMERIC;
  token TEXT;
  payload_hash TEXT;
  prior public.pharmacy_inventory_import_runs%ROWTYPE;
  result JSONB;
  inserted_count INTEGER := 0;
  updated_count INTEGER := 0;
  saved_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in before importing.'; END IF;
  SELECT * INTO biz FROM public.businesses WHERE id = p_pharmacy_id FOR SHARE;
  IF NOT FOUND OR biz.type <> 'pharmacy' OR biz.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'An approved pharmacy account is required.';
  END IF;
  IF NOT public.can_act_for_business(p_pharmacy_id, 'manage') THEN
    RAISE EXCEPTION 'Only owners and managers can import inventory.';
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('replace', 'add', 'details') THEN RAISE EXCEPTION 'Invalid import mode.'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Expected an item array.'; END IF;
  IF jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 5000 THEN
    RAISE EXCEPTION 'Import between 1 and 5000 items at a time.';
  END IF;

  payload_hash := md5(p_items::TEXT || p_mode || p_pharmacy_id::TEXT);
  IF p_confirm_token IS NOT NULL THEN
    IF p_request_id IS NULL THEN RAISE EXCEPTION 'An import request ID is required.'; END IF;
    LOCK TABLE public.pharmacy_inventory_items IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO prior FROM public.pharmacy_inventory_import_runs WHERE id = p_request_id;
    IF FOUND THEN
      IF prior.created_by <> auth.uid() OR prior.pharmacy_id <> p_pharmacy_id OR prior.payload_hash <> payload_hash THEN
        RAISE EXCEPTION 'Import request ID already used for different data.';
      END IF;
      RETURN prior.result;
    END IF;
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object' OR NULLIF(btrim(item->>'name'), '') IS NULL THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Missing item name.'));
      CONTINUE;
    END IF;
    IF item->>'stock' IS NOT NULL AND item->>'stock' !~ '^[0-9]+$' THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Stock must be a whole number.'));
      CONTINUE;
    END IF;
    IF COALESCE((item->>'stock')::NUMERIC, 0) > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Stock is outside the allowed range.'));
      CONTINUE;
    END IF;
    input_stock := (item->>'stock')::BIGINT;
    input_cost := NULLIF(item->>'unitCostGhs', '')::NUMERIC;

    identity_key := public.product_import_identity(item->>'name', item->>'brand', item->>'form', item->>'pack_size');
    IF identity_key = ANY(seen) THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Duplicate row: remove repeated item identities before importing.'));
      CONTINUE;
    END IF;
    seen := array_append(seen, identity_key);

    SELECT count(*) INTO matches FROM public.pharmacy_inventory_items i WHERE i.pharmacy_id = p_pharmacy_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = identity_key;
    IF matches > 1 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Multiple existing items match. Resolve the collision first.'));
      CONTINUE;
    END IF;

    SELECT * INTO old_item FROM public.pharmacy_inventory_items i WHERE i.pharmacy_id = p_pharmacy_id
      AND public.product_import_identity(i.name, i.brand, i.form, i.pack_size) = identity_key;

    new_stock := CASE
      WHEN p_mode = 'details' THEN COALESCE(old_item.stock, 0)
      WHEN input_stock IS NULL THEN COALESCE(old_item.stock, 0)
      WHEN p_mode = 'add' THEN COALESCE(old_item.stock, 0)::BIGINT + input_stock
      ELSE input_stock END;
    IF new_stock > 2147483647 THEN
      problems := problems || jsonb_build_array(jsonb_build_object('row', item->'source_row', 'message', 'Resulting stock exceeds the allowed range.'));
      CONTINUE;
    END IF;

    plan := plan || jsonb_build_array(jsonb_build_object(
      'row', item->'source_row', 'id', old_item.id, 'name', btrim(item->>'name'),
      'kind', CASE WHEN old_item.id IS NULL THEN 'new' ELSE 'existing' END,
      'stock_before', old_item.stock, 'stock_after', new_stock,
      'cost_before', old_item.unit_cost_ghs, 'cost_after', COALESCE(input_cost, old_item.unit_cost_ghs),
      'item', item
    ));
  END LOOP;

  token := md5(plan::TEXT || problems::TEXT || payload_hash);
  result := jsonb_build_object('rows', plan, 'issues', problems, 'token', token, 'mode', p_mode);
  IF p_confirm_token IS NULL THEN RETURN result; END IF;
  IF jsonb_array_length(problems) > 0 THEN RAISE EXCEPTION 'Fix all import issues before confirming.'; END IF;
  IF p_confirm_token <> token THEN RAISE EXCEPTION 'Inventory changed since preview. Generate a new preview before confirming.'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(plan) LOOP
    IF item->>'id' IS NULL THEN
      INSERT INTO public.pharmacy_inventory_items (pharmacy_id, name, brand, category, form, pack_size, stock, reorder_level, unit_cost_ghs)
      VALUES (p_pharmacy_id, item->>'name', NULLIF(btrim(item#>>'{item,brand}'), ''),
        NULLIF(btrim(item#>>'{item,category}'), ''), NULLIF(btrim(item#>>'{item,form}'), ''),
        NULLIF(btrim(item#>>'{item,pack_size}'), ''), (item->>'stock_after')::INTEGER,
        NULLIF(item#>>'{item,reorderLevel}', '')::INTEGER, (item->>'cost_after')::NUMERIC)
      RETURNING id INTO saved_id;
      inserted_count := inserted_count + 1;
    ELSE
      saved_id := (item->>'id')::UUID;
      UPDATE public.pharmacy_inventory_items SET
        name = item->>'name', brand = NULLIF(btrim(item#>>'{item,brand}'), ''),
        category = NULLIF(btrim(item#>>'{item,category}'), ''), form = NULLIF(btrim(item#>>'{item,form}'), ''),
        pack_size = NULLIF(btrim(item#>>'{item,pack_size}'), ''), stock = (item->>'stock_after')::INTEGER,
        reorder_level = COALESCE(NULLIF(item#>>'{item,reorderLevel}', '')::INTEGER, reorder_level),
        unit_cost_ghs = (item->>'cost_after')::NUMERIC
      WHERE id = saved_id;
      updated_count := updated_count + 1;
    END IF;

    IF COALESCE((item->>'stock_before')::INTEGER, 0) <> (item->>'stock_after')::INTEGER THEN
      INSERT INTO public.pharmacy_inventory_movements (item_id, pharmacy_id, kind, quantity_delta, stock_after, note, created_by)
      VALUES (saved_id, p_pharmacy_id, 'import', (item->>'stock_after')::INTEGER - COALESCE((item->>'stock_before')::INTEGER, 0),
        (item->>'stock_after')::INTEGER, 'Bulk import (' || p_mode || ')', auth.uid());
    END IF;

    PERFORM public.write_audit_log('Pharmacy inventory imported', biz.name, 'pharmacy_inventory_item', saved_id, item->>'name',
      jsonb_build_object('request_id', p_request_id, 'mode', p_mode, 'stock_before', item->'stock_before', 'stock_after', item->'stock_after'),
      _business_id => p_pharmacy_id);
  END LOOP;

  result := result || jsonb_build_object('inserted_count', inserted_count, 'updated_count', updated_count);
  INSERT INTO public.pharmacy_inventory_import_runs (id, pharmacy_id, created_by, payload_hash, result)
    VALUES (p_request_id, p_pharmacy_id, auth.uid(), payload_hash, result);
  RETURN result;
END;
$$;
REVOKE ALL ON FUNCTION public.preview_pharmacy_inventory_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.preview_pharmacy_inventory_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- preview_wholesaler_import: add attribution to the DEPLOYED implementation.
-- Production has inventory_operation_context handling and blank-form normalization that
-- are absent from the older repository definition. Replacing the full function would
-- silently discard those protections. Patch only its single Inventory imported audit call.
-- Fail closed if that call is missing/ambiguous; rerunning this migration is a no-op here.
-- ---------------------------------------------------------------------------
DO $migration$
DECLARE
  definition TEXT;
  audit_call TEXT;
  patched_call TEXT;
  call_count INTEGER;
BEGIN
  SELECT pg_get_functiondef('public.preview_wholesaler_import(uuid,jsonb,text,text,uuid)'::regprocedure)
    INTO definition;
  SELECT count(*), min(m[1]) INTO call_count, audit_call
  FROM regexp_matches(definition,
    $pattern$PERFORM public[.]write_audit_log[(]'Inventory imported'[^;]*[)];$pattern$, 'g') AS m;
  IF call_count <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one Inventory imported audit call; inspect the deployed preview_wholesaler_import before migrating.';
  END IF;
  IF audit_call ~ '_business_id[[:space:]]*=>' THEN
    IF audit_call !~ '_business_id[[:space:]]*=>[[:space:]]*_business_id[[:space:]]*[)][;]$' THEN
      RAISE EXCEPTION 'Unexpected existing import audit attribution; inspect before migrating.';
    END IF;
  ELSE
    patched_call := regexp_replace(audit_call, '[)][;]$', ', _business_id => _business_id);');
    EXECUTE replace(definition, audit_call, patched_call);
  END IF;
END;
$migration$;
REVOKE ALL ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.preview_wholesaler_import(UUID, JSONB, TEXT, TEXT, UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- list_audit_log: the read RPC behind the Audit Centre UI. Owner/manager/accountant of the given
-- business only (matches §27's "View audit logs: Yes" for accountants, and the people who'd
-- reasonably need this). Only returns rows that have business_id set -- see the schema migration's
-- header comment for which call sites that currently covers.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_audit_log(
  p_business_id UUID,
  p_from TIMESTAMPTZ DEFAULT NULL,
  p_to TIMESTAMPTZ DEFAULT NULL,
  p_record_type TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_cursor_created_at TIMESTAMPTZ DEFAULT NULL,
  p_cursor_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  activity TEXT,
  record_type TEXT,
  record_id UUID,
  record_label TEXT,
  performed_by_email TEXT,
  details JSONB,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role public.staff_role;
  v_is_owner BOOLEAN;
  v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = p_business_id AND b.owner_id = auth.uid()) INTO v_is_owner;
  v_role := public.get_staff_role(auth.uid(), p_business_id);
  IF NOT v_is_owner AND (v_role IS NULL OR v_role::TEXT NOT IN ('owner', 'manager', 'accountant')) THEN
    RAISE EXCEPTION 'You do not have permission to view this business''s audit log.';
  END IF;

  RETURN QUERY
  SELECT a.id, a.activity, a.record_type, a.record_id, a.record_label, a.performed_by_email, a.details, a.created_at
  FROM public.audit_logs a
  WHERE a.business_id = p_business_id
    AND (p_from IS NULL OR a.created_at >= p_from)
    AND (p_to IS NULL OR a.created_at < p_to)
    AND (p_record_type IS NULL OR a.record_type = p_record_type)
    AND (
      p_search IS NULL OR NULLIF(btrim(p_search), '') IS NULL
      OR a.activity ILIKE '%' || p_search || '%' OR a.record_label ILIKE '%' || p_search || '%'
    )
    AND (
      p_cursor_created_at IS NULL OR p_cursor_id IS NULL
      OR (a.created_at, a.id) < (p_cursor_created_at, p_cursor_id)
    )
  ORDER BY a.created_at DESC, a.id DESC
  LIMIT v_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.list_audit_log(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_audit_log(UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT, TIMESTAMPTZ, UUID, INTEGER) TO authenticated;
