-- Accountant staff role: enum + can_act_for_business read-tier wiring (foundation phase of the
-- procurement/credit/RFQ/accounting expansion). No write capability is granted yet -- this suite
-- only proves: the role is assignable on BOTH pharmacy and wholesaler businesses, it lands in the
-- read tier (not process/manage), it can read orders directly (via the existing role-agnostic
-- is_business_staff SELECT policies) and call a can_act_for_business('read')-gated RPC, it cannot
-- write to orders, and cross-tenant isolation still holds.
-- Run after setup.sql + migrations through 20261002110000_accountant_staff_role_permissions.sql.
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

-- Accountants on both sides of the same trading pair.
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000c1', 'wac@zz.test', '{"full_name":"Alpha Accountant","phone":"+233241000015"}');
SELECT zz.mkuser('10000000-0000-0000-0000-0000000000c2', 'pac@zz.test', '{"full_name":"Good Pharmacy Accountant","phone":"+233241000016"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at) VALUES
  ((SELECT id FROM zz.b WHERE name='Alpha Wholesale'), '10000000-0000-0000-0000-0000000000c1', 'accountant', 'active', now()),
  ((SELECT id FROM zz.b WHERE name='Good Pharmacy'), '10000000-0000-0000-0000-0000000000c2', 'accountant', 'active', now());

DO $$
DECLARE
  alpha UUID := (SELECT id FROM zz.b WHERE name='Alpha Wholesale');
  other_wh UUID := (SELECT id FROM zz.b WHERE name='Other Wholesale');
  good  UUID := (SELECT id FROM zz.b WHERE name='Good Pharmacy');
  other_ph UUID := (SELECT id FROM zz.b WHERE name='Other Pharmacy');
  u_wac UUID := '10000000-0000-0000-0000-0000000000c1'; -- Alpha's accountant (wholesaler side)
  u_pac UUID := '10000000-0000-0000-0000-0000000000c2'; -- Good Pharmacy's accountant (pharmacy side)
  u_wo UUID := (SELECT id FROM zz.u WHERE k='w_owner');
  u_po UUID := (SELECT id FROM zz.u WHERE k='ph_owner');
  o_id UUID;
  other_o_id UUID;
  r TEXT;
BEGIN
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (good, alpha, 'accepted', 25, 25, 0, 'unpaid', 'cod') RETURNING id INTO o_id;
  -- An order entirely between the OTHER wholesaler/pharmacy pair, for the cross-tenant check.
  INSERT INTO public.orders(pharmacy_id, wholesaler_id, status, total_ghs, subtotal_ghs, discount_amount_ghs, payment_status, payment_method)
    VALUES (other_ph, other_wh, 'accepted', 25, 25, 0, 'unpaid', 'cod') RETURNING id INTO other_o_id;

  ------------------------------------------------------------------
  -- 1. The role is assignable on both business types (no business-type-restriction trigger
  --    fires for 'accountant', unlike warehouse/finance).
  ------------------------------------------------------------------
  PERFORM zz.check('accountant staff row exists on the wholesaler', EXISTS (
    SELECT 1 FROM public.business_staff WHERE business_id = alpha AND user_id = u_wac AND role = 'accountant'));
  PERFORM zz.check('accountant staff row exists on the pharmacy', EXISTS (
    SELECT 1 FROM public.business_staff WHERE business_id = good AND user_id = u_pac AND role = 'accountant'));
  PERFORM zz.check('get_staff_role reports accountant (wholesaler)',
    public.get_staff_role(u_wac, alpha) = 'accountant');
  PERFORM zz.check('get_staff_role reports accountant (pharmacy)',
    public.get_staff_role(u_pac, good) = 'accountant');

  ------------------------------------------------------------------
  -- 2. can_act_for_business tiers, probed indirectly through real tier-gated RPCs -- the function
  --    itself is REVOKE ALL'd from authenticated (deliberately, only callable from inside other
  --    SECURITY DEFINER functions), so a direct SELECT of it as accountant always fails with
  --    "permission denied for function can_act_for_business" regardless of tier; that's a
  --    property of every role, not a signal about accountant specifically, and calling it that
  --    way here would just test the lockdown, not the tier membership.
  ------------------------------------------------------------------
  r := zz.val_as(u_wac, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', o_id));
  PERFORM zz.check('accountant passes the read tier (via get_order_delivery)', r = 'true', r);
  r := zz.val_as(u_wac, format('SELECT public.record_order_dispatch_details(%L, ''Test Driver'', NULL, NULL, NULL)::text', o_id));
  PERFORM zz.check('accountant does NOT pass the process tier (record_order_dispatch_details)', r LIKE 'ERR%', r);
  r := zz.val_as(u_wac, format('SELECT public.record_credit_adjustment(%L, %L, NULL, ''adjustment'', ''debit'', 1, ''probe'')::text', alpha, good));
  PERFORM zz.check('accountant does NOT pass the manage tier (record_credit_adjustment)', r LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- 3. Orders visibility: role-agnostic is_business_staff SELECT policies already cover
  --    accountant automatically (no RLS change needed for this), on both sides.
  ------------------------------------------------------------------
  r := zz.val_as(u_wac, format('SELECT count(*)::text FROM public.orders WHERE id = %L', o_id));
  PERFORM zz.check('wholesaler accountant can read the order', r = '1', r);
  r := zz.val_as(u_pac, format('SELECT count(*)::text FROM public.orders WHERE id = %L', o_id));
  PERFORM zz.check('pharmacy accountant can read the order', r = '1', r);

  ------------------------------------------------------------------
  -- 4. A read-tier-gated RPC (get_order_delivery uses can_act_for_business(..., 'read') on both
  --    sides) works for the accountant on whichever side they belong to.
  ------------------------------------------------------------------
  r := zz.val_as(u_wac, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', o_id));
  PERFORM zz.check('wholesaler accountant can call a read-tier RPC', r = 'true', r);
  r := zz.val_as(u_pac, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', o_id));
  PERFORM zz.check('pharmacy accountant can call a read-tier RPC', r = 'true', r);

  ------------------------------------------------------------------
  -- 5. No write capability yet: accountant is not in the orders UPDATE RLS policy's role list,
  --    so a direct table UPDATE affects zero rows (not an error -- RLS silently filters).
  ------------------------------------------------------------------
  r := zz.val_as(u_wac, format('WITH x AS (UPDATE public.orders SET status = ''packed'' WHERE id = %L RETURNING id) SELECT count(*)::text FROM x', o_id));
  PERFORM zz.check('wholesaler accountant cannot update the order', r = '0', r);

  ------------------------------------------------------------------
  -- 6. Cross-tenant isolation: an accountant on one business cannot read another business's
  --    orders, same as every other staff role. Uses a fresh order actually owned by the other
  --    wholesaler/pharmacy (get_order_delivery checks both sides of the SPECIFIC order, so probing
  --    it with an unrelated business id proves nothing -- it must be an order that business
  --    genuinely can't reach).
  ------------------------------------------------------------------
  r := zz.val_as(u_wac, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', other_o_id));
  PERFORM zz.check('Alpha''s accountant has no access to a different wholesaler''s order', r LIKE 'ERR%', r);
  r := zz.val_as(u_pac, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', other_o_id));
  PERFORM zz.check('Good Pharmacy''s accountant has no access to a different pharmacy''s order', r LIKE 'ERR%', r);

  ------------------------------------------------------------------
  -- 7. Regression: owner still passes every tier; unrelated roles are unaffected by this change.
  ------------------------------------------------------------------
  r := zz.val_as(u_wo, format('SELECT public.record_credit_adjustment(%L, %L, NULL, ''adjustment'', ''debit'', 1, ''owner probe'')::text', alpha, good));
  PERFORM zz.check('regression: wholesaler owner still passes the manage tier', r NOT LIKE 'ERR%', r);
  r := zz.val_as(u_po, format('SELECT (public.get_order_delivery(%L) IS NOT NULL)::text', o_id));
  PERFORM zz.check('regression: pharmacy owner still passes the read tier', r = 'true', r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
SELECT name, detail FROM zz.results WHERE NOT ok;
