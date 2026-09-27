-- Pharmacy order history filters: date range, supplier, purchase category, procurement-reference
-- search, plus the pharmacy-staff access fix. Run after setup.sql + migrations through
-- 20260929100000_pharmacy_order_history_filters.sql.
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

-- a pharmacy manager on Good Pharmacy, to prove the staff-access fix
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000c1', 'phm@zz.test', '{"full_name":"Good Pharmacy Manager","phone":"+233241000015"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT id, '30000000-0000-0000-0000-0000000000c1', 'manager', 'active', now() FROM zz.b WHERE name='Good Pharmacy';

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'OHF Metformin', 'Generic', 'Antidiabetic', 'TABLET', '100s', 20, 500, true FROM zz.b WHERE name='Alpha Wholesale';
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'OHF Amlodipine', 'Generic', 'Antihypertensive', 'TABLET', '50s', 25, 500, true FROM zz.b WHERE name='Other Wholesale';

-- Three separate checkout calls, each its own top-level statement/transaction (create_marketplace_orders'
-- ON COMMIT DROP temp tables would collide if these ran inside one shared transaction/DO block -
-- see the note at the top of purchase-classification.sql for the full explanation).
-- 1) an NHIS order from Alpha
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='OHF Metformin'), 'quantity', 2, 'category', 'nhis')));
-- 2) a Cash order from Other Wholesale
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='OHF Amlodipine'), 'quantity', 2, 'category', 'cash_private')));
-- 3) an unclassified order, backdated afterward to prove date-range filtering excludes it
SELECT public.create_marketplace_orders(
  (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name='OHF Metformin'), 'quantity', 1)));
UPDATE public.orders SET created_at = now() - interval '60 days'
WHERE pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy') AND purchase_category IS NULL;

DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  other_pharm UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pm UUID := '30000000-0000-0000-0000-0000000000c1';
  o_old UUID := (SELECT id FROM public.orders WHERE pharmacy_id = (SELECT id FROM zz.b WHERE name='Good Pharmacy') AND purchase_category IS NULL);
  r TEXT;
BEGIN
  ------------------------------------------------------------------
  -- Staff access fix: the owner and an active manager can both list and open order history;
  -- a different pharmacy still cannot see any of it.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'')->>''total_count'')'));
  PERFORM zz.check('owner can list order history', r::int >= 3, r);
  r := zz.val_as(u_pm, format('SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'')->>''total_count'')'));
  PERFORM zz.check('active manager can also list order history (staff-access fix)', r::int >= 3, r);
  r := zz.val_as(u_px, format('SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'')->>''total_count'')'));
  PERFORM zz.check('a different pharmacy sees none of these orders', r = '0', r);

  r := zz.val_as(u_pm, format('SELECT (public.get_pharmacy_order_detail(%L)->''order''->>''order_number'')', o_old));
  PERFORM zz.check('active manager can open order detail (staff-access fix)', r LIKE 'ORD-%', r);
  r := zz.val_as(u_px, format('SELECT (public.get_pharmacy_order_detail(%L)::text)', o_old));
  PERFORM zz.check('a different pharmacy cannot open the order detail', r IS NULL, r);

  ------------------------------------------------------------------
  -- Purchase category filter.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, 'SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',NULL,NULL,NULL,NULL,''nhis'')->>''total_count'')');
  PERFORM zz.check('purchase category filter: nhis', r = '1', r);
  r := zz.val_as(u_po, 'SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',NULL,NULL,NULL,NULL,''cash_private'')->>''total_count'')');
  PERFORM zz.check('purchase category filter: cash_private', r = '1', r);
  r := zz.val_as(u_po, 'SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',NULL,NULL,NULL,NULL,''unclassified'')->>''total_count'')');
  PERFORM zz.check('purchase category filter: unclassified', r = '1', r);

  ------------------------------------------------------------------
  -- Supplier filter.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',NULL,NULL,NULL,%L)->>''total_count'')', alpha));
  PERFORM zz.check('supplier filter: Alpha only', r = '2', r); -- the NHIS order and the (also-Alpha) backdated order
  r := zz.val_as(u_po, format('SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',NULL,NULL,NULL,%L)->>''total_count'')', other_w));
  PERFORM zz.check('supplier filter: Other Wholesale only', r = '1', r);

  ------------------------------------------------------------------
  -- Date range filter: 'today' excludes the 60-day-old backdated order.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, 'SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',''today'')->>''total_count'')');
  PERFORM zz.check('date range filter: today excludes the backdated order', r = '2', r);
  r := zz.val_as(u_po, 'SELECT (public.list_pharmacy_order_history(1,20,NULL,NULL,NULL,''newest'',''this_month'')->>''total_count'')');
  PERFORM zz.check('date range filter: this_month still excludes a 60-day-old order', r = '2', r);

  ------------------------------------------------------------------
  -- Search matches the procurement reference too (not just order number / supplier / product).
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format(
    'SELECT (public.list_pharmacy_order_history(1,20,%L)->>''total_count'')',
    (SELECT pr.reference FROM public.procurements pr JOIN public.orders o ON o.procurement_id = pr.id WHERE o.id = o_old)));
  PERFORM zz.check('search matches procurement reference', r = '1', r);

  ------------------------------------------------------------------
  -- get_pharmacy_order_detail surfaces the procurement reference and purchase category.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT (public.get_pharmacy_order_detail(%L)->''order''->>''procurement_reference'')',
    (SELECT id FROM public.orders WHERE pharmacy_id = good AND purchase_category = 'nhis')));
  PERFORM zz.check('order detail includes procurement_reference', r LIKE 'PUR-%', r);
  r := zz.val_as(u_po, format('SELECT (public.get_pharmacy_order_detail(%L)->''order''->>''purchase_category'')',
    (SELECT id FROM public.orders WHERE pharmacy_id = good AND purchase_category = 'nhis')));
  PERFORM zz.check('order detail includes purchase_category', r = 'nhis', r);

  ------------------------------------------------------------------
  -- resolve_report_range's new this_week branch behaves sensibly (from <= now, spans <= 7 days).
  ------------------------------------------------------------------
  PERFORM zz.check('resolve_report_range this_week is sane',
    (SELECT range_from <= now() AND range_to >= now() - interval '1 minute' AND now() - range_from <= interval '7 days'
     FROM public.resolve_report_range('this_week', NULL, NULL)));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
