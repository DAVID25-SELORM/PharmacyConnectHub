-- Admin verification queue: ordering, filters, document counts, waiting time, summary, access.
-- Run after setup.sql + migrations (through 20260924190000_admin_verification_queue.sql).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  RETURN r;
END $$;

DO $$
DECLARE
  pp UUID := (SELECT id FROM zz.b WHERE name='Pending Pharmacy');
  pw UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  rw UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner'); u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  r TEXT;
BEGIN
  UPDATE public.businesses SET created_at = now() - interval '3 days' WHERE id = pp;
  UPDATE public.businesses SET created_at = now() - interval '10 days' WHERE id = pw;
  UPDATE public.businesses SET created_at = now() - interval '20 days' WHERE id = rw;
  DELETE FROM public.audit_logs WHERE activity = 'Verification resubmitted';
  INSERT INTO public.audit_logs(activity, organization, record_type, record_id, record_label, details, created_at)
  VALUES ('Verification resubmitted', 'Pending Wholesale', 'business', pw, 'Pending Wholesale', '{}', now() - interval '2 days');
  DELETE FROM public.license_documents;
  INSERT INTO public.license_documents(business_id, doc_type, storage_path) VALUES
    (pp, 'pharmacy_council', 'p/1'),
    (pw, 'wholesale_license', 'p/2'), (pw, 'fda_certificate', 'p/3'), (pw, 'business_registration', 'p/4'),
    (rw, 'wholesale_license', 'p/5'), (rw, 'other', 'p/7');

  r := zz.val_as(u_admin, 'SELECT string_agg(business_name, ''|'' ORDER BY ord) FROM (SELECT business_name, row_number() OVER () ord FROM public.admin_verification_queue()) q');
  PERFORM zz.check('default queue: pending only, oldest submission first (resubmission counts from its own date)', r = 'Pending Pharmacy|Pending Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT summary_pending || ''/'' || summary_new || ''/'' || summary_resubmitted || ''/'' || summary_rejected || ''/'' || summary_longest_wait_days FROM public.admin_verification_queue() LIMIT 1');
  PERFORM zz.check('summary: 2 pending, 1 new, 1 resubmitted, 1 rejected, longest wait 3 days', r = '2/1/1/1/3', r);
  r := zz.val_as(u_admin, 'SELECT business_name FROM public.admin_verification_queue(''new'')');
  PERFORM zz.check('filter new', r = 'Pending Pharmacy', r);
  r := zz.val_as(u_admin, 'SELECT business_name FROM public.admin_verification_queue(''resubmitted'')');
  PERFORM zz.check('filter resubmitted', r = 'Pending Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT business_name FROM public.admin_verification_queue(''rejected'')');
  PERFORM zz.check('filter rejected', r = 'Rejected Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'')');
  PERFORM zz.check('all = pending + rejected, approved businesses never appear', r = '3', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', ''wholesaler'')');
  PERFORM zz.check('type filter wholesaler', r = '2', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', ''pharmacy'')');
  PERFORM zz.check('type filter pharmacy', r = '1', r);
  r := zz.val_as(u_admin, 'SELECT business_name FROM public.admin_verification_queue(''pending'', NULL, NULL, ''newest'') LIMIT 1');
  PERFORM zz.check('sort newest first', r = 'Pending Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT string_agg(business_name, ''|'' ORDER BY ord) FROM (SELECT business_name, row_number() OVER () ord FROM public.admin_verification_queue(''all'', NULL, NULL, ''name'')) q');
  PERFORM zz.check('sort by name', r = 'Pending Pharmacy|Pending Wholesale|Rejected Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', NULL, ''Rejected'')');
  PERFORM zz.check('search by name', r = '1', r);
  r := zz.val_as(u_admin, 'SELECT business_name FROM public.admin_verification_queue(''all'', NULL, ''W-2'')');
  PERFORM zz.check('search by licence number', r = 'Pending Wholesale', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', NULL, ''%'')');
  PERFORM zz.check('search treats % literally', r = '0', r);

  r := zz.val_as(u_admin, 'SELECT docs_uploaded || ''/'' || docs_required FROM public.admin_verification_queue(''all'') WHERE business_name = ''Pending Pharmacy''');
  PERFORM zz.check('pharmacy with 1 of 2 required documents', r = '1/2', r);
  r := zz.val_as(u_admin, 'SELECT docs_uploaded || ''/'' || docs_required FROM public.admin_verification_queue(''all'') WHERE business_name = ''Pending Wholesale''');
  PERFORM zz.check('wholesaler with all 3 required documents', r = '3/3', r);
  r := zz.val_as(u_admin, 'SELECT docs_uploaded || ''/'' || docs_required FROM public.admin_verification_queue(''all'') WHERE business_name = ''Rejected Wholesale''');
  PERFORM zz.check('an unrelated document type does not count towards the required documents', r = '1/3', r);
  r := zz.val_as(u_admin, 'SELECT waiting_days::text FROM public.admin_verification_queue(''all'') WHERE business_name = ''Pending Pharmacy''');
  PERFORM zz.check('waiting days for a new submission = 3', r = '3', r);
  r := zz.val_as(u_admin, 'SELECT waiting_days::text FROM public.admin_verification_queue(''all'') WHERE business_name = ''Pending Wholesale''');
  PERFORM zz.check('waiting days for a resubmission count from the resubmission = 2', r = '2', r);
  r := zz.val_as(u_admin, 'SELECT COALESCE(waiting_days::text, ''none'') FROM public.admin_verification_queue(''all'') WHERE business_name = ''Rejected Wholesale''');
  PERFORM zz.check('rejected rows have no waiting time', r = 'none', r);
  r := zz.val_as(u_admin, 'SELECT is_resubmitted::text FROM public.admin_verification_queue(''all'') WHERE business_name = ''Pending Wholesale''');
  PERFORM zz.check('resubmission flag', r = 'true', r);
  r := zz.val_as(u_admin, 'SELECT rejection_reason FROM public.admin_verification_queue(''rejected'')');
  PERFORM zz.check('rejection reason is returned', r = 'Licence unreadable', r);

  r := zz.val_as(u_admin, 'SELECT business_name || ''/'' || total_count FROM public.admin_verification_queue(''pending'', NULL, NULL, ''oldest'', 1, 1)');
  PERFORM zz.check('paging: second page of size 1 keeps total 2', r = 'Pending Wholesale/2', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''bogus'')');
  PERFORM zz.check('unknown status rejected', r LIKE 'ERR%', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', ''hospital'')');
  PERFORM zz.check('unknown type rejected', r LIKE 'ERR%', r);
  r := zz.val_as(u_admin, 'SELECT count(*)::text FROM public.admin_verification_queue(''all'', NULL, NULL, ''random'')');
  PERFORM zz.check('unknown sort rejected', r LIKE 'ERR%', r);

  r := zz.val_as(u_wo, 'SELECT count(*)::text FROM public.admin_verification_queue()');
  PERFORM zz.check('a wholesaler cannot read the queue', r LIKE 'ERR: Only platform admins%', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.admin_verification_queue()');
  PERFORM zz.check('a pharmacy cannot read the queue', r LIKE 'ERR: Only platform admins%', r);
  r := zz.val_as(u_nb, 'SELECT count(*)::text FROM public.admin_verification_queue()');
  PERFORM zz.check('an unrelated user cannot read the queue', r LIKE 'ERR: Only platform admins%', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.admin_verification_queue();
    RESET ROLE;
    PERFORM zz.check('anon cannot read the queue', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read the queue', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
