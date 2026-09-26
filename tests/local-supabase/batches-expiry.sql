-- Batch + expiry tracking: receiving, permissions, FEFO picks, allocation/release, write-offs, audit.
-- Run after setup.sql + migrations (through 20260924170000_batches_and_expiry.sql).
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
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now());

CREATE TABLE zz.bx(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.bx TO PUBLIC;

-- 1. receiving --------------------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  p UUID; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Bx Amox', 'Cat', 'TABLET', '10s', 10, 20, true) RETURNING id INTO p;
  INSERT INTO zz.bx VALUES ('p', p);

  r := zz.val_as(u_wc, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 10)::text', p));
  PERFORM zz.check('cashier cannot receive stock', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wa, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 10)::text', p));
  PERFORM zz.check('assistant cannot receive stock', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wx, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 10)::text', p));
  PERFORM zz.check('another wholesaler cannot receive stock', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 10)::text', p));
  PERFORM zz.check('a pharmacy cannot receive stock', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''B1'', current_date - 1, 10)::text', p));
  PERFORM zz.check('an already expired batch cannot be received', r LIKE 'ERR: This batch has already expired%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 0)::text', p));
  PERFORM zz.check('quantity 0 rejected', r LIKE 'ERR: Enter a quantity%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''  '', current_date + 40, 5)::text', p));
  PERFORM zz.check('blank batch number rejected', r LIKE 'ERR: Enter a batch number%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 4000, 5)::text', p));
  PERFORM zz.check('an expiry more than 10 years away is rejected', r LIKE 'ERR: The expiry date is more than 10 years%', r);
  PERFORM zz.check('stock untouched by the failed attempts', (SELECT stock FROM public.products WHERE id = p) = 20);

  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''B1'', current_date + 40, 10)::text', p));
  PERFORM zz.check('manager receives B1 (10 units, +40 days)', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.receive_product_batch(%L, ''B2'', current_date + 200, 15)::text', p));
  PERFORM zz.check('owner receives B2 (15 units, +200 days)', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''B0'', current_date + 10, 5)::text', p));
  PERFORM zz.check('manager receives B0 (5 units, +10 days)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('receiving adds to sellable stock: 20 + 10 + 15 + 5 = 50', (SELECT stock FROM public.products WHERE id = p) = 50);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''b1'', current_date + 41, 3)::text', p));
  PERFORM zz.check('same batch number with a different expiry is rejected', r LIKE 'ERR: Batch b1 already exists%', r);
  r := zz.val_as(u_wm, format('SELECT public.receive_product_batch(%L, ''b1'', current_date + 40, 3)::text', p));
  PERFORM zz.check('same batch number and expiry adds to the batch', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('batch B1 now holds 13 and stock is 53',
    (SELECT quantity_on_hand FROM public.product_batches WHERE lower(batch_number) = 'b1') = 13 AND (SELECT stock FROM public.products WHERE id = p) = 53);
  PERFORM zz.check('no duplicate batch row was created', (SELECT count(*) FROM public.product_batches WHERE product_id = p) = 3);
END $$;

-- 2. listing and buckets ------------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); p UUID := (SELECT id FROM zz.bx WHERE k='p');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1'; u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  r TEXT;
BEGIN
  INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
  VALUES (p, alpha, 'OLD', current_date - 5, 4, 4);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_product_batches(%L)', alpha));
  PERFORM zz.check('cashier can list batches (4 with stock)', r = '4', r);
  r := zz.val_as(u_wc, format('SELECT summary_expired || ''/'' || summary_within_30 || ''/'' || summary_within_60 || ''/'' || summary_within_90 || ''/'' || summary_units_at_risk FROM public.list_product_batches(%L, NULL, NULL, 1, 0)', alpha));
  PERFORM zz.check('summary: 1 expired, 1 within 30, 1 within 60, 0 within 90, 4+5+13=22 units at risk', r = '1/1/1/0/22', r);
  r := zz.val_as(u_wc, format('SELECT batch_number FROM public.list_product_batches(%L) LIMIT 1', alpha));
  PERFORM zz.check('earliest expiry first (the expired one)', r = 'OLD', r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_product_batches(%L, ''within_30'')', alpha));
  PERFORM zz.check('filter within_30 returns B0', r = '1', r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_product_batches(%L, NULL, ''b2'')', alpha));
  PERFORM zz.check('search by batch number', r = '1', r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_product_batches(%L, NULL, ''%%'')', alpha));
  PERFORM zz.check('search treats % literally', r = '0', r);
  r := zz.val_as(u_wc, format('SELECT total_count::text FROM public.list_product_batches(%L, NULL, NULL, 1, 0)', alpha));
  PERFORM zz.check('paging keeps the total', r = '4', r);
  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_product_batches(%L, ''bogus'')', alpha));
  PERFORM zz.check('unknown filter rejected', r LIKE 'ERR%', r);
  r := zz.val_as(u_wa, format('SELECT count(*)::text FROM public.list_product_batches(%L)', alpha));
  PERFORM zz.check('assistant cannot list batches', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.list_product_batches(%L)', alpha));
  PERFORM zz.check('another wholesaler cannot list my batches', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.list_product_batches(%L)', alpha));
  PERFORM zz.check('a pharmacy cannot list batches', r LIKE 'ERR%', r);
  r := zz.val_as(u_wc, 'SELECT count(*)::text FROM public.product_batches');
  PERFORM zz.check('direct table read is hidden by RLS', r = '0', r);
END $$;

-- 3. FEFO picks, confirm, release ----------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  p UUID := (SELECT id FROM zz.bx WHERE k='p');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); u_wa UUID := '10000000-0000-0000-0000-0000000000a1'; u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  o UUID; o_big UUID; o_pend UUID; r TEXT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'accepted', 120, 120, 0, 'unpaid', 'cod') RETURNING id INTO o;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o, p, 'Bx Amox', 10, 12);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'accepted', 1000, 1000, 0, 'unpaid', 'cod') RETURNING id INTO o_big;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_big, p, 'Bx Amox', 10, 100);
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method) VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_pend;
  INSERT INTO public.order_items(order_id, product_id, product_name, unit_price_ghs, quantity) VALUES (o_pend, p, 'Bx Amox', 10, 1);
  INSERT INTO zz.bx VALUES ('o', o), ('o_big', o_big), ('o_pend', o_pend);

  r := zz.val_as(u_wc, format('SELECT (SELECT string_agg(x->>''batch_number'' || ''x'' || (x->>''quantity''), '','') FROM jsonb_array_elements(picks) x) || ''/'' || shortfall FROM public.suggest_order_picks(%L)', o));
  PERFORM zz.check('FEFO for 12 units: 5 from B0 then 7 from B1, expired batch skipped, no shortfall', r = 'B0x5,B1x7/0', r);
  r := zz.val_as(u_wc, format('SELECT shortfall::text FROM public.suggest_order_picks(%L)', o_big));
  PERFORM zz.check('100 units needed but only 5+13+15=33 in date: shortfall 67', r = '67', r);
  r := zz.val_as(u_wa, format('SELECT count(*)::text FROM public.suggest_order_picks(%L)', o));
  PERFORM zz.check('assistant cannot see picks', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.suggest_order_picks(%L)', o));
  PERFORM zz.check('another wholesaler cannot see picks', r LIKE 'ERR%', r);
  PERFORM zz.check('suggesting does not change batch quantities', (SELECT quantity_on_hand FROM public.product_batches WHERE batch_number = 'B0') = 5);

  r := zz.val_as(u_wc, format('SELECT public.confirm_order_picks(%L)::text', o_pend));
  PERFORM zz.check('picks cannot be confirmed for a pending order', r LIKE 'ERR: Batches can only be confirmed%', r);
  r := zz.val_as(u_wa, format('SELECT public.confirm_order_picks(%L)::text', o));
  PERFORM zz.check('assistant cannot confirm picks', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wc, format('SELECT public.confirm_order_picks(%L)::text', o));
  PERFORM zz.check('cashier confirms picks for the 12-unit order', r LIKE '%"units_allocated": 12%' AND r LIKE '%"units_not_batched": 0%', r);
  PERFORM zz.check('B0 emptied and B1 reduced to 6', (SELECT quantity_on_hand FROM public.product_batches WHERE batch_number = 'B0') = 0 AND (SELECT quantity_on_hand FROM public.product_batches WHERE lower(batch_number) = 'b1') = 6);
  PERFORM zz.check('two allocation rows recorded for traceability', (SELECT count(*) FROM public.order_batch_allocations WHERE order_id = o) = 2);
  PERFORM zz.check('products.stock is not touched by allocation (still 53)', (SELECT stock FROM public.products WHERE id = p) = 53);
  r := zz.val_as(u_wc, format('SELECT allocated::text || ''/'' || shortfall FROM public.suggest_order_picks(%L)', o));
  PERFORM zz.check('the picks now show as allocated', r = 'true/0', r);
  r := zz.val_as(u_wc, format('SELECT public.confirm_order_picks(%L)::text', o));
  PERFORM zz.check('confirming again is idempotent (re-allocates the same units)', r LIKE '%"units_allocated": 12%', r);
  PERFORM zz.check('quantities are unchanged after the repeat', (SELECT quantity_on_hand FROM public.product_batches WHERE lower(batch_number) = 'b1') = 6 AND (SELECT count(*) FROM public.order_batch_allocations WHERE order_id = o) = 2);
  r := zz.val_as(u_wc, format('SELECT public.confirm_order_picks(%L)::text', o_big));
  PERFORM zz.check('a big order allocates what exists and reports what is not batched',
    r LIKE '%"units_not_batched": 79%', r);

  UPDATE public.orders SET status = 'cancelled' WHERE id = o;
  PERFORM zz.check('cancelling the 12-unit order returns 5 to B0 and 7 to B1 (B1 was 0 after the big order took its 6)',
    (SELECT quantity_on_hand FROM public.product_batches WHERE batch_number = 'B0') = 5
    AND (SELECT quantity_on_hand FROM public.product_batches WHERE lower(batch_number) = 'b1') = 7);
  UPDATE public.orders SET status = 'cancelled' WHERE id = o_big;
  PERFORM zz.check('after cancelling both orders every batch is back to its full quantity',
    (SELECT quantity_on_hand FROM public.product_batches WHERE batch_number = 'B0') = 5
    AND (SELECT quantity_on_hand FROM public.product_batches WHERE lower(batch_number) = 'b1') = 13
    AND (SELECT quantity_on_hand FROM public.product_batches WHERE batch_number = 'B2') = 15
    AND (SELECT count(*) FROM public.order_batch_allocations) = 0);
END $$;

-- 4. write-offs and audit -------------------------------------------------------------------------
DO $$
DECLARE
  p UUID := (SELECT id FROM zz.bx WHERE k='p'); b2 UUID; old UUID; s0 INTEGER;
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier'); r TEXT;
BEGIN
  SELECT stock INTO s0 FROM public.products WHERE id = p;
  SELECT id INTO b2 FROM public.product_batches WHERE batch_number = 'B2';
  SELECT id INTO old FROM public.product_batches WHERE batch_number = 'OLD';
  r := zz.val_as(u_wc, format('SELECT public.write_off_batch(%L, 2, ''damaged'', NULL)::text', b2));
  PERFORM zz.check('cashier cannot write off', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wm, format('SELECT public.write_off_batch(%L, 2, ''theft'', NULL)::text', b2));
  PERFORM zz.check('unknown write-off reason rejected', r LIKE 'ERR: Choose a write-off reason%', r);
  r := zz.val_as(u_wm, format('SELECT public.write_off_batch(%L, 99, ''damaged'', NULL)::text', b2));
  PERFORM zz.check('cannot write off more than is on hand', r LIKE 'ERR: Enter a quantity between 1 and 15%', r);
  r := zz.val_as(u_wm, format('SELECT public.write_off_batch(%L, 2, ''damaged'', ''Water damage'')::text', b2));
  PERFORM zz.check('manager writes off 2 damaged units', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('batch 13 and stock reduced by 2', (SELECT quantity_on_hand FROM public.product_batches WHERE id = b2) = 13 AND (SELECT stock FROM public.products WHERE id = p) = s0 - 2);
  r := zz.val_as(u_wm, format('SELECT public.write_off_batch(%L, 4, ''expired'', NULL)::text', old));
  PERFORM zz.check('the expired batch can be written off', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('expired batch emptied and stock reduced by 4 more', (SELECT quantity_on_hand FROM public.product_batches WHERE id = old) = 0 AND (SELECT stock FROM public.products WHERE id = p) = s0 - 6);
  r := zz.val_as(u_wm, format('SELECT count(*)::text FROM public.list_product_batches((SELECT id FROM zz.b WHERE name=''Alpha Wholesale''), ''depleted'')', NULL));
  PERFORM zz.check('the emptied batch appears under depleted', r = '1', r);
  PERFORM zz.check('write-offs are recorded in the movement ledger', (SELECT count(*) FROM public.batch_movements WHERE kind = 'write_off') = 2);
  PERFORM zz.check('audit log covers receive, allocate and write-off',
    (SELECT count(DISTINCT activity) FROM public.audit_logs WHERE activity IN ('Batch received', 'Batches allocated', 'Batch written off')) = 3);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.list_product_batches((SELECT id FROM zz.b WHERE name='Alpha Wholesale'));
    RESET ROLE;
    PERFORM zz.check('anon cannot list batches', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot list batches', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
