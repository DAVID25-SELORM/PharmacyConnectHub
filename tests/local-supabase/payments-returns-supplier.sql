-- Online payments (Pay Now), optional gaps 1 and 2: (1) a supplier sees its own settlement status and the online payments that reached it; (2) a return of goods resolved as a refund on an order
-- paid online becomes a refund request. Run after setup.sql + migrations (through 20261112120000_payments_returns_patches.sql), with the production guard and stock fixtures installed and the
-- checkout compatibility migration (20261017110000) re-applied. Successful create_marketplace_orders calls are top-level statements (one per statement).
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
BEGIN
  IF p_uid IS NULL THEN PERFORM set_config('request.jwt.claims', '', true); PERFORM set_config('request.jwt.claim.sub', '', true);
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO r;
  EXCEPTION WHEN OTHERS THEN
    r := 'ERR: ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;
CREATE FUNCTION zz.svc(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN r;
END $$;
CREATE FUNCTION zz.try(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  BEGIN
    IF p_sql ~* '^[[:space:]]*select' THEN EXECUTE p_sql INTO r; ELSE EXECUTE p_sql; END IF;
  EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  RETURN r;
END $$;

SELECT zz.mkuser('30000000-0000-0000-0000-0000000000d1', 'wfin@zz.test', '{"full_name":"Alpha Finance","phone":"+233241000061"}');
INSERT INTO public.business_staff(business_id, user_id, role, status, joined_at)
VALUES ((SELECT id FROM zz.b WHERE name = 'Alpha Wholesale'), '30000000-0000-0000-0000-0000000000d1', 'finance'::public.staff_role, 'active'::public.staff_status, now());

CREATE TABLE zz.gx AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='ph_other') u_px,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM zz.u WHERE k='w_cashier') u_wc,
  (SELECT id FROM zz.u WHERE k='w_other') u_wx,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  '30000000-0000-0000-0000-0000000000d1'::uuid u_wf,
  NULL::uuid pa;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT b.id, 'GP A', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 5000, true FROM zz.b b WHERE b.name = 'Alpha Wholesale';
UPDATE zz.gx SET pa = (SELECT id FROM public.products WHERE name = 'GP A');
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.gx), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.gx)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;

CREATE TABLE zz.go_(label TEXT PRIMARY KEY, order_id UUID);
CREATE FUNCTION zz.ord(p_label TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT order_id FROM zz.go_ WHERE label = p_label $$;
CREATE FUNCTION zz.neworder(p_label TEXT, p_method TEXT DEFAULT 'pay_now') RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  r := zz.try(format('SELECT public.create_marketplace_orders(%L, %L, %L::jsonb, ''{}'', TRUE, %L::jsonb)::text', (SELECT u_po FROM zz.gx), (SELECT good FROM zz.gx),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.gx), 'quantity', 10, 'category', 'cash_private'))::text,
    jsonb_build_object((SELECT alpha FROM zz.gx)::text, p_method)::text));
  IF r NOT LIKE 'ERR:%' THEN INSERT INTO zz.go_ SELECT p_label, id FROM public.orders ORDER BY created_at DESC LIMIT 1; END IF;
  RETURN r;
END $$;
CREATE FUNCTION zz.apply(p_ref TEXT, p_status TEXT, p_minor BIGINT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_payment_result(''paystack'', ''test'', %L, %L, %s, ''GHS'', ''tx-1'', ''card'', 50, ''reconcile'')::text', p_ref, p_status, p_minor))::jsonb $$;
CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT, p_prepare BOOLEAN DEFAULT FALSE) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
  SELECT p_order, 'paystack', 'test', p_ref, o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  IF p_prepare THEN PERFORM zz.svc(format('SELECT public.prepare_attempt_for_provider(%L)::text', v_id)); END IF;
  RETURN v_id;
END $$;
-- Paid online (1000.00), accepted, then moved through to delivered.
CREATE FUNCTION zz.paid_delivered(p_order UUID, p_ref TEXT, p_prepare BOOLEAN DEFAULT FALSE) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID := zz.att(p_order, p_ref, p_prepare); s TEXT;
BEGIN
  PERFORM zz.apply(p_ref, 'success', 100000);
  UPDATE public.orders SET status = 'accepted' WHERE id = p_order;
  FOREACH s IN ARRAY ARRAY['picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] LOOP
    EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', s, p_order);
  END LOOP;
  RETURN v_id;
END $$;
-- A return of `p_qty` units, all accepted, taken through to resolution; returns the text of the last step (the resolution's answer or its error).
CREATE FUNCTION zz.do_return(p_order UUID, p_qty INT, p_accept INT, p_resolution TEXT, OUT ret_id UUID, OUT outcome TEXT) LANGUAGE plpgsql AS $$
DECLARE r TEXT; v_item UUID := (SELECT id FROM public.order_items WHERE order_id = p_order LIMIT 1);
BEGIN
  r := zz.val_as((SELECT u_po FROM zz.gx), format('SELECT public.request_order_return(%L, ''damaged'', ''Box crushed'', %L::jsonb)::text', p_order, jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'quantity', p_qty))::text));
  IF r LIKE 'ERR%' THEN outcome := 'request: ' || r; RETURN; END IF;
  ret_id := r::uuid;
  r := zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.review_order_return(%L, true, NULL)::text', ret_id));
  r := zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.mark_order_return_returned(%L)::text', ret_id));
  r := zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.inspect_order_return(%L, %L::jsonb)::text', ret_id,
    (SELECT jsonb_agg(jsonb_build_object('return_item_id', i.id, 'quantity_accepted', p_accept, 'restock', true)) FROM public.order_return_items i WHERE i.return_id = ret_id)::text));
  IF r LIKE 'ERR%' THEN outcome := 'inspect: ' || r; RETURN; END IF;
  outcome := zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.resolve_order_return(%L, %L, ''Done'')::text', ret_id, p_resolution));
END $$;
CREATE FUNCTION zz.rstat(p_order UUID) RETURNS TEXT LANGUAGE sql AS $$
  SELECT string_agg(r.status || '/' || r.amount_minor || '/' || r.reason, ',' ORDER BY r.created_at, r.amount_minor) FROM public.order_refunds r WHERE r.order_id = p_order $$;
CREATE FUNCTION zz.gj(p_uid UUID, p_sql TEXT) RETURNS JSONB LANGUAGE sql AS $$ SELECT NULLIF(zz.val_as(p_uid, p_sql), '')::jsonb $$;
CREATE FUNCTION zz.overview(p_uid UUID, p_wholesaler UUID, p_days INT DEFAULT 30) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.val_as(p_uid, format('SELECT public.supplier_settlement_overview(%L, now() - interval ''%s days'', now() + interval ''1 day'')::text', p_wholesaler, p_days)) $$;

UPDATE public.payments_settings SET online_enabled = FALSE, mode = 'test', auto_refunds = FALSE, split_mode = 'none', platform_fee_bps = 250, fee_bearer = 'subaccount',
  max_order_ghs = NULL, split_refunds_confirmed = FALSE;
UPDATE public.payments_settings SET online_enabled = TRUE;
SELECT zz.neworder('G1');
SELECT zz.neworder('G2');
SELECT zz.neworder('G3');
SELECT zz.neworder('G4');
SELECT zz.neworder('G5');
SELECT zz.neworder('C1', 'cod');
SELECT zz.neworder('G6');
SELECT zz.check('setup: seven orders placed', (SELECT count(*) FROM zz.go_) = 7, (SELECT string_agg(label, ',') FROM zz.go_));

-- Each online order is paid and delivered here (G1..G5, G6 for the supplier overview), the cash order delivered without payment.
DO $$
BEGIN
  PERFORM zz.paid_delivered(zz.ord('G1'), 'dx-test-gp-0001');
  PERFORM zz.paid_delivered(zz.ord('G2'), 'dx-test-gp-0002');
  PERFORM zz.paid_delivered(zz.ord('G3'), 'dx-test-gp-0003');
  PERFORM zz.paid_delivered(zz.ord('G4'), 'dx-test-gp-0004');
  PERFORM zz.paid_delivered(zz.ord('G5'), 'dx-test-gp-0005');
END $$;
DO $$
DECLARE s TEXT;
BEGIN
  UPDATE public.orders SET status = 'accepted' WHERE id = zz.ord('C1');
  FOREACH s IN ARRAY ARRAY['picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] LOOP
    EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', s, zz.ord('C1'));
  END LOOP;
END $$;

-- ===== Gap 2: a return resolved as a refund on an order paid online ================================================================================================================
DO $$
DECLARE x RECORD; r TEXT; money JSONB;
BEGIN
  UPDATE public.payments_settings SET auto_refunds = TRUE;
  x := zz.do_return(zz.ord('G1'), 3, 3, 'refund');
  PERFORM zz.check('R: resolving a return as a refund on an order paid online succeeds', x.outcome NOT LIKE 'ERR%' AND x.outcome::numeric = 300, x.outcome);
  PERFORM zz.check('R: it asks for a refund of exactly the accepted value (3 x 100), reason "order_return"', zz.rstat(zz.ord('G1')) LIKE '%/30000/order_return', zz.rstat(zz.ord('G1')));
  PERFORM zz.check('R: it waits for an administrator even with automatic refunds ON (a wholesaler decides a return)', zz.rstat(zz.ord('G1')) LIKE 'requested/%', zz.rstat(zz.ord('G1')));
  PERFORM zz.check('R: the same return can be resolved only once (a second request is refused)', zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.resolve_order_return(%L, ''refund'', ''again'')::text', x.ret_id)) LIKE 'ERR:%');
  money := public.order_money(zz.ord('G1'));
  PERFORM zz.check('R: the order is not made to look as if the pharmacy owes a top-up: balance stays 0, nothing due', (money ->> 'balance_minor')::bigint = 0 AND public.order_topup_due_minor(zz.ord('G1')) = 0, money::text);
  PERFORM zz.check('R: and the refund is not counted as money returned against the price', (money ->> 'alive_refund_minor')::bigint = 0 AND (money ->> 'refunded_minor')::bigint = 0, money::text);
  PERFORM zz.check('R: the pharmacy''s payment summary still shows the refund waiting', (public.order_payment_summary(zz.ord('G1')) ->> 'refunded_ghs') IS NOT NULL);

  -- credit, replacement and none create no refund
  x := zz.do_return(zz.ord('G2'), 2, 2, 'credit');
  PERFORM zz.check('R: resolving as credit asks for no refund (a statement credit, as before)', x.outcome::numeric = 200 AND zz.rstat(zz.ord('G2')) IS NULL, x.outcome || ' ' || COALESCE(zz.rstat(zz.ord('G2')), '-'));
  x := zz.do_return(zz.ord('G2'), 1, 1, 'replacement');
  PERFORM zz.check('R: nor does a replacement', zz.rstat(zz.ord('G2')) IS NULL, x.outcome);
  x := zz.do_return(zz.ord('G2'), 1, 0, 'none');
  PERFORM zz.check('R: nor "no action"', zz.rstat(zz.ord('G2')) IS NULL, x.outcome);

  -- a cash order is unchanged
  x := zz.do_return(zz.ord('C1'), 2, 2, 'refund');
  PERFORM zz.check('R: a refund on a CASH order is unchanged: resolved, no provider refund', x.outcome::numeric = 200 AND zz.rstat(zz.ord('C1')) IS NULL, x.outcome);
  UPDATE public.payments_settings SET auto_refunds = FALSE;
END $$;

DO $$
DECLARE x RECORD; rid UUID; before_cnt INT;
BEGIN
  -- an unsent amendment refund is netted off when the price rises, but a return refund is left alone
  x := zz.do_return(zz.ord('G3'), 2, 2, 'refund');
  PERFORM zz.check('R: (setup) a return refund of 200 is waiting', zz.rstat(zz.ord('G3')) = 'requested/20000/order_return', zz.rstat(zz.ord('G3')));
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 900 WHERE id = zz.ord('G3');
  PERFORM zz.check('R: (setup) the order was reduced to 900: an amendment refund of 100 is also waiting', zz.rstat(zz.ord('G3')) LIKE '%requested/10000/amendment_reduction%' AND zz.rstat(zz.ord('G3')) LIKE '%requested/20000/order_return%', zz.rstat(zz.ord('G3')));
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 1000 WHERE id = zz.ord('G3');
  PERFORM zz.check('R: when the price rises again the amendment refund is cancelled but the RETURN refund stays', zz.rstat(zz.ord('G3')) LIKE '%cancelled/10000/amendment_reduction%' AND zz.rstat(zz.ord('G3')) LIKE '%requested/20000/order_return%', zz.rstat(zz.ord('G3')));
  PERFORM zz.check('R: and no top-up is due (the order costs what was paid)', public.order_topup_due_minor(zz.ord('G3')) = 0);

  -- more than can still be refunded: refused with a plain message, the return stays inspected
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 1000 WHERE id = zz.ord('G4');
  x := zz.do_return(zz.ord('G4'), 10, 10, 'refund');
  PERFORM zz.check('R: a return worth the whole payment can be refunded (1000 of 1000)', x.outcome::numeric = 1000 AND zz.rstat(zz.ord('G4')) = 'requested/100000/order_return', x.outcome || ' ' || COALESCE(zz.rstat(zz.ord('G4')), '-'));
  x := zz.do_return(zz.ord('G5'), 10, 10, 'refund');
  PERFORM zz.check('R: (setup) another full-value return on a different order is fine', x.outcome::numeric = 1000);
END $$;

DO $$
DECLARE x RECORD; rid UUID; r TEXT; ord UUID := zz.ord('G5');
BEGIN
  -- G5's payment has 1000 and a 1000 return refund waiting. A second return cannot add up to more than the payment (the one-per-line rule means we use a fresh order for the cap test).
  PERFORM zz.check('R: the cap holds at the database: refunds of one payment can never exceed it',
    zz.try(format('SELECT public._request_order_refund(%L, 1000, ''order_return'', ''return:extra'')::text', ord)) = '1000', zz.try(format('SELECT public._request_order_refund(%L, 1000, ''order_return'', ''return:extra2'')::text', ord)));
  r := zz.try(format('SELECT public._refund_online_return(%L, %L, 100)::text', gen_random_uuid(), ord));
  PERFORM zz.check('R: a return that cannot be refunded in full is refused in plain words and suggests a credit', r LIKE 'ERR: The payment for order % has only GH% 0.00 left%Resolve it as a credit instead%', r);
  -- an administrator can approve a return refund like any other
  r := zz.svc(format('SELECT public.admin_refund_transition(%L, %L, ''approve'', NULL)::text', (SELECT u_admin FROM zz.gx), (SELECT id FROM public.order_refunds WHERE order_id = ord AND reason = 'order_return' LIMIT 1)));
  PERFORM zz.check('R: a platform administrator can approve a return refund', r LIKE '%approved%' OR r LIKE '%needs_submission%', r);
  PERFORM zz.check('R: the new reason is accepted by the refund ledger and no other unknown reason is', zz.try('INSERT INTO public.order_refunds(order_id, attempt_id, provider, mode, amount_ghs, amount_minor, reason, source_key) SELECT order_id, id, ''paystack'', ''test'', 1, 100, ''bogus'', ''x:bogus'' FROM public.order_payment_attempts LIMIT 1') LIKE 'ERR:%');
END $$;

-- ===== Gap 1: the supplier's own view =======================================================================================================================================================
DO $$
DECLARE r TEXT; j JSONB; alpha UUID := (SELECT alpha FROM zz.gx); other UUID := (SELECT other FROM zz.gx); a UUID; acc UUID; rid UUID;
BEGIN
  UPDATE public.payments_settings SET split_mode = 'none', online_enabled = TRUE;
  -- who may look
  FOR r IN SELECT unnest(ARRAY['u_wo', 'u_wm', 'u_wf']) LOOP
    PERFORM zz.check('S: ' || r || ' (owner / manager / finance) can see the supplier''s online payments', zz.overview((SELECT CASE r WHEN 'u_wo' THEN u_wo WHEN 'u_wm' THEN u_wm ELSE u_wf END FROM zz.gx), alpha) NOT LIKE 'ERR:%');
  END LOOP;
  PERFORM zz.check('S: a cashier cannot', zz.overview((SELECT u_wc FROM zz.gx), alpha) LIKE 'ERR: You do not have permission%');
  PERFORM zz.check('S: a pharmacy owner cannot', zz.overview((SELECT u_po FROM zz.gx), alpha) LIKE 'ERR: You do not have permission%');
  PERFORM zz.check('S: another supplier''s owner cannot see this supplier''s', zz.overview((SELECT u_wx FROM zz.gx), alpha) LIKE 'ERR: You do not have permission%');
  PERFORM zz.check('S: nobody signed in cannot', zz.val_as(NULL, format('SELECT public.supplier_settlement_overview(%L, now() - interval ''1 day'', now())::text', alpha)) LIKE 'ERR: Sign in%');
  PERFORM zz.check('S: a pharmacy id is not a supplier', zz.overview((SELECT u_po FROM zz.gx), (SELECT good FROM zz.gx)) = 'ERR: Supplier not found.');
  PERFORM zz.check('S: a period must end after it starts and be at most 400 days', zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.supplier_settlement_overview(%L, now(), now() - interval ''1 day'')::text', alpha)) LIKE 'ERR: Choose a period%'
    AND zz.overview((SELECT u_wo FROM zz.gx), alpha, 401) LIKE 'ERR: Choose a period%');

  -- the status
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: with no split every supplier is ready (test phase), with no account shown', (j ->> 'ready')::boolean AND j -> 'account' = 'null'::jsonb AND j ->> 'split_mode' = 'none', j::text);
  UPDATE public.payments_settings SET split_mode = 'subaccount';
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: in split mode with no account the supplier is not ready', NOT (j ->> 'ready')::boolean AND j -> 'account' = 'null'::jsonb, j::text);
  acc := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Alpha Wholesale Ltd'', ''GCB'', ''1234'')::text', (SELECT u_admin FROM zz.gx), alpha))::uuid;
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: a pending account is shown as pending, not ready', NOT (j ->> 'ready')::boolean AND j -> 'account' ->> 'status' = 'pending', j::text);
  PERFORM zz.svc(format('SELECT public.finish_payout_account(%L, ''ACCT_gap0001'', NULL)', acc));
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: an active account is ready, with only the last four digits and the bank', (j ->> 'ready')::boolean AND j -> 'account' ->> 'last4' = '1234' AND j -> 'account' ->> 'bank_code' = 'GCB', j::text);
  PERFORM zz.check('S: nothing about the provider''s account code or failures is revealed', j::text NOT LIKE '%ACCT_gap0001%' AND j::text NOT LIKE '%failure%' AND j::text NOT LIKE '%provider_subaccount%');
  PERFORM zz.check('S: another supplier does not see this supplier''s account', zz.overview((SELECT u_wx FROM zz.gx), other) NOT LIKE '%1234%');
  UPDATE public.supplier_payout_accounts SET status = 'inactive' WHERE id = acc;
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: a switched-off account is shown as such and is not ready', NOT (j ->> 'ready')::boolean AND j -> 'account' ->> 'status' = 'inactive', j::text);
  UPDATE public.supplier_payout_accounts SET status = 'active' WHERE id = acc;
  UPDATE public.payments_settings SET online_enabled = FALSE;
  PERFORM zz.check('S: when online payments are off it says so', NOT (zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb ->> 'online_enabled')::boolean);
  UPDATE public.payments_settings SET online_enabled = TRUE;
END $$;

DO $$
DECLARE j JSONB; alpha UUID := (SELECT alpha FROM zz.gx); a UUID; rid UUID;
BEGIN
  -- a split payment: 1000 received, 25 to the platform; then a 200 refund that succeeded
  PERFORM zz.neworder('S1');
END $$;
DO $$
DECLARE j JSONB; alpha UUID := (SELECT alpha FROM zz.gx); a UUID; rid UUID;
BEGIN
  UPDATE public.order_payment_attempts SET paid_at = now() - interval '40 days' WHERE status = 'succeeded';
  a := zz.att(zz.ord('S1'), 'dx-test-gp-0100', TRUE);
  PERFORM zz.apply('dx-test-gp-0100', 'success', 100000);
  rid := public._request_refund(a, 20000, 'amendment_reduction', 'gp:s1', NULL, NULL);
  UPDATE public.order_refunds SET status = 'approved', approved_at = now() WHERE id = rid;
  UPDATE public.order_refunds SET status = 'submitting' WHERE id = rid;
  UPDATE public.order_refunds SET status = 'processing' WHERE id = rid;
  UPDATE public.order_refunds SET status = 'succeeded', completed_at = now() WHERE id = rid;
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha)::jsonb;
  PERFORM zz.check('S: the summary counts the payment received in the period and nothing older', (j -> 'summary' ->> 'payments')::int = 1 AND (j -> 'summary' ->> 'received_ghs')::numeric = 1000, (j -> 'summary')::text);
  PERFORM zz.check('S: the platform''s share is GHS 25.00 (2.5%)', (j -> 'summary' ->> 'platform_share_ghs')::numeric = 25, (j -> 'summary')::text);
  PERFORM zz.check('S: refunds that succeeded are taken off (GHS 200.00) and what should settle is 1000 - 25 - 200 = 775', (j -> 'summary' ->> 'refunded_ghs')::numeric = 200 AND (j -> 'summary' ->> 'to_settle_ghs')::numeric = 775, (j -> 'summary')::text);
  PERFORM zz.check('S: the recent list shows the order number, amount and refund', jsonb_array_length(j -> 'recent') = 1 AND j -> 'recent' -> 0 ->> 'order_number' = (SELECT order_number FROM public.orders WHERE id = zz.ord('S1'))
    AND (j -> 'recent' -> 0 ->> 'refunded_ghs')::numeric = 200, (j -> 'recent')::text);
  j := zz.overview((SELECT u_wx FROM zz.gx), (SELECT other FROM zz.gx))::jsonb;
  PERFORM zz.check('S: another supplier sees none of it', (j -> 'summary' ->> 'payments')::int = 0 AND (j -> 'summary' ->> 'received_ghs')::numeric = 0 AND jsonb_array_length(j -> 'recent') = 0, j::text);
  j := zz.overview((SELECT u_wo FROM zz.gx), alpha, 30)::jsonb;
  PERFORM zz.check('S: a 30-day window leaves out the payments made 40 days ago', (j -> 'summary' ->> 'payments')::int = 1);
  j := zz.val_as((SELECT u_wo FROM zz.gx), format('SELECT public.supplier_settlement_overview(%L, now() - interval ''90 days'', now() + interval ''1 day'')::text', alpha))::jsonb;
  PERFORM zz.check('S: a 90-day window includes them (the earlier orders were paid unsplit: platform share stays 25)', (j -> 'summary' ->> 'payments')::int >= 6 AND (j -> 'summary' ->> 'platform_share_ghs')::numeric = 25, (j -> 'summary')::text);
END $$;

DO $$
DECLARE r TEXT; fn TEXT; u RECORD;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.gx)), ('a wholesaler owner', (SELECT u_wo FROM zz.gx)), ('an admin', (SELECT u_admin FROM zz.gx))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['_refund_online_return(gen_random_uuid(), gen_random_uuid(), 10)', 'order_money(gen_random_uuid())'] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
