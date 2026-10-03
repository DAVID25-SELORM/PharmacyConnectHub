-- Run in the isolated credit_review_clean fixture database, never production.
BEGIN;
DO $$
DECLARE f RECORD; rid UUID; rid2 UUID; debt NUMERIC;
BEGIN
 SELECT * INTO f FROM zz.cc;
 debt := public.credit_exposure(f.alpha,f.good);
 PERFORM set_config('request.jwt.claim.sub',f.u_po::text,true);
 BEGIN
  PERFORM public.set_credit_request_eligibility(f.good,true);
  RAISE EXCEPTION 'FAILED: pharmacy changed eligibility';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Only platform admins%' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.request_credit_account(f.good,f.alpha,6000);
  RAISE EXCEPTION 'FAILED: disabled pharmacy requested credit';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Credit requests are not enabled%' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='admin'),true);
 PERFORM public.set_credit_request_eligibility(f.good,true);
 PERFORM set_config('request.jwt.claim.sub',f.u_po::text,true);
 rid:=public.request_credit_account(f.good,f.alpha,6000);
 rid2:=public.request_credit_account(f.good,f.alpha,7000);
 IF rid<>rid2 THEN RAISE EXCEPTION 'FAILED: duplicate pending request'; END IF;
 IF public.credit_exposure(f.alpha,f.good)<>debt THEN RAISE EXCEPTION 'FAILED: request created debt'; END IF;
 BEGIN
  PERFORM public.review_credit_account_request(rid,true,6000,30,'Approved account');
  RAISE EXCEPTION 'FAILED: pharmacy approved its own credit';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Only this supplier%' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='w_other'),true);
 BEGIN
  PERFORM public.review_credit_account_request(rid,true,6000,30,'Approved account');
  RAISE EXCEPTION 'FAILED: other supplier approved credit';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Only this supplier%' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='w_owner'),true);
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='admin'),true);
 PERFORM public.set_credit_request_eligibility(f.good,false);
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='w_owner'),true);
 BEGIN
  PERFORM public.review_credit_account_request(rid,true,6000,45,'Disabled approval');
  RAISE EXCEPTION 'FAILED: disabled eligibility approved';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'This request has expired%' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='admin'),true);
 PERFORM public.set_credit_request_eligibility(f.good,true);
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='w_owner'),true);
 PERFORM public.review_credit_account_request(rid,true,6000,45,'Approved ongoing account');
 IF NOT EXISTS(SELECT 1 FROM public.wholesaler_credit_terms WHERE wholesaler_id=f.alpha AND pharmacy_id=f.good AND active AND credit_limit_ghs=6000 AND payment_terms_days=45) THEN RAISE EXCEPTION 'FAILED: ongoing terms not saved'; END IF;
 BEGIN
  PERFORM public.review_credit_account_request(rid,true,9000,30,'Duplicate approval');
  RAISE EXCEPTION 'FAILED: duplicate approval allowed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'This request has already%' THEN RAISE; END IF; END;
 IF public.credit_exposure(f.alpha,f.good)<>debt THEN RAISE EXCEPTION 'FAILED: approval created debt'; END IF;
 UPDATE public.wholesaler_credit_terms SET status='blocked' WHERE wholesaler_id=f.alpha AND pharmacy_id=f.good;
 PERFORM set_config('request.jwt.claim.sub',f.u_po::text,true);
 BEGIN
  PERFORM public.request_credit_account(f.good,f.alpha,7000);
  RAISE EXCEPTION 'FAILED: blocked account bypass';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'This supplier has suspended%' THEN RAISE; END IF; END;
 UPDATE public.wholesaler_credit_terms SET status='active' WHERE wholesaler_id=f.alpha AND pharmacy_id=f.good;
 rid:=public.request_credit_account(f.good,f.alpha,7000);
 UPDATE public.credit_account_requests SET expires_at=now()-interval '1 minute' WHERE id=rid;
 PERFORM set_config('request.jwt.claim.sub',(SELECT id::text FROM zz.u WHERE k='w_owner'),true);
 BEGIN
  PERFORM public.review_credit_account_request(rid,true,7000,30,'Expired approval');
  RAISE EXCEPTION 'FAILED: expired request approved';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'This request has expired%' THEN RAISE; END IF; END;
 PERFORM public.review_credit_account_request(rid,false,NULL,NULL,'Request has expired');
 IF (SELECT status FROM public.credit_account_requests WHERE id=rid)<>'rejected' THEN RAISE EXCEPTION 'FAILED: rejection missing'; END IF;
 IF has_table_privilege('authenticated','public.credit_request_eligibility','UPDATE') OR has_table_privilege('authenticated','public.credit_account_requests','INSERT') THEN RAISE EXCEPTION 'FAILED: direct mutation granted'; END IF;
 RAISE NOTICE 'PASS: eligibility, duplicate requests, ownership, ongoing terms, no debt, blocked accounts, expiry, rejection, grants';
END $$;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000007',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.credit_account_requests WHERE pharmacy_id='d8040e49-aad4-4c84-a75a-6bcab81a4fb2') THEN RAISE EXCEPTION 'FAILED: another supplier read requests'; END IF;
 IF EXISTS(SELECT 1 FROM public.credit_request_eligibility WHERE pharmacy_id='d8040e49-aad4-4c84-a75a-6bcab81a4fb2') THEN RAISE EXCEPTION 'FAILED: another supplier read eligibility'; END IF;
 RAISE NOTICE 'PASS: tenant isolation';
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000008',true);
SET LOCAL ROLE authenticated;
DO $$ BEGIN
 IF (SELECT count(*) FROM public.credit_account_requests WHERE pharmacy_id='d8040e49-aad4-4c84-a75a-6bcab81a4fb2')<>2 THEN RAISE EXCEPTION 'FAILED: pharmacy cannot read its decisions'; END IF;
 RAISE NOTICE 'PASS: pharmacy can read its request history';
END $$;
RESET ROLE;
ROLLBACK;
