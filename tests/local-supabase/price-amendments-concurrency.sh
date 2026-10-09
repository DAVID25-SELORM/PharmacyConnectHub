#!/bin/bash
# Price amendments under concurrency, with real overlapping database sessions.
#
#   1. Two people at the pharmacy approve the same price proposal at the same moment: exactly ONE debit note, ONE application;
#      the second call waits and reports a replay.
#   2. The pharmacy approves while the wholesaler withdraws, at the same moment: exactly one of them wins, and the proposal is
#      never both withdrawn and applied.
#   3. Two managers of the wholesaler propose on the same order at the same moment: exactly ONE proposal is open; the second
#      call waits and is refused.
#   4. Two price increases on two different orders of the same customer, approved at the same moment, that together exceed the
#      credit limit: exactly ONE is applied (the customer's credit line is locked while its limit is checked).
#
# Run on the local Docker stack after setup.sql, the migrations through 20261104120000 and the production guard and stock
# fixtures (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the credit line in respond_to_price_amendment; scenario 4 must then fail
# (both increases are applied); remove the `FOR UPDATE` on both the order row and the proposal row and scenario 1 fails
# (the second approval is no longer a replay; the proposal row's lock alone serialises scenarios 1 and 2).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PC A'), ('PC B'), ('PC C'), ('PC D'), ('PC E')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM public.products WHERE name='PC A') pa,
  (SELECT id FROM public.products WHERE name='PC B') pb,
  (SELECT id FROM public.products WHERE name='PC C') pc,
  (SELECT id FROM public.products WHERE name='PC D') pd,
  (SELECT id FROM public.products WHERE name='PC E') pe;
CREATE TABLE zz.pc_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.pc ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 1000000, active = true, status = 'active';
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pc)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pc), 'role', 'authenticated')::text, false);"; }

make_order() { # $1 label, $2 product column; ten units at 100 = 1000 on credit, left accepted
$P <<SQL >/dev/null
$(as_sql u_wo)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pc), (SELECT good FROM zz.pc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.pc), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pc)::text, 'credit'));
INSERT INTO zz.pc_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM zz.pc_o WHERE label = '$1');
SQL
}
make_order S1 pa
make_order S2 pb
make_order S3 pc
make_order S4A pd
make_order S4B pe

propose_sql() { # $1 who, $2 label, $3 new price
echo "$(as_sql $1)
SELECT public.propose_price_amendment((SELECT id FROM zz.pc_o WHERE label = '$2'), 'cost increase',
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = '$2') LIMIT 1), 'unit_price_ghs', $3)), gen_random_uuid())->>'amendment_id';"
}
new_proposal() { $P <<SQL | tail -1
$(propose_sql "$1" "$2" "$3")
SQL
}
accept_sql() { # $1 amendment, $2 who
echo "$(as_sql $2)
SELECT public.respond_to_price_amendment('$1', 'accept', NULL)->>'replayed';"
}

# ----- Scenario 1: the same proposal approved twice at once -----------------------------------------------------------------
A1=$(new_proposal u_wo S1 120)
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(accept_sql "$A1" u_po)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(accept_sql "$A1" u_po)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second approval waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first was applied (replayed = false)" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 1: the second was a replay (replayed = true)" "$(grep -q '^true$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 1: exactly one debit note of 200 (10 units x 20)" "$([ "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.credit_ledger_entries WHERE amendment_id = '$A1'")" = "1/200.00" ] && echo true || echo false)" ""
check "scenario 1: the order total is 1200, applied once" "$([ "$(q "SELECT effective_total_ghs FROM public.orders WHERE id = (SELECT id FROM zz.pc_o WHERE label = 'S1')")" = "1200.00" ] && echo true || echo false)" ""

# ----- Scenario 2: approval racing a withdrawal -------------------------------------------------------------------------------
A2=$(new_proposal u_wo S2 130)
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(accept_sql "$A2" u_po)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_wm)
SELECT public.withdraw_price_amendment('$A2', 'too late')->>'status';
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the approval won and the late withdrawal was refused" "$(grep -q 'has already been accepted' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 2: the proposal ends accepted with its one debit note, never withdrawn" "$([ "$(q "SELECT status || '/' || (SELECT count(*) FROM public.credit_ledger_entries WHERE amendment_id = '$A2') FROM public.order_amendments WHERE id = '$A2'")" = "accepted/1" ] && echo true || echo false)" ""

# ----- Scenario 3: two proposals at once ----------------------------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(propose_sql u_wo S3 140)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(propose_sql u_wm S3 150)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 3: the second proposal waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 3: the second was refused with the clear message" "$(grep -q 'A change is already awaiting a response on this order' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 3: exactly one open proposal" "$([ "$(q "SELECT count(*) FROM public.order_amendments WHERE order_id = (SELECT id FROM zz.pc_o WHERE label = 'S3') AND status IN ('proposed', 'clarification_requested')")" = "1" ] && echo true || echo false)" ""

# ----- Scenario 4: two increases that together exceed the credit limit ------------------------------------------------------------
# Each increase is 10 units x 10 = 100. The limit leaves room for exactly one of them.
B1=$(new_proposal u_wo S4A 110)
B2=$(new_proposal u_wo S4B 110)
q "UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = public.credit_exposure((SELECT alpha FROM zz.pc), (SELECT good FROM zz.pc)) + 150 WHERE wholesaler_id = (SELECT alpha FROM zz.pc)" >/dev/null
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(accept_sql "$B1" u_po)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(accept_sql "$B2" u_po)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 4: the first increase was applied" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 4: the second was refused because the limit was already used" "$(grep -q 'would take the account above its credit limit' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-200)"
check "scenario 4: exactly one of the two orders was repriced" "$([ "$(q "SELECT count(*) FROM public.order_amendments WHERE id IN ('$B1', '$B2') AND status = 'accepted'")" = "1" ] && echo true || echo false)" ""
q "UPDATE public.wholesaler_credit_terms SET credit_limit_ghs = 1000000 WHERE wholesaler_id = (SELECT alpha FROM zz.pc)" >/dev/null

exit $fail
