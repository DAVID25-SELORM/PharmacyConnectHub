#!/bin/bash
# Starting an online payment under concurrency, with real overlapping database sessions.
#
#   1. Two people on the paying side start a payment for the same order at the same moment: they are served one after the other;
#      exactly ONE attempt stays open (the earlier, unanswered one is closed as expired); the database never holds two open attempts.
#   2. A payment is being started while the customer's earlier payment is reported as paid: the report waits for the start, then
#      pays the order once; the order is never paid twice, and no money is lost.
#   3. The order is cancelled while a payment is being started: whichever goes first, a payment is never started for a cancelled
#      order (the start that comes second is refused, and creates nothing).
#
# Run on the local Docker stack after setup.sql, the migrations through 20261107120000, and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in begin_order_payment; scenarios 1 and 3 must then fail.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PC A'), ('PC B'), ('PC C')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PC A') pa,
  (SELECT id FROM public.products WHERE name='PC B') pb,
  (SELECT id FROM public.products WHERE name='PC C') pc;
CREATE TABLE zz.pc_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test';
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pc)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pc), 'role', 'authenticated')::text, false);"; }

make_order() { # $1 label, $2 product column; ten units at 100 = 1000, an online order awaiting payment
$P <<SQL >/dev/null
$(as_sql u_po)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.pc), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pc)::text, 'pay_now'));
INSERT INTO zz.pc_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
SQL
}
begin_sql() { # $1 order label, $2 reference
echo "SELECT (public.begin_order_payment((SELECT u_po FROM zz.pc), (SELECT id FROM zz.pc_o WHERE label = '$1'), 'paystack', 'test', '$2')->>'reused');"
}
begin_error_sql() { # same, but an error is an answer, not a failure of the script
echo "DO \$\$ BEGIN PERFORM public.begin_order_payment((SELECT u_po FROM zz.pc), (SELECT id FROM zz.pc_o WHERE label = '$1'), 'paystack', 'test', '$2'); RAISE NOTICE 'started'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'refused: %', SQLERRM; END \$\$;"
}
make_order M1 pa; make_order M2 pb; make_order M3 pc

# ----- Scenario 1: two people start the same payment at once --------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(begin_sql M1 dx-test-conc-0001)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(begin_sql M1 dx-test-conc-0002)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second start waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: both were served (neither failed)" "$(grep -q '^false$' "$A_OUT" && grep -q '^false$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-100) / $(tr '\n' ' ' < "$B_OUT" | cut -c1-100)"
check "scenario 1: exactly one open attempt; the earlier one was closed" "$([ "$(q "SELECT count(*) FILTER (WHERE status = 'initiated') || '/' || count(*) FILTER (WHERE status = 'expired') FROM public.order_payment_attempts WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = 'M1')")" = "1/1" ] && echo true || echo false)" ""
check "scenario 1: the open one is the later start" "$([ "$(q "SELECT reference FROM public.order_payment_attempts WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = 'M1') AND status = 'initiated'")" = "dx-test-conc-0002" ] && echo true || echo false)" ""

# ----- Scenario 2: a start racing the report of an earlier payment ------------------------------------------------------------------
$P -c "$(begin_sql M2 dx-test-conc-0003 | tr -d '\n')" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(begin_sql M2 dx-test-conc-0004)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
SELECT public.apply_payment_result('paystack', 'test', 'dx-test-conc-0003', 'success', 100000, 'GHS', 'tx-conc-3', 'card', 1500, 'webhook')->>'outcome';
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 2: the payment report waited for the start (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 2: the earlier payment (on the closed attempt) was applied" "$(grep -q '^applied$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-120)"
check "scenario 2: the order is paid once, by the first attempt; the new attempt is simply open" "$([ "$(q "SELECT (SELECT payment_status FROM public.orders WHERE id = (SELECT id FROM zz.pc_o WHERE label = 'M2')) || '/' || count(*) FILTER (WHERE status = 'succeeded' AND NOT refund_required) || '/' || count(*) FILTER (WHERE status = 'initiated') FROM public.order_payment_attempts WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = 'M2')")" = "paid/1/1" ] && echo true || echo false)" ""

# ----- Scenario 3: a cancellation racing the start of a payment ----------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'window ended' WHERE id = (SELECT id FROM zz.pc_o WHERE label = 'M3');
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(begin_error_sql M3 dx-test-conc-0005)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: the start that came second was refused (the order was cancelled)" "$(grep -q 'refused: This order was cancelled' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 3: nothing was created for the cancelled order" "$([ "$(q "SELECT count(*) FROM public.order_payment_attempts WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = 'M3')")" = "0" ] && echo true || echo false)" ""

$P -c "UPDATE public.payments_settings SET online_enabled = FALSE" >/dev/null
exit $fail
