-- Platform billing, Phase 5 (administrator controls and promotions): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
-- It also confirms nothing has been used yet (no promotion, no temporary change, no administrator credit or grant), billing is still off, and the reconciliation finds nothing.
WITH
  fns AS (SELECT p.proname::text AS name FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  trgs AS (SELECT t.tgname::text AS name, c.relname::text AS tbl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal),
  admin_ops(sig) AS (VALUES
    ('admin_billing_extend_trial(uuid, timestamp with time zone, text)'), ('admin_billing_grant_free_orders(uuid, integer, timestamp with time zone, text, text)'),
    ('admin_billing_apply_credit(uuid, numeric, text, text, text)'), ('admin_billing_apply_charge(uuid, numeric, text, text)'), ('admin_billing_waive_fee(uuid, uuid, text)'),
    ('admin_billing_set_exemption(uuid, boolean, text)'), ('admin_billing_set_paused(uuid, boolean, text)'), ('admin_billing_set_cancellation(uuid, boolean, text)'),
    ('admin_billing_set_custom_terms(uuid, jsonb, timestamp with time zone, text)'), ('admin_billing_change_plan(uuid, text, timestamp with time zone, boolean, text)'),
    ('admin_billing_add_temporary_terms(uuid, jsonb, timestamp with time zone, timestamp with time zone, text)'), ('admin_billing_end_temporary_terms(uuid, text)'),
    ('admin_billing_create_promotion(text, text, text, text, jsonb, timestamp with time zone, timestamp with time zone, integer, text)'),
    ('admin_billing_set_promotion_active(uuid, boolean, text)'), ('admin_billing_apply_promotion(uuid, text, text)'), ('admin_billing_promotions()')),
  helpers(sig) AS (VALUES
    ('_billing_money(numeric)'), ('_billing_lock_subscription(uuid)'), ('_billing_open_real_period(public.billing_subscriptions)'),
    ('_billing_post_credit(public.billing_periods, text, numeric, text, text, uuid, uuid, jsonb)'), ('_billing_do_extend_trial(public.billing_subscriptions, timestamp with time zone, text)'),
    ('_billing_do_grant_orders(uuid, integer, text, text, text, timestamp with time zone)'), ('_billing_do_window(uuid, timestamp with time zone, timestamp with time zone, jsonb, text, uuid, text)'),
    ('billing_validate_overrides(jsonb, boolean)'), ('_billing_reconcile_controls()')),
  checks(item, ok) AS (VALUES
  ('the three tables exist with row security on', to_regclass('public.billing_term_windows') IS NOT NULL AND to_regclass('public.billing_promotions') IS NOT NULL AND to_regclass('public.billing_promotion_redemptions') IS NOT NULL
    AND (SELECT bool_and(relrowsecurity) FROM pg_class WHERE oid IN ('public.billing_term_windows'::regclass, 'public.billing_promotions'::regclass, 'public.billing_promotion_redemptions'::regclass))),
  ('visitors cannot read them and nobody can write to them directly', NOT has_table_privilege('anon', 'public.billing_promotions', 'SELECT') AND NOT has_table_privilege('anon', 'public.billing_term_windows', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.billing_promotions', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.billing_promotions', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.billing_term_windows', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.billing_promotion_redemptions', 'DELETE')),
  ('a promotion and its redemptions cannot be edited or deleted, and a temporary window can only be ended early', EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_promotions_guard' AND tbl = 'billing_promotions')
    AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_redemptions_append_only' AND tbl = 'billing_promotion_redemptions') AND EXISTS (SELECT 1 FROM trgs WHERE name = 'trg_billing_term_windows_guard' AND tbl = 'billing_term_windows')),
  ('a promotion goes to a business, an owner and a licence number once, and an administrator''s grant is recorded once per request key', to_regclass('public.billing_promotion_redemptions_licence_idx') IS NOT NULL
    AND to_regclass('public.billing_promotion_redemptions_owner_idx') IS NOT NULL AND to_regclass('public.billing_allowance_grants_admin_ref_idx') IS NOT NULL
    AND EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.billing_promotion_redemptions'::regclass AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (promotion_id, business_id)')),
  ('all sixteen administrator operations exist', (SELECT count(*) FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL) = 16),
  ('visitors cannot call any administrator operation; signed-in users can (each checks for an administrator itself)', NOT EXISTS (SELECT 1 FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL AND has_function_privilege('anon', 'public.' || o.sig, 'EXECUTE'))
    AND NOT EXISTS (SELECT 1 FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL AND NOT has_function_privilege('authenticated', 'public.' || o.sig, 'EXECUTE'))),
  ('every administrator operation checks for an administrator and a reason', NOT EXISTS (SELECT 1 FROM admin_ops o WHERE to_regprocedure('public.' || o.sig) IS NOT NULL AND o.sig <> 'admin_billing_promotions()'
    AND pg_get_functiondef(to_regprocedure('public.' || o.sig)) NOT LIKE '%_billing_admin_reason%')),
  ('the internal helpers exist and cannot be called by signed-in users or visitors', (SELECT count(*) FROM helpers h WHERE to_regprocedure('public.' || h.sig) IS NOT NULL) = 9
    AND NOT EXISTS (SELECT 1 FROM helpers h WHERE to_regprocedure('public.' || h.sig) IS NOT NULL AND (has_function_privilege('authenticated', 'public.' || h.sig, 'EXECUTE') OR has_function_privilege('anon', 'public.' || h.sig, 'EXECUTE')))),
  ('the terms in force include any temporary change that is running', pg_get_functiondef('public.billing_resolve_terms(uuid, timestamp with time zone)'::regprocedure) LIKE '%billing_term_windows%'),
  ('scheduling a cancellation fixes the end date at once', pg_get_function_result('public.admin_billing_set_cancellation(uuid, boolean, text)'::regprocedure) = 'timestamp with time zone'),
  ('the administrator''s detail shows temporary changes and promotions', pg_get_functiondef('public.admin_billing_business_detail(uuid, text)'::regprocedure) LIKE '%billing_term_windows%'
    AND pg_get_functiondef('public.admin_billing_business_detail(uuid, text)'::regprocedure) LIKE '%billing_promotion_redemptions%'),
  ('the reconciliation has four more checks (charges, waivers, promotion limits, audit)', (SELECT count(*) FROM public.billing_reconcile()) >= (SELECT count(*) FROM public._billing_reconcile_engine()) + (SELECT count(*) FROM public._billing_reconcile_invoices()) + 4),
  ('billing is still OFF: mode is disabled', (SELECT mode FROM public.billing_settings WHERE id) = 'disabled'),
  ('nothing has been used: no promotion, temporary change, redemption, administrator credit, charge, waiver or grant', (SELECT count(*) FROM public.billing_promotions) + (SELECT count(*) FROM public.billing_term_windows)
    + (SELECT count(*) FROM public.billing_promotion_redemptions) + (SELECT count(*) FROM public.billing_ledger_entries WHERE source = 'admin') + (SELECT count(*) FROM public.billing_allowance_grants WHERE source IN ('admin', 'promotion')) = 0),
  ('the reconciliation finds nothing wrong', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode
FROM checks;
