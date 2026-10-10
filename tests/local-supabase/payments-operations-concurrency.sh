#!/bin/bash
# Expiring unpaid online orders under concurrency, with real overlapping database sessions.
#
#   1. Expiry holds the order while a payment for it is being recorded: the payment waits, then is recorded as a LATE payment (the order stays
#      cancelled, a refund is required): money is never lost and the order is never revived.
#   2. A payment holds the order while expiry runs: expiry skips the locked order (it does not wait), the order ends PAID and is never cancelled.
#   3. Two expiry runs at once: the order is cancelled once, its stock is returned once, one log entry.
#   4. Expiry holds the order while someone starts a payment: the start is refused (the order was cancelled) and creates nothing.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261108110000, and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove `FOR UPDATE SKIP LOCKED` from the order lookup in expire_unpaid_online_orders; scenarios 2 and 3 must then fail (a paid order gets cancelled; the stock comes back twice).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }
q() { $P -c "$1"; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.po;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, n, 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b, (VALUES ('PO A'), ('PO B'), ('PO C'), ('PO D')) v(n) WHERE name='Alpha Wholesale';
CREATE TABLE zz.po AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM public.products WHERE name='PO A') pa,
  (SELECT id FROM public.products WHERE name='PO B') pb,
  (SELECT id FROM public.products WHERE name='PO C') pc,
  (SELECT id FROM public.products WHERE name='PO D') pd;
CREATE TABLE zz.po_o(label TEXT PRIMARY KEY, id UUID);
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test';
SQL

as_sql() { echo "SELECT set_config('request.jwt.claim.sub', (SELECT $1 FROM zz.po)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT $1 FROM zz.po), 'role', 'authenticated')::text, false);"; }

# An online order for ten units at 100 (= 1000), placed 45 minutes ago, with one open attempt that was checked with the provider a minute ago.
make_order() { # $1 label, $2 product column, $3 reference ('' = no attempt)
$P <<SQL >/dev/null
$(as_sql u_po)
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.po), (SELECT good FROM zz.po),
  jsonb_build_array(jsonb_build_object('productId', (SELECT $2 FROM zz.po), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.po)::text, 'pay_now'));
INSERT INTO zz.po_o SELECT '$1', id FROM public.orders ORDER BY created_at DESC LIMIT 1;
ALTER TABLE public.orders DISABLE TRIGGER aa_phase0_order_integrity;
UPDATE public.orders SET created_at = now() - interval '45 minutes' WHERE id = (SELECT id FROM zz.po_o WHERE label = '$1');
ALTER TABLE public.orders ENABLE TRIGGER aa_phase0_order_integrity;
SQL
if [ -n "$3" ]; then
$P <<SQL >/dev/null
INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor, initiated_at, last_checked_at)
SELECT o.id, 'paystack', 'test', '$3', o.total_ghs, public.payment_minor_from_ghs(o.total_ghs), now() - interval '40 minutes', now() - interval '1 minute'
FROM public.orders o WHERE o.id = (SELECT id FROM zz.po_o WHERE label = '$1');
SQL
fi
}
oid() { echo "(SELECT id FROM zz.po_o WHERE label = '$1')"; }
expire_sql() { echo "SELECT public.expire_unpaid_online_orders(50, 30, 2)::text;"; }
apply_sql() { echo "SELECT public.apply_payment_result('paystack', 'test', '$1', 'success', 100000, 'GHS', 'tx-$1', 'card', 1500, 'webhook')->>'outcome';"; }
stock() { q "SELECT stock FROM public.products WHERE id = (SELECT $1 FROM zz.po)"; }


# ----- Scenario 1: expiry holds the order, a payment arrives ---------------------------------------------------------------------------
make_order Q1 pa dx-test-conc-p1   # each scenario creates its own old order, so an expiry run only ever finds that one
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(expire_sql)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(apply_sql dx-test-conc-p1)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 1: the payment waited for the expiry (at least 1.5 s)" "$([ "$B_MS" -ge 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 1: the expiry cancelled the order" "$(grep -q '"expired": 1' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 1: the payment was recorded as late" "$(grep -q '^late$' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-120)"
check "scenario 1: the order stays cancelled; the money received is marked for refund" "$([ "$(q "SELECT o.status || '/' || o.payment_status || '/' || a.status || '/' || a.refund_required FROM public.orders o JOIN public.order_payment_attempts a ON a.order_id = o.id WHERE o.id = $(oid Q1)")" = "cancelled/unpaid/succeeded/true" ] && echo true || echo false)" ""
check "scenario 1: an alert says a refund is needed" "$([ "$(q "SELECT count(*) FROM public.payment_alerts WHERE kind = 'refund_required' AND order_id = $(oid Q1) AND status = 'open'")" = "1" ] && echo true || echo false)" ""

# ----- Scenario 2: a payment holds the order, expiry runs ----------------------------------------------------------------------------------
make_order Q2 pb dx-test-conc-p2
STOCK_BEFORE=$(stock pb)
A_OUT=$(mktemp); B_OUT=$(mktemp); T_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(apply_sql dx-test-conc-p2)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
(
  B_START=$(date +%s%N)
  $P > "$B_OUT" 2>&1 <<SQL
$(expire_sql)
SQL
  echo $(( ($(date +%s%N) - B_START) / 1000000 )) > "$T_OUT"
) &
B_PID=$!
wait $A_PID $B_PID
B_MS=$(cat "$T_OUT")
check "scenario 2: the payment was applied" "$(grep -q '^applied$' "$A_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-120)"
check "scenario 2: expiry did not wait for the order (it skipped it)" "$([ "$B_MS" -lt 1500 ] && echo true || echo false)" "${B_MS} ms"
check "scenario 2: the order ends paid and not cancelled; its stock is unchanged" "$([ "$(q "SELECT status || '/' || payment_status FROM public.orders WHERE id = $(oid Q2)")" = "pending/paid" ] && [ "$(stock pb)" = "$STOCK_BEFORE" ] && echo true || echo false)" "$(q "SELECT status || '/' || payment_status FROM public.orders WHERE id = $(oid Q2)")"
$P -c "$(expire_sql)" >/dev/null
check "scenario 2: a later expiry run still leaves the paid order alone" "$([ "$(q "SELECT status || '/' || payment_status FROM public.orders WHERE id = $(oid Q2)")" = "pending/paid" ] && echo true || echo false)" ""

# ----- Scenario 3: two expiry runs at once -------------------------------------------------------------------------------------------------
make_order Q3 pc ''
STOCK_BEFORE=$(stock pc)
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(expire_sql)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
$(expire_sql)
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 3: one run cancelled the order, the other found nothing to do" "$(grep -q '"expired": 1' "$A_OUT" && grep -q '"expired": 0' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$A_OUT" | cut -c1-80) / $(tr '\n' ' ' < "$B_OUT" | cut -c1-80)"
check "scenario 3: cancelled once, stock returned once (+10), one log entry" "$([ "$(q "SELECT status FROM public.orders WHERE id = $(oid Q3)")" = "cancelled" ] && [ "$(stock pc)" = "$((STOCK_BEFORE + 10))" ] && [ "$(q "SELECT count(*) FROM public.order_payment_log WHERE order_id = $(oid Q3) AND kind = 'order_expired'")" = "1" ] && echo true || echo false)" "stock $(stock pc) vs $STOCK_BEFORE"

# ----- Scenario 4: expiry holds the order, someone starts a payment ---------------------------------------------------------------------------
make_order Q4 pd ''
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(expire_sql)
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
( $P > "$B_OUT" 2>&1 <<SQL
DO \$\$ BEGIN PERFORM public.begin_order_payment((SELECT u_po FROM zz.po), $(oid Q4), 'paystack', 'test', 'dx-test-conc-p4'); RAISE NOTICE 'started'; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'refused: %', SQLERRM; END \$\$;
SQL
) &
B_PID=$!
wait $A_PID $B_PID
check "scenario 4: the start that came second was refused (the order was cancelled)" "$(grep -q 'refused: This order was cancelled' "$B_OUT" && echo true || echo false)" "$(tr '\n' ' ' < "$B_OUT" | cut -c1-160)"
check "scenario 4: nothing was created for the expired order" "$([ "$(q "SELECT count(*) FROM public.order_payment_attempts WHERE order_id = $(oid Q4)")" = "0" ] && echo true || echo false)" ""

$P -c "UPDATE public.payments_settings SET online_enabled = FALSE" >/dev/null
exit $fail
