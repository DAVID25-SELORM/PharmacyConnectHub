INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Zz Test Tablet', 'Generic', 'Antibiotic', 'TABLET', '10s', 100, 10, true FROM zz.b WHERE name = 'Alpha Wholesale';
CREATE TABLE IF NOT EXISTS zz.ctx AS SELECT (SELECT id FROM public.products WHERE name='Zz Test Tablet') AS pid;
-- 1) legit checkout through the service path (postgres == service_role privileges)
SELECT public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.ctx), 'quantity', 2))) AS orders_created;
SELECT o.subtotal_ghs, o.discount_type, o.discount_rate, o.discount_amount_ghs, o.total_ghs, o.status FROM public.orders o ORDER BY created_at DESC LIMIT 1;
SELECT oi.quantity, oi.unit_price_ghs, oi.base_unit_price_ghs, oi.discount_amount_ghs FROM public.order_items oi ORDER BY oi.id DESC LIMIT 1;
SELECT stock AS stock_after_reserve FROM public.products WHERE id = (SELECT pid FROM zz.ctx);
-- 2) pending pharmacy rejected
DO $$ BEGIN
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_pending'), (SELECT id FROM zz.b WHERE name='Pending Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.ctx), 'quantity', 1)));
    RAISE NOTICE 'FAIL | pending pharmacy checkout was allowed';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PASS | pending pharmacy checkout denied: %', SQLERRM; END;
  BEGIN
    PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_other'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.ctx), 'quantity', 1)));
    RAISE NOTICE 'FAIL | unrelated caller checkout was allowed';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PASS | unrelated caller cannot order for another pharmacy: %', SQLERRM; END;
END $$;
-- 3) IMPERSONATION PROBE: an ordinary authenticated user (ph_other) calls the RPC directly over the API path,
--    passing the victim pharmacy owner's id as _caller_id.
SELECT zz.run_as((SELECT id FROM zz.u WHERE k='ph_other'),
  format('SELECT public.create_marketplace_orders(%L, %L, %L::jsonb)', (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.ctx), 'quantity', 1))::text)) AS authenticated_direct_rpc_impersonation;
SELECT count(*) AS orders_total FROM public.orders;
