-- Online payments (Pay Now), P5: settlement (where a payment's money ends up) and the controls for going live (the per-payment limit, supplier settlement accounts, the split recorded on
-- every payment, the readiness check, the guard on switching live payments on, the settlement report, and refunds of split payments). Run after setup.sql + migrations (through
-- 20261111120000_payments_settlement_patches.sql), with the production guard and stock fixtures installed and the checkout compatibility migration (20261017110000) re-applied.
GRANT USAGE ON SCHEMA zz TO authenticated;
GRANT SELECT ON zz.b, zz.u TO authenticated;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
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
-- As the superuser, catching an error as text (for internal functions and for what a trigger refuses).
CREATE FUNCTION zz.try(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  BEGIN
    IF p_sql ~* '^[[:space:]]*select' THEN EXECUTE p_sql INTO r; ELSE EXECUTE p_sql; END IF;
  EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  RETURN r;
END $$;

CREATE TABLE zz.sx AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  (SELECT id FROM public.products WHERE name='BO A') pa;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT b.id, 'BO A', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b b WHERE b.name = 'Alpha Wholesale' AND NOT EXISTS (SELECT 1 FROM public.products WHERE name = 'BO A');
UPDATE zz.sx SET pa = (SELECT id FROM public.products WHERE name = 'BO A');
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.sx), 'role', 'authenticated')::text, false);
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.sx)::text, false);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;

CREATE TABLE zz.so(label TEXT PRIMARY KEY, order_id UUID);
CREATE FUNCTION zz.ord(p_label TEXT) RETURNS UUID LANGUAGE sql AS $$ SELECT order_id FROM zz.so WHERE label = p_label $$;
CREATE FUNCTION zz.att(p_order UUID, p_ref TEXT, p_mode TEXT DEFAULT 'test') RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
  SELECT p_order, 'paystack', p_mode, p_ref, o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = p_order RETURNING id INTO v_id;
  RETURN v_id;
END $$;
CREATE FUNCTION zz.prep(p_attempt UUID) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.svc(format('SELECT public.prepare_attempt_for_provider(%L)::text', p_attempt)) $$;
CREATE FUNCTION zz.auth(p_attempt UUID) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.record_attempt_authorization(%L, ''https://checkout.test/x'', ''ac1'')::text', p_attempt)) $$;
CREATE FUNCTION zz.apply(p_ref TEXT, p_status TEXT, p_minor BIGINT) RETURNS JSONB LANGUAGE sql AS $$
  SELECT zz.svc(format('SELECT public.apply_payment_result(''paystack'', ''test'', %L, %L, %s, ''GHS'', ''tx-1'', ''card'', 50, ''reconcile'')::text', p_ref, p_status, p_minor))::jsonb $$;
CREATE FUNCTION zz.adm(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.val_as((SELECT u_admin FROM zz.sx), p_sql) $$;
CREATE FUNCTION zz.neworder(p_label TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  r := zz.try(format('SELECT public.create_marketplace_orders(%L, %L, %L::jsonb, ''{}'', TRUE, %L::jsonb)::text', (SELECT u_po FROM zz.sx), (SELECT good FROM zz.sx),
    jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.sx), 'quantity', 10, 'category', 'cash_private'))::text,
    jsonb_build_object((SELECT alpha FROM zz.sx)::text, 'pay_now')::text));
  IF r NOT LIKE 'ERR:%' THEN
    INSERT INTO zz.so SELECT p_label, id FROM public.orders ORDER BY created_at DESC LIMIT 1;
  END IF;
  RETURN r;
END $$;
CREATE FUNCTION zz.reset_settings() RETURNS VOID LANGUAGE sql AS $$
  UPDATE public.payments_settings SET online_enabled = FALSE, mode = 'test', auto_refunds = FALSE, split_mode = 'none', platform_fee_bps = 0, fee_bearer = 'subaccount',
    max_order_ghs = NULL, split_refunds_confirmed = FALSE, reconciler_frequent_at = NULL, reconciler_daily_at = NULL WHERE id $$;

SELECT zz.reset_settings();
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test';

-- Orders placed up front, one statement each (a checkout call keeps a temporary table for its transaction, so a block can place only one).
SELECT zz.neworder('N1');
SELECT zz.neworder('N2');
SELECT zz.neworder('N5');
SELECT zz.neworder('N6');
SELECT zz.neworder('N7');
SELECT zz.neworder('R1');
SELECT zz.neworder('R2');
SELECT zz.check('setup: seven online orders placed', (SELECT count(*) FROM zz.so) = 7, (SELECT string_agg(label, ',') FROM zz.so));

-- 1. Defaults: nothing about a payment changes -----------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; a UUID; s RECORD;
BEGIN
  SELECT * INTO s FROM public.payments_settings WHERE id;
  PERFORM zz.check('1: by default there is no split, no commission, no cap and refunds of split payments are not confirmed',
    s.split_mode = 'none' AND s.platform_fee_bps = 0 AND s.max_order_ghs IS NULL AND NOT s.split_refunds_confirmed AND s.fee_bearer = 'subaccount');
  PERFORM zz.check('1: checkout still creates an online order', zz.ord('N1') IS NOT NULL);
  a := zz.att(zz.ord('N1'), 'dx-test-sx-0001');
  PERFORM zz.check('1: an unprepared payment is still given its checkout address while nothing is set (the earlier phases are unaffected)', zz.auth(a) = 'true', zz.auth(a));
  a := zz.att(zz.ord('N1'), 'dx-test-sx-0002');
  r := zz.prep(a);
  PERFORM zz.check('1: preparing with the defaults says: no split', r::jsonb = jsonb_build_object('split', FALSE), r);
  PERFORM zz.check('1: and records that it was checked, with nothing split', (SELECT prepared_at IS NOT NULL AND split_subaccount IS NULL AND split_charge_minor IS NULL FROM public.order_payment_attempts WHERE id = a));
  PERFORM zz.check('1: preparing twice is harmless', zz.prep(a)::jsonb = jsonb_build_object('split', FALSE));
  PERFORM zz.check('1: online payments status carries the limit (empty) and still says enabled', (public.online_payments_status() ->> 'enabled')::boolean AND public.online_payments_status() -> 'max_order_ghs' = 'null'::jsonb,
    public.online_payments_status()::text);
END $$;

-- 2. The limit for one online payment -------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; a UUID; b UUID;
BEGIN
  UPDATE public.payments_settings SET max_order_ghs = 500 WHERE id;
  a := zz.att(zz.ord('N2'), 'dx-test-sx-0003');
  r := zz.prep(a);
  PERFORM zz.check('2: a payment above the limit is refused, in plain words, naming the limit', r LIKE 'ERR: This payment is above the limit for online payments (GH% 500.00)%', r);
  PERFORM zz.check('2: and it was not marked as checked', (SELECT prepared_at IS NULL FROM public.order_payment_attempts WHERE id = a));
  r := zz.auth(a);
  PERFORM zz.check('2: while a limit is set, a payment that was not checked is not given a checkout address', r LIKE 'ERR: This payment has not been checked%', r);
  PERFORM zz.check('2: the status shown to screens carries the limit', (public.online_payments_status() ->> 'max_order_ghs')::numeric = 500);
  UPDATE public.payments_settings SET max_order_ghs = 1000 WHERE id;
  b := zz.att(zz.ord('N2'), 'dx-test-sx-0004');
  PERFORM zz.check('2: a payment exactly at the limit is allowed', zz.prep(b)::jsonb = jsonb_build_object('split', FALSE), zz.prep(b));
  PERFORM zz.check('2: and then it can be given its checkout address', zz.auth(b) = 'true', zz.auth(b));
  r := zz.try('UPDATE public.payments_settings SET max_order_ghs = 0 WHERE id');
  PERFORM zz.check('2: a limit of nothing is not a limit', r LIKE 'ERR:%', r);
  UPDATE public.payments_settings SET max_order_ghs = NULL WHERE id;
END $$;

-- 3. Settlement accounts ---------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; acc UUID; acc2 UUID; admin UUID := (SELECT u_admin FROM zz.sx); alpha UUID := (SELECT alpha FROM zz.sx); other UUID := (SELECT other FROM zz.sx);
BEGIN
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Alpha Wholesale Ltd'', ''GCB'', ''1234'')::text', (SELECT u_po FROM zz.sx), alpha));
  PERFORM zz.check('3: only an administrator can create a settlement account', r = 'ERR: Only platform administrators can do this.', r);
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Good Pharmacy'', ''GCB'', ''1234'')::text', admin, (SELECT good FROM zz.sx)));
  PERFORM zz.check('3: only for a wholesaler, not a pharmacy', r = 'ERR: Supplier not found.', r);
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''sandbox'', ''Alpha Wholesale Ltd'', ''GCB'', ''1234'')::text', admin, alpha));
  PERFORM zz.check('3: only for test or live', r = 'ERR: Unknown payment mode.', r);
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Alpha Wholesale Ltd'', ''GCB'', ''1234567890'')::text', admin, alpha));
  PERFORM zz.check('3: the full account number cannot be stored: only the last digits fit', r LIKE 'ERR:%', r);
  acc := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Alpha Wholesale Ltd'', ''GCB'', ''1234'')::text', admin, alpha))::uuid;
  PERFORM zz.check('3: a settlement account is created waiting for the provider', (SELECT status = 'pending' AND provider_subaccount_code IS NULL FROM public.supplier_payout_accounts WHERE id = acc));
  PERFORM zz.check('3: a pending account does not make the supplier ready', NOT public.payout_account_ready(alpha, 'paystack', 'test') OR (SELECT split_mode = 'none' FROM public.payments_settings WHERE id));
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Again Ltd'', ''GCB'', ''5678'')::text', admin, alpha));
  PERFORM zz.check('3: a second account for the same supplier and mode is refused while one is in use', r LIKE 'ERR: This supplier already has a settlement account%', r);
  r := zz.svc(format('SELECT public.finish_payout_account(%L, ''ACCT_test0001'', NULL)', acc));
  PERFORM zz.check('3: the provider''s answer makes it active', r = 'active' AND (SELECT status = 'active' AND provider_subaccount_code = 'ACCT_test0001' FROM public.supplier_payout_accounts WHERE id = acc), r);
  r := zz.svc(format('SELECT public.finish_payout_account(%L, ''ACCT_test0002'', NULL)', acc));
  PERFORM zz.check('3: an active account cannot be finished again', r LIKE 'ERR: That settlement account is not waiting%', r);
  r := zz.try(format('UPDATE public.supplier_payout_accounts SET provider_subaccount_code = ''ACCT_other'' WHERE id = %L', acc));
  PERFORM zz.check('3: the provider''s code cannot be swapped', r LIKE 'ERR: The provider''s account code cannot be changed.', r);
  r := zz.try(format('UPDATE public.supplier_payout_accounts SET settlement_bank_code = ''ABC'' WHERE id = %L', acc));
  PERFORM zz.check('3: what the account was made for cannot be changed', r LIKE 'ERR: What a payout account was made for cannot be changed.', r);
  r := zz.try(format('DELETE FROM public.supplier_payout_accounts WHERE id = %L', acc));
  PERFORM zz.check('3: it is never deleted', r LIKE 'ERR: Payout accounts are never deleted.', r);
  r := zz.try(format('INSERT INTO public.supplier_payout_accounts(wholesaler_id, mode, business_name, settlement_bank_code, account_last4, status, provider_subaccount_code) VALUES (%L, ''test'', ''Dup'', ''GCB'', ''1111'', ''active'', ''ACCT_test0001'')', other));
  PERFORM zz.check('3: one provider code belongs to one account', r LIKE 'ERR:%', r);

  -- failures keep a history and allow a new account
  acc2 := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Other Wholesale Ltd'', ''GCB'', ''9999'')::text', admin, other))::uuid;
  r := zz.svc(format('SELECT public.finish_payout_account(%L, NULL, ''The provider refused it.'')', acc2));
  PERFORM zz.check('3: a refusal is recorded with its reason', r = 'failed' AND (SELECT failure_reason = 'The provider refused it.' FROM public.supplier_payout_accounts WHERE id = acc2), r);
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Other Wholesale Ltd'', ''GCB'', ''9999'')::text', admin, other));
  PERFORM zz.check('3: after a failure a new one can be made', r NOT LIKE 'ERR:%', r);
  UPDATE public.supplier_payout_accounts SET created_at = now() - interval '20 minutes' WHERE wholesaler_id = other AND status = 'pending';
  r := zz.svc(format('SELECT public.begin_payout_account(%L, %L, ''test'', ''Other Wholesale Ltd'', ''GCB'', ''9999'')::text', admin, other));
  PERFORM zz.check('3: a request that never got an answer does not block a new one for ever, and says so', r NOT LIKE 'ERR:%' AND EXISTS (SELECT 1 FROM public.supplier_payout_accounts WHERE wholesaler_id = other AND status = 'failed' AND failure_reason LIKE 'No answer was recorded%'), r);
  r := zz.svc(format('SELECT public.finish_payout_account(%L, NULL, NULL)', r::uuid));
  PERFORM zz.check('3: with no reason given a failure still says something', r = 'failed' AND (SELECT failure_reason IS NOT NULL FROM public.supplier_payout_accounts WHERE wholesaler_id = other AND status = 'failed' ORDER BY updated_at DESC LIMIT 1), r);

  -- switching off and on
  r := zz.svc(format('SELECT public.admin_set_payout_account_status(%L, %L, FALSE)', (SELECT u_po FROM zz.sx), acc));
  PERFORM zz.check('3: only an administrator switches an account off', r = 'ERR: Only platform administrators can do this.', r);
  r := zz.svc(format('SELECT public.admin_set_payout_account_status(%L, %L, FALSE)', admin, acc));
  PERFORM zz.check('3: an account can be switched off', r = 'inactive', r);
  PERFORM zz.check('3: and then the supplier is not ready (in split mode)', (SELECT NOT public.payout_account_ready(alpha, 'paystack', 'test') OR split_mode = 'none' FROM public.payments_settings WHERE id));
  r := zz.svc(format('SELECT public.admin_set_payout_account_status(%L, %L, TRUE)', admin, acc));
  PERFORM zz.check('3: and back on', r = 'active', r);
  r := zz.svc(format('SELECT public.admin_set_payout_account_status(%L, %L, TRUE)', admin, acc));
  PERFORM zz.check('3: only a switched-off account can be switched on', r LIKE 'ERR: Only a switched-off account can be switched back on.', r);
  r := zz.svc(format('SELECT public.admin_set_payout_account_status(%L, %L, TRUE)', admin, gen_random_uuid()));
  PERFORM zz.check('3: an unknown account is refused', r = 'ERR: Settlement account not found.', r);

  -- the administrator's view
  r := zz.adm('SELECT public.admin_payout_accounts()::text');
  PERFORM zz.check('3: the administrator sees the suppliers, their accounts and the settings, with only the last four digits',
    r NOT LIKE 'ERR:%' AND (r::jsonb -> 'suppliers') @> jsonb_build_array(jsonb_build_object('name', 'Alpha Wholesale')) AND r LIKE '%"last4": "1234"%' AND r NOT LIKE '%1234567890%', left(r, 200));
  r := zz.val_as((SELECT u_po FROM zz.sx), 'SELECT public.admin_payout_accounts()::text');
  PERFORM zz.check('3: nobody else sees it', r LIKE 'ERR: Only platform administrators%', r);
  PERFORM zz.check('3: and the table itself is unreadable to a pharmacy and a supplier',
    zz.val_as((SELECT u_po FROM zz.sx), 'SELECT count(*)::text FROM public.supplier_payout_accounts') = '0'
    AND zz.val_as((SELECT u_wo FROM zz.sx), 'SELECT count(*)::text FROM public.supplier_payout_accounts') = '0');
END $$;

-- 4. Split mode: who can be paid online, and what each payment is split with ------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; a UUID; b UUID; alpha UUID := (SELECT alpha FROM zz.sx); other UUID := (SELECT other FROM zz.sx); j JSONB;
BEGIN
  UPDATE public.payments_settings SET split_mode = 'subaccount', platform_fee_bps = 250 WHERE id;
  PERFORM zz.check('4: in split mode only a supplier with an active account is ready',
    public.payout_account_ready(alpha, 'paystack', 'test') AND NOT public.payout_account_ready(other, 'paystack', 'test') AND NOT public.payout_account_ready(alpha, 'paystack', 'live'));
  r := zz.val_as((SELECT u_po FROM zz.sx), format('SELECT public.suppliers_ready_for_online_payment(ARRAY[%L, %L, %L]::uuid[])::text', alpha, other, (SELECT good FROM zz.sx)));
  PERFORM zz.check('4: checkout can ask which suppliers are ready: Alpha yes; Other no; a pharmacy never', r = format('{%s}', alpha), r);
  r := zz.val_as(NULL::uuid, 'SELECT public.suppliers_ready_for_online_payment(ARRAY[]::uuid[])::text');
  PERFORM zz.check('4: only a signed-in person can ask', r LIKE 'ERR:%', r);
  UPDATE public.payments_settings SET split_mode = 'none' WHERE id;
  PERFORM zz.check('4: with no split every supplier is ready', public.payout_account_ready(other, 'paystack', 'test'));
  UPDATE public.payments_settings SET split_mode = 'subaccount' WHERE id;

  -- checkout refuses an unready supplier, and takes a ready one
  UPDATE public.supplier_payout_accounts SET status = 'inactive' WHERE wholesaler_id = alpha AND status = 'active';
  r := zz.neworder('N3');
  PERFORM zz.check('4: checkout refuses Pay now for a supplier that cannot take online payments yet', r LIKE 'ERR: A supplier in this order cannot take online payments yet.%', r);
  PERFORM zz.check('4: and no order was created', (SELECT count(*) FROM zz.so WHERE label = 'N3') = 0);
  UPDATE public.supplier_payout_accounts SET status = 'active' WHERE wholesaler_id = alpha AND status = 'inactive';
  r := zz.neworder('N4');
  PERFORM zz.check('4: with an active account checkout takes it', r NOT LIKE 'ERR:%', r);

  -- the split recorded on the payment
  a := zz.att(zz.ord('N4'), 'dx-test-sx-0005');
  j := zz.prep(a)::jsonb;
  PERFORM zz.check('4: the payment is split with the supplier''s account and the platform''s share (2.5% of GHS 1000.00 = GHS 25.00)',
    j = jsonb_build_object('split', TRUE, 'subaccount', 'ACCT_test0001', 'charge_minor', 2500, 'bearer', 'subaccount'), j::text);
  PERFORM zz.check('4: recorded on the payment, with the time it was checked', (SELECT split_subaccount = 'ACCT_test0001' AND split_charge_minor = 2500 AND split_bearer = 'subaccount' AND prepared_at IS NOT NULL FROM public.order_payment_attempts WHERE id = a));
  PERFORM zz.check('4: asking again returns the same answer', zz.prep(a)::jsonb = j);
  UPDATE public.payments_settings SET platform_fee_bps = 1000, fee_bearer = 'account' WHERE id;
  PERFORM zz.check('4: and a later change of the commission does not change a payment already prepared', zz.prep(a)::jsonb = j);
  r := zz.try(format('UPDATE public.order_payment_attempts SET split_charge_minor = 0 WHERE id = %L', a));
  PERFORM zz.check('4: how a payment was split can never be changed', r = 'ERR: How a payment was split cannot be changed.', r);
  r := zz.try(format('UPDATE public.order_payment_attempts SET split_subaccount = NULL, split_charge_minor = NULL, split_bearer = NULL, prepared_at = NULL WHERE id = %L', a));
  PERFORM zz.check('4: nor removed', r = 'ERR: How a payment was split cannot be changed.', r);
  PERFORM zz.check('4: a checked payment is given its checkout address', zz.auth(a) = 'true');
  b := zz.att(zz.ord('N4'), 'dx-test-sx-0006');
  j := zz.prep(b)::jsonb;
  PERFORM zz.check('4: a new payment takes the new commission (10% = GHS 100.00) and bearer', j ->> 'charge_minor' = '10000' AND j ->> 'bearer' = 'account', j::text);
  PERFORM zz.check('4: in split mode an unchecked payment is not given a checkout address', zz.auth(zz.att(zz.ord('N4'), 'dx-test-sx-0007')) LIKE 'ERR: This payment has not been checked%');
  UPDATE public.payments_settings SET platform_fee_bps = 0 WHERE id;
  j := zz.prep(zz.att(zz.ord('N4'), 'dx-test-sx-0008'))::jsonb;
  PERFORM zz.check('4: no commission means the platform''s share is nothing, still stated', j ->> 'charge_minor' = '0' AND (j ->> 'split')::boolean, j::text);
  r := zz.try(format('INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, split_subaccount, split_charge_minor, split_bearer) VALUES (%L, ''paystack'', ''test'', ''dx-test-sx-0009'', 10, 1000, ''ACCT_x'', 2000, ''account'')', zz.ord('N4')));
  PERFORM zz.check('4: the platform''s share can never be more than the payment', r LIKE 'ERR:%', r);

  -- a supplier without an account, a live attempt against a test account, a switched-off account
  UPDATE public.supplier_payout_accounts SET status = 'inactive' WHERE wholesaler_id = alpha AND status = 'active';
  r := zz.prep(zz.att(zz.ord('N4'), 'dx-test-sx-0010'));
  PERFORM zz.check('4: an attempt for a supplier whose account was switched off is refused', r LIKE 'ERR: This supplier cannot receive online payments yet.%', r);
  UPDATE public.supplier_payout_accounts SET status = 'active' WHERE wholesaler_id = alpha AND status = 'inactive';
  r := zz.prep(zz.att(zz.ord('N4'), 'dx-live-sx-0011', 'live'));
  PERFORM zz.check('4: a test account does not serve a live payment', r LIKE 'ERR: This supplier cannot receive online payments yet.%', r);
  PERFORM zz.check('4: the refusal did not mark it as checked', (SELECT prepared_at IS NULL FROM public.order_payment_attempts WHERE reference = 'dx-live-sx-0011'));
  UPDATE public.order_payment_attempts SET status = 'failed' WHERE reference = 'dx-live-sx-0011';
  r := zz.prep((SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-live-sx-0011'));
  PERFORM zz.check('4: a payment that already failed cannot be started', r = 'ERR: This payment can no longer be started.', r);
  r := zz.svc('SELECT public.prepare_attempt_for_provider(gen_random_uuid())::text');
  PERFORM zz.check('4: an unknown payment is refused', r = 'ERR: Payment not found.', r);
END $$;

-- 5. Refunds of a split payment wait for a person until how Paystack takes them is confirmed ---------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; a UUID; u UUID; rid UUID; alpha UUID := (SELECT alpha FROM zz.sx);
BEGIN
  UPDATE public.payments_settings SET split_mode = 'subaccount', auto_refunds = TRUE, split_refunds_confirmed = FALSE, platform_fee_bps = 250, fee_bearer = 'subaccount' WHERE id;
  a := zz.att(zz.ord('N5'), 'dx-test-sx-0020');
  PERFORM zz.prep(a);
  PERFORM zz.apply('dx-test-sx-0020', 'success', 100000);
  rid := public._request_refund(a, 10000, 'amendment_reduction', 'sx:r1', NULL, NULL);
  PERFORM zz.check('5: with automatic refunds ON, a refund of a split payment still waits for approval until the behaviour is confirmed', (SELECT status = 'requested' FROM public.order_refunds WHERE id = rid), (SELECT status FROM public.order_refunds WHERE id = rid));
  UPDATE public.payments_settings SET split_refunds_confirmed = TRUE WHERE id;
  rid := public._request_refund(a, 10000, 'amendment_reduction', 'sx:r2', NULL, NULL);
  PERFORM zz.check('5: once a person has confirmed it, it is approved automatically as before', (SELECT status = 'approved' FROM public.order_refunds WHERE id = rid), (SELECT status FROM public.order_refunds WHERE id = rid));
  rid := public._request_refund(a, 10000, 'delivery_credit', 'sx:r3', NULL, NULL);
  PERFORM zz.check('5: a delivery credit always waits, as before', (SELECT status = 'requested' FROM public.order_refunds WHERE id = rid));
  UPDATE public.payments_settings SET split_refunds_confirmed = FALSE WHERE id;
  UPDATE public.payments_settings SET split_mode = 'none' WHERE id;
  a := zz.att(zz.ord('N7'), 'dx-test-sx-0021');
  PERFORM zz.prep(a);
  PERFORM zz.apply('dx-test-sx-0021', 'success', 100000);
  rid := public._request_refund(a, 10000, 'amendment_reduction', 'sx:r4', NULL, NULL);
  PERFORM zz.check('5: a payment that was not split is unaffected: approved automatically', (SELECT status = 'approved' FROM public.order_refunds WHERE id = rid), (SELECT status FROM public.order_refunds WHERE id = rid));
  PERFORM zz.check('5: an administrator can still approve the one that waited', zz.adm(format('SELECT public.admin_payment_overview()::text')) NOT LIKE 'ERR:%');
  UPDATE public.payments_settings SET auto_refunds = FALSE WHERE id;
END $$;

-- 6. Going live: the readiness check and the guard ----------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; j JSONB; alpha UUID := (SELECT alpha FROM zz.sx); admin UUID := (SELECT u_admin FROM zz.sx);
BEGIN
  PERFORM zz.reset_settings();
  UPDATE public.supplier_payout_accounts SET status = 'inactive' WHERE mode = 'test' AND status = 'active';
  r := zz.val_as((SELECT u_po FROM zz.sx), 'SELECT public.payments_readiness()::text');
  PERFORM zz.check('6: only an administrator sees the readiness check', r LIKE 'ERR: Only platform administrators%', r);
  j := zz.adm('SELECT public.payments_readiness()::text')::jsonb;
  PERFORM zz.check('6: with the defaults the platform is not ready for live money, and says which things are missing',
    NOT (j ->> 'ready_for_live')::boolean AND (SELECT count(*) FROM jsonb_array_elements(j -> 'items') i WHERE (i ->> 'blocking')::boolean AND NOT (i ->> 'ok')::boolean) = 5, j::text);
  PERFORM zz.check('6: each item states what it means in a sentence', (SELECT bool_and(length(i ->> 'detail') > 20) FROM jsonb_array_elements(j -> 'items') i));

  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: live payments cannot be switched on with the defaults, and the refusal names what is missing',
    r LIKE 'ERR: Live payments cannot be switched on yet. Not met:%' AND r LIKE '%split_on%' AND r LIKE '%cap_set%' AND r LIKE '%reconciler_alive%' AND r LIKE '%live_payout_account%' AND r LIKE '%split_refunds_confirmed%', r);
  PERFORM zz.check('6: nothing changed', (SELECT NOT online_enabled AND mode = 'test' FROM public.payments_settings WHERE id));
  UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test' WHERE id;
  PERFORM zz.check('6: test mode is never held back by any of this', (SELECT online_enabled FROM public.payments_settings WHERE id));
  UPDATE public.payments_settings SET online_enabled = FALSE WHERE id;

  UPDATE public.payments_settings SET split_mode = 'subaccount' WHERE id;
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: the split alone is not enough', r LIKE 'ERR: Live payments cannot be switched on yet.%' AND r NOT LIKE '%split_on%', r);
  UPDATE public.payments_settings SET max_order_ghs = 500, split_refunds_confirmed = TRUE WHERE id;
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: nor with the limit and the refund confirmation', r LIKE '%reconciler_alive%' AND r LIKE '%live_payout_account%' AND r NOT LIKE '%cap_set%', r);

  PERFORM zz.svc('SELECT public.record_reconciler_run(''frequent'')');
  PERFORM zz.check('6: the reconciler noting its run is recorded', (SELECT reconciler_frequent_at > now() - interval '1 minute' FROM public.payments_settings WHERE id));
  r := zz.svc('SELECT public.record_reconciler_run(''hourly'')');
  PERFORM zz.check('6: only the two known jobs', r = 'ERR: Unknown job.', r);
  r := zz.val_as((SELECT u_po FROM zz.sx), 'SELECT public.record_reconciler_run(''frequent'')');
  PERFORM zz.check('6: and only the server can note it', r LIKE 'ERR: permission denied%', r);
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: with the scheduler alive, only a live settlement account is still missing', r LIKE '%live_payout_account%' AND r NOT LIKE '%reconciler_alive%', r);

  -- a live account; an open critical alert blocks; a stale reconciler blocks
  INSERT INTO public.supplier_payout_accounts(wholesaler_id, mode, business_name, settlement_bank_code, account_last4, status, provider_subaccount_code)
  VALUES (alpha, 'live', 'Alpha Wholesale Ltd', 'GCB', '1234', 'active', 'ACCT_live0001');
  INSERT INTO public.payment_alerts(kind, severity, summary, dedupe_key, status) VALUES ('provider_unreachable', 'critical', 'test', 'sx:crit', 'open');
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: an open critical alert holds live payments back', r LIKE '%no_critical_alerts%' AND r NOT LIKE '%live_payout_account%', r);
  UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolution_note = 'ok' WHERE dedupe_key = 'sx:crit';
  UPDATE public.payments_settings SET reconciler_frequent_at = now() - interval '2 hours' WHERE id;
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: a scheduler that stopped two hours ago holds it back', r LIKE '%reconciler_alive%', r);
  PERFORM zz.svc('SELECT public.record_reconciler_run(''frequent'')');

  j := zz.adm('SELECT public.payments_readiness()::text')::jsonb;
  PERFORM zz.check('6: the readiness check now says ready', (j ->> 'ready_for_live')::boolean, j::text);
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE, mode = ''live'' WHERE id');
  PERFORM zz.check('6: and live payments can be switched on', r IS NULL AND (SELECT online_enabled AND mode = 'live' FROM public.payments_settings WHERE id), r);

  -- while live
  r := zz.try('UPDATE public.payments_settings SET split_mode = ''none'' WHERE id');
  PERFORM zz.check('6: while live, the split cannot be removed', r LIKE 'ERR: While live payments are on, the split and the payment limit cannot be removed.%', r);
  r := zz.try('UPDATE public.payments_settings SET max_order_ghs = NULL WHERE id');
  PERFORM zz.check('6: nor the limit', r LIKE 'ERR: While live payments are on%', r);
  UPDATE public.payments_settings SET max_order_ghs = 300 WHERE id;
  PERFORM zz.check('6: but the limit can be lowered', (SELECT max_order_ghs = 300 FROM public.payments_settings WHERE id));
  INSERT INTO public.payment_alerts(kind, severity, summary, dedupe_key, status) VALUES ('provider_unreachable', 'critical', 'test', 'sx:crit2', 'open');
  UPDATE public.payments_settings SET reconciler_frequent_at = now() - interval '3 hours' WHERE id;
  r := zz.svc('SELECT public.record_reconciler_run(''daily'')');
  PERFORM zz.check('6: the reconciler can still note its run while live with a critical alert open and a stale scheduler (the guard never stops it)', COALESCE(r, '') NOT LIKE 'ERR:%' AND (SELECT reconciler_daily_at > now() - interval '1 minute' FROM public.payments_settings WHERE id), r);
  UPDATE public.payments_settings SET auto_refunds = FALSE WHERE id;
  r := zz.try('UPDATE public.payments_settings SET online_enabled = FALSE WHERE id');
  PERFORM zz.check('6: the kill switch always works, whatever the state of the alerts and the scheduler', r IS NULL AND (SELECT NOT online_enabled FROM public.payments_settings WHERE id), r);
  r := zz.try('UPDATE public.payments_settings SET online_enabled = TRUE WHERE id');
  PERFORM zz.check('6: switching it back on is checked again (the scheduler is stale and an alert is open)', r LIKE 'ERR: Live payments cannot be switched on yet.%', r);
  UPDATE public.payments_settings SET mode = 'test' WHERE id;
  PERFORM zz.check('6: going back to test mode is never blocked', (SELECT mode = 'test' FROM public.payments_settings WHERE id));
  UPDATE public.payment_alerts SET status = 'resolved', resolved_at = now(), resolution_note = 'ok' WHERE dedupe_key = 'sx:crit2';
  DELETE FROM public.supplier_payout_accounts WHERE mode = 'live' AND FALSE;
END $$;

-- 7. The settlement report ----------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; j JSONB; a UUID; b UUID; rid UUID; alpha UUID := (SELECT alpha FROM zz.sx); row JSONB;
BEGIN
  PERFORM zz.reset_settings();
  UPDATE public.order_payment_attempts SET paid_at = now() - interval '5 days' WHERE status = 'succeeded';
  UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', split_mode = 'subaccount', platform_fee_bps = 250 WHERE id;
  UPDATE public.supplier_payout_accounts SET status = 'active' WHERE mode = 'test' AND wholesaler_id = alpha AND status = 'inactive';
  a := zz.att(zz.ord('R1'), 'dx-test-sx-0030');
  PERFORM zz.prep(a);
  PERFORM zz.apply('dx-test-sx-0030', 'success', 100000);
  UPDATE public.payments_settings SET split_mode = 'none' WHERE id;
  b := zz.att(zz.ord('R2'), 'dx-test-sx-0031');
  PERFORM zz.prep(b);
  PERFORM zz.apply('dx-test-sx-0031', 'success', 100000);
  rid := public._request_refund(a, 20000, 'amendment_reduction', 'sx:rep1', NULL, NULL);
  UPDATE public.order_refunds SET status = 'approved', approved_at = now() WHERE id = rid;
  UPDATE public.order_refunds SET status = 'submitting' WHERE id = rid;
  UPDATE public.order_refunds SET status = 'processing' WHERE id = rid;
  UPDATE public.order_refunds SET status = 'succeeded', completed_at = now() WHERE id = rid;

  r := zz.val_as((SELECT u_po FROM zz.sx), format('SELECT public.admin_settlement_report(now() - interval ''1 day'', now() + interval ''1 day'')::text'));
  PERFORM zz.check('7: only an administrator reads the settlement report', r LIKE 'ERR: Only platform administrators%', r);
  r := zz.adm('SELECT public.admin_settlement_report(now() + interval ''1 day'', now())::text');
  PERFORM zz.check('7: a period must end after it starts', r LIKE 'ERR: Choose a period%', r);
  j := zz.adm('SELECT public.admin_settlement_report(now() - interval ''1 day'', now() + interval ''1 day'', ''test'')::text')::jsonb;
  SELECT x INTO row FROM jsonb_array_elements(j -> 'suppliers') x WHERE x ->> 'name' = 'Alpha Wholesale';
  PERFORM zz.check('7: per supplier: two payments received (GHS 2000.00)', (row ->> 'payments')::int = 2 AND (row ->> 'received_ghs')::numeric = 2000, row::text);
  PERFORM zz.check('7: the platform''s share is GHS 25.00 (only the split payment)', (row ->> 'platform_share_ghs')::numeric = 25, row::text);
  PERFORM zz.check('7: money that was NOT split is called out (GHS 1000.00 here)', (row ->> 'not_split_ghs')::numeric = 1000, row::text);
  PERFORM zz.check('7: refunds that succeeded are taken off (GHS 200.00)', (row ->> 'refunded_ghs')::numeric = 200, row::text);
  PERFORM zz.check('7: what should settle to the supplier is received - platform share - refunded = GHS 1775.00', (row ->> 'to_settle_ghs')::numeric = 1775, row::text);
  j := zz.adm('SELECT public.admin_settlement_report(now() - interval ''1 day'', now() + interval ''1 day'', ''live'')::text')::jsonb;
  PERFORM zz.check('7: the other mode is separate', jsonb_array_length(j -> 'suppliers') = 0, j::text);
  j := zz.adm('SELECT public.admin_settlement_report(now() - interval ''3 days'', now() - interval ''2 days'')::text')::jsonb;
  PERFORM zz.check('7: a period with no payments is empty', jsonb_array_length(j -> 'suppliers') = 0);
END $$;

-- 8. Who can call what ----------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r TEXT; u RECORD; fn TEXT;
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a pharmacy owner', (SELECT u_po FROM zz.sx)), ('a wholesaler owner', (SELECT u_wo FROM zz.sx)), ('an admin', (SELECT u_admin FROM zz.sx))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['prepare_attempt_for_provider(gen_random_uuid())', 'begin_payout_account(gen_random_uuid(), gen_random_uuid(), ''test'', ''x'', ''y'', ''1234'')',
      'finish_payout_account(gen_random_uuid(), ''ACCT_x'', NULL)', 'admin_set_payout_account_status(gen_random_uuid(), gen_random_uuid(), TRUE)', 'record_reconciler_run(''frequent'')',
      'payout_account_ready(gen_random_uuid(), ''paystack'', ''test'')'] LOOP
      r := zz.val_as(u.uid, 'SELECT public.' || fn || '::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
  r := zz.val_as((SELECT u_po FROM zz.sx), 'SELECT split_mode FROM public.payments_settings');
  PERFORM zz.check('the platform settings are unreadable to a pharmacy', r LIKE 'ERR:%' OR r IS NULL, r);
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
