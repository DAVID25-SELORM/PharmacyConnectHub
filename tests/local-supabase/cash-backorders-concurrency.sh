#!/bin/bash
# Cash-order back-orders under concurrency, with real overlapping database sessions.
#
#   1. Two people confirm the same shipment's cash at the same moment: exactly ONE collection; the second call waits and reports a
#      replay.
#   2. The main delivery is confirmed while a back-order shipment is dispatched, at the same moment: whichever goes second, the
#      order ends unpaid with exactly ONE main collection (never marked paid with a shipment unpaid), and the order total rises once.
#   3. The main delivery and the last shipment are confirmed at the same moment: both collections exist and the order ends PAID
#      (neither call can leave it unpaid by not seeing the other).
#
# Run on the local Docker stack after setup.sql, the migrations through 20261105120000 and the production guard and stock
# fixtures (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in confirm_cash_collection; scenario 3 must then fail (the unique index
# alone still keeps scenario 1 to one collection, but the order can be left unpaid).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.cc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('CC A'), ('CC B'), ('CC C')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.cc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM public.products WHERE name='CC A') pa,
  (SELECT id FROM public.products WHERE name='CC B') pb,
  (SELECT id FROM public.products WHERE name='CC C') pc;
CREATE TABLE zz.cc_o(label TEXT PRIMARY KEY, id UUID);
CREATE TABLE zz.cc_s(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.cc)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.cc), 'role', 'authenticated')::text, false);"; }

# A cash order of ten units at 100 (1000), four back-ordered (main 600, shipment 400). $3 says how far it gets:
#   delivered  = main delivered, shipment prepared and packed (not yet dispatched)
#   shipped    = main delivered, shipment dispatched and delivered
make_order() { # $1 label, $2 product col, $3 stage
$P <<SQL >/dev/null
$(as_sql u_wo)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cc), (SELECT good FROM zz.cc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.cc), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cc)::text, 'cod'));
INSERT INTO zz.cc_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
SELECT public.propose_partial_fulfilment((SELECT id FROM zz.cc_o WHERE label = '$1'), 'short',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cc_o WHERE label = '$1') LIMIT 1), 'supplied_qty', 6, 'stock_treatment', 'release')), gen_random_uuid());
$(as_sql u_po)
SELECT public.respond_to_amendment((SELECT a.id FROM public.order_amendments a WHERE a.order_id = (SELECT id FROM zz.cc_o WHERE label = '$1')), 'accept_backorder', NULL);
$(as_sql u_wo)
UPDATE public.orders SET status = 'picking' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
UPDATE public.orders SET status = 'packed' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
UPDATE public.orders SET status = 'dispatched' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
UPDATE public.orders SET status = 'delivered' WHERE id = (SELECT id FROM zz.cc_o WHERE label = '$1');
INSERT INTO zz.cc_s SELECT '$1', (public.create_backorder_shipment((SELECT id FROM zz.cc_o WHERE label = '$1'),
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.cc_o WHERE label = '$1') LIMIT 1), 'quantity', 4)), NULL, gen_random_uuid())->>'shipment_id')::uuid;
SELECT public.advance_backorder_shipment((SELECT id FROM zz.cc_s WHERE label = '$1'), 'packed');
SQL
if [ "$3" = "shipped" ]; then
$P <<SQL >/dev/null
$(as_sql u_wo)
SELECT public.advance_backorder_shipment((SELECT id FROM zz.cc_s WHERE label = '$1'), 'dispatched');
SELECT public.advance_backorder_shipment((SELECT id FROM zz.cc_s WHERE label = '$1'), 'delivered');
SQL
fi
}
make_order K1 pa shipped
make_order K2 pb packed
make_order K3 pc shipped

collect_sql() { # $1 who, $2 label, $3 'main' or 'ship'
if [ "$3" = "main" ]; then portion="NULL"; else portion="(SELECT id FROM zz.cc_s WHERE label = '$2')"; fi
echo "$(as_sql $1)
SELECT public.confirm_cash_collection((SELECT id FROM zz.cc_o WHERE label = '$2'), $portion)->>'replayed';"
}
state() { q "SELECT o.payment_status || '/' || (SELECT count(*) FROM public.order_collections c WHERE c.order_id = o.id) || '/' || o.effective_total_ghs FROM public.orders o WHERE o.id = (SELECT id FROM zz.cc_o WHERE label = '$1')"; }

# ----- Scenario 1: the same shipment confirmed twice at once ---------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(collect_sql u_wo K1 ship)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(collect_sql u_wm K1 ship)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second confirmation waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first was recorded (replayed = false)" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 1: the second was a replay (replayed = true)" "$(grep -q '^true$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 1: exactly one collection of 400 for the shipment" "$([ "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.order_collections WHERE shipment_id = (SELECT id FROM zz.cc_s WHERE label = 'K1')")" = "1/400.00" ] && echo true || echo false)" ""
check "scenario 1: the order is still unpaid (the main delivery is not collected)" "$([ "$(state K1)" = "unpaid/1/1000.00" ] && echo true || echo false)" "$(state K1)"

# ----- Scenario 2: main confirmed while the shipment is dispatched -------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_sql u_wo)
SELECT public.advance_backorder_shipment((SELECT id FROM zz.cc_s WHERE label = 'K2'), 'dispatched')->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(collect_sql u_wm K2 main)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the dispatch went through" "$(grep -q '^dispatched$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 2: the main delivery was collected (replayed = false)" "$(grep -q '^false$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 2: the order is unpaid with ONE collection (600) and the total raised once to 1000" "$([ "$(state K2)" = "unpaid/1/1000.00" ] && echo true || echo false)" "$(state K2)"
check "scenario 2: the main collection is for the main delivery only (600)" "$([ "$(q "SELECT amount_ghs FROM public.order_collections WHERE order_id = (SELECT id FROM zz.cc_o WHERE label = 'K2') AND shipment_id IS NULL")" = "600.00" ] && echo true || echo false)" ""

# ----- Scenario 3: main and last shipment confirmed at once -----------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(collect_sql u_wo K3 main)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(collect_sql u_wm K3 ship)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: both collections were recorded" "$(grep -q '^false$' "$A_OUT" && grep -q '^false$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-60) / $(tr '\n' ' ' < "$B_OUT" | cut -c1-60)"
check "scenario 3: the order ends PAID with two collections (600 + 400)" "$([ "$(state K3)" = "paid/2/1000.00" ] && echo true || echo false)" "$(state K3)"

exit $fail
