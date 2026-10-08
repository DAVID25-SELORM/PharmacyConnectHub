-- Order amendments, Phase 6: readers use the effective total and supplied quantities (fixture shared with the Phase 2 suite).
-- Run after setup.sql + migrations (through 20261101100000_effective_total_readers.sql), with the production
-- guard and stock fixtures installed and the checkout compatibility migration (20261017110000) re-applied.
-- Successful create_marketplace_orders calls are top-level statements (ON COMMIT DROP temp tables).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c1', 'ww@zz.test', '{"full_name":"Alpha Warehouse","phone":"+233241000051"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c2', 'wf@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000052"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c3', 'pc@zz.test', '{"full_name":"Good Cashier","phone":"+233241000053"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c4', 'pa@zz.test', '{"full_name":"Good Assistant","phone":"+233241000054"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = v.biz), v.uid, v.r::public.staff_role, 'active'::public.staff_status, now()
FROM (VALUES
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000c1'::uuid, 'warehouse'),
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000c2'::uuid, 'finance'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000c3'::uuid, 'cashier'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000c4'::uuid, 'assistant')) v(biz, uid, r);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT b.id, v.n, 'Generic', 'Analgesic', 'TABLET', '100s', v.p, v.s, true
FROM zz.b b, (VALUES ('PF A', 100, 1000), ('PF B', 50, 500), ('PF C', 20, 200), ('PF D', 10, 300)) v(n, p, s) WHERE b.name = 'Alpha Wholesale';
CREATE TABLE zz.pf AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  '30000000-0000-0000-0000-0000000000c1'::uuid u_ww,
  '30000000-0000-0000-0000-0000000000c2'::uuid u_wf,
  '30000000-0000-0000-0000-0000000000c3'::uuid u_pc,
  '30000000-0000-0000-0000-0000000000c4'::uuid u_pa,
  (SELECT id FROM public.products WHERE name='PF A') pa,
  (SELECT id FROM public.products WHERE name='PF B') pb,
  (SELECT id FROM public.products WHERE name='PF C') pcc,
  (SELECT id FROM public.products WHERE name='PF D') pd;
CREATE TABLE zz.pf_orders(label TEXT PRIMARY KEY, order_id UUID);
CREATE FUNCTION zz.ord(p_label TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT order_id FROM zz.pf_orders WHERE label = p_label $$;
CREATE FUNCTION zz.item(p_order UUID, p_name TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT id FROM public.order_items WHERE order_id = p_order AND product_name = p_name $$;
CREATE FUNCTION zz.stock(p_name TEXT) RETURNS INTEGER LANGUAGE sql AS $$ SELECT stock FROM public.products WHERE name = p_name $$;
CREATE FUNCTION zz.line(p_order UUID, p_name TEXT, p_qty INT, p_treat TEXT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT jsonb_build_object('order_item_id', zz.item(p_order, p_name), 'supplied_qty', p_qty, 'stock_treatment', p_treat) $$;

SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.pf), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.pf)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.pf;

-- Order A: credit, 3 lines (PF A x10 @100, PF B x20 @50, PF C x5 @20) = 2100.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 10, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pb FROM zz.pf), 'quantity', 20, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'credit')) AS r \gset a_
INSERT INTO zz.pf_orders SELECT 'A', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order B: cash on delivery, PF A x4 + PF B x10 = 900.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 4, 'category', 'cash_private'),
    jsonb_build_object('productId', (SELECT pb FROM zz.pf), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset b_
INSERT INTO zz.pf_orders SELECT 'B', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order D: credit, PF A x5 = 500, with a payment of 200 already recorded.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.pf), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'credit')) AS r \gset d_
INSERT INTO zz.pf_orders SELECT 'D', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note)
SELECT alpha, good, zz.ord('D'), 'payment', 'credit', 200, 'test payment' FROM zz.pf;
-- Order E and F: cash on delivery, PF D (batched), 30 and 20 units.
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pd FROM zz.pf), 'quantity', 30, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset e_
INSERT INTO zz.pf_orders SELECT 'E', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pd FROM zz.pf), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset f_
INSERT INTO zz.pf_orders SELECT 'F', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- Order G: a legacy order with no stock deduction evidence (cod, PF C x10 = 200).
ALTER TABLE public.orders DISABLE TRIGGER trg_notify_new_order;
INSERT INTO public.orders(pharmacy_id, wholesaler_id, subtotal_ghs, discount_amount_ghs, delivery_fee_ghs, total_ghs, payment_method, is_credit_order)
SELECT good, alpha, 200, 0, 0, 200, 'cod', false FROM zz.pf;
ALTER TABLE public.orders ENABLE TRIGGER trg_notify_new_order;
INSERT INTO zz.pf_orders SELECT 'G', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity)
SELECT zz.ord('G'), pcc, 'PF C', 20, 10 FROM zz.pf;
-- Order H: pending (never accepted).
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pcc FROM zz.pf), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'cod')) AS r \gset h_
INSERT INTO zz.pf_orders SELECT 'H', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Batches for PF D (stock 300 - 30 - 20 = 250 after the two checkouts).
INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
SELECT pd, alpha, 'B-EARLY', current_date + 60, 20, 20 FROM zz.pf;
INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
SELECT pd, alpha, 'B-LATE', current_date + 120, 100, 100 FROM zz.pf;

UPDATE public.orders SET status = 'accepted' WHERE id IN (SELECT order_id FROM zz.pf_orders WHERE label IN ('A', 'B', 'D', 'E', 'F', 'G'));


-- Amend order A (credit, 2100 -> 1550) and order B (cod, 900 -> 700) through the real flow.
DO $$
DECLARE r TEXT; a UUID; o UUID;
BEGIN
  o := zz.ord('A');
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 7, 'release'), zz.line(o, 'PF B', 15, 'write_off'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
  o := zz.ord('B');
  r := zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT public.propose_partial_fulfilment(%L, ''Short'', %L::jsonb, gen_random_uuid())::text', o,
    jsonb_build_array(zz.line(o, 'PF A', 2, 'release'))::text));
  a := (r::jsonb->>'amendment_id')::uuid;
  PERFORM zz.val_as((SELECT u_po FROM zz.pf), format('SELECT public.respond_to_amendment(%L, ''accept_cancel_remaining'', NULL)::text', a));
END $$;

-- Orders now: A credit 2100 -> 1550 (supplied 7/15/5), B cod 900 -> 700 (PF A 2, PF B 10), D credit 500 (+200 paid),
-- E cod 300, F cod 200, G legacy cod 200, H pending 20. Placed sum = 4220; effective sum = 3470.
CREATE FUNCTION zz.j(p_uid UUID, p_sql TEXT) RETURNS JSONB LANGUAGE sql AS $$ SELECT NULLIF(zz.val_as(p_uid, p_sql), '')::jsonb $$;

-- 1. Wholesaler reports.
DO $$
DECLARE w UUID := (SELECT u_wo FROM zz.pf); a UUID := (SELECT alpha FROM zz.pf); r JSONB;
BEGIN
  r := zz.j(w, format('SELECT public.wholesaler_report_overview(%L, ''all'')::text', a));
  PERFORM zz.check('wholesaler overview: total sales use the effective totals (3470, not the placed 4220)', (r->'kpis'->>'total_sales_ghs')::numeric = 3470, r::text);
  PERFORM zz.check('wholesaler overview: units sold count what was supplied (105, not 160 ordered)', (r->'kpis'->>'units_sold')::int = 105, r::text);
  PERFORM zz.check('wholesaler overview: the average order uses effective totals (3470 / 7)', abs((r->'kpis'->>'avg_order_value_ghs')::numeric - 3470.0/7) < 0.01);
  PERFORM zz.check('wholesaler overview: the day series is on the original order date and adds up to 3470', (SELECT sum((x->>'sales_ghs')::numeric) = 3470 FROM jsonb_array_elements(r->'series') x));
  r := zz.j(w, format('SELECT (SELECT jsonb_agg(jsonb_build_object(''n'',order_number,''gross'',gross_ghs,''disc'',discount_amount_ghs,''net'',net_ghs,''o'',id)) FROM public.wholesaler_report_sales(%L, ''all'') s)::text', a));
  PERFORM zz.check('sales report: an amended order shows its effective total as net AND gross, with no order-level discount',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'o')::uuid = zz.ord('A') AND (x->>'net')::numeric = 1550 AND (x->>'gross')::numeric = 1550 AND (x->>'disc')::numeric = 0), r::text);
  PERFORM zz.check('sales report: the cash order amended to 700 shows 700', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'o')::uuid = zz.ord('B') AND (x->>'net')::numeric = 700));
  PERFORM zz.check('sales report: an order that was never amended is exactly as before (D: 500 / 500 / 0)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'o')::uuid = zz.ord('D') AND (x->>'net')::numeric = 500 AND (x->>'gross')::numeric = 500 AND (x->>'disc')::numeric = 0));
  PERFORM zz.check('sales report: the rows add up to 3470', (SELECT sum((x->>'net')::numeric) = 3470 FROM jsonb_array_elements(r) x));
  r := zz.j(w, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.wholesaler_report_products(%L, ''all'') s)::text', a));
  PERFORM zz.check('product report: PF A sold 14 units for 1400 (7 + 2 + 5), not 19', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF A' AND (x->>'units_sold')::int = 14 AND (x->>'revenue_ghs')::numeric = 1400), r::text);
  PERFORM zz.check('product report: PF B sold 25 units for 1250 (15 + 10), not 30', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF B' AND (x->>'units_sold')::int = 25 AND (x->>'revenue_ghs')::numeric = 1250));
  r := zz.j(w, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.wholesaler_report_customers(%L, ''all'') s)::text', a));
  PERFORM zz.check('customer report: revenue 3470', (r->0->>'revenue_ghs')::numeric = 3470, r::text);
  r := zz.j(w, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.wholesaler_inventory_insights(%L) s)::text', a));
  PERFORM zz.check('inventory insights: PF A sold 14 in 90 days (supplied), not 19', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF A' AND (x->>'units_sold_90d')::int = 14), r::text);
  r := zz.j(w, format('SELECT (public.wholesaler_customer_detail(%L, %L)->''top_products'')::text', a, (SELECT good FROM zz.pf)));
  PERFORM zz.check('customer detail: top products count supplied units (PF A 14, PF B 25)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF A' AND (x->>'units')::int = 14 AND (x->>'spend_ghs')::numeric = 1400)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF B' AND (x->>'units')::int = 25), r::text);
  r := zz.j(w, format('SELECT (public.wholesaler_customer_detail(%L, %L)->''recent_orders'')::text', a, (SELECT good FROM zz.pf)));
  PERFORM zz.check('customer detail: recent orders show the effective total for an amended order',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'id')::uuid = zz.ord('A') AND (x->>'total_ghs')::numeric = 1550), r::text);
  PERFORM zz.check('customers list: revenue 3470 and outstanding (all unpaid) 3470',
    zz.val_as(w, format('SELECT string_agg(c::text, ''|'') FROM public.wholesaler_customers(%L) c', a)) LIKE '%,7,3470.00,495.71,3470.00,%',
    zz.val_as(w, format('SELECT string_agg(c::text, ''|'') FROM public.wholesaler_customers(%L) c', a)));
END $$;

-- 2. Pharmacy reports.
DO $$
DECLARE p UUID := (SELECT u_po FROM zz.pf); g UUID := (SELECT good FROM zz.pf); r JSONB;
BEGIN
  r := zz.j(p, format('SELECT public.pharmacy_report_overview(%L, ''all'')::text', g));
  PERFORM zz.check('pharmacy overview: total purchases 3470', (r->'kpis'->>'total_purchases_ghs')::numeric = 3470, r::text);
  PERFORM zz.check('pharmacy overview: spend series adds up to 3470', (SELECT sum((x->>'spend_ghs')::numeric) = 3470 FROM jsonb_array_elements(r->'series') x));
  r := zz.j(p, format('SELECT (SELECT jsonb_agg(jsonb_build_object(''o'',id,''sub'',subtotal_ghs,''disc'',discount_amount_ghs,''tot'',total_ghs)) FROM public.pharmacy_report_orders(%L, ''all'') s)::text', g));
  PERFORM zz.check('order report: the amended order shows total 1550, subtotal (goods as supplied) 1550, discount 0',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'o')::uuid = zz.ord('A') AND (x->>'tot')::numeric = 1550 AND (x->>'sub')::numeric = 1550 AND (x->>'disc')::numeric = 0), r::text);
  PERFORM zz.check('order report: an unamended order is unchanged', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE (x->>'o')::uuid = zz.ord('D') AND (x->>'tot')::numeric = 500 AND (x->>'sub')::numeric = 500));
  r := zz.j(p, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_supplier_spend(%L, ''all'') s)::text', g));
  PERFORM zz.check('supplier spend: 3470', (r->0->>'spend_ghs')::numeric = 3470, r::text);
  r := zz.j(p, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_products(%L, ''all'') s)::text', g));
  PERFORM zz.check('product report: PF A purchased 14 units for 1400', EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'product_name' = 'PF A' AND (x->>'units_purchased')::int = 14 AND (x->>'spend_ghs')::numeric = 1400), r::text);
  r := zz.j(p, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_purchases_summary(%L, ''all'') s)::text', g));
  PERFORM zz.check('purchases summary: total value 3470 and 105 units', (r->0->>'total_value_ghs')::numeric = 3470 AND (r->0->>'item_quantity')::int = 105, r::text);
  r := zz.j(p, format('SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.pharmacy_report_purchases(%L, ''all'') s)::text', g));
  PERFORM zz.check('purchases list: the quantities are the supplied ones (PF A on order A is 7)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'order_id' = zz.ord('A')::text AND x->>'product_name' = 'PF A' AND (x->>'quantity')::int = 7), r::text);
END $$;

-- 3. Platform admin reports.
DO $$
DECLARE ad UUID := (SELECT u_admin FROM zz.pf); r JSONB;
BEGIN
  PERFORM zz.check('admin summary: GMV 3470', (zz.j(ad, 'SELECT public.admin_platform_summary()::text')->>'gmv_ghs')::numeric = 3470);
  r := zz.j(ad, 'SELECT public.admin_report_overview(''all'')::text');
  PERFORM zz.check('admin overview: GMV 3470 and the series adds up', (r->'kpis'->>'gmv_ghs')::numeric = 3470 AND (SELECT sum((x->>'gmv_ghs')::numeric) = 3470 FROM jsonb_array_elements(r->'series') x), r::text);
  r := zz.j(ad, 'SELECT public.admin_report_payments(''all'')::text');
  PERFORM zz.check('admin payments: the amended order row shows 1550', EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rows') x WHERE x->>'order_id' = zz.ord('A')::text AND (x->>'total_ghs')::numeric = 1550), left(r::text, 300));
  PERFORM zz.check('admin payments: the unpaid total is 3470', r::text LIKE '%3470.00%' AND NOT r::text LIKE '%4220%', left(r::text, 120));
  r := zz.j(ad, 'SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.admin_report_sales(''all'') s)::text');
  PERFORM zz.check('admin sales: net 3470 and gross 3470 (goods as supplied for amended orders)', (SELECT sum((x->>'net_ghs')::numeric) = 3470 AND sum((x->>'gross_ghs')::numeric) = 3470 FROM jsonb_array_elements(r) x), r::text);
  r := zz.j(ad, 'SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.admin_report_pharmacy_activity(''all'') s)::text');
  PERFORM zz.check('admin pharmacy activity: purchases 3470', (r->0->>'purchases_ghs')::numeric = 3470, r::text);
  r := zz.j(ad, 'SELECT (SELECT jsonb_agg(to_jsonb(s)) FROM public.admin_report_wholesaler_performance(''all'') s)::text');
  PERFORM zz.check('admin wholesaler performance: items sold 105 (supplied)', (r->0->>'items_sold')::int = 105, r::text);
END $$;

-- 4. Order lists.
DO $$
DECLARE p UUID := (SELECT u_po FROM zz.pf); r JSONB;
BEGIN
  r := zz.j(p, 'SELECT public.list_pharmacy_order_history(1, 20)::text');
  PERFORM zz.check('pharmacy order list: an amended order carries total_ghs as placed and effective_total_ghs',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'id' = zz.ord('A')::text AND (x->>'total_ghs')::numeric = 2100 AND (x->>'effective_total_ghs')::numeric = 1550), left(r::text, 300));
  PERFORM zz.check('pharmacy order list: an unamended order has a NULL effective total',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'id' = zz.ord('D')::text AND x->'effective_total_ghs' = 'null'::jsonb));
  PERFORM zz.check('pharmacy order list: unit counts are supplied units (A 27, B 12)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'id' = zz.ord('A')::text AND (x->>'unit_count')::int = 27)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'id' = zz.ord('B')::text AND (x->>'unit_count')::int = 12));
  r := zz.j(p, 'SELECT public.list_pharmacy_order_history(1, 20, NULL, NULL, NULL, ''highest'')::text');
  PERFORM zz.check('sorting by highest uses what is owed: A (1550) first, then B (700), not by the placed 2100/900',
    r->'orders'->0->>'id' = zz.ord('A')::text AND r->'orders'->1->>'id' = zz.ord('B')::text, left(r::text, 200));
END $$;

-- 5. Customer statement: the placed order stays; an accepted reduction is its own line.
DO $$
DECLARE w UUID := (SELECT u_wo FROM zz.pf); r JSONB; q TEXT;
BEGIN
  q := format('SELECT public.customer_statement(%L, %L, now() - interval ''1 day'', now() + interval ''1 day'')::text', (SELECT alpha FROM zz.pf), (SELECT good FROM zz.pf));
  r := zz.j(w, q);
  PERFORM zz.check('statement: the order line is still the placed amount (A: 2100, B: 900)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'kind' = 'order' AND x->>'order_id' = zz.ord('A')::text AND (x->>'debit')::numeric = 2100)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'kind' = 'order' AND x->>'order_id' = zz.ord('B')::text AND (x->>'debit')::numeric = 900), left(r::text, 400));
  PERFORM zz.check('statement: each accepted reduction is a separate "adjustment" credit line (550 and 200)',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'kind' = 'adjustment' AND x->>'order_id' = zz.ord('A')::text AND (x->>'credit')::numeric = 550 AND (x->>'debit')::numeric = 0)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'kind' = 'adjustment' AND x->>'order_id' = zz.ord('B')::text AND (x->>'credit')::numeric = 200));
  PERFORM zz.check('statement: the closing balance is what is owed: 3470 effective total - 200 payment = 3270',
    (r->>'closing_balance')::numeric = 3270, r->>'closing_balance');
  PERFORM zz.check('statement: the pharmacy sees the same statement', zz.j((SELECT u_po FROM zz.pf), q)->>'closing_balance' = '3270.00');
  -- A cash order marked paid shows its payment at what was actually due.
  UPDATE public.orders SET status = 'picking' WHERE id = zz.ord('B');
  UPDATE public.orders SET status = 'packed' WHERE id = zz.ord('B');
  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = zz.ord('B');
  UPDATE public.orders SET status = 'dispatched' WHERE id = zz.ord('B');
  UPDATE public.orders SET status = 'delivered' WHERE id = zz.ord('B');
  UPDATE public.orders SET payment_status = 'paid', paid_at = now() WHERE id = zz.ord('B');
  r := zz.j(w, q);
  PERFORM zz.check('statement: the cash order''s payment line is 700 (effective), so B nets to zero and the balance is 2570',
    EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'kind' = 'payment' AND x->>'order_id' = zz.ord('B')::text AND (x->>'credit')::numeric = 700)
    AND (r->>'closing_balance')::numeric = 2570, r->>'closing_balance');
END $$;

-- 6. Returns: only what was supplied.
DO $$
DECLARE o UUID := zz.ord('B'); p UUID := (SELECT u_po FROM zz.pf); r TEXT;
BEGIN
  r := zz.val_as(p, format('SELECT quantity_ordered::text || ''/'' || quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''PF A''', o));
  PERFORM zz.check('returnable items: PF A was ordered 4 but only 2 were supplied, so 2 can come back', r = '4/2', r);
  r := zz.val_as(p, format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''PF B''', o));
  PERFORM zz.check('returnable items: PF B (not reduced) is 10', r = '10', r);
  r := zz.val_as(p, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o, 'PF A'), 'quantity', 3))::text));
  PERFORM zz.check('a return of 3 units when only 2 were supplied is refused', r LIKE 'ERR: Only 2 unit(s) of PF A can still be returned.%', r);
  r := zz.val_as(p, format('SELECT public.request_order_return(%L, ''damaged'', NULL, %L::jsonb)::text', o, jsonb_build_array(jsonb_build_object('order_item_id', zz.item(o, 'PF A'), 'quantity', 2))::text));
  PERFORM zz.check('a return of the 2 supplied units is accepted', r NOT LIKE 'ERR%', r);
  r := zz.val_as(p, format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''PF A''', o));
  PERFORM zz.check('and nothing more can then be returned for that line', r = '0', r);
  UPDATE public.orders SET status = 'picking' WHERE id = zz.ord('D');
  UPDATE public.orders SET status = 'packed' WHERE id = zz.ord('D');
  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = zz.ord('D');
  UPDATE public.orders SET status = 'dispatched' WHERE id = zz.ord('D');
  UPDATE public.orders SET status = 'delivered' WHERE id = zz.ord('D');
  r := zz.val_as(p, format('SELECT quantity_available::text FROM public.get_returnable_items(%L) WHERE product_name = ''PF A''', zz.ord('D')));
  PERFORM zz.check('an unamended order is unchanged (D: 5 of 5)', r = '5', r);
END $$;

-- 7. Receipt data.
DO $$
DECLARE r JSONB;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := public.order_receipt_supply(zz.ord('A'));
  PERFORM zz.check('receipt data: an amended order returns the effective total and the supplied lines',
    (r->>'effective_total_ghs')::numeric = 1550 AND jsonb_array_length(r->'lines') = 3
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(r->'lines') x WHERE x->>'product_name' = 'PF B' AND (x->>'supplied_qty')::int = 15), r::text);
  PERFORM zz.check('receipt data: an un-amended order returns nothing (NULL)', public.order_receipt_supply(zz.ord('D')) IS NULL);
  PERFORM zz.check('receipt data: an unknown order returns nothing', public.order_receipt_supply(gen_random_uuid()) IS NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM zz.check('receipt data: the wholesaler can read it for its own order', zz.val_as((SELECT u_wo FROM zz.pf), format('SELECT (public.order_receipt_supply(%L)->>''effective_total_ghs'')', zz.ord('A'))) = '1550.00');
  PERFORM zz.check('receipt data: the pharmacy can read it for its own order', zz.val_as((SELECT u_po FROM zz.pf), format('SELECT (public.order_receipt_supply(%L)->>''effective_total_ghs'')', zz.ord('A'))) = '1550.00');
  PERFORM zz.check('receipt data: another pharmacy cannot', zz.val_as((SELECT u_px FROM zz.pf), format('SELECT public.order_receipt_supply(%L)::text', zz.ord('A'))) LIKE 'ERR: You do not have access to this order.%');
  PERFORM zz.check('receipt data: another wholesaler cannot', zz.val_as((SELECT u_wx FROM zz.pf), format('SELECT public.order_receipt_supply(%L)::text', zz.ord('A'))) LIKE 'ERR: You do not have access to this order.%');
  PERFORM zz.check('receipt data: a signed-out caller cannot', zz.val_as(NULL, format('SELECT public.order_receipt_supply(%L)::text', zz.ord('A'))) LIKE 'ERR:%');
END $$;

-- 8. The patch helper is repeatable and fail-closed; price history was deliberately left alone.
DO $$
BEGIN
  PERFORM zz.check('re-running a reader patch is recognised as already applied',
    public.apply_function_regex_patch('wholesaler_report_overview', '\mo\.total_ghs\M', 'COALESCE(o.effective_total_ghs, o.total_ghs)', 2, 'COALESCE(o.effective_total_ghs, o.total_ghs)') = 'already patched');
  BEGIN
    PERFORM public.apply_function_regex_patch('admin_platform_summary', '\mNOPE_NOT_THERE\M', 'x', 1, 'MARKER_NOT_PRESENT');
    PERFORM zz.check('a pattern that is not found raises and changes nothing', FALSE, 'no error');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('a pattern that is not found raises and changes nothing', SQLERRM LIKE 'Unexpected definition of admin_platform_summary%', SQLERRM);
  END;
  PERFORM zz.check('a function that does not exist is skipped', public.apply_function_regex_patch('no_such_function_here', 'a', 'b', 1, 'c') = 'not present');
  PERFORM zz.check('the price-history reports were deliberately left on the placed quantities',
    NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('pharmacy_price_history', 'pharmacy_price_history_detail') AND prosrc LIKE '%order_item_supplied_qty%'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
