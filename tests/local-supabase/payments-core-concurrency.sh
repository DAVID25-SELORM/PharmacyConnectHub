#!/bin/bash
# The payment core under concurrency, with real overlapping database sessions.
#
#   1. A webhook and a verify call report the same successful payment at the same moment: exactly ONE is applied, the other is a
#      duplicate; the order is paid once, with one timeline event and one payment log entry.
#   2. Two different attempts for the same order are both reported as paid at the same moment (the customer paid twice): exactly one
#      pays the order; the other is flagged as an already-paid double payment with a refund required; the database never ends with
#      two paying attempts.
#   3. The order is cancelled while a payment is being applied: whichever goes first, the order ends cancelled and the payment that
#      was received is marked refund-required (paid then cancelled, or cancelled then paid late): the money is never lost silently.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261106110000 and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove the `FOR UPDATE` on the order row in apply_payment_result; scenarios 1 and 2 must then fail.
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.pk;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PK A'), ('PK B'), ('PK C')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.pk AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='w_owner') u_wo,
  (SELECT id FROM public.products WHERE name='PK A') pa,
  (SELECT id FROM public.products WHERE name='PK B') pb,
  (SELECT id FROM public.products WHERE name='PK C') pc;
CREATE TABLE zz.pk_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.pk)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.pk), 'role', 'authenticated')::text, false);"; }

make_order() { # $1 label, $2 product column; ten units at 100 = 1000, an online order awaiting payment
$P <<SQL >/dev/null
$(as_sql u_po)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.pk), (SELECT good FROM zz.pk),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.pk), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.pk)::text, 'cod'));
INSERT INTO zz.pk_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
UPDATE public.orders SET payment_method = 'paystack', settlement_method = 'pay_now' WHERE id = (SELECT id FROM zz.pk_o WHERE label = '$1');
ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
SQL
}
make_attempt() { # $1 order label, $2 reference
$P <<SQL >/dev/null
INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
SELECT o.id, 'paystack', 'test', '$2', o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o WHERE o.id = (SELECT id FROM zz.pk_o WHERE label = '$1');
SQL
}
apply_sql() { # $1 reference, $2 source
echo "SELECT public.apply_payment_result('paystack', 'test', '$1', 'success', 100000, 'GHS', 'tx-$1', 'card', 1500, '$2')->>'outcome';"
}
make_order K1 pa; make_attempt K1 DX-CONC-0001
make_order K2 pb; make_attempt K2 DX-CONC-0002; make_attempt K2 DX-CONC-0003
make_order K3 pc; make_attempt K3 DX-CONC-0004

# ----- Scenario 1: webhook and verify report the same payment at once ------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(apply_sql DX-CONC-0001 verify)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(apply_sql DX-CONC-0001 webhook)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the second report waited for the first (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the first was applied" "$(grep -q '^applied$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 1: the second was a duplicate" "$(grep -q '^duplicate$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-120)"
check "scenario 1: the order is paid once: one timeline event, one log entry" "$([ "$(q "SELECT (SELECT payment_status FROM public.orders WHERE id = (SELECT id FROM zz.pk_o WHERE label = 'K1')) || '/' || (SELECT count(*) FROM public.order_events WHERE order_id = (SELECT id FROM zz.pk_o WHERE label = 'K1') AND event_type = 'payment_received') || '/' || (SELECT count(*) FROM public.order_payment_log WHERE order_id = (SELECT id FROM zz.pk_o WHERE label = 'K1') AND kind = 'payment_applied')")" = "paid/1/1" ] && echo true || echo false)" ""

# ----- Scenario 2: the customer paid twice, both reported at once ---------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(apply_sql DX-CONC-0002 webhook)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(apply_sql DX-CONC-0003 webhook)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 2: the first payment paid the order" "$(grep -q '^applied$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 2: the second was flagged, not applied" "$(grep -q '^flagged$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-120)"
check "scenario 2: exactly one paying attempt; the other needs a refund" "$([ "$(q "SELECT count(*) FILTER (WHERE status = 'succeeded' AND NOT refund_required) || '/' || count(*) FILTER (WHERE status = 'flagged' AND flag_reason = 'already_paid' AND refund_required) FROM public.order_payment_attempts WHERE order_id = (SELECT id FROM zz.pk_o WHERE label = 'K2')")" = "1/1" ] && echo true || echo false)" ""

# ----- Scenario 3: cancellation racing a payment ----------------------------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(apply_sql DX-CONC-0004 webhook)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
UPDATE public.orders SET status = 'cancelled', cancellation_reason = 'window ended' WHERE id = (SELECT id FROM zz.pk_o WHERE label = 'K3');
SQL
) &
B_PID=$!
wait $A_PID $B_PID
S3=$(q "SELECT o.status || '/' || o.payment_status || '/' || a.status || '/' || a.refund_required FROM public.orders o JOIN public.order_payment_attempts a ON a.order_id = o.id WHERE o.id = (SELECT id FROM zz.pk_o WHERE label = 'K3')")
check "scenario 3: the payment was applied first (the order is paid)" "$(grep -q '^applied$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 3: the order ends cancelled and the money received is never lost: the payment needs a refund" "$([ "$S3" = "cancelled/paid/succeeded/true" ] || [ "$S3" = "cancelled/unpaid/succeeded/true" ] && echo true || echo false)" "$S3"

exit $fail
