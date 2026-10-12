-- Platform billing, Phase 6 (going live, unpaid-invoice status, notices, monitoring): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- It also confirms that NOTHING has gone live: billing is still disabled, no business has a go-live date, no notice has been sent, and the restriction policy is off.
WITH
  fns AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT t.tgname::text AS name, c.relname::text AS tbl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal),
  admin_ops(sig) AS (VALUES
    ('admin_billing_readiness()'), ('admin_billing_activate_platform(boolean, text, text)'), ('admin_billing_go_live_business(uuid, timestamp with time zone, text)'),
    ('admin_billing_set_grace_days(integer, text)'), ('admin_billing_set_enforcement(text, text)'), ('admin_billing_set_notification_settings(jsonb, text)'),
    ('admin_billing_extend_grace(uuid, timestamp with time zone, text)'), ('admin_billing_rollout_status()')),
  internals(sig) AS (VALUES
    ('billing_restriction_level(uuid)'), ('billing_block_new_orders()'), ('_billing_notify_once(uuid, text, text, text, text)'), ('_billing_notify_admins_once(text, text, text)'),
    ('_billing_enforce_one(public.billing_subscriptions, timestamp with time zone)'), ('billing_advance_enforcement(timestamp with time zone)'),
    ('billing_send_notifications(timestamp with time zone)'), ('_billing_go_live(public.billing_subscriptions, timestamp with time zone)'), ('_billing_reconcile_rollout()')),
  checks(item, ok) AS (VALUES
  ('the new settings and subscription columns exist', (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'billing_settings' AND column_name IN ('enforcement', 'notifications', 'live_since')) = 3
    AND (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'billing_subscriptions' AND column_name IN ('past_due_since', 'grace_extended_until')) = 2),
  ('the two new tables exist with row security on, closed to visitors, with no direct writes', to_regclass('public.billing_notifications_sent') IS NOT NULL AND to_regclass('public.billing_run_status') IS NOT NULL
    AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_notifications_sent'::regclass, 'public.billing_run_status'::regclass))
    AND NOT has_table_privilege('anon', 'public.billing_notifications_sent', 'SELECT') AND NOT has_table_privilege('authenticated', 'public.billing_notifications_sent', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.billing_run_status', 'UPDATE')),
  ('a notice is recorded once per event (the event key is unique) and a record cannot be deleted', EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.billing_notifications_sent'::regclass AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (event_key)')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_notifications_sent_append_only' AND tbl = 'billing_notifications_sent')),
  ('all eight administrator operations exist; visitors cannot call them; signed-in users can (each checks for an administrator itself)', (SELECT count(*) FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL) = 8
    AND NOT EXISTS (SELECT 1 FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL AND has_function_privilege('anon', 'public.' || o.sig, 'EXECUTE'))
    AND NOT EXISTS (SELECT 1 FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.' || o.sig, 'EXECUTE'))),
  ('the nine internal functions exist and cannot be called by signed-in users or visitors', (SELECT count(*) FROM internals i WHERE to_regprocedure('public.' || i.sig) IS NOT NULL) = 9
    AND NOT EXISTS (SELECT 1 FROM internals i WHERE to_regprocedure('public.' || i.sig) IS NOT NULL AND (has_function_privilege('authenticated', 'public.' || i.sig, 'EXECUTE') OR has_function_privilege('anon', 'public.' || i.sig, 'EXECUTE')))),
  ('the plain mode switch no longer turns real billing on (the checklist does)', pg_get_functiondef('public.admin_billing_set_mode(text, text)'::regprocedure) LIKE '%activation checklist%'
    AND pg_get_functiondef('public.admin_billing_set_mode(text, text)'::regprocedure) LIKE '%cannot go back to shadow%'),
  ('activation needs the typed confirmation and the readiness checks', pg_get_functiondef('public.admin_billing_activate_platform(boolean, text, text)'::regprocedure) LIKE '%ACTIVATE BILLING%'
    AND pg_get_functiondef('public.admin_billing_activate_platform(boolean, text, text)'::regprocedure) LIKE '%admin_billing_readiness%'),
  ('real billing never looks back: period opening starts at the go-live moment, and a new subscription cannot start in the past once live', pg_get_functiondef('public.billing_open_periods(timestamp with time zone)'::regprocedure) LIKE '%Real billing never looks back%'
    AND pg_get_functiondef('public.admin_billing_start_subscription(uuid, text, timestamp with time zone, text, text)'::regprocedure) LIKE '%no historical order is ever charged%'),
  ('the only place a billing status can stop anything is a guard on NEW orders, which lets an order through if the check itself fails', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_orders_billing_block_new' AND tbl = 'orders')
    AND pg_get_functiondef('public.billing_block_new_orders()'::regprocedure) LIKE '%EXCEPTION WHEN OTHERS%'),
  ('the scheduled run records that it ran and applies account status and notices', pg_get_functiondef('public.billing_run_scheduled(timestamp with time zone)'::regprocedure) LIKE '%billing_run_status%'
    AND pg_get_functiondef('public.billing_run_scheduled(timestamp with time zone)'::regprocedure) LIKE '%billing_advance_enforcement%' AND pg_get_functiondef('public.billing_run_scheduled(timestamp with time zone)'::regprocedure) LIKE '%billing_send_notifications%'),
  ('the reconciliation includes the rollout checks (five more)', (SELECT count(*) FROM public.billing_reconcile()) = (SELECT count(*) FROM public._billing_reconcile_engine()) + (SELECT count(*) FROM public._billing_reconcile_invoices())
    + (SELECT count(*) FROM public._billing_reconcile_controls()) + (SELECT count(*) FROM public._billing_reconcile_rollout()) AND (SELECT count(*) FROM public._billing_reconcile_rollout()) = 5),
  ('billing is still OFF: mode is disabled, and the restriction policy is off', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled' AND (SELECT enforcement FROM public.billing_settings WHERE id) = 'none'),
  ('nothing has gone live: no activation date was ever recorded and no business has a go-live date', (SELECT live_since IS NULL FROM public.billing_settings WHERE id) AND NOT EXISTS (SELECT 1 FROM public.billing_subscriptions WHERE activated_at IS NOT NULL)),
  ('no notice has been sent and the run has never recorded a result', (SELECT count(*) FROM public.billing_notifications_sent) = 0 AND (SELECT runs FROM public.billing_run_status WHERE id) = 0),
  ('the notice settings hold all eleven keys and the grace period is a week', (SELECT count(*) FROM jsonb_object_keys((SELECT notifications FROM public.billing_settings WHERE id))) = 11 AND (SELECT grace_days FROM public.billing_settings WHERE id) = 7),
  ('the reconciliation finds nothing wrong', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode
FROM checks;
