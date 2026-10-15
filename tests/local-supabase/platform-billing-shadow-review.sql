-- Run only in an isolated local database, after the rollout fixture suite (it defines the zz helpers) and migrations through 20261208100000_billing_shadow_review.sql.
-- Every fixture and every deliberate corruption is rolled back. No provider calls.
BEGIN;
CREATE FUNCTION pg_temp.assert_ok(label text, ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL: %',label; END IF; RAISE NOTICE 'PASS: %',label; END $$;
CREATE FUNCTION pg_temp.cnt(p_review jsonb, p_key text) RETURNS integer LANGUAGE sql AS $$
  SELECT (c ->> 'count')::integer FROM jsonb_array_elements(p_review -> 'checks') c WHERE c ->> 'key' = p_key $$;
DO $$
DECLARE b uuid; o1 uuid; o2 uuid; o3 uuid; o4 uuid; r jsonb; base jsonb; r0 text; n1 integer; n2 integer; n3 integer;
BEGIN
 -- who may read it ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 r0 := zz.val_as(zz.owner((SELECT good FROM zz.bx)), 'SELECT public.admin_billing_shadow_review()::text');
 PERFORM pg_temp.assert_ok('a business owner cannot run the review', r0 LIKE 'ERR:%');
 r0 := zz.anon('SELECT public.admin_billing_shadow_review()::text');
 PERFORM pg_temp.assert_ok('a signed-out visitor cannot run the review', r0 LIKE 'ERR:%');
 r0 := zz.adm('SELECT public.admin_billing_shadow_review()::text');
 PERFORM pg_temp.assert_ok('an administrator can run it', r0 NOT LIKE 'ERR:%');
 PERFORM pg_temp.assert_ok('it is not granted to anonymous visitors', NOT has_function_privilege('anon', 'public.admin_billing_shadow_review(integer)', 'EXECUTE'));

 -- a plan with a minimum, a maximum and a percentage, and shadow orders that hit each branch --------------------------------------------------------------------------------------------------
 base := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM zz.mkplan('sr_plan', '{"subscription_amount":0,"transaction_fee_percentage":2.5,"transaction_fee_min":3,"transaction_fee_max":40}'::jsonb);
 b := zz.mkws('Review shadow wholesaler');
 PERFORM zz.sub(b, 'sr_plan', now(), 'shadow');
 o1 := zz.go(b, 100, 0, now());     -- 2.50 raised to the minimum of 3.00
 o2 := zz.go(b, 400, 5, now());     -- 10.00, delivery fee not counted
 o3 := zz.go(b, 5000, 0, now());    -- 125.00 lowered to the maximum of 40.00
 o4 := zz.go(b, 0.04, 0, now());    -- a very small order
 PERFORM pg_temp.assert_ok('the orders were assessed in shadow', (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = b AND shadow AND kind = 'primary') = 4);
 PERFORM pg_temp.assert_ok('minimum, plain and maximum fees were recorded', (SELECT array_agg(fee_after_limits ORDER BY fee_after_limits) FROM public.order_billing_assessments WHERE business_id = b AND shadow AND outcome = 'chargeable' AND billable_gmv >= 100) = ARRAY[3.00, 10.00, 40.00]::numeric[]);

 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('the review recalculated the new chargeable orders', (r ->> 'recomputed')::int >= (base ->> 'recomputed')::int + 3);
 PERFORM pg_temp.assert_ok('no fee differs from its recalculation', pg_temp.cnt(r, 'fee_formula') = 0);
 PERFORM pg_temp.assert_ok('every fee used the percentage saved in its terms', pg_temp.cnt(r, 'terms_used') = 0);
 PERFORM pg_temp.assert_ok('every charge plus the cap adds up to its fee', pg_temp.cnt(r, 'charge_split') = 0);
 PERFORM pg_temp.assert_ok('no order changed in value unnoticed', pg_temp.cnt(r, 'order_value') = 0);
 PERFORM pg_temp.assert_ok('recorded and recalculated totals agree', (r ->> 'recorded_fee_total')::numeric = (r ->> 'recalculated_fee_total')::numeric);
 PERFORM pg_temp.assert_ok('four named checks are always reported', jsonb_array_length(r -> 'checks') = 4);
 PERFORM pg_temp.assert_ok('a clean review lists no rows', jsonb_array_length(r -> 'rows') = 0);

 -- an adjustment (the order value is reduced) is handled by the engine and is not a discrepancy ---------------------------------------------------------------------------------------------
 UPDATE public.orders SET effective_total_ghs = 200 WHERE id = o2;
 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('an order value change that the engine adjusted is not flagged', pg_temp.cnt(r, 'order_value') = 0 AND pg_temp.cnt(r, 'fee_formula') = 0);

 -- the review writes nothing -----------------------------------------------------------------------------------------------------------------------------------------------------------------
 n1 := (SELECT count(*) FROM public.order_billing_assessments);
 n2 := (SELECT count(*) FROM public.billing_ledger_entries);
 n3 := (SELECT count(*) FROM public.audit_logs);
 PERFORM zz.adm('SELECT public.admin_billing_shadow_review(5)::text');
 PERFORM pg_temp.assert_ok('running the review adds no assessments, ledger entries or audit rows',
   n1 = (SELECT count(*) FROM public.order_billing_assessments) AND n2 = (SELECT count(*) FROM public.billing_ledger_entries) AND n3 = (SELECT count(*) FROM public.audit_logs));

 -- deliberate corruption: each kind must be found, and named with both figures ---------------------------------------------------------------------------------------------------------------
 SET LOCAL session_replication_role = replica;
 UPDATE public.order_billing_assessments SET fee_after_limits = 11.00, charged_amount = 11.00 WHERE order_id = o2 AND shadow AND kind = 'primary';
 SET LOCAL session_replication_role = origin;
 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('a wrong fee is found', pg_temp.cnt(r, 'fee_formula') = 1);
 PERFORM pg_temp.assert_ok('it names the order, the business and both figures',
   EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'rows') x WHERE x ->> 'check' = 'fee_formula' AND x ->> 'business_name' = 'Review shadow wholesaler'
           AND (x ->> 'recorded')::numeric = 11.00 AND (x ->> 'recalculated')::numeric = 10.00 AND (x ->> 'difference')::numeric = 1.00
           AND x ->> 'order_number' = (SELECT order_number FROM public.orders WHERE id = o2)));
 PERFORM pg_temp.assert_ok('the totals now disagree by the same amount', (r ->> 'recorded_fee_total')::numeric - (r ->> 'recalculated_fee_total')::numeric = 1.00);

 SET LOCAL session_replication_role = replica;
 UPDATE public.order_billing_assessments SET fee_after_limits = 10.00, charged_amount = 10.00, percentage = 2.0, calculated_fee = 8.00 WHERE order_id = o2 AND shadow AND kind = 'primary';
 SET LOCAL session_replication_role = origin;
 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('a percentage that is not the one in the saved terms is found', pg_temp.cnt(r, 'terms_used') = 1);

 SET LOCAL session_replication_role = replica;
 UPDATE public.order_billing_assessments SET percentage = 2.5, calculated_fee = 10.00, fee_after_limits = 10.00, charged_amount = 4.00, cap_adjustment = 0 WHERE order_id = o2 AND shadow AND kind = 'primary';
 SET LOCAL session_replication_role = origin;
 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('a charge that the cap does not explain is found', pg_temp.cnt(r, 'charge_split') = 1 AND pg_temp.cnt(r, 'fee_formula') = 0 AND pg_temp.cnt(r, 'terms_used') = 0);

 SET LOCAL session_replication_role = replica;
 UPDATE public.order_billing_assessments SET charged_amount = 10.00 WHERE order_id = o2 AND shadow AND kind = 'primary';
 UPDATE public.orders SET effective_total_ghs = 900 WHERE id = o3;
 SET LOCAL session_replication_role = origin;
 r := zz.adm('SELECT public.admin_billing_shadow_review()::text')::jsonb;
 PERFORM pg_temp.assert_ok('an order whose value changed without an adjustment is found as a warning', pg_temp.cnt(r, 'order_value') >= 1
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(r -> 'checks') c WHERE c ->> 'key' = 'order_value' AND c ->> 'severity' = 'warning'));
 PERFORM pg_temp.assert_ok('and the critical checks are clean again', pg_temp.cnt(r, 'fee_formula') = 0 AND pg_temp.cnt(r, 'terms_used') = 0 AND pg_temp.cnt(r, 'charge_split') = 0);

 -- the list is capped --------------------------------------------------------------------------------------------------------------------------------------------------------------------------
 SET LOCAL session_replication_role = replica;
 UPDATE public.order_billing_assessments SET fee_after_limits = fee_after_limits + 1 WHERE business_id = b AND shadow AND kind = 'primary' AND outcome = 'chargeable';
 SET LOCAL session_replication_role = origin;
 r := zz.adm('SELECT public.admin_billing_shadow_review(1)::text')::jsonb;
 PERFORM pg_temp.assert_ok('a limit of 1 lists one row but counts every issue', jsonb_array_length(r -> 'rows') = 1 AND pg_temp.cnt(r, 'fee_formula') >= 3);
 r := zz.adm('SELECT public.admin_billing_shadow_review(0)::text')::jsonb;
 PERFORM pg_temp.assert_ok('a limit of 0 is treated as 1', jsonb_array_length(r -> 'rows') = 1);
 r0 := zz.adm('SELECT public.admin_billing_shadow_review(100000)::text');
 PERFORM pg_temp.assert_ok('a huge limit is accepted and capped', r0 NOT LIKE 'ERR:%' AND jsonb_array_length((r0::jsonb) -> 'rows') <= 200);
 r0 := zz.adm('SELECT public.admin_billing_shadow_review(NULL)::text');
 PERFORM pg_temp.assert_ok('a missing limit uses the default', r0 NOT LIKE 'ERR:%');

 -- real billing is not part of the review ---------------------------------------------------------------------------------------------------------------------------------------------------
 PERFORM pg_temp.assert_ok('only shadow assessments are reviewed', (r ->> 'assessments_total')::int = (SELECT count(*) FROM public.order_billing_assessments WHERE shadow AND kind = 'primary'));
END $$;
ROLLBACK;
