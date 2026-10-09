#!/bin/bash
# Delivery reconciliation under concurrency, with real overlapping database sessions.
#
#   1. Two pharmacy users submit a report for the same delivery at the same moment: exactly ONE live report exists; the second
#      call waits and is then refused.
#   2. Two wholesaler managers decide the same report at the same moment: exactly ONE credit note, ONE return and one set of
#      decisions; the second call waits and reports a replay.
#   3. A report is withdrawn while the wholesaler decides it at the same moment: exactly one of them wins, and the report is
#      never both withdrawn and credited.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261103120000 and the production guard and stock
# fixtures (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in submit_delivery_report; scenario 1 must then fail (the unique
# index still refuses the second row, but with a different message and the check on the message fails).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.rc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('RC A'), ('RC B'), ('RC C')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.rc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM zz.u WHERE k='w_manager') u_wm,
  (SELECT id FROM public.products WHERE name='RC A') pa,
  (SELECT id FROM public.products WHERE name='RC B') pb,
  (SELECT id FROM public.products WHERE name='RC C') pc;
CREATE TABLE zz.rc_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
INSERT INTO public.wholesaler_credit_terms(wholesaler_id, pharmacy_id, credit_limit_ghs, payment_terms_days)
SELECT alpha, good, 1000000, 30 FROM zz.rc ON CONFLICT (wholesaler_id, pharmacy_id) DO UPDATE SET credit_limit_ghs = 1000000, active = true, status = 'active';
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.rc)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.rc), 'role', 'authenticated')::text, false);"; }

make_delivered_order() { # $1 label, $2 product col
$P <<SQL >/dev/null
$(as_sql u_wo)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.rc), (SELECT good FROM zz.rc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.rc), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.rc)::text, 'credit'));
INSERT INTO zz.rc_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
UPDATE public.orders SET status = 'accepted' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
UPDATE public.orders SET status = 'picking' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
UPDATE public.orders SET status = 'packed' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
UPDATE public.orders SET status = 'ready_for_dispatch' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
UPDATE public.orders SET status = 'dispatched' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
UPDATE public.orders SET status = 'delivered' WHERE id = (SELECT id FROM zz.rc_o WHERE label = '$1');
SQL
}
make_delivered_order R1 pa
make_delivered_order R2 pb
make_delivered_order R3 pc

submit_sql() { # $1 label
echo "$(as_sql u_po)
SELECT public.submit_delivery_report((SELECT id FROM zz.rc_o WHERE label = '$1'), NULL,
  jsonb_build_array(jsonb_build_object('order_item_id', (SELECT id FROM public.order_items WHERE order_id = (SELECT id FROM zz.rc_o WHERE label = '$1') LIMIT 1), 'missing', 2, 'damaged', 1, 'reason', 'counted on arrival')),
  'note', gen_random_uuid())->>'status';"
}
new_report() { $P <<SQL | tail -1
$(submit_sql "$1")
SQL
}
decide_sql() { # $1 report id, $2 who
echo "$(as_sql $2)
SELECT public.resolve_delivery_report('$1', (SELECT jsonb_agg(jsonb_build_object('line_id', l.id, 'kind', k, 'outcome', CASE k WHEN 'missing' THEN 'credit' ELSE 'return' END))
  FROM public.order_delivery_report_lines l, unnest(ARRAY['missing', 'damaged']) k WHERE l.report_id = '$1'), 'checked')->>'replayed';"
}

# ----- Scenario 1: two submissions for the same delivery at once ---------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(submit_sql R1)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(submit_sql R1)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second submission waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first was accepted" "$(grep -q '^submitted$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT")"
check "scenario 1: the second was refused with the clear message" "$(grep -q 'There is already a delivery report for this delivery' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 1: exactly one live report" "$([ "$(q "SELECT count(*) FROM public.order_delivery_reports WHERE order_id = (SELECT id FROM zz.rc_o WHERE label = 'R1') AND status IN ('submitted', 'resolved', 'received_in_full')")" = "1" ] && echo true || echo false)" ""

# ----- Scenario 2: the same report decided twice at once -----------------------------------------------------------------------
R2=$(new_report R2 >/dev/null; q "SELECT id FROM public.order_delivery_reports WHERE order_id = (SELECT id FROM zz.rc_o WHERE label = 'R2')")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(decide_sql "$R2" u_wo)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(decide_sql "$R2" u_wm)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the first decision was applied (replayed = false)" "$(grep -q '^false$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 2: the second was a replay (replayed = true)" "$(grep -q '^true$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 2: exactly one credit note of 200 (2 units x 100)" "$([ "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.credit_ledger_entries WHERE delivery_report_id = '$R2'")" = "1/200.00" ] && echo true || echo false)" "$(q "SELECT count(*) || '/' || COALESCE(sum(amount_ghs), 0) FROM public.credit_ledger_entries WHERE delivery_report_id = '$R2'")"
check "scenario 2: exactly one return and two decisions" "$([ "$(q "SELECT (SELECT count(*) FROM public.order_returns WHERE delivery_report_id = '$R2') || '/' || (SELECT count(*) FROM public.order_delivery_report_decisions WHERE report_id = '$R2')")" = "1/2" ] && echo true || echo false)" ""
check "scenario 2: the order total was reduced once (1000 -> 800)" "$([ "$(q "SELECT effective_total_ghs FROM public.orders WHERE id = (SELECT id FROM zz.rc_o WHERE label = 'R2')")" = "800.00" ] && echo true || echo false)" ""

# ----- Scenario 3: withdrawal racing the decision --------------------------------------------------------------------------------
R3=$(new_report R3 >/dev/null; q "SELECT id FROM public.order_delivery_reports WHERE order_id = (SELECT id FROM zz.rc_o WHERE label = 'R3')")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(decide_sql "$R3" u_wo)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(as_sql u_po)
SELECT public.withdraw_delivery_report('$R3')->>'status';
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: the decision won and the late withdrawal was refused" "$(grep -q 'has already been resolved' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 3: the report ends resolved with its credit, never withdrawn" "$([ "$(q "SELECT status || '/' || (SELECT count(*) FROM public.credit_ledger_entries WHERE delivery_report_id = '$R3') FROM public.order_delivery_reports WHERE id = '$R3'")" = "resolved/1" ] && echo true || echo false)" ""

exit $fail
