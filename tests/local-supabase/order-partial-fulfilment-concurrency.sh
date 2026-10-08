#!/bin/bash
# Partial fulfilment under concurrency, with real overlapping database sessions.
#
#   1. Two pharmacy users accept the same proposal at the same moment: exactly ONE credit note and ONE stock release; the
#      second call waits for the first and then reports a replay.
#   2. A proposal is accepted while the wholesaler cancels the order at the same moment: the cancel waits for the
#      acceptance, then restores only what is still deducted, so stock ends where it started and the ledger nets to zero.
#   3. A proposal is made while the wholesaler tries to dispatch at the same moment: the dispatch waits, then is refused.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261030120000 and the production guard and
# stock fixtures (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in respond_to_amendment (and the replay check); scenario 1
# must then fail.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pcx;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PCX 1'), ('PCX 2'), ('PCX 3')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pcx AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PCX 1') p1,
  (SELECT id FROM public.products WHERE name='PCX 2') p2,
  (SELECT id FROM public.products WHERE name='PCX 3') p3;
CREATE TABLE zz.pcx_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.pcx ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 1000000, active = true, status = 'active';
SQL

# One accepted credit order per scenario, each on its own product (10 units at 100 = 1,000).
for n in 1 2 3; do
$P <<SQL >/dev/null
SELECT set_config('request.jwt.claim.sub', (SELECT u_wo FROM zz.pcx)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_wo FROM zz.pcx), 'role', 'authenticated')::text, false);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pcx), (SELECT good FROM zz.pcx),
  jsonb_build_array(jsonb_build_object('productId', (SELECT p$n FROM zz.pcx), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pcx)::text, 'credit'));
INSERT INTO zz.pcx_o SELECT '$n', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '$n');
SQL
done

as_sql() { # $1 = user column in zz.pcx
  echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pcx)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pcx), 'role', 'authenticated')::text, false);"
}
propose_sql() { # $1 = order label, $2 = product column
  echo "$(as_sql u_wo)
SELECT public.propose_partial_fulfilment((SELECT id FROM zz.pcx_o WHERE label = '$1'), 'Concurrency test shortage',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.pcx_o WHERE label = '$1') LIMIT 1), 'supplied_qty', 6, 'stock_treatment', 'release')),
  gen_random_uuid())->>'amendment_id';"
}
stock_of() { $P -c "SELECT stock FROM public.products WHERE name = 'PCX $1'"; }

# ----- Scenario 1: two simultaneous acceptances -------------------------------------------------------------------------
A1=$($P <<SQL | tail -1
$(propose_sql 1 p1)
SQL
)
S1_BEFORE=$(stock_of 1)   # 990 after the checkout deduction
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_sql u_po)
SELECT public.respond_to_amendment('$A1', 'accept_cancel_remaining', 'first')->>'replayed';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_po)
SELECT public.respond_to_amendment('$A1', 'accept_cancel_remaining', 'second')->>'replayed';
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second acceptance waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first call applied it (replayed = false)" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 1: the second call was a replay (replayed = true)" "$(grep -q '^true$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT")"
check "scenario 1: exactly one credit note of 400" "$([ "$($P -c "SELECT count(*) || '/' || COALESCE(sum(amount_ghs),0) FROM public.credit_ledger_entries WHERE amendment_id = '$A1'")" = "1/400.00" ] && echo true || echo false)" "$($P -c "SELECT count(*) || '/' || COALESCE(sum(amount_ghs),0) FROM public.credit_ledger_entries WHERE amendment_id = '$A1'")"
check "scenario 1: stock released exactly once (+4)" "$([ "$(stock_of 1)" = "$((S1_BEFORE + 4))" ] && echo true || echo false)" "before $S1_BEFORE now $(stock_of 1)"
check "scenario 1: one stock movement and one inventory movement" "$([ "$($P -c "SELECT (SELECT count(*) FROM public.order_stock_movements WHERE amendment_id = '$A1') || '/' || (SELECT count(*) FROM public.inventory_movements WHERE request_id = '$A1')")" = "1/1" ] && echo true || echo false)" "$($P -c "SELECT (SELECT count(*) FROM public.order_stock_movements WHERE amendment_id = '$A1') || '/' || (SELECT count(*) FROM public.inventory_movements WHERE request_id = '$A1')")"

# ----- Scenario 2: acceptance racing a cancellation ---------------------------------------------------------------------
A2=$($P <<SQL | tail -1
$(propose_sql 2 p2)
SQL
)
S2_BEFORE=$(stock_of 2)   # 990
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_sql u_po)
SELECT public.respond_to_amendment('$A2', 'accept_cancel_remaining', NULL)->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_wo)
UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'race' WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '2');
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the acceptance was applied" "$(grep -q '^accepted$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 2: the cancellation succeeded afterwards" "$([ "$($P -c "SELECT status FROM public.orders WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '2')")" = "cancelled" ] && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT")"
check "scenario 2: stock ended where it started plus the 10 originally deducted (1000), restored once, never twice" "$([ "$(stock_of 2)" = "1000" ] && echo true || echo false)" "now $(stock_of 2), before $S2_BEFORE"
check "scenario 2: the order's ledger nets to zero (invoice, credit note, cancellation credit)" "$([ "$($P -c "SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) FROM public.credit_ledger_entries WHERE order_id = (SELECT id FROM zz.pcx_o WHERE label = '2')")" = "0.00" ] && echo true || echo false)" "$($P -c "SELECT SUM(CASE direction WHEN 'debit' THEN amount_ghs ELSE -amount_ghs END) FROM public.credit_ledger_entries WHERE order_id = (SELECT id FROM zz.pcx_o WHERE label = '2')")"

# ----- Scenario 3: proposal racing a dispatch -------------------------------------------------------------------------------
$P <<SQL >/dev/null
UPDATE public.orders SET status = 'packed' WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '3');
UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '3');
SQL
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(propose_sql 3 p3)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_wo)
UPDATE public.orders SET status = 'dispatched' WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '3');
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: the proposal was recorded" "$([ "$($P -c "SELECT count(*) FROM public.order_amendments WHERE order_id = (SELECT id FROM zz.pcx_o WHERE label = '3') AND status = 'proposed'")" = "1" ] && echo true || echo false)" ""
check "scenario 3: the dispatch that overlapped it was refused" "$(grep -q 'awaiting the pharmacy' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-120)"
check "scenario 3: the order did not move to dispatched" "$([ "$($P -c "SELECT status FROM public.orders WHERE id = (SELECT id FROM zz.pcx_o WHERE label = '3')")" = "ready_for_dispatch" ] && echo true || echo false)" ""

exit $fail
