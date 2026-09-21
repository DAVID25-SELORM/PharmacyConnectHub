\set QUIET on
\pset format unaligned
\pset tuples_only on
CREATE TEMP TABLE q(name text, sql text);
INSERT INTO q VALUES
('1 first page (preview/unfiltered)', $$SELECT a.id FROM public.audit_logs a ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('2 next page (keyset cursor deep in the table)', $$SELECT a.id FROM public.audit_logs a WHERE (a.created_at, a.id) < (now() - interval '2 days', 'ffffffff-ffff-ffff-ffff-ffffffffffff') ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('3 organization filter', $$SELECT a.id FROM public.audit_logs a WHERE a.organization = 'Org 17' ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('4 event filter', $$SELECT a.id FROM public.audit_logs a WHERE a.activity = 'Order placed' ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('5 date range 7d', $$SELECT a.id FROM public.audit_logs a WHERE a.created_at >= now() - interval '7 days' ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('6 category orders (LIKE ANY)', $$SELECT a.id FROM public.audit_logs a WHERE a.activity LIKE ANY (ARRAY['Order %']) ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('7 free-text search (rare term)', $$SELECT a.id FROM public.audit_logs a WHERE (COALESCE(a.organization,'')||' '||COALESCE(a.performed_by_email,'')||' '||COALESCE(a.record_label,'')||' '||a.activity) ILIKE '%REF-2999%' ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('8 actor email', $$SELECT a.id FROM public.audit_logs a WHERE lower(a.performed_by_email) = lower('actor7@example.com') ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('9 actor = system', $$SELECT a.id FROM public.audit_logs a WHERE a.performed_by IS NULL ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('10 org type pharmacy', $$SELECT a.id FROM public.audit_logs a WHERE a.organization IN (SELECT b.name FROM public.businesses b WHERE b.type = 'pharmacy') ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$),
('11 event + org (combined)', $$SELECT a.id FROM public.audit_logs a WHERE a.activity = 'Order placed' AND a.organization = 'Org 17' ORDER BY a.created_at DESC, a.id DESC LIMIT 51$$);
DO $$
DECLARE r record; plan text; line text; idx text; seq boolean; t text;
BEGIN
  FOR r IN SELECT * FROM q LOOP
    idx := ''; seq := false; t := '';
    FOR line IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS OFF, TIMING OFF) ' || r.sql LOOP
      IF line ~ 'Index|Bitmap' THEN idx := idx || regexp_replace(trim(line), '^->\s*', '') || ' | '; END IF;
      IF line ~ 'Seq Scan' THEN seq := true; END IF;
      IF line ~ 'Execution Time' THEN t := trim(line); END IF;
    END LOOP;
    RAISE NOTICE '% :: seqscan=% :: % :: %', r.name, seq, t, left(idx, 230);
  END LOOP;
END $$;
