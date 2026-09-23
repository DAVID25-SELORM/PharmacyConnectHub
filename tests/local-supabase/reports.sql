GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;
GRANT INSERT, SELECT ON zz.results TO authenticated;
GRANT USAGE ON SEQUENCE zz.results_seq_seq TO authenticated;

-- Reports Phase 1: correctness checks on the real schema with hand-computed expected values.
-- Fixtures + all denial checks (run as the un-elevated caller, no role switch needed there
-- because zz.run_as does its own switch per call).
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  p1 UUID; p2 UUID;
  o1 UUID; o2 UUID; o3 UUID;
  r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (alpha, 'Amoxicillin 500mg', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 10.00, 40, true) RETURNING id INTO p1;
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (alpha, 'Paracetamol 500mg', 'Generic', 'Analgesic', 'TABLET', '20s', 5.00, 3, true) RETURNING id INTO p2;

  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (good, alpha, 'delivered', 100.00, 110.00, 10.00, 'paid', 'cod', now() - interval '2 days') RETURNING id INTO o1;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o1, p1, 'Amoxicillin 500mg', 10.00, 10);

  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (good, alpha, 'cancelled', 50.00, 50.00, 0, 'unpaid', 'cod', now() - interval '1 days') RETURNING id INTO o2;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o2, p2, 'Paracetamol 500mg', 5.00, 10);

  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (otherp, alpha, 'pending', 25.00, 25.00, 0, 'unpaid', 'paystack', now() - interval '3 hours') RETURNING id INTO o3;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o3, p1, 'Amoxicillin 500mg', 10.00, 2);

  PERFORM zz.check('range: today starts at UTC midnight',
    (SELECT range_from = date_trunc('day', now()) FROM public.resolve_report_range('today', NULL, NULL)));
  PERFORM zz.check('range: custom requires both bounds',
    zz.run_as(u_admin, $q$SELECT * FROM public.resolve_report_range('custom', NULL, now())$q$) LIKE 'ERR: A custom range needs both%');
  PERFORM zz.check('range: custom rejects from > to',
    zz.run_as(u_admin, format($q$SELECT * FROM public.resolve_report_range('custom', %L, %L)$q$, now()::text, (now() - interval '1 day')::text)) LIKE 'ERR: The start date must be before%');

  PERFORM zz.check('admin_report_overview: non-admin denied', zz.run_as(u_px, 'SELECT public.admin_report_overview()') LIKE 'ERR: Only platform admins%');
  PERFORM zz.check('admin_report_sales: non-admin denied', zz.run_as(u_px, 'SELECT * FROM public.admin_report_sales()') LIKE 'ERR: Only platform admins%');
  PERFORM zz.check('admin_report_wholesaler_performance: non-admin denied', zz.run_as(u_px, 'SELECT * FROM public.admin_report_wholesaler_performance()') LIKE 'ERR: Only platform admins%');
  PERFORM zz.check('admin_report_pharmacy_activity: non-admin denied', zz.run_as(u_px, 'SELECT * FROM public.admin_report_pharmacy_activity()') LIKE 'ERR: Only platform admins%');
  PERFORM zz.check('admin_report_payments: non-admin denied', zz.run_as(u_px, 'SELECT public.admin_report_payments()') LIKE 'ERR: Only platform admins%');
  PERFORM zz.check('pharmacy_report_overview: unrelated user denied', zz.run_as(u_nb, format('SELECT public.pharmacy_report_overview(%L)', good)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('pharmacy_report_orders: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.pharmacy_report_orders(%L)', good)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('pharmacy_report_supplier_spend: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.pharmacy_report_supplier_spend(%L)', good)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('wholesaler_report_overview: unrelated user denied', zz.run_as(u_nb, format('SELECT public.wholesaler_report_overview(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('wholesaler_report_sales: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.wholesaler_report_sales(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('wholesaler_report_customers: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.wholesaler_report_customers(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('wholesaler_report_products: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.wholesaler_report_products(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('wholesaler_report_inventory: unrelated user denied', zz.run_as(u_nb, format('SELECT * FROM public.wholesaler_report_inventory(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('cross-tenant: pharmacy owner cannot read the WHOLESALER report for its own id',
    zz.run_as(u_po, format('SELECT public.wholesaler_report_overview(%L)', alpha)) LIKE 'ERR: You do not have access%');
  PERFORM zz.check('anon has no EXECUTE on report RPCs',
    NOT has_function_privilege('anon', 'public.admin_report_overview(text,timestamptz,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.pharmacy_report_orders(uuid,text,timestamptz,timestamptz,uuid,text,text,text,timestamptz,uuid,integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.wholesaler_report_inventory(uuid,text,integer)', 'EXECUTE'));

  r := zz.run_as(u_admin, $q$SELECT * FROM public.admin_report_sales(p_group_by => 'century')$q$);
  PERFORM zz.check('admin sales: invalid group_by rejected', r LIKE 'ERR: group_by must be%', r);
END $$;

-- ===== as platform admin: aggregate/table-shaped reports =====
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM zz.u WHERE k='admin'), 'role','authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='admin')::text, false);
SET ROLE authenticated;
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  o3 UUID := (SELECT id FROM public.orders WHERE pharmacy_id = (SELECT id FROM zz.b WHERE name='Other Pharmacy') AND wholesaler_id = alpha);
  j JSONB;
BEGIN
  j := public.admin_report_overview('all');
  PERFORM zz.check('admin overview: gmv = 100+50+25', (j->'kpis'->>'gmv_ghs')::numeric = 175.00, j::text);
  PERFORM zz.check('admin overview: orders_total = 3', (j->'kpis'->>'orders_total')::int = 3);
  PERFORM zz.check('admin overview: completed_orders = 1 (delivered)', (j->'kpis'->>'completed_orders')::int = 1);
  PERFORM zz.check('admin overview: cancelled_orders = 1', (j->'kpis'->>'cancelled_orders')::int = 1);
  PERFORM zz.check('admin overview: active_pharmacies counts only approved', (j->>'active_pharmacies')::int >= 2);
  PERFORM zz.check('admin overview: pending_businesses counts pending', (j->>'pending_businesses')::int >= 1);
  PERFORM zz.check('admin overview: series is bounded (<= number of distinct days, not orders)', jsonb_array_length(j->'series') <= 3);

  PERFORM zz.check('admin sales: gross(day1) = 110 (subtotal), net(day1) = 100 (total)',
    EXISTS (SELECT 1 FROM public.admin_report_sales('all', NULL, NULL, 'day') s WHERE s.gross_ghs = 110.00 AND s.net_ghs = 100.00 AND s.discount_ghs = 10.00));
  PERFORM zz.check('admin sales: filter by wholesaler + status=pending isolates order 3',
    (SELECT count(*) = 1 AND sum(orders) = 1 AND sum(net_ghs) = 25.00 FROM public.admin_report_sales('all', NULL, NULL, 'day', alpha, NULL, 'pending')));
  PERFORM zz.check('admin sales: unrelated wholesaler filter returns nothing',
    (SELECT count(*) = 0 FROM public.admin_report_sales('all', NULL, NULL, 'day', other)));

  PERFORM zz.check('wholesaler performance: Alpha shows 3 orders, 175 sales, 1 cancelled, 2 customers, 22 items',
    (SELECT orders = 3 AND sales_ghs = 175.00 AND cancelled_orders = 1 AND customers = 2 AND items_sold = 22
     FROM public.admin_report_wholesaler_performance('all') WHERE wholesaler_id = alpha));
  PERFORM zz.check('wholesaler performance: search filters by name',
    (SELECT count(*) = 1 FROM public.admin_report_wholesaler_performance('all', NULL, NULL, 'Alpha Wholesale')));
  PERFORM zz.check('pharmacy activity: Good Pharmacy shows 2 orders, 150 purchases, 1 supplier',
    (SELECT orders = 2 AND purchases_ghs = 150.00 AND suppliers_used = 1
     FROM public.admin_report_pharmacy_activity('all') WHERE pharmacy_id = good));

  j := public.admin_report_payments('all');
  PERFORM zz.check('admin payments: paid=1/100, unpaid=2/75, cod=2, paystack=1',
    (j->'summary'->>'paid_orders')::int = 1 AND (j->'summary'->>'paid_ghs')::numeric = 100.00
    AND (j->'summary'->>'unpaid_orders')::int = 2 AND (j->'summary'->>'unpaid_ghs')::numeric = 75.00
    AND (j->'summary'->>'cod_orders')::int = 2 AND (j->'summary'->>'paystack_orders')::int = 1, j::text);
  PERFORM zz.check('admin payments: rows list is bounded and newest first',
    jsonb_array_length(j->'rows') = 3 AND (j->'rows'->0->>'order_id') = o3::text);
END $$;
RESET ROLE;

-- ===== as the pharmacy owner: only its own orders/spend, never the sibling pharmacy's =====
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM zz.u WHERE k='ph_owner'), 'role','authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='ph_owner')::text, false);
SET ROLE authenticated;
DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  j JSONB;
BEGIN
  j := public.pharmacy_report_overview(good, 'all');
  PERFORM zz.check('pharmacy overview: total_purchases=150, delivered=1, outstanding=0 (cancelled excluded), discount=10',
    (j->'kpis'->>'total_purchases_ghs')::numeric = 150.00 AND (j->'kpis'->>'delivered_orders')::int = 1
    AND (j->'kpis'->>'outstanding_orders')::int = 0 AND (j->'kpis'->>'total_discount_ghs')::numeric = 10.00, j::text);
  PERFORM zz.check('pharmacy overview: sees only its own 2 orders, not the sibling pharmacy''s',
    (j->'kpis'->>'total_orders')::int = 2);

  PERFORM zz.check('pharmacy orders: keyset list for Good Pharmacy has exactly 2 rows, newest first',
    (SELECT array_agg(order_number ORDER BY created_at DESC) FROM public.pharmacy_report_orders(good, 'all')) =
    (SELECT array_agg(order_number) FROM (SELECT order_number FROM public.orders WHERE pharmacy_id = good ORDER BY created_at DESC) x));

  PERFORM zz.check('supplier spend: Alpha row for Good Pharmacy = 2 orders, 150 spend, 10 discount',
    (SELECT orders = 2 AND spend_ghs = 150.00 AND discount_ghs = 10.00
     FROM public.pharmacy_report_supplier_spend(good, 'all') WHERE wholesaler_id = alpha));
END $$;
RESET ROLE;

-- ===== as the wholesaler owner: sales, customers, products, inventory =====
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM zz.u WHERE k='w_owner'), 'role','authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='w_owner')::text, false);
SET ROLE authenticated;
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  p1 UUID := (SELECT id FROM public.products WHERE wholesaler_id = alpha AND name = 'Amoxicillin 500mg');
  p2 UUID := (SELECT id FROM public.products WHERE wholesaler_id = alpha AND name = 'Paracetamol 500mg');
  j JSONB;
  page1_ids UUID[]; page2_ids UUID[]; last_ts TIMESTAMPTZ; last_id UUID;
BEGIN
  j := public.wholesaler_report_overview(alpha, 'all');
  PERFORM zz.check('wholesaler overview: sales=175, orders=3, customers=2, units=22, pending=1',
    (j->'kpis'->>'total_sales_ghs')::numeric = 175.00 AND (j->'kpis'->>'total_orders')::int = 3
    AND (j->'kpis'->>'customers')::int = 2 AND (j->'kpis'->>'units_sold')::int = 22
    AND (j->'kpis'->>'pending_orders')::int = 1, j::text);

  PERFORM zz.check('wholesaler sales: 3 rows, newest row (order 3) has gross=25',
    (SELECT count(*) = 3 FROM public.wholesaler_report_sales(alpha, 'all'))
    AND (SELECT gross_ghs FROM public.wholesaler_report_sales(alpha, 'all') ORDER BY created_at DESC LIMIT 1) = 25.00);

  SELECT array_agg(id), (array_agg(created_at ORDER BY created_at ASC))[1], (array_agg(id ORDER BY created_at ASC))[1]
    INTO page1_ids, last_ts, last_id
    FROM public.wholesaler_report_sales(alpha, 'all', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 2);
  SELECT array_agg(id) INTO page2_ids
    FROM public.wholesaler_report_sales(alpha, 'all', NULL, NULL, NULL, NULL, NULL, last_ts, last_id, 2);
  PERFORM zz.check('wholesaler sales: keyset page 1 (limit 2) + page 2 cover all 3 rows with no overlap',
    cardinality(page1_ids) = 2 AND cardinality(page2_ids) = 1
    AND cardinality(ARRAY(SELECT DISTINCT x FROM unnest(page1_ids || page2_ids) x)) = 3);

  PERFORM zz.check('wholesaler customers: Good Pharmacy=150 revenue/2 orders, Other Pharmacy=25 revenue/1 order',
    (SELECT revenue_ghs = 150.00 AND orders = 2 FROM public.wholesaler_report_customers(alpha, 'all') WHERE pharmacy_id = good)
    AND (SELECT revenue_ghs = 25.00 AND orders = 1 FROM public.wholesaler_report_customers(alpha, 'all') WHERE pharmacy_id = otherp));

  PERFORM zz.check('wholesaler products: Amoxicillin units=12 (10+2)/revenue=120/2 customers; Paracetamol units=10/revenue=50',
    (SELECT units_sold = 12 AND revenue_ghs = 120.00 AND customers = 2 FROM public.wholesaler_report_products(alpha, 'all') WHERE product_id = p1)
    AND (SELECT units_sold = 10 AND revenue_ghs = 50.00 FROM public.wholesaler_report_products(alpha, 'all') WHERE product_id = p2));

  PERFORM zz.check('wholesaler inventory: Paracetamol stock=3, stock_value=15',
    (SELECT stock = 3 AND stock_value_ghs = 15.00 FROM public.wholesaler_report_inventory(alpha) WHERE product_id = p2));
  PERFORM zz.check('wholesaler inventory: low-stock filter (<=5) isolates only Paracetamol',
    (SELECT count(*) = 1 AND bool_and(product_id = p2) FROM public.wholesaler_report_inventory(alpha, NULL, 5)));
  PERFORM zz.check('wholesaler inventory: never returns another wholesaler''s products',
    NOT EXISTS (SELECT 1 FROM public.wholesaler_report_inventory(alpha) WHERE product_id NOT IN (p1, p2)));
END $$;
RESET ROLE;

-- ===== staff access: manager can read the wholesaler's own reports =====
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM zz.u WHERE k='w_manager'), 'role','authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='w_manager')::text, false);
SET ROLE authenticated;
SELECT (public.wholesaler_report_overview((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), 'all') IS NOT NULL) AS manager_can_read_wholesaler_report;
RESET ROLE;

-- ===== a pending business owner can still see its OWN (empty) report: reports are not gated by verification =====
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT id FROM zz.u WHERE k='w_pending'), 'role','authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT id FROM zz.u WHERE k='w_pending')::text, false);
SET ROLE authenticated;
SELECT (public.wholesaler_report_overview((SELECT id FROM zz.b WHERE name='Pending Wholesale'), 'all') IS NOT NULL) AS pending_owner_can_read_own_report;
RESET ROLE;

SELECT set_config('request.jwt.claims', '', false);
SELECT set_config('request.jwt.claim.sub', '', false);

SELECT proname, prosecdef, proconfig FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('admin_report_overview','pharmacy_report_orders','wholesaler_report_inventory','resolve_report_range')
ORDER BY 1;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok ORDER BY seq;
