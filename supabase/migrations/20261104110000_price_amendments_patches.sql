-- Order amendments, Phase 4 part 2: fail-closed in-place patches so that every reader and writer that multiplies a unit price
-- by a quantity sees the price now in force (order_item_effective_price), not only the price as placed. Each patch rebuilds
-- the LIVE definition, must match exactly the expected number of times, otherwise stops without changing anything, and is
-- safe to re-run. For an order with no accepted price amendment the new expression returns exactly order_items.unit_price_ghs,
-- so nothing changes until a price amendment is accepted.
--
--   1. Writers that price quantities: partial-fulfilment proposals (the value of a shortage), back-order shipments (the value
--      of what is sent), delivery reports (the value of a problem), returns (the refund value of a returned unit).
--   2. Readers: the order-amendment, back-order and delivery-report read functions, the purchase / product / customer reports,
--      and the price history (it reports the unit price actually paid).
--   3. The statement shows an accepted price amendment as its own kind of line ("price_adjustment").
--   4. The proposal reminder no longer says "a reduced supply" (it now covers both kinds of proposal), and the two
--      supply-change replies refuse a price proposal (a price proposal has its own functions with its own wording).
-- Not patched: get_order_print (production-only; its definition cannot be verified from the repository) and
-- get_order_reorder_lines (reordering what was ordered is the useful default).

-- ---------------------------------------------------------------------------
-- 1. Writers
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('propose_partial_fulfilment',
  'oi\.quantity, oi\.unit_price_ghs, public\.order_item_supplied_qty\(oi\.id\) AS prior_qty',
  'oi.quantity, public.order_item_effective_price(oi.id) AS unit_price_ghs, public.order_item_supplied_qty(oi.id) AS prior_qty',
  1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('create_backorder_shipment',
  'SELECT oi\.id, oi\.product_id, oi\.product_name, oi\.unit_price_ghs INTO v_item',
  'SELECT oi.id, oi.product_id, oi.product_name, public.order_item_effective_price(oi.id) AS unit_price_ghs INTO v_item',
  1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('submit_delivery_report',
  'oi\.product_name, oi\.unit_price_ghs,',
  'oi.product_name, public.order_item_effective_price(oi.id) AS unit_price_ghs,',
  1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('request_order_return',
  'AS quantity, oi\.unit_price_ghs INTO v_oi',
  'AS quantity, public.order_item_effective_price(oi.id) AS unit_price_ghs INTO v_oi',
  1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('get_returnable_items',
  '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 1, 'order_item_effective_price');

-- ---------------------------------------------------------------------------
-- 2. Readers
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('get_order_amendments',
  '''unit_price_ghs'', oi\.unit_price_ghs', '''unit_price_ghs'', public.order_item_effective_price(oi.id)', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('get_order_amendments',
  '''unit_price_ghs'', l\.unit_price_ghs, ''note'', l\.note,',
  '''unit_price_ghs'', l.unit_price_ghs, ''proposed_unit_price_ghs'', l.proposed_unit_price_ghs, ''note'', l.note,', 1, 'proposed_unit_price_ghs');
SELECT public.apply_function_regex_patch('get_order_backorder',
  '''unit_price_ghs'', oi\.unit_price_ghs', '''unit_price_ghs'', public.order_item_effective_price(oi.id)', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('get_order_delivery_reports',
  '''unit_price_ghs'', oi\.unit_price_ghs', '''unit_price_ghs'', public.order_item_effective_price(oi.id)', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('pharmacy_report_products', '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 3, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases', '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 2, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('pharmacy_report_purchases_summary', '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 5, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('wholesaler_report_products', '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 2, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('wholesaler_customer_detail', '\moi\.unit_price_ghs\M', 'public.order_item_effective_price(oi.id)', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('pharmacy_price_history',
  'oi\.unit_price_ghs AS paid', 'public.order_item_effective_price(oi.id) AS paid', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('pharmacy_price_history_detail',
  'oi\.unit_price_ghs AS paid', 'public.order_item_effective_price(oi.id) AS paid', 1, 'order_item_effective_price');

-- What the screens and the receipt endpoints overlay on an amended order: the price now in force per line.
SELECT public.apply_function_regex_patch('order_supply_summary',
  '''fulfilled_qty'', public\.order_item_fulfilled_qty\(oi\.id\)\)',
  '''fulfilled_qty'', public.order_item_fulfilled_qty(oi.id), ''unit_price_ghs'', public.order_item_effective_price(oi.id))', 1, 'order_item_effective_price');
SELECT public.apply_function_regex_patch('order_receipt_supply',
  '''supplied_qty'', public\.order_item_supplied_qty\(oi\.id\)\) ORDER BY oi\.id\)',
  '''supplied_qty'', public.order_item_supplied_qty(oi.id), ''unit_price_ghs'', public.order_item_effective_price(oi.id)) ORDER BY oi.id)', 1, 'order_item_effective_price');

-- ---------------------------------------------------------------------------
-- 3. Statement
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('customer_statement',
  '''adjustment'', CASE WHEN a\.delta_ghs < 0',
  'CASE a.kind WHEN ''price_change'' THEN ''price_adjustment'' ELSE ''adjustment'' END, CASE WHEN a.delta_ghs < 0',
  1, '''price_adjustment''');

-- ---------------------------------------------------------------------------
-- 4. Wording, and the replies that belong to supply changes only
-- ---------------------------------------------------------------------------
SELECT public.apply_function_regex_patch('send_amendment_reminders',
  'for your decision on a reduced supply\.', 'for your decision on a proposed change to it.', 1, 'on a proposed change to it');
SELECT public.apply_function_regex_patch('withdraw_amendment',
  'IF v_a\.status = ''withdrawn'' THEN',
  'IF v_a.kind <> ''partial_fulfilment'' THEN RAISE EXCEPTION ''Use the price proposal actions for a price proposal.''; END IF;' || E'\n'
  || '  IF v_a.status = ''withdrawn'' THEN',
  1, 'Use the price proposal actions');
SELECT public.apply_function_regex_patch('answer_amendment_clarification',
  'IF v_a\.status <> ''clarification_requested'' THEN',
  'IF v_a.kind <> ''partial_fulfilment'' THEN RAISE EXCEPTION ''Use the price proposal actions for a price proposal.''; END IF;' || E'\n'
  || '  IF v_a.status <> ''clarification_requested'' THEN',
  1, 'Use the price proposal actions');
