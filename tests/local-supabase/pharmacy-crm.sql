-- Isolated credit_review_clean fixtures only.
BEGIN;
DO $$
DECLARE f RECORD; rep UUID; company UUID; visit UUID; followup UUID; other UUID; before_count INTEGER;
BEGIN
 SELECT * INTO f FROM zz.cc;
 PERFORM set_config('request.jwt.claim.sub',f.u_po::text,true);
 rep:=public.save_pharmacy_crm(f.good,'representatives',jsonb_build_object('name','Private rep','created_by',gen_random_uuid()));
 IF NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_representatives WHERE id=rep AND created_by=f.u_po AND status='active') THEN RAISE EXCEPTION 'Identity/default failure'; END IF;
 company:=public.save_pharmacy_crm(f.good,'companies',jsonb_build_object('name','Test supplier','wholesaler_id',f.alpha));
 PERFORM public.save_pharmacy_crm(f.good,'rep_companies',jsonb_build_object('rep_id',rep,'company_id',company,'designated',true));
 visit:=public.save_pharmacy_crm(f.good,'interactions',jsonb_build_object('rep_id',rep,'purpose','Review products','followup_due_at',now()+interval '1 day'));
 SELECT id INTO followup FROM public.pharmacy_crm_followups WHERE interaction_id=visit;
 IF followup IS NULL THEN RAISE EXCEPTION 'Atomic followup missing'; END IF;
 PERFORM public.save_pharmacy_crm(f.good,'followups',jsonb_build_object('status','completed','completed_by',gen_random_uuid()),followup);
 IF NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_followups WHERE id=followup AND completed_by=f.u_po AND completed_at IS NOT NULL) THEN RAISE EXCEPTION 'Completion identity failure'; END IF;
 SELECT count(*) INTO before_count FROM public.pharmacy_crm_interactions;
 BEGIN
  PERFORM public.save_pharmacy_crm(f.good,'interactions',jsonb_build_object('rep_id',rep,'purpose','Atomic rollback','followup_due_at','invalid date'));
  RAISE EXCEPTION 'Accepted invalid date';
 EXCEPTION WHEN invalid_datetime_format THEN NULL; END;
 IF (SELECT count(*) FROM public.pharmacy_crm_interactions)<>before_count THEN RAISE EXCEPTION 'Partial visit saved'; END IF;
 BEGIN
  PERFORM public.save_pharmacy_crm(f.good,'procurement_links',jsonb_build_object('rep_id',rep,'order_id',gen_random_uuid()));
  RAISE EXCEPTION 'Accepted foreign order';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Order belongs%' THEN RAISE; END IF; END;
 PERFORM public.save_pharmacy_crm(f.good,'representatives','{"archived":true}',rep);
 IF EXISTS(SELECT 1 FROM public.pharmacy_crm_rep_companies WHERE rep_id=rep AND designated) THEN RAISE EXCEPTION 'Archived designated rep'; END IF;
 IF (SELECT count(*) FROM public.pharmacy_crm_activity WHERE rep_id=rep)<5 THEN RAISE EXCEPTION 'Audit missing'; END IF;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='ph_other'),true);
 BEGIN
  PERFORM public.save_pharmacy_crm(f.good,'representatives','{"name":"Intruder"}',rep);
  RAISE EXCEPTION 'Cross pharmacy mutation';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Only this pharmacy%' THEN RAISE; END IF; END;
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.pharmacy_crm_representatives) OR EXISTS(SELECT 1 FROM public.pharmacy_crm_activity) THEN RAISE EXCEPTION 'Cross pharmacy read'; END IF;
 BEGIN
 INSERT INTO public.pharmacy_crm_representatives(pharmacy_id,name) VALUES(gen_random_uuid(),'Direct write');
 RAISE EXCEPTION 'Direct write allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
DO $$
DECLARE f RECORD; staff UUID;
BEGIN
 SELECT * INTO f FROM zz.cc;
 SELECT id INTO staff FROM zz.u WHERE k='nobody';
 INSERT INTO public.business_staff(business_id,user_id,role,status) VALUES(f.good,staff,'cashier','active') ON CONFLICT(business_id,user_id) DO UPDATE SET role='cashier',status='active';
 PERFORM set_config('request.jwt.claim.sub',staff::text,true);
 IF public.can_manage_pharmacy_crm(f.good) THEN RAISE EXCEPTION 'Cashier access'; END IF;
 UPDATE public.business_staff SET role='manager' WHERE business_id=f.good AND user_id=staff;
 IF NOT public.can_manage_pharmacy_crm(f.good) THEN RAISE EXCEPTION 'Manager denied'; END IF;
 PERFORM public.save_pharmacy_crm(f.good,'representatives','{"name":"Manager created"}');
 UPDATE public.business_staff SET status='inactive' WHERE business_id=f.good AND user_id=staff;
 IF public.can_manage_pharmacy_crm(f.good) THEN RAISE EXCEPTION 'Inactive manager access'; END IF;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='admin'),true);
 IF public.can_manage_pharmacy_crm(f.good) THEN RAISE EXCEPTION 'Admin bypass'; END IF;
 PERFORM set_config('request.jwt.claim.sub',f.u_po::text,true);
END $$;
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_representatives) THEN RAISE EXCEPTION 'Owner RLS denied'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.pharmacy_crm_activity) THEN RAISE EXCEPTION 'Owner history denied'; END IF;
END $$;
RESET ROLE;
ROLLBACK;
