-- Run only in an isolated local database after the rollout fixture suite and audit-fixes migration.
-- Every new fixture and setting change is rolled back. No provider calls.
BEGIN;
CREATE FUNCTION pg_temp.assert_ok(label text, ok boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL: %',label; END IF; RAISE NOTICE 'PASS: %',label; END $$;
DO $$
DECLARE b uuid; o uuid; result text; n integer; p public.billing_subscriptions;
BEGIN
 PERFORM zz.mkplan('audit_cap', '{"subscription_amount":0,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":10}'::jsonb);
 b:=zz.mkws('Audit capped refunds'); PERFORM zz.sub(b,'audit_cap',now(),NULL);
 o:=zz.go(b,10000,0,now());
 PERFORM pg_temp.assert_ok('primary fee is capped at 10', (SELECT sum(charged_amount)=10 FROM public.order_billing_assessments WHERE order_id=o));
 UPDATE public.orders SET effective_total_ghs=5000 WHERE id=o;
 PERFORM pg_temp.assert_ok('value still above cap earns no credit', (SELECT sum(credit_amount)=0 FROM public.billing_ledger_entries WHERE order_id=o));
 UPDATE public.orders SET effective_total_ghs=500 WHERE id=o;
 PERFORM pg_temp.assert_ok('value below cap credits only 5', (SELECT sum(credit_amount)=5 FROM public.billing_ledger_entries WHERE order_id=o));
 UPDATE public.orders SET effective_total_ghs=0 WHERE id=o;
 PERFORM pg_temp.assert_ok('full refund credits exactly the 10 charged', (SELECT sum(credit_amount)=10 AND sum(charged_amount)=10 FROM public.billing_ledger_entries WHERE order_id=o));
 n:=(SELECT count(*) FROM public.order_billing_assessments WHERE order_id=o);
 PERFORM public.billing_assess_order_change(o);
 PERFORM pg_temp.assert_ok('replay creates no adjustment', n=(SELECT count(*) FROM public.order_billing_assessments WHERE order_id=o));
 UPDATE public.orders SET effective_total_ghs=10000 WHERE id=o;
 PERFORM pg_temp.assert_ok('later increase cannot exceed spent cycle cap', (SELECT sum(charged_amount)=10 FROM public.billing_ledger_entries WHERE order_id=o));
 UPDATE public.orders SET effective_total_ghs=0 WHERE id=o;
 PERFORM pg_temp.assert_ok('second decrease cannot repeat the refund', (SELECT sum(credit_amount)=10 FROM public.billing_ledger_entries WHERE order_id=o));
 b:=zz.mkws('Audit waived refunds'); PERFORM zz.sub(b,'audit_cap',now(),NULL); o:=zz.go(b,10000,0,now());
 result:=zz.adm(format('SELECT public.admin_billing_waive_fee(%L,%L,''Audit full fee waiver'')',b,o));
 PERFORM pg_temp.assert_ok('waiver succeeded', result NOT LIKE 'ERR:%');
 UPDATE public.orders SET effective_total_ghs=0 WHERE id=o;
 PERFORM pg_temp.assert_ok('waiver plus refund never exceeds charge', (SELECT sum(credit_amount)=10 AND sum(charged_amount)=10 FROM public.billing_ledger_entries WHERE order_id=o));
 PERFORM zz.mkplan('audit_plain','{"subscription_amount":0,"transaction_fee_percentage":1}'::jsonb);
 b:=zz.mkws('Audit uncapped refunds'); PERFORM zz.sub(b,'audit_plain',now(),NULL); o:=zz.go(b,1000,0,now());
 UPDATE public.orders SET effective_total_ghs=900 WHERE id=o;
 UPDATE public.orders SET effective_total_ghs=1200 WHERE id=o;
 UPDATE public.orders SET effective_total_ghs=0 WHERE id=o;
 PERFORM pg_temp.assert_ok('uncapped decreases and increases preserve net-zero full refund', (SELECT sum(credit_amount)=13 AND sum(charged_amount)=13 FROM public.billing_ledger_entries WHERE order_id=o));
 -- Reproduce the shadow-to-follow bypass through the authorized admin API.
 b:=zz.mkws('Audit shadow bypass'); PERFORM zz.sub(b,'rl_ws',now()-interval '90 days','shadow');
 result:=zz.adm(format('SELECT public.admin_billing_set_subscription_mode(%L,NULL,''Audit follow platform'')',b));
 PERFORM pg_temp.assert_ok('follow-platform cannot activate shadow',result LIKE 'ERR:%');
 -- Defence in depth against an existing inconsistent subscription from an older release.
 UPDATE public.billing_subscriptions SET billing_mode=NULL WHERE business_id=b;
 o:=zz.go(b,1000,0,now()-interval '1 day');
 PERFORM public.billing_open_periods(now());
 PERFORM pg_temp.assert_ok('engine creates no historical real periods',(SELECT count(*)=0 FROM public.billing_periods WHERE business_id=b AND NOT shadow));
 PERFORM pg_temp.assert_ok('engine creates no unactivated real assessment',(SELECT count(*)=0 FROM public.order_billing_assessments WHERE order_id=o AND NOT shadow));
 PERFORM pg_temp.assert_ok('catch-up ignores unactivated business',NOT EXISTS(SELECT 1 FROM public._billing_unassessed_orders() WHERE order_id=o));
 PERFORM pg_temp.assert_ok('unactivated effective mode is disabled',public.billing_effective_mode(b)='disabled');
 SELECT * INTO p FROM public.billing_subscriptions WHERE business_id=b;
 BEGIN PERFORM public._billing_ensure_period(p,now(),FALSE); RAISE EXCEPTION 'FAIL: period guard'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='FAIL: period guard' THEN RAISE; END IF; END;
 PERFORM pg_temp.assert_ok('period guard independently refuses unactivated business',TRUE);
 UPDATE public.billing_subscriptions SET billing_mode='shadow' WHERE business_id=b;
 result:=zz.adm(format('SELECT public.admin_billing_go_live_business(%L,NULL,''Audit explicit go live'')',b));
 PERFORM pg_temp.assert_ok('explicit go-live succeeds',result NOT LIKE 'ERR:%');
 PERFORM public.billing_open_periods(clock_timestamp()+interval '1 second');
 PERFORM pg_temp.assert_ok('first real period begins at activation',(SELECT count(*)=1 AND min(period_start)=(SELECT activated_at FROM public.billing_subscriptions WHERE business_id=b) FROM public.billing_periods WHERE business_id=b AND NOT shadow));
 PERFORM public.billing_assess_order(o);
 PERFORM pg_temp.assert_ok('historical order stays unbilled after go-live',NOT EXISTS(SELECT 1 FROM public.order_billing_assessments WHERE order_id=o AND NOT shadow));
END $$;
-- Commission invariant in both directions, including direct SQL configuration changes.
DO $$
DECLARE r text;
BEGIN
 r:=zz.try('UPDATE public.payments_settings SET platform_fee_bps=100 WHERE id');
 PERFORM pg_temp.assert_ok('active billing refuses later commission',r LIKE 'ERR:%');
 PERFORM zz.adm('SELECT public.admin_billing_set_mode(''disabled'',''Audit commission policy'')');
 UPDATE public.payments_settings SET platform_fee_bps=100 WHERE id;
 PERFORM pg_temp.assert_ok('readiness reports commission blocker',EXISTS(SELECT 1 FROM jsonb_array_elements(zz.adm('SELECT public.admin_billing_readiness()')::jsonb->'checks') c WHERE c->>'key'='zero_commission' AND c->>'ok'='false'));
 r:=zz.adm('SELECT public.admin_billing_activate_platform(TRUE,''ACTIVATE BILLING'',''Audit commission policy'')');
 PERFORM pg_temp.assert_ok('activation rejects nonzero commission',r LIKE 'ERR:%');
 r:=zz.try('UPDATE public.billing_settings SET mode=''active'' WHERE id');
 PERFORM pg_temp.assert_ok('direct settings update also rejects conflict',r LIKE 'ERR:%');
 UPDATE public.payments_settings SET platform_fee_bps=0 WHERE id;
 PERFORM public.billing_run_scheduled(now());
 UPDATE public.billing_run_status SET last_run_at=now() WHERE id;
 r:=zz.adm('SELECT public.admin_billing_activate_platform(TRUE,''ACTIVATE BILLING'',''Audit commission policy'')');
 PERFORM pg_temp.assert_ok('zero commission allows activation',r NOT LIKE 'ERR:%');
 PERFORM pg_temp.assert_ok('internal trigger functions not callable by users',NOT has_function_privilege('authenticated','public.billing_revenue_policy_guard()','EXECUTE') AND NOT has_function_privilege('anon','public.billing_revenue_policy_lock()','EXECUTE'));
END $$;
ROLLBACK;
