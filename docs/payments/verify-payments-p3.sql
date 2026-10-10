-- Online payments, P3 (alerts, checking attempts with the provider, expiry, the daily comparison, the admin views): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- The last two columns are information: while online payments are not in use both should read 0.
WITH
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  cols AS (SELECT table_name::text AS t, column_name::text AS c FROM information_schema.columns WHERE table_schema = 'public'),
  checks(item, ok) AS (VALUES
  ('table payment_alerts', EXISTS (SELECT 1 FROM cols WHERE t = 'payment_alerts' AND c = 'dedupe_key')),
  ('column order_payment_attempts.last_checked_at', EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'last_checked_at')),
  ('column order_payment_attempts.check_requested_at', EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'check_requested_at')),
  ('index payment_alerts_one_open', EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'payment_alerts_one_open')),
  ('trigger trg_payment_alerts_protect', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_payment_alerts_protect')),
  ('trigger trg_payment_attempt_alerts', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_payment_attempt_alerts')),
  ('function _raise_payment_alert', EXISTS (SELECT 1 FROM fns WHERE name = '_raise_payment_alert')),
  ('function report_payment_job_problem', EXISTS (SELECT 1 FROM fns WHERE name = 'report_payment_job_problem')),
  ('function mark_attempt_checked', EXISTS (SELECT 1 FROM fns WHERE name = 'mark_attempt_checked')),
  ('function payment_attempts_due_for_check', EXISTS (SELECT 1 FROM fns WHERE name = 'payment_attempts_due_for_check')),
  ('function close_stale_payment_attempts', EXISTS (SELECT 1 FROM fns WHERE name = 'close_stale_payment_attempts')),
  ('function expire_unpaid_online_orders', EXISTS (SELECT 1 FROM fns WHERE name = 'expire_unpaid_online_orders')),
  ('function reconcile_provider_transactions', EXISTS (SELECT 1 FROM fns WHERE name = 'reconcile_provider_transactions')),
  ('function admin_payment_overview', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_payment_overview')),
  ('function admin_resolve_payment_alert', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_resolve_payment_alert')),
  ('function admin_attempts_to_reverify', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_attempts_to_reverify')),
  ('expiry never cancels an order whose attempts were not checked recently', EXISTS (SELECT 1 FROM fns WHERE name = 'expire_unpaid_online_orders' AND def LIKE '%FOR UPDATE SKIP LOCKED%' AND def LIKE '%interval ''15 minutes''%')),
  ('the return page check is throttled', EXISTS (SELECT 1 FROM fns WHERE name = 'payment_attempts_to_check' AND def LIKE '%check_requested_at%')),
  ('alerts cannot be written through the API', NOT has_table_privilege('authenticated', 'public.payment_alerts', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.payment_alerts', 'INSERT') AND NOT has_table_privilege('anon', 'public.payment_alerts', 'SELECT')),
  ('the expiry, comparison and checking functions are for the server only',
    (to_regprocedure('public.expire_unpaid_online_orders(integer,integer,integer)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.expire_unpaid_online_orders(integer,integer,integer)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.expire_unpaid_online_orders(integer,integer,integer)', 'EXECUTE'))
    AND (to_regprocedure('public.reconcile_provider_transactions(text,text,timestamptz,timestamptz,jsonb,boolean,boolean)') IS NOT NULL
      AND NOT has_function_privilege('authenticated', 'public.reconcile_provider_transactions(text,text,timestamptz,timestamptz,jsonb,boolean,boolean)', 'EXECUTE'))
    AND (to_regprocedure('public.mark_attempt_checked(uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.mark_attempt_checked(uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.payment_attempts_due_for_check(integer,integer,integer)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.payment_attempts_due_for_check(integer,integer,integer)', 'EXECUTE'))),
  ('the admin views are callable by signed-in users (they check for an administrator themselves) and not by visitors',
    (to_regprocedure('public.admin_payment_overview()') IS NOT NULL AND has_function_privilege('authenticated', 'public.admin_payment_overview()', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.admin_payment_overview()', 'EXECUTE'))
    AND (to_regprocedure('public.admin_resolve_payment_alert(uuid,text)') IS NOT NULL AND has_function_privilege('authenticated', 'public.admin_resolve_payment_alert(uuid,text)', 'EXECUTE')
         AND NOT has_function_privilege('anon', 'public.admin_resolve_payment_alert(uuid,text)', 'EXECUTE')))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       CASE WHEN to_regclass('public.order_payment_attempts') IS NULL THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.order_payment_attempts', false, true, '')))[1]::text::int END AS payment_attempts,
       CASE WHEN to_regclass('public.payment_alerts') IS NULL THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.payment_alerts', false, true, '')))[1]::text::int END AS payment_alerts
FROM checks;
