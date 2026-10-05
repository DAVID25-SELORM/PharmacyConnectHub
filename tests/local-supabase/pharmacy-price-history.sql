-- Pharmacy price history (pharmacy_price_history, pharmacy_price_history_detail):
--   * price paid per product over time, matched across suppliers on name + brand + form + pack size;
--   * change = latest purchase vs the previous purchase from the SAME supplier (looking back before the
--     range); a supplier switch is not a price change;
--   * "cheaper elsewhere" only when another supplier's latest price is lower;
--   * cancelled orders are ignored; quantity-weighted average; category / supplier / search filters; paging;
--   * access: the pharmacy's owner and active staff only; nothing of another business is readable.
-- Run after setup.sql + migrations (through 20261023100000_pharmacy_price_history.sql).
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

-- Pharmacy staff: an accountant, a cashier and an assistant who will be made inactive.
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b1', 'gacc@zz.test', '{"full_name":"Good Accountant","phone":"+233241000045"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b2', 'gcash@zz.test', '{"full_name":"Good Cashier","phone":"+233241000046"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b3', 'gass@zz.test', '{"full_name":"Good Assistant","phone":"+233241000047"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = 'Good Pharmacy'), v.uid, v.r::public.staff_role, 'active', now()
FROM (VALUES
  ('30000000-0000-0000-0000-0000000000b1'::uuid, 'accountant'),
  ('30000000-0000-0000-0000-0000000000b2'::uuid, 'cashier'),
  ('30000000-0000-0000-0000-0000000000b3'::uuid, 'assistant')) v(uid, r);

-- The same drug at two suppliers (spelled differently at the second), a different pack size, and a single-supplier product.
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), 'PH Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true
UNION ALL SELECT (SELECT id FROM zz.b WHERE name='Other Wholesale'), '  PH ITEM ', 'GENERIC', 'Analgesic', 'tablet', ' 100S', 90, 100000, true
UNION ALL SELECT (SELECT id FROM zz.b WHERE name='Other Wholesale'), 'PH Item', 'Generic', 'Analgesic', 'TABLET', '50s', 50, 100000, true
UNION ALL SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), 'PH Second', NULL, 'Analgesic', 'TABLET', '10s', 20, 100000, true;
CREATE TABLE zz.ph AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Other Pharmacy') other_p,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other_w,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  '30000000-0000-0000-0000-0000000000b1'::uuid u_pacc,
  '30000000-0000-0000-0000-0000000000b2'::uuid u_pcash,
  '30000000-0000-0000-0000-0000000000b3'::uuid u_pass,
  (SELECT id FROM public.products WHERE name = 'PH Item' AND pack_size = '100s') p_a,
  (SELECT id FROM public.products WHERE name = '  PH ITEM ') p_o,
  (SELECT id FROM public.products WHERE name = 'PH Item' AND pack_size = '50s') p_o50,
  (SELECT id FROM public.products WHERE name = 'PH Second') p_a2;
CREATE TABLE zz.ph_runs(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_po FROM zz.ph), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_po FROM zz.ph)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;

-- Purchases (cash on delivery), each placed at the product's price of the moment and then dated.
-- A1  Alpha  10 @100   60 days ago  (before the 30-day range)
UPDATE public.products SET price_ghs = 100 WHERE id = (SELECT p_a FROM zz.ph);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a FROM zz.ph), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset a1_
INSERT INTO zz.ph_runs SELECT 'A1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- A2  Alpha  10 @110   20 days ago, NHIS
UPDATE public.products SET price_ghs = 110 WHERE id = (SELECT p_a FROM zz.ph);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a FROM zz.ph), 'quantity', 10, 'category', 'nhis')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset a2_
INSERT INTO zz.ph_runs SELECT 'A2', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- A3  Alpha  20 @121   2 days ago
UPDATE public.products SET price_ghs = 121 WHERE id = (SELECT p_a FROM zz.ph);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a FROM zz.ph), 'quantity', 20, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset a3_
INSERT INTO zz.ph_runs SELECT 'A3', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- C1  Alpha  5 @130    1 day ago, then CANCELLED (must not count as a price paid)
UPDATE public.products SET price_ghs = 130 WHERE id = (SELECT p_a FROM zz.ph);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a FROM zz.ph), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset c1_
INSERT INTO zz.ph_runs SELECT 'C1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- O1  Other Wholesale  10 @90   10 days ago
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_o FROM zz.ph), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT other_w FROM zz.ph)::text, 'cod')) AS r \gset o1_
INSERT INTO zz.ph_runs SELECT 'O1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- N1  Other Wholesale  1 @50  (a different pack size: must not be compared with the 100s)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_o50 FROM zz.ph), 'quantity', 1, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT other_w FROM zz.ph)::text, 'cod')) AS r \gset n1_
INSERT INTO zz.ph_runs SELECT 'N1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- S1  Alpha  4 @20  (a product bought from one supplier only, once)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.ph), (SELECT good FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a2 FROM zz.ph), 'quantity', 4, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset s1_
INSERT INTO zz.ph_runs SELECT 'S1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
-- P1  Another pharmacy buys the same product from Alpha (isolation).
UPDATE public.products SET price_ghs = 121 WHERE id = (SELECT p_a FROM zz.ph);
SELECT public.create_marketplace_orders((SELECT u_px FROM zz.ph), (SELECT other_p FROM zz.ph),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_a FROM zz.ph), 'quantity', 3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.ph)::text, 'cod')) AS r \gset p1_
INSERT INTO zz.ph_runs SELECT 'P1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- Production's order guard makes created_at immutable; lift it only while dating the fixtures, then restore it.
-- (On a database without the guard this loop finds nothing and does nothing.)
DO $$
DECLARE trg RECORD;
BEGIN
  FOR trg IN SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass AND NOT tgisinternal
      AND tgfoid IN (SELECT oid FROM pg_proc WHERE proname = 'phase0_order_integrity') LOOP
    EXECUTE format('ALTER TABLE public.orders DISABLE TRIGGER %I', trg.tgname);
  END LOOP;
END $$;
-- Date them, cancel C1, and make O1's list price higher than what was paid (a discount).
UPDATE public.orders SET created_at = now() - interval '60 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'A1');
UPDATE public.orders SET created_at = now() - interval '20 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'A2');
UPDATE public.orders SET created_at = now() - interval '2 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'A3');
UPDATE public.orders SET created_at = now() - interval '1 day' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'C1');
UPDATE public.orders SET created_at = now() - interval '10 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'O1');
UPDATE public.orders SET created_at = now() - interval '3 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'N1');
UPDATE public.orders SET created_at = now() - interval '5 days' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'S1');
UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT order_id FROM zz.ph_runs WHERE label = 'C1');
DO $$
DECLARE trg RECORD;
BEGIN
  FOR trg IN SELECT tgname FROM pg_trigger WHERE tgrelid = 'public.orders'::regclass AND NOT tgisinternal
      AND tgfoid IN (SELECT oid FROM pg_proc WHERE proname = 'phase0_order_integrity') LOOP
    EXECUTE format('ALTER TABLE public.orders ENABLE TRIGGER %I', trg.tgname);
  END LOOP;
END $$;
UPDATE public.order_items SET base_unit_price_ghs = 150 WHERE order_id = (SELECT order_id FROM zz.ph_runs WHERE label = 'O1');

-- 1. The fixtures are what the test assumes.
DO $$
BEGIN
  PERFORM zz.check('seven purchases for Good Pharmacy exist, plus one for the other pharmacy', (SELECT count(*) FROM public.orders WHERE pharmacy_id = (SELECT good FROM zz.ph)) = 7 AND (SELECT count(*) FROM public.orders WHERE pharmacy_id = (SELECT other_p FROM zz.ph)) = 1,
    (SELECT count(*)::text FROM public.orders WHERE pharmacy_id = (SELECT good FROM zz.ph)));
  PERFORM zz.check('the prices were captured at checkout: 100, 110, 121, 130 (Alpha) and 90 (Other)',
    (SELECT string_agg(oi.unit_price_ghs::text, ',' ORDER BY o.created_at) FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id WHERE o.pharmacy_id = (SELECT good FROM zz.ph) AND oi.product_id IN (SELECT p_a FROM zz.ph UNION SELECT p_o FROM zz.ph))
      = '100.00,110.00,90.00,121.00,130.00');
END $$;

-- 2. The summary over the last 30 days.
DO $$
DECLARE g UUID := (SELECT good FROM zz.ph); r RECORD; n INT;
BEGIN
  SELECT count(*) INTO n FROM public.pharmacy_price_history(g, '30d');
  PERFORM zz.check('three products in the last 30 days (the 100s, the 50s, and PH Second)', n = 3, n::text);
  PERFORM zz.check('rows come back ordered by spend, highest first (100s, then PH Second, then the 50s)',
    (SELECT array_agg(pack_size) FROM (SELECT * FROM public.pharmacy_price_history(g, '30d') OFFSET 0) x) = ARRAY['100s', '10s', '50s']::text[],
    (SELECT array_agg(pack_size)::text FROM (SELECT * FROM public.pharmacy_price_history(g, '30d') OFFSET 0) x));
  SELECT * INTO r FROM public.pharmacy_price_history(g, '30d') WHERE pack_size = '100s';
  PERFORM zz.check('PH Item 100s: 3 purchases (the 60-day-old one and the cancelled one are not counted), 40 units', r.purchases = 3 AND r.units = 40, r.purchases || '/' || r.units);
  PERFORM zz.check('spend = 1,100 + 2,420 + 900 = 4,420 and the average paid is quantity-weighted (110.50, not the simple 107)', r.spend_ghs = 4420 AND r.avg_paid_ghs = 110.5, r.spend_ghs || '/' || r.avg_paid_ghs);
  PERFORM zz.check('lowest paid 90, highest paid 121 (the cancelled 130 is ignored)', r.min_paid_ghs = 90 AND r.max_paid_ghs = 121, r.min_paid_ghs || '/' || r.max_paid_ghs);
  PERFORM zz.check('two suppliers (the second spells the product differently and still matches)', r.suppliers = 2);
  PERFORM zz.check('latest purchase: 121 from Alpha Wholesale', r.latest_paid_ghs = 121 AND r.latest_supplier_name = 'Alpha Wholesale', r.latest_paid_ghs || '/' || r.latest_supplier_name);
  PERFORM zz.check('the previous purchase from the same supplier was 110, so the change is +10.0%', r.previous_paid_ghs = 110 AND r.change_pct = 10.0, r.previous_paid_ghs || '/' || r.change_pct);
  PERFORM zz.check('Other Wholesale''s latest price (90) is lower than the 121 last paid, so it is shown as cheaper', r.cheaper_paid_ghs = 90 AND r.cheaper_supplier_name = 'Other Wholesale', r.cheaper_paid_ghs || '/' || r.cheaper_supplier_name);
  PERFORM zz.check('the display name comes from the latest purchase', r.product_name = 'PH Item' AND r.brand = 'Generic');
  SELECT * INTO r FROM public.pharmacy_price_history(g, '30d') WHERE pack_size = '50s';
  PERFORM zz.check('the 50s pack is its own row and is not compared with the 100s: one purchase, no change, nothing cheaper',
    r.purchases = 1 AND r.latest_paid_ghs = 50 AND r.change_pct IS NULL AND r.cheaper_paid_ghs IS NULL AND r.suppliers = 1);
  SELECT * INTO r FROM public.pharmacy_price_history(g, '30d') WHERE product_name = 'PH Second';
  PERFORM zz.check('a product bought once from one supplier shows no change and nothing cheaper', r.purchases = 1 AND r.change_pct IS NULL AND r.previous_paid_ghs IS NULL AND r.cheaper_paid_ghs IS NULL);
  PERFORM zz.check('every row reports the same total count', (SELECT count(DISTINCT total_count) = 1 AND max(total_count) = 3 FROM public.pharmacy_price_history(g, '30d')));
END $$;

-- 3. Ranges: the previous price may lie before the range; a longer range sees older purchases.
DO $$
DECLARE g UUID := (SELECT good FROM zz.ph); r RECORD;
BEGIN
  SELECT * INTO r FROM public.pharmacy_price_history(g, 'custom', now() - interval '3 days', now(), NULL, NULL, NULL) WHERE pack_size = '100s';
  PERFORM zz.check('a 3-day range holds only the latest Alpha purchase, yet still reports +10.0% against the 110 paid before the range',
    r.purchases = 1 AND r.latest_paid_ghs = 121 AND r.previous_paid_ghs = 110 AND r.change_pct = 10.0 AND r.suppliers = 1 AND r.cheaper_paid_ghs IS NULL,
    r.purchases || '/' || r.change_pct || '/' || COALESCE(r.cheaper_paid_ghs::text, 'null'));
  SELECT * INTO r FROM public.pharmacy_price_history(g, 'custom', now() - interval '90 days', now(), NULL, NULL, NULL) WHERE pack_size = '100s';
  PERFORM zz.check('a 90-day range adds the 60-day-old purchase: 4 purchases, 50 units, lowest 90', r.purchases = 4 AND r.units = 50 AND r.min_paid_ghs = 90 AND r.spend_ghs = 5420, r.purchases || '/' || r.units || '/' || r.spend_ghs);
  PERFORM zz.check('a range before any purchase returns nothing', (SELECT count(*) FROM public.pharmacy_price_history(g, 'custom', now() - interval '200 days', now() - interval '100 days', NULL, NULL, NULL)) = 0);
  SELECT * INTO r FROM public.pharmacy_price_history(g, 'custom', now() - interval '25 days', now() - interval '15 days', NULL, NULL, NULL) WHERE pack_size = '100s';
  PERFORM zz.check('a mid range ending before the later purchases: latest is the 110 NHIS purchase, +10.0% on the 100 before the range',
    r.latest_paid_ghs = 110 AND r.previous_paid_ghs = 100 AND r.change_pct = 10.0, r.latest_paid_ghs || '/' || COALESCE(r.change_pct::text, 'null'));
END $$;

-- 4. Filters and paging.
DO $$
DECLARE g UUID := (SELECT good FROM zz.ph); r RECORD;
BEGIN
  SELECT * INTO r FROM public.pharmacy_price_history(g, '30d', NULL, NULL, (SELECT other_w FROM zz.ph)) WHERE lower(btrim(pack_size)) = '100s';
  PERFORM zz.check('supplier filter (Other Wholesale): the 100s shows only its 90 purchase, nothing to compare', r.purchases = 1 AND r.latest_paid_ghs = 90 AND r.suppliers = 1 AND r.cheaper_paid_ghs IS NULL AND r.change_pct IS NULL);
  PERFORM zz.check('supplier filter (Other Wholesale) returns its two products, not Alpha''s PH Second', (SELECT count(*) FROM public.pharmacy_price_history(g, '30d', NULL, NULL, (SELECT other_w FROM zz.ph))) = 2);
  SELECT * INTO r FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, 'nhis') WHERE pack_size = '100s';
  PERFORM zz.check('category NHIS: only the 110 NHIS purchase', r.purchases = 1 AND r.latest_paid_ghs = 110 AND r.units = 10);
  PERFORM zz.check('category NHIS returns just that one product', (SELECT count(*) FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, 'nhis')) = 1);
  PERFORM zz.check('category "unclassified" finds nothing (every purchase was classified)', (SELECT count(*) FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, 'unclassified')) = 0);
  PERFORM zz.check('search by name finds PH Second only', (SELECT count(*) FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, NULL, 'second')) = 1);
  PERFORM zz.check('search by brand (generic) finds the two PH Item rows', (SELECT count(*) FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, NULL, '  GENERIC ')) = 2);
  PERFORM zz.check('paging: limit 1 offset 1 returns the second row and still reports 3 in total',
    (SELECT count(*) = 1 AND max(total_count) = 3 AND max(pack_size) = '10s' FROM public.pharmacy_price_history(g, '30d', NULL, NULL, NULL, NULL, NULL, 1, 1)));
END $$;

-- 5. The purchases behind a row.
DO $$
DECLARE g UUID := (SELECT good FROM zz.ph); pid UUID; n INT;
BEGIN
  SELECT sample_product_id INTO pid FROM public.pharmacy_price_history(g, '30d') WHERE pack_size = '100s';
  SELECT count(*) INTO n FROM public.pharmacy_price_history_detail(g, pid, '30d');
  PERFORM zz.check('detail: three purchases in range, from both suppliers (cancelled and out-of-range ones excluded)', n = 3, n::text);
  PERFORM zz.check('detail is newest first: Alpha 121, Other 90, Alpha 110',
    (SELECT string_agg(supplier_name || ' ' || paid_ghs::int, ', ' ORDER BY purchased_at DESC) FROM public.pharmacy_price_history_detail(g, pid, '30d')) = 'Alpha Wholesale 121, Other Wholesale 90, Alpha Wholesale 110',
    (SELECT string_agg(supplier_name || ' ' || paid_ghs::int, ', ' ORDER BY purchased_at DESC) FROM public.pharmacy_price_history_detail(g, pid, '30d')));
  PERFORM zz.check('detail changes: +10.0% for each Alpha purchase, none for the first Other Wholesale purchase',
    (SELECT string_agg(COALESCE(change_pct::text, 'none'), ',' ORDER BY purchased_at DESC) FROM public.pharmacy_price_history_detail(g, pid, '30d')) = '10.0,none,10.0');
  PERFORM zz.check('detail change for the oldest in-range purchase looks back before the range (110 vs the 100 paid 60 days ago)',
    (SELECT previous_paid_ghs = 100 FROM public.pharmacy_price_history_detail(g, pid, '30d') ORDER BY purchased_at ASC LIMIT 1));
  PERFORM zz.check('detail shows the list price above the price paid where there was a discount (150 list, 90 paid)',
    (SELECT list_price_ghs = 150 AND paid_ghs = 90 FROM public.pharmacy_price_history_detail(g, pid, '30d') WHERE supplier_name = 'Other Wholesale'));
  PERFORM zz.check('detail carries the order number, category and status',
    (SELECT bool_and(order_number IS NOT NULL AND order_status IS NOT NULL) AND bool_or(purchase_category = 'nhis') FROM public.pharmacy_price_history_detail(g, pid, '30d')));
  PERFORM zz.check('detail honours the supplier filter', (SELECT count(*) FROM public.pharmacy_price_history_detail(g, pid, '30d', NULL, NULL, (SELECT other_w FROM zz.ph))) = 1);
  PERFORM zz.check('detail honours the category filter', (SELECT count(*) FROM public.pharmacy_price_history_detail(g, pid, '30d', NULL, NULL, NULL, 'nhis')) = 1);
  PERFORM zz.check('the detail total_count covers all rows even when the page is cut short',
    (SELECT count(*) = 1 AND max(total_count) = 3 FROM public.pharmacy_price_history_detail(g, pid, '30d', NULL, NULL, NULL, NULL, 1)));
  PERFORM zz.check('the detail of a product this pharmacy never bought is empty (nothing leaks)',
    zz.val_as((SELECT u_px FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history_detail(%L, %L, ''30d'')', (SELECT other_p FROM zz.ph), (SELECT p_a2 FROM zz.ph))) = '0');
END $$;

-- 6. Validation.
DO $$
DECLARE r TEXT; g UUID := (SELECT good FROM zz.ph);
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history(%L, ''30d'', NULL, NULL, NULL, ''bogus'')', g));
  PERFORM zz.check('an unknown category is refused', r = 'ERR: Invalid purchase category filter.', r);
  r := zz.val_as((SELECT u_po FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history(%L, ''30d'', NULL, NULL, NULL, NULL, NULL, 0, 0)', g));
  PERFORM zz.check('a page size of 0 is refused', r = 'ERR: The page size must be between 1 and 500.', r);
  r := zz.val_as((SELECT u_po FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history(%L, ''30d'', NULL, NULL, NULL, NULL, NULL, 10, -1)', g));
  PERFORM zz.check('a negative offset is refused', r = 'ERR: Invalid offset.', r);
  r := zz.val_as((SELECT u_po FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history_detail(%L, %L, ''30d'')', g, gen_random_uuid()));
  PERFORM zz.check('a detail request for an unknown product is refused', r = 'ERR: Product not found.', r);
END $$;

-- 7. Access.
UPDATE public.business_staff SET status = 'inactive' WHERE user_id = '30000000-0000-0000-0000-0000000000b3';
DO $$
DECLARE r TEXT; g UUID := (SELECT good FROM zz.ph);
  q TEXT := 'SELECT count(*)::text FROM public.pharmacy_price_history(%L, ''30d'')';
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.ph), format(q, g));    PERFORM zz.check('the pharmacy owner can read it', r = '3', r);
  r := zz.val_as((SELECT u_pacc FROM zz.ph), format(q, g));  PERFORM zz.check('the pharmacy accountant can', r = '3', r);
  r := zz.val_as((SELECT u_pcash FROM zz.ph), format(q, g)); PERFORM zz.check('active pharmacy staff can, as with the other pharmacy reports', r = '3', r);
  r := zz.val_as((SELECT u_pass FROM zz.ph), format(q, g));  PERFORM zz.check('suspended staff cannot', r = 'ERR: You do not have access to this pharmacy''s reports.', r);
  r := zz.val_as((SELECT u_px FROM zz.ph), format(q, g));    PERFORM zz.check('another pharmacy''s owner cannot read Good Pharmacy''s prices', r = 'ERR: You do not have access to this pharmacy''s reports.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ph), format(q, g));    PERFORM zz.check('a wholesaler cannot read a pharmacy''s prices', r = 'ERR: You do not have access to this pharmacy''s reports.', r);
  r := zz.val_as((SELECT u_wo FROM zz.ph), format(q, (SELECT alpha FROM zz.ph))); PERFORM zz.check('a business that is not a pharmacy cannot use the report even for itself', r = 'ERR: You do not have access to this pharmacy''s reports.', r);
  r := zz.val_as((SELECT u_pass FROM zz.ph), format('SELECT count(*)::text FROM public.pharmacy_price_history_detail(%L, %L, ''30d'')', g, (SELECT p_a FROM zz.ph)));
  PERFORM zz.check('the detail has the same gate', r = 'ERR: You do not have access to this pharmacy''s reports.', r);
  r := zz.val_as((SELECT u_px FROM zz.ph), format('SELECT count(*)::text || ''/'' || COALESCE(max(quantity), 0) FROM public.pharmacy_price_history_detail(%L, %L, ''30d'')', (SELECT other_p FROM zz.ph), (SELECT p_a FROM zz.ph)));
  PERFORM zz.check('the other pharmacy sees only its own single purchase (3 units), none of Good Pharmacy''s', r = '1/3', r);
  r := zz.val_as((SELECT u_px FROM zz.ph), format('SELECT purchases::text || ''/'' || units || ''/'' || COALESCE(change_pct::text, ''none'') FROM public.pharmacy_price_history(%L, ''30d'')', (SELECT other_p FROM zz.ph)));
  PERFORM zz.check('the other pharmacy''s summary has one purchase, 3 units and no change (Good Pharmacy''s history does not leak in)', r = '1/3/none', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
