-- Minimum order quantity is enforced by create_marketplace_orders. Run after setup.sql + migrations.
-- Each checkout call is its own transaction (the function uses ON COMMIT DROP temp tables).
CREATE TABLE zz.moq(pid UUID);
GRANT ALL ON zz.moq TO PUBLIC;
DO $$
DECLARE alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); p1 UUID;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (alpha, 'Zz MOQ Tablet', 'Generic', 'Antibiotic', 'TABLET', '10s', 10, 50, true) RETURNING id INTO p1;
  UPDATE public.wholesaler_products SET minimum_order_quantity = 6 WHERE id = p1;
  INSERT INTO zz.moq VALUES (p1);
END $$;

DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.moq), 'quantity', 5)));
  PERFORM zz.check('below minimum order rejected', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('below minimum order rejected', SQLERRM LIKE 'The minimum order%', SQLERRM);
END $$;

DO $$ BEGIN
  PERFORM zz.check('rejected order reserved no stock', (SELECT stock FROM public.products WHERE id = (SELECT pid FROM zz.moq)) = 50);
  PERFORM zz.check('exactly the minimum is accepted', public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.moq), 'quantity', 6))) = 1);
END $$;

DO $$ BEGIN
  PERFORM zz.check('stock reserved for accepted order', (SELECT stock FROM public.products WHERE id = (SELECT pid FROM zz.moq)) = 44);
  UPDATE public.wholesaler_products SET minimum_order_quantity = 1 WHERE id = (SELECT pid FROM zz.moq);
END $$;

DO $$ BEGIN
  PERFORM zz.check('default minimum of 1 still accepts single units', public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pid FROM zz.moq), 'quantity', 1))) = 1);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
