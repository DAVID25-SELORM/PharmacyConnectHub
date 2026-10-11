-- Run only in an isolated local database after 20261118100000 and setup fixtures.
-- Everything is rolled back. No production credentials or data are needed.
BEGIN;
CREATE FUNCTION pg_temp.assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',label; END IF; RAISE NOTICE 'PASS: %',label; END $$;
CREATE FUNCTION pg_temp.read_as(uid uuid, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE result jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',uid::text,true);
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',uid,'role','authenticated')::text,true);
 SET LOCAL ROLE authenticated;
 BEGIN EXECUTE statement INTO result;
 EXCEPTION WHEN OTHERS THEN result:=jsonb_build_object('error',SQLERRM); END;
 RESET ROLE;
 RETURN result;
END $$;
DO $$
DECLARE
 a uuid := (SELECT id FROM public.businesses WHERE name='Good Pharmacy');
 b uuid := (SELECT id FROM public.businesses WHERE name='Other Pharmacy');
 supplier uuid := (SELECT id FROM public.businesses WHERE name='Alpha Wholesale');
 buyer uuid := (SELECT owner_id FROM public.businesses WHERE id=a);
 outsider uuid := (SELECT owner_id FROM public.businesses WHERE name='Pending Pharmacy');
 oid uuid; foreign_order uuid; r jsonb; filtered jsonb; before_count int;
BEGIN
 SELECT count(*) INTO before_count FROM public.orders WHERE pharmacy_id=a;
 INSERT INTO public.business_staff(business_id,user_id,role,status,joined_at)
 VALUES(b,buyer,'manager','active',now()) ON CONFLICT(business_id,user_id) DO UPDATE SET status='active';
 FOR i IN 1..25 LOOP
   INSERT INTO public.orders(pharmacy_id,wholesaler_id,total_ghs,created_at,status,settlement_method,is_credit_order)
   VALUES(a,supplier,i,now()- interval '2 days',
    (CASE WHEN i=1 THEN 'picking' WHEN i=2 THEN 'ready_for_dispatch' WHEN i=3 THEN 'packed' WHEN i=4 THEN 'dispatched' ELSE 'pending' END)::public.order_status,
    'credit',true) RETURNING id INTO oid;
 END LOOP;
 INSERT INTO public.orders(pharmacy_id,wholesaler_id,total_ghs,created_at)
 VALUES(b,supplier,999,now()-interval '1 day') RETURNING id INTO foreign_order;
 r:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L)',a));
 PERFORM pg_temp.assert((r->>'workspace_total')::int=before_count+25,'workspace count exceeds page size');
 PERFORM pg_temp.assert(jsonb_array_length(r->'orders')=20,'page is limited to 20');
 PERFORM pg_temp.assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'orders') x WHERE x->>'pharmacy_id'<>a::text),'authorized second pharmacy excluded');
 PERFORM pg_temp.assert((r->'counts'->>'active')::int>=25,'picking and ready count as active');
 PERFORM pg_temp.assert((r->'counts'->>'transit')::int=(SELECT count(*) FROM public.orders WHERE pharmacy_id=a AND status='dispatched'),'packed excluded from transit');
 filtered:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L,p_status=>%L)',a,'delivered'));
 PERFORM pg_temp.assert(filtered->'counts'=r->'counts' AND filtered->'workspace_total'=r->'workspace_total','filters preserve global metrics');
 filtered:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L,p_page=>999)',a));
 PERFORM pg_temp.assert(filtered->'total_count'=r->'total_count' AND filtered->'orders'='[]'::jsonb,'empty page preserves matched total');
 filtered:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L,p_sort=>%L)',a,'highest'));
 PERFORM pg_temp.assert(NOT EXISTS(SELECT 1 FROM (SELECT (v->>'total_ghs')::numeric amount,lead((v->>'total_ghs')::numeric) OVER(ORDER BY ord) next FROM jsonb_array_elements(filtered->'orders') WITH ORDINALITY j(v,ord)) x WHERE x.amount<x.next),'descending amount sort');
 r:=pg_temp.read_as(buyer,format('SELECT public.get_pharmacy_order_scoped(%L,%L)',a,foreign_order));
 PERFORM pg_temp.assert(r IS NULL,'detail excludes other authorized workspace');
 r:=pg_temp.read_as(buyer,format('SELECT public.get_pharmacy_order_scoped(%L,%L)',b,foreign_order));
 PERFORM pg_temp.assert(r->'pharmacy'->>'id'=b::text,'document buyer is order pharmacy');
 r:=pg_temp.read_as(outsider,format('SELECT public.list_pharmacy_orders_scoped(%L)',a));
 PERFORM pg_temp.assert(r ? 'error','unrelated user cannot list');
 r:=pg_temp.read_as(outsider,format('SELECT public.get_pharmacy_order_scoped(%L,%L)',b,foreign_order));
 PERFORM pg_temp.assert(r IS NULL,'unrelated user cannot read detail');
 UPDATE public.business_staff SET status='inactive' WHERE business_id=b AND user_id=buyer;
 r:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L)',b));
 PERFORM pg_temp.assert(r ? 'error','inactive staff cannot list');
 r:=pg_temp.read_as(buyer,format('SELECT public.list_pharmacy_orders_scoped(%L,p_range=>%L,p_from=>%L,p_to=>%L)',a,'custom','2026-10-12','2026-10-11'));
 PERFORM pg_temp.assert(r ? 'error','reversed dates rejected server-side');
 PERFORM pg_temp.assert(NOT has_function_privilege('anon','public.get_pharmacy_order_scoped(uuid,uuid)','EXECUTE'),'anonymous detail execution denied');
 PERFORM pg_temp.assert((SELECT provolatile='s' FROM pg_proc WHERE pg_proc.oid='public.resolve_report_range(text,timestamptz,timestamptz)'::regprocedure),'time dependent range helper is stable');
END $$;
ROLLBACK;
