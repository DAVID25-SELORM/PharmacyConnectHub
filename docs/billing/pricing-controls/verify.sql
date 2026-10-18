-- VERIFY after applying 20261210100000_billing_pricing_controls.sql. READ-ONLY: nothing here writes.
-- Run it in the PRODUCTION SQL Editor. Every row should say ok = true.
SELECT 'the two charging switches exist and are both on' AS check_name,
       COALESCE((SELECT bool_and(subscriptions_enabled AND commissions_enabled) FROM public.billing_settings), false) AS ok,
       'Nothing is switched off by applying this.' AS note
UNION ALL
SELECT 'scheduled price changes can be stored',
       to_regclass('public.billing_scheduled_changes') IS NOT NULL,
       'The table behind the scheduled-changes list.'
UNION ALL
SELECT 'plan versions can be scheduled, published, retired or cancelled',
       EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'billing_plan_versions_status_check' AND pg_get_constraintdef(oid) LIKE '%scheduled%' AND pg_get_constraintdef(oid) LIKE '%cancelled%'),
       'The status rule that lets a version wait for its start date.'
UNION ALL
SELECT 'only the platform owner can change billing',
       COALESCE((SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure('public._billing_admin_reason(text)')) LIKE '%is_platform_owner%', false),
       'Every billing change goes through this one check. Other administrators can still read billing.'
UNION ALL
SELECT 'the database refuses a future-dated price that would take effect at once',
       COALESCE((SELECT prosrc FROM pg_proc WHERE oid = to_regproc('public.billing_plan_versions_guard')) LIKE '%must be scheduled, not published%', false),
       'Prices that start in the future have to be scheduled.'
UNION ALL
SELECT 'new function exists: ' || f,
       to_regprocedure(f) IS NOT NULL,
       'Used by the Pricing & Plans screen.'
FROM unnest(ARRAY[
  'public.admin_billing_preview_price_change(uuid,jsonb,timestamptz,text,boolean)',
  'public.admin_billing_schedule_price_change(uuid,jsonb,timestamptz,text,boolean,integer,text)',
  'public.admin_billing_cancel_scheduled_change(uuid,text)',
  'public.admin_billing_scheduled_changes(integer)',
  'public.admin_billing_plan_history(uuid)',
  'public.admin_billing_set_charging(boolean,boolean,text)',
  'public.billing_apply_due_price_changes(timestamptz)']) AS f
UNION ALL
SELECT 'signed-out visitors cannot run the change functions',
       NOT has_function_privilege('anon', 'public.admin_billing_schedule_price_change(uuid,jsonb,timestamptz,text,boolean,integer,text)', 'EXECUTE')
         AND NOT has_function_privilege('anon', 'public.admin_billing_set_charging(boolean,boolean,text)', 'EXECUTE')
         AND NOT has_function_privilege('anon', 'public.billing_apply_due_price_changes(timestamptz)', 'EXECUTE'),
       'They also refuse anyone who is not the platform owner, inside the function.'
UNION ALL
SELECT 'signed-in users cannot call the scheduler directly',
       NOT has_function_privilege('authenticated', 'public.billing_apply_due_price_changes(timestamptz)', 'EXECUTE'),
       'Only the scheduled job applies due changes.'
UNION ALL
SELECT 'no price change is scheduled or cancelled yet',
       NOT EXISTS (SELECT 1 FROM public.billing_scheduled_changes) AND NOT EXISTS (SELECT 1 FROM public.billing_plan_versions WHERE status IN ('scheduled', 'cancelled')),
       'The migration schedules nothing by itself.'
UNION ALL
SELECT 'existing plan versions are all still published or retired',
       NOT EXISTS (SELECT 1 FROM public.billing_plan_versions WHERE status NOT IN ('published', 'retired')),
       'No existing price was changed.'
UNION ALL
SELECT 'billing is still not live',
       NOT EXISTS (SELECT 1 FROM public.billing_subscriptions WHERE activated_at IS NOT NULL),
       'No business is being charged for real.';
