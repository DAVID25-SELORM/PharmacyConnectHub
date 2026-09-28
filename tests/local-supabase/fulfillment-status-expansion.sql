-- Fulfillment status expansion: 'picking' and 'ready_for_dispatch' inserted into the order
-- lifecycle between accepted/packed and packed/dispatched respectively. Both are manual,
-- wholesaler-button-driven transitions (no new automation) -- this suite walks a single order
-- through the full new chain and checks: timestamp stamping, status-history rows, notification
-- text, the widened confirm_order_picks/record_order_dispatch_details status gates, and the two
-- 'active'/'pending' report queries that switched from an enumerated list to NOT IN (terminal).
-- Run after setup.sql + migrations through 20261001110000_fulfillment_status_expansion_logic.sql.
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

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  o_id UUID;
  o_disp UUID; -- already-dispatched fixture for the "too late to pick" check
  r TEXT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'accepted', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_id;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'dispatched', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_disp;

  -- Backdate created_at: resolve_report_range('all', ...) sets range_to = now(), and now() is
  -- frozen for the whole transaction, so a row inserted with the now()-default created_at would
  -- sit exactly ON the (exclusive) upper bound and get filtered out. Real orders are always
  -- created in an earlier transaction than the report query, so this only matters here.
  UPDATE public.orders SET created_at = now() - interval '5 minutes' WHERE id IN (o_id, o_disp);

  ------------------------------------------------------------------
  -- 1. Walk one order through the full new chain via direct table UPDATE (the same path the
  --    wholesaler UI uses), checking each transition succeeds, its timestamp gets stamped, and a
  --    status_history row is written.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format('WITH x AS (UPDATE public.orders SET status=''picking'' WHERE id=%L RETURNING id) SELECT count(*)::text FROM x', o_id));
  PERFORM zz.check('accepted -> picking succeeds', r = '1', r);
  PERFORM zz.check('picking_started_at stamped', (SELECT picking_started_at FROM public.orders WHERE id = o_id) IS NOT NULL);
  PERFORM zz.check('history row: accepted -> picking', EXISTS (
    SELECT 1 FROM public.order_status_history WHERE order_id = o_id AND from_status = 'accepted' AND to_status = 'picking'));
  PERFORM zz.check('pharmacy notified: "being picked"', EXISTS (
    SELECT 1 FROM public.notifications WHERE user_id = u_po AND body LIKE '%is now being picked.%'
      AND created_at > now() - interval '1 minute'));

  r := zz.val_as(u_wo, format('WITH x AS (UPDATE public.orders SET status=''packed'' WHERE id=%L RETURNING id) SELECT count(*)::text FROM x', o_id));
  PERFORM zz.check('picking -> packed succeeds', r = '1', r);
  PERFORM zz.check('packed_at stamped', (SELECT packed_at FROM public.orders WHERE id = o_id) IS NOT NULL);

  r := zz.val_as(u_wo, format('WITH x AS (UPDATE public.orders SET status=''ready_for_dispatch'' WHERE id=%L RETURNING id) SELECT count(*)::text FROM x', o_id));
  PERFORM zz.check('packed -> ready_for_dispatch succeeds', r = '1', r);
  PERFORM zz.check('ready_for_dispatch_at stamped', (SELECT ready_for_dispatch_at FROM public.orders WHERE id = o_id) IS NOT NULL);
  PERFORM zz.check('history row: packed -> ready_for_dispatch', EXISTS (
    SELECT 1 FROM public.order_status_history WHERE order_id = o_id AND from_status = 'packed' AND to_status = 'ready_for_dispatch'));
  PERFORM zz.check('pharmacy notified: "ready for dispatch"', EXISTS (
    SELECT 1 FROM public.notifications WHERE user_id = u_po AND body LIKE '%is now ready for dispatch.%'
      AND created_at > now() - interval '1 minute'));

  r := zz.val_as(u_wo, format('WITH x AS (UPDATE public.orders SET status=''dispatched'' WHERE id=%L RETURNING id) SELECT count(*)::text FROM x', o_id));
  PERFORM zz.check('ready_for_dispatch -> dispatched succeeds', r = '1', r);

  ------------------------------------------------------------------
  -- 2. confirm_order_picks: widened to accept 'picking' and 'ready_for_dispatch' (previously only
  --    'accepted'/'packed'); still rejects once actually dispatched.
  ------------------------------------------------------------------
  UPDATE public.orders SET status = 'picking' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT public.confirm_order_picks(%L)::text', o_id));
  PERFORM zz.check('confirm_order_picks allowed during picking', r NOT LIKE 'ERR%', r);

  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT public.confirm_order_picks(%L)::text', o_id));
  PERFORM zz.check('confirm_order_picks allowed during ready_for_dispatch', r NOT LIKE 'ERR%', r);

  r := zz.val_as(u_wo, format('SELECT public.confirm_order_picks(%L)::text', o_disp));
  PERFORM zz.check('confirm_order_picks still rejected once dispatched', r LIKE 'ERR: Batches can only be confirmed%', r);

  ------------------------------------------------------------------
  -- 3. record_order_dispatch_details: widened the same way.
  ------------------------------------------------------------------
  UPDATE public.orders SET status = 'picking' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_id));
  PERFORM zz.check('record_order_dispatch_details allowed during picking', r NOT LIKE 'ERR%', r);

  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_id));
  PERFORM zz.check('record_order_dispatch_details allowed during ready_for_dispatch', r NOT LIKE 'ERR%', r);

  UPDATE public.orders SET status = 'pending' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_id));
  PERFORM zz.check('record_order_dispatch_details still rejected while pending', r LIKE 'ERR: Delivery details can only be added%', r);

  ------------------------------------------------------------------
  -- 4. wholesaler_report_overview: 'pending_orders' KPI now counts every non-terminal status,
  --    including the two new ones, instead of an enumerated list that would have missed them.
  ------------------------------------------------------------------
  UPDATE public.orders SET status = 'picking' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT (public.wholesaler_report_overview(%L, ''all'')->''kpis''->>''pending_orders'')', alpha));
  PERFORM zz.check('wholesaler_report_overview counts a picking order as pending', r::INTEGER >= 1, r);

  UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = o_id;
  r := zz.val_as(u_wo, format('SELECT (public.wholesaler_report_overview(%L, ''all'')->''kpis''->>''pending_orders'')', alpha));
  PERFORM zz.check('wholesaler_report_overview counts a ready_for_dispatch order as pending', r::INTEGER >= 1, r);

  ------------------------------------------------------------------
  -- 5. list_pharmacy_order_history: the 'active' filter now matches every non-terminal status too.
  ------------------------------------------------------------------
  r := zz.val_as(u_po, format('SELECT (public.list_pharmacy_order_history(1, 20, NULL, ''active'', NULL, ''newest'', NULL, NULL, NULL, NULL, NULL)->>''total_count'')'));
  PERFORM zz.check('pharmacy "active" filter finds the ready_for_dispatch order', r::INTEGER >= 1, r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
