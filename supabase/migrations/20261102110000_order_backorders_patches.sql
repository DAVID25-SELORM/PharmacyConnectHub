-- Order amendments, Phase 3 part 2: fail-closed in-place patches that back-orders need in existing code. Each rebuilds the LIVE
-- definition with exact fragments replaced, stops without changing anything if the function is not what was expected, and is
-- safe to re-run (uses apply_function_patch / apply_function_regex_patch from the earlier phases).
--
--   1. inventory_movements may record 'backorder_dispatch_deduction' (once per order, product and shipment).
--   2. The cancel-restore only counts stock released or written off by proposals (not stock deducted by a shipment).
--   3. Reports, returns and the pharmacy order list count everything that has been supplied: the main shipment's quantity plus
--      back-order units already dispatched (order_item_fulfilled_qty), not just the main shipment's.
--   4. The customer statement shows each dispatched back-order shipment as a charge on the date it was dispatched.
--   5. orders.effective_total_ghs can only change inside an approved amendment or shipment, never by editing the row; the same
--      approved path may reopen a paid credit order's payment state, which warehouse staff otherwise may not touch.

-- ---------------------------------------------------------------------------
-- 1. Inventory ledger: the back-order dispatch deduction
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def TEXT;
  v_literals INTEGER;
BEGIN
  IF to_regclass('public.inventory_movements') IS NULL THEN
    RETURN;
  END IF;
  SELECT pg_get_constraintdef(c.oid) INTO v_def FROM pg_constraint c
  WHERE c.conrelid = 'public.inventory_movements'::regclass AND c.conname = 'inventory_movements_movement_type_check';
  IF v_def IS NULL THEN
    RAISE EXCEPTION 'inventory_movements has no movement type check; inspect before extending it.';
  END IF;
  IF position('backorder_dispatch_deduction' IN v_def) = 0 THEN
    SELECT count(*) INTO v_literals FROM regexp_matches(v_def, '''[a-z_]+''', 'g');
    IF v_literals <> 10 OR v_def NOT LIKE '%order_amendment_release%' OR v_def NOT LIKE '%checkout_deduction%'
       OR v_def NOT LIKE '%order_cancellation_restore%' OR v_def NOT LIKE '%admin_adjustment%' THEN
      RAISE EXCEPTION 'Unexpected movement types in inventory_movements (%). Run the order-amendment patches first. Nothing was changed.', v_def;
    END IF;
    ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
    ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check CHECK (movement_type = ANY (ARRAY[
      'product_created', 'manual_add', 'manual_remove', 'manual_reconciliation', 'checkout_deduction',
      'order_cancellation_restore', 'import_add', 'import_replace', 'admin_adjustment', 'order_amendment_release',
      'backorder_dispatch_deduction']));
  END IF;
  CREATE UNIQUE INDEX IF NOT EXISTS inventory_backorder_dispatch_once
    ON public.inventory_movements (order_id, product_id, request_id) WHERE movement_type = 'backorder_dispatch_deduction';
END $$;

-- ---------------------------------------------------------------------------
-- 2. Cancel-restore counts only what proposals released or wrote off
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.order_amendment_stock_taken(p_order_id UUID, p_product_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(m.quantity), 0)::INTEGER FROM public.order_stock_movements m
  WHERE m.order_id = p_order_id AND m.product_id = p_product_id AND m.kind IN ('shortage_release', 'shortage_write_off')
$$;

-- ---------------------------------------------------------------------------
-- 3. Readers count what has been supplied so far (main shipment + dispatched back-order units)
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('admin_report_wholesaler_performance', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 1, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('wholesaler_report_overview', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 1, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('pharmacy_report_products', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 3, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 2, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases_summary', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 6, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('wholesaler_report_products', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 3, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('wholesaler_inventory_insights', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 2, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('wholesaler_customer_detail', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 3, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('list_pharmacy_order_history', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 1, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('get_order_print', 'order_item_supplied_qty\(i\.id\)', 'order_item_fulfilled_qty(i.id)', 2, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('get_returnable_items', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 1, 'order_item_fulfilled_qty');
SELECT public.apply_function_regex_patch('request_order_return', 'order_item_supplied_qty\(oi\.id\)', 'order_item_fulfilled_qty(oi.id)', 1, 'order_item_fulfilled_qty');

-- ---------------------------------------------------------------------------
-- 4. Statement: a dispatched back-order shipment is a charge on its dispatch date
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('customer_statement',
  'SELECT a\.applied_at, ''adjustment'',',
  'SELECT s.dispatched_at, ''shipment'', ''debit'', s.order_id, so.order_number, s.amount_ghs, 0::NUMERIC' || E'\n'
  || '    FROM public.order_shipments s JOIN public.orders so ON so.id = s.order_id' || E'\n'
  || '    WHERE so.wholesaler_id = p_wholesaler_id AND so.pharmacy_id = p_pharmacy_id AND s.status IN (''dispatched'', ''delivered'') AND s.amount_ghs > 0' || E'\n'
  || '      AND so.status <> ''cancelled'' AND so.payment_status <> ''refunded''' || E'\n'
  || '    UNION ALL' || E'\n'
  || '    SELECT a.applied_at, ''adjustment'',',
  1, '''shipment''');

-- ---------------------------------------------------------------------------
-- 5. The order total only moves through an approved supply change or shipment
-- ---------------------------------------------------------------------------
-- Staff of the wholesaler may update order rows (status, payment...), so without this guard they could edit
-- effective_total_ghs directly and change what a pharmacy owes without its approval. The approved functions announce
-- themselves with a transaction-local setting (set_config is not exposed to API users); anything else is refused, including
-- ad-hoc SQL, which must set the same value deliberately.
CREATE OR REPLACE FUNCTION public.protect_effective_total()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.effective_total_ghs IS DISTINCT FROM OLD.effective_total_ghs
     AND COALESCE(current_setting('drugxone.amendment_txid', true), '') <> txid_current()::TEXT THEN
    RAISE EXCEPTION 'The order total can only change through an approved supply change or back-order shipment.';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_protect_effective_total ON public.orders;
CREATE TRIGGER trg_protect_effective_total BEFORE UPDATE OF effective_total_ghs ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.protect_effective_total();

-- Warehouse staff may never change payment details, but dispatching a back-order shipment reopens a paid credit order's payment
-- state automatically; allow exactly that, inside the approved path only.
SELECT public.apply_function_patch(
  'public.enforce_wholesaler_staff_order_scope()',
  'IF v_role = ''warehouse'' THEN',
  'IF v_role = ''warehouse'' AND COALESCE(current_setting(''drugxone.amendment_txid'', true), '''') <> txid_current()::TEXT THEN',
  'drugxone.amendment_txid');
