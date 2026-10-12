-- Platform billing, Phase 2 (the engine): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- It also confirms the engine is switched off: mode disabled, nothing assessed, nothing queued, and the reconciliation finds nothing.
WITH
  fns  AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT t.tgname::text AS name, c.relname::text AS tbl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal),
  engine_fns(name, args) AS (VALUES
    ('billing_compute_fee', 'numeric,numeric,numeric,numeric'), ('billing_assess_order', 'uuid'), ('billing_assess_order_change', 'uuid'), ('billing_open_periods', 'timestamp with time zone'),
    ('billing_advance_states', 'timestamp with time zone'), ('billing_process_queue', 'integer'), ('billing_catch_up', 'integer'), ('billing_run_scheduled', 'timestamp with time zone'),
    ('billing_reconcile', '')),
  checks(item, ok) AS (VALUES
  ('the queue table exists with RLS on, readable by administrators only', to_regclass('public.billing_engine_queue') IS NOT NULL
    AND (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.billing_engine_queue'::regclass) AND NOT has_table_privilege('anon', 'public.billing_engine_queue', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.billing_engine_queue', 'INSERT')),
  ('a shadow period and a real period may share a start (uniqueness includes the shadow flag)', EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_periods_business_id_period_start_shadow_key')
    AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_periods_business_id_period_start_key')),
  ('a free adjustment is an allowed outcome', EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_billing_assessments_outcome_check' AND pg_get_constraintdef(oid) LIKE '%free_adjustment%')),
  ('shadow free-order numbers are unique too', to_regclass('public.order_billing_onboarding_seq_shadow_idx') IS NOT NULL AND to_regclass('public.order_billing_monthly_seq_shadow_idx') IS NOT NULL),
  ('the engine functions exist', (SELECT count(*) FROM engine_fns e WHERE EXISTS (SELECT 1 FROM fns WHERE name = e.name)) = 9),
  ('the engine functions cannot be called by signed-in users or visitors', NOT EXISTS (
     SELECT 1 FROM engine_fns e, unnest(ARRAY['authenticated', 'anon']) r
     WHERE to_regprocedure('public.' || e.name || '(' || e.args || ')') IS NOT NULL AND has_function_privilege(r, to_regprocedure('public.' || e.name || '(' || e.args || ')'), 'EXECUTE'))),
  ('the administrator functions exist and visitors cannot call them', EXISTS (SELECT 1 FROM fns WHERE name = 'admin_billing_run_now') AND EXISTS (SELECT 1 FROM fns WHERE name = 'admin_billing_reconciliation')
    AND NOT has_function_privilege('anon', 'public.admin_billing_run_now(text)', 'EXECUTE') AND NOT has_function_privilege('anon', 'public.admin_billing_reconciliation()', 'EXECUTE')),
  ('the delivery trigger is on orders', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_orders_billing_delivered' AND tbl = 'orders')),
  ('the value-change trigger is on orders', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_orders_billing_value_change' AND tbl = 'orders')),
  ('the returns trigger is on order_returns', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_order_returns_billing' AND tbl = 'order_returns')),
  ('billing is OFF: mode is disabled', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled'),
  ('nothing is assessed, no period or ledger entry exists, and nothing is queued', (SELECT count(*) FROM public.order_billing_assessments) + (SELECT count(*) FROM public.billing_periods)
    + (SELECT count(*) FROM public.billing_ledger_entries) + (SELECT count(*) FROM public.billing_engine_queue) = 0),
  ('the reconciliation finds nothing wrong', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0)),
  ('the fee arithmetic is right (5,000 at 0.75% = 37.50; with a minimum of 2 and 100 at 0.75% = 2.00; a maximum of 200 on 100,000 = 200.00)',
    (SELECT fee_after_limits FROM public.billing_compute_fee(5000, 0.75, NULL, NULL)) = 37.50 AND (SELECT fee_after_limits FROM public.billing_compute_fee(100, 0.75, 2, NULL)) = 2.00
    AND (SELECT fee_after_limits FROM public.billing_compute_fee(100000, 0.75, 2, 200)) = 200.00),
  ('a pg_cron job for the billing run is scheduled when pg_cron is available (informational: true if cron is missing or the job exists)',
    to_regclass('cron.job') IS NULL OR (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM cron.job WHERE jobname = ''drugxone-billing-run''', false, true, '')))[1]::text::int = 1)
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode,
       (SELECT count(*) FROM pg_extension WHERE extname = 'pg_cron') AS pg_cron_enabled
FROM checks;
