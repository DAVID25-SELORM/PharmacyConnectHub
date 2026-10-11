-- Isolated local zz.cc fixture only. Every change rolls back.
BEGIN;
CREATE FUNCTION pg_temp.branding_check(ok BOOLEAN, message TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',message; END IF;
  RAISE NOTICE 'PASS: %',message;
END $$;
DO $$
DECLARE c RECORD; n INTEGER; denied BOOLEAN; path TEXT;
BEGIN
  SELECT * INTO c FROM zz.cc LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',c.u_po::text,true);
  SET LOCAL ROLE authenticated;
  PERFORM public.save_business_document_branding(c.good,p_footer_note=>'Original footer');
  SELECT count(*) INTO n FROM public.business_document_branding WHERE business_id=c.good;
  PERFORM pg_temp.branding_check(n=1,'Authenticated owner can save and read branding through RLS');
  PERFORM public.save_business_document_branding(c.good,p_footer_note=>'Updated footer');
  PERFORM pg_temp.branding_check((SELECT footer_note='Updated footer' FROM public.business_document_branding WHERE business_id=c.good),'Update trigger and RPC work');
  denied:=false;
  BEGIN UPDATE public.business_document_branding SET display_name='Bypass' WHERE business_id=c.good;
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  PERFORM pg_temp.branding_check(denied,'Direct writes cannot bypass RPC logo validation');
  denied:=false;
  BEGIN PERFORM public.save_business_document_branding(c.alpha);
  EXCEPTION WHEN raise_exception THEN denied:=true; END;
  PERFORM pg_temp.branding_check(denied,'Cross-business branding modification refused');
  path:=c.good::text||'/preflight.png';
  PERFORM pg_temp.branding_check(public.business_document_logo_write_access(path),'Authenticated owner can execute storage policy predicate');
  PERFORM pg_temp.branding_check(NOT public.business_document_logo_write_access(c.alpha::text||'/preflight.png'),'Cross-business logo write refused');
  PERFORM pg_temp.branding_check(NOT public.business_document_logo_write_access('invalid/logo.png'),'Malformed logo path refused');
  denied:=false;
  BEGIN PERFORM public.save_business_document_branding(c.good,p_logo_path=>path);
  EXCEPTION WHEN raise_exception THEN denied:=true; END;
  PERFORM pg_temp.branding_check(denied,'Nonexistent logo cannot be registered');
  INSERT INTO storage.objects(bucket_id,name) VALUES('business-document-logos',path);
  PERFORM public.save_business_document_branding(c.good,p_logo_path=>path);
  PERFORM pg_temp.branding_check((SELECT logo_path=path FROM public.business_document_branding WHERE business_id=c.good),'Own uploaded logo can be registered');
  denied:=false;
  BEGIN INSERT INTO storage.objects(bucket_id,name) VALUES('business-document-logos',c.alpha::text||'/forged.png');
  EXCEPTION WHEN insufficient_privilege THEN denied:=true; END;
  PERFORM pg_temp.branding_check(denied,'Storage RLS rejects another business folder');
  denied:=false;
  BEGIN PERFORM public.save_business_document_branding(c.good,p_logo_path=>c.alpha::text||'/forged.png');
  EXCEPTION WHEN raise_exception THEN denied:=true; END;
  PERFORM pg_temp.branding_check(denied,'RPC rejects another business logo reference');
  RESET ROLE;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000000',true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO n FROM public.business_document_branding WHERE business_id=c.good;
  PERFORM pg_temp.branding_check(n=0,'Unrelated user cannot read branding');
  RESET ROLE;
END $$;
ROLLBACK;
