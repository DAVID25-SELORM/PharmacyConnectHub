-- Read-only checks after scheduling. Run in the production SQL editor.

-- 1) The job exists and is active (expect 1 row, schedule */5 * * * *, active = true).
select jobname, schedule, active from cron.job where jobname = 'drugxone-push-dispatch';

-- 2) Recent runs of the job itself (wait ~10 minutes after scheduling). status should be 'succeeded'.
select start_time, status, left(return_message, 120) as message
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'drugxone-push-dispatch')
order by start_time desc limit 5;

-- 3) What the function answered (net.http_post is asynchronous; status_code 200 = ran,
--    401 = wrong secret, 503 = a secret is missing in the function, 404 = function not deployed).
select created, status_code, left(content::text, 200) as response
from net._http_response
order by created desc limit 5;

-- 4) Devices that have turned on closed-tab alerts, and alerts already delivered.
select (select count(*) from public.push_subscriptions) as subscribed_devices,
       (select count(*) from public.push_notification_deliveries) as delivered_alerts;
