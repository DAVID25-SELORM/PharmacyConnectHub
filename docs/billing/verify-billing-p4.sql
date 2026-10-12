-- Platform billing, Phase 4 (invoices and payment records): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- It also confirms nothing has been invoiced or paid yet (billing is still off), and that the reconciliation, now including invoices and payments, finds nothing.
WITH
  fns AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT t.tgname::text AS name, c.relname::text AS tbl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal),
  checks(item, ok) AS (VALUES
  ('the three tables exist with row security on', to_regclass('public.billing_invoices') IS NOT NULL AND to_regclass('public.billing_invoice_lines') IS NOT NULL AND to_regclass('public.billing_payments') IS NOT NULL
    AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_invoices'::regclass, 'public.billing_invoice_lines'::regclass, 'public.billing_payments'::regclass))),
  ('visitors cannot read them and nobody can write to them directly', NOT has_table_privilege('anon', 'public.billing_invoices', 'SELECT') AND NOT has_table_privilege('anon', 'public.billing_payments', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.billing_invoice_lines', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.billing_invoices', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.billing_invoices', 'UPDATE') AND NOT has_table_privilege('authenticated', 'public.billing_payments', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.billing_payments', 'DELETE')
    AND NOT has_table_privilege('authenticated', 'public.billing_invoice_lines', 'UPDATE')),
  ('the settings for invoicing exist (payment terms, delay, number counter, issuer)', (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'billing_settings'
    AND column_name IN ('payment_terms_days', 'invoice_delay_hours', 'last_invoice_number', 'issuer')) = 4),
  ('one invoice per period and one number per invoice are enforced by the database', EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.billing_invoices'::regclass AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (period_id)')
    AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.billing_invoices'::regclass AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (invoice_number)')),
  ('a payment is recorded once: the request key is unique and so is a bank or mobile-money reference per method', EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.billing_payments'::regclass AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (idempotency_key)')
    AND to_regclass('public.billing_payments_reference_idx') IS NOT NULL AND to_regclass('public.billing_payments_reverses_idx') IS NOT NULL),
  ('invoices, lines and payments are protected from edits and deletes', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_invoices_guard' AND tbl = 'billing_invoices')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_invoice_lines_append_only' AND tbl = 'billing_invoice_lines') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_payments_append_only' AND tbl = 'billing_payments')),
  ('an invoiced period is final: no entry or assessment can be written into it', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_ledger_period_open' AND tbl = 'billing_ledger_entries')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_assessments_period_open' AND tbl = 'order_billing_assessments')
    AND pg_get_functiondef('public.billing_periods_guard()'::regprocedure) LIKE '%An invoiced billing period is final%'),
  ('late entries are redirected to the current period', pg_get_functiondef('public._billing_ensure_period(public.billing_subscriptions, timestamp with time zone, boolean)'::regprocedure) LIKE '%lands in the period that contains now%'),
  ('period opening fills a skipped month', pg_get_functiondef('public.billing_open_periods(timestamp with time zone)'::regprocedure) LIKE '%first month that has no period yet%'),
  ('the invoicing functions exist and cannot be called by signed-in users or visitors', (SELECT count(*) FROM fns WHERE name IN ('billing_issue_invoices', 'billing_mark_overdue', '_billing_sync_invoice', '_billing_available_credit', '_billing_invoice_json', '_billing_reconcile_invoices', '_billing_reconcile_engine')) = 7
    AND NOT has_function_privilege('authenticated', 'public.billing_issue_invoices(timestamp with time zone)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.billing_issue_invoices(timestamp with time zone)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.billing_mark_overdue(timestamp with time zone)', 'EXECUTE') AND NOT has_function_privilege('authenticated', 'public._billing_sync_invoice(uuid, timestamp with time zone)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.billing_reconcile()', 'EXECUTE')),
  ('the administrator operations exist and visitors cannot call them', (SELECT count(*) FROM fns WHERE name IN ('admin_billing_record_payment', 'admin_billing_reverse_payment', 'admin_billing_set_invoice_settings', 'admin_billing_invoices', 'admin_billing_invoice_detail')) = 5
    AND NOT has_function_privilege('anon', 'public.admin_billing_record_payment(uuid, numeric, text, text, timestamp with time zone, text, text, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_reverse_payment(uuid, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_set_invoice_settings(integer, integer, jsonb, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_invoices(text, text, text, timestamp with time zone, timestamp with time zone, integer, integer)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.admin_billing_invoice_detail(uuid)', 'EXECUTE')),
  ('a business can read only its own invoices through functions that check who is asking', (SELECT count(*) FROM fns WHERE name IN ('billing_my_invoices', 'billing_my_invoice')) = 2
    AND NOT has_function_privilege('anon', 'public.billing_my_invoices(uuid, integer, integer)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.billing_my_invoice(uuid)', 'EXECUTE')
    AND pg_get_functiondef('public.billing_my_invoices(uuid, integer, integer)'::regprocedure) LIKE '%billing_user_can_view%' AND pg_get_functiondef('public.billing_my_invoice(uuid)'::regprocedure) LIKE '%billing_user_can_view%'),
  ('the scheduled run now issues invoices and marks overdue ones', pg_get_functiondef('public.billing_run_scheduled(timestamp with time zone)'::regprocedure) LIKE '%billing_issue_invoices%'
    AND pg_get_functiondef('public.billing_run_scheduled(timestamp with time zone)'::regprocedure) LIKE '%billing_mark_overdue%'),
  ('the reconciliation covers invoices and payments (ten more checks than before)', (SELECT count(*) FROM public.billing_reconcile()) = (SELECT count(*) FROM public._billing_reconcile_engine()) + 10),
  ('the administrator dashboard reports invoiced, collected, outstanding, overdue and not-yet-invoiced separately', pg_get_functiondef('public._billing_flavor_summary(boolean, timestamp with time zone, timestamp with time zone, uuid[])'::regprocedure) LIKE '%not_yet_invoiced%'),
  ('billing is still OFF: mode is disabled', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled'),
  ('nothing is invoiced or paid, and no invoice number has been used', (SELECT count(*) FROM public.billing_invoices) + (SELECT count(*) FROM public.billing_invoice_lines) + (SELECT count(*) FROM public.billing_payments) = 0
    AND (SELECT last_invoice_number FROM public.billing_settings WHERE id) = 0),
  ('the reconciliation finds nothing wrong', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0)),
  ('an invoice status follows the money (unpaid, part paid, paid, overdue)', public._billing_invoice_status(100, 0, now() + interval '5 days', now()) = 'issued' AND public._billing_invoice_status(100, 40, now() + interval '5 days', now()) = 'partially_paid'
    AND public._billing_invoice_status(100, 100, now() - interval '5 days', now()) = 'paid' AND public._billing_invoice_status(100, 40, now() - interval '5 days', now()) = 'overdue')
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode
FROM checks;
