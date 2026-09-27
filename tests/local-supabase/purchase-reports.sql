-- Pharmacy purchase reports (pharmacy_report_purchases / pharmacy_report_purchases_summary):
-- NHIS/Cash filtering, correct exclusion of Mixed-order lines that don't match, no double
-- counting, access control. Run after setup.sql + migrations through
-- 20260930100000_pharmacy_purchase_reports.sql.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
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
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

-- a pharmacy manager on Good Pharmacy, to prove the report RPCs use the same owner-or-staff check
-- as the other pharmacy report RPCs
SELECT zz.mkuser('40000000-0000-0000-0000-0000000000d1', 'phrm@zz.test', '{"full_name":"Good Pharmacy Report Manager","phone":"+233241000016"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '40000000-0000-0000-0000-0000000000d1', 'manager', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PR Metformin', 'Generic', 'Antidiabetic', 'TABLET', '100s', 20, 500, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PR Vitamin C', 'Generic', 'Supplement', 'TABLET', '30s', 15, 500, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'PR Amlodipine', 'Generic', 'Antihypertensive', 'TABLET', '50s', 25, 500, true FROM zz.b WHERE name='Other Wholesale';

-- Each checkout is its own top-level statement (create_marketplace_orders' ON COMMIT DROP temp
-- tables would collide if these ran inside one shared transaction - see purchase-classification.sql).
-- 1) fully NHIS, single line, Alpha
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='PR Metformin'), 'quantity', 2, 'category', 'nhis')));
-- 2) fully Cash/Private, single line, Alpha
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='PR Vitamin C'), 'quantity', 1, 'category', 'cash_private')));
-- 3) Mixed, two lines, Alpha: 20 GHS*2=40 NHIS, 15 GHS*1=15 Cash
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(
    jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='PR Metformin'), 'quantity', 2, 'category', 'nhis'),
    jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='PR Vitamin C'), 'quantity', 1, 'category', 'cash_private')
  ));
-- 4) unclassified (no category sent), single line, Other Wholesale
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='PR Amlodipine'), 'quantity', 1)));

DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pm UUID := '40000000-0000-0000-0000-0000000000d1';
  r TEXT;
  -- Ground truth computed directly from order_items (NOT hardcoded list-price arithmetic: Good
  -- Pharmacy has standing customer discounts with both wholesalers per setup.sql, so the stored
  -- unit_price_ghs is already post-discount and would make hand-calculated totals wrong).
  v_nhis_total NUMERIC; v_cash_total NUMERIC; v_unclassified_total NUMERIC; v_grand_total NUMERIC;
  v_other_total NUMERIC; v_item_qty NUMERIC;
BEGIN
  SELECT
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category = 'nhis'), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category = 'cash_private'), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE oi.purchase_category IS NULL), 0),
    COALESCE(SUM(round(oi.unit_price_ghs * oi.quantity, 2)) FILTER (WHERE o.wholesaler_id = other_w), 0),
    COALESCE(SUM(oi.quantity), 0)
  INTO v_grand_total, v_nhis_total, v_cash_total, v_unclassified_total, v_other_total, v_item_qty
  FROM public.order_items oi JOIN public.orders o ON o.id = oi.order_id WHERE o.pharmacy_id = good;
  ------------------------------------------------------------------
  -- Access control, matching every other pharmacy_report_* RPC: owner or active staff, never a
  -- different pharmacy.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT jsonb_agg(x)::text FROM public.pharmacy_report_purchases(%L, ''all'') x', good));
  PERFORM zz.check('owner can list purchase lines', r NOT LIKE 'ERR%' AND r IS NOT NULL, r);
  r := zz.val_as(u_pm, format(
    'SELECT jsonb_agg(x)::text FROM public.pharmacy_report_purchases(%L, ''all'') x', good));
  PERFORM zz.check('active manager can also list purchase lines', r NOT LIKE 'ERR%' AND r IS NOT NULL, r);
  r := zz.val_as(u_px, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'')', good));
  PERFORM zz.check('a different pharmacy is denied', r LIKE 'ERR: You do not have access%', r);

  ------------------------------------------------------------------
  -- Purchase category filter: item-level, so a Mixed order contributes only the lines that match.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''nhis'')', good));
  PERFORM zz.check('NHIS filter: 2 lines (the NHIS-only order + the NHIS line of the Mixed order)', r = '2', r);
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''cash_private'')', good));
  PERFORM zz.check('Cash filter: 2 lines (the Cash-only order + the Cash line of the Mixed order)', r = '2', r);
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''unclassified'')', good));
  PERFORM zz.check('unclassified filter: 1 line', r = '1', r);
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'')', good));
  PERFORM zz.check('no category filter: all 5 lines (2+2+1)', r = '5', r);

  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''mixed'')', good));
  PERFORM zz.check('mixed is not a valid item-level filter value', r LIKE 'ERR: Invalid purchase category filter%', r);

  ------------------------------------------------------------------
  -- A Mixed order's Cash line never appears in the NHIS-filtered result, and vice versa (the
  -- exact requirement from the brief, checked directly rather than just by count).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''nhis'') x WHERE x.product_name = ''PR Vitamin C''', good));
  PERFORM zz.check('NHIS-filtered rows never include a Vitamin C (cash) line', r = '0', r);
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, NULL, ''cash_private'') x WHERE x.product_name = ''PR Metformin''', good));
  PERFORM zz.check('Cash-filtered rows never include a Metformin (nhis) line', r = '0', r);

  ------------------------------------------------------------------
  -- Supplier filter.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, %L)', good, alpha));
  PERFORM zz.check('supplier filter: Alpha has 4 lines', r = '4', r);
  r := zz.val_as(u_po, format(
    'SELECT count(*)::text FROM public.pharmacy_report_purchases(%L, ''all'', NULL, NULL, %L)', good, other_w));
  PERFORM zz.check('supplier filter: Other Wholesale has 1 line', r = '1', r);

  ------------------------------------------------------------------
  -- Summary: correct value split, no double counting (order_count is DISTINCT orders, not rows).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).total_value_ghs::text', good));
  PERFORM zz.check('summary total matches ground truth (post-discount) sum', r::numeric = v_grand_total, format('%s vs %s', r, v_grand_total));
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).nhis_value_ghs::text', good));
  PERFORM zz.check('summary nhis_value matches ground truth', r::numeric = v_nhis_total, format('%s vs %s', r, v_nhis_total));
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).cash_private_value_ghs::text', good));
  PERFORM zz.check('summary cash_private_value matches ground truth', r::numeric = v_cash_total, format('%s vs %s', r, v_cash_total));
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).unclassified_value_ghs::text', good));
  PERFORM zz.check('summary unclassified_value matches ground truth', r::numeric = v_unclassified_total, format('%s vs %s', r, v_unclassified_total));
  PERFORM zz.check('nhis + cash + unclassified + other(none here) = grand total (no double counting across categories)',
    v_nhis_total + v_cash_total + v_unclassified_total = v_grand_total);
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).order_count::text', good));
  PERFORM zz.check('summary order_count = 4 distinct orders, not 5 lines (no double counting)', r = '4', r);
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'')).item_quantity::text', good));
  PERFORM zz.check('summary item_quantity matches ground truth', r::numeric = v_item_qty, format('%s vs %s', r, v_item_qty));

  ------------------------------------------------------------------
  -- Summary respects the supplier/status/payment filters but not a category filter (it has none -
  -- it always shows the full NHIS/Cash breakdown for whatever set of orders is in scope).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT (public.pharmacy_report_purchases_summary(%L, ''all'', NULL, NULL, %L)).total_value_ghs::text', good, other_w));
  PERFORM zz.check('summary scoped to Other Wholesale only matches ground truth', r::numeric = v_other_total, format('%s vs %s', r, v_other_total));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
