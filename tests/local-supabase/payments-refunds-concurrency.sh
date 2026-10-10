#!/bin/bash
# Refunds under concurrency, with real overlapping database sessions.
#
#   1. Two workers try to take the same approved refund at once: exactly ONE gets it (the other gets nothing); it is sent once.
#   2. The provider's "processed" notification and an administrator's "confirm as refunded" arrive at the same moment: the refund completes ONCE
#      (one log entry, one notification to the pharmacy, the order refunded once).
#   3. Two requests for refunds of the same payment at once, each for most of it: only one is accepted (the cap holds under the payment's lock);
#      two requests with the same source: one refund.
#   4. A refund that is being sent cannot be cancelled underneath the sender: the cancellation waits, then is refused.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261109110000, and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove `FOR UPDATE` from the payment attempt lookup in _request_refund; scenario 3 must then fail;
# remove `SKIP LOCKED` from claim_refund_for_submission; scenario 1 must then fail (both workers get the refund) or the second worker must wait.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pf;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PF A'), ('PF B'), ('PF C'), ('PF D')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pf AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  (SELECT id FROM public.products WHERE name='PF A') pa,
  (SELECT id FROM public.products WHERE name='PF B') pb,
  (SELECT id FROM public.products WHERE name='PF C') pc,
  (SELECT id FROM public.products WHERE name='PF D') pd;
CREATE TABLE zz.pf_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', auto_refunds = FALSE;
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pf)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pf), 'role', 'authenticated')::text, false);"; }

# A paid online order (ten units at 100 = 1000), $3 = "cancel" to also cancel it (which requests the full refund).
make_paid() { # $1 label, $2 product column, $3 reference, $4 cancel|keep
$P <<SQL >/dev/null
$(as_sql u_po)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pf), (SELECT good FROM zz.pf),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.pf), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pf)::text, 'pay_now'));
INSERT INTO zz.pf_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
SELECT o.id, 'paystack', 'test', '$3', o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = (SELECT id FROM zz.pf_o WHERE label = '$1');
SELECT public.apply_payment_result('paystack', 'test', '$3', 'success', 100000, 'GHS', 'tx-$3', 'card', 1500, 'verify')->>'outcome';
SQL
if [ "$4" = "cancel" ]; then $P -c "UPDATE public.orders SET status = 'cancelled' WHERE id = (SELECT id FROM zz.pf_o WHERE label = '$1')" >/dev/null; fi
}
refund_of() { q "SELECT r.id FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id WHERE a.reference = '$1' ORDER BY r.created_at LIMIT 1"; }
admin_sql() { echo "SELECT public.admin_refund_transition((SELECT u_admin FROM zz.pf), '$1', '$2', '$3')->>'status';"; }

# ----- Scenario 1: two workers take the same approved refund ------------------------------------------------------------------------------
make_paid F1 pa dx-test-rconc-0001 cancel
R1=$(refund_of dx-test-rconc-0001)
q "$(admin_sql "$R1" approve '' | tr -d '\n')" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.claim_refund_for_submission('$R1')->>'amount_minor';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
SELECT COALESCE(public.claim_refund_for_submission('$R1')->>'amount_minor', 'nothing');
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the first worker got the refund (100000 pesewas)" "$(grep -q '^100000$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-100)"
check "scenario 1: the second worker got nothing, and did not wait for the first" "$(grep -q '^nothing$' "$B_OUT" && [ "$B_MS" -lt 1500 ] && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-100) ${B_MS} ms"
check "scenario 1: the refund is submitting, once" "$([ "$(q "SELECT status FROM public.order_refunds WHERE id = '$R1'")" = "submitting" ] && echo true || echo false)" ""

# ----- Scenario 4 (same refund): a refund being sent cannot be cancelled underneath the sender -----------------------------------------------
make_paid F4 pd dx-test-rconc-0004 cancel
R4=$(refund_of dx-test-rconc-0004)
q "$(admin_sql "$R4" approve '' | tr -d '\n')" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.claim_refund_for_submission('$R4')->>'amount_minor';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
DO \$\$ BEGIN PERFORM public.admin_refund_transition((SELECT u_admin FROM zz.pf), '$R4', 'cancel', 'changed my mind'); RAISE NOTICE 'cancelled'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'refused: %', SQLERRM; END \$\$;
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 4: the cancellation was refused because the refund was already being sent" "$(grep -q 'refused: A refund that is submitting cannot be cancelled' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 4: the refund is submitting, not cancelled" "$([ "$(q "SELECT status FROM public.order_refunds WHERE id = '$R4'")" = "submitting" ] && echo true || echo false)" ""

# ----- Scenario 2: the provider's notification and an administrator's confirmation at the same moment ---------------------------------------------
make_paid F2 pb dx-test-rconc-0002 cancel
R2=$(refund_of dx-test-rconc-0002)
q "$(admin_sql "$R2" approve '' | tr -d '\n')" >/dev/null
$P -c "SELECT public.claim_refund_for_submission('$R2')" >/dev/null
$P -c "SELECT public.record_refund_submission('$R2', 'rf-conc-2', 'pending')" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.apply_refund_event('paystack', 'test', 'dx-test-rconc-0002', 'refund.processed', 'rf-conc-2', 100000)->>'outcome';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(admin_sql "$R2" confirm_refunded 'Confirmed in the dashboard at the same moment')
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 2: the notification completed the refund" "$(grep -q '^succeeded$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-100)"
check "scenario 2: the confirmation waited for it (at least 1.5 s) and changed nothing more" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms / $(tr '\n' ' ' < "$B_OUT" | cut -c1-100)"
check "scenario 2: one completion: one log entry, one notification per recipient, the order refunded once" "$([ "$(q "SELECT (SELECT count(*) FROM public.order_payment_log WHERE order_id = (SELECT id FROM zz.pf_o WHERE label = 'F2') AND kind = 'refund_succeeded') || '/' || (SELECT count(*) = count(DISTINCT user_id) FROM public.notifications WHERE title = 'Refund sent' AND metadata->>'order_id' = (SELECT id::text FROM zz.pf_o WHERE label = 'F2')) || '/' || (SELECT payment_status FROM public.orders WHERE id = (SELECT id FROM zz.pf_o WHERE label = 'F2'))")" = "1/true/refunded" ] && echo true || echo false)" ""

# ----- Scenario 3: two refund requests for the same payment at once --------------------------------------------------------------------------
make_paid F3 pc dx-test-rconc-0003 keep
ATT=$(q "SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-rconc-0003'")
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public._request_refund('$ATT', 70000, 'amendment_reduction', 'conc:one', NULL, NULL) IS NOT NULL;
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
DO \$\$ BEGIN PERFORM public._request_refund('$ATT', 70000, 'amendment_reduction', 'conc:two', NULL, NULL); RAISE NOTICE 'accepted'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'refused: %', SQLERRM; END \$\$;
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 3: the second request waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 3: the second request was refused: together they would exceed the payment" "$(grep -q 'refused: Refunds for this payment cannot add up to more' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 3: only 70000 pesewas of the 100000 are refunded" "$([ "$(q "SELECT COALESCE(sum(amount_minor), 0) FROM public.order_refunds WHERE attempt_id = '$ATT' AND status <> 'cancelled'")" = "70000" ] && echo true || echo false)" ""
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public._request_refund('$ATT', 10000, 'manual', 'conc:same', NULL, NULL) IS NOT NULL;
SELECT pg_sleep(3);
COMMIT;
SQL
) &
A_PID=$!
sleep 1
( $P > "$B_OUT" 2>&1 <<SQL
SELECT public._request_refund('$ATT', 10000, 'manual', 'conc:same', NULL, NULL) IS NOT NULL;
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: two requests with the same source make one refund" "$([ "$(q "SELECT count(*) FROM public.order_refunds WHERE source_key = 'conc:same'")" = "1" ] && echo true || echo false)" ""

$P -c "UPDATE public.payments_settings SET online_enabled = FALSE" >/dev/null
exit $fail
