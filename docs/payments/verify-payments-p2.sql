-- Online payments, P2 (starting a payment, Pay now at checkout behind the platform switch): read-only verification. Run it in the SQL Editor of the
-- PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and the switch row; it changes nothing.
-- One row: passed should equal checks and "missing" should be empty. The two switch columns are information, not checks: while online payments are
-- not in use they should read  online_enabled = false  and  online_orders = 0.
WITH
  tbls AS (SELECT table_name::text AS name FROM information_schema.tables WHERE table_schema = 'public'),
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  checks(item, ok) AS (VALUES
  ('table payments_settings', EXISTS (SELECT 1 FROM tbls WHERE name = 'payments_settings')),
  ('payments_settings holds exactly one row', (SELECT count(*) FROM public.payments_settings) = 1),
  ('payments_settings cannot be written through the API', NOT has_table_privilege('authenticated', 'public.payments_settings', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.payments_settings', 'INSERT') AND NOT has_table_privilege('anon', 'public.payments_settings', 'SELECT')),
  ('function online_payments_enabled', EXISTS (SELECT 1 FROM fns WHERE name = 'online_payments_enabled')),
  ('function online_payments_status', EXISTS (SELECT 1 FROM fns WHERE name = 'online_payments_status')),
  ('function begin_order_payment', EXISTS (SELECT 1 FROM fns WHERE name = 'begin_order_payment')),
  ('function record_attempt_authorization', EXISTS (SELECT 1 FROM fns WHERE name = 'record_attempt_authorization')),
  ('function fail_payment_attempt', EXISTS (SELECT 1 FROM fns WHERE name = 'fail_payment_attempt')),
  ('function payment_attempts_to_check', EXISTS (SELECT 1 FROM fns WHERE name = 'payment_attempts_to_check')),
  ('function order_payment_summary', EXISTS (SELECT 1 FROM fns WHERE name = 'order_payment_summary')),
  ('function block_accept_unpaid_online_order', EXISTS (SELECT 1 FROM fns WHERE name = 'block_accept_unpaid_online_order')),
  ('trigger trg_block_accept_unpaid_online_order', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_block_accept_unpaid_online_order')),
  ('begin_order_payment is not callable by signed-in users or anonymous visitors',
    (to_regprocedure('public.begin_order_payment(uuid,uuid,text,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.begin_order_payment(uuid,uuid,text,text,text)', 'EXECUTE'))
    AND (to_regprocedure('public.begin_order_payment(uuid,uuid,text,text,text)') IS NOT NULL AND NOT has_function_privilege('anon', 'public.begin_order_payment(uuid,uuid,text,text,text)', 'EXECUTE'))),
  ('the other payment-start functions are not callable by signed-in users or anonymous visitors',
    (to_regprocedure('public.record_attempt_authorization(uuid,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.record_attempt_authorization(uuid,text,text)', 'EXECUTE'))
    AND (to_regprocedure('public.fail_payment_attempt(uuid,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.fail_payment_attempt(uuid,text)', 'EXECUTE'))
    AND (to_regprocedure('public.payment_attempts_to_check(uuid,uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.payment_attempts_to_check(uuid,uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.order_payment_summary(uuid)') IS NOT NULL AND NOT has_function_privilege('anon', 'public.order_payment_summary(uuid)', 'EXECUTE'))),
  ('signed-in users can read the payment summary of their own orders and ask whether online payment is on',
    (to_regprocedure('public.order_payment_summary(uuid)') IS NOT NULL AND has_function_privilege('authenticated', 'public.order_payment_summary(uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.online_payments_status()') IS NOT NULL AND has_function_privilege('authenticated', 'public.online_payments_status()', 'EXECUTE'))),
  ('checkout accepts Pay now only while the switch is on',
    EXISTS (SELECT 1 FROM fns WHERE name = 'create_marketplace_orders' AND def LIKE '%AND NOT public.online_payments_enabled()%'
      AND def LIKE '%THEN ''paystack'' ELSE ''cod'' END%' AND def LIKE '%m.value NOT IN (''pay_now''%')),
  ('the wholesaler is not told of an unpaid online order, only of the paid one',
    EXISTS (SELECT 1 FROM fns WHERE name = 'notify_new_order' AND def LIKE '%NEW.payment_method::TEXT = ''paystack'' THEN RETURN NEW%')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'notify_payment_status_changed' AND def LIKE '%New paid order%')),
  ('an online order keeps its payment method',
    EXISTS (SELECT 1 FROM fns WHERE name = 'change_order_settlement_method' AND def LIKE '%An online-payment order%')),
  ('a repeated failed or abandoned report is not logged again',
    EXISTS (SELECT 1 FROM fns WHERE name = 'apply_payment_result' AND def LIKE '%''repeat'', TRUE%'))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT online_enabled FROM public.payments_settings WHERE id) AS online_enabled,
       (SELECT mode FROM public.payments_settings WHERE id) AS mode,
       (SELECT count(*) FROM public.orders WHERE payment_method::text = 'paystack') AS online_orders
FROM checks;
