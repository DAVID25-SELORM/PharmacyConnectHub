-- POST migration 1: authorization matrix on the real schema, real RLS, real JWT-claim identities.
DO $$
DECLARE
  alpha  UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other  UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  pendw  UUID := (SELECT id FROM zz.b WHERE name='Pending Wholesale');
  rejw   UUID := (SELECT id FROM zz.b WHERE name='Rejected Wholesale');
  good   UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  pendp  UUID := (SELECT id FROM zz.b WHERE name='Pending Pharmacy');
  u_admin UUID := (SELECT id FROM zz.u WHERE k='admin');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wp UUID := (SELECT id FROM zz.u WHERE k='w_pending');
  u_wr UUID := (SELECT id FROM zz.u WHERE k='w_rejected');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_pp UUID := (SELECT id FROM zz.u WHERE k='ph_pending');
  u_px UUID := (SELECT id FROM zz.u WHERE k='ph_other');
  u_nb UUID := (SELECT id FROM zz.u WHERE k='nobody');
  r TEXT; n BIGINT; d_alpha UUID; d_other UUID; d_pend UUID;
BEGIN
  -- ===== upsert_customer_discount authorization matrix =====
  r := zz.run_as(u_wo, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',11)', alpha, good));
  PERFORM zz.check('upsert: approved owner allowed', r='OK', r);
  r := zz.run_as(u_wm, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',12)', alpha, good));
  PERFORM zz.check('upsert: approved manager allowed', r='OK', r);
  r := zz.run_as(u_wc, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',13)', alpha, good));
  PERFORM zz.check('upsert: approved cashier (not owner/manager) denied', r LIKE 'ERR: Only wholesaler owners%', r);
  r := zz.run_as(u_wp, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',14)', pendw, good));
  PERFORM zz.check('upsert: pending wholesaler owner denied', r LIKE 'ERR: Your wholesaler account must be verified%', r);
  r := zz.run_as(u_wr, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',15)', rejw, good));
  PERFORM zz.check('upsert: rejected wholesaler owner denied', r LIKE 'ERR: Your wholesaler account must be verified%', r);
  r := zz.run_as(u_px, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',16)', alpha, good));
  PERFORM zz.check('upsert: unrelated pharmacy denied (former NULL bypass)', r LIKE 'ERR: Only wholesaler owners%', r);
  r := zz.run_as(u_wx, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',17)', alpha, good));
  PERFORM zz.check('upsert: unrelated wholesaler denied (former NULL bypass)', r LIKE 'ERR: Only wholesaler owners%', r);
  r := zz.run_as(u_nb, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',18)', alpha, good));
  PERFORM zz.check('upsert: authenticated user with no business membership denied (former NULL bypass)', r LIKE 'ERR: Only wholesaler owners%', r);
  r := zz.run_as(u_admin, format('SELECT public.upsert_customer_discount(%L,%L,''percentage'',19)', alpha, good));
  PERFORM zz.check('upsert: platform admin unchanged (still not an authorised discount manager)', r LIKE 'ERR: Only wholesaler owners%', r);
  PERFORM zz.check('upsert: no rogue rows written by denied callers',
    (SELECT count(*) FROM public.customer_discounts WHERE discount_percent IN (13,14,15,16,17,18,19)) = 0);

  -- ===== customer_discounts direct-table RLS =====
  PERFORM zz.check('RLS select: approved owner sees only own discounts',
    zz.count_as(u_wo, 'SELECT 1 FROM public.customer_discounts') >= 1 AND
    zz.count_as(u_wo, format('SELECT 1 FROM public.customer_discounts WHERE wholesaler_id <> %L', alpha)) = 0);
  PERFORM zz.check('RLS select: pending wholesaler sees nothing (even its own row)',
    zz.count_as(u_wp, 'SELECT 1 FROM public.customer_discounts') = 0);
  PERFORM zz.check('RLS select: rejected wholesaler sees nothing',
    zz.count_as(u_wr, 'SELECT 1 FROM public.customer_discounts') = 0);
  PERFORM zz.check('RLS select: unrelated wholesaler cannot see another wholesaler''s terms',
    zz.count_as(u_wx, format('SELECT 1 FROM public.customer_discounts WHERE wholesaler_id = %L', alpha)) = 0);
  r := zz.run_as(u_wp, format('INSERT INTO public.customer_discounts(wholesaler_id,pharmacy_id,discount_type,discount_percent) VALUES (%L,%L,''percentage'',21)', pendw, good));
  PERFORM zz.check('RLS insert: pending wholesaler denied', r LIKE 'ERR:%row-level security%', r);
  PERFORM zz.check('RLS update: pending wholesaler affects 0 rows',
    zz.dml_as(u_wp, format('UPDATE public.customer_discounts SET discount_percent = 55 WHERE wholesaler_id = %L', pendw)) = 0);
  PERFORM zz.check('RLS delete: pending wholesaler affects 0 rows',
    zz.dml_as(u_wp, format('DELETE FROM public.customer_discounts WHERE wholesaler_id = %L', pendw)) = 0);
  r := zz.run_as(u_wx, format('INSERT INTO public.customer_discounts(wholesaler_id,pharmacy_id,discount_type,discount_percent) VALUES (%L,%L,''percentage'',22)', alpha, good));
  PERFORM zz.check('RLS insert: unrelated wholesaler denied for another wholesaler''s id', r LIKE 'ERR:%row-level security%', r);
  PERFORM zz.check('RLS update: unrelated wholesaler affects 0 rows',
    zz.dml_as(u_wx, format('UPDATE public.customer_discounts SET discount_percent = 56 WHERE wholesaler_id = %L', alpha)) = 0);
  PERFORM zz.check('RLS update: approved owner can update own row',
    zz.dml_as(u_wo, format('UPDATE public.customer_discounts SET internal_note = ''ok'' WHERE wholesaler_id = %L', alpha)) >= 1);
  PERFORM zz.check('RLS: approved manager can read own wholesaler''s discounts',
    zz.count_as(u_wm, format('SELECT 1 FROM public.customer_discounts WHERE wholesaler_id = %L', alpha)) >= 1);
  PERFORM zz.check('RLS: cashier cannot read discount table',
    zz.count_as(u_wc, format('SELECT 1 FROM public.customer_discounts WHERE wholesaler_id = %L', alpha)) = 0);

  -- ===== deactivate_customer_discount =====
  SELECT id INTO d_alpha FROM public.customer_discounts WHERE wholesaler_id = alpha AND pharmacy_id = good AND active LIMIT 1;
  SELECT id INTO d_other FROM public.customer_discounts WHERE wholesaler_id = other AND active LIMIT 1;
  SELECT id INTO d_pend  FROM public.customer_discounts WHERE wholesaler_id = pendw AND active LIMIT 1;
  r := zz.run_as(u_wx, format('SELECT 1 WHERE public.deactivate_customer_discount(%L) IS FALSE', d_alpha));
  PERFORM zz.check('deactivate: unrelated wholesaler cannot deactivate (returns false, no change)',
    (SELECT active FROM public.customer_discounts WHERE id = d_alpha) IS TRUE AND zz.count_as(u_wx, format('SELECT 1 WHERE public.deactivate_customer_discount(%L) IS FALSE', d_alpha)) = 1);
  r := zz.run_as(u_nb, format('SELECT public.deactivate_customer_discount(%L)', d_alpha));
  PERFORM zz.check('deactivate: no-membership user cannot deactivate (NULL-safe)', (SELECT active FROM public.customer_discounts WHERE id = d_alpha) IS TRUE, r);
  r := zz.run_as(u_wp, format('SELECT public.deactivate_customer_discount(%L)', d_pend));
  PERFORM zz.check('deactivate: pending wholesaler denied', r LIKE 'ERR: Your wholesaler account must be verified%', r);
  r := zz.run_as(u_wo, format('SELECT public.deactivate_customer_discount(%L)', d_alpha));
  PERFORM zz.check('deactivate: approved owner allowed', r='OK' AND (SELECT active FROM public.customer_discounts WHERE id = d_alpha) IS FALSE, r);

  -- ===== list_wholesaler_customer_discounts =====
  r := zz.run_as(u_wp, format('SELECT public.list_wholesaler_customer_discounts(%L)', pendw));
  PERFORM zz.check('list: pending wholesaler denied', r LIKE 'ERR: Your wholesaler account must be verified%', r);
  r := zz.run_as(u_wo, format('SELECT public.list_wholesaler_customer_discounts(%L)', alpha));
  PERFORM zz.check('list: approved owner allowed', r='OK', r);
  PERFORM zz.check('list: unrelated wholesaler gets nothing for another wholesaler',
    zz.count_as(u_wx, format('SELECT jsonb_array_elements(public.list_wholesaler_customer_discounts(%L))', alpha)) = 0);
  PERFORM zz.check('list: internal_note is never returned',
    NOT EXISTS (SELECT 1 FROM (SELECT set_config('request.jwt.claims', json_build_object('sub', u_wo, 'role','authenticated')::text, true)) s,
      LATERAL (SELECT jsonb_array_elements(public.list_wholesaler_customer_discounts(alpha)) e) x WHERE x.e ? 'internal_note'));

  -- ===== get_my_customer_discount =====
  PERFORM zz.check('get_my_customer_discount: approved pharmacy gets its own applicable discount',
    zz.count_as(u_po, format('SELECT * FROM public.get_my_customer_discount(%L)', other)) >= 1);
  PERFORM zz.check('get_my_customer_discount: pending pharmacy gets NO commercial terms',
    zz.count_as(u_pp, format('SELECT * FROM public.get_my_customer_discount(%L)', alpha)) = 0);
  PERFORM zz.check('get_my_customer_discount: unrelated pharmacy cannot read another pharmacy''s discount',
    zz.count_as(u_px, format('SELECT * FROM public.get_my_customer_discount(%L)', other)) = 0);
  PERFORM zz.check('get_my_customer_discount: wholesaler-specific isolation (only rows for the requested wholesaler)',
    zz.count_as(u_po, format('SELECT * FROM public.get_my_customer_discount(%L)', other)) =
    (SELECT count(*) FROM public.customer_discounts WHERE wholesaler_id = other AND pharmacy_id = good AND active));

  -- ===== add_business_staff_by_email + business_staff INSERT policy =====
  r := zz.run_as(u_wo, format('SELECT public.add_business_staff_by_email(%L, ''nb@zz.test'', ''assistant'')', alpha));
  PERFORM zz.check('staff RPC: approved owner can add staff', r='OK', r);
  r := zz.run_as(u_wp, format('SELECT public.add_business_staff_by_email(%L, ''nb@zz.test'', ''assistant'')', pendw));
  PERFORM zz.check('staff RPC: pending owner denied', r LIKE 'ERR: Your business must be verified%', r);
  r := zz.run_as(u_wr, format('SELECT public.add_business_staff_by_email(%L, ''nb@zz.test'', ''assistant'')', rejw));
  PERFORM zz.check('staff RPC: rejected owner denied', r LIKE 'ERR: Your business must be verified%', r);
  r := zz.run_as(u_px, format('SELECT public.add_business_staff_by_email(%L, ''nb@zz.test'', ''assistant'')', alpha));
  PERFORM zz.check('staff RPC: unrelated user denied', r LIKE 'ERR: Only the business owner%', r);
  r := zz.run_as(u_admin, format('SELECT public.add_business_staff_by_email(%L, ''wc@zz.test'', ''cashier'')', pendw));
  PERFORM zz.check('staff RPC: platform admin can still add staff to any business', r='OK', r);
  r := zz.run_as(u_wp, format('INSERT INTO public.business_staff(business_id,user_id,role,status) VALUES (%L,%L,''assistant'',''active'')', pendw, u_px));
  PERFORM zz.check('staff RLS insert: pending owner denied (direct table)', r LIKE 'ERR:%row-level security%', r);
  r := zz.run_as(u_wo, format('INSERT INTO public.business_staff(business_id,user_id,role,status) VALUES (%L,%L,''assistant'',''active'')', alpha, u_px));
  PERFORM zz.check('staff RLS insert: approved owner allowed (direct table)', r='OK', r);
  r := zz.run_as(u_px, format('INSERT INTO public.business_staff(business_id,user_id,role,status) VALUES (%L,%L,''manager'',''active'')', alpha, u_px));
  PERFORM zz.check('staff RLS insert: unrelated user cannot self-assign to another business', r LIKE 'ERR:%row-level security%', r);

  -- ===== signup trigger still creates owner staff row for a NEW pending business (RLS bypass in trigger) =====
  PERFORM zz.check('signup trigger: pending business still gets its owner staff row',
    EXISTS (SELECT 1 FROM public.business_staff WHERE business_id = pendw AND user_id = u_wp AND role = 'owner'));
END $$;

SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed FROM zz.results;
SELECT name FROM zz.results WHERE NOT ok ORDER BY seq;

-- structural checks on the applied migration
SELECT p.proname, p.prosecdef AS secdef, p.provolatile, p.proconfig::text AS config,
       (SELECT string_agg(a.grantee::text || ':' || a.privilege_type, ',' ORDER BY a.grantee::text) FROM information_schema.routine_privileges a WHERE a.specific_name = p.proname || '_' || p.oid AND a.grantee IN ('PUBLIC','anon','authenticated')) AS grants
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('upsert_customer_discount','deactivate_customer_discount','list_wholesaler_customer_discounts','get_my_customer_discount','add_business_staff_by_email')
ORDER BY 1;
SELECT polname, polcmd FROM pg_policy WHERE polrelid IN ('public.customer_discounts'::regclass, 'public.business_staff'::regclass) ORDER BY 1;
