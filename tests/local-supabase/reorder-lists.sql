-- Reorder lists: RLS, constraints, limits and the get_order_reorder_lines RPC on the real schema.
-- Run after setup.sql (fixtures) and the migration 20260924100000_pharmacy_reorder_lists.sql.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  pend  UUID := (SELECT id FROM zz.b WHERE name='Pending Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_pp UUID := (SELECT id FROM zz.u WHERE k='ph_pending');
  u_cash UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_asst UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  p1 UUID; p2 UUID; m1 UUID; m2 UUID; o1 UUID; l1 UUID;
  n BIGINT; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (alpha, 'Amoxicillin 500mg', 'Generic', 'Antibiotic', 'CAPSULE', '10s', 10.00, 40, true) RETURNING id INTO p1;
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (alpha, 'Paracetamol 500mg', 'Generic', 'Analgesic', 'TABLET', '20s', 5.00, 30, true) RETURNING id INTO p2;
  SELECT product_id INTO m1 FROM public.wholesaler_products WHERE id = p1;
  SELECT product_id INTO m2 FROM public.wholesaler_products WHERE id = p2;
  PERFORM zz.check('fixture: master products exist', m1 IS NOT NULL AND m2 IS NOT NULL AND m1 <> m2);

  INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
    (good, u_cash, 'cashier', 'active', now()), (good, u_asst, 'assistant', 'active', now());

  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
  VALUES (good, alpha, 'delivered', 100, 100, 0, 'paid', 'cod') RETURNING id INTO o1;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o1, p1, 'Amoxicillin 500mg', 10, 10);

  r := zz.run_as(u_po, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,''Monthly'',%L)', good, u_po));
  PERFORM zz.check('owner can create list', r='OK', r);
  SELECT id INTO l1 FROM public.reorder_lists WHERE pharmacy_id=good AND name='Monthly';
  r := zz.run_as(u_po, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,'' monthly '',%L)', good, u_po));
  PERFORM zz.check('duplicate name (case/space-insensitive) rejected', r LIKE 'ERR%', r);
  r := zz.run_as(u_po, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,'''',%L)', good, u_po));
  PERFORM zz.check('empty name rejected', r LIKE 'ERR%', r);
  r := zz.run_as(u_po, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,''Spoof'',%L)', good, u_px));
  PERFORM zz.check('created_by must be the caller', r LIKE 'ERR%', r);

  n := zz.count_as(u_px, 'SELECT id FROM public.reorder_lists');
  PERFORM zz.check('other pharmacy sees no lists', n=0, n::text);
  r := zz.run_as(u_px, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,''Hack'',%L)', good, u_px));
  PERFORM zz.check('other pharmacy cannot insert into my pharmacy', r LIKE 'ERR%', r);
  n := zz.count_as(u_nb, 'SELECT id FROM public.reorder_lists');
  PERFORM zz.check('unrelated user sees no lists', n=0, n::text);

  r := zz.run_as(u_pp, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,''Pend'',%L)', pend, u_pp));
  PERFORM zz.check('unapproved pharmacy cannot create list', r LIKE 'ERR%', r);

  n := zz.count_as(u_cash, 'SELECT id FROM public.reorder_lists');
  PERFORM zz.check('cashier can read list', n=1, n::text);
  r := zz.run_as(u_cash, format('INSERT INTO public.reorder_list_items(list_id,master_product_id,name_snapshot,quantity) VALUES (%L,%L,''Amox'',5)', l1, m1));
  PERFORM zz.check('cashier can add item', r='OK', r);
  n := zz.count_as(u_asst, 'SELECT id FROM public.reorder_lists');
  PERFORM zz.check('assistant can read list', n=1, n::text);
  r := zz.run_as(u_asst, format('INSERT INTO public.reorder_list_items(list_id,master_product_id,name_snapshot,quantity) VALUES (%L,%L,''X'',1)', l1, m2));
  PERFORM zz.check('assistant cannot add item', r LIKE 'ERR%', r);
  r := zz.run_as(u_asst, format('INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (%L,''A'',%L)', good, u_asst));
  PERFORM zz.check('assistant cannot create list', r LIKE 'ERR%', r);

  r := zz.run_as(u_po, format('INSERT INTO public.reorder_list_items(list_id,master_product_id,name_snapshot,quantity) VALUES (%L,%L,''Amox'',5)', l1, m1));
  PERFORM zz.check('duplicate master product in list rejected', r LIKE 'ERR%', r);
  r := zz.run_as(u_po, format('INSERT INTO public.reorder_list_items(list_id,master_product_id,name_snapshot,quantity) VALUES (%L,%L,''Y'',0)', l1, m2));
  PERFORM zz.check('quantity 0 rejected', r LIKE 'ERR%', r);
  r := zz.run_as(u_po, format('INSERT INTO public.reorder_list_items(list_id,master_product_id,name_snapshot,quantity) VALUES (%L,%L,''Y'',100001)', l1, m2));
  PERFORM zz.check('quantity over 100000 rejected', r LIKE 'ERR%', r);
  r := zz.run_as(u_po, format('UPDATE public.reorder_list_items SET quantity=12, preferred_wholesaler_id=%L WHERE list_id=%L', alpha, l1));
  PERFORM zz.check('owner can update quantity and preferred supplier', r='OK', r);
  r := zz.run_as(u_px, format('UPDATE public.reorder_list_items SET quantity=99 WHERE list_id=%L', l1));
  n := (SELECT quantity FROM public.reorder_list_items WHERE list_id=l1);
  PERFORM zz.check('other pharmacy cannot update my item', n=12, n::text);
  n := zz.count_as(u_px, format('SELECT id FROM public.reorder_list_items WHERE list_id=%L', l1));
  PERFORM zz.check('other pharmacy cannot read my items', n=0, n::text);

  FOR i IN 1..50 LOOP
    INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (otherp, 'L'||i, u_px);
  END LOOP;
  BEGIN
    INSERT INTO public.reorder_lists(pharmacy_id,name,created_by) VALUES (otherp, 'L51', u_px);
    PERFORM zz.check('51st list rejected', FALSE);
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('51st list rejected', TRUE, SQLERRM);
  END;

  n := zz.count_as(u_po, format('SELECT * FROM public.get_order_reorder_lines(%L)', o1));
  PERFORM zz.check('owner: rpc returns the order line', n=1, n::text);
  n := zz.count_as(u_px, format('SELECT * FROM public.get_order_reorder_lines(%L)', o1));
  PERFORM zz.check('other pharmacy gets no lines for my order', n<=0, n::text);
  n := zz.count_as(u_asst, format('SELECT * FROM public.get_order_reorder_lines(%L)', o1));
  PERFORM zz.check('assistant can read order lines', n=1, n::text);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.get_order_reorder_lines(o1);
    RESET ROLE;
    PERFORM zz.check('anon cannot execute rpc', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot execute rpc', TRUE, SQLERRM);
  END;

  r := zz.run_as(u_po, format('DELETE FROM public.reorder_lists WHERE id=%L', l1));
  n := (SELECT count(*) FROM public.reorder_list_items WHERE list_id=l1);
  PERFORM zz.check('deleting a list removes its items', r='OK' AND n=0, r || ' ' || n);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
