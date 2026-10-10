-- Online payments, P1 (the provider-neutral core): read-only verification. One row; passed should equal checks and "missing" should be empty.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog.
WITH
  tbls AS (SELECT table_name::text AS name FROM information_schema.tables WHERE table_schema = 'public'),
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  idxs AS (SELECT indexname::text AS name FROM pg_indexes WHERE schemaname = 'public'),
  checks(item, ok) AS (VALUES
  ('table payment_provider_events', EXISTS (SELECT 1 FROM tbls WHERE name = 'payment_provider_events')),
  ('table order_payment_attempts', EXISTS (SELECT 1 FROM tbls WHERE name = 'order_payment_attempts')),
  ('table order_payment_log', EXISTS (SELECT 1 FROM tbls WHERE name = 'order_payment_log')),
  ('function record_payment_provider_event', EXISTS (SELECT 1 FROM fns WHERE name = 'record_payment_provider_event')),
  ('function finish_payment_provider_event', EXISTS (SELECT 1 FROM fns WHERE name = 'finish_payment_provider_event')),
  ('function apply_payment_result', EXISTS (SELECT 1 FROM fns WHERE name = 'apply_payment_result')),
  ('function payment_minor_from_ghs', EXISTS (SELECT 1 FROM fns WHERE name = 'payment_minor_from_ghs')),
  ('function flag_refund_when_paid_online_order_cancelled', EXISTS (SELECT 1 FROM fns WHERE name = 'flag_refund_when_paid_online_order_cancelled')),
  ('trigger trg_payment_provider_events_protect', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_payment_provider_events_protect')),
  ('trigger trg_order_payment_attempts_protect', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_order_payment_attempts_protect')),
  ('trigger trg_order_payment_log_append_only', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_order_payment_log_append_only')),
  ('trigger trg_flag_refund_when_paid_online_order_cancelled', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_flag_refund_when_paid_online_order_cancelled')),
  ('index order_payment_attempts_one_success', EXISTS (SELECT 1 FROM idxs WHERE name = 'order_payment_attempts_one_success')),
  ('apply_payment_result checks the amount and double payments', EXISTS (SELECT 1 FROM fns WHERE name = 'apply_payment_result' AND def LIKE '%amount_mismatch%' AND def LIKE '%already_paid%')),
  ('apply_payment_result is not callable by signed-in users or anonymous visitors',
    NOT has_function_privilege('authenticated', 'public.apply_payment_result(text,text,text,text,bigint,text,text,text,bigint,text,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.apply_payment_result(text,text,text,text,bigint,text,text,text,bigint,text,uuid,text)', 'EXECUTE')),
  ('the payment tables hold no rows yet (P1 has no screen)', (SELECT count(*) FROM public.order_payment_attempts) = 0)
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing FROM checks;
