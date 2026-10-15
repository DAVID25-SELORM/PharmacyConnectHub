-- READ-ONLY checks after applying 20261209100000_expiry_sales_guard.sql. Nothing here writes. Every row should say ok = true.
SELECT 'policy row exists and starts in observe mode' AS check_name,
       COALESCE((SELECT mode = 'observe' FROM public.expiry_guard_policy WHERE id), false) AS ok,
       'It records what would be refused and blocks nothing. Change the mode on the Admin Console, under Expired stock.' AS note
UNION ALL
SELECT 'checkout carries exactly one guard call',
       (SELECT (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1
        FROM pg_proc WHERE oid = 'public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure), ''
UNION ALL
SELECT 'RFQ award (whole quote) carries exactly one guard call',
       (SELECT (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1
        FROM pg_proc WHERE oid = 'public.award_rfq_quote(uuid,uuid,boolean)'::regprocedure), ''
UNION ALL
SELECT 'RFQ award (by line) carries exactly one guard call',
       (SELECT (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1
        FROM pg_proc WHERE oid = 'public.award_rfq_lines(uuid,jsonb,boolean)'::regprocedure), ''
UNION ALL
SELECT 'back-order shipment carries exactly one guard call',
       (SELECT (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1
        FROM pg_proc WHERE oid = 'public.advance_backorder_shipment(uuid,text)'::regprocedure), ''
UNION ALL
SELECT 'the storefront catalogue reports sellable stock',
       (SELECT prosrc LIKE '%available_stock(p)%' FROM pg_proc WHERE oid = 'public.list_marketplace_catalogue()'::regprocedure), 'Plain stock until the guard is enforced.'
UNION ALL
SELECT 'the batch lookup index exists',
       to_regclass('public.product_batches_live_expiry_idx') IS NOT NULL, ''
UNION ALL
SELECT 'the record of what the guard saw is append-only',
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'expiry_guard_events_append_only' AND NOT tgisinternal), ''
UNION ALL
SELECT 'signed-out visitors cannot read the computed stock columns',
       NOT has_function_privilege('anon', 'public.available_stock(public.products)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.expired_stock(public.products)', 'EXECUTE'), ''
UNION ALL
SELECT 'the internal helpers are not callable by users',
       NOT has_function_privilege('authenticated', 'public.expired_units_on_hand(uuid)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public._expiry_guard(uuid,integer,integer,text,text,uuid)', 'EXECUTE')
       AND NOT has_function_privilege('authenticated', 'public.expiry_guard_mode()', 'EXECUTE'), ''
UNION ALL
SELECT 'administrator controls exist and refuse signed-out visitors',
       to_regprocedure('public.admin_expiry_guard_status(integer)') IS NOT NULL
       AND to_regprocedure('public.admin_set_expiry_guard_mode(text,text)') IS NOT NULL
       AND NOT has_function_privilege('anon', 'public.admin_expiry_guard_status(integer)', 'EXECUTE')
       AND NOT has_function_privilege('anon', 'public.admin_set_expiry_guard_mode(text,text)', 'EXECUTE'), ''
UNION ALL
SELECT 'nothing has been blocked or recorded yet',
       (SELECT count(*) = 0 FROM public.expiry_guard_events), 'Records appear as orders that need expired units are placed. Zero straight after applying is expected.';
