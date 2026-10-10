-- Online payments, P5 (settlement and going live): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
WITH
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT tgname::text AS name FROM pg_trigger WHERE NOT tgisinternal),
  cols AS (SELECT table_name::text AS t, column_name::text AS c FROM information_schema.columns WHERE table_schema = 'public'),
  checks(item, ok) AS (VALUES
  ('settings: split_mode', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'split_mode')),
  ('settings: platform_fee_bps', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'platform_fee_bps')),
  ('settings: fee_bearer', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'fee_bearer')),
  ('settings: max_order_ghs', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'max_order_ghs')),
  ('settings: split_refunds_confirmed', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'split_refunds_confirmed')),
  ('settings: reconciler timestamps', EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'reconciler_frequent_at') AND EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'reconciler_daily_at')),
  ('table supplier_payout_accounts', to_regclass('public.supplier_payout_accounts') IS NOT NULL),
  ('attempts: split columns and prepared_at', EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'split_subaccount') AND EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'split_charge_minor')
     AND EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'split_bearer') AND EXISTS (SELECT 1 FROM cols WHERE t = 'order_payment_attempts' AND c = 'prepared_at')),
  ('a payment''s split cannot be changed', EXISTS (SELECT 1 FROM fns WHERE name = 'order_payment_attempts_protect' AND def LIKE '%How a payment was split cannot be changed%')),
  ('function prepare_attempt_for_provider', EXISTS (SELECT 1 FROM fns WHERE name = 'prepare_attempt_for_provider')),
  ('function payout_account_ready', EXISTS (SELECT 1 FROM fns WHERE name = 'payout_account_ready')),
  ('function suppliers_ready_for_online_payment', EXISTS (SELECT 1 FROM fns WHERE name = 'suppliers_ready_for_online_payment')),
  ('functions begin/finish payout account, admin_set_payout_account_status, admin_payout_accounts',
     EXISTS (SELECT 1 FROM fns WHERE name = 'begin_payout_account') AND EXISTS (SELECT 1 FROM fns WHERE name = 'finish_payout_account')
     AND EXISTS (SELECT 1 FROM fns WHERE name = 'admin_set_payout_account_status') AND EXISTS (SELECT 1 FROM fns WHERE name = 'admin_payout_accounts')),
  ('functions record_reconciler_run, payments_readiness, admin_settlement_report',
     EXISTS (SELECT 1 FROM fns WHERE name = 'record_reconciler_run') AND EXISTS (SELECT 1 FROM fns WHERE name = 'payments_readiness') AND EXISTS (SELECT 1 FROM fns WHERE name = 'admin_settlement_report')),
  ('trigger trg_payments_settings_live_guard', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_payments_settings_live_guard')),
  ('trigger trg_supplier_payout_accounts_protect', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_supplier_payout_accounts_protect')),
  ('a checkout payment is checked before the provider', EXISTS (SELECT 1 FROM fns WHERE name = 'record_attempt_authorization' AND def LIKE '%has not been checked against the platform%')),
  ('a refund of a split payment waits for a person until confirmed', EXISTS (SELECT 1 FROM fns WHERE name = '_request_refund' AND def LIKE '%split_refunds_confirmed%')),
  ('checkout refuses a supplier that cannot take online payments', EXISTS (SELECT 1 FROM fns WHERE name = 'create_marketplace_orders' AND def LIKE '%payout_account_ready(m.key%')),
  ('online payments status carries the limit', EXISTS (SELECT 1 FROM fns WHERE name = 'online_payments_status' AND def LIKE '%max_order_ghs%')),
  ('the server-only functions are server-only',
    (to_regprocedure('public.prepare_attempt_for_provider(uuid)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.prepare_attempt_for_provider(uuid)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.prepare_attempt_for_provider(uuid)', 'EXECUTE'))
    AND (to_regprocedure('public.begin_payout_account(uuid,uuid,text,text,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.begin_payout_account(uuid,uuid,text,text,text,text)', 'EXECUTE'))
    AND (to_regprocedure('public.record_reconciler_run(text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.record_reconciler_run(text)', 'EXECUTE'))
    AND (to_regprocedure('public.payout_account_ready(uuid,text,text)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.payout_account_ready(uuid,text,text)', 'EXECUTE'))),
  ('payout accounts cannot be read by pharmacies and suppliers',
    to_regclass('public.supplier_payout_accounts') IS NOT NULL AND EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'supplier_payout_accounts' AND policyname = 'Admins read payout accounts'))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       CASE WHEN to_regclass('public.payments_settings') IS NULL OR NOT EXISTS (SELECT 1 FROM cols WHERE t = 'payments_settings' AND c = 'split_mode') THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT split_mode AS c FROM public.payments_settings', false, true, '')))[1]::text END AS split_mode,
       CASE WHEN to_regclass('public.supplier_payout_accounts') IS NULL THEN NULL
            ELSE (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.supplier_payout_accounts', false, true, '')))[1]::text::int END AS payout_accounts,
       (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'create_marketplace_orders') AS checkout_versions
FROM checks;
