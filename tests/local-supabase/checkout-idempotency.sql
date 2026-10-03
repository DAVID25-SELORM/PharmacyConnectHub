-- Run against the isolated credit-concurrency fixture database after 20261017100000.
-- Every change is rolled back.
BEGIN;
DO $$
DECLARE
  f RECORD;
  request UUID := gen_random_uuid();
  items JSONB;
  stock_before INTEGER;
  orders_before INTEGER;
  exposure_before NUMERIC;
  result INTEGER;
BEGIN
  SELECT * INTO f FROM zz.cc;
  items := jsonb_build_array(jsonb_build_object('productId', f.p_item_a, 'quantity', 1, 'category', 'cash_private'));
  SELECT stock INTO stock_before FROM public.products WHERE id=f.p_item_a;
  SELECT count(*) INTO orders_before FROM public.orders;
  exposure_before := public.credit_exposure(f.alpha,f.good);
  result := public.create_marketplace_orders_once(f.u_po,f.good,request,items,'{}',jsonb_build_object(f.alpha::TEXT,'credit'));
  IF result <> 1 THEN RAISE EXCEPTION 'first checkout failed'; END IF;
  result := public.create_marketplace_orders_once(f.u_po,f.good,request,items,'{}',jsonb_build_object(f.alpha::TEXT,'credit'));
  IF result <> 1 OR (SELECT count(*) FROM public.orders) <> orders_before+1 THEN RAISE EXCEPTION 'duplicate order'; END IF;
  IF (SELECT stock FROM public.products WHERE id=f.p_item_a) <> stock_before-1 THEN RAISE EXCEPTION 'duplicate stock deduction'; END IF;
  IF public.credit_exposure(f.alpha,f.good) <> exposure_before+100 THEN RAISE EXCEPTION 'duplicate debt'; END IF;
  BEGIN
    PERFORM public.create_marketplace_orders_once(f.u_po,f.good,request,items,'{}','{}');
    RAISE EXCEPTION 'payload mismatch accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'Checkout request ID already used%' THEN RAISE; END IF;
  END;
  UPDATE public.businesses SET verification_status='pending' WHERE id=f.good;
  BEGIN
    PERFORM public.create_marketplace_orders_once(f.u_po,f.good,request,items,'{}',jsonb_build_object(f.alpha::TEXT,'credit'));
    RAISE EXCEPTION 'unauthorized replay accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'You do not have permission%' THEN RAISE; END IF;
  END;
  IF has_function_privilege('authenticated','public.create_marketplace_orders_once(uuid,uuid,uuid,jsonb,uuid[],jsonb)','EXECUTE')
     OR has_table_privilege('authenticated','public.marketplace_checkout_requests','SELECT') THEN
    RAISE EXCEPTION 'client role has privileged access';
  END IF;
  RAISE NOTICE 'PASS: replay, stock, debt, payload mismatch, replay authorization, grants';
END $$;
ROLLBACK;
