-- Read-only checks after applying the enterprise RFQ and branding migrations.
-- Run the complete script in the Supabase SQL editor and inspect NOTICE output.
BEGIN TRANSACTION READ ONLY;
DO $$
DECLARE signature text; job_ok boolean;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.rfq_transition(uuid,text,integer,text,timestamp with time zone)',
    'public.rfq_negotiate(uuid,uuid,uuid,jsonb)',
    'public.rfq_respond_negotiation(uuid,text,text,uuid)',
    'public.list_enterprise_rfqs(uuid,jsonb,integer,integer)',
    'public.rfq_procurement_report(uuid,date,date)',
    'public.investigate_rfq(uuid,text)',
    'public.run_enterprise_rfq_deadline_reminders()',
    'public.can_read_business_document_branding(uuid)',
    'public.business_document_logo_write_access(text)',
    'public.save_business_document_branding(uuid,text,text,text,boolean,boolean,text,text,text,text)'
  ] LOOP
    IF to_regprocedure(signature) IS NULL THEN
      RAISE EXCEPTION 'Missing function: %', signature;
    END IF;
  END LOOP;
  IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid=to_regclass('public.business_document_branding') AND relrowsecurity) THEN
    RAISE EXCEPTION 'Branding table or row security missing';
  END IF;
  IF NOT has_function_privilege('authenticated','public.can_read_business_document_branding(uuid)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.business_document_logo_write_access(text)','EXECUTE') THEN
    RAISE EXCEPTION 'Branding policy helper grants missing';
  END IF;
  IF has_table_privilege('authenticated','public.business_document_branding','INSERT')
     OR has_table_privilege('authenticated','public.business_document_branding','UPDATE')
     OR has_table_privilege('authenticated','public.business_document_branding','DELETE') THEN
    RAISE EXCEPTION 'Branding direct write privileges unexpectedly enabled';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM storage.buckets WHERE id='business-document-logos' AND public AND file_size_limit=2097152) THEN
    RAISE EXCEPTION 'Logo bucket configuration missing or unexpected';
  END IF;
  RAISE NOTICE 'PASS: required function signatures, branding RLS, helper grants and logo bucket';
  IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    EXECUTE 'SELECT EXISTS(SELECT 1 FROM cron.job WHERE jobname=$1 AND active AND schedule=$2 AND command=$3)'
      INTO job_ok USING 'drugxone-enterprise-rfq-reminders','0 * * * *','SELECT public.run_enterprise_rfq_deadline_reminders()';
    IF job_ok THEN RAISE NOTICE 'PASS: hourly RFQ reminder job registered';
    ELSE RAISE WARNING 'Hourly RFQ reminder job missing or misconfigured'; END IF;
  ELSE
    RAISE WARNING 'pg_cron is not enabled; hourly RFQ reminders are not scheduled';
  END IF;
END $$;
SELECT schemaname,tablename,policyname,cmd
FROM pg_policies
WHERE (schemaname='public' AND tablename='business_document_branding')
   OR (schemaname='storage' AND tablename='objects' AND policyname LIKE '%document logos')
ORDER BY schemaname,tablename,policyname;
ROLLBACK;
