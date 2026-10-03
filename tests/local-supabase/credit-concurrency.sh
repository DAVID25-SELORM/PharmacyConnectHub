#!/bin/bash
# Credit checks must be atomic: two simultaneous credit orders must not both pass a limit check that
# only has room for one of them.
#
# Scenario: a 5,000 credit limit and two GHS 4,000 orders placed at the same moment.
#   Session A opens a transaction, places its order (taking the credit row lock) and holds it open
#   for a few seconds before committing. Session B starts while A is still open. B must WAIT for A,
#   then see A's order in the ledger and be refused. Exactly one order may exist at the end.
#   If the check were not atomic, B would see no exposure, succeed, and 8,000 would be on a 5,000 limit.
#
# Run after the fixtures are loaded (see README: nuke.sql / setup.sql / pw.sql) and migrations are
# applied through 20261016100000_credit_foundation.sql. Local Docker stack only.
set -eu
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
DB=${DB_NAME:-postgres}
P="docker exec -i $C psql -U postgres -d $DB -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.cc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 10000, true FROM zz.b, (VALUES ('CC Item A'), ('CC Item B')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.cc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM public.products WHERE name='CC Item A') p_item_a,
  (SELECT id FROM public.products WHERE name='CC Item B') p_item_b;
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 5000, 30 FROM zz.cc
ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 5000, active = true, status = 'active';
SQL

order_sql() {
  echo "SELECT public.create_marketplace_orders((SELECT u_po FROM zz.cc), (SELECT good FROM zz.cc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $1 FROM zz.cc), 'quantity', 40, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.cc)::text, 'credit'));"
}

A_OUT=$(mktemp); B_OUT=$(mktemp)
T_OUT=$(mktemp)
trap 'rm -f "$A_OUT" "$B_OUT" "$T_OUT"' EXIT

# Session A: place the order, then hold the transaction open for 5 seconds before committing.
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(order_sql p_item_a)
SELECT pg_sleep(5);
COMMIT;
SQL
) &
A_PID=$!

sleep 1.5   # A now holds the credit row lock, uncommitted

# Session B: a DIFFERENT product (so the two orders share no product row lock), started while A is still open.
# Only the credit-relationship lock can make it wait. It should block until A commits, then be refused.
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL || true
$(order_sql p_item_b)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!

wait $A_PID
wait $B_PID
B_MS=$(cat "$T_OUT" 2>/dev/null || echo 0)

orders=$($P -c "SELECT count(*) FROM public.orders WHERE is_credit_order AND status <> 'cancelled' AND wholesaler_id = (SELECT alpha FROM zz.cc)")
exposure=$($P -c "SELECT public.credit_exposure((SELECT alpha FROM zz.cc), (SELECT good FROM zz.cc))")
a_ok=$(grep -c "^1$" "$A_OUT" || true)
b_err=$(grep -c "would exceed your approved limit" "$B_OUT" || true)
b_ok=$(grep -c "^1$" "$B_OUT" || true)

check "session A's order succeeded" "$([ "$a_ok" -ge 1 ] && echo true || echo false)" "$(cat "$A_OUT")"
check "session B was refused for exceeding the limit" "$([ "$b_err" -ge 1 ] && echo true || echo false)" "$(cat "$B_OUT")"
check "session B did not also succeed" "$([ "$b_ok" -eq 0 ] && echo true || echo false)" "$(cat "$B_OUT")"
check "exactly one credit order exists" "$([ "$orders" = "1" ] && echo true || echo false)" "orders=$orders"
check "exposure is 4000, not 8000 (limit 5000)" "$([ "${exposure%.*}" = "4000" ] && echo true || echo false)" "exposure=$exposure"
check "session B had to wait for A (>= 3000 ms)" "$([ "${B_MS:-0}" -ge 3000 ] && echo true || echo false)" "elapsed=${B_MS}ms"

rm -f "$A_OUT" "$B_OUT" "$T_OUT"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
