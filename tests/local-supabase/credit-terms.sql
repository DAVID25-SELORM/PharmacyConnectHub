-- Wholesaler credit terms: setting, permissions, checkout enforcement, outstanding balance, access.
-- Run after setup.sql + migrations (through 20260924220000_wholesaler_credit_terms.sql).
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

SELECT zz.mkuser('10000000-0000-0000-0000-0000000000a1', 'wa@zz.test', '{"full_name":"Alpha Assistant","phone":"+233241000012"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000a1', 'assistant', 'active', now());

CREATE TABLE zz.ct(k TEXT PRIMARY KEY, id UUID);
GRANT ALL ON zz.ct TO PUBLIC;

-- 1. setting terms + permissions -----------------------------------------------------------------
DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy'); otherp UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager'); u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_wx UUID := (SELECT id FROM zz.u WHERE k='w_other'); u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner'); u_wa UUID := '10000000-0000-0000-0000-0000000000a1';
  r TEXT;
BEGIN
  r := zz.val_as(u_wc, format('SELECT public.set_credit_terms(%L, %L, 1000, 30)::text', alpha, good));
  PERFORM zz.check('cashier cannot set credit terms', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_wa, format('SELECT public.set_credit_terms(%L, %L, 1000, 30)::text', alpha, good));
  PERFORM zz.check('assistant cannot set credit terms', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_wx, format('SELECT public.set_credit_terms(%L, %L, 1000, 30)::text', alpha, good));
  PERFORM zz.check('another wholesaler cannot set my credit terms', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  r := zz.val_as(u_po, format('SELECT public.set_credit_terms(%L, %L, 1000, 30)::text', good, good));
  PERFORM zz.check('a pharmacy cannot set credit terms', r LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, 0, 30)::text', alpha, good));
  PERFORM zz.check('a zero credit limit rejected', r LIKE 'ERR: The credit limit must be above%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, -5, 30)::text', alpha, good));
  PERFORM zz.check('a negative credit limit rejected', r LIKE 'ERR: The credit limit must be above%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, 1000, 0)::text', alpha, good));
  PERFORM zz.check('0 payment days rejected', r LIKE 'ERR: Payment terms must be between%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, 1000, 400)::text', alpha, good));
  PERFORM zz.check('over 365 payment days rejected', r LIKE 'ERR: Payment terms must be between%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, 1000, 30)::text', alpha, alpha));
  PERFORM zz.check('the customer must be a pharmacy', r LIKE 'ERR: Pharmacy workspace not found%', r);
  r := zz.val_as(u_wm, format('SELECT public.set_credit_terms(%L, %L, 500, 30, ''Good payer'')::text', alpha, good));
  PERFORM zz.check('manager approves GHS 500 credit, 30 days for Good Pharmacy', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_wo, format('SELECT public.set_credit_terms(%L, %L, 700, 15)::text', alpha, good));
  PERFORM zz.check('owner can revise an existing line (limit 700, 15 days)', r NOT LIKE 'ERR%', r);
  PERFORM zz.check('audit log records the change', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Credit terms updated') = 2);

  r := zz.val_as(u_wc, format('SELECT count(*)::text FROM public.list_wholesaler_credit_terms(%L)', alpha));
  PERFORM zz.check('cashier cannot list credit terms', r LIKE 'ERR%', r);
  r := zz.val_as(u_wm, format('SELECT credit_limit_ghs || ''/'' || payment_terms_days || ''/'' || outstanding_ghs || ''/'' || available_ghs FROM public.list_wholesaler_credit_terms(%L)', alpha));
  PERFORM zz.check('manager sees the line with no orders yet: 700/15/0/700', r = '700.00/15/0.00/700.00', r);
  r := zz.val_as(u_po, format('SELECT credit_limit_ghs || ''/'' || available_ghs FROM public.get_my_credit_terms(%L)', good));
  PERFORM zz.check('the pharmacy sees its own line', r = '700.00/700.00', r);
  r := zz.val_as(u_po, format('SELECT count(*)::text FROM public.get_my_credit_terms(%L, %L)', otherp, alpha));
  PERFORM zz.check('a pharmacy cannot read another pharmacy''s line', r LIKE 'ERR%', r);
  r := zz.val_as(u_po, 'SELECT count(*)::text FROM public.wholesaler_credit_terms');
  PERFORM zz.check('the table is not readable directly', r = '0', r);
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM * FROM public.get_my_credit_terms(good);
    RESET ROLE;
    PERFORM zz.check('anon cannot read credit terms', FALSE);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM zz.check('anon cannot read credit terms', TRUE, SQLERRM);
  END;
END $$;

-- 2. checkout (one call per transaction) ----------------------------------------------------------
-- Alpha -> Good Pharmacy: credit limit 700, 15 days. Good Pharmacy also has a 5% general discount with Alpha.
DO $$
DECLARE alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale'); other_w UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale'); p UUID; px UUID;
BEGIN
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (alpha, 'Ct Amox', 'Cat', 'TABLET', '10s', 100, 500, true) RETURNING id INTO p;
  INSERT INTO public.products(wholesaler_id, name, category, form, pack_size, price_ghs, stock, active) VALUES (other_w, 'Ct Other', 'Cat', 'TABLET', '10s', 40, 500, true) RETURNING id INTO px;
  INSERT INTO zz.ct VALUES ('p', p), ('px', px);
END $$;

DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='px'), 'quantity', 2)),
    ARRAY[(SELECT id FROM zz.b WHERE name='Other Wholesale')]);
  PERFORM zz.check('asking for credit from a wholesaler with no approved line is rejected', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('asking for credit from a wholesaler with no approved line is rejected', SQLERRM = 'Other Wholesale has not approved credit for your pharmacy.', SQLERRM);
END $$;

DO $$ BEGIN
  PERFORM zz.check('the rejected credit request reserved no stock and created no order',
    (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.ct WHERE k='px')) = 500 AND (SELECT count(*) FROM public.orders) = 0);
  -- 5 units x 100 = 500 gross, 475 net (5% discount). Within the 700 limit.
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='p'), 'quantity', 5)),
    ARRAY[(SELECT id FROM zz.b WHERE name='Alpha Wholesale')]);
END $$;

DO $$
DECLARE r TEXT; o RECORD;
BEGIN
  SELECT total_ghs, is_credit_order, credit_due_date, payment_status INTO o FROM public.orders ORDER BY created_at DESC LIMIT 1;
  PERFORM zz.check('order placed on credit: total 475, is_credit_order true, due in 15 days, still unpaid',
    o.total_ghs = 475 AND o.is_credit_order AND o.credit_due_date = (current_date + 15) AND o.payment_status = 'unpaid');
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT outstanding_ghs || ''/'' || available_ghs FROM public.list_wholesaler_credit_terms(%L)', (SELECT id FROM zz.b WHERE name='Alpha Wholesale')));
  PERFORM zz.check('outstanding rises to 475, available drops to 225', r = '475.00/225.00', r);
  INSERT INTO zz.ct VALUES ('o1', (SELECT id FROM public.orders ORDER BY created_at DESC LIMIT 1));
END $$;

-- a second credit order for 2 units (190 net) would push outstanding to 665, still under 700: allowed
DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='p'), 'quantity', 2)),
    ARRAY[(SELECT id FROM zz.b WHERE name='Alpha Wholesale')]);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT outstanding_ghs::text FROM public.list_wholesaler_credit_terms(%L)', (SELECT id FROM zz.b WHERE name='Alpha Wholesale')));
  PERFORM zz.check('outstanding now 475 + 190 = 665', r = '665.00', r);
END $$;

-- a third credit order for 1 more unit (95 net) would push it to 760, over the 700 limit: rejected
DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='p'), 'quantity', 1)),
    ARRAY[(SELECT id FROM zz.b WHERE name='Alpha Wholesale')]);
  PERFORM zz.check('exceeding the credit limit is rejected', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('exceeding the credit limit is rejected with the amounts',
    SQLERRM = 'Using credit with Alpha Wholesale would exceed your approved limit of GHS 700.00 (you currently owe GHS 665.00, this order is GHS 95.00).', SQLERRM);
END $$;

DO $$ BEGIN
  PERFORM zz.check('the rejected order reserved no stock', (SELECT stock FROM public.products WHERE id = (SELECT id FROM zz.ct WHERE k='p')) = 500 - 5 - 2);
  -- an order placed WITHOUT requesting credit is unaffected by the limit, even though it is large
  PERFORM zz.check('a normal (non-credit) order ignores the credit limit entirely',
    public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
      jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='p'), 'quantity', 20))) = 1);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  r := (SELECT is_credit_order::text FROM public.orders ORDER BY created_at DESC LIMIT 1);
  PERFORM zz.check('that order is not a credit order', r = 'false', r);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT outstanding_ghs::text FROM public.list_wholesaler_credit_terms(%L)', (SELECT id FROM zz.b WHERE name='Alpha Wholesale')));
  PERFORM zz.check('a non-credit order does not add to the outstanding credit balance', r = '665.00', r);
  -- settling the first credit order (mark paid, as confirm-payment.ts does after delivery) frees up credit
  UPDATE public.orders SET status = 'delivered', delivered_at = now(), payment_status = 'paid', paid_at = now() WHERE id = (SELECT id FROM zz.ct WHERE k='o1');
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT outstanding_ghs || ''/'' || available_ghs FROM public.list_wholesaler_credit_terms(%L)', (SELECT id FROM zz.b WHERE name='Alpha Wholesale')));
  PERFORM zz.check('settling the first order (475) drops outstanding to 190, available back to 510', r = '190.00/510.00', r);
  -- cancelling the second credit order also releases it (checkout still reserved stock/orders separately from batches; here we check the credit view only)
  UPDATE public.orders SET status = 'cancelled' WHERE id NOT IN (SELECT id FROM zz.ct WHERE k = 'o1') AND is_credit_order;
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT outstanding_ghs::text FROM public.list_wholesaler_credit_terms(%L)', (SELECT id FROM zz.b WHERE name='Alpha Wholesale')));
  PERFORM zz.check('cancelling the remaining credit order drops outstanding to 0', r = '0.00', r);

END $$;

DO $$
DECLARE r TEXT;
BEGIN
  -- revoking the credit line blocks further credit checkout
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_owner'), format('SELECT public.revoke_credit_terms(%L, %L)::text', (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy')));
  PERFORM zz.check('owner can revoke credit terms', r = 'true', r);
END $$;

DO $$ BEGIN
  PERFORM public.create_marketplace_orders((SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'),
    jsonb_build_array(jsonb_build_object('productId', (SELECT id FROM zz.ct WHERE k='p'), 'quantity', 1)),
    ARRAY[(SELECT id FROM zz.b WHERE name='Alpha Wholesale')]);
  PERFORM zz.check('a revoked credit line blocks new credit orders', FALSE);
EXCEPTION WHEN OTHERS THEN
  PERFORM zz.check('a revoked credit line blocks new credit orders', SQLERRM LIKE '%has not approved credit%', SQLERRM);
END $$;

DO $$
DECLARE r TEXT;
BEGIN
  r := zz.val_as((SELECT id FROM zz.u WHERE k='w_cashier'), format('SELECT public.revoke_credit_terms(%L, %L)::text', (SELECT id FROM zz.b WHERE name='Alpha Wholesale'), (SELECT id FROM zz.b WHERE name='Good Pharmacy')));
  PERFORM zz.check('cashier cannot revoke credit terms', r LIKE 'ERR: Only wholesaler owners and managers%', r);
  PERFORM zz.check('audit log records the revocation', (SELECT count(*) FROM public.audit_logs WHERE activity = 'Credit terms revoked') = 1);
  r := zz.val_as((SELECT id FROM zz.u WHERE k='ph_other'), format('SELECT public.create_marketplace_orders(%L, %L, %L::jsonb, %L::uuid[])::text', (SELECT id FROM zz.u WHERE k='ph_owner'), (SELECT id FROM zz.b WHERE name='Good Pharmacy'), '[]', '{}'));
  PERFORM zz.check('checkout is still service-only', r LIKE 'ERR: permission denied%', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
