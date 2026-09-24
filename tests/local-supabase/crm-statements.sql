-- Wholesaler CRM + customer statements: hand-computed expectations and access control.
-- Run after setup.sql + migration 20260924120000_wholesaler_crm_and_statements.sql.
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
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  r TEXT;
  stmt TEXT;
BEGIN
  -- alpha -> good: o1 paid 100 (-40d, paid -39d), o2 cancelled 50, o3 unpaid 30 (-5d),
  --                o4 paid 20 (-2d, paid now), o5 refunded 15.   alpha -> otherp: unpaid 100 (-90d)
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method, created_at, paid_at) VALUES
    (good, alpha, 'delivered', 100, 100, 0, 'paid',     'cod', now() - interval '40 days', now() - interval '39 days'),
    (good, alpha, 'cancelled',  50,  50, 0, 'unpaid',   'cod', now() - interval '30 days', NULL),
    (good, alpha, 'pending',    30,  30, 0, 'unpaid',   'cod', now() - interval '5 days',  NULL),
    (good, alpha, 'delivered',  20,  20, 0, 'paid',     'cod', now() - interval '2 days',  now() - interval '1 hour'),
    (good, alpha, 'delivered',  15,  15, 0, 'refunded', 'cod', now() - interval '10 days', NULL),
    (otherp, alpha, 'delivered', 100, 100, 0, 'unpaid', 'cod', now() - interval '90 days', NULL);

  -- customer list as the wholesaler owner
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_customers(%L)', alpha));
  PERFORM zz.check('customer list has both pharmacies', r = '2', r);
  r := zz.val_as(u_wo, format('SELECT orders::text || ''/'' || revenue_ghs::text || ''/'' || outstanding_ghs::text FROM public.wholesaler_customers(%L) WHERE pharmacy_id = %L', alpha, good));
  PERFORM zz.check('good pharmacy: 3 counted orders, revenue 150, outstanding 30', r = '3/150.00/30.00', r);
  r := zz.val_as(u_wo, format('SELECT segments::text FROM public.wholesaler_customers(%L) WHERE pharmacy_id = %L', alpha, good));
  PERFORM zz.check('good pharmacy segments: active, high_value, discount', r LIKE '%active%' AND r LIKE '%high_value%' AND r LIKE '%discount%' AND r NOT LIKE '%dormant%', r);
  r := zz.val_as(u_wo, format('SELECT segments::text FROM public.wholesaler_customers(%L) WHERE pharmacy_id = %L', alpha, otherp));
  PERFORM zz.check('other pharmacy is dormant, not high value', r LIKE '%dormant%' AND r NOT LIKE '%high_value%', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_customers(%L, NULL, ''dormant'')', alpha));
  PERFORM zz.check('segment filter dormant returns 1', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_customers(%L, ''good'')', alpha));
  PERFORM zz.check('search by name works', r = '1', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_customers(%L, ''%%'')', alpha));
  PERFORM zz.check('search treats % literally (no match)', r = '0', r);
  r := zz.val_as(u_wo, format('SELECT total_count::text FROM public.wholesaler_customers(%L, NULL, NULL, 1, 0)', alpha));
  PERFORM zz.check('paging: limit 1 still reports total 2', r = '2', r);
  r := zz.val_as(u_wo, format('SELECT count(*)::text FROM public.wholesaler_customers(%L, NULL, ''bogus'')', alpha));
  PERFORM zz.check('unknown segment rejected', r LIKE 'ERR%', r);

  -- customer list access
  r := zz.val_as(u_wx, format('SELECT count(*)::text FROM public.wholesaler_customers(%L)', alpha));
  PERFORM zz.check('other wholesaler cannot list my customers', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.wholesaler_customers(%L)', alpha));
  PERFORM zz.check('a pharmacy cannot list a wholesaler''s customers', r LIKE 'ERR%', r);
  r := zz.val_as(u_nb, format('SELECT count(*)::text FROM public.wholesaler_customers(%L)', alpha));
  PERFORM zz.check('unrelated user cannot list customers', r LIKE 'ERR%', r);

  -- customer detail
  r := zz.val_as(u_wo, format('SELECT jsonb_array_length(public.wholesaler_customer_detail(%L, %L)->''recent_orders'')::text', alpha, good));
  PERFORM zz.check('detail returns recent orders', r = '5', r);
  r := zz.val_as(u_wx, format('SELECT public.wholesaler_customer_detail(%L, %L)::text', alpha, good));
  PERFORM zz.check('other wholesaler cannot read customer detail', r LIKE 'ERR%', r);

  -- statement: whole history
  r := zz.val_as(u_wo, format('SELECT (s->>''opening_balance'') || ''/'' || (s->>''total_debits'') || ''/'' || (s->>''total_credits'') || ''/'' || (s->>''closing_balance'') FROM (SELECT public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'') s) q', alpha, good));
  PERFORM zz.check('statement all time: 0/150/120/30', r = '0/150.00/120.00/30.00', r);
  -- statement starting between o1 debit and o1 payment: opening should be 100
  r := zz.val_as(u_wo, format('SELECT (s->>''opening_balance'') || ''/'' || (s->>''total_debits'') || ''/'' || (s->>''total_credits'') || ''/'' || (s->>''closing_balance'') || ''/'' || (s->>''line_count'') FROM (SELECT public.customer_statement(%L, %L, now() - interval ''39.5 days'', now() + interval ''1 day'') s) q', alpha, good));
  PERFORM zz.check('statement mid-range: opening 100, closing 30, 4 lines', r = '100.00/50.00/120.00/30.00/4', r);
  -- last line balance equals closing
  r := zz.val_as(u_wo, format('SELECT (s->''lines''->-1->>''balance'') FROM (SELECT public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'') s) q', alpha, good));
  PERFORM zz.check('last running balance equals closing balance', r::numeric = 30, r);
  -- both sides see the same statement; outsiders do not
  r := zz.val_as(u_po, format('SELECT (public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'')->>''closing_balance'')', alpha, good));
  PERFORM zz.check('pharmacy owner sees the same closing balance', r::numeric = 30, r);
  r := zz.val_as(u_px, format('SELECT public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'')::text', alpha, good));
  PERFORM zz.check('another pharmacy cannot read the statement', r LIKE 'ERR%', r);
  r := zz.val_as(u_wx, format('SELECT public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'')::text', alpha, good));
  PERFORM zz.check('another wholesaler cannot read the statement', r LIKE 'ERR%', r);
  r := zz.val_as(u_nb, format('SELECT public.customer_statement(%L, %L, now() - interval ''200 days'', now() + interval ''1 day'')::text', alpha, good));
  PERFORM zz.check('unrelated user cannot read the statement', r LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.customer_statement(%L, %L, now(), now() - interval ''1 day'')::text', alpha, good));
  PERFORM zz.check('inverted date range rejected', r LIKE 'ERR%', r);

  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.customer_statement(alpha, good, now() - interval '1 day', now());
    RESET ROLE;
    PERFORM zz.check('anon cannot execute statement rpc', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot execute statement rpc', TRUE, SQLERRM);
  END;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
