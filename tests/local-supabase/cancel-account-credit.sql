BEGIN;
DO $$
DECLARE f RECORD; target UUID; before_balance NUMERIC; after_balance NUMERIC; payment JSONB;
BEGIN
 SELECT * INTO f FROM zz.cc;
 SELECT id INTO STRICT target FROM public.orders WHERE pharmacy_id=f.good AND total_ghs=100 AND status='pending' ORDER BY created_at DESC LIMIT 1;
 SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) INTO before_balance
 FROM public.credit_ledger_entries WHERE wholesaler_id=f.alpha AND pharmacy_id=f.good;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::TEXT FROM zz.u WHERE k='w_owner'),true);
 payment := public.record_credit_payment(f.alpha,f.good,30,'cash',NULL,NULL,NULL,NULL,
   jsonb_build_array(jsonb_build_object('order_id',target,'amount',30)));
 UPDATE public.orders SET status='cancelled',cancellation_reason='Local audit test' WHERE id=target;
 SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) INTO after_balance
 FROM public.credit_ledger_entries WHERE wholesaler_id=f.alpha AND pharmacy_id=f.good;
 IF after_balance <> before_balance-130 THEN RAISE EXCEPTION 'Paid amount was not retained as account credit'; END IF;
 IF (SELECT amount_ghs FROM public.credit_ledger_entries WHERE cancellation_order_id=target) <> 100 THEN
   RAISE EXCEPTION 'Cancellation did not release full invoice charge';
 END IF;
 UPDATE public.orders SET status='cancelled' WHERE id=target;
 IF (SELECT count(*) FROM public.credit_ledger_entries WHERE cancellation_order_id=target) <> 1 THEN
   RAISE EXCEPTION 'Duplicate cancellation credit';
 END IF;
 BEGIN
   PERFORM public.reverse_credit_ledger_entry((SELECT id FROM public.credit_ledger_entries WHERE cancellation_order_id=target),'Audit reversal');
   RAISE EXCEPTION 'Cancellation reversal allowed';
 EXCEPTION WHEN OTHERS THEN
   IF SQLERRM NOT LIKE 'Cancellation credits cannot be reversed%' THEN RAISE; END IF;
 END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 PERFORM public.create_marketplace_orders_once(f.u_po,f.good,gen_random_uuid(),
   jsonb_build_array(jsonb_build_object('productId',f.p_item_a,'quantity',1,'category','other')),
   '{}',jsonb_build_object(f.alpha::TEXT,'credit'));
 IF public.credit_exposure(f.alpha,f.good) <> GREATEST(after_balance+100,0) THEN
   RAISE EXCEPTION 'Later purchase did not retain account credit';
 END IF;
 RAISE NOTICE 'PASS: partial payment retained, full charges cancelled, repeated cancellation idempotent';
END $$;
ROLLBACK;
