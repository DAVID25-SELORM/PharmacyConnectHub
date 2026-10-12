#!/bin/bash
# The billing engine under concurrency, with real overlapping database sessions.
#
#   1. THE MONTHLY CAP. A wholesaler on 1% with a monthly cap of GHS 100 has five GHS 4,000 orders (GHS 40.00 each) delivered at the same moment by five sessions. However they interleave, the
#      month's charged fees must be exactly GHS 100.00 (40 + 40 + 20, then nothing): two sessions must never both see the same remaining cap.
#   2. FREE ORDERS. A wholesaler with 2 launch free orders has four orders delivered at once: exactly two are free (numbers 1 and 2), two are charged, and no number is used twice.
#   3. THE SAME DELIVERY ASSESSED TWICE AT ONCE (a retry racing the trigger): exactly one assessment, one set of ledger entries.
#   In every case the reconciliation must find nothing wrong afterwards.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261202110000, and the production guard and stock fixtures.
# Negative control: remove BOTH row locks (the subscription's "FOR UPDATE" and the period's "FOR UPDATE") from billing_assess_order and scenarios 1, 2 and 3 fail.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.cc;
UPDATE public.billing_settings SET mode = 'active';
CREATE TABLE zz.cc(scenario TEXT, label TEXT, id UUID);
DO $$
DECLARE
  v_ph UUID := (SELECT id FROM zz.b WHERE name = 'Good Pharmacy');
  v_u UUID; v_b UUID; v_plan UUID; v_ver UUID; v_sub UUID; v_terms UUID; v_o UUID; s TEXT; i INT; st TEXT;
BEGIN
  FOREACH s IN ARRAY ARRAY['cap', 'free', 'idem'] LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc' || s || '@zz.test', '{}', '{"provider":"email"}', now(), now());
    INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', 'CC ' || s, 'CCLIC-' || s, 'approved') RETURNING id INTO v_b;
    INSERT INTO public.billing_plans(code, business_type, name, active) VALUES ('cc_' || s, 'wholesaler', 'CC ' || s, TRUE) RETURNING id INTO v_plan;
    INSERT INTO public.billing_plan_versions(plan_id, version, transaction_fee_percentage, transaction_fee_cycle_cap, reason)
    VALUES (v_plan, 1, 1, CASE WHEN s = 'cap' THEN 100 END, 'Concurrency test') RETURNING id INTO v_ver;
    INSERT INTO public.billing_subscriptions(business_id, status, billing_starts_at, period_anchor_at) VALUES (v_b, 'active', '2026-01-01+00', '2026-01-01+00') RETURNING id INTO v_sub;
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, reason) VALUES (v_sub, '2026-01-01+00', v_ver, 'Concurrency test');
    IF s = 'free' THEN
      INSERT INTO public.billing_allowance_grants(business_id, quantity, source, reason) VALUES (v_b, 2, 'admin', 'Concurrency test');
    END IF;
    INSERT INTO zz.cc VALUES (s, 'business', v_b);
    FOR i IN 1..(CASE s WHEN 'cap' THEN 5 WHEN 'free' THEN 4 ELSE 1 END) LOOP
      INSERT INTO public.orders(order_number, pharmacy_id, wholesaler_id, total_ghs, delivery_fee_ghs, delivered_at) VALUES ('ORD-CC' || s || i, v_ph, v_b, 4000, 0, '2026-03-10 10:00+00') RETURNING id INTO v_o;
      FOREACH st IN ARRAY ARRAY['accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched'] LOOP EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', st, v_o); END LOOP;
      INSERT INTO zz.cc VALUES (s, 'order' || i, v_o);
    END LOOP;
  END LOOP;
END $$;
SQL

# The periods already exist (opened by the scheduled run), so what is raced is the spending of the cap and of the free numbers, not the creation of the period.
$P -c "SELECT public.billing_open_periods('2026-03-15 00:00+00')" >/dev/null

oid() { $P -c "SELECT id FROM zz.cc WHERE scenario = '$1' AND label = '$2'"; }
bid() { $P -c "SELECT id FROM zz.cc WHERE scenario = '$1' AND label = 'business'"; }
deliver_sql() { echo "BEGIN;
UPDATE public.orders SET status = 'delivered' WHERE id = '$1';
SELECT pg_sleep($2);
COMMIT;"; }

run_parallel() {  # $1 scenario, $2 number of orders
  local sc=$1 n=$2 pids=() outs=() i
  for i in $(seq 1 $n); do
    local out; out=$(mktemp); outs+=("$out")
    ( $P > "$out" 2>&1 <<SQL
$(deliver_sql "$(oid $sc order$i)" $([ $i = 1 ] && echo 3 || echo 0.3))
SQL
    ) &
    pids+=($!)
    sleep $([ $i = 1 ] && echo 1.2 || echo 0.15)
  done
  for p in "${pids[@]}"; do wait $p; done
  ERRS=""
  for out in "${outs[@]}"; do if grep -q "ERROR" "$out"; then ERRS="$ERRS $(grep -m1 ERROR "$out")"; fi; done
}

# ----- Scenario 1: five orders, a cap of 100 ---------------------------------------------------------------------------------------------------------------
run_parallel cap 5
B=$(bid cap)
TOTAL=$($P -c "SELECT COALESCE(sum(charged_amount), 0) FROM public.order_billing_assessments WHERE business_id = '$B'")
N=$($P -c "SELECT count(*) FROM public.order_billing_assessments WHERE business_id = '$B'")
CH=$($P -c "SELECT string_agg(charged_amount::text, ',' ORDER BY charged_amount DESC) FROM public.order_billing_assessments WHERE business_id = '$B'")
PERIOD=$($P -c "SELECT transaction_fees_amount || '/' || fees_before_cap FROM public.billing_periods WHERE business_id = '$B' AND period_start = '2026-03-01+00'")
check "1: all five orders were assessed with no error" "$([ "$N" = "5" ] && [ -z "$ERRS" ] && echo true || echo false)" "n=$N errors=$ERRS"
check "1: the month's charged fees are exactly GHS 100.00, never more (the cap held under concurrency)" "$([ "$TOTAL" = "100.00" ] && echo true || echo false)" "total=$TOTAL charged=$CH"
check "1: the charges were 40.00, 40.00, 20.00, 0.00, 0.00 in some order" "$([ "$CH" = "40.00,40.00,20.00,0.00,0.00" ] && echo true || echo false)" "$CH"
check "1: the period shows 100.00 charged and 200.00 before the cap" "$([ "$PERIOD" = "100.00/200.00" ] && echo true || echo false)" "$PERIOD"

# ----- Scenario 2: four orders, two launch free orders ---------------------------------------------------------------------------------------------------
run_parallel free 4
B=$(bid free)
FREE=$($P -c "SELECT string_agg(free_seq::text, ',' ORDER BY free_seq) FROM public.order_billing_assessments WHERE business_id = '$B' AND free_source = 'onboarding'")
NCH=$($P -c "SELECT count(*) FROM public.order_billing_assessments WHERE business_id = '$B' AND outcome = 'chargeable'")
N=$($P -c "SELECT count(*) FROM public.order_billing_assessments WHERE business_id = '$B'")
check "2: all four orders were assessed with no error" "$([ "$N" = "4" ] && [ -z "$ERRS" ] && echo true || echo false)" "n=$N errors=$ERRS"
check "2: exactly two orders were free, with the numbers 1 and 2, each used once" "$([ "$FREE" = "1,2" ] && echo true || echo false)" "free=$FREE"
check "2: the other two were charged" "$([ "$NCH" = "2" ] && echo true || echo false)" "chargeable=$NCH"

# ----- Scenario 3: the same delivery assessed by two sessions at once ----------------------------------------------------------------------------------
B=$(bid idem); O=$(oid idem order1)
# deliver it with billing off, so the engine has not seen it; then two sessions assess it at once
$P -c "UPDATE public.billing_settings SET mode = 'disabled'; UPDATE public.orders SET status = 'delivered' WHERE id = '$O'; UPDATE public.billing_settings SET mode = 'active'" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.billing_assess_order('$O')->>'outcome';
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.2
$P > "$B_OUT" 2>&1 <<SQL
SELECT public.billing_assess_order('$O')->>'skipped';
SQL
wait $A_PID
N=$($P -c "SELECT count(*) FROM public.order_billing_assessments WHERE order_id = '$O'")
L=$($P -c "SELECT count(*) FROM public.billing_ledger_entries WHERE order_id = '$O'")
check "3: the first session assessed the order" "$(grep -q chargeable "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "3: the second, racing it, found it already assessed (no error)" "$(grep -q already_assessed "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "3: exactly one assessment and one fee entry exist" "$([ "$N" = "1" ] && [ "$L" = "1" ] && echo true || echo false)" "assessments=$N ledger=$L"

# ----- Afterwards everything reconciles ----------------------------------------------------------------------------------------------------------------------------------
BAD=$($P -c "SELECT count(*) FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'billing_queue_stuck'")
check "all: the reconciliation finds nothing wrong after the concurrent runs" "$([ "$BAD" = "0" ] && echo true || echo false)" "$($P -c "SELECT string_agg(check_name || '=' || finding_count, ';') FROM public.billing_reconcile() WHERE finding_count > 0")"

$P -c "UPDATE public.billing_settings SET mode = 'disabled'" >/dev/null
exit $fail
