-- Expiry sales guard: expired batch units must not be sold (modes off / observe / enforce).
-- Run in an isolated local database after setup.sql, the production stock fixtures and migrations through 20261209100000_expiry_sales_guard.sql.
-- Checkout creates a session temp table that lives until commit, so every SUCCESSFUL checkout or quote is its own top-level statement; refused ones are wrapped in a function
-- (a failed call rolls its own temp table back). Product names are unique to this suite.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE OR REPLACE FUNCTION zz.gv_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;
-- Set the guard mode the way an administrator does.
CREATE OR REPLACE FUNCTION zz.gmode(p_mode TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), format('SELECT public.admin_set_expiry_guard_mode(%L, ''Test the expiry guard'')', p_mode)) $$;
-- Run a statement as the database owner and report OK or the message (for things only the owner can attempt).
CREATE OR REPLACE FUNCTION zz.gtry(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'OK'; EXCEPTION WHEN OTHERS THEN RETURN 'ERR: ' || SQLERRM; END $$;
-- A checkout through the real service path. Returns OK or the message.
CREATE OR REPLACE FUNCTION zz.gorder(p_product TEXT, p_qty INT) RETURNS TEXT LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k = 'ph_owner'), (SELECT id FROM zz.b WHERE name = 'Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM public.products WHERE name = p_product), 'quantity', p_qty)));
  RETURN 'OK';
EXCEPTION WHEN OTHERS THEN RETURN 'ERR: ' || SQLERRM;
END $$;
-- A product with batches: p_expired units in an expired batch, p_good in a batch that is fine, p_loose units in no batch; stock is the sum.
CREATE OR REPLACE FUNCTION zz.gprod(p_name TEXT, p_expired INT, p_good INT, p_loose INT, p_expired_days INT DEFAULT -5) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_alpha UUID := (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale');
BEGIN
  INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
  VALUES (v_alpha, p_name, 'Generic', 'Antibiotic', 'TABLET', '10s', 10, p_expired + p_good + p_loose, true) RETURNING id INTO v_id;
  IF p_expired > 0 THEN
    INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
    VALUES (v_id, v_alpha, 'OLD', current_date + p_expired_days, p_expired, p_expired);
  END IF;
  IF p_good > 0 THEN
    INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
    VALUES (v_id, v_alpha, 'NEW', current_date + 200, p_good, p_good);
  END IF;
  RETURN v_id;
END $$;
CREATE OR REPLACE FUNCTION zz.gstock(p_name TEXT) RETURNS INT LANGUAGE sql AS $$ SELECT stock FROM public.products WHERE name = p_name $$;
CREATE OR REPLACE FUNCTION zz.gevents(p_name TEXT) RETURNS INT LANGUAGE sql AS $$ SELECT count(*)::int FROM public.expiry_guard_events WHERE product_name = p_name $$;
CREATE OR REPLACE FUNCTION zz.gorders(p_name TEXT) RETURNS INT LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.order_items oi JOIN public.products p ON p.id = oi.product_id WHERE p.name = p_name $$;

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 0. the starting point
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.check('the guard starts in observe mode: it records and blocks nothing', public.expiry_guard_mode() = 'observe');
SELECT zz.check('all four selling functions carry exactly one guard call',
  (SELECT count(*) FROM pg_proc WHERE proname IN ('create_marketplace_orders', 'award_rfq_quote', 'award_rfq_lines', 'advance_backorder_shipment')
     AND (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1) = 4);

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 1. observe: the sale goes through, and the guard writes down that it would have refused it
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.gprod('Guard A', 8, 12, 0);
SELECT zz.gorder('Guard A', 15) AS observe_order;
SELECT zz.check('observe: an order that needs expired units is NOT blocked', zz.gorders('Guard A') = 1 AND zz.gstock('Guard A') = 5);
SELECT zz.check('observe: it is recorded with what the guard saw',
  (SELECT count(*) = 1 AND bool_and(entry_point = 'checkout' AND quantity = 15 AND stock = 20 AND expired_units = 8 AND sellable = 12 AND wholesaler_id = (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale')
                                  AND actor_id = (SELECT id FROM zz.u WHERE k = 'ph_owner')) FROM public.expiry_guard_events WHERE product_name = 'Guard A'));

SELECT zz.gprod('Guard A2', 8, 12, 0);
SELECT zz.gorder('Guard A2', 12) AS observe_order_within_sellable;
SELECT zz.check('observe: an order the good units can cover is not even recorded', zz.gorders('Guard A2') = 1 AND zz.gevents('Guard A2') = 0);

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 2. enforce: refused with a reason, nothing changes; what the good units can cover still sells
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.gmode('enforce') AS switched;
SELECT zz.check('an administrator can switch the guard to enforce', public.expiry_guard_mode() = 'enforce');
SELECT zz.gprod('Guard B', 8, 12, 0);
SELECT zz.check('enforce: more than the unexpired units is refused, and says why',
  zz.gorder('Guard B', 13) = 'ERR: Only 12 unit(s) of Guard B can be sold: 8 unit(s) are past their expiry date.');
SELECT zz.check('enforce: a refused order leaves stock, orders and the record untouched', zz.gstock('Guard B') = 20 AND zz.gorders('Guard B') = 0 AND zz.gevents('Guard B') = 0);
SELECT zz.gorder('Guard B', 12) AS enforce_order_within_sellable;
SELECT zz.check('enforce: exactly what the unexpired units cover can be sold', zz.gorders('Guard B') = 1 AND zz.gstock('Guard B') = 8);
SELECT zz.check('enforce: what remains is only expired units, so nothing more can be sold',
  zz.gorder('Guard B', 1) = 'ERR: Guard B cannot be sold right now: its remaining 8 unit(s) are past their expiry date.');

SELECT zz.gprod('Guard C', 0, 0, 10);
SELECT zz.gorder('Guard C', 10) AS unbatched_order;
SELECT zz.check('a product with no batches is exactly as before: all of its stock sells', zz.gorders('Guard C') = 1 AND zz.gstock('Guard C') = 0);

SELECT zz.gprod('Guard D', 20, 0, 10);
SELECT zz.check('unbatched units stay sellable next to an expired batch: one too many is refused',
  zz.gorder('Guard D', 11) = 'ERR: Only 10 unit(s) of Guard D can be sold: 20 unit(s) are past their expiry date.');
SELECT zz.gorder('Guard D', 10) AS mixed_order;
SELECT zz.check('...and all ten unbatched units can be sold', zz.gorders('Guard D') = 1 AND zz.gstock('Guard D') = 20);

-- the ordinary out-of-stock message still wins when stock is already zero
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'Guard E', 'Generic', 'Antibiotic', 'TABLET', '10s', 10, 0, true FROM zz.b WHERE name = 'Alpha Wholesale';
INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand)
SELECT p.id, p.wholesaler_id, 'OLD', current_date - 3, 5, 5 FROM public.products p WHERE p.name = 'Guard E';
SELECT zz.check('zero stock keeps the ordinary message', zz.gorder('Guard E', 1) = 'ERR: Guard E is currently out of stock.');

-- the expiry date itself
SELECT zz.gprod('Guard F1', 10, 0, 0, 0);
SELECT zz.gorder('Guard F1', 10) AS order_on_expiry_day;
SELECT zz.check('a batch is still good ON its expiry date', zz.gorders('Guard F1') = 1);
SELECT zz.gprod('Guard F2', 10, 0, 0, -1);
SELECT zz.check('the day after, it is not', zz.gorder('Guard F2', 1) LIKE 'ERR: Guard F2 cannot be sold right now%' AND zz.gorders('Guard F2') = 0);

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 3. what the screens read
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.gprod('Guard G', 8, 12, 0);
SELECT zz.check('enforce: a buyer is shown the sellable number',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT public.available_stock(p)::text FROM public.products p WHERE p.name = 'Guard G'$q$) = '12');
SELECT zz.check('enforce: the storefront catalogue reports the sellable number as each offer''s stock',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT o ->> 'stock' FROM jsonb_array_elements(public.list_marketplace_catalogue()) m, jsonb_array_elements(m -> 'offers') o WHERE o ->> 'name' = 'Guard G'$q$) = '12');
SELECT zz.check('...and zero when only expired units are left',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT o ->> 'stock' FROM jsonb_array_elements(public.list_marketplace_catalogue()) m, jsonb_array_elements(m -> 'offers') o WHERE o ->> 'name' = 'Guard A'$q$) = '0');
SELECT zz.check('the rest of the catalogue offer is unchanged (price, minimum order, wholesaler)',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT (o ->> 'price_ghs') || '/' || (o ->> 'minimum_order_quantity') || '/' || (o -> 'wholesaler' ->> 'name') FROM jsonb_array_elements(public.list_marketplace_catalogue()) m, jsonb_array_elements(m -> 'offers') o WHERE o ->> 'name' = 'Guard G'$q$) LIKE '10%/1/Alpha Wholesale');
SELECT zz.check('the product''s own staff are told how many are expired',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'), $q$SELECT public.expired_stock(p)::text FROM public.products p WHERE p.name = 'Guard G'$q$) = '8');
SELECT zz.check('an administrator is too',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), $q$SELECT public.expired_stock(p)::text FROM public.products p WHERE p.name = 'Guard G'$q$) = '8');
SELECT zz.check('a buyer is NOT told how many are expired',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT coalesce(public.expired_stock(p)::text, 'hidden') FROM public.products p WHERE p.name = 'Guard G'$q$) = 'hidden');
SELECT zz.check('another wholesaler is not told either',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_other'), $q$SELECT coalesce(public.expired_stock(p)::text, 'hidden') FROM public.products p WHERE p.name = 'Guard G'$q$) = 'hidden');
SELECT zz.check('signed-out visitors cannot call either',
  NOT has_function_privilege('anon', 'public.available_stock(public.products)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.expired_stock(public.products)', 'EXECUTE'));
SELECT zz.check('the internal helpers are not callable by users',
  NOT has_function_privilege('authenticated', 'public.expired_units_on_hand(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public._expiry_guard(uuid,integer,integer,text,text,uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.expiry_guard_mode()', 'EXECUTE'));

-- writing off the expired units changes nothing a buyer can order
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'),
  format($q$SELECT public.write_off_batch(%L, 8, 'expired', NULL)::text$q$, (SELECT b.id FROM public.product_batches b JOIN public.products p ON p.id = b.product_id WHERE p.name = 'Guard G' AND b.batch_number = 'OLD'))) AS write_off;
SELECT zz.check('writing off the expired units lowers stock but not what can be sold',
  zz.gstock('Guard G') = 12
  AND zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT public.available_stock(p)::text FROM public.products p WHERE p.name = 'Guard G'$q$) = '12');

SELECT zz.gmode('observe');
SELECT zz.check('observe: the catalogue reports the plain stock too',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT o ->> 'stock' FROM jsonb_array_elements(public.list_marketplace_catalogue()) m, jsonb_array_elements(m -> 'offers') o WHERE o ->> 'name' = 'Guard A'$q$) = '5');
SELECT zz.check('observe: the storefront number is the plain stock, so nothing changes on screen until you enforce',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT public.available_stock(p)::text FROM public.products p WHERE p.name = 'Guard A'$q$) = zz.gstock('Guard A')::text);

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 4. off
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.gmode('off');
SELECT zz.gprod('Guard H', 8, 12, 0);
SELECT zz.gorder('Guard H', 15) AS off_order;
SELECT zz.check('off: nothing is checked and nothing is recorded', zz.gorders('Guard H') = 1 AND zz.gevents('Guard H') = 0);
SELECT zz.gmode('observe');

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 5. administrator controls and the record
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.check('a pharmacy owner cannot change the mode', zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), $q$SELECT public.admin_set_expiry_guard_mode('off', 'I would rather not')$q$) = 'ERR: Administrators only.');
SELECT zz.check('a wholesaler owner cannot change the mode', zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'), $q$SELECT public.admin_set_expiry_guard_mode('off', 'I would rather not')$q$) = 'ERR: Administrators only.');
SELECT zz.check('a mode must be one of the three',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), $q$SELECT public.admin_set_expiry_guard_mode('strict', 'Try a made-up mode')$q$) = 'ERR: Choose off, observe or enforce.');
SELECT zz.check('a reason is needed',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), $q$SELECT public.admin_set_expiry_guard_mode('enforce', 'no')$q$) = 'ERR: Give a reason of at least 5 characters.');
SELECT zz.check('the mode did not move after those refusals', public.expiry_guard_mode() = 'observe');
SELECT zz.check('every change is in the audit log with who, what and why',
  (SELECT count(*) >= 4 FROM public.audit_logs WHERE activity = 'Expiry guard mode changed')
  AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Expiry guard mode changed' AND details ->> 'previous' = 'off' AND details ->> 'new' = 'observe' AND details ->> 'reason' = 'Test the expiry guard'));

SELECT zz.check('the status shows the mode, the counts and the most recent would-be blocks',
  (SELECT (s ->> 'mode') = 'observe' AND (s ->> 'would_have_blocked_7_days')::int >= 1 AND jsonb_array_length(s -> 'events') >= 1
          AND (s ->> 'expired_units')::int >= 8 AND (s -> 'events' -> 0 ->> 'wholesaler_name') IS NOT NULL
   FROM (SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), 'SELECT public.admin_expiry_guard_status(5)::text')::jsonb AS s) x));
SELECT zz.check('the status is for administrators only', zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), 'SELECT public.admin_expiry_guard_status()::text') = 'ERR: Administrators only.');
SELECT zz.check('the record cannot be edited', zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), $q$UPDATE public.expiry_guard_events SET quantity = 1 RETURNING 'x'$q$) LIKE 'ERR:%'
  AND (SELECT count(*) FROM public.expiry_guard_events WHERE quantity = 1) = 0);
SELECT zz.check('even the database owner cannot edit or delete the record',
  zz.gtry('DELETE FROM public.expiry_guard_events') = 'ERR: Expiry guard events cannot be changed or deleted.'
  AND zz.gtry('UPDATE public.expiry_guard_events SET quantity = quantity') = 'ERR: Expiry guard events cannot be changed or deleted.');
SELECT zz.check('the record is readable by administrators only',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), 'SELECT count(*)::text FROM public.expiry_guard_events') = '0'
  AND zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'), 'SELECT count(*)::text FROM public.expiry_guard_events') = '0'
  AND zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), 'SELECT count(*)::text FROM public.expiry_guard_events')::int >= 1);
SELECT zz.check('nobody can write the policy directly',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'admin'), $q$UPDATE public.expiry_guard_policy SET mode = 'off' RETURNING 'x'$q$) LIKE 'ERR:%' AND public.expiry_guard_mode() = 'observe');

-- the guard called directly, once for each place that sells stock
SELECT public._expiry_guard((SELECT id FROM public.products WHERE name = 'Guard A2'), 20, 15, 'Guard A2', 'rfq_award', NULL);
SELECT public._expiry_guard((SELECT id FROM public.products WHERE name = 'Guard A2'), 20, 15, 'Guard A2', 'backorder_shipment', NULL);
SELECT zz.check('each entry point is recorded under its own name',
  (SELECT array_agg(entry_point ORDER BY entry_point) FROM public.expiry_guard_events WHERE product_name = 'Guard A2') = ARRAY['backorder_shipment', 'rfq_award']);
SELECT zz.check('an unknown entry point is refused',
  zz.gtry($q$SELECT public._expiry_guard((SELECT id FROM public.products WHERE name = 'Guard A2'), 20, 15, 'Guard A2', 'somewhere_else', NULL)$q$) LIKE 'ERR: new row%violates check constraint%');

------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 6. RFQ awards: the same rule, by whole quote and by line
------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.gprod('Guard RFQ Q', 20, 5, 0);
SELECT zz.gprod('Guard RFQ L', 20, 5, 0);
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format($q$SELECT public.create_rfq(%L, 'Guard Award Q', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
  (SELECT id FROM zz.b WHERE name = 'Good Pharmacy'), (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'), '[{"productName":"Guard RFQ Q","quantity":10}]'::jsonb)) AS rfq_q;
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format($q$SELECT public.create_rfq(%L, 'Guard Award L', NULL, NULL, ARRAY[%L]::uuid[], %L)::text$q$,
  (SELECT id FROM zz.b WHERE name = 'Good Pharmacy'), (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'), '[{"productName":"Guard RFQ L","quantity":10}]'::jsonb)) AS rfq_l;
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'), format($q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q'), (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q')),
    'productId', (SELECT id FROM public.products WHERE name = 'Guard RFQ Q'), 'unitPriceGhs', 10.00)))) AS quote_q;
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'w_owner'), format($q$SELECT public.submit_rfq_quote(%L, %L, %L)::text$q$,
  (SELECT id FROM public.rfqs WHERE title = 'Guard Award L'), (SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'),
  jsonb_build_array(jsonb_build_object('rfqItemId', (SELECT id FROM public.rfq_items WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award L')),
    'productId', (SELECT id FROM public.products WHERE name = 'Guard RFQ L'), 'unitPriceGhs', 10.00)))) AS quote_l;
SELECT zz.check('fixture: both quotes were submitted', (SELECT count(*) FROM public.rfq_quotes WHERE rfq_id IN (SELECT id FROM public.rfqs WHERE title LIKE 'Guard Award %')) = 2);

SELECT zz.gmode('enforce');
SELECT zz.check('enforce: awarding a whole quote that needs expired units is refused',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format('SELECT public.award_rfq_quote(%L, %L)::text', (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q'),
    (SELECT id FROM public.rfq_quotes WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q'))))
  = 'ERR: Only 5 unit(s) of Guard RFQ Q can be sold: 20 unit(s) are past their expiry date.');
SELECT zz.check('...and nothing moved: stock is unchanged and the request is still open', zz.gstock('Guard RFQ Q') = 25
  AND (SELECT status::text FROM public.rfqs WHERE title = 'Guard Award Q') NOT IN ('awarded', 'completed'));
SELECT zz.check('enforce: awarding by line is refused the same way',
  zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format('SELECT public.award_rfq_lines(%L, %L)::text', (SELECT id FROM public.rfqs WHERE title = 'Guard Award L'),
    jsonb_build_array(jsonb_build_object('quoteItemId', (SELECT qi.id FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id
                                                        WHERE q.rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award L')), 'quantity', 10))))
  = 'ERR: Only 5 unit(s) of Guard RFQ L can be sold: 20 unit(s) are past their expiry date.');
SELECT zz.check('...with stock untouched', zz.gstock('Guard RFQ L') = 25);

SELECT zz.gmode('observe');
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format('SELECT public.award_rfq_quote(%L, %L)::text', (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q'),
  (SELECT id FROM public.rfq_quotes WHERE rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award Q')))) AS observed_award_quote;
SELECT zz.check('observe: the whole-quote award goes through and the would-be refusal is recorded',
  zz.gstock('Guard RFQ Q') = 15 AND (SELECT count(*) = 1 AND bool_and(entry_point = 'rfq_award' AND quantity = 10 AND sellable = 5 AND expired_units = 20) FROM public.expiry_guard_events WHERE product_name = 'Guard RFQ Q'));
SELECT zz.gv_as((SELECT id FROM zz.u WHERE k = 'ph_owner'), format('SELECT public.award_rfq_lines(%L, %L)::text', (SELECT id FROM public.rfqs WHERE title = 'Guard Award L'),
  jsonb_build_array(jsonb_build_object('quoteItemId', (SELECT qi.id FROM public.rfq_quote_items qi JOIN public.rfq_quotes q ON q.id = qi.rfq_quote_id
                                                       WHERE q.rfq_id = (SELECT id FROM public.rfqs WHERE title = 'Guard Award L')), 'quantity', 10)))) AS observed_award_lines;
SELECT zz.check('observe: the line award goes through and is recorded',
  zz.gstock('Guard RFQ L') = 15 AND (SELECT count(*) = 1 AND bool_and(entry_point = 'rfq_award') FROM public.expiry_guard_events WHERE product_name = 'Guard RFQ L'));

SELECT zz.check('the guard is back in observe mode at the end of this suite', public.expiry_guard_mode() = 'observe');
