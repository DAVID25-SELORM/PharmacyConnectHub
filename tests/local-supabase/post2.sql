-- Migration 2 (resubmission + server-stamped upload time) on the real schema.
DO $$
DECLARE
  rejw UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  pendw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  u_wr UUID := (SELECT id FROM zz.u WHERE k='w_rejected');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wp UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  r TEXT; st TEXT; reason TEXT; ts1 TIMESTAMPTZ; ts2 TIMESTAMPTZ; doc UUID;
BEGIN
  -- baseline: rejection recorded through the real audit trigger
  r := zz.run_as(u_admin, format('UPDATE public.businesses SET verification_status=''rejected'', rejection_reason=''Stamp missing'' WHERE id=%L', rejw));
  PERFORM zz.check('admin can reject (audit trail written)', r='OK' AND EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id=rejw AND activity='Business rejected'), r);

  r := zz.run_as(u_px, format('SELECT public.resubmit_business_verification(%L)', rejw));
  PERFORM zz.check('resubmit: non-owner denied', r LIKE 'ERR: Only the business owner%', r);
  r := zz.run_as(u_wr, format('SELECT public.resubmit_business_verification(%L)', rejw));
  PERFORM zz.check('resubmit: blocked while required documents are missing', r LIKE 'ERR: Upload all required documents%', r);

  -- owner uploads all three docs with a CLIENT-supplied far-future/past timestamp; the server must ignore it
  r := zz.run_as(u_wr, format($q$INSERT INTO public.license_documents(business_id, doc_type, storage_path, uploaded_at) VALUES
     (%1$L,'wholesale_license','p/a','2099-01-01'), (%1$L,'fda_certificate','p/b','2099-01-01'), (%1$L,'business_registration','p/c','1999-01-01')$q$, rejw));
  PERFORM zz.check('owner can upload onboarding documents (RLS)', r='OK', r);
  PERFORM zz.check('upload time is server-stamped on INSERT (client 2099/1999 ignored)',
    (SELECT bool_and(uploaded_at BETWEEN now() - interval '5 minutes' AND now() + interval '1 minute') FROM public.license_documents WHERE business_id = rejw));

END $$;
DO $$
DECLARE
  rejw UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  pendw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  u_wr UUID := (SELECT id FROM zz.u WHERE k='w_rejected');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wp UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  r TEXT; st TEXT; reason TEXT; ts1 TIMESTAMPTZ; ts2 TIMESTAMPTZ;
BEGIN
  UPDATE public.businesses SET verification_status='pending' WHERE id = rejw;               -- (as postgres) reset
  UPDATE public.businesses SET verification_status='rejected', rejection_reason='Address wrong' WHERE id = rejw;
  r := zz.run_as(u_wr, format('SELECT public.resubmit_business_verification(%L)', rejw));
  PERFORM zz.check('resubmit: unchanged since latest rejection is refused', r LIKE 'ERR: Update at least one required document%', r);

END $$;
DO $$
DECLARE
  rejw UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  pendw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  u_wr UUID := (SELECT id FROM zz.u WHERE k='w_rejected');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wp UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  r TEXT; st TEXT; reason TEXT; ts1 TIMESTAMPTZ; ts2 TIMESTAMPTZ;
BEGIN

  -- client tries to backdate/forward-date: setting uploaded_at alone must not count as a change
  r := zz.run_as(u_wr, format($q$UPDATE public.license_documents SET uploaded_at = '2099-01-01' WHERE business_id=%L$q$, rejw));
  SELECT max(uploaded_at) INTO ts1 FROM public.license_documents WHERE business_id = rejw;
  PERFORM zz.check('client cannot forge uploaded_at on UPDATE (value ignored)', ts1 < now() + interval '1 minute', r || ' max=' || ts1);
  r := zz.run_as(u_wr, format('SELECT public.resubmit_business_verification(%L)', rejw));
  PERFORM zz.check('resubmit: still refused after the forged-timestamp attempt', r LIKE 'ERR: Update at least one required document%', r);

END $$;
DO $$
DECLARE
  rejw UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  pendw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  u_wr UUID := (SELECT id FROM zz.u WHERE k='w_rejected');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wp UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  r TEXT; st TEXT; reason TEXT; ts1 TIMESTAMPTZ; ts2 TIMESTAMPTZ;
BEGIN

  -- genuine replacement
  r := zz.run_as(u_wr, format($q$UPDATE public.license_documents SET storage_path='p/a2', uploaded_at='1999-01-01' WHERE business_id=%L AND doc_type='wholesale_license'$q$, rejw));
  SELECT uploaded_at INTO ts2 FROM public.license_documents WHERE business_id = rejw AND doc_type='wholesale_license';
  PERFORM zz.check('replacement gets a server timestamp (client 1999 ignored)', r='OK' AND ts2 > now() - interval '1 minute', r || ' ts=' || ts2);
  r := zz.run_as(u_wr, format('SELECT public.resubmit_business_verification(%L)', rejw));
  SELECT verification_status::text, rejection_reason INTO st, reason FROM public.businesses WHERE id = rejw;
  PERFORM zz.check('resubmit: allowed after a genuine replacement; status -> pending; stale reason cleared', r='OK' AND st='pending' AND reason IS NULL, r || ' ' || st);
  PERFORM zz.check('audit history keeps rejection AND resubmission (with the replaced reason)',
    EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id=rejw AND activity='Business rejected')
    AND EXISTS (SELECT 1 FROM public.audit_logs WHERE record_id=rejw AND activity='Verification resubmitted' AND details->>'previous_rejection_reason'='Address wrong'));

  r := zz.run_as(u_wr, format('SELECT public.resubmit_business_verification(%L)', rejw));
  PERFORM zz.check('resubmit: idempotent while pending', r='OK', r);
  r := zz.run_as(u_wo, format('SELECT public.resubmit_business_verification(%L)', alpha));
  PERFORM zz.check('resubmit: approved business cannot call it', r LIKE 'ERR: Only a rejected business%', r);
  r := zz.run_as(u_wp, format('SELECT public.resubmit_business_verification(%L)', pendw));
  PERFORM zz.check('resubmit: never-rejected pending business is a no-op, not a bypass', r='OK' AND (SELECT verification_status::text FROM public.businesses WHERE id=pendw)='pending', r);

  -- no self-approval / direct status writes
  r := zz.run_as(u_wr, format('UPDATE public.businesses SET verification_status=''approved'' WHERE id=%L', rejw));
  PERFORM zz.check('owner cannot self-approve', r LIKE 'ERR: Only admins%', r);
  r := zz.run_as(u_wr, format('UPDATE public.businesses SET verification_status=''pending'' WHERE id=%L', rejw));
  PERFORM zz.check('owner cannot set status directly (only via the RPC)', r LIKE 'ERR: Only admins%' OR r = 'OK' AND (SELECT verification_status::text FROM public.businesses WHERE id=rejw)='pending', r);
  r := zz.run_as(u_admin, format('UPDATE public.businesses SET verification_status=''approved'' WHERE id=%L', rejw));
  PERFORM zz.check('platform admin can still approve', r='OK' AND (SELECT verification_status::text FROM public.businesses WHERE id=rejw)='approved', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok ORDER BY seq;
