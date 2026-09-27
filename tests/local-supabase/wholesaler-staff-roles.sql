-- Wholesaler internal roles (warehouse / finance): enum, role-assignment guard, permission-tier
-- widening, and the column-level order-update split.
-- Run after setup.sql + migrations through 20260927110000_wholesaler_staff_roles_permissions.sql.
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

-- warehouse/finance staff on Alpha Wholesale (Good Pharmacy is the counterpart pharmacy)
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000b1', 'wwh@zz.test', '{"full_name":"Alpha Warehouse","phone":"+233241000013"}');
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000b2', 'wfi@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000014"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000b1', 'warehouse', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000b2', 'finance', 'active', now());

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_wm UUID := (SELECT id FROM zz.u WHERE k='w_manager');
  u_wc UUID := (SELECT id FROM zz.u WHERE k='w_cashier');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  u_wh UUID := '10000000-0000-0000-0000-0000000000b1';
  u_fi UUID := '10000000-0000-0000-0000-0000000000b2';
  o_pend UUID; o_acc UUID; o_del UUID;
  r TEXT;
BEGIN
  ------------------------------------------------------------------
  -- 1. business_staff role-assignment guard: warehouse/finance only on wholesaler businesses.
  ------------------------------------------------------------------
  BEGIN
    INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
    VALUES (good, (SELECT id FROM zz.u WHERE k='nobody'), 'warehouse', 'active', now());
    PERFORM zz.check('warehouse role rejected on a pharmacy business', FALSE);
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('warehouse role rejected on a pharmacy business', SQLERRM LIKE '%only available for wholesaler%', SQLERRM);
  END;
  BEGIN
    INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
    VALUES (good, (SELECT id FROM zz.u WHERE k='nobody'), 'finance', 'active', now());
    PERFORM zz.check('finance role rejected on a pharmacy business', FALSE);
  EXCEPTION WHEN OTHERS THEN
    PERFORM zz.check('finance role rejected on a pharmacy business', SQLERRM LIKE '%only available for wholesaler%', SQLERRM);
  END;
  PERFORM zz.check('warehouse staff row exists on the wholesaler', EXISTS (
    SELECT 1 FROM public.business_staff WHERE business_id = alpha AND user_id = u_wh AND role = 'warehouse'
  ));
  PERFORM zz.check('finance staff row exists on the wholesaler', EXISTS (
    SELECT 1 FROM public.business_staff WHERE business_id = alpha AND user_id = u_fi AND role = 'finance'
  ));

  ------------------------------------------------------------------
  -- 2. Fixture orders.
  ------------------------------------------------------------------
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'pending', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_pend;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'accepted', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_acc;
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'delivered', 10, 10, 0, 'unpaid', 'cod') RETURNING id INTO o_del;

  ------------------------------------------------------------------
  -- 3. 'process' tier: warehouse gains it, finance does not. Exercised through a real
  --    process-gated RPC (record_order_dispatch_details) rather than the revoked helper directly.
  ------------------------------------------------------------------
  r := zz.val_as(u_wh, format('SELECT public.record_order_dispatch_details(%L, ''Kofi Driver'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('warehouse can record dispatch details (process tier)', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_fi, format('SELECT public.record_order_dispatch_details(%L, ''Ama Driver'', NULL, NULL, NULL)::text', o_acc));
  PERFORM zz.check('finance cannot record dispatch details (no process tier)', r LIKE 'ERR: You do not have permission%', r);

  ------------------------------------------------------------------
  -- 4. 'read' tier: both warehouse and finance can read order details.
  ------------------------------------------------------------------
  r := zz.val_as(u_wh, format('SELECT public.get_order_delivery(%L)->>''driver_name''', o_acc));
  PERFORM zz.check('warehouse can read delivery details', r = 'Kofi Driver', r);
  r := zz.val_as(u_fi, format('SELECT public.get_order_delivery(%L)->>''driver_name''', o_acc));
  PERFORM zz.check('finance can read delivery details', r = 'Kofi Driver', r);

  ------------------------------------------------------------------
  -- 5. Orders UPDATE RLS + column-level trigger split.
  ------------------------------------------------------------------
  -- warehouse: may change fulfilment status ...
  r := zz.val_as(u_wh, format('WITH x AS (UPDATE public.orders SET status = ''accepted'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_pend));
  PERFORM zz.check('warehouse can advance order status', r = '1', r);
  -- ... but never a payment/receipt column.
  r := zz.val_as(u_wh, format('WITH x AS (UPDATE public.orders SET payment_status = ''paid'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_del));
  PERFORM zz.check('warehouse cannot change payment_status', r LIKE 'ERR: Warehouse staff cannot change payment%', r);
  r := zz.val_as(u_wh, format('WITH x AS (UPDATE public.orders SET payment_confirmed_at = now(), payment_confirmed_by = %L WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', u_wh, o_del));
  PERFORM zz.check('warehouse cannot set payment_confirmed_at', r LIKE 'ERR: Warehouse staff cannot change payment%', r);

  -- finance: may change payment columns ...
  r := zz.val_as(u_fi, format('WITH x AS (UPDATE public.orders SET payment_status = ''paid'', paid_at = now(), payment_confirmed_at = now(), payment_confirmed_by = %L WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', u_fi, o_del));
  PERFORM zz.check('finance can confirm payment', r = '1', r);
  -- ... but never fulfilment status.
  r := zz.val_as(u_fi, format('WITH x AS (UPDATE public.orders SET status = ''packed'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_acc));
  PERFORM zz.check('finance cannot change order status', r LIKE 'ERR: Finance staff cannot change order fulfilment status%', r);
  r := zz.val_as(u_fi, format('WITH x AS (UPDATE public.orders SET status = ''cancelled'', cancellation_reason = ''test'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_acc));
  PERFORM zz.check('finance cannot cancel an order', r LIKE 'ERR: Finance staff cannot change order fulfilment status%', r);

  ------------------------------------------------------------------
  -- 6. Regression: owner/manager/cashier keep full read+write (both status and payment columns);
  --    assistant is still blocked entirely; another wholesaler's staff still cannot reach these
  --    orders at all. None of this should have changed.
  ------------------------------------------------------------------
  r := zz.val_as(u_wc, format('WITH x AS (UPDATE public.orders SET status = ''packed'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_acc));
  PERFORM zz.check('regression: cashier can still advance status', r = '1', r);
  r := zz.val_as(u_wm, format('WITH x AS (UPDATE public.orders SET payment_status = ''paid'', paid_at = now() WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_acc));
  PERFORM zz.check('regression: manager can still confirm payment', r = '1', r);
  r := zz.val_as(u_wo, format('WITH x AS (UPDATE public.orders SET status = ''dispatched'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_acc));
  PERFORM zz.check('regression: owner (business owner, not staff row) can still advance status', r = '1', r);
  r := zz.val_as(u_po, format('WITH x AS (UPDATE public.orders SET status = ''cancelled'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_pend));
  PERFORM zz.check('regression: the buying pharmacy still cannot update the order', r = '0', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
