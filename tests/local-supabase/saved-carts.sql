-- Pharmacy saved carts + draft cart: permissions, sync semantics, named carts, limits, tamper protection.
-- Run after setup.sql + migrations (through 20260924230000_pharmacy_saved_carts.sql).
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

INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.u WHERE k='w_cashier'), 'cashier', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), (SELECT id FROM zz.u WHERE k='w_manager'), 'assistant', 'active', now());

CREATE TABLE zz.sc(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.sc TO PUBLIC;

DO $$
DECLARE
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy'); pend UUID := (SELECT id FROM zz.b WHERE name='Pending Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy'); alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_cash UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); u_asst UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_pp UUID := (SELECT id FROM zz.u WHERE k='ph_pending');
  p1 UUID; p2 UUID; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Sc Amox', 'Cat', 'TABLET', '10s', 10, 50, true) RETURNING id INTO p1;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Sc Para', 'Cat', 'TABLET', '10s', 5, 50, true) RETURNING id INTO p2;
  INSERT INTO zz.sc VALUES ('p1', p1), ('p2', p2);

  -- draft cart sync -----------------------------------------------------------------------------
  r := zz.val_as(u_asst, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 2))::text));
  PERFORM zz.check('pharmacy assistant cannot write a draft', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_px, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, '[]'));
  PERFORM zz.check('another pharmacy cannot write my draft', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_pp, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', pend, '[]'));
  PERFORM zz.check('an unapproved pharmacy cannot save a draft', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_cash, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 3), jsonb_build_object('productId', p2, 'quantity', 200000))::text));
  PERFORM zz.check('cashier can sync the draft; quantity is clamped to 100000', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('exactly one draft row exists with 2 items, quantity clamped', (SELECT count(*) FROM public.pharmacy_saved_carts WHERE pharmacy_id = good AND name IS NULL) = 1
    AND (SELECT quantity FROM public.pharmacy_saved_cart_items i JOIN public.pharmacy_saved_carts c ON c.id = i.cart_id WHERE c.pharmacy_id = good AND c.name IS NULL AND i.product_id = p2) = 100000);

  r := zz.val_as(u_po, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 9))::text));
  PERFORM zz.check('owner re-syncing replaces the whole draft (1 item now)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('draft now has exactly 1 item with quantity 9',
    (SELECT count(*) FROM public.pharmacy_saved_cart_items i JOIN public.pharmacy_saved_carts c ON c.id = i.cart_id WHERE c.pharmacy_id = good AND c.name IS NULL) = 1
    AND (SELECT quantity FROM public.pharmacy_saved_cart_items i JOIN public.pharmacy_saved_carts c ON c.id = i.cart_id WHERE c.pharmacy_id = good AND c.name IS NULL) = 9);
  PERFORM zz.check('there is still only one draft row (no duplicates)', (SELECT count(*) FROM public.pharmacy_saved_carts WHERE pharmacy_id = good AND name IS NULL) = 1);

  r := zz.val_as(u_po, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, '[]'));
  PERFORM zz.check('syncing an empty cart deletes the draft row', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('the draft row is gone', (SELECT count(*) FROM public.pharmacy_saved_carts WHERE pharmacy_id = good AND name IS NULL) = 0);

  -- read access -----------------------------------------------------------------------------------
  PERFORM zz.val_as(u_po, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', good, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 4))::text));
  r := zz.val_as(u_asst, format('SELECT count(*)::text FROM public.pharmacy_saved_carts WHERE pharmacy_id = %L AND name IS NULL', good));
  PERFORM zz.check('assistant can read the draft', r = '1', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.pharmacy_saved_carts WHERE pharmacy_id = %L', good));
  PERFORM zz.check('another pharmacy cannot read my draft', r = '0', r);

  -- named saved carts -------------------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', good, '', jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  PERFORM zz.check('a blank name is rejected', r LIKE 'ERR: Enter a name%', r);
  r := zz.val_as(u_po, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', good, 'September Restock', '[]'));
  PERFORM zz.check('an empty cart cannot be saved', r LIKE 'ERR: The cart is empty%', r);
  r := zz.val_as(u_cash, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', good, 'September Restock', jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 5), jsonb_build_object('productId', p2, 'quantity', 20))::text));
  PERFORM zz.check('cashier saves a named cart with 2 items', r NOT LIKE 'ERR%', r);
  INSERT INTO zz.sc VALUES ('cart1', r::uuid);
  r := zz.val_as(u_asst, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', good, 'Other', jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  PERFORM zz.check('assistant cannot save a named cart', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', good, '  september restock  ', jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  PERFORM zz.check('a duplicate name (case/space-insensitive) is rejected', r LIKE 'ERR%', r);
  PERFORM zz.check('saving a NAMED cart does not touch the draft (still 1 item)',
    (SELECT count(*) FROM public.pharmacy_saved_cart_items i JOIN public.pharmacy_saved_carts c ON c.id = i.cart_id WHERE c.pharmacy_id = good AND c.name IS NULL) = 1);

  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.pharmacy_saved_carts WHERE pharmacy_id = %L AND name IS NOT NULL', good));
  PERFORM zz.check('one named saved cart exists', r = '1', r);
  r := zz.val_as(u_px, format('SELECT count(*)::text FROM public.pharmacy_saved_carts WHERE pharmacy_id = %L AND name IS NOT NULL', good));
  PERFORM zz.check('another pharmacy cannot read my saved carts', r = '0', r);

  r := zz.val_as(u_asst, format('SELECT public.can_use_reorder_lists(%L, false)::text', good));
  PERFORM zz.check('sanity: read access helper still allows assistants to read', r = 'true', r);
  r := zz.val_as(u_asst, format('DELETE FROM public.pharmacy_saved_carts WHERE id = %L', (SELECT id FROM zz.sc WHERE k = 'cart1')::text));
  PERFORM zz.check('assistant cannot delete a named cart', r LIKE 'ERR%', r);
  r := zz.val_as(u_px, format('WITH d AS (DELETE FROM public.pharmacy_saved_carts WHERE id = %L RETURNING 1) SELECT count(*)::text FROM d', (SELECT id FROM zz.sc WHERE k = 'cart1')));
  PERFORM zz.check('another pharmacy cannot delete my saved cart (deletes 0 rows)', r = '0', r);
  PERFORM zz.check('...and it is in fact untouched', (SELECT count(*) FROM public.pharmacy_saved_carts WHERE id = (SELECT id FROM zz.sc WHERE k = 'cart1')) = 1);
  r := zz.val_as(u_po, format('WITH d AS (DELETE FROM public.pharmacy_saved_carts WHERE id = %L RETURNING 1) SELECT count(*)::text FROM d', (SELECT id FROM zz.sc WHERE k = 'cart1')));
  PERFORM zz.check('owner can delete their saved cart (deletes 1 row)', r = '1', r);
  PERFORM zz.check('the cart and its items are gone', (SELECT count(*) FROM public.pharmacy_saved_carts WHERE id = (SELECT id FROM zz.sc WHERE k = 'cart1')) = 0
    AND (SELECT count(*) FROM public.pharmacy_saved_cart_items WHERE cart_id = (SELECT id FROM zz.sc WHERE k = 'cart1')) = 0);

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.pharmacy_saved_carts;
    RESET ROLE;
    PERFORM zz.check('anon cannot read saved carts', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read saved carts', TRUE, SQLERRM);
  END;
END $$;

-- limits ------------------------------------------------------------------------------------------
DO $$
DECLARE
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy'); u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other'); p1 UUID := (SELECT id FROM zz.sc WHERE k='p1');
  r TEXT; i INT;
BEGIN
  FOR i IN 1..30 LOOP
    PERFORM zz.val_as(u_px, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', otherp, 'Cart ' || i, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  END LOOP;
  r := zz.val_as(u_px, format('SELECT public.create_saved_cart(%L, %L, %L::jsonb)::text', otherp, 'Cart 31', jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  PERFORM zz.check('the 31st named cart is rejected', r LIKE 'ERR: A pharmacy can have at most 30%', r);
  -- the draft is not counted towards the 30-cart limit
  r := zz.val_as(u_px, format('SELECT public.save_draft_cart(%L, %L::jsonb)::text', otherp, jsonb_build_array(jsonb_build_object('productId', p1, 'quantity', 1))::text));
  PERFORM zz.check('the draft still syncs fine even with 30 named carts', r NOT LIKE 'ERR%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
