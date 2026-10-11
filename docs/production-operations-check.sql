-- Read-only operational evidence. Run after the corrective migration.
BEGIN TRANSACTION READ ONLY;
SELECT position('jsonb_object_length' IN pg_get_functiondef('public.rfq_negotiate(uuid,uuid,uuid,jsonb)'::regprocedure))=0
  AS negotiation_unsupported_call_removed;
SELECT position('issuer' IN pg_get_functiondef('public.rfq_document(uuid,uuid,uuid)'::regprocedure))>0
  AS rfq_issuer_payload_present;
-- Requires pg_cron, already confirmed by the postflight checks.
SELECT jobid,jobname,schedule,active FROM cron.job
WHERE jobname='drugxone-enterprise-rfq-reminders';
SELECT d.status,d.return_message,d.start_time,d.end_time
FROM cron.job_run_details d JOIN cron.job j ON j.jobid=d.jobid
WHERE j.jobname='drugxone-enterprise-rfq-reminders'
ORDER BY d.start_time DESC LIMIT 10;
ROLLBACK;
