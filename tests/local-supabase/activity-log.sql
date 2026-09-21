-- Activity log RPCs on the real schema with a large seeded audit_logs table.
-- Run after setup.sql on a local stack with 20260921120000 applied. Local only.

-- ---- seed: 300k events, many sharing the same timestamp (tie-break test), some with secrets ----
DELETE FROM public.audit_logs;
INSERT INTO public.audit_logs (activity, organization, performed_by, performed_by_email, record_type, record_id, record_label, ip_address, details, created_at)
SELECT
  (ARRAY['Order placed','Order accepted','Order delivered','Payment paid','Business approved','Business rejected','Verification resubmitted','Pharmacy submitted','Business staff invited','Inventory imported'])[1 + (i % 10)],
  CASE WHEN i % 25 = 0 THEN 'Good Pharmacy' WHEN i % 25 = 1 THEN 'Alpha Wholesale' ELSE 'Org ' || (i % 200) END,
  CASE WHEN i % 10 = 0 THEN NULL ELSE (SELECT id FROM zz.u WHERE k = 'admin') END,
  CASE WHEN i % 10 = 0 THEN NULL WHEN i % 7 = 0 THEN 'actor7@example.com' ELSE 'actor' || (i % 50) || '@example.com' END,
  CASE WHEN (i % 10) IN (0,1,2,3) THEN 'order' ELSE 'business' END,
  gen_random_uuid(),
  'REF-' || i,
  '203.0.113.' || (i % 250),
  CASE WHEN i % 1000 = 0 THEN jsonb_build_object('status','ok','access_token','SECRET-TOKEN-' || i,'nested',jsonb_build_object('smtp_pass','SECRET-SMTP'))
       ELSE jsonb_build_object('status','ok','total_ghs', i % 500) END,
  now() - ((i / 50) * interval '30 seconds')   -- 50 rows share each timestamp
FROM generate_series(1, 300000) i;
VACUUM ANALYZE public.audit_logs;
SELECT count(*) AS seeded_rows, count(DISTINCT created_at) AS distinct_timestamps FROM public.audit_logs;

DO $$
DECLARE
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  r TEXT; n BIGINT; pages INT := 0;
  cur_ts TIMESTAMPTZ; cur_id UUID; ids UUID[] := '{}'; batch UUID[]; batch_n INT; last_ts TIMESTAMPTZ; last_id UUID;
  prev_ts TIMESTAMPTZ; prev_id UUID; ok_order BOOLEAN := TRUE; dup INT; ref UUID[]; got_more BOOLEAN;
BEGIN
  -- ===== security =====
  r := zz.run_as(u_px, 'SELECT * FROM public.admin_list_activity()');
  PERFORM zz.check('list: non-admin denied', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_px, format('SELECT * FROM public.admin_get_activity(%L)', (SELECT id FROM public.audit_logs LIMIT 1)));
  PERFORM zz.check('get: non-admin denied', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_px, 'SELECT public.admin_platform_summary()');
  PERFORM zz.check('summary: non-admin denied', r LIKE 'ERR: Only platform admins%', r);
  r := zz.run_as(u_px, 'SELECT count(*) FROM public.audit_logs');
  PERFORM zz.check('direct audit_logs read still admin-only (RLS): non-admin sees 0 rows',
    zz.count_as(u_px, 'SELECT 1 FROM public.audit_logs') = 0);
  PERFORM zz.check('anon has no EXECUTE on the RPCs',
    NOT has_function_privilege('anon', 'public.admin_list_activity(text,text,text,text,text,text,text,timestamptz,timestamptz,timestamptz,uuid,integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_get_activity(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_platform_summary()', 'EXECUTE'));

  -- ===== bounded results =====
  PERFORM zz.check('preview: 15 rows requested => at most 16 fetched, whatever the table size',
    zz.count_as(u_admin, 'SELECT * FROM public.admin_list_activity(p_limit => 15)') = 16);
  PERFORM zz.check('limit is clamped to 200 (+1)',
    zz.count_as(u_admin, 'SELECT * FROM public.admin_list_activity(p_limit => 100000)') = 201);
  r := zz.run_as(u_admin, $q$SELECT * FROM public.admin_list_activity(p_search => 'a')$q$);
  PERFORM zz.check('search under 2 characters rejected', r LIKE 'ERR: Search needs at least 2%', r);

  -- ===== keyset walk over the first 60 pages =====
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', u_admin::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  LOOP
    SELECT array_agg(t.id ORDER BY t.created_at DESC, t.id DESC), count(*)::int, min(t.created_at), (array_agg(t.id ORDER BY t.created_at DESC, t.id DESC))[50]
      INTO batch, batch_n, last_ts, last_id
    FROM public.admin_list_activity(p_limit => 50, p_cursor_created_at => cur_ts, p_cursor_id => cur_id) t;
    -- the 51st row only signals "more"; take the first 50 and use the 50th as the cursor
    ids := ids || batch[1:50];
    SELECT created_at INTO cur_ts FROM public.audit_logs WHERE id = batch[50];
    cur_id := batch[50];
    pages := pages + 1;
    EXIT WHEN pages >= 60;
  END LOOP;
  EXECUTE 'RESET ROLE';

  SELECT array_agg(id ORDER BY created_at DESC, id DESC) INTO ref FROM (SELECT id, created_at FROM public.audit_logs ORDER BY created_at DESC, id DESC LIMIT 3000) x;
  PERFORM zz.check('keyset: 60 pages x 50 rows are identical to the first 3000 rows of a plain ORDER BY', ids = ref);
  SELECT count(*) - count(DISTINCT x) INTO dup FROM unnest(ids) x;
  PERFORM zz.check('keyset: no duplicate rows across pages (50 rows share each timestamp)', dup = 0, dup::text);
  PERFORM zz.check('keyset: 3000 distinct rows walked', cardinality(ids) = 3000);

  -- ===== filters (all server-side; every returned row must satisfy the filter) =====
  PERFORM zz.check('filter: event = Order placed',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_activity => 'Order placed', p_limit => 200) WHERE activity <> 'Order placed'$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_activity => 'Order placed', p_limit => 200)$q$) = 201);
  PERFORM zz.check('filter: category orders (Order %)',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_category => 'orders', p_limit => 200) WHERE activity NOT LIKE 'Order %'$q$) = 0);
  PERFORM zz.check('filter: category verification',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_category => 'verification', p_limit => 200) WHERE activity NOT IN ('Pharmacy submitted','Wholesaler submitted','Business approved','Business rejected','Business verification updated','Verification resubmitted')$q$) = 0);
  r := zz.run_as(u_admin, $q$SELECT * FROM public.admin_list_activity(p_category => 'bogus')$q$);
  PERFORM zz.check('filter: unknown category rejected', r LIKE 'ERR: Unknown activity category%', r);
  PERFORM zz.check('filter: organization exact',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_organization => 'Org 17', p_limit => 200) WHERE organization <> 'Org 17'$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_organization => 'Org 17', p_limit => 200)$q$) > 0);
  PERFORM zz.check('filter: organization type pharmacy only returns pharmacy organizations',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_org_type => 'pharmacy', p_limit => 200) WHERE organization NOT IN (SELECT name FROM public.businesses WHERE type = 'pharmacy')$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_org_type => 'pharmacy', p_limit => 200)$q$) > 0);
  PERFORM zz.check('filter: organization type wholesaler',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_org_type => 'wholesaler', p_limit => 200) WHERE organization NOT IN (SELECT name FROM public.businesses WHERE type = 'wholesaler')$q$) = 0);
  PERFORM zz.check('filter: actor = system returns only system events',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_actor => 'system', p_limit => 200) WHERE performed_by_email IS NOT NULL$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_actor => 'system', p_limit => 200)$q$) = 201);
  PERFORM zz.check('filter: actor email (case-insensitive)',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_actor => 'ACTOR7@example.com', p_limit => 200) WHERE performed_by_email <> 'actor7@example.com'$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_actor => 'ACTOR7@example.com', p_limit => 200)$q$) > 0);
  PERFORM zz.check('search: matches organization / actor / record / event only',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'REF-1234', p_limit => 200)$q$) > 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'REF-1234', p_limit => 200) WHERE record_label NOT ILIKE '%REF-1234%'$q$) = 0);
  PERFORM zz.check('search: does NOT scan the details JSON (secret value is not searchable)',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'SECRET-TOKEN')$q$) = 0);
  PERFORM zz.check('search: % and _ are treated literally',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'Org%')$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'Org_17')$q$) = 0);
  PERFORM zz.check('search: SQL-looking input is just text (no injection)',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => $x$'; DROP TABLE public.audit_logs; --$x$)$q$) = 0
    AND to_regclass('public.audit_logs') IS NOT NULL);
  PERFORM zz.check('date: today returns only rows from today',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_range => 'today', p_limit => 200) WHERE created_at < date_trunc('day', now())$q$) = 0);
  PERFORM zz.check('date: 7d returns nothing older than 7 days',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_range => '7d', p_limit => 200) WHERE created_at < now() - interval '7 days'$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_range => '7d', p_limit => 200)$q$) = 201);
  PERFORM zz.check('date: custom range is inclusive of from, exclusive of to',
    zz.count_as(u_admin, format($q$SELECT 1 FROM public.admin_list_activity(p_range => 'custom', p_from => %L, p_to => %L, p_limit => 200) WHERE created_at < %L OR created_at >= %L$q$,
      (now() - interval '3 days')::text, (now() - interval '2 days')::text, (now() - interval '3 days')::text, (now() - interval '2 days')::text)) = 0);
  PERFORM zz.check('filters combine (event + org type + 7d)',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_activity => 'Order placed', p_org_type => 'pharmacy', p_range => '7d', p_limit => 200) WHERE activity <> 'Order placed' OR organization NOT IN (SELECT name FROM public.businesses WHERE type='pharmacy')$q$) = 0);

  -- keyset with a filter: no duplicates and still correct
  PERFORM set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  ids := '{}'; cur_ts := NULL; cur_id := NULL;
  FOR i IN 1..20 LOOP
    SELECT array_agg(t.id ORDER BY t.created_at DESC, t.id DESC) INTO batch
    FROM public.admin_list_activity(p_activity => 'Order placed', p_limit => 40, p_cursor_created_at => cur_ts, p_cursor_id => cur_id) t;
    ids := ids || batch[1:40];
    cur_id := batch[40];
    SELECT created_at INTO cur_ts FROM public.audit_logs WHERE id = cur_id;
  END LOOP;
  EXECUTE 'RESET ROLE';
  SELECT array_agg(id ORDER BY created_at DESC, id DESC) INTO ref FROM (SELECT id, created_at FROM public.audit_logs WHERE activity = 'Order placed' ORDER BY created_at DESC, id DESC LIMIT 800) x;
  PERFORM zz.check('keyset + filter: 20 pages of 40 equal the plain filtered ORDER BY, no duplicates', ids = ref AND (SELECT count(DISTINCT x) FROM unnest(ids) x) = 800);

  -- ===== redaction =====
  PERFORM zz.check('redaction: list never returns a secret value',
    zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'REF-1000', p_limit => 200) WHERE details::text LIKE '%SECRET-%'$q$) = 0
    AND zz.count_as(u_admin, $q$SELECT 1 FROM public.admin_list_activity(p_search => 'REF-1000', p_limit => 200) WHERE details::text LIKE '%[redacted]%'$q$) > 0);
  PERFORM zz.check('redaction: nested keys and detail drawer are redacted too',
    zz.count_as(u_admin, format($q$SELECT 1 FROM public.admin_get_activity(%L) WHERE details::text LIKE '%%SECRET-%%'$q$, (SELECT id FROM public.audit_logs WHERE details ? 'access_token' LIMIT 1))) = 0
    AND zz.count_as(u_admin, format($q$SELECT 1 FROM public.admin_get_activity(%L) WHERE ip_address IS NOT NULL$q$, (SELECT id FROM public.audit_logs WHERE details ? 'access_token' LIMIT 1))) = 1);
  PERFORM zz.check('redaction: stored audit record is untouched (append-only source keeps the original)',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE details->>'access_token' LIKE 'SECRET-TOKEN-%'));

  -- ===== summary =====
  PERFORM zz.check('summary: KPI shape and values come from the database',
    (SELECT (s->'pharmacies'->>'total')::int = (SELECT count(*) FROM public.businesses WHERE type='pharmacy')
        AND (s->>'orders_total')::int = (SELECT count(*) FROM public.orders)
     FROM (SELECT set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role','authenticated')::text, true), public.admin_platform_summary() s) q));
END $$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok ORDER BY seq;
