#!/bin/bash
# Amendments on an order paid online, under concurrency, with real overlapping database sessions.
#
#   An order was paid (1000.00), its price rose to 110 (1100.00) and the pharmacy started an extra payment of 100.00. A further price change to 120 is accepted at the
#   very moment that extra payment is verified. Whichever reaches the order first, the result must be consistent and no money lost:
#   1. The payment is recorded first (it holds the order): it is APPLIED; the further increase then leaves 100.00 due.
#   2. The price change is accepted first (it holds the order): the extra payment, which no longer matches what is due, is FLAGGED and refunded; 200.00 is due.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261110120000, and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Both outcomes are correct; what matters is that no money is lost or counted twice whichever session reaches the order first (the order lock decides).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pj;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PJ A'), ('PJ B')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pj AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PJ A') pa,
  (SELECT id FROM public.products WHERE name='PJ B') pb;
CREATE TABLE zz.pj_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', auto_refunds = FALSE;
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pj)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pj), 'role', 'authenticated')::text, false);"; }
oid() { echo "(SELECT id FROM zz.pj_o WHERE label = '$1')"; }

# $1 label, $2 product column, $3 base reference. Paid (1000), accepted, price raised to 110 and accepted (1100), an extra payment of 100.00 STARTED (attempt $3-top),
# and a FURTHER price change to 120 PROPOSED but not yet accepted.
make_ready() {
$P <<SQL >/dev/null
$(as_sql u_po)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pj), (SELECT good FROM zz.pj),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.pj), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pj)::text, 'pay_now'));
INSERT INTO zz.pj_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
SELECT o.id, 'paystack', 'test', '$3', o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = $(oid $1);
SELECT public.apply_payment_result('paystack', 'test', '$3', 'success', 100000, 'GHS', 'tx-$3', 'card', 1500, 'verify')->>'outcome';
UPDATE public.orders SET status = 'accepted' WHERE id = $(oid $1);
$(as_sql u_wo)
SELECT public.propose_price_amendment($(oid $1), 'Supplier price revised',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = $(oid $1)), 'unit_price_ghs', 110)), gen_random_uuid());
$(as_sql u_po)
SELECT public.respond_to_price_amendment((SELECT id FROM public.order_amendments WHERE order_id = $(oid $1) AND version = 1), 'accept', NULL);
SELECT public.begin_order_topup((SELECT u_po FROM zz.pj), $(oid $1), 'paystack', 'test', '$3-top');
$(as_sql u_wo)
SELECT public.propose_price_amendment($(oid $1), 'Supplier price revised again',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = $(oid $1)), 'unit_price_ghs', 120)), gen_random_uuid());
SQL
}
accept_sql() { echo "$(as_sql u_po)
SELECT 'accepted' FROM (SELECT public.respond_to_price_amendment((SELECT id FROM public.order_amendments WHERE order_id = $(oid $1) AND version = 2), 'accept', NULL)) x;"; }
apply_sql() { echo "SELECT public.apply_payment_result('paystack', 'test', '$1', 'success', 10000, 'GHS', 'tx-$1', 'card', 150, 'webhook')->>'outcome';"; }

# ----- Scenario 1: the extra payment holds the order; the further price change waits -------------------------------------------------------------
make_ready H1 pa dx-test-pjc-0001
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(apply_sql dx-test-pjc-0001-top)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(accept_sql H1)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the extra payment was applied" "$(grep -q '^applied$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-100)"
check "scenario 1: the price change waited for it (at least 1.5 s) and was then accepted" "$([ "$B_MS" -ge 1500 ] && grep -q '^accepted$' "$B_OUT" && echo true || echo false)" "${B_MS} ms / $(tr '\n' ' ' < "$B_OUT" | cut -c1-100)"
check "scenario 1: the order now costs 1200, 1100 is paid, 100.00 is due, and nothing was refunded" "$([ "$(q "SELECT COALESCE(effective_total_ghs, total_ghs) || '/' || public.order_topup_due_minor(id) || '/' || (SELECT count(*) FROM public.order_refunds r WHERE r.order_id = orders.id) FROM public.orders WHERE id = $(oid H1)")" = "1200.00/10000/0" ] && echo true || echo false)" "$(q "SELECT COALESCE(effective_total_ghs, total_ghs) || '/' || public.order_topup_due_minor(id) FROM public.orders WHERE id = $(oid H1)")"

# ----- Scenario 2: the further price change holds the order; the extra payment waits --------------------------------------------------------------
make_ready H2 pb dx-test-pjc-0002
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(accept_sql H2)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(apply_sql dx-test-pjc-0002-top)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 2: the price change was accepted first" "$(grep -q '^accepted$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-100)"
check "scenario 2: the extra payment waited (at least 1.5 s) and, no longer matching what is due, was FLAGGED" "$([ "$B_MS" -ge 1500 ] && grep -q '^flagged$' "$B_OUT" && echo true || echo false)" "${B_MS} ms / $(tr '\n' ' ' < "$B_OUT" | cut -c1-100)"
check "scenario 2: 200.00 is due, and the money of the flagged extra payment is on a refund request" "$([ "$(q "SELECT public.order_topup_due_minor($(oid H2)) || '/' || (SELECT count(*) FROM public.order_refunds r JOIN public.order_payment_attempts a ON a.id = r.attempt_id WHERE a.reference = 'dx-test-pjc-0002-top' AND r.status = 'requested' AND r.amount_minor = 10000)")" = "20000/1" ] && echo true || echo false)" "$(q "SELECT public.order_topup_due_minor($(oid H2))")"

$P -c "UPDATE public.payments_settings SET online_enabled = FALSE" >/dev/null
exit $fail
