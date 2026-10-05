#!/bin/bash
# A one-time credit override must be usable by exactly ONE order, even when two over-limit orders
# arrive at the same moment.
#
# Scenario: limit 5,000, 4,000 already owed, a one-time override of up to 1,500, and two GHS 1,200
# orders placed together (each would take the exposure above the limit, so each needs the override).
#   Session A opens a transaction, places its order (consuming the override) and holds the
#   transaction open for a few seconds. Session B starts while A is still open, on a DIFFERENT
#   product so the only thing the two orders share is the credit line. B must WAIT, then find the
#   override already used and be refused. Exactly one more credit order may exist.
#   If the override were not locked, both would use it and exposure would reach 6,400.
#
# Run on the local Docker stack after fixtures are loaded and migrations applied through
# 20261019100000_credit_override.sql. Negative control: remove the `FOR UPDATE` locks on the credit
# line AND on the override lookup in create_marketplace_orders; this script must then FAIL.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.oc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 10000, true FROM zz.b, (VALUES ('OC Item A'), ('OC Item B'), ('OC Item C')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.oc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='OC Item A') p_a,
  (SELECT id FROM public.products WHERE name='OC Item B') p_b,
  (SELECT id FROM public.products WHERE name='OC Item C') p_c;
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
DELETE FROM public.credit_overrides;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 5000, 30 FROM zz.oc
ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 5000, active = true, status = 'active';
SQL

# Baseline: 4,000 already owed (a normal credit order, within the limit).
$P <<'SQL' >/dev/null
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.oc), (SELECT good FROM zz.oc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p_c FROM zz.oc), 'quantity', 40, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.oc)::text, 'credit'));
-- The wholesaler owner approves ONE order of up to 1,500 above the limit.
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.oc)::text, false);
SELECT public.grant_credit_override((SELECT alpha FROM zz.oc), (SELECT good FROM zz.oc), 1500, 7, 'Seasonal stock-up approved');
SQL

order_sql() {
  echo "SELECT public.create_marketplace_orders((SELECT u_po FROM zz.oc), (SELECT good FROM zz.oc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $1 FROM zz.oc), 'quantity', 12, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.oc)::text, 'credit'));"
}

A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)

# Session A: place its 1,200 order on the override, then hold the transaction open for 5 seconds.
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(order_sql p_a)
SELECT pg_sleep(5);
COMMIT;
SQL
) &
A_PID=$!

sleep 1.5   # A now holds the credit line and the override, uncommitted

# Session B: the same size order on a DIFFERENT product. Only the credit line is shared.
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(order_sql p_b)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!

wait $A_PID
wait $B_PID
B_MS=$(cat "$T_OUT" 2>/dev/null || echo 0)

orders=$($P -c "SELECT count(*) FROM public.orders WHERE is_credit_order AND status <> 'cancelled' AND wholesaler_id = (SELECT alpha FROM zz.oc)")
exposure=$($P -c "SELECT public.credit_exposure((SELECT alpha FROM zz.oc), (SELECT good FROM zz.oc))")
used=$($P -c "SELECT count(*) FROM public.credit_overrides WHERE status = 'used'")
used_audit=$($P -c "SELECT count(*) FROM public.audit_logs WHERE activity = 'Credit override used'")
a_ok=$(grep -c "^1$" "$A_OUT")
b_err=$(grep -c "would exceed your approved limit" "$B_OUT")
b_ok=$(grep -c "^1$" "$B_OUT")

check "session A's order used the override and succeeded" "$([ "$a_ok" -ge 1 ] && echo true || echo false)" "$(cat "$A_OUT")"
check "session B was refused: the override was already used" "$([ "$b_err" -ge 1 ] && echo true || echo false)" "$(cat "$B_OUT")"
check "session B did not also succeed" "$([ "$b_ok" -eq 0 ] && echo true || echo false)" "$(cat "$B_OUT")"
check "exactly two credit orders exist (the 4,000 baseline + A's 1,200)" "$([ "$orders" = "2" ] && echo true || echo false)" "orders=$orders"
check "exposure is 5,200, not 6,400" "$([ "${exposure%.*}" = "5200" ] && echo true || echo false)" "exposure=$exposure"
check "the override was used exactly once" "$([ "$used" = "1" ] && [ "$used_audit" = "1" ] && echo true || echo false)" "used=$used audit=$used_audit"
check "session B had to wait for A (>= 3000 ms)" "$([ "${B_MS:-0}" -ge 3000 ] && echo true || echo false)" "elapsed=${B_MS}ms"

rm -f "$A_OUT" "$B_OUT" "$T_OUT"
[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
