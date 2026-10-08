-- Order amendments, Phase 6: every reader of an order's total or quantities now sees an amended order as amended.
--
-- An accepted partial supply sets orders.effective_total_ghs (NULL = never amended) and reduces the quantity the
-- wholesaler is committed to supply per line (order_item_supplied_qty). The placed total and the order lines are never
-- edited, so every report, list, statement and receipt that read them would otherwise overstate sales, spend,
-- outstanding amounts and units for an amended order. This migration moves those readers over, in place:
--
--   * totals:     o.total_ghs  ->  COALESCE(o.effective_total_ghs, o.total_ghs)         (reports use the original order date)
--   * quantities: oi.quantity  ->  public.order_item_supplied_qty(oi.id)               (units sold / purchased)
--   * lists:      the order lists also return effective_total_ghs, and sort by it
--   * statement:  the order stays at its placed amount on its own date; the accepted reduction appears as a separate
--                 "adjustment" line on the date it was accepted, so a statement already issued for an earlier period
--                 never changes retroactively
--   * returns:    a pharmacy can only return what it was actually supplied
--   * receipts:   order_receipt_supply() gives the receipt endpoints the amended quantities and total
--
-- For an order that was never amended every replacement returns exactly what the old expression returned, so existing
-- results do not change. Each patch rebuilds the LIVE definition with one expression replaced, must match exactly the
-- expected number of times, and otherwise stops the whole migration without changing anything. Re-running is safe.
--
-- Deliberately NOT changed: pharmacy_price_history* (they report the unit price paid, which an amendment never changes),
-- get_order_reorder_lines (reordering what was ordered is the useful default), the credit ledger readers
-- (get_credit_invoice, credit_invoice_status: they already read the ledger, which carries the credit note).

-- ---------------------------------------------------------------------------
-- Helper: replace a regular expression in a function's live definition, a fixed number of times.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_function_regex_patch(
  p_function_name TEXT, p_pattern TEXT, p_replacement TEXT, p_expected INTEGER, p_applied_marker TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_oids OID[];
  v_def TEXT;
  v_count INTEGER;
BEGIN
  SELECT array_agg(p.oid) INTO v_oids FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_function_name;
  IF v_oids IS NULL THEN
    RETURN 'not present';
  END IF;
  IF array_length(v_oids, 1) <> 1 THEN
    RAISE EXCEPTION 'Function % has % overloads; patch it by signature instead. Nothing was changed.', p_function_name, array_length(v_oids, 1);
  END IF;
  v_def := replace(pg_get_functiondef(v_oids[1]), E'\r', '');
  IF position(p_applied_marker IN v_def) > 0 THEN
    RETURN 'already patched';
  END IF;
  SELECT count(*) INTO v_count FROM regexp_matches(v_def, p_pattern, 'g');
  IF v_count <> p_expected THEN
    RAISE EXCEPTION 'Unexpected definition of % (expected % match(es) of %, found %). Nothing was changed.', p_function_name, p_expected, p_pattern, v_count;
  END IF;
  EXECUTE regexp_replace(v_def, p_pattern, p_replacement, 'g');
  RETURN 'patched';
END;
$$;
REVOKE ALL ON FUNCTION public.apply_function_regex_patch(TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;

-- The reports run as the signed-in user (SECURITY INVOKER), so they must be able to call the quantity helper. It returns
-- one integer for an order-line id the caller already holds; ids are random UUIDs and cannot be enumerated.
GRANT EXECUTE ON FUNCTION public.order_item_supplied_qty(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1. Totals in reports (o / o2 alias an orders row in every one of these)
-- ---------------------------------------------------------------------------
-- COALESCE(o.effective_total_ghs, o.total_ghs) for every plain o.total_ghs.
SELECT public.apply_function_regex_patch('admin_platform_summary',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 1, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('admin_report_overview',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 3, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('admin_report_payments',
  'SUM\(o\.total_ghs\)', 'SUM(COALESCE(o.effective_total_ghs, o.total_ghs))', 2, 'SUM(COALESCE(o.effective_total_ghs, o.total_ghs))');
SELECT public.apply_function_regex_patch('admin_report_payments',
  'o\.payment_method, o\.total_ghs, o\.payment_status', 'o.payment_method, COALESCE(o.effective_total_ghs, o.total_ghs) AS total_ghs, o.payment_status', 1,
  'COALESCE(o.effective_total_ghs, o.total_ghs) AS total_ghs');
SELECT public.apply_function_regex_patch('admin_report_pharmacy_activity',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 3, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
-- admin_report_sales: plain totals first (not the subtotal fallback), then the gross-sales expression.
SELECT public.apply_function_regex_patch('admin_report_sales',
  '(?<!o\.subtotal_ghs, )\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 2, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('admin_report_sales',
  'COALESCE\(o\.subtotal_ghs, o\.total_ghs\)',
  'CASE WHEN o.effective_total_ghs IS NOT NULL THEN GREATEST(o.effective_total_ghs - COALESCE(o.delivery_fee_ghs, 0), 0) ELSE COALESCE(o.subtotal_ghs, o.total_ghs) END', 1,
  'o.effective_total_ghs IS NOT NULL THEN GREATEST');
SELECT public.apply_function_regex_patch('admin_report_wholesaler_performance',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 3, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('admin_report_wholesaler_performance',
  '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 1, 'order_item_supplied_qty');

SELECT public.apply_function_regex_patch('pharmacy_report_overview',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 2, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('pharmacy_report_overview',
  '\mo2\.total_ghs\M', 'COALESCE(o2.effective_total_ghs, o2.total_ghs)', 1, 'COALESCE(o2.effective_total_ghs, o2.total_ghs)');
SELECT public.apply_function_regex_patch('pharmacy_report_supplier_spend',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 3, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('wholesaler_report_overview',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 2, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('wholesaler_report_overview',
  '\mo2\.total_ghs\M', 'COALESCE(o2.effective_total_ghs, o2.total_ghs)', 1, 'COALESCE(o2.effective_total_ghs, o2.total_ghs)');
SELECT public.apply_function_regex_patch('wholesaler_report_overview',
  '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 1, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('wholesaler_report_customers',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 3, 'COALESCE(o.effective_total_ghs, o.total_ghs)');
SELECT public.apply_function_regex_patch('wholesaler_customers',
  '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 2, 'COALESCE(o.effective_total_ghs, o.total_ghs)');

-- Order rows in the report tables: total is the effective total; an amended row's subtotal is the goods as supplied
-- (total less the unchanged delivery fee) and carries no order-level discount (that was granted on the quantities first
-- ordered), the same way the printed documents show it.
SELECT public.apply_function_regex_patch('pharmacy_report_orders',
  'COALESCE\(o\.subtotal_ghs, o\.total_ghs\), o\.discount_amount_ghs, o\.total_ghs,',
  'CASE WHEN o.effective_total_ghs IS NOT NULL THEN GREATEST(o.effective_total_ghs - COALESCE(o.delivery_fee_ghs, 0), 0) ELSE COALESCE(o.subtotal_ghs, o.total_ghs) END, CASE WHEN o.effective_total_ghs IS NOT NULL THEN 0 ELSE o.discount_amount_ghs END, COALESCE(o.effective_total_ghs, o.total_ghs),',
  1, 'o.effective_total_ghs IS NOT NULL THEN GREATEST');
SELECT public.apply_function_regex_patch('wholesaler_report_sales',
  'COALESCE\(o\.subtotal_ghs, o\.total_ghs\), o\.discount_amount_ghs, o\.total_ghs,',
  'CASE WHEN o.effective_total_ghs IS NOT NULL THEN GREATEST(o.effective_total_ghs - COALESCE(o.delivery_fee_ghs, 0), 0) ELSE COALESCE(o.subtotal_ghs, o.total_ghs) END, CASE WHEN o.effective_total_ghs IS NOT NULL THEN 0 ELSE o.discount_amount_ghs END, COALESCE(o.effective_total_ghs, o.total_ghs),',
  1, 'o.effective_total_ghs IS NOT NULL THEN GREATEST');

-- ---------------------------------------------------------------------------
-- 2. Units and line values in reports: what was supplied, not what was first ordered
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('pharmacy_report_products', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 3, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 2, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases_summary', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 6, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('wholesaler_report_products', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 3, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('wholesaler_inventory_insights', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 2, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('wholesaler_customer_detail', '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 3, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('wholesaler_customer_detail',
  'o\.payment_status, o\.total_ghs, o\.created_at', 'o.payment_status, COALESCE(o.effective_total_ghs, o.total_ghs) AS total_ghs, o.created_at', 1,
  'COALESCE(o.effective_total_ghs, o.total_ghs) AS total_ghs');

-- ---------------------------------------------------------------------------
-- 3. Pharmacy order list: return the effective total beside the placed one, sort by what is owed, count supplied units
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('list_pharmacy_order_history',
  'SELECT o\.id, o\.order_number, o\.status, o\.total_ghs, o\.created_at,',
  'SELECT o.id, o.order_number, o.status, o.total_ghs, o.effective_total_ghs, o.created_at,', 1, 'o.total_ghs, o.effective_total_ghs, o.created_at');
SELECT public.apply_function_regex_patch('list_pharmacy_order_history',
  'THEN total_ghs END', 'THEN COALESCE(effective_total_ghs, total_ghs) END', 4, 'THEN COALESCE(effective_total_ghs, total_ghs) END');
SELECT public.apply_function_regex_patch('list_pharmacy_order_history',
  '\moi\.quantity\M', 'public.order_item_supplied_qty(oi.id)', 1, 'order_item_supplied_qty');
-- list_wholesaler_order_queue is not patched: no screen calls it (the wholesaler screen reads the orders table directly) and its
-- production definition differs from the repository's, so a blind patch could not be verified.

-- get_order_print(business, order) exists only in production (it is not defined by any repository migration, and nothing in
-- the repository calls it). It prints an order's total and line quantities, so it follows the same rule. Skipped silently
-- where it does not exist; stops the migration if its production definition is not what was read on 9 Oct 2026.
SELECT public.apply_function_regex_patch('get_order_print',
  '\mpurchase\.total_ghs::TEXT', 'COALESCE(purchase.effective_total_ghs, purchase.total_ghs)::TEXT', 1,
  'COALESCE(purchase.effective_total_ghs, purchase.total_ghs)');
SELECT public.apply_function_regex_patch('get_order_print',
  '\mi\.quantity\M', 'public.order_item_supplied_qty(i.id)', 2, 'order_item_supplied_qty');

-- ---------------------------------------------------------------------------
-- 4. Returns: only what was supplied can come back
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('get_returnable_items',
  'GREATEST\(oi\.quantity - COALESCE\(c\.claimed, 0\), 0\)', 'GREATEST(public.order_item_supplied_qty(oi.id) - COALESCE(c.claimed, 0), 0)', 1, 'order_item_supplied_qty');
SELECT public.apply_function_regex_patch('request_order_return',
  'SELECT oi\.id, oi\.product_id, oi\.product_name, oi\.quantity, oi\.unit_price_ghs INTO v_oi',
  'SELECT oi.id, oi.product_id, oi.product_name, public.order_item_supplied_qty(oi.id) AS quantity, oi.unit_price_ghs INTO v_oi', 1, 'order_item_supplied_qty');

-- ---------------------------------------------------------------------------
-- 5. Customer statements: the placed order stays as it was; an accepted reduction is its own dated line
-- ---------------------------------------------------------------------------
-- (a) a cash order's payment line is for what was actually due; (b) the adjustment line.
SELECT public.apply_function_regex_patch('customer_statement',
  '\mo\.total_ghs, 0::NUMERIC', 'COALESCE(o.effective_total_ghs, o.total_ghs), 0::NUMERIC', 1,
  'COALESCE(o.effective_total_ghs, o.total_ghs), 0::NUMERIC');
SELECT public.apply_function_regex_patch('customer_statement',
  'SELECT c\.resolved_at, ''return'', ''credit'', c\.order_id, c\.return_number, c\.amount_ghs, 0::NUMERIC',
  'SELECT a.applied_at, ''adjustment'', CASE WHEN a.delta_ghs < 0 THEN ''credit'' ELSE ''debit'' END, a.order_id, ao.order_number, abs(a.delta_ghs), 0::NUMERIC' || E'\n'
  || '    FROM public.order_amendments a JOIN public.orders ao ON ao.id = a.order_id' || E'\n'
  || '    WHERE ao.wholesaler_id = p_wholesaler_id AND ao.pharmacy_id = p_pharmacy_id AND a.status = ''accepted'' AND a.delta_ghs <> 0' || E'\n'
  || '      AND ao.status <> ''cancelled'' AND ao.payment_status <> ''refunded''' || E'\n'
  || '    UNION ALL' || E'\n'
  || '    SELECT c.resolved_at, ''return'', ''credit'', c.order_id, c.return_number, c.amount_ghs, 0::NUMERIC',
  1, '''adjustment''');

-- ---------------------------------------------------------------------------
-- 6. What a receipt email must show for an amended order (used by the receipt endpoints)
-- ---------------------------------------------------------------------------
-- NULL for an order that was never amended. The caller is either a service-role endpoint or a signed-in member of the
-- order's wholesaler or pharmacy.
CREATE OR REPLACE FUNCTION public.order_receipt_supply(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order RECORD;
BEGIN
  SELECT o.id, o.pharmacy_id, o.wholesaler_id, o.total_ghs, o.effective_total_ghs, o.delivery_fee_ghs
  INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
    IF NOT (public.can_act_for_business(v_order.wholesaler_id, 'read') OR public.can_act_for_business(v_order.pharmacy_id, 'read')
            OR public.has_role(auth.uid(), 'admin')) THEN
      RAISE EXCEPTION 'You do not have access to this order.';
    END IF;
  END IF;
  IF v_order.effective_total_ghs IS NULL AND NOT EXISTS (SELECT 1 FROM public.order_amendments a WHERE a.order_id = p_order_id AND a.status = 'accepted') THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'effective_total_ghs', COALESCE(v_order.effective_total_ghs, v_order.total_ghs),
    'delivery_fee_ghs', v_order.delivery_fee_ghs,
    'lines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('order_item_id', oi.id, 'product_name', oi.product_name,
        'supplied_qty', public.order_item_supplied_qty(oi.id)) ORDER BY oi.id)
      FROM public.order_items oi WHERE oi.order_id = p_order_id), '[]'::JSONB));
END;
$$;
REVOKE ALL ON FUNCTION public.order_receipt_supply(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_receipt_supply(UUID) TO authenticated, service_role;
