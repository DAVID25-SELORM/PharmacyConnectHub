#!/bin/bash
# Settlement under concurrency, with real overlapping database sessions.
#
#   1. Two administrators create a settlement account for the same supplier at the same moment: exactly one is made, the other is refused.
#   2. Two requests prepare the same payment for the provider at the same moment (a retry racing the first): both get the same answer, the payment is split once and never changed.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261111120000, and the production guard and stock fixtures
# (production-guard-fixture.sql, production-stock-fixture.sql, then 20261017110000 re-applied).
# Negative control: remove "FOR UPDATE" from the attempt lookup in prepare_attempt_for_provider and scenario 2 fails (the second session tries to change the split and is refused).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

$P <<'SQL' >/dev/null
DROP TABLE IF EXISTS zz.sc;
INSERT INTO public.products(wholesaler_id, name, brand, category, form, pack_size, price_ghs, stock, active)
SELECT id, 'SC A', 'Generic', 'Analgesic', 'TABLET', '100s', 100, 1000, true FROM zz.b WHERE name='Alpha Wholesale';
CREATE TABLE zz.sc AS SELECT
  (SELECT id FROM zz.b WHERE name='Good Pharmacy') good,
  (SELECT id FROM zz.b WHERE name='Alpha Wholesale') alpha,
  (SELECT id FROM zz.b WHERE name='Other Wholesale') other,
  (SELECT id FROM zz.u WHERE k='ph_owner') u_po,
  (SELECT id FROM zz.u WHERE k='admin') u_admin,
  (SELECT id FROM public.products WHERE name='SC A') pa;
UPDATE public.customer_discounts SET active = false;
UPDATE public.product_discounts SET active = false;
DELETE FROM public.wholesaler_order_terms;
UPDATE public.payments_settings SET online_enabled = TRUE, mode = 'test', auto_refunds = FALSE, split_mode = 'none', platform_fee_bps = 250, max_order_ghs = NULL;
SQL

# ----- Scenario 1: two administrators, one account -------------------------------------------------------------------------------------------------
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<'SQL'
BEGIN;
SELECT public.begin_payout_account((SELECT u_admin FROM zz.sc), (SELECT other FROM zz.sc), 'test', 'Other Wholesale Ltd', 'GCB', '1111');
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
$P > "$B_OUT" 2>&1 <<'SQL'
SELECT public.begin_payout_account((SELECT u_admin FROM zz.sc), (SELECT other FROM zz.sc), 'test', 'Other Wholesale Ltd', 'GCB', '2222');
SQL
wait $A_PID
ROWS=$($P -c "SELECT count(*) FROM public.supplier_payout_accounts WHERE wholesaler_id = (SELECT other FROM zz.sc) AND status IN ('pending','active')")
check "1: exactly one account is made for the supplier" "$([ "$ROWS" = "1" ] && echo true || echo false)" "rows=$ROWS"
check "1: the first administrator succeeded" "$(grep -qiE 'error' "$A_OUT" && echo false || echo true)" "$(cat "$A_OUT")"
check "1: the second was refused (not both made)" "$(grep -qiE 'error' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "1: the one that exists is the first administrator's (last digits 1111)" "$([ "$($P -c "SELECT account_last4 FROM public.supplier_payout_accounts WHERE wholesaler_id = (SELECT other FROM zz.sc) AND status IN ('pending','active')")" = "1111" ] && echo true || echo false)" "last4"

# ----- Scenario 2: two requests prepare the same payment ---------------------------------------------------------------------------------------------
$P <<'SQL' >/dev/null
SELECT set_config('request.jwt.claim.sub', (SELECT u_po FROM zz.sc)::text, false);
SELECT set_config('request.jwt.claims', json_build_object('sub', (SELECT u_po FROM zz.sc), 'role', 'authenticated')::text, false);
SELECT public.create_marketplace_orders((SELECT u_po FROM zz.sc), (SELECT good FROM zz.sc),
  jsonb_build_array(jsonb_build_object('productId', (SELECT pa FROM zz.sc), 'quantity', 10, 'category', 'cash_private')),
  '{}', TRUE, jsonb_build_object((SELECT alpha FROM zz.sc)::text, 'pay_now'));
INSERT INTO public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor)
SELECT o.id, 'paystack', 'test', 'dx-test-scc-0001', o.total_ghs, public.payment_minor_from_ghs(o.total_ghs) FROM public.orders o ORDER BY o.created_at DESC LIMIT 1;
INSERT INTO public.supplier_payout_accounts(wholesaler_id, mode, business_name, settlement_bank_code, account_last4, status, provider_subaccount_code)
VALUES ((SELECT alpha FROM zz.sc), 'test', 'Alpha Wholesale Ltd', 'GCB', '1234', 'active', 'ACCT_scc0001');
UPDATE public.payments_settings SET split_mode = 'subaccount';
SQL
ATT=$($P -c "SELECT id FROM public.order_payment_attempts WHERE reference = 'dx-test-scc-0001'")
A_OUT=$(mktemp); B_OUT=$(mktemp)
( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
SELECT public.prepare_attempt_for_provider('$ATT')::text;
SELECT pg_sleep(4);
COMMIT;
SQL
) &
A_PID=$!
sleep 1.5
$P > "$B_OUT" 2>&1 <<SQL
SELECT public.prepare_attempt_for_provider('$ATT')::text;
SQL
wait $A_PID
A_JSON=$(grep -m1 '^{' "$A_OUT")
B_JSON=$(grep -m1 '^{' "$B_OUT")
check "2: the first request prepared it, split with the supplier's account" "$(echo "$A_JSON" | grep -q 'ACCT_scc0001' && echo true || echo false)" "$(cat "$A_OUT")"
check "2: the second request got exactly the same answer, with no error" "$([ -n "$B_JSON" ] && [ "$A_JSON" = "$B_JSON" ] && echo true || echo false)" "A=$A_JSON B=$(cat "$B_OUT")"
check "2: the payment carries the split once" "$([ "$($P -c "SELECT split_subaccount || '/' || split_charge_minor FROM public.order_payment_attempts WHERE id = '$ATT'")" = "ACCT_scc0001/2500" ] && echo true || echo false)" "row"

$P -c "UPDATE public.payments_settings SET online_enabled = FALSE, split_mode = 'none', platform_fee_bps = 0" >/dev/null
exit $fail
