-- Order amendments, Phase 2 part 2: the small, fail-closed in-place patches that existing functions need so they stay
-- correct once an order can be partly cancelled. Each patch rebuilds the LIVE definition of the function with one exact
-- fragment replaced; if the live function is not exactly what is expected the whole migration stops and nothing is
-- changed. Re-running it is safe (an already-patched function is recognised and left alone).
--
--   1. inventory_movements may record the new movement type 'order_amendment_release' (and only once per order, product
--      and amendment).
--   2. Cancelling an order restores only what is still deducted: units already released back to stock, or written off
--      as non-existent, by an accepted amendment are not restored a second time.
--   3. credit_invoice_status() counts an amendment credit note as a reduction of the invoice, not as a payment, so
--      "paid" and "outstanding" stay honest on a partly cancelled credit order.
--   4. Pick suggestions and batch confirmation use the quantity the wholesaler is committed to supply, not the original.

-- ---------------------------------------------------------------------------
-- Helper: replace exactly one fragment of a function's live definition.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_function_patch(p_signature TEXT, p_old TEXT, p_new TEXT, p_applied_marker TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_proc REGPROCEDURE := to_regprocedure(p_signature);
  v_def TEXT;
  v_count INTEGER;
BEGIN
  IF v_proc IS NULL THEN
    RAISE EXCEPTION 'Function % does not exist; inspect before patching.', p_signature;
  END IF;
  v_def := replace(pg_get_functiondef(v_proc), E'\r', '');
  IF position(p_applied_marker IN v_def) > 0 THEN
    RETURN 'already patched';
  END IF;
  v_count := (length(v_def) - length(replace(v_def, p_old, ''))) / length(p_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Unexpected definition of % (expected the fragment exactly once, found % times). Nothing was changed.', p_signature, v_count;
  END IF;
  EXECUTE replace(v_def, p_old, p_new);
  RETURN 'patched';
END;
$$;
REVOKE ALL ON FUNCTION public.apply_function_patch(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. The inventory ledger accepts the amendment release movement
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def TEXT;
  v_literals INTEGER;
BEGIN
  IF to_regclass('public.inventory_movements') IS NULL THEN
    RETURN; -- no stock ledger in this database: nothing to extend
  END IF;
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
  WHERE c.conrelid = 'public.inventory_movements'::regclass AND c.conname = 'inventory_movements_movement_type_check';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'inventory_movements has no movement type check; inspect before extending it.';
  END IF;
  IF position('order_amendment_release' IN v_def) = 0 THEN
    SELECT count(*) INTO v_literals FROM regexp_matches(v_def, '''[a-z_]+''', 'g');
    IF v_literals <> 9
       OR v_def NOT LIKE '%product_created%' OR v_def NOT LIKE '%manual_add%' OR v_def NOT LIKE '%manual_remove%'
       OR v_def NOT LIKE '%manual_reconciliation%' OR v_def NOT LIKE '%checkout_deduction%'
       OR v_def NOT LIKE '%order_cancellation_restore%' OR v_def NOT LIKE '%import_add%'
       OR v_def NOT LIKE '%import_replace%' OR v_def NOT LIKE '%admin_adjustment%'
    THEN
      RAISE EXCEPTION 'Unexpected movement types in inventory_movements (%). Nothing was changed.', v_def;
    END IF;
    ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
    ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check CHECK (movement_type = ANY (ARRAY[
      'product_created', 'manual_add', 'manual_remove', 'manual_reconciliation', 'checkout_deduction',
      'order_cancellation_restore', 'import_add', 'import_replace', 'admin_adjustment', 'order_amendment_release']));
  END IF;
  -- A release is applied once per (order, product, amendment); the amendment id travels as the request id.
  CREATE UNIQUE INDEX IF NOT EXISTS inventory_amendment_release_once
    ON public.inventory_movements (order_id, product_id, request_id) WHERE movement_type = 'order_amendment_release';
END $$;

-- ---------------------------------------------------------------------------
-- 2. Cancellation restores only what is still deducted (production's strict evidence-based restore)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regclass('public.order_stock_deductions') IS NOT NULL
     AND to_regprocedure('public.restore_stock_for_cancelled_order()') IS NOT NULL THEN
    PERFORM public.apply_function_patch(
      'public.restore_stock_for_cancelled_order()',
      'stock = stock + deduction.quantity WHERE',
      'stock = stock + GREATEST(deduction.quantity - public.order_amendment_stock_taken(NEW.id, deduction.product_id), 0) WHERE',
      'order_amendment_stock_taken');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. An amendment credit note reduces the invoice instead of counting as a payment
-- ---------------------------------------------------------------------------
SELECT public.apply_function_patch(
  'public.credit_invoice_status(uuid)',
  'SELECT COALESCE(SUM(amount_ghs) FILTER (WHERE entry_type = ''invoice''), 0),',
  'SELECT COALESCE(SUM(amount_ghs) FILTER (WHERE entry_type = ''invoice''), 0) + COALESCE(SUM(CASE direction WHEN ''debit'' THEN amount_ghs ELSE -amount_ghs END) FILTER (WHERE amendment_id IS NOT NULL), 0),',
  'amendment_id IS NOT NULL');

-- ---------------------------------------------------------------------------
-- 4. Picking works from the supplied quantity
-- ---------------------------------------------------------------------------
SELECT public.apply_function_patch(
  'public.suggest_order_picks(uuid)',
  'SELECT oi.id, oi.product_id, oi.product_name, oi.quantity FROM public.order_items oi',
  'SELECT oi.id, oi.product_id, oi.product_name, public.order_item_supplied_qty(oi.id) AS quantity FROM public.order_items oi',
  'order_item_supplied_qty');
SELECT public.apply_function_patch(
  'public.confirm_order_picks(uuid)',
  'SELECT oi.id, oi.product_id, oi.quantity FROM public.order_items oi',
  'SELECT oi.id, oi.product_id, public.order_item_supplied_qty(oi.id) AS quantity FROM public.order_items oi',
  'order_item_supplied_qty');
