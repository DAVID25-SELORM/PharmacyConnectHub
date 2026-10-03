-- Admin-enabled applications for ongoing supplier credit. No stock or ledger mutation on request.
CREATE TABLE public.credit_request_eligibility (
 pharmacy_id UUID PRIMARY KEY REFERENCES public.businesses(id),
 enabled BOOLEAN NOT NULL DEFAULT false,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE public.credit_account_requests (
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 pharmacy_id UUID NOT NULL REFERENCES public.businesses(id),
 wholesaler_id UUID NOT NULL REFERENCES public.businesses(id),
 requested_limit NUMERIC(12,2) NOT NULL CHECK(requested_limit > 0 AND requested_limit <= 10000000),
 status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
 requested_by UUID NOT NULL REFERENCES auth.users(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '7 days',
 reviewed_by UUID REFERENCES auth.users(id),
 reviewed_at TIMESTAMPTZ,
 reason TEXT,
 approved_limit NUMERIC(12,2),
 approved_days INTEGER
);
CREATE UNIQUE INDEX credit_account_request_pending ON public.credit_account_requests(pharmacy_id,wholesaler_id) WHERE status='pending';
ALTER TABLE public.credit_request_eligibility ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_account_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.credit_request_eligibility, public.credit_account_requests FROM anon, authenticated;
GRANT SELECT ON public.credit_request_eligibility, public.credit_account_requests TO authenticated;
-- RLS uses a narrowly scoped definer helper: can_act_for_business is internal-only.
CREATE FUNCTION public.can_read_credit_request(p_pharmacy_id UUID,p_wholesaler_id UUID DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT auth.uid() IS NOT NULL AND (public.has_role(auth.uid(),'admin')
 OR public.can_act_for_business(p_pharmacy_id,'read')
 OR (p_wholesaler_id IS NOT NULL AND public.can_act_for_business(p_wholesaler_id,'manage')))
$$;
REVOKE ALL ON FUNCTION public.can_read_credit_request(UUID,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_read_credit_request(UUID,UUID) TO authenticated;
CREATE POLICY eligibility_read ON public.credit_request_eligibility FOR SELECT TO authenticated USING (
 public.can_read_credit_request(pharmacy_id,NULL));
CREATE POLICY credit_requests_read ON public.credit_account_requests FOR SELECT TO authenticated USING (
 public.can_read_credit_request(pharmacy_id,wholesaler_id));

CREATE FUNCTION public.set_credit_request_eligibility(p_pharmacy_id UUID,p_enabled BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(),'admin') THEN RAISE EXCEPTION 'Only platform admins may enable credit requests.'; END IF;
 IF p_enabled IS NULL THEN RAISE EXCEPTION 'An enabled value is required.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND type::text='pharmacy' AND verification_status='approved') THEN RAISE EXCEPTION 'Choose a verified pharmacy.'; END IF;
 INSERT INTO public.credit_request_eligibility(pharmacy_id,enabled) VALUES(p_pharmacy_id,p_enabled)
 ON CONFLICT(pharmacy_id) DO UPDATE SET enabled=EXCLUDED.enabled,updated_at=now();
 PERFORM public.write_audit_log('Credit request eligibility changed','Platform','business',p_pharmacy_id,NULL,jsonb_build_object('enabled',p_enabled));
END $$;

CREATE FUNCTION public.request_credit_account(p_pharmacy_id UUID,p_wholesaler_id UUID,p_limit NUMERIC)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_id UUID; v_enabled BOOLEAN; v_status TEXT;
BEGIN
 IF auth.uid() IS NULL OR NOT public.can_act_for_business(p_pharmacy_id,'manage') THEN RAISE EXCEPTION 'Only pharmacy owners and managers may request credit.'; END IF;
 SELECT enabled INTO v_enabled FROM public.credit_request_eligibility WHERE pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF NOT COALESCE(v_enabled,false) THEN RAISE EXCEPTION 'Credit requests are not enabled for this pharmacy.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_pharmacy_id AND type::text='pharmacy' AND verification_status='approved')
 OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=p_wholesaler_id AND type::text='wholesaler' AND verification_status='approved') THEN RAISE EXCEPTION 'Both businesses must be verified.'; END IF;
 IF p_limit IS NULL OR p_limit::text IN ('NaN','Infinity','-Infinity') OR round(p_limit,2)<=0 OR p_limit>10000000 THEN RAISE EXCEPTION 'Enter a limit above zero and at most GHS 10,000,000.'; END IF;
 SELECT status INTO v_status FROM public.wholesaler_credit_terms WHERE wholesaler_id=p_wholesaler_id AND pharmacy_id=p_pharmacy_id FOR UPDATE;
 IF v_status IN ('suspended','blocked') THEN RAISE EXCEPTION 'This supplier has suspended or blocked credit. Contact them directly.'; END IF;
 UPDATE public.credit_account_requests SET status='rejected',reason='Request expired',reviewed_at=now()
 WHERE pharmacy_id=p_pharmacy_id AND wholesaler_id=p_wholesaler_id AND status='pending' AND expires_at<=now();
 SELECT id INTO v_id FROM public.credit_account_requests WHERE pharmacy_id=p_pharmacy_id AND wholesaler_id=p_wholesaler_id AND status='pending';
 IF v_id IS NOT NULL THEN RETURN v_id; END IF;
 INSERT INTO public.credit_account_requests(pharmacy_id,wholesaler_id,requested_limit,requested_by)
 VALUES(p_pharmacy_id,p_wholesaler_id,round(p_limit,2),auth.uid()) RETURNING id INTO v_id;
 PERFORM public.write_audit_log('Credit account requested','Pharmacy','business',p_pharmacy_id,NULL,jsonb_build_object('request_id',v_id,'wholesaler_id',p_wholesaler_id,'requested_limit',round(p_limit,2)));
 PERFORM public.notify_business(p_wholesaler_id,ARRAY['owner','manager'],'credit_status','Credit account requested','A pharmacy has requested an ongoing credit account. Review it in Credit.','/wholesaler?tab=credit',jsonb_build_object('request_id',v_id));
 RETURN v_id;
END $$;

CREATE FUNCTION public.review_credit_account_request(p_request_id UUID,p_accept BOOLEAN,p_limit NUMERIC DEFAULT NULL,p_days INTEGER DEFAULT NULL,p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.credit_account_requests; v_pharmacy UUID; v_enabled BOOLEAN; v_status TEXT; v_note TEXT;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in to review requests.'; END IF;
 SELECT pharmacy_id INTO v_pharmacy FROM public.credit_account_requests WHERE id=p_request_id;
 SELECT enabled INTO v_enabled FROM public.credit_request_eligibility WHERE pharmacy_id=v_pharmacy FOR UPDATE;
 SELECT * INTO r FROM public.credit_account_requests WHERE id=p_request_id FOR UPDATE;
 IF NOT FOUND OR NOT public.can_act_for_business(r.wholesaler_id,'manage') THEN RAISE EXCEPTION 'Only this supplier owner or manager may review requests.'; END IF;
 IF p_accept IS NULL THEN RAISE EXCEPTION 'Choose accept or reject.'; END IF;
 IF r.status<>'pending' THEN RAISE EXCEPTION 'This request has already been reviewed.'; END IF;
 IF char_length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 5 AND 500 THEN RAISE EXCEPTION 'Provide a reason of 5 to 500 characters.'; END IF;
 IF p_accept THEN
  IF NOT COALESCE(v_enabled,false) OR r.expires_at<=now() THEN RAISE EXCEPTION 'This request has expired or eligibility was disabled.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=r.pharmacy_id AND verification_status='approved') OR NOT EXISTS(SELECT 1 FROM public.businesses WHERE id=r.wholesaler_id AND verification_status='approved') THEN RAISE EXCEPTION 'Both businesses must be verified.'; END IF;
  SELECT status,internal_note INTO v_status,v_note FROM public.wholesaler_credit_terms WHERE wholesaler_id=r.wholesaler_id AND pharmacy_id=r.pharmacy_id FOR UPDATE;
  IF v_status IN ('suspended','blocked') THEN RAISE EXCEPTION 'Reactivate this credit account separately before approving a request.'; END IF;
  IF p_limit IS NULL OR p_limit::text IN ('NaN','Infinity','-Infinity') OR round(p_limit,2)<=0 OR p_limit>10000000 OR p_days IS NULL OR p_days NOT BETWEEN 1 AND 365 THEN RAISE EXCEPTION 'Provide a valid credit limit and 1 to 365 payment days.'; END IF;
  IF round(p_limit,2)<public.credit_exposure(r.wholesaler_id,r.pharmacy_id) THEN RAISE EXCEPTION 'The limit cannot be below current outstanding credit.'; END IF;
  PERFORM public.set_credit_terms(r.wholesaler_id,r.pharmacy_id,round(p_limit,2),p_days,v_note);
 END IF;
 UPDATE public.credit_account_requests SET status=CASE WHEN p_accept THEN 'approved' ELSE 'rejected' END,
 reviewed_by=auth.uid(),reviewed_at=now(),reason=btrim(p_reason),approved_limit=CASE WHEN p_accept THEN round(p_limit,2) END,approved_days=CASE WHEN p_accept THEN p_days END WHERE id=r.id;
 PERFORM public.write_audit_log('Credit account request reviewed','Wholesaler','business',r.pharmacy_id,NULL,jsonb_build_object('request_id',r.id,'accepted',p_accept,'limit',p_limit,'days',p_days,'reason',btrim(p_reason)));
 PERFORM public.notify_business(r.pharmacy_id,ARRAY['owner','manager'],'credit_status',CASE WHEN p_accept THEN 'Credit account approved' ELSE 'Credit request rejected' END,btrim(p_reason),'/pharmacy?tab=credit',jsonb_build_object('request_id',r.id));
END $$;
REVOKE ALL ON FUNCTION public.set_credit_request_eligibility(UUID,BOOLEAN),public.request_credit_account(UUID,UUID,NUMERIC),public.review_credit_account_request(UUID,BOOLEAN,NUMERIC,INTEGER,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_credit_request_eligibility(UUID,BOOLEAN),public.request_credit_account(UUID,UUID,NUMERIC),public.review_credit_account_request(UUID,BOOLEAN,NUMERIC,INTEGER,TEXT) TO authenticated;
