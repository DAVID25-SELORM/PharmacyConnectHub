-- Online payments, P4b (amendments on an order paid online: refund of what it no longer costs, top-up of what it now costs more): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
WITH
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  cols AS (SELECT table_name::text AS t, column_name::text AS c FROM information_schema.columns WHERE table_schema = 'public'),
  checks(item, ok) AS (VALUES
  ('column order_payment_attempts.purpose', EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'purpose')),
  ('only the paying order attempt is limited to one', EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'order_payment_attempts_one_success' AND indexdef LIKE '%purpose%')),
  ('function order_is_online', EXISTS (SELECT 1 FROM fns WHERE name = 'order_is_online')),
  ('function order_money', EXISTS (SELECT 1 FROM fns WHERE name = 'order_money')),
  ('function order_topup_due_minor', EXISTS (SELECT 1 FROM fns WHERE name = 'order_topup_due_minor')),
  ('function begin_order_topup', EXISTS (SELECT 1 FROM fns WHERE name = 'begin_order_topup')),
  ('function _apply_topup_success', EXISTS (SELECT 1 FROM fns WHERE name = '_apply_topup_success')),
  ('function flag_unrefunded_balances', EXISTS (SELECT 1 FROM fns WHERE name = 'flag_unrefunded_balances')),
  ('function admin_request_balance_refund', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_request_balance_refund')),
  ('trigger trg_orders_effective_total_money', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_orders_effective_total_money')),
  ('trigger trg_block_dispatch_topup_due', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_block_dispatch_topup_due')),
  ('trigger trg_refuse_backorder_on_online_order', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_refuse_backorder_on_online_order')),
  ('amendments are allowed on an order paid online', EXISTS (SELECT 1 FROM fns WHERE name = 'propose_partial_fulfilment' AND def LIKE '%AND NOT public.order_is_online(v_order.id)%')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'propose_price_amendment' AND def LIKE '%AND NOT public.order_is_online(v_order.id)%')
    AND EXISTS (SELECT 1 FROM fns WHERE name = 'respond_to_price_amendment' AND def LIKE '%AND NOT public.order_is_online(v_order.id)%')),
  ('a delivery credit is allowed and marked so its refund waits for an administrator', EXISTS (SELECT 1 FROM fns WHERE name = 'resolve_delivery_report' AND def LIKE '%AND NOT public.order_is_online(v_order.id)%' AND def LIKE '%drugxone.refund_reason%')),
  ('an extra payment is judged on its own rules', EXISTS (SELECT 1 FROM fns WHERE name = 'apply_payment_result' AND def LIKE '%public._apply_topup_success(%' AND def LIKE '%v_a.purpose = ''top_up'' AND v_a.status IN%')),
  ('the return page check knows about extra payments', EXISTS (SELECT 1 FROM fns WHERE name = 'payment_attempts_to_check' AND def LIKE '%topup_due%')),
  ('the extra-payment and balance functions are for the server only',
    (to_regprocedure('public.begin_order_topup(uuid,uuid,text,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.begin_order_topup(uuid,uuid,text,text,text)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.begin_order_topup(uuid,uuid,text,text,text)', 'EXECUTE'))
    AND (to_regprocedure('public.order_money(uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.order_money(uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.admin_request_balance_refund(uuid,uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.admin_request_balance_refund(uuid,uuid)', 'EXECUTE')))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       CASE WHEN to_regclass('public.order_payment_attempts') IS NULL OR NOT EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'purpose') THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.order_payment_attempts WHERE purpose = ''top_up''', false, true, '')))[1]::text::int END AS top_up_attempts
FROM checks;
