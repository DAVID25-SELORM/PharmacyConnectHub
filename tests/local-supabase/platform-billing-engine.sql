-- Platform billing, Phase 2: the engine. Free orders (launch and monthly, in the agreed order, never two for one order), fee arithmetic with per-order limits and rounding, the monthly cap,
-- what is and is not billable, idempotency, adjustments after delivery, shadow versus real, plan versions never rewriting history, trial and cancellation, a failure never blocking a delivery,
-- reconciliation, and who can call what. Run after setup.sql + migrations (through 20261202110000_platform_billing_engine.sql). The Africa/Accra timezone is UTC+0, so every date below is UTC.
GRANT USAGE ON SCHEMA zz TO authenticated, anon;
GRANT SELECT ON zz.b, zz.u TO authenticated, anon;

CREATE FUNCTION zz.val_as(p_uid UUID, p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT; prev_claims TEXT := current_setting('request.jwt.claims', true); prev_sub TEXT := current_setting('request.jwt.claim.sub', true);
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql INTO r; EXCEPTION WHEN OTHERS THEN r := 'ERR: ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', COALESCE(prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(prev_sub, ''), true);
  RETURN r;
END $$;
CREATE FUNCTION zz.anon(p_sql TEXT) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  EXECUTE 'SET LOCAL ROLE anon';
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

CREATE TABLE zz.bx AS SELECT (SELECT id FROM zz.b WHERE name='Good Pharmacy') good, (SELECT id FROM zz.u WHERE k='admin') u_admin;
CREATE SEQUENCE zz.ordn START 1;
CREATE FUNCTION zz.adm(p_sql TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT zz.val_as((SELECT u_admin FROM zz.bx), p_sql) $$;
-- A wholesaler with its own owner (so licence and owner keys differ), approved.
CREATE FUNCTION zz.mkws(p_name TEXT) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_u UUID := gen_random_uuid(); v_b UUID;
BEGIN
  INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', replace(lower(p_name), ' ', '') || '@zz.test', '{}', '{"provider":"email"}', now(), now());
  INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', p_name, 'LIC-' || p_name, 'approved') RETURNING id INTO v_b;
  RETURN v_b;
END $$;
CREATE FUNCTION zz.owner(p_b UUID) RETURNS UUID LANGUAGE sql AS $$ SELECT owner_id FROM public.businesses WHERE id = p_b $$;
CREATE FUNCTION zz.mkplan(p_code TEXT, p_params JSONB) RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE pid UUID;
BEGIN
  pid := zz.adm(format('SELECT public.admin_billing_create_plan(%L, ''wholesaler'', %L, NULL, ''standard'', ''Plan for tests'')::text', p_code, 'Plan ' || p_code))::uuid;
  PERFORM zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, %L::jsonb, ''Terms for tests'')::text', pid, p_params::text));
  PERFORM zz.adm(format('SELECT public.admin_billing_set_plan_availability(%L, TRUE, FALSE, ''Switch on for tests'')::text', pid));
  RETURN p_code;
END $$;
CREATE FUNCTION zz.sub(p_b UUID, p_plan TEXT, p_starts TIMESTAMPTZ DEFAULT '2026-01-01 00:00+00', p_mode TEXT DEFAULT NULL) RETURNS TEXT LANGUAGE sql AS $$
  SELECT zz.adm(format('SELECT public.admin_billing_start_subscription(%L, %L, %L, %L, ''Start for tests'')::text', p_b, p_plan, p_starts, p_mode)) $$;
-- An order (pending), worth p_goods plus a delivery fee, to be delivered at p_at.
CREATE FUNCTION zz.mkorder(p_ws UUID, p_goods NUMERIC, p_fee NUMERIC, p_at TIMESTAMPTZ, p_eff NUMERIC DEFAULT NULL, p_ph UUID DEFAULT NULL) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.orders(order_number, pharmacy_id, wholesaler_id, total_ghs, delivery_fee_ghs, delivered_at) VALUES ('ORD-B' || nextval('zz.ordn'), COALESCE(p_ph, (SELECT good FROM zz.bx)), p_ws, p_goods + p_fee, p_fee, p_at) RETURNING id INTO v_id;
  IF p_eff IS NOT NULL THEN PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = p_eff WHERE id = v_id; END IF;
  RETURN v_id;
END $$;
CREATE FUNCTION zz.advance(p_order UUID, p_to TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE s TEXT;
BEGIN
  FOREACH s IN ARRAY (CASE p_to WHEN 'accepted' THEN ARRAY['accepted'] WHEN 'packed' THEN ARRAY['accepted', 'packed'] WHEN 'dispatched' THEN ARRAY['accepted', 'packed', 'dispatched']
                                WHEN 'cancelled' THEN ARRAY['cancelled'] ELSE ARRAY['accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] END) LOOP
    -- only the steps still ahead of where the order already is
    IF array_position(ARRAY['pending', 'accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'], (SELECT status::text FROM public.orders WHERE id = p_order))
       < array_position(ARRAY['pending', 'accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'], s) OR s = 'cancelled' THEN
      EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', s, p_order);
    END IF;
  END LOOP;
END $$;
CREATE FUNCTION zz.deliver(p_order UUID) RETURNS VOID LANGUAGE sql AS $$ SELECT zz.advance(p_order, 'delivered') $$;
CREATE FUNCTION zz.go(p_ws UUID, p_goods NUMERIC, p_fee NUMERIC, p_at TIMESTAMPTZ) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v UUID := zz.mkorder(p_ws, p_goods, p_fee, p_at);
BEGIN PERFORM zz.deliver(v); RETURN v; END $$;
-- How an order was billed: outcome / free source and number / charged.
CREATE FUNCTION zz.a(p_order UUID, p_shadow BOOLEAN DEFAULT FALSE) RETURNS TEXT LANGUAGE sql AS $$
  SELECT outcome || '/' || COALESCE(free_source || free_seq, '-') || '/' || charged_amount FROM public.order_billing_assessments WHERE order_id = p_order AND kind = 'primary' AND shadow = p_shadow $$;
CREATE FUNCTION zz.per(p_b UUID, p_start TIMESTAMPTZ, p_shadow BOOLEAN DEFAULT FALSE) RETURNS public.billing_periods LANGUAGE sql AS $$
  SELECT * FROM public.billing_periods WHERE business_id = p_b AND period_start = p_start AND shadow = p_shadow $$;
CREATE FUNCTION zz.nass(p_b UUID, p_shadow BOOLEAN DEFAULT FALSE) RETURNS INT LANGUAGE sql AS $$ SELECT count(*)::int FROM public.order_billing_assessments WHERE business_id = p_b AND shadow = p_shadow $$;

-- A. The fee arithmetic, in one place -------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
  SELECT * INTO r FROM public.billing_compute_fee(5000, 0.75, NULL, NULL);
  PERFORM zz.check('A: GHS 5,000 at 0.75% is GHS 37.50', r.calculated_fee = 37.50 AND r.fee_after_limits = 37.50, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(5000, 0.75, 2, 200);
  PERFORM zz.check('A: limits that do not bite change nothing', r.fee_after_limits = 37.50);
  SELECT * INTO r FROM public.billing_compute_fee(100, 0.75, 2, NULL);
  PERFORM zz.check('A: the per-order MINIMUM lifts a tiny fee (0.75 becomes 2.00); the percentage-only figure is still shown', r.calculated_fee = 0.75 AND r.fee_after_limits = 2.00, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(100000, 0.75, 2, 200);
  PERFORM zz.check('A: the per-order MAXIMUM caps a big fee (750.00 becomes 200.00)', r.calculated_fee = 750.00 AND r.fee_after_limits = 200.00, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(0.67, 0.75, NULL, NULL);
  PERFORM zz.check('A: rounding is half-up to 2 decimals once: 0.005025 becomes 0.01', r.calculated_fee = 0.01 AND r.fee_after_limits = 0.01, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(1, 0.5, NULL, NULL);
  PERFORM zz.check('A: exactly half a pesewa rounds UP (0.005 becomes 0.01)', r.fee_after_limits = 0.01, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(0.66, 0.75, NULL, NULL);
  PERFORM zz.check('A: below half a pesewa rounds down (0.00495 becomes 0.00)', r.fee_after_limits = 0.00, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(5000, 0, 2, 200);
  PERFORM zz.check('A: a zero percentage has no fee, whatever the minimum (a retailer plan is never charged a minimum)', r.fee_after_limits = 0, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(0, 0.75, 2, 200);
  PERFORM zz.check('A: an order with no value has no fee, whatever the minimum', r.fee_after_limits = 0, r::text);
  SELECT * INTO r FROM public.billing_compute_fee(5000, 100, NULL, NULL);
  PERFORM zz.check('A: 100% is allowed', r.fee_after_limits = 5000);
  SELECT * INTO r FROM public.billing_compute_fee(1234.56, 0.6, NULL, 5);
  PERFORM zz.check('A: a maximum alone (7.4074 capped at 5.00)', r.calculated_fee = 7.41 AND r.fee_after_limits = 5.00, r::text);
  PERFORM zz.check('A: negative inputs are refused', zz.try('SELECT * FROM public.billing_compute_fee(-1, 1, NULL, NULL)') LIKE 'ERR:%' AND zz.try('SELECT * FROM public.billing_compute_fee(1, -1, NULL, NULL)') LIKE 'ERR:%');
END $$;

-- Setup: plans and wholesalers -----------------------------------------------------------------------------------------------------------------------------------------------------------
UPDATE public.billing_settings SET mode = 'active';
SELECT zz.mkplan('eng_launch', '{"subscription_amount":100,"free_trial_days":30,"onboarding_free_orders":5,"monthly_free_orders":2,"transaction_fee_percentage":0.75,"transaction_fee_cycle_cap":1500}'::jsonb);
CREATE TABLE zz.w AS SELECT zz.mkws('Engine W1') w1;
SELECT zz.sub((SELECT w1 FROM zz.w), 'eng_launch');

-- B. The free-order sequence and the first chargeable orders (the agreed example) ---------------------------------------------------------------------------------------------------------
DO $$
DECLARE w UUID := (SELECT w1 FROM zz.w); o UUID[] := ARRAY[]::UUID[]; i INT; x UUID; p public.billing_periods; g UUID; outs TEXT := '';
BEGIN
  PERFORM zz.check('B: Alpha-style subscription: trialing from 1 Jan for 30 days, with a launch grant of 5', (SELECT status = 'trialing' AND trial_end = '2026-01-31 00:00+00' FROM public.billing_subscriptions WHERE business_id = w)
    AND (SELECT quantity FROM public.billing_allowance_grants WHERE business_id = w) = 5);
  SELECT id INTO g FROM public.billing_allowance_grants WHERE business_id = w;
  FOR i IN 1..10 LOOP
    x := zz.go(w, 1000, 50, '2026-03-10 10:00+00'::timestamptz + make_interval(mins => i));
    o := o || x;
    outs := outs || zz.a(x) || ' ';
  END LOOP;
  PERFORM zz.check('B: orders 1 to 5 are LAUNCH free (numbers 1 to 5)', zz.a(o[1]) = 'free_onboarding/onboarding1/0.00' AND zz.a(o[2]) = 'free_onboarding/onboarding2/0.00' AND zz.a(o[3]) = 'free_onboarding/onboarding3/0.00'
    AND zz.a(o[4]) = 'free_onboarding/onboarding4/0.00' AND zz.a(o[5]) = 'free_onboarding/onboarding5/0.00', outs);
  PERFORM zz.check('B: orders 6 and 7 are MONTHLY free (numbers 1 and 2)', zz.a(o[6]) = 'free_monthly/monthly1/0.00' AND zz.a(o[7]) = 'free_monthly/monthly2/0.00', outs);
  PERFORM zz.check('B: orders 8 to 10 are charged 0.75% of GHS 1,000 = GHS 7.50 (the delivery fee is NOT part of the amount)', zz.a(o[8]) = 'chargeable/-/7.50' AND zz.a(o[9]) = 'chargeable/-/7.50' AND zz.a(o[10]) = 'chargeable/-/7.50', outs);
  PERFORM zz.check('B: each free launch order records the grant and its number', (SELECT count(*) FROM public.order_billing_assessments WHERE grant_id = g AND free_source = 'onboarding' AND NOT shadow) = 5
    AND (SELECT array_agg(free_seq ORDER BY free_seq) FROM public.order_billing_assessments WHERE grant_id = g AND free_source = 'onboarding') = ARRAY[1, 2, 3, 4, 5]);
  PERFORM zz.check('B: no order consumed two allowances: every assessment has exactly one outcome and one source', (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w AND ((free_source IS NOT NULL) <> (outcome IN ('free_onboarding', 'free_monthly')))) = 0
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w) = 10);
  p := zz.per(w, '2026-03-01 00:00+00');
  PERFORM zz.check('B: March counters: 10 eligible orders, 5 launch free, 2 monthly free, 3 charged, GHS 10,000 billable', p.eligible_orders = 10 AND p.free_onboarding_orders = 5 AND p.free_monthly_orders = 2 AND p.chargeable_orders = 3 AND p.billable_gmv = 10000, p::text);
  PERFORM zz.check('B: March fees GHS 22.50, before the cap GHS 22.50, subscription GHS 100.00 (the trial ended on 31 Jan), amount due GHS 122.50', p.transaction_fees_amount = 22.50 AND p.fees_before_cap = 22.50 AND p.subscription_amount = 100 AND p.amount_due = 122.50 AND p.outstanding_amount = 122.50, p::text);
  PERFORM zz.check('B: the ledger holds 5 + 2 free-order entries and 3 fee entries of GHS 7.50 on GHS 1,000 at 0.75%', (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = w AND entry_type = 'free_order') = 7
    AND (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = w AND entry_type = 'transaction_fee' AND charged_amount = 7.50 AND gross_amount = 1000 AND percentage = 0.75) = 3);
  PERFORM zz.check('B: each assessment keeps a snapshot of the terms used (0.75%, cap 1500, plan version 1, the rule version)', (SELECT (terms_snapshot ->> 'transaction_fee_percentage')::numeric = 0.75 AND (terms_snapshot ->> 'transaction_fee_cycle_cap')::numeric = 1500
    AND rule_version = 'billing-engine-1' AND plan_version_id IS NOT NULL AND subscription_terms_id IS NOT NULL FROM public.order_billing_assessments WHERE order_id = o[10]));
  PERFORM zz.check('B: a real assessment is audited against the business (not as the person who delivered)', EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order billing assessed' AND business_id = w AND performed_by IS NULL));

  -- next month: the monthly allowance resets, the launch allowance does NOT
  FOR i IN 1..3 LOOP x := zz.go(w, 1000, 50, '2026-04-10 10:00+00'::timestamptz + make_interval(mins => i)); o := o || x; END LOOP;
  PERFORM zz.check('B: in April the first 2 orders are MONTHLY free again (numbers 1 and 2) and the third is charged', zz.a(o[11]) = 'free_monthly/monthly1/0.00' AND zz.a(o[12]) = 'free_monthly/monthly2/0.00' AND zz.a(o[13]) = 'chargeable/-/7.50', zz.a(o[11]) || ' ' || zz.a(o[12]) || ' ' || zz.a(o[13]));
  PERFORM zz.check('B: the launch allowance did not come back (still 5 used of 5)', (SELECT count(*) FROM public.order_billing_assessments WHERE grant_id = g AND free_source = 'onboarding') = 5);
  p := zz.per(w, '2026-04-01 00:00+00');
  PERFORM zz.check('B: April has its own counters and its own subscription charge', p.free_monthly_orders = 2 AND p.chargeable_orders = 1 AND p.free_onboarding_orders = 0 AND p.subscription_amount = 100 AND p.transaction_fees_amount = 7.50, p::text);
END $$;

-- C. No orders, a quiet business, a low-volume business ------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_quiet', '{"subscription_amount":100,"free_trial_days":30,"monthly_free_orders":2,"transaction_fee_percentage":0.75}'::jsonb);
CREATE TABLE zz.w2 AS SELECT zz.mkws('Engine W2') w2, zz.mkws('Engine W3') w3;
SELECT zz.sub((SELECT w2 FROM zz.w2), 'eng_quiet');
SELECT zz.sub((SELECT w3 FROM zz.w2), 'eng_quiet');
DO $$
DECLARE w UUID := (SELECT w2 FROM zz.w2); w3 UUID := (SELECT w3 FROM zz.w2); n INT; x UUID; r JSONB; p public.billing_periods;
BEGIN
  n := public.billing_open_periods('2026-04-15 12:00+00');
  PERFORM zz.check('C: opening periods up to mid-April creates January to April for each subscription with no orders at all (and nothing for the platform''s other, unrelated state)', n >= 8, n::text);
  PERFORM zz.check('C: a business with no orders has NO transaction fees: nothing assessed, no fee entries', zz.nass(w) = 0 AND (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = w AND entry_type = 'transaction_fee') = 0);
  PERFORM zz.check('C: its January subscription charge is WAIVED (the period starts inside the 30-day trial) and recorded as a zero charge with the reason',
    (SELECT subscription_amount = 0 FROM public.billing_periods WHERE business_id = w AND period_start = '2026-01-01+00')
    AND EXISTS (SELECT 1 FROM public.billing_ledger_entries e JOIN public.billing_periods bp ON bp.id = e.period_id WHERE bp.business_id = w AND bp.period_start = '2026-01-01+00' AND e.entry_type = 'subscription_charge' AND e.charged_amount = 0 AND e.reason = 'Free trial'));
  PERFORM zz.check('C: after the trial the subscription is charged each period (GHS 100 for February, March and April)', (SELECT array_agg(subscription_amount ORDER BY period_start) FROM public.billing_periods WHERE business_id = w) = ARRAY[0, 100, 100, 100]::numeric[]);
  PERFORM zz.check('C: running it again opens nothing new and changes nothing (idempotent)', public.billing_open_periods('2026-04-15 12:00+00') = 0 AND (SELECT count(*) FROM public.billing_periods WHERE business_id = w) = 4);
  PERFORM zz.check('C: periods are contiguous: each starts where the last ended', (SELECT bool_and(g.period_start = g.prev_end) FROM (SELECT period_start, lag(period_end) OVER (ORDER BY period_start) prev_end FROM public.billing_periods WHERE business_id = w) g WHERE g.prev_end IS NOT NULL));
  -- low volume: two orders a month, two free a month: no transaction fee at all, but the subscription is still charged
  FOR n IN 1..2 LOOP x := zz.go(w3, 800, 20, '2026-03-12 09:00+00'::timestamptz + make_interval(days => n)); END LOOP;
  FOR n IN 1..2 LOOP x := zz.go(w3, 800, 20, '2026-04-12 09:00+00'::timestamptz + make_interval(days => n)); END LOOP;
  PERFORM zz.check('C: a wholesaler with only 2 orders a month and 2 free a month pays no transaction fee in either month', (SELECT coalesce(sum(charged_amount), 0) FROM public.order_billing_assessments WHERE business_id = w3) = 0
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w3 AND outcome = 'free_monthly') = 4);
  p := zz.per(w3, '2026-04-01 00:00+00');
  PERFORM zz.check('C: ... but it still pays its subscription (GHS 100 for April, total due GHS 100)', p.subscription_amount = 100 AND p.transaction_fees_amount = 0 AND p.amount_due = 100, p::text);
END $$;

-- D. Per-order limits and the monthly cap --------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_limits', '{"transaction_fee_percentage":0.75,"transaction_fee_min":2,"transaction_fee_max":200}'::jsonb);
SELECT zz.mkplan('eng_cap100', '{"transaction_fee_percentage":1,"transaction_fee_cycle_cap":100}'::jsonb);
SELECT zz.mkplan('eng_cap1500', '{"subscription_amount":250,"transaction_fee_percentage":0.75,"transaction_fee_cycle_cap":1500}'::jsonb);
CREATE TABLE zz.w3 AS SELECT zz.mkws('Engine W4') w4, zz.mkws('Engine W5') w5, zz.mkws('Engine W6') w6;
SELECT zz.sub((SELECT w4 FROM zz.w3), 'eng_limits'), zz.sub((SELECT w5 FROM zz.w3), 'eng_cap100'), zz.sub((SELECT w6 FROM zz.w3), 'eng_cap1500');
DO $$
DECLARE w4 UUID := (SELECT w4 FROM zz.w3); w5 UUID := (SELECT w5 FROM zz.w3); w6 UUID := (SELECT w6 FROM zz.w3); x UUID; i INT; p public.billing_periods; a RECORD; o UUID[] := ARRAY[]::UUID[];
BEGIN
  x := zz.go(w4, 100, 0, '2026-03-05 10:00+00');
  PERFORM zz.check('D: a GHS 100 order at 0.75% with a GHS 2 minimum is charged GHS 2.00 (the minimum)', zz.a(x) = 'chargeable/-/2.00', zz.a(x));
  x := zz.go(w4, 100000, 0, '2026-03-05 11:00+00');
  PERFORM zz.check('D: a GHS 100,000 order is charged GHS 200.00 (the maximum), though 0.75% would be 750.00', zz.a(x) = 'chargeable/-/200.00', zz.a(x));
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = x;
  PERFORM zz.check('D: the assessment shows the percentage figure (750.00), the figure after limits (200.00) and nothing lost to a cap', a.calculated_fee = 750 AND a.fee_after_limits = 200 AND a.cap_adjustment = 0, a::text);
  x := zz.go(w4, 5000, 0, '2026-03-05 12:00+00');
  PERFORM zz.check('D: an ordinary order inside the limits is just 0.75% (37.50)', zz.a(x) = 'chargeable/-/37.50');

  -- cap of GHS 100 at 1%: orders of GHS 4,000 are GHS 40.00 each
  FOR i IN 1..5 LOOP o := o || zz.go(w5, 4000, 0, '2026-03-05 10:00+00'::timestamptz + make_interval(mins => i)); END LOOP;
  PERFORM zz.check('D: orders 1 and 2 are charged in full (40.00 and 40.00): below the cap', zz.a(o[1]) = 'chargeable/-/40.00' AND zz.a(o[2]) = 'chargeable/-/40.00');
  PERFORM zz.check('D: order 3 would take the total to 120, so only the REMAINING GHS 20.00 is charged', zz.a(o[3]) = 'chargeable/-/20.00', zz.a(o[3]));
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = o[3];
  PERFORM zz.check('D: it records the fee before the cap (40.00), what was charged (20.00) and the cap adjustment (20.00)', a.fee_after_limits = 40 AND a.charged_amount = 20 AND a.cap_adjustment = 20, a::text);
  PERFORM zz.check('D: a ledger entry explains the cap adjustment', EXISTS (SELECT 1 FROM public.billing_ledger_entries WHERE order_id = o[3] AND entry_type = 'fee_cap_adjustment' AND calculated_fee = 20 AND charged_amount = 0 AND reason LIKE 'Monthly fee cap reached%'));
  PERFORM zz.check('D: orders 4 and 5, after the cap, are charged NOTHING but still recorded with their full calculated fee', zz.a(o[4]) = 'chargeable/-/0.00' AND zz.a(o[5]) = 'chargeable/-/0.00'
    AND (SELECT fee_after_limits = 40 AND cap_adjustment = 40 FROM public.order_billing_assessments WHERE order_id = o[5]));
  p := zz.per(w5, '2026-03-01 00:00+00');
  PERFORM zz.check('D: the month''s fees are exactly the cap (100.00), with 200.00 calculated before it', p.transaction_fees_amount = 100 AND p.fees_before_cap = 200 AND p.chargeable_orders = 5, p::text);
  -- an order that lands exactly on the cap
  x := zz.go(w5, 4000, 0, '2026-04-05 10:00+00'); x := zz.go(w5, 4000, 0, '2026-04-05 11:00+00'); x := zz.go(w5, 2000, 0, '2026-04-05 12:00+00');
  PERFORM zz.check('D: an order that lands EXACTLY on the cap (40 + 40 + 20 = 100) is charged in full, with no adjustment', zz.a(x) = 'chargeable/-/20.00' AND (SELECT cap_adjustment = 0 FROM public.order_billing_assessments WHERE order_id = x));
  PERFORM zz.check('D: the cap resets in the next period', zz.a(zz.go(w5, 4000, 0, '2026-05-05 10:00+00')) = 'chargeable/-/40.00');

  -- the high-volume example: 100 orders of GHS 5,000 at 0.75% = 37.50 each, cap 1,500: the 40th order reaches the cap, the other 60 pay nothing
  o := ARRAY[]::UUID[];
  FOR i IN 1..100 LOOP o := o || zz.go(w6, 5000, 0, '2026-03-02 00:00+00'::timestamptz + make_interval(mins => i)); END LOOP;
  p := zz.per(w6, '2026-03-01 00:00+00');
  PERFORM zz.check('D: 100 orders of GHS 5,000 (GHS 500,000) at 0.75% would be GHS 3,750; the month''s fees stop at the cap of GHS 1,500.00', p.transaction_fees_amount = 1500 AND p.fees_before_cap = 3750 AND p.billable_gmv = 500000 AND p.chargeable_orders = 100, p::text);
  PERFORM zz.check('D: orders 1 to 40 are charged 37.50 each; orders 41 to 100 are charged nothing', (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w6 AND charged_amount = 37.50) = 40 AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w6 AND charged_amount = 0) = 60);
  PERFORM zz.check('D: the month''s bill is the subscription (250) plus the capped fees (1,500) = 1,750', p.amount_due = 1750, p::text);
END $$;

-- E. What is and is not billable -------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_plain', '{"transaction_fee_percentage":1}'::jsonb);
SELECT zz.mkplan('eng_minorder', '{"onboarding_free_orders":2,"transaction_fee_percentage":1,"min_billable_order_amount":100}'::jsonb);
CREATE TABLE zz.w4 AS SELECT zz.mkws('Engine W7') w7, zz.mkws('Engine W8') w8, zz.mkws('Engine W9') w9, zz.mkws('Engine NoSub') nosub, zz.mkws('Engine W10') w10;
SELECT zz.sub((SELECT w7 FROM zz.w4), 'eng_plain'), zz.sub((SELECT w8 FROM zz.w4), 'eng_plain'), zz.sub((SELECT w9 FROM zz.w4), 'eng_minorder'), zz.sub((SELECT w10 FROM zz.w4), 'eng_plain');
DO $$
DECLARE w7 UUID := (SELECT w7 FROM zz.w4); w8 UUID := (SELECT w8 FROM zz.w4); w9 UUID := (SELECT w9 FROM zz.w4); ns UUID := (SELECT nosub FROM zz.w4); w10 UUID := (SELECT w10 FROM zz.w4);
        x UUID; a UUID; b UUID; c UUID; d UUID; same_ph UUID; r JSONB;
BEGIN
  a := zz.mkorder(w7, 1000, 0, '2026-03-05 10:00+00');
  PERFORM zz.check('E: a PENDING order is not billed', zz.nass(w7) = 0);
  PERFORM zz.advance(a, 'accepted'); PERFORM zz.check('E: nor an ACCEPTED one', zz.nass(w7) = 0);
  PERFORM zz.advance(a, 'dispatched'); PERFORM zz.check('E: nor one that has been packed and DISPATCHED', zz.nass(w7) = 0);
  b := zz.mkorder(w7, 1000, 0, '2026-03-05 10:00+00');
  ALTER TABLE public.orders DISABLE TRIGGER USER; UPDATE public.orders SET status = 'cancelled' WHERE id = b; ALTER TABLE public.orders ENABLE TRIGGER USER;
  PERFORM zz.check('E: nor a CANCELLED order', zz.nass(w7) = 0);
  PERFORM zz.deliver(a);
  PERFORM zz.check('E: a DELIVERED order is billed (1% of 1,000 = 10.00)', zz.a(a) = 'chargeable/-/10.00' AND zz.nass(w7) = 1, zz.a(a));
  PERFORM zz.check('E: no one can deliver a cancelled order into billing: it stays unbilled', zz.try(format('UPDATE public.orders SET status = ''delivered'' WHERE id = %L', b)) LIKE 'ERR:%' AND zz.nass(w7) = 1);

  -- before billing started
  c := zz.go(w8, 1000, 0, '2025-12-31 23:59:59+00');
  PERFORM zz.check('E: an order delivered BEFORE the business''s billing start date is never billed', zz.nass(w8) = 0);
  c := zz.go(w8, 1000, 0, '2026-01-01 00:00:00+00');
  PERFORM zz.check('E: an order delivered exactly AT the start is billed', zz.nass(w8) = 1);
  -- no subscription, and a pharmacy that has one
  x := zz.go(ns, 1000, 0, '2026-03-05 10:00+00');
  PERFORM zz.check('E: a wholesaler with no subscription is not billed (and nothing breaks)', zz.nass(ns) = 0 AND (SELECT status FROM public.orders WHERE id = x) = 'delivered');
  -- billing disabled, then catch-up
  UPDATE public.billing_settings SET mode = 'disabled';
  x := zz.go(w8, 1000, 0, '2026-03-06 10:00+00');
  PERFORM zz.check('E: with billing DISABLED a delivery writes nothing', zz.nass(w8) = 1 AND zz.a(x) IS NULL);
  UPDATE public.billing_settings SET mode = 'active';
  PERFORM zz.check('E: the reconciliation sees that order as delivered but not assessed', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'delivered_order_not_assessed') >= 1);
  r := public.billing_catch_up(50);
  PERFORM zz.check('E: catch-up assesses it (and again does nothing)', zz.a(x) = 'chargeable/-/10.00' AND (public.billing_catch_up(50) ->> 'done') = '0', r::text || ' ' || coalesce(zz.a(x), 'none'));

  -- same owner on both sides
  INSERT INTO public.businesses(owner_id, type, name, verification_status) VALUES (zz.owner(w10), 'pharmacy', 'Engine Own Pharmacy', 'approved') RETURNING id INTO same_ph;
  x := zz.mkorder(w10, 1000, 0, '2026-03-07 10:00+00', NULL, same_ph); PERFORM zz.deliver(x);
  PERFORM zz.check('E: an order between two businesses with the SAME OWNER is excluded (no fee, no free order used)', zz.a(x) = 'excluded/-/0.00' AND (SELECT terms_snapshot -> 'decision' ->> 'reason' = 'The buyer and the seller have the same owner' FROM public.order_billing_assessments WHERE order_id = x));
  -- zero value
  x := zz.go(w10, 0, 50, '2026-03-08 10:00+00');
  PERFORM zz.check('E: an order with no billable value (only a delivery fee) is excluded', zz.a(x) = 'excluded/-/0.00', zz.a(x));
  -- exempt
  UPDATE public.billing_subscriptions SET exempt_from_transaction_fees = TRUE, exempt_reason = 'Strategic partner' WHERE business_id = w10;
  x := zz.go(w10, 1000, 0, '2026-03-09 10:00+00');
  PERFORM zz.check('E: an exempt business is not charged (outcome exempt) and no free order is used', zz.a(x) = 'exempt/-/0.00');
  UPDATE public.billing_subscriptions SET exempt_from_transaction_fees = FALSE, exempt_reason = NULL, billing_paused = TRUE, paused_at = now(), paused_reason = 'Paused for a test' WHERE business_id = w10;
  x := zz.go(w10, 1000, 0, '2026-03-10 10:00+00');
  PERFORM zz.check('E: a PAUSED business''s deliveries are recorded as excluded (so they are never billed later)', zz.a(x) = 'excluded/-/0.00' AND (SELECT terms_snapshot -> 'decision' ->> 'reason' = 'Billing is paused' FROM public.order_billing_assessments WHERE order_id = x));
  UPDATE public.billing_subscriptions SET billing_paused = FALSE, paused_reason = NULL WHERE business_id = w10;
  PERFORM zz.check('E: catch-up does not bill the order delivered while paused (it already has its excluded assessment)', (public.billing_catch_up(50) ->> 'done') = '0');

  -- minimum billable order amount
  a := zz.go(w9, 50, 0, '2026-03-05 10:00+00');
  PERFORM zz.check('E: an order below the plan''s minimum billable amount is not fee-eligible and does NOT use a free order', zz.a(a) = 'below_minimum/-/0.00');
  b := zz.go(w9, 500, 0, '2026-03-05 11:00+00'); c := zz.go(w9, 500, 0, '2026-03-05 12:00+00'); d := zz.go(w9, 500, 0, '2026-03-05 13:00+00');
  PERFORM zz.check('E: the next orders still get the launch free orders (1 and 2) and then pay', zz.a(b) = 'free_onboarding/onboarding1/0.00' AND zz.a(c) = 'free_onboarding/onboarding2/0.00' AND zz.a(d) = 'chargeable/-/5.00', zz.a(b) || ' ' || zz.a(c) || ' ' || zz.a(d));
  PERFORM zz.check('E: a below-minimum order is not counted as eligible in the period', (SELECT eligible_orders = 3 FROM public.billing_periods WHERE business_id = w9 AND period_start = '2026-03-01+00'));
END $$;

-- F. The billable amount: goods after discounts and shortages, without delivery ------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w UUID := (SELECT w7 FROM zz.w4); x UUID; a RECORD;
BEGIN
  x := zz.mkorder(w, 1000, 50, '2026-03-15 10:00+00', 850);
  PERFORM zz.deliver(x);
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = x;
  PERFORM zz.check('F: a partly fulfilled order (effective total 850 with a 50 delivery fee) is billed on the SUPPLIED goods: 800, fee 8.00', a.billable_gmv = 800 AND a.charged_amount = 8.00, a::text);
  x := zz.mkorder(w, 1000, 50, '2026-03-16 10:00+00'); PERFORM zz.deliver(x);
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = x;
  PERFORM zz.check('F: an order delivered in full is billed on the goods (1,000), not the delivery fee (1,050)', a.billable_gmv = 1000, a::text);
END $$;

-- G. Changes in an order's value after delivery: adjustments -------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_adj', '{"onboarding_free_orders":1,"transaction_fee_percentage":1,"transaction_fee_cycle_cap":60}'::jsonb);
CREATE TABLE zz.w5 AS SELECT zz.mkws('Engine W11') w11;
SELECT zz.sub((SELECT w11 FROM zz.w5), 'eng_adj');
DO $$
DECLARE w UUID := (SELECT w11 FROM zz.w5); free_o UUID; o1 UUID; o2 UUID; o3 UUID; r JSONB; a RECORD; n INT; ret UUID; per_now public.billing_periods; g UUID;
BEGIN
  SELECT id INTO g FROM public.billing_allowance_grants WHERE business_id = w;
  free_o := zz.go(w, 1000, 50, '2026-03-02 10:00+00');
  o1 := zz.go(w, 1000, 50, '2026-03-03 10:00+00');
  PERFORM zz.check('G: (setup) the first order used the launch free order, the second is charged GHS 10.00', zz.a(free_o) = 'free_onboarding/onboarding1/0.00' AND zz.a(o1) = 'chargeable/-/10.00');
  -- a delivery credit lowers the order from 1,050 to 950 (billable 1,000 to 900)
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 950 WHERE id = o1;
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'adjustment' AND adjustment_seq = 1;
  PERFORM zz.check('G: a delivery credit creates ADJUSTMENT 1 for the difference (-100) priced at the order''s own 1%: a credit of GHS 1.00', a.billable_gmv = -100 AND a.fee_after_limits = -1.00 AND a.charged_amount = -1.00, a::text);
  PERFORM zz.check('G: it is a refund-type CREDIT entry of GHS 1.00 linked to the order, and the original entry is untouched', EXISTS (SELECT 1 FROM public.billing_ledger_entries WHERE order_id = o1 AND entry_type = 'refund' AND credit_amount = 1.00 AND assessment_id = a.id)
    AND (SELECT charged_amount = 10 FROM public.billing_ledger_entries WHERE order_id = o1 AND entry_type = 'transaction_fee' AND assessment_id = (SELECT id FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'primary')));
  PERFORM zz.check('G: the primary assessment is unchanged', zz.a(o1) = 'chargeable/-/10.00');
  SELECT * INTO per_now FROM public.billing_periods WHERE business_id = w AND period_start <= now() AND period_end > now() AND NOT shadow;
  PERFORM zz.check('G: the credit lands in the period that contains TODAY (earlier periods are not rewritten) and is counted there', per_now.credits_amount = 1.00 AND per_now.billable_gmv = -100, per_now::text);
  -- the same value again changes nothing
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 950 WHERE id = o1;
  PERFORM zz.check('G: setting the same value again records nothing', (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'adjustment') = 1 AND (public.billing_assess_order_change(o1) ->> 'skipped') = 'no_change');
  -- a back-order shipment raises it to 1,250 (billable 1,200)
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 1250 WHERE id = o1;
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'adjustment' AND adjustment_seq = 2;
  PERFORM zz.check('G: a later rise (back-order shipment) is ADJUSTMENT 2: +300 on the order, fee now 12.00 vs 9.00 assessed so +3.00 is charged', a.billable_gmv = 300 AND a.fee_after_limits = 3.00 AND a.charged_amount = 3.00, a::text);
  PERFORM zz.check('G: the adjustments never touch the free-order counters (still 1 of 1 used)', (SELECT count(*) FROM public.order_billing_assessments WHERE grant_id = g) = 1);
  -- returned goods resolved as a refund (value 120)
  INSERT INTO public.order_returns(order_id, pharmacy_id, wholesaler_id, reason, status) SELECT o1, o.pharmacy_id, o.wholesaler_id, 'damaged', 'requested' FROM public.orders o WHERE o.id = o1 RETURNING id INTO ret;
  UPDATE public.order_returns SET status = 'resolved', resolution = 'refund', resolved_amount_ghs = 120, resolved_at = now() WHERE id = ret;
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'adjustment' AND adjustment_seq = 3;
  PERFORM zz.check('G: goods returned and refunded (120) are ADJUSTMENT 3: -120 on the order, fee 10.80 vs 12.00 assessed, so GHS 1.20 is credited', a.billable_gmv = -120 AND a.charged_amount = -1.20, a::text);
  UPDATE public.order_returns SET resolved_amount_ghs = 120 WHERE id = ret;
  PERFORM zz.check('G: nothing more is recorded when nothing changes (still 3 adjustments)', (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = o1 AND kind = 'adjustment') = 3);

  -- an order that was FREE stays free when its value changes, and uses no allowance
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 800 WHERE id = free_o;
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = free_o AND kind = 'adjustment';
  PERFORM zz.check('G: an adjustment to a FREE order is a free adjustment: no money, no free order consumed', a.outcome = 'free_adjustment' AND a.charged_amount = 0 AND a.billable_gmv = -250 AND NOT EXISTS (SELECT 1 FROM public.billing_ledger_entries WHERE assessment_id = a.id AND (charged_amount <> 0 OR credit_amount <> 0)), a::text);
  -- an adjustment cannot exceed the cap
  o2 := zz.go(w, 6000, 0, now() - interval '1 day');
  PERFORM zz.check('G: (setup) an order in the current period is charged only GHS 57.00: the cap is 60 and the earlier +3.00 adjustment already used 3.00 of it', zz.a(o2) = 'chargeable/-/57.00', zz.a(o2));
  PERFORM public._allow_order_total_change(); UPDATE public.orders SET effective_total_ghs = 7000 WHERE id = o2;
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = o2 AND kind = 'adjustment';
  PERFORM zz.check('G: a rise after the cap is reached has fee 10.00 but charges NOTHING, with the cap adjustment recorded', a.fee_after_limits = 10 AND a.charged_amount = 0 AND a.cap_adjustment = 10, a::text);
  -- an order that was never assessed gets no adjustment
  o3 := zz.mkorder(w, 100, 0, '2026-03-20 10:00+00');
  PERFORM zz.check('G: an order that is not delivered / not assessed has nothing to adjust', (public.billing_assess_order_change(o3) ->> 'skipped') IN ('not_delivered', 'not_assessed'));
END $$;

-- H. A plan change never rewrites history ---------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w UUID := (SELECT w1 FROM zz.w); sub UUID; pid UUID; v1 UUID; v2 UUID; before_snap JSONB; x UUID; a RECORD;
BEGIN
  SELECT id INTO sub FROM public.billing_subscriptions WHERE business_id = w;
  SELECT id INTO pid FROM public.billing_plans WHERE code = 'eng_launch';
  SELECT id INTO v1 FROM public.billing_plan_versions WHERE plan_id = pid AND version = 1;
  SELECT terms_snapshot INTO before_snap FROM public.order_billing_assessments WHERE business_id = w ORDER BY assessed_at LIMIT 1;
  v2 := zz.adm(format('SELECT public.admin_billing_publish_plan_version(%L, ''{"subscription_amount":150,"onboarding_free_orders":5,"monthly_free_orders":0,"transaction_fee_percentage":1.0,"transaction_fee_cycle_cap":1500}''::jsonb, ''Raise the percentage'')::text', pid))::uuid;
  INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, overrides, reason) VALUES (sub, '2026-06-01 00:00+00', v2, '{}', 'Move to version 2 from June');
  x := zz.go(w, 1000, 0, '2026-07-10 10:00+00');
  SELECT * INTO a FROM public.order_billing_assessments WHERE order_id = x;
  PERFORM zz.check('H: an order delivered after the change is billed at the NEW 1.0% (version 2 has no monthly free orders and the launch allowance is used up, so GHS 10.00)', a.outcome = 'chargeable' AND a.charged_amount = 10.00 AND a.percentage = 1.0 AND (a.terms_snapshot ->> 'plan_version')::int = 2, a::text);
  PERFORM zz.check('H: orders assessed BEFORE the change are exactly as they were (0.75%, version 1)', (SELECT terms_snapshot FROM public.order_billing_assessments WHERE business_id = w ORDER BY assessed_at LIMIT 1) = before_snap
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w AND plan_version_id = v1) >= 13 AND (SELECT count(DISTINCT percentage) FROM public.order_billing_assessments WHERE business_id = w AND outcome = 'chargeable' AND plan_version_id = v1) = 1);
  PERFORM zz.check('H: the July subscription charge uses the new price (150) and the earlier periods keep theirs (100)', (SELECT subscription_amount FROM public.billing_periods WHERE business_id = w AND period_start = '2026-07-01+00') = 150
    AND (SELECT subscription_amount FROM public.billing_periods WHERE business_id = w AND period_start = '2026-03-01+00') = 100);
  -- an adjustment to an old order is priced under the OLD terms
  PERFORM public._allow_order_total_change();
  UPDATE public.orders SET effective_total_ghs = 1050 - 500 WHERE id = (SELECT order_id FROM public.order_billing_assessments WHERE business_id = w AND outcome = 'chargeable' AND kind = 'primary' ORDER BY assessed_at LIMIT 1);
  SELECT * INTO a FROM public.order_billing_assessments WHERE business_id = w AND kind = 'adjustment' LIMIT 1;
  PERFORM zz.check('H: a later change to an OLD order is priced at that order''s own percentage (0.75%), not today''s', a.percentage = 0.75 AND a.charged_amount = -3.75, a::text);
END $$;

-- I. Idempotency -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE w UUID := (SELECT w7 FROM zz.w4); x UUID; n1 INT; n2 INT; l1 INT; l2 INT; r JSONB;
BEGIN
  x := zz.go(w, 1000, 0, '2026-03-20 10:00+00');
  SELECT count(*) INTO n1 FROM public.order_billing_assessments WHERE business_id = w; SELECT count(*) INTO l1 FROM public.billing_ledger_entries WHERE business_id = w;
  r := public.billing_assess_order(x);
  PERFORM public.billing_assess_order(x); PERFORM public.billing_assess_order(x);
  SELECT count(*) INTO n2 FROM public.order_billing_assessments WHERE business_id = w; SELECT count(*) INTO l2 FROM public.billing_ledger_entries WHERE business_id = w;
  PERFORM zz.check('I: assessing the same delivery again and again changes nothing (one assessment, no new ledger entries)', n1 = n2 AND l1 = l2 AND (r ->> 'skipped') = 'already_assessed', r::text);
  PERFORM zz.check('I: a duplicate assessment cannot be inserted directly either (database constraint, not application state)', zz.try(format('INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome) VALUES (%L, %L, 1, ''excluded'')', w, x)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('I: a duplicate ledger entry cannot be inserted (idempotency key)', zz.try(format('INSERT INTO public.billing_ledger_entries(business_id, entry_type, idempotency_key) VALUES (%L, ''free_order'', ''fee:%s:primary:r'')', w, x)) LIKE 'ERR:%duplicate%');
  PERFORM zz.check('I: the delivery trigger does not fire again for a delivered order that is updated', (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = x) = 1 AND zz.try(format('UPDATE public.orders SET notes = ''again'' WHERE id = %L', x)) IS NULL AND (SELECT count(*) FROM public.order_billing_assessments WHERE order_id = x) = 1);
END $$;

-- J. Reconciliation is clean after all of that, and finds what is wrong when it is not -------------------------------------------------------------------------------------------------
DO $$
DECLARE r RECORD; n INT; sub_id UUID; per UUID; w UUID := (SELECT w5 FROM zz.w3); a UUID;
BEGIN
  PERFORM zz.check('J: after every scenario above the reconciliation finds NOTHING wrong (period totals, counters, ledger, free numbers, caps, queue)', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count || ' ' || details::text, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
  PERFORM zz.check('J: the administrator''s view says healthy', (zz.adm('SELECT public.admin_billing_reconciliation()::text')::jsonb ->> 'healthy')::boolean);
  SELECT id INTO per FROM public.billing_periods WHERE business_id = w AND period_start = '2026-03-01+00';
  UPDATE public.billing_periods SET transaction_fees_amount = transaction_fees_amount + 1 WHERE id = per;
  PERFORM zz.check('J: a period whose fee total no longer matches the ledger is reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'period_transaction_fees_differ_from_ledger') = 1);
  PERFORM zz.check('J: ... and so is one that is over the cap', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'period_fees_exceed_the_cap') >= 1);
  UPDATE public.billing_periods SET transaction_fees_amount = transaction_fees_amount - 1 WHERE id = per;
  UPDATE public.billing_periods SET credits_amount = credits_amount + 5 WHERE id = per;
  PERFORM zz.check('J: a credit total that does not match the ledger is reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'period_credits_differ_from_ledger') = 1);
  UPDATE public.billing_periods SET credits_amount = credits_amount - 5 WHERE id = per;
  UPDATE public.billing_periods SET subscription_amount = subscription_amount + 5 WHERE id = per;
  PERFORM zz.check('J: a subscription total that does not match the ledger is reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'period_subscription_differs_from_ledger') = 1);
  UPDATE public.billing_periods SET subscription_amount = subscription_amount - 5 WHERE id = per;
  UPDATE public.billing_periods SET chargeable_orders = chargeable_orders + 1 WHERE id = per;
  PERFORM zz.check('J: order counters that do not match the assessments are reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'period_counters_differ_from_assessments') = 1);
  UPDATE public.billing_periods SET chargeable_orders = chargeable_orders - 1 WHERE id = per;
  ALTER TABLE public.order_billing_assessments DISABLE TRIGGER trg_billing_assessments_append_only;
  SELECT id INTO a FROM public.order_billing_assessments WHERE business_id = (SELECT w1 FROM zz.w) AND free_source = 'onboarding' AND free_seq = 3;
  UPDATE public.order_billing_assessments SET free_seq = 9 WHERE id = a;
  PERFORM zz.check('J: free-order numbers with a gap (1, 2, 4, 5, 9) are reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'free_order_numbers_not_contiguous') = 1);
  UPDATE public.order_billing_assessments SET free_seq = 3 WHERE id = a;
  SELECT id INTO a FROM public.order_billing_assessments WHERE business_id = w AND charged_amount = 40 LIMIT 1;
  UPDATE public.order_billing_assessments SET charged_amount = 41 WHERE id = a;
  PERFORM zz.check('J: an assessment whose charge differs from its ledger entry is reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'assessment_charge_differs_from_ledger') = 1);
  UPDATE public.order_billing_assessments SET charged_amount = 40 WHERE id = a;
  ALTER TABLE public.order_billing_assessments ENABLE TRIGGER trg_billing_assessments_append_only;
  DROP INDEX public.order_billing_primary_real_idx;
  INSERT INTO public.order_billing_assessments(business_id, order_id, billable_gmv, outcome) SELECT business_id, order_id, 1, 'excluded' FROM public.order_billing_assessments WHERE kind = 'primary' AND NOT shadow LIMIT 1;
  PERFORM zz.check('J: a duplicate primary assessment (with the unique index removed) is reported', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'duplicate_primary_assessment') = 1);
  ALTER TABLE public.order_billing_assessments DISABLE TRIGGER trg_billing_assessments_append_only;
  DELETE FROM public.order_billing_assessments WHERE outcome = 'excluded' AND billable_gmv = 1 AND terms_snapshot = '{}'::jsonb;
  ALTER TABLE public.order_billing_assessments ENABLE TRIGGER trg_billing_assessments_append_only;
  CREATE UNIQUE INDEX order_billing_primary_real_idx ON public.order_billing_assessments (order_id) WHERE kind = 'primary' AND NOT shadow;
  PERFORM zz.check('J: and clean again once everything is put back', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0), (SELECT string_agg(check_name || '=' || finding_count, '; ') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- K. A failure in billing never stops a delivery; the queue retries ------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE zz.q AS SELECT NULL::uuid poison, NULL::uuid retry;
DO $$
DECLARE w UUID := (SELECT w8 FROM zz.w4); x UUID; y UUID; q RECORD; i INT; r JSONB;
BEGIN
  -- a poisoned ledger key makes this order's billing fail every time
  x := zz.mkorder(w, 1000, 0, '2026-03-25 10:00+00');
  INSERT INTO public.billing_ledger_entries(business_id, entry_type, idempotency_key, reason, source) VALUES (w, 'manual_debit', 'fee:' || x || ':primary:r', 'Poison for the test', 'admin');
  PERFORM zz.deliver(x);
  UPDATE zz.q SET poison = x;
  PERFORM zz.check('K: the order is DELIVERED even though its billing failed', (SELECT status FROM public.orders WHERE id = x) = 'delivered');
  PERFORM zz.check('K: nothing half-written was left behind (no assessment, no ledger entry other than the poison)', zz.a(x) IS NULL AND (SELECT count(*) FROM public.billing_ledger_entries WHERE order_id = x) = 0);
  SELECT * INTO q FROM public.billing_engine_queue WHERE order_id = x AND kind = 'assess';
  PERFORM zz.check('K: the failure is queued, with the reason, for a retry', q.status = 'pending' AND q.attempts = 1 AND q.last_error LIKE '%duplicate key%', q::text);
  FOR i IN 1..12 LOOP PERFORM public.billing_process_queue(10); END LOOP;
  SELECT * INTO q FROM public.billing_engine_queue WHERE order_id = x AND kind = 'assess';
  PERFORM zz.check('K: a failure that never clears stops being retried after 10 attempts and is marked FAILED', q.status = 'failed' AND q.attempts = 10, q::text);
  PERFORM zz.check('K: reconciliation reports the stuck queue entry and the unassessed delivery', (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'billing_queue_stuck') >= 1 AND (SELECT finding_count FROM public.billing_reconcile() WHERE check_name = 'delivered_order_not_assessed') >= 1);
  -- a transient failure succeeds on retry
  y := zz.mkorder(w, 1000, 0, '2026-03-26 10:00+00');
  UPDATE public.billing_settings SET mode = 'disabled'; PERFORM zz.deliver(y); UPDATE public.billing_settings SET mode = 'active';
  INSERT INTO public.billing_engine_queue(order_id, kind, status, attempts, last_error) VALUES (y, 'assess', 'pending', 1, 'transient');
  r := public.billing_process_queue(10);
  PERFORM zz.check('K: a queued delivery whose cause has gone away is assessed on the next run and marked done', zz.a(y) LIKE 'chargeable/%' AND (SELECT status FROM public.billing_engine_queue WHERE order_id = y) = 'done', r::text);
  PERFORM zz.check('K: the queue is for administrators only', zz.val_as((SELECT owner_id FROM public.businesses WHERE id = w), 'SELECT count(*)::text FROM public.billing_engine_queue') = '0' AND zz.adm('SELECT count(*)::text FROM public.billing_engine_queue')::int >= 2);
END $$;

-- L. Shadow is a separate world from real ----------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_shadow', '{"subscription_amount":100,"onboarding_free_orders":2,"monthly_free_orders":1,"transaction_fee_percentage":1}'::jsonb);
CREATE TABLE zz.w6 AS SELECT zz.mkws('Engine W12') w12;
SELECT zz.sub((SELECT w12 FROM zz.w6), 'eng_shadow');
DO $$
DECLARE w UUID := (SELECT w12 FROM zz.w6); a UUID; b UUID; c UUID; d UUID; e UUID; f UUID; g UUID;
BEGIN
  UPDATE public.billing_settings SET mode = 'shadow';
  a := zz.go(w, 1000, 0, '2026-03-03 10:00+00'); b := zz.go(w, 1000, 0, '2026-03-04 10:00+00'); c := zz.go(w, 1000, 0, '2026-03-05 10:00+00'); d := zz.go(w, 1000, 0, '2026-03-06 10:00+00');
  PERFORM zz.check('L: in SHADOW mode the same rules are simulated (2 launch free, 1 monthly free, then charged) but flagged shadow', zz.a(a, TRUE) = 'free_onboarding/onboarding1/0.00' AND zz.a(b, TRUE) = 'free_onboarding/onboarding2/0.00' AND zz.a(c, TRUE) = 'free_monthly/monthly1/0.00' AND zz.a(d, TRUE) = 'chargeable/-/10.00');
  PERFORM zz.check('L: nothing real was written: no real assessment, period or ledger entry', zz.nass(w) = 0 AND (SELECT count(*) FROM public.billing_periods WHERE business_id = w AND NOT shadow) = 0 AND (SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = w AND NOT shadow) = 0);
  PERFORM zz.check('L: the shadow period and ledger carry the shadow flag, including the simulated subscription charge (100)', (SELECT shadow AND subscription_amount = 100 FROM public.billing_periods WHERE business_id = w) AND (SELECT bool_and(shadow) FROM public.billing_ledger_entries WHERE business_id = w));
  PERFORM zz.check('L: shadow assessments write no audit entry (no noise in the activity log)', NOT EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Order billing assessed' AND business_id = w));
  PERFORM zz.check('L: the business''s owner cannot see any of the shadow rows; an administrator can', zz.val_as((SELECT owner_id FROM public.businesses WHERE id = w), 'SELECT (SELECT count(*) FROM public.order_billing_assessments) + (SELECT count(*) FROM public.billing_ledger_entries) + (SELECT count(*) FROM public.billing_periods) || ''''') = '0'
    AND zz.adm(format('SELECT count(*)::text FROM public.order_billing_assessments WHERE business_id = %L', w)) = '4');
  -- activation: real billing starts fresh, only from the activation moment
  UPDATE public.billing_settings SET mode = 'active';
  UPDATE public.billing_subscriptions SET activated_at = '2026-03-06 12:00+00' WHERE business_id = w;
  PERFORM zz.check('L: orders delivered in shadow, BEFORE activation, are not billed for real by catch-up', (public.billing_catch_up(50) ->> 'done')::int >= 0 AND zz.nass(w) = 0, zz.nass(w)::text);
  e := zz.go(w, 1000, 0, '2026-03-07 10:00+00'); f := zz.go(w, 1000, 0, '2026-03-08 10:00+00'); g := zz.go(w, 1000, 0, '2026-03-09 10:00+00');
  PERFORM zz.check('L: after activation the REAL counters start fresh: the first real orders are launch free 1 and 2 (the shadow use did not count), then monthly free, then charged', zz.a(e) = 'free_onboarding/onboarding1/0.00' AND zz.a(f) = 'free_onboarding/onboarding2/0.00' AND zz.a(g) = 'free_monthly/monthly1/0.00', zz.a(e) || ' ' || zz.a(f) || ' ' || zz.a(g));
  PERFORM zz.check('L: the earlier shadow assessments are untouched and shadow and real never mix', (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w AND shadow) = 4 AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w AND NOT shadow) = 3
    AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = w AND shadow AND outcome = 'free_onboarding') = 2);
  PERFORM zz.check('L: the owner now sees the real rows only', zz.val_as((SELECT owner_id FROM public.businesses WHERE id = w), 'SELECT count(*)::text FROM public.order_billing_assessments') = '3');
  PERFORM zz.check('L: both worlds reconcile', NOT EXISTS (SELECT 1 FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('billing_queue_stuck', 'delivered_order_not_assessed')), (SELECT string_agg(check_name, ',') FROM public.billing_reconcile() WHERE finding_count > 0));
END $$;

-- M. Trial and cancellation ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT zz.mkplan('eng_states', '{"subscription_amount":100,"free_trial_days":30,"transaction_fee_percentage":1}'::jsonb);
CREATE TABLE zz.w7 AS SELECT zz.mkws('Engine W13') w13, zz.mkws('Engine W14') w14;
SELECT zz.sub((SELECT w13 FROM zz.w7), 'eng_states', '2026-08-01 00:00+00'), zz.sub((SELECT w14 FROM zz.w7), 'eng_states', '2026-01-01 00:00+00');
DO $$
DECLARE w UUID := (SELECT w13 FROM zz.w7); c UUID := (SELECT w14 FROM zz.w7); n INT; s RECORD; x UUID;
BEGIN
  n := public.billing_advance_states('2026-08-15 00:00+00');
  PERFORM zz.check('M: during the 30-day trial the subscription stays TRIALING', (SELECT status FROM public.billing_subscriptions WHERE business_id = w) = 'trialing');
  n := public.billing_advance_states('2026-08-30 23:59:59+00');
  PERFORM zz.check('M: one second before the trial ends it is still trialing', (SELECT status FROM public.billing_subscriptions WHERE business_id = w) = 'trialing');
  n := public.billing_advance_states('2026-08-31 00:00:00+00');
  PERFORM zz.check('M: when the trial ends it becomes ACTIVE, and the change is audited against the business', (SELECT status FROM public.billing_subscriptions WHERE business_id = w) = 'active' AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing trial ended' AND business_id = w));
  PERFORM zz.check('M: running it again changes nothing', public.billing_advance_states('2026-09-30 00:00+00') >= 0 AND (SELECT status FROM public.billing_subscriptions WHERE business_id = w) = 'active');
  -- cancel at the end of the period
  UPDATE public.billing_subscriptions SET cancel_at_period_end = TRUE WHERE business_id = c;
  PERFORM public.billing_advance_states('2026-05-10 00:00+00');
  SELECT * INTO s FROM public.billing_subscriptions WHERE business_id = c;
  PERFORM zz.check('M: "cancel at the end of the period" sets the end date to the end of the CURRENT period (31 May) and records the cancellation moment', s.ended_at = '2026-06-01 00:00+00' AND s.cancelled_at IS NOT NULL AND s.status = 'active', s::text);
  PERFORM zz.check('M: until that date it is still billed', zz.a(zz.go(c, 1000, 0, '2026-05-20 10:00+00')) LIKE 'chargeable/%');
  PERFORM zz.check('M: an order delivered on or after the end date is not billed', (zz.go(c, 1000, 0, '2026-06-01 00:00+00') IS NOT NULL) AND (SELECT count(*) FROM public.order_billing_assessments WHERE business_id = c) = 1);
  PERFORM public.billing_advance_states('2026-06-01 00:00+00');
  PERFORM zz.check('M: at the end date the subscription becomes CANCELLED and is audited', (SELECT status FROM public.billing_subscriptions WHERE business_id = c) = 'cancelled' AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing subscription ended' AND business_id = c));
  PERFORM public.billing_open_periods('2026-09-01 00:00+00');
  PERFORM zz.check('M: no periods are opened after the end date', (SELECT max(period_end) FROM public.billing_periods WHERE business_id = c AND NOT shadow) <= '2026-06-01 00:00+00');
  PERFORM zz.check('M: a cancelled subscription cannot be reopened', zz.try(format('UPDATE public.billing_subscriptions SET status = ''active'' WHERE business_id = %L', c)) LIKE 'ERR: A cancelled subscription cannot be reopened.%');
END $$;

-- N. Who can call what, and the delivery by the wholesaler's own user ----------------------------------------------------------------------------------------------------------------------------
DO $$
DECLARE u RECORD; fn TEXT; r TEXT; w UUID := (SELECT w7 FROM zz.w4); wo UUID := zz.owner((SELECT w7 FROM zz.w4)); x UUID; ph_owner UUID := (SELECT uu.id FROM zz.u uu WHERE uu.k = 'ph_owner');
BEGIN
  FOR u IN SELECT * FROM (VALUES ('a wholesaler owner', wo), ('a pharmacy owner', ph_owner), ('an administrator', (SELECT u_admin FROM zz.bx))) v(label, uid) LOOP
    FOREACH fn IN ARRAY ARRAY['billing_assess_order(gen_random_uuid())', 'billing_assess_order_change(gen_random_uuid())', 'billing_open_periods(now())', 'billing_advance_states(now())', 'billing_process_queue(5)',
      'billing_catch_up(5)', 'billing_run_scheduled(now())', 'billing_reconcile()', 'billing_compute_fee(1, 1, NULL, NULL)', '_billing_billable(gen_random_uuid())', '_billing_unassessed_orders()'] LOOP
      r := zz.val_as(u.uid, 'SELECT (public.' || fn || ')::text');
      PERFORM zz.check(u.label || ' cannot call ' || split_part(fn, '(', 1), r LIKE 'ERR: permission denied%', r);
    END LOOP;
  END LOOP;
  PERFORM zz.check('someone not signed in cannot call the engine', zz.anon('SELECT public.billing_assess_order(gen_random_uuid())::text') LIKE 'ERR: permission denied%');
  r := zz.val_as(wo, 'SELECT public.admin_billing_run_now(''Trying to run billing'')::text');
  PERFORM zz.check('only an administrator can run billing now', r LIKE 'ERR: Only platform administrators%', r);
  PERFORM zz.check('and needs a reason', zz.adm('SELECT public.admin_billing_run_now('''')::text') LIKE 'ERR: A reason of at least 5%');
  r := zz.adm('SELECT public.admin_billing_run_now(''Run billing for the test'')::text');
  PERFORM zz.check('run now returns what it did and is audited with the reason', r NOT LIKE 'ERR:%' AND EXISTS (SELECT 1 FROM public.audit_logs WHERE activity = 'Billing run now' AND details ->> 'reason' = 'Run billing for the test'), r);
  PERFORM zz.check('the reconciliation is for administrators only', zz.val_as(wo, 'SELECT public.admin_billing_reconciliation()::text') LIKE 'ERR: Only platform administrators%' AND zz.anon('SELECT public.admin_billing_reconciliation()::text') LIKE 'ERR: permission denied%');
  -- the wholesaler's own user delivers an order: billing still happens, computed by the database, with no billing rights of their own
  x := zz.mkorder(w, 2000, 0, '2026-04-02 10:00+00');
  PERFORM zz.advance(x, 'dispatched');
  r := zz.val_as(wo, format('UPDATE public.orders SET status = ''delivered'' WHERE id = %L RETURNING status::text', x));
  PERFORM zz.check('a delivery made by the wholesaler''s OWN user is billed by the engine (the user has no billing rights and sends no amounts)', r = 'delivered' AND zz.a(x) = 'chargeable/-/20.00', r || ' ' || coalesce(zz.a(x), 'none'));
  PERFORM zz.check('and that user still cannot touch any billing table', zz.val_as(wo, 'UPDATE public.order_billing_assessments SET charged_amount = 0') LIKE 'ERR: permission denied%' AND zz.val_as(wo, 'DELETE FROM public.billing_ledger_entries') LIKE 'ERR: permission denied%');
END $$;

SELECT count(*) FILTER (WHERE ok) AS pass, count(*) FILTER (WHERE NOT ok) AS fail FROM zz.results;
