-- Inventory intelligence: hand-computed expectations and access control.
-- Run after setup.sql + migration 20260924130000_wholesaler_inventory_insights.sql.
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

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now();

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  ph UUID; pa UUID; pb UUID; pc UUID; pd UUID; pe UUID; pf UUID; pg UUID;
  o1 UUID; o2 UUID; o3 UUID;
  r TEXT;
BEGIN
  -- stock: A 0, B 10, C 500, D 100, E 1000, F 20, G 40 (inactive); price 10 each
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Alpha',  'Cat', 'TABLET', '10s', 10, 0,    true) RETURNING id INTO pa;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Bravo',  'Cat', 'TABLET', '10s', 10, 10,   true) RETURNING id INTO pb;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Charlie','Cat', 'TABLET', '10s', 10, 500,  true) RETURNING id INTO pc;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Delta',  'Cat', 'TABLET', '10s', 10, 100,  true) RETURNING id INTO pd;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Echo',   'Cat', 'TABLET', '10s', 10, 1000, true) RETURNING id INTO pe;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Foxtrot', 'Cat', 'TABLET', '10s', 10, 20,   true) RETURNING id INTO pf;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Golf',    'Cat', 'TABLET', '10s', 10, 40,   false) RETURNING id INTO pg;

  -- Delta and Foxtrot have been listed for 120 days; Hotel is brand new and has never sold
  UPDATE public.products SET created_at = now() - interval '120 days' WHERE id IN (pd, pf);
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Zi Hotel', 'Cat', 'TABLET', '10s', 10, 30, true) RETURNING id INTO ph;

  -- counted sales in the last 10 days: A 30, B 30, C 3, E 300
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (good, alpha, 'delivered', 1, 1, 0, 'paid', 'cod', now() - interval '10 days') RETURNING id INTO o1;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES
    (o1, pa, 'Zi Alpha', 10, 30), (o1, pb, 'Zi Bravo', 10, 30), (o1, pc, 'Zi Charlie', 10, 3), (o1, pe, 'Zi Echo', 10, 300);
  -- a cancelled order for Delta must not count
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (good, alpha, 'cancelled', 1, 1, 0, 'unpaid', 'cod', now() - interval '5 days') RETURNING id INTO o2;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o2, pd, 'Zi Delta', 10, 99);
  -- an old sale (100 days ago) for Foxtrot is outside the 90-day lookback
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at)
  VALUES (good, alpha, 'delivered', 1, 1, 0, 'paid', 'cod', now() - interval '100 days') RETURNING id INTO o3;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o3, pf, 'Zi Foxtrot', 10, 50);

  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'', NULL, 100, 0)', alpha));
  PERFORM zz.check('seven active products listed, inactive hidden', r = '7', r);

  r := zz.val_as(u_wo, format('SELECT current_stock || ''/'' || status || ''/'' || COALESCE(suggested_reorder::text, ''-'') FROM public.wholesaler_inventory_insights(%L, 30, ''Alpha'') ', alpha));
  PERFORM zz.check('Alpha: out of stock, suggest 30', r = '0/out_of_stock/30', r);
  r := zz.val_as(u_wo, format('SELECT days_remaining || ''/'' || status || ''/'' || suggested_reorder FROM public.wholesaler_inventory_insights(%L, 30, ''Bravo'')', alpha));
  PERFORM zz.check('Bravo: 10 days left, low stock, suggest 20', r = '10.0/low_stock/20', r);
  r := zz.val_as(u_wo, format('SELECT status || ''/'' || movement FROM public.wholesaler_inventory_insights(%L, 30, ''Echo'')', alpha));
  PERFORM zz.check('Echo: ok and fast moving', r = 'ok/fast', r);
  r := zz.val_as(u_wo, format('SELECT status || ''/'' || movement FROM public.wholesaler_inventory_insights(%L, 30, ''Charlie'')', alpha));
  PERFORM zz.check('Charlie: ok and slow moving', r = 'ok/slow', r);
  r := zz.val_as(u_wo, format('SELECT status || ''/'' || units_sold_90d FROM public.wholesaler_inventory_insights(%L, 30, ''Delta'')', alpha));
  PERFORM zz.check('Delta: cancelled order ignored, dead stock', r = 'dead_stock/0', r);
  r := zz.val_as(u_wo, format('SELECT status FROM public.wholesaler_inventory_insights(%L, 30, ''Foxtrot'')', alpha));
  PERFORM zz.check('Foxtrot: sale older than 90 days is dead stock', r = 'dead_stock', r);

  r := zz.val_as(u_wo, format('SELECT status || ''/'' || COALESCE(movement, ''-'') FROM public.wholesaler_inventory_insights(%L, 30, ''Hotel'')', alpha));
  PERFORM zz.check('Hotel: new unsold product is ok, not dead stock', r = 'ok/-', r);
  r := zz.val_as(u_wo, format('SELECT total_products || ''/'' || total_out_of_stock || ''/'' || total_low_stock || ''/'' || total_dead_stock || ''/'' || total_stock_value_ghs FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'', NULL, 1, 0)', alpha));
  PERFORM zz.check('summary: 7 products, 1 out, 1 low, 2 dead, value 16600', r = '7/1/1/2/16600.00', r);
  r := zz.val_as(u_wo, format('SELECT total_count::text FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'', ''dead_stock'', 1, 0)', alpha));
  PERFORM zz.check('filter dead_stock totals 2 even when paged to 1', r = '2', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'', ''fast'')', alpha));
  PERFORM zz.check('filter fast returns 1', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT product_name FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'') LIMIT 1', alpha));
  PERFORM zz.check('most urgent first (out of stock)', r = 'Zi Alpha', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L, 30, ''%%'')', alpha));
  PERFORM zz.check('search treats % literally', r = '0', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L, 30, NULL, ''bogus'')', alpha));
  PERFORM zz.check('unknown filter rejected', r LIKE 'ERR%', r);

  r := zz.val_as(u_wm, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L, 30, ''Zi'', NULL, 100, 0)', alpha));
  PERFORM zz.check('manager allowed', r = '7', r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L)', alpha));
  PERFORM zz.check('cashier denied by the database', r LIKE 'ERR%', r);
  r := zz.val_as(u_wa, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L)', alpha));
  PERFORM zz.check('assistant denied by the database', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L)', alpha));
  PERFORM zz.check('other wholesaler denied', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L)', alpha));
  PERFORM zz.check('pharmacy denied', r LIKE 'ERR%', r);
  r := zz.val_as(u_nb, format('SELECT count(*)::text FROM public.wholesaler_inventory_insights(%L)', alpha));
  PERFORM zz.check('unrelated user denied', r LIKE 'ERR%', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.wholesaler_inventory_insights(alpha);
    RESET ROLE;
    PERFORM zz.check('anon cannot execute', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot execute', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
