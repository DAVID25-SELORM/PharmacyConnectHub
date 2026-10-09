#!/bin/bash
# Back-order shipments under concurrency, with real overlapping database sessions.
#
#   1. The same shipment is dispatched by two sessions at the same moment: exactly ONE invoice entry and ONE stock deduction;
#      the second call waits for the first and then reports a replay.
#   2. Two different shipments are dispatched at the same moment. Each fits the customer's credit limit on its own, together
#      they do not: exactly ONE goes out, the other is refused at the limit (the credit-line lock serialises the checks).
#   3. A shipment is prepared while the remaining back-order is cancelled at the same moment: units shipped + planned +
#      cancelled never exceed the back-ordered quantity.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261102120000 and the production guard and stock
# fixtures (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in advance_backorder_shipment (and its status re-check) and the
# credit-line lock; scenarios 1 and 2 must then fail.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.cb;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', p, 1000, true FROM zz.b, (VALUES ('CB A', 100), ('CB B', 50)) v(n, p) WHERE name='Alpha Wholesale';
CREATE TABLE zz.cb AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='CB A') pa,
  (SELECT id FROM public.products WHERE name='CB B') pb;
CREATE TABLE zz.cb_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.cb ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 1000000, active = true, status = 'active';
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.cb)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.cb), 'role', 'authenticated')::text, false);"; }

# X1: CB A x10 (1000) supply 5, back-order 5.   X2: CB B x20 (1000) supply 10, back-order 10.
make_order() { # $1 label, $2 product col, $3 qty, $4 supplied
$P <<SQL >/dev/null
$(as_sql u_wo)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cb), (SELECT good FROM zz.cb),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.cb), 'quantity', $3, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cb)::text, 'credit'));
INSERT INTO zz.cb_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM zz.cb_o WHERE label = '$1');
CREATE TEMP TABLE r AS SELECT public.propose_partial_fulfilment((SELECT id FROM zz.cb_o WHERE label = '$1'), 'Supplier short',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cb_o WHERE label = '$1') LIMIT 1), 'supplied_qty', $4, 'stock_treatment', 'write_off')),
  gen_random_uuid())->>'amendment_id' AS a;
$(as_sql u_po)
SELECT public.respond_to_amendment((SELECT a::uuid FROM r), 'accept_backorder', NULL);
$(as_sql u_wo)
UPDATE public.orders SET status = 'picking' WHERE id = (SELECT id FROM zz.cb_o WHERE label = '$1');
UPDATE public.orders SET status = 'packed' WHERE id = (SELECT id FROM zz.cb_o WHERE label = '$1');
UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = (SELECT id FROM zz.cb_o WHERE label = '$1');
UPDATE public.orders SET status = 'dispatched' WHERE id = (SELECT id FROM zz.cb_o WHERE label = '$1');
SQL
}
make_order X1 pa 10 5
make_order X2 pb 20 10

new_shipment() { # $1 order label, $2 qty ; prints the shipment id packed and ready
$P <<SQL | tail -1
$(as_sql u_wo)
SELECT public.create_backorder_shipment((SELECT id FROM zz.cb_o WHERE label = '$1'),
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cb_o WHERE label = '$1') LIMIT 1), 'quantity', $2)),
  NULL, gen_random_uuid())->>'shipment_id';
SQL
}
pack() { $P >/dev/null <<SQL
$(as_sql u_wo)
SELECT public.advance_backorder_shipment('$1', 'packed');
SQL
}
dispatch_sql() { echo "$(as_sql u_wo)
SELECT public.advance_backorder_shipment('$1', 'dispatched')->>'replayed';"; }

# ----- Scenario 1: the same shipment dispatched twice at once ---------------------------------------------------------------
S1=$(new_shipment X1 3); pack "$S1"
STOCK_A0=$(q "SELECT stock FROM public.products WHERE name = 'CB A'")
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(dispatch_sql "$S1")
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(dispatch_sql "$S1")
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second dispatch waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first call dispatched (replayed = false)" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 1: the second call was a replay (replayed = true)" "$(grep -q '^true$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT")"
check "scenario 1: exactly one invoice entry of 300" "$([ "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs),0) FROM public.credit_ledger_entries WHERE shipment_id = '$S1'")" = "1/300.00" ] && echo true || echo false)" "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs),0) FROM public.credit_ledger_entries WHERE shipment_id = '$S1'")"
check "scenario 1: stock deducted exactly once (-3)" "$([ "$(q "SELECT stock FROM public.products WHERE name = 'CB A'")" = "$((STOCK_A0 - 3))" ] && echo true || echo false)" "was $STOCK_A0, now $(q "SELECT stock FROM public.products WHERE name = 'CB A'")"
check "scenario 1: one stock movement and one inventory movement" "$([ "$(q "SELECT (SELECT count(*) FROM public.order_stock_movements WHERE shipment_id = '$S1') || '/' || (SELECT count(*) FROM public.inventory_movements WHERE request_id = '$S1')")" = "1/1" ] && echo true || echo false)" ""

# ----- Scenario 2: two shipments, each within the limit alone, not together ------------------------------------------------------
S2=$(new_shipment X1 2); pack "$S2"      # 200
S3=$(new_shipment X2 6); pack "$S3"      # 300
$P >/dev/null <<SQL
UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = public.credit_exposure(wholesaler_id, pharmacy_id) + 350 WHERE wholesaler_id = (SELECT alpha FROM zz.cb);
SQL
LIMIT=$(q "SELECT credit_limit_ghs FROM public.wholesaler_credit_terms WHERE wholesaler_id = (SELECT alpha FROM zz.cb)")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(dispatch_sql "$S2")
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(dispatch_sql "$S3")
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the first shipment (200) went out" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 2: the second (300) was refused at the credit limit" "$(grep -q 'above its credit limit' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 2: exactly one of the two is dispatched" "$([ "$(q "SELECT count(*) FROM public.order_shipments WHERE id IN ('$S2', '$S3') AND status = 'dispatched'")" = "1" ] && echo true || echo false)" ""
check "scenario 2: the refused shipment is still packed and has no invoice entry" "$([ "$(q "SELECT (SELECT status FROM public.order_shipments WHERE id = '$S3') || '/' || (SELECT count(*) FROM public.credit_ledger_entries WHERE shipment_id = '$S3')")" = "packed/0" ] && echo true || echo false)" ""
check "scenario 2: the customer's exposure never passed the limit" "$([ "$(q "SELECT (public.credit_exposure(wholesaler_id, pharmacy_id) <= credit_limit_ghs)::text FROM public.wholesaler_credit_terms WHERE wholesaler_id = (SELECT alpha FROM zz.cb)")" = "true" ] && echo true || echo false)" "limit $LIMIT"

# ----- Scenario 3: preparing a shipment while the rest is cancelled ---------------------------------------------------------------
$P >/dev/null <<SQL
UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = 1000000 WHERE wholesaler_id = (SELECT alpha FROM zz.cb);
SQL
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_sql u_wo)
SELECT public.create_backorder_shipment((SELECT id FROM zz.cb_o WHERE label = 'X2'),
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cb_o WHERE label = 'X2') LIMIT 1), 'quantity', 4)), NULL, gen_random_uuid())->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_wo)
SELECT public.cancel_backorder_remaining((SELECT id FROM zz.cb_o WHERE label = 'X2'), 'giving up the rest')->>'cancelled_units';
SQL
) &
B_PID=$!
wait $A_PID $B_PID
ITEM=$(q "SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cb_o WHERE label = 'X2') LIMIT 1")
check "scenario 3: the shipment of 4 was prepared" "$(grep -q '^pending$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 3: the cancellation closed only what was left (10 - 6 sent - 4 planned = 0, so nothing)" "$(grep -q 'Nothing is waiting' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 3: shipped + planned + cancelled never exceeds the back-ordered quantity" "$([ "$(q "SELECT (public.order_item_shipment_qty('$ITEM', FALSE) + COALESCE((SELECT SUM(quantity) FROM public.order_backorder_cancellations WHERE order_item_id = '$ITEM'), 0) <= public.order_item_backordered_qty('$ITEM'))::text")" = "true" ] && echo true || echo false)" ""

exit $fail
