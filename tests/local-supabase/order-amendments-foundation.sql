-- Order amendments, Phase 1 foundation (effective total, order_events, order_timeline, ledger markers).
--   * orders.effective_total_ghs is NULL by default, can be set under production's legacy guard, while total_ghs stays
--     immutable;
--   * order_events is append-only, readable by the two parties only, writable only through the internal helper;
--   * order_timeline merges placement + status history + events, with actors shown by email on your own side and by
--     business name on the other side, and is refused to everyone outside the order;
--   * the ledger markers allow at most one credit note / debit note per amendment and one invoice per shipment.
-- Run after setup.sql + migrations (through 20261030120000; the ledger markers reference real proposals), with the production
-- guard and stock fixtures installed.
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

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000a3', 'aass@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000043"}');
SELECT zz.mkuser('30000000-0000-0000-0000-0000000000b2', 'gcash@zz.test', '{"full_name":"Good Cashier","phone":"+233241000046"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
SELECT (SELECT id FROM zz.b WHERE name = v.biz), v.uid, v.r::public.staff_role, v.st::public.staff_status, now()
FROM (VALUES
  ('Alpha Wholesale', '30000000-0000-0000-0000-0000000000a3'::uuid, 'assistant', 'inactive'),
  ('Good Pharmacy', '30000000-0000-0000-0000-0000000000b2'::uuid, 'cashier', 'active')) v(biz, uid, r, st);

INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'AF Item', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 100000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.af AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  '30000000-0000-0000-0000-0000000000a3'::uuid u_wsusp,
  '30000000-0000-0000-0000-0000000000b2'::uuid u_pcash,
  (SELECT id FROM public.products WHERE name='AF Item') p_item;
CREATE TABLE zz.af_orders(label TEXT PRIMARY KEY, order_id UUID);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.af), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.af)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.af;

SELECT public.create_marketplace_orders((SELECT u_po FROM zz.af), (SELECT good FROM zz.af),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_item FROM zz.af), 'quantity', 5, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.af)::text, 'credit')) AS r \gset o1_
INSERT INTO zz.af_orders SELECT 'o1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;

-- 1. The effective total.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.af_orders WHERE label = 'o1'); r TEXT;
BEGIN
  PERFORM zz.check('a new order has no effective total (NULL = not amended)', (SELECT effective_total_ghs IS NULL FROM public.orders WHERE id = o));
  PERFORM zz.check('order_effective_total falls back to the placed total (500)', public.order_effective_total(o) = 500);
  BEGIN
    UPDATE public.orders SET effective_total_ghs = 400 WHERE id = o;
    PERFORM zz.check('the order total cannot be edited directly (phase 3 guard)', FALSE, 'update was allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('the order total cannot be edited directly (phase 3 guard)', SQLERRM LIKE 'The order total can only change through an approved supply change%', SQLERRM);
  END;
  PERFORM set_config('drugxone.amendment_txid', txid_current()::text, true);
  UPDATE public.orders SET effective_total_ghs = 400 WHERE id = o;
  PERFORM zz.check('the effective total can be set even under production''s legacy guard', (SELECT effective_total_ghs = 400 FROM public.orders WHERE id = o));
  PERFORM zz.check('order_effective_total now returns 400', public.order_effective_total(o) = 400);
  PERFORM zz.check('the placed total is untouched (500)', (SELECT total_ghs = 500 FROM public.orders WHERE id = o));
  BEGIN
    UPDATE public.orders SET total_ghs = 400 WHERE id = o;
    PERFORM zz.check('the placed total stays immutable (the legacy guard still refuses to change it)', FALSE, 'update was allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('the placed total stays immutable (the legacy guard still refuses to change it)', SQLERRM = 'Order parties and historical financial fields are immutable.', SQLERRM);
  END;
  BEGIN
    UPDATE public.orders SET effective_total_ghs = -1 WHERE id = o;
    PERFORM zz.check('a negative effective total is refused', FALSE, 'update was allowed');
  EXCEPTION WHEN check_violation THEN
    PERFORM zz.check('a negative effective total is refused', TRUE);
  END;
  UPDATE public.orders SET effective_total_ghs = NULL WHERE id = o;
  PERFORM zz.check('and can be cleared again', public.order_effective_total(o) = 500);
  PERFORM set_config('drugxone.amendment_txid', '', true);
  r := zz.val_as((SELECT u_wo FROM zz.af), format('SELECT public.order_effective_total(%L)::text', o));
  PERFORM zz.check('the helper is internal: users cannot call it directly', r LIKE 'ERR: permission denied%', r);
END $$;

-- 2. Events: writable only through the internal helper, append-only, readable by the two parties.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.af_orders WHERE label = 'o1'); r TEXT; n BIGINT;
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.af), format('SELECT public.record_order_event(%L, ''x'', ''wholesaler'', ''x'')::text', o));
  PERFORM zz.check('users cannot write events through the helper', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as((SELECT u_wo FROM zz.af), format('INSERT INTO public.order_events(order_id, event_type, actor_side, summary) VALUES (%L, ''x'', ''wholesaler'', ''x'') RETURNING id::text', o));
  PERFORM zz.check('users cannot insert events directly', r LIKE 'ERR: permission denied%', r);
END $$;
-- Two events recorded as each side (the helper is called by the later phases' definer functions).
SELECT set_config('request.jwt.claim.sub', (SELECT u_wm FROM zz.af)::text, false);
SELECT public.record_order_event((SELECT order_id FROM zz.af_orders WHERE label = 'o1'), 'note_added', 'wholesaler', 'Wholesaler note: stock check under way', '{"k": 1}'::jsonb) IS NOT NULL AS ev1;
SELECT set_config('request.jwt.claim.sub', (SELECT u_po FROM zz.af)::text, false);
SELECT public.record_order_event((SELECT order_id FROM zz.af_orders WHERE label = 'o1'), 'note_added', 'pharmacy', 'Pharmacy note: please confirm delivery date') IS NOT NULL AS ev2;
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.af)::text, false);

DO $$
DECLARE o UUID := (SELECT order_id FROM zz.af_orders WHERE label = 'o1'); r TEXT; q TEXT := 'SELECT count(*)::text FROM public.order_events WHERE order_id = %L';
BEGIN
  PERFORM zz.check('two events exist', (SELECT count(*) FROM public.order_events WHERE order_id = o) = 2);
  r := zz.val_as((SELECT u_wo FROM zz.af), format(q, o)); PERFORM zz.check('the wholesaler owner sees both events', r = '2', r);
  r := zz.val_as((SELECT u_wm FROM zz.af), format(q, o)); PERFORM zz.check('a wholesaler manager sees them', r = '2', r);
  r := zz.val_as((SELECT u_wc FROM zz.af), format(q, o)); PERFORM zz.check('a wholesaler cashier sees them', r = '2', r);
  r := zz.val_as((SELECT u_po FROM zz.af), format(q, o)); PERFORM zz.check('the pharmacy owner sees them', r = '2', r);
  r := zz.val_as((SELECT u_pcash FROM zz.af), format(q, o)); PERFORM zz.check('active pharmacy staff see them', r = '2', r);
  r := zz.val_as((SELECT u_wsusp FROM zz.af), format(q, o)); PERFORM zz.check('suspended wholesaler staff see nothing', r = '0', r);
  r := zz.val_as((SELECT u_px FROM zz.af), format(q, o)); PERFORM zz.check('another pharmacy sees nothing', r = '0', r);
  r := zz.val_as((SELECT u_wx FROM zz.af), format(q, o)); PERFORM zz.check('another wholesaler sees nothing', r = '0', r);
  BEGIN
    UPDATE public.order_events SET summary = 'changed' WHERE order_id = o;
    PERFORM zz.check('an event cannot be edited, even by a superuser', FALSE, 'update allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('an event cannot be edited, even by a superuser', SQLERRM = 'Order events are append-only.', SQLERRM);
  END;
  BEGIN
    DELETE FROM public.order_events WHERE order_id = o;
    PERFORM zz.check('an event cannot be deleted, even by a superuser', FALSE, 'delete allowed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('an event cannot be deleted, even by a superuser', SQLERRM = 'Order events are append-only.', SQLERRM);
  END;
  BEGIN
    PERFORM public.record_order_event(o, 'bad', 'martian', 'x');
    PERFORM zz.check('an unknown actor side is refused', FALSE, 'insert allowed');
  EXCEPTION WHEN check_violation THEN
    PERFORM zz.check('an unknown actor side is refused', TRUE);
  END;
  BEGIN
    PERFORM public.record_order_event(o, 'bad', 'system', '');
    PERFORM zz.check('an empty summary is refused', FALSE, 'insert allowed');
  EXCEPTION WHEN check_violation THEN
    PERFORM zz.check('an empty summary is refused', TRUE);
  END;
END $$;

-- Give the order a real life: accepted -> picking -> packed, by the wholesaler owner.
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT order_id FROM zz.af_orders WHERE label = 'o1');
UPDATE public.orders SET status = 'picking' WHERE id = (SELECT order_id FROM zz.af_orders WHERE label = 'o1');
UPDATE public.orders SET status = 'packed' WHERE id = (SELECT order_id FROM zz.af_orders WHERE label = 'o1');

-- 3. The timeline.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.af_orders WHERE label = 'o1'); r TEXT; tq TEXT := 'SELECT count(*)::text FROM public.order_timeline(%L)';
BEGIN
  r := zz.val_as((SELECT u_wo FROM zz.af), format(tq, o));
  PERFORM zz.check('the timeline has 7 entries: placed, the initial status, 3 status changes, 2 notes', r = '7', r);
  PERFORM zz.check('it is chronological and starts with the placement',
    (SELECT (array_agg(event_type ORDER BY at, ord))[1] = 'placed' FROM (SELECT t.*, row_number() OVER () AS ord FROM public.order_timeline(o) t) x));
  PERFORM zz.check('entries are in time order', (SELECT bool_and(at >= prev_at) FROM (SELECT at, lag(at) OVER (ORDER BY at, source) AS prev_at FROM public.order_timeline(o)) x WHERE prev_at IS NOT NULL));
  PERFORM zz.check('status entries say what changed in words',
    EXISTS (SELECT 1 FROM public.order_timeline(o) WHERE source = 'status' AND summary = 'Status changed from picking to packed'));
  PERFORM zz.check('the initial status entry (no previous status) reads naturally',
    EXISTS (SELECT 1 FROM public.order_timeline(o) WHERE source = 'status' AND summary LIKE 'Status set to %') OR NOT EXISTS (SELECT 1 FROM public.order_status_history WHERE order_id = o AND from_status IS NULL));
  -- As the wholesaler: own people by email, the pharmacy by business name.
  PERFORM zz.check('the wholesaler sees its own status changes by email',
    zz.val_as((SELECT u_wo FROM zz.af), format('SELECT string_agg(DISTINCT actor_label, '','') FROM public.order_timeline(%L) WHERE source = ''status''', o)) = 'wo@zz.test');
  PERFORM zz.check('and sees the pharmacy''s note attributed to the pharmacy''s business name, not its staff email',
    zz.val_as((SELECT u_wo FROM zz.af), format('SELECT actor_label FROM public.order_timeline(%L) WHERE summary LIKE ''Pharmacy note%%''', o)) = 'Good Pharmacy');
  PERFORM zz.check('the placement is attributed to the pharmacy business',
    zz.val_as((SELECT u_wo FROM zz.af), format('SELECT actor_label FROM public.order_timeline(%L) WHERE event_type = ''placed''', o)) = 'Good Pharmacy');
  -- As the pharmacy: the reverse.
  PERFORM zz.check('the pharmacy sees the wholesaler''s status changes attributed to the wholesaler''s business name',
    zz.val_as((SELECT u_po FROM zz.af), format('SELECT string_agg(DISTINCT actor_label, '','') FROM public.order_timeline(%L) WHERE source = ''status''', o)) = 'Alpha Wholesale');
  PERFORM zz.check('and sees its own note by its own email',
    zz.val_as((SELECT u_po FROM zz.af), format('SELECT actor_label FROM public.order_timeline(%L) WHERE summary LIKE ''Pharmacy note%%''', o)) = 'po@zz.test');
  PERFORM zz.check('no staff email of the other organisation appears anywhere in the pharmacy''s view',
    zz.val_as((SELECT u_po FROM zz.af), format('SELECT count(*)::text FROM public.order_timeline(%L) WHERE actor_label LIKE ''%%@zz.test'' AND actor_label <> ''po@zz.test''', o)) = '0');
  r := zz.val_as((SELECT u_pcash FROM zz.af), format(tq, o)); PERFORM zz.check('active pharmacy staff can read it', r = '7', r);
  r := zz.val_as((SELECT u_wc FROM zz.af), format(tq, o)); PERFORM zz.check('active wholesaler staff can read it', r = '7', r);
  r := zz.val_as((SELECT u_admin FROM zz.af), format(tq, o)); PERFORM zz.check('a platform admin can read it', r = '7', r);
  r := zz.val_as((SELECT u_wsusp FROM zz.af), format(tq, o)); PERFORM zz.check('suspended staff are refused', r = 'ERR: You do not have access to this order.', r);
  r := zz.val_as((SELECT u_px FROM zz.af), format(tq, o)); PERFORM zz.check('another pharmacy is refused', r = 'ERR: You do not have access to this order.', r);
  r := zz.val_as((SELECT u_wx FROM zz.af), format(tq, o)); PERFORM zz.check('another wholesaler is refused', r = 'ERR: You do not have access to this order.', r);
  r := zz.val_as((SELECT u_wo FROM zz.af), format(tq, gen_random_uuid())); PERFORM zz.check('an unknown order is not found', r = 'ERR: Order not found.', r);
  PERFORM zz.check('the timeline carries nothing from the credit ledger',
    NOT EXISTS (SELECT 1 FROM public.order_timeline(o) WHERE details::text ~* 'ledger|outstanding|credit_note|exposure'));
END $$;

-- 4. Ledger idempotency markers.
DO $$
DECLARE o UUID := (SELECT order_id FROM zz.af_orders WHERE label = 'o1'); a UUID := gen_random_uuid(); s UUID := gen_random_uuid();
  w UUID := (SELECT alpha FROM zz.af); g UUID := (SELECT good FROM zz.af);
BEGIN
  -- Since phase 2 the marker points at a real proposal (foreign key), so make one.
  INSERT INTO public.order_amendments(id, order_id, version, kind, reason, proposed_by, original_total_ghs, proposed_total_ghs, delta_ghs, request_id)
  VALUES (a, o, 1, 'partial_fulfilment', 'marker test', (SELECT u_wo FROM zz.af), 500, 450, -50, gen_random_uuid());
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, amendment_id, note)
  VALUES (w, g, o, 'credit_note', 'credit', 50, a, 'amendment credit note');
  PERFORM zz.check('one credit note per amendment is accepted', TRUE);
  BEGIN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, amendment_id, note)
    VALUES (w, g, o, 'credit_note', 'credit', 50, a, 'duplicate');
    PERFORM zz.check('a second credit note for the same amendment is refused', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second credit note for the same amendment is refused', TRUE);
  END;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, amendment_id, note)
  VALUES (w, g, o, 'debit_note', 'debit', 20, a, 'price increase');
  PERFORM zz.check('the same amendment may also carry one debit note (a different document type)', TRUE);
  INSERT INTO public.order_shipments(id, order_id, sequence, status, amount_ghs, request_id, created_by)
  VALUES (s, o, 2, 'pending', 30, gen_random_uuid(), (SELECT u_wo FROM zz.af));
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, shipment_id, note)
  VALUES (w, g, o, 'invoice', 'debit', 30, s, 'back-order shipment invoice');
  BEGIN
    INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, shipment_id, note)
    VALUES (w, g, o, 'invoice', 'debit', 30, s, 'duplicate shipment invoice');
    PERFORM zz.check('a second invoice entry for the same shipment is refused', FALSE, 'insert allowed');
  EXCEPTION WHEN unique_violation THEN
    PERFORM zz.check('a second invoice entry for the same shipment is refused', TRUE);
  END;
  INSERT INTO public.credit_ledger_entries(wholesaler_id, pharmacy_id, order_id, entry_type, direction, amount_ghs, note)
  VALUES (w, g, o, 'credit_note', 'credit', 1, 'no marker'), (w, g, o, 'credit_note', 'credit', 1, 'no marker either');
  PERFORM zz.check('entries without a marker are unconstrained (existing behaviour is untouched)', TRUE);
  PERFORM zz.check('the ledger still adds up: 500 invoice - 50 - 1 - 1 + 20 + 30 = 498', (SELECT outstanding_ghs = 498 FROM public.credit_invoice_status(o)), (SELECT outstanding_ghs::text FROM public.credit_invoice_status(o)));
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
