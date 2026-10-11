BEGIN;

-- Send deadline reminders centrally; the receipt key makes hourly runs idempotent.
CREATE FUNCTION public.run_enterprise_rfq_deadline_reminders() RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r RECORD; affected INTEGER; total INTEGER:=0;
BEGIN
 FOR r IN
  SELECT q.id,q.title,q.response_deadline,i.wholesaler_id
  FROM public.rfqs q JOIN public.rfq_invitees i ON i.rfq_id=q.id
  WHERE q.enterprise AND q.status IN('open','partially_awarded')
    AND q.response_deadline>now() AND q.response_deadline<=now()+interval '24 hours'
    AND i.response_status<>'declined'
  ORDER BY q.response_deadline,q.id,i.wholesaler_id
 LOOP
  INSERT INTO public.rfq_reminder_receipts(rfq_id,wholesaler_id,deadline)
  VALUES(r.id,r.wholesaler_id,r.response_deadline) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS affected=ROW_COUNT;
  IF affected>0 THEN
   PERFORM public.notify_business(r.wholesaler_id,ARRAY['owner','manager','cashier','warehouse'],
     'rfq_deadline','RFQ deadline within 24 hours',r.title,
     '/wholesaler/rfqs?rfq='||r.id);
   total:=total+1;
  END IF;
 END LOOP;
 RETURN total;
END $$;
REVOKE ALL ON FUNCTION public.run_enterprise_rfq_deadline_reminders() FROM PUBLIC,anon,authenticated;

DO $$
BEGIN
 IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
  PERFORM cron.schedule('drugxone-enterprise-rfq-reminders','0 * * * *',
    'SELECT public.run_enterprise_rfq_deadline_reminders()');
 ELSE
  RAISE NOTICE 'pg_cron is not enabled: RFQ reminders can still be generated when participants open the RFQ workspace.';
 END IF;
EXCEPTION WHEN OTHERS THEN
 RAISE NOTICE 'Could not schedule RFQ deadline reminders: %',SQLERRM;
END $$;

COMMIT;
