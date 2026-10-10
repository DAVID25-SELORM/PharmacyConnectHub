-- Online payments, P4a (the refund ledger and moving money back): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- The last three columns are information: while online payments are not in use they should read 0, 0 and false.
WITH
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  cols AS (SELECT table_name::text AS t, column_name::text AS c FROM information_schema.columns WHERE table_schema = 'public'),
  checks(item, ok) AS (VALUES
  ('table order_refunds', EXISTS (SELECT 1 FROM cols WHERE t = 'order_refunds' AND c = 'source_key')),
  ('column payments_settings.auto_refunds', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'auto_refunds')),
  ('trigger trg_order_refunds_protect', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_order_refunds_protect')),
  ('trigger trg_order_refunds_cap', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_order_refunds_cap')),
  ('trigger trg_payment_attempt_refund_request', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_payment_attempt_refund_request')),
  ('alerts know the refund kinds', EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_alerts_kind_check' AND pg_get_constraintdef(oid) LIKE '%refund_stuck%' AND pg_get_constraintdef(oid) LIKE '%refund_unmatched%')),
  ('function _request_refund', EXISTS (SELECT 1 FROM fns WHERE name = '_request_refund')),
  ('function _complete_refund', EXISTS (SELECT 1 FROM fns WHERE name = '_complete_refund')),
  ('function refunds_to_submit', EXISTS (SELECT 1 FROM fns WHERE name = 'refunds_to_submit')),
  ('function claim_refund_for_submission', EXISTS (SELECT 1 FROM fns WHERE name = 'claim_refund_for_submission')),
  ('function record_refund_submission', EXISTS (SELECT 1 FROM fns WHERE name = 'record_refund_submission')),
  ('function record_refund_rejection', EXISTS (SELECT 1 FROM fns WHERE name = 'record_refund_rejection')),
  ('function apply_refund_event', EXISTS (SELECT 1 FROM fns WHERE name = 'apply_refund_event')),
  ('function admin_refund_transition', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_refund_transition')),
  ('function flag_stale_refunds', EXISTS (SELECT 1 FROM fns WHERE name = 'flag_stale_refunds')),
  ('the claim lets exactly one worker take a refund', EXISTS (SELECT 1 FROM fns WHERE name = 'claim_refund_for_submission' AND def LIKE '%FOR UPDATE SKIP LOCKED%')),
  ('an uncertain send is never retried by the system', EXISTS (SELECT 1 FROM fns WHERE name = 'record_refund_rejection' AND def LIKE '%_refund_unknown%')),
  ('refunds can never exceed the payment (function and trigger)', EXISTS (SELECT 1 FROM fns WHERE name = '_request_refund' AND def LIKE '%cannot add up to more%')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'order_refunds_cap' AND def LIKE '%cannot add up to more%')),
  ('the order summary shows refunds and the admin overview lists them', EXISTS (SELECT 1 FROM fns WHERE name = 'order_payment_summary' AND def LIKE '%refunded_ghs%')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'admin_payment_overview' AND def LIKE '%auto_refunds%')),
  ('the refund ledger cannot be written through the API', NOT has_table_privilege('authenticated', 'public.order_refunds', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.order_refunds', 'INSERT') AND NOT has_table_privilege('anon', 'public.order_refunds', 'SELECT')),
  ('the refund functions are for the server only',
    (to_regprocedure('public.admin_refund_transition(uuid,uuid,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.admin_refund_transition(uuid,uuid,text,text)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.admin_refund_transition(uuid,uuid,text,text)', 'EXECUTE'))
    AND (to_regprocedure('public.claim_refund_for_submission(uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.claim_refund_for_submission(uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.apply_refund_event(text,text,text,text,text,bigint)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.apply_refund_event(text,text,text,text,text,bigint)', 'EXECUTE'))
    AND (to_regprocedure('public.refunds_to_submit(integer)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.refunds_to_submit(integer)', 'EXECUTE'))),
  ('automatic refunds are OFF', COALESCE((SELECT NOT auto_refunds FROM public.payments_settings WHERE id), FALSE))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       CASE WHEN to_regclass('public.order_refunds') IS NULL THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.order_refunds', false, true, '')))[1]::text::int END AS refunds,
       CASE WHEN to_regclass('public.order_refunds') IS NULL THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.order_refunds WHERE status IN (''requested'', ''approved'', ''submitting'', ''processing'', ''unknown'', ''failed'')', false, true, '')))[1]::text::int END AS open_refunds,
       (SELECT auto_refunds FROM public.payments_settings WHERE id) AS auto_refunds
FROM checks;
