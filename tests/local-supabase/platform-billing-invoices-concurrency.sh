#!/bin/bash
# Invoices and payments under concurrency, with real overlapping database sessions.
#
#   1. TWO INVOICE RUNS AT ONCE. Two sessions run the invoicing step while the same periods are due. Each period is invoiced exactly once, the numbers are contiguous, neither run reports a failure.
#   2. THE SAME PAYMENT SENT TWICE AT ONCE (a double click). Two administrators' sessions record a payment with the same request key: one payment exists, the second is told it was already recorded.
#   3. TWO PAYMENTS THAT TOGETHER EXCEED THE BALANCE. A 100.00 invoice; two sessions each record 70.00 at once. One succeeds; the other is refused in plain words (it saw the balance AFTER the first); the
#      invoice is never paid more than its total.
#   4. A DELIVERY ASSESSED WHILE ITS PERIOD IS BEING INVOICED. The invoicing step holds the business's lock; an assessment for a delivery dated inside the period waits, then lands in the CURRENT period
#      (never inside the invoiced one); the invoice's total does not move.
#   In every case the reconciliation must find nothing wrong afterwards.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261204110000, and the production guard and stock fixtures.
# Negative controls (each makes a scenario fail): scenario 1, remove the subscription's and the period's "FOR UPDATE" from billing_issue_invoices (the second run then reports a failure); scenario 2 and 3,
# remove the invoice's "FOR UPDATE" from admin_billing_record_payment (scenario 3 then dies on the database's own CHECK instead of the plain-words refusal, and scenario 2 records twice);
# scenario 4, remove the redirect from _billing_ensure_period (the assessment is refused by the period guard instead of landing in the current period).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

ADMIN=$($P -c "SELECT id FROM zz.u WHERE k = 'admin'")
$P <<SQL >/dev/null
DROP TABLE IF EXISTS zz.cc;
UPDATE public.billing_settings SET mode = 'active', invoice_delay_hours = 24, payment_terms_days = 14;
CREATE TABLE zz.cc(scenario TEXT, label TEXT, id UUID);
DO \$\$
DECLARE
  v_ph UUID := (SELECT id FROM zz.b WHERE name = 'Good Pharmacy');
  v_u UUID; v_b UUID; v_plan UUID; v_ver UUID; v_sub UUID; s TEXT;
BEGIN
  INSERT INTO public.billing_plans(code, business_type, name, active) VALUES ('ic_plan', 'wholesaler', 'IC plan', TRUE) RETURNING id INTO v_plan;
  INSERT INTO public.billing_plan_versions(plan_id, version, subscription_amount, transaction_fee_percentage, reason) VALUES (v_plan, 1, 100, 1, 'Concurrency test') RETURNING id INTO v_ver;
  FOREACH s IN ARRAY ARRAY['pay', 'over', 'issue', 'assess'] LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ic' || s || '@zz.test', '{}', '{"provider":"email"}', now(), now());
    INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', 'IC ' || s, 'ICLIC-' || s, 'approved') RETURNING id INTO v_b;
    INSERT INTO public.billing_subscriptions(business_id, status, billing_starts_at, period_anchor_at) VALUES (v_b, 'active', '2026-07-01+00', '2026-07-01+00') RETURNING id INTO v_sub;
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, reason) VALUES (v_sub, '2026-07-01+00', v_ver, 'Concurrency test');
    INSERT INTO zz.cc VALUES (s, 'business', v_b);
  END LOOP;
END \$\$;
SQL

bid() { $P -c "SELECT id FROM zz.cc WHERE scenario = '$1' AND label = 'business'"; }

# The two payment scenarios need invoices that already exist. Open every period and invoice only those two businesses first, by making the others' periods not yet due.
$P -c "SELECT public.billing_open_periods(now())" >/dev/null
$P <<SQL >/dev/null
UPDATE public.billing_settings SET invoice_delay_hours = 24;
-- only 'pay' and 'over' are invoiced now: hold the other two back by giving their periods a future end for a moment (the guard allows only status and paid amounts to change, so use the replica role as a test fixture)
SET session_replication_role = replica;
UPDATE public.billing_periods SET status = 'closed' WHERE business_id IN (SELECT id FROM zz.cc WHERE scenario IN ('issue', 'assess') AND label = 'business') AND period_end <= now();
SET session_replication_role = origin;
SELECT public.billing_issue_invoices(now());
SET session_replication_role = replica;
UPDATE public.billing_periods SET status = 'open' WHERE business_id IN (SELECT id FROM zz.cc WHERE scenario IN ('issue', 'assess') AND label = 'business') AND status = 'closed';
SET session_replication_role = origin;
SQL

# Scenario 4's delivery: dated in August, delivered while billing is off so the engine has not seen it.
$P <<SQL >/dev/null
UPDATE public.billing_settings SET mode = 'disabled';
DO \$\$
DECLARE v_o UUID; st TEXT; v_ph UUID := (SELECT id FROM zz.b WHERE name = 'Good Pharmacy'); v_b UUID := (SELECT id FROM zz.cc WHERE scenario = 'assess' AND label = 'business');
BEGIN
  INSERT INTO public.orders(order_number, pharmacy_id, wholesaler_id, total_ghs, delivery_fee_ghs, delivered_at) VALUES ('ORD-ICA1', v_ph, v_b, 4000, 0, '2026-08-10 10:00+00') RETURNING id INTO v_o;
  FOREACH st IN ARRAY ARRAY['accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] LOOP EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', st, v_o); END LOOP;
  INSERT INTO zz.cc VALUES ('assess', 'order1', v_o);
END \$\$;
UPDATE public.billing_settings SET mode = 'active';
SQL

as_admin() { echo "SELECT set_config('request.jwt.claims', '{\"sub\":\"$ADMIN\",\"role\":\"authenticated\"}', true); SELECT set_config('request.jwt.claim.sub', '$ADMIN', true); SET LOCAL ROLE authenticated;"; }

# ----- Scenario 1: two invoice runs at once ------------------------------------------------------------------------------------------------------------------------
# (scenario 4's business is held back again, so that its invoice is still to be issued when scenario 4 starts)
hold() { $P -c "SET session_replication_role = replica; UPDATE public.billing_periods SET status = '$1' WHERE business_id = (SELECT id FROM zz.cc WHERE scenario = 'assess' AND label = 'business') AND status = '$2' AND period_end <= now()" >/dev/null; }
hold closed open
B=$(bid issue)
N0=$($P -c "SELECT count(*) FROM public.billing_invoices")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.billing_issue_invoices(now())::text;
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.2
$P > "$B_OUT" 2>&1 <<SQL
SELECT public.billing_issue_invoices(now())::text;
SQL
wait $A_PID
N=$($P -c "SELECT count(*) FROM public.billing_invoices WHERE business_id = '$B'")
DUP=$($P -c "SELECT count(*) FROM (SELECT period_id FROM public.billing_invoices GROUP BY period_id HAVING count(*) > 1) d")
NUMS=$($P -c "SELECT count(*) = max(substring(invoice_number FROM '[0-9]+\$')::int) AND (SELECT last_invoice_number FROM public.billing_settings) = count(*) FROM public.billing_invoices")
check "1: the first run issued the invoices that were due" "$(grep -q '"invoices_issued": [1-9]' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "1: the second, racing it, issued nothing and reported no failure" "$(grep -q '"invoices_issued": 0' "$B_OUT" && grep -q '"failed": 0' "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "1: the business has one invoice for each ended month (July, August and September: 3) and no period was invoiced twice" "$([ "$N" = "3" ] && [ "$DUP" = "0" ] && echo true || echo false)" "n=$N dup=$DUP"
check "1: the invoice numbers are contiguous with the counter" "$([ "$NUMS" = "t" ] && echo true || echo false)" "$NUMS"

hold open closed

# ----- Scenario 2: the same payment sent twice at once -------------------------------------------------------------------------------------------------------
B=$(bid pay)
INV=$($P -c "SELECT id FROM public.billing_invoices WHERE business_id = '$B' ORDER BY period_start LIMIT 1")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
SELECT (public.admin_billing_record_payment('$INV', 40, 'cash', NULL, now(), NULL, 'Concurrency test payment', 'cc-same-key')->>'replayed');
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.2
$P > "$B_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
SELECT (public.admin_billing_record_payment('$INV', 40, 'cash', NULL, now(), NULL, 'Concurrency test payment', 'cc-same-key')->>'replayed');
COMMIT;
SQL
wait $A_PID
NP=$($P -c "SELECT count(*) FROM public.billing_payments WHERE invoice_id = '$INV'")
PAID=$($P -c "SELECT amount_paid FROM public.billing_invoices WHERE id = '$INV'")
check "2: the first session recorded the payment" "$(grep -q '^false' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "2: the second, sending the same request, was told it was already recorded (no error)" "$(grep -q '^true' "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "2: exactly one payment exists and the invoice shows 40.00 paid" "$([ "$NP" = "1" ] && [ "$PAID" = "40.00" ] && echo true || echo false)" "payments=$NP paid=$PAID"

# ----- Scenario 3: two different payments that together exceed the balance -----------------------------------------------------------------------------------
B=$(bid over)
INV=$($P -c "SELECT id FROM public.billing_invoices WHERE business_id = '$B' ORDER BY period_start LIMIT 1")
TOTAL=$($P -c "SELECT total_amount FROM public.billing_invoices WHERE id = '$INV'")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
SELECT (public.admin_billing_record_payment('$INV', 70, 'bank_transfer', 'CC-OVER-A', now(), NULL, 'Concurrency test payment', 'cc-over-a')->>'invoice_status');
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.2
$P > "$B_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
SELECT (public.admin_billing_record_payment('$INV', 70, 'bank_transfer', 'CC-OVER-B', now(), NULL, 'Concurrency test payment', 'cc-over-b')->>'invoice_status');
COMMIT;
SQL
wait $A_PID
NP=$($P -c "SELECT count(*) FROM public.billing_payments WHERE invoice_id = '$INV'")
PAID=$($P -c "SELECT amount_paid FROM public.billing_invoices WHERE id = '$INV'")
check "3: the invoice is 100.00" "$([ "$TOTAL" = "100.00" ] && echo true || echo false)" "$TOTAL"
check "3: the first payment of 70.00 was accepted (part paid)" "$(grep -q 'partially_paid' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "3: the second was refused in plain words, because it saw the balance after the first (30.00)" "$(grep -q 'more than the balance of this invoice (30.00 outstanding)' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "3: only one payment exists and the invoice is never paid more than it is worth" "$([ "$NP" = "1" ] && [ "$PAID" = "70.00" ] && echo true || echo false)" "payments=$NP paid=$PAID"

# ----- Scenario 4: a delivery assessed while its period is being invoiced ------------------------------------------------------------------------------------
B=$(bid assess); O=$(echo "$($P -c "SELECT id FROM zz.cc WHERE scenario = 'assess' AND label = 'order1'")")
AUG=$($P -c "SELECT id FROM public.billing_periods WHERE business_id = '$B' AND period_start = '2026-08-01+00' AND NOT shadow")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.billing_issue_invoices(now())::text;
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.2
$P > "$B_OUT" 2>&1 <<SQL
SELECT public.billing_assess_order('$O')->>'period_id';
SQL
wait $A_PID
CUR=$($P -c "SELECT id FROM public.billing_periods WHERE business_id = '$B' AND period_start <= now() AND period_end > now() AND NOT shadow")
GOT=$($P -c "SELECT period_id FROM public.order_billing_assessments WHERE order_id = '$O' AND kind = 'primary'")
AUGTOTAL=$($P -c "SELECT total_amount FROM public.billing_invoices WHERE period_id = '$AUG'")
AUGSTATUS=$($P -c "SELECT status FROM public.billing_periods WHERE id = '$AUG'")
check "4: the invoicing step issued August's invoice" "$(grep -q '"invoices_issued": [1-9]' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "4: the assessment that waited for it raised no error" "$(! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "4: the delivery dated in August is billed in the CURRENT period, not in the invoiced August" "$([ "$GOT" = "$CUR" ] && [ "$GOT" != "$AUG" ] && echo true || echo false)" "assessed in $GOT current $CUR august $AUG"
check "4: August's invoice is exactly its subscription (100.00) and its period is final" "$([ "$AUGTOTAL" = "100.00" ] && [ "$AUGSTATUS" = "invoiced" ] && echo true || echo false)" "total=$AUGTOTAL status=$AUGSTATUS"

# ----- Afterwards everything reconciles ---------------------------------------------------------------------------------------------------------------------------------
BAD=$($P -c "SELECT count(*) FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name <> 'billing_queue_stuck'")
check "all: the reconciliation finds nothing wrong after the concurrent runs" "$([ "$BAD" = "0" ] && echo true || echo false)" "$($P -c "SELECT string_agg(check_name || '=' || finding_count, ';') FROM public.billing_reconcile() WHERE finding_count > 0")"

$P -c "UPDATE public.billing_settings SET mode = 'disabled'" >/dev/null
exit $fail
