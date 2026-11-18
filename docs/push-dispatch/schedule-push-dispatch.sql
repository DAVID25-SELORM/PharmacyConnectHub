-- Schedule closed-tab push delivery every 5 minutes, from the database (not from Vercel).
-- Run ONCE in the Supabase SQL editor of the production project, AFTER the `push-dispatch` edge
-- function is deployed and its secrets are set (see README.md in this folder).
--
-- Before running: replace BOTH placeholders below
--   <PROJECT_REF>        the project ref in the dashboard URL (ywpntuioeqpreouauuir)
--   <PUSH_CRON_SECRET>   the same long random value you set as the PUSH_CRON_SECRET function secret
-- The secret is stored in the cron job's definition (visible to database admins only). Do not
-- commit this file with the real secret filled in.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- Re-running replaces the job instead of adding a second one.
select cron.unschedule(jobid) from cron.job where jobname = 'drugxone-push-dispatch';

select cron.schedule(
  'drugxone-push-dispatch',
  '*/5 * * * *',
  $job$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/push-dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer <PUSH_CRON_SECRET>'
    ),
    body := '{}'::jsonb
  );
  $job$
);
