BEGIN;
DO $$
DECLARE target UUID;
BEGIN
 SELECT id INTO STRICT target FROM public.orders WHERE status='pending' ORDER BY created_at DESC LIMIT 1;
 UPDATE public.orders SET status='accepted' WHERE id=target;
 UPDATE public.orders SET status='picking' WHERE id=target;
 BEGIN
   UPDATE public.orders SET status='cancelled' WHERE id=target;
   RAISE EXCEPTION 'invalid picking cancellation allowed';
 EXCEPTION WHEN OTHERS THEN
   IF SQLERRM NOT LIKE 'Invalid order transition:%' THEN RAISE; END IF;
 END;
 UPDATE public.orders SET status='packed' WHERE id=target;
 UPDATE public.orders SET status='ready_for_dispatch' WHERE id=target;
 UPDATE public.orders SET status='dispatched' WHERE id=target;
 UPDATE public.orders SET status='delivered' WHERE id=target;
 BEGIN
   UPDATE public.orders SET total_ghs=total_ghs+1 WHERE id=target;
   RAISE EXCEPTION 'financial immutability lost';
 EXCEPTION WHEN OTHERS THEN
   IF SQLERRM NOT LIKE 'Order parties and historical financial fields%' THEN RAISE; END IF;
 END;
 RAISE NOTICE 'PASS: full fulfilment chain, invalid transition rejected, financial immutability preserved';
END $$;
ROLLBACK;
