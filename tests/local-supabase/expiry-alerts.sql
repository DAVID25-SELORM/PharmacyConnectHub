-- Expiry alerts: bucketing, grouping, de-duplication, recipients, throttle, permissions.
-- Run after setup.sql + migrations (through 20260924180000_batch_expiry_alerts.sql).
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

CREATE FUNCTION zz.who(p_title TEXT) RETURNS TEXT LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(u.k, ',' ORDER BY u.k), '-')
  FROM public.notifications n JOIN zz.u u ON u.id = n.user_id
  WHERE n.type = 'expiry_alert' AND n.title = p_title
$$;

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now());
DELETE FROM public.notifications;

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  p UUID; px UUID; n INTEGER; r TEXT;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Ex Amox', 'Cat', 'TABLET', '10s', 10, 100, true) RETURNING id INTO p;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (other_w, 'Ex Other', 'Cat', 'TABLET', '10s', 10, 100, true) RETURNING id INTO px;
  INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand) VALUES
    (p, alpha, 'E',  current_date - 3,  4, 4),
    (p, alpha, 'A',  current_date + 10, 6, 6),
    (p, alpha, 'A2', current_date + 20, 2, 2),
    (p, alpha, 'B',  current_date + 45, 5, 5),
    (p, alpha, 'C',  current_date + 80, 7, 7),
    (p, alpha, 'D',  current_date + 200, 9, 9),
    (p, alpha, 'Z',  current_date + 10, 3, 0),
    (px, other_w, 'X', current_date + 5, 3, 3);

  n := public.generate_batch_expiry_alerts(alpha);
  PERFORM zz.check('alpha run: 4 buckets x (owner + manager) = 8 notifications', n = 8, n::text);
  PERFORM zz.check('expired bucket notifies owner and manager only', zz.who('Expired stock') = 'w_manager,w_owner', zz.who('Expired stock'));
  PERFORM zz.check('cashier receives no expiry alert',
    (SELECT count(*) FROM public.notifications x WHERE x.type = 'expiry_alert' AND x.user_id = (SELECT id FROM zz.u WHERE k = 'w_cashier')) = 0);
  PERFORM zz.check('assistant receives no expiry alert',
    (SELECT count(*) FROM public.notifications x WHERE x.type = 'expiry_alert' AND x.user_id = '10000000-0000-0000-0000-0000000000a1') = 0);
  PERFORM zz.check('the other wholesaler is untouched by a run scoped to alpha',
    (SELECT count(*) FROM public.notifications x WHERE x.type = 'expiry_alert' AND x.user_id = (SELECT id FROM zz.u WHERE k = 'w_other')) = 0);
  PERFORM zz.check('two batches in the 30-day bucket are one grouped notification per recipient',
    (SELECT count(*) FROM public.notifications WHERE title = 'Stock expiring within 30 days') = 2
    AND (SELECT body FROM public.notifications WHERE title = 'Stock expiring within 30 days' LIMIT 1) LIKE '2 batches (8 units) are close to expiry:%');
  PERFORM zz.check('the expired notification is singular and mentions the batch',
    (SELECT body FROM public.notifications WHERE title = 'Expired stock' LIMIT 1) LIKE '1 batch (4 units) has expired: Ex Amox (E)%');
  PERFORM zz.check('60 and 90 day buckets each produce one notification per recipient',
    (SELECT count(*) FROM public.notifications WHERE title = 'Stock expiring within 60 days') = 2
    AND (SELECT count(*) FROM public.notifications WHERE title = 'Stock expiring within 90 days') = 2);
  PERFORM zz.check('a batch 200 days out and a used-up batch are ignored',
    (SELECT count(*) FROM public.batch_expiry_alerts_sent WHERE batch_id IN (SELECT id FROM public.product_batches WHERE batch_number IN ('D', 'Z'))) = 0);
  PERFORM zz.check('alerts link to the batches tab', (SELECT count(*) FROM public.notifications WHERE type = 'expiry_alert' AND link = '/wholesaler?tab=batches') = 8);

  n := public.generate_batch_expiry_alerts(alpha);
  PERFORM zz.check('running again creates nothing (de-duplicated)', n = 0, n::text);

  UPDATE public.product_batches SET expiry_date = current_date + 20 WHERE batch_number = 'B';
  n := public.generate_batch_expiry_alerts(alpha);
  PERFORM zz.check('a batch moving into a closer bucket creates a new alert (1 batch x 2 recipients)', n = 2, n::text);
  PERFORM zz.check('the escalation is titled for the 30-day bucket and names only that batch',
    (SELECT count(*) FROM public.notifications WHERE title = 'Stock expiring within 30 days' AND body LIKE '1 batch (5 units) is close to expiry: Ex Amox (B)%') = 2);

  UPDATE public.product_batches SET quantity_on_hand = 0 WHERE batch_number = 'C';
  UPDATE public.product_batches SET expiry_date = current_date + 5 WHERE batch_number = 'C';
  n := public.generate_batch_expiry_alerts(alpha);
  PERFORM zz.check('a used-up batch never alerts even when its date is close', n = 0, n::text);

  n := public.generate_batch_expiry_alerts(NULL);
  PERFORM zz.check('the global (cron) run covers other wholesalers: 1 batch x 1 owner', n = 1, n::text);
  PERFORM zz.check('the other wholesaler owner got it', (SELECT count(*) FROM public.notifications x WHERE x.type = 'expiry_alert' AND x.user_id = (SELECT id FROM zz.u WHERE k = 'w_other')) = 1);
  n := public.generate_batch_expiry_alerts(NULL);
  PERFORM zz.check('and the global run is idempotent too', n = 0, n::text);
END $$;

-- throttled refresh + permissions ----------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  p UUID := (SELECT id FROM public.products WHERE name = 'Ex Amox');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other'); u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wa UUID := '10000000-0000-0000-0000-0000000000a1'; r TEXT;
BEGIN
  INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand) VALUES (p, alpha, 'N1', current_date + 2, 1, 1);
  r := zz.val_as(u_wm, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('manager refresh runs and finds the new batch (1 batch x 2 recipients)', r = 'ran:2', r);
  INSERT INTO public.product_batches(product_id, wholesaler_id, batch_number, expiry_date, quantity_received, quantity_on_hand) VALUES (p, alpha, 'N2', current_date + 3, 1, 1);
  r := zz.val_as(u_wm, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('a second refresh within 6 hours is skipped', r = 'skipped', r);
  UPDATE public.expiry_alert_runs SET last_run_at = now() - interval '7 hours' WHERE business_id = alpha;
  r := zz.val_as(u_wm, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('after 6 hours it runs again and picks up N2', r = 'ran:2', r);

  r := zz.val_as(u_wc, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('cashier cannot refresh', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wa, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('assistant cannot refresh', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_wx, format('SELECT public.refresh_my_expiry_alerts(%L)', alpha));
  PERFORM zz.check('another wholesaler cannot refresh my alerts', r LIKE 'ERR: You do not have permission%', r);
  r := zz.val_as(u_po, format('SELECT public.refresh_my_expiry_alerts(%L)', good));
  PERFORM zz.check('a pharmacy owner cannot use it for their pharmacy', r LIKE 'ERR: Expiry alerts are only available for wholesalers%', r);
  r := zz.val_as(u_wm, format('SELECT public.generate_batch_expiry_alerts(%L)', alpha));
  PERFORM zz.check('the generator itself is not callable by signed-in users', r LIKE 'ERR: permission denied%', r);
  r := zz.val_as(u_wm, 'SELECT count(*)::text FROM public.batch_expiry_alerts_sent');
  PERFORM zz.check('the sent log is hidden from users', r = '0', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.refresh_my_expiry_alerts(alpha);
    RESET ROLE;
    PERFORM zz.check('anon cannot refresh', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot refresh', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
