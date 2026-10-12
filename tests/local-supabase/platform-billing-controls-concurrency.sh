#!/bin/bash
# The administrator's controls under concurrency, with real overlapping database sessions.
#
#   1. THE LAST PLACE IN A PROMOTION. A promotion limited to one business is applied to two different businesses at the same moment: exactly one gets it; the other is told the promotion is full.
#   2. THE SAME FEE WAIVED TWICE AT ONCE (two administrators): the order's fee is credited once; the second is told there is nothing left to waive.
#   3. THE SAME CREDIT REQUEST SENT TWICE AT ONCE (a double click): one credit is recorded; the second is told it was already recorded (not an error).
#   4. THE SAME FREE-ORDER GRANT SENT TWICE AT ONCE: one grant.
#   In every case the reconciliation must find nothing wrong afterwards.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261205110000, and the production guard and stock fixtures.
# Negative controls (each makes a scenario fail): scenario 1, remove the "FOR UPDATE" on the promotion row in admin_billing_apply_promotion (two businesses get a one-place promotion);
# scenarios 2 and 3, remove the "FOR UPDATE" in _billing_lock_subscription (the fee is waived twice; the credit key collides and errors).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

ADMIN=$($P -c "SELECT id FROM zz.u WHERE k = 'admin'")
$P <<SQL >/dev/null
DROP TABLE IF EXISTS zz.cc;
UPDATE public.billing_settings SET mode = 'active';
CREATE TABLE zz.cc(scenario TEXT, label TEXT, id UUID);
DO \$\$
DECLARE
  v_ph UUID := (SELECT id FROM zz.b WHERE name = 'Good Pharmacy');
  v_u UUID; v_b UUID; v_plan UUID; v_ver UUID; v_sub UUID; v_o UUID; s TEXT; st TEXT;
BEGIN
  INSERT INTO public.billing_plans(code, business_type, name, active) VALUES ('cc5_plan', 'wholesaler', 'CC5 plan', TRUE) RETURNING id INTO v_plan;
  INSERT INTO public.billing_plan_versions(plan_id, version, subscription_amount, transaction_fee_percentage, reason) VALUES (v_plan, 1, 100, 1, 'Concurrency test') RETURNING id INTO v_ver;
  FOREACH s IN ARRAY ARRAY['promoA', 'promoB', 'waive', 'credit', 'grant'] LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc5' || s || '@zz.test', '{}', '{"provider":"email"}', now(), now());
    INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', 'CC5 ' || s, 'CC5LIC-' || s, 'approved') RETURNING id INTO v_b;
    INSERT INTO public.billing_subscriptions(business_id, status, billing_starts_at, period_anchor_at) VALUES (v_b, 'active', now() - interval '2 days', now() - interval '2 days') RETURNING id INTO v_sub;
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, reason) VALUES (v_sub, now() - interval '2 days', v_ver, 'Concurrency test');
    INSERT INTO zz.cc VALUES (s, 'business', v_b);
  END LOOP;
  INSERT INTO public.billing_promotions(code, name, business_type, benefits, max_redemptions, reason) VALUES ('CC5-ONE-SLOT', 'One slot', 'wholesaler', '{"free_orders":1}', 1, 'Concurrency test');
  -- the order whose fee is waived: delivered now, 1% of 4,000 = GHS 40.00
  v_b := (SELECT id FROM zz.cc WHERE scenario = 'waive' AND label = 'business');
  PERFORM public.billing_open_periods(now());
  INSERT INTO public.orders(order_number, pharmacy_id, wholesaler_id, total_ghs, delivery_fee_ghs, delivered_at) VALUES ('ORD-CC5W', v_ph, v_b, 4000, 0, clock_timestamp()) RETURNING id INTO v_o;
  FOREACH st IN ARRAY ARRAY['accepted', 'picking', 'packed', 'ready_for_dispatch', 'dispatched', 'delivered'] LOOP EXECUTE format('UPDATE public.orders SET status = %L WHERE id = %L', st, v_o); END LOOP;
  INSERT INTO zz.cc VALUES ('waive', 'order', v_o);
END \$\$;
SQL

bid() { $P -c "SELECT id FROM zz.cc WHERE scenario = '$1' AND label = 'business'"; }
as_admin() { echo "SELECT set_config('request.jwt.claims', '{\"sub\":\"$ADMIN\",\"role\":\"authenticated\"}', true); SELECT set_config('request.jwt.claim.sub', '$ADMIN', true); SET LOCAL ROLE authenticated;"; }

race() {  # $1 first statement (held 3 seconds), $2 second statement (starts 1.2 seconds later)
  A_OUT=$(mktemp); B_OUT=$(mktemp)
  ( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
$1
SELECT pg_sleep(3);
COMMIT;
SQL
  ) &
  local pid=$!
  sleep 1.2
  $P > "$B_OUT" 2>&1 <<SQL
BEGIN;
$(as_admin)
$2
COMMIT;
SQL
  wait $pid
}

# ----- Scenario 1: the last place in a promotion --------------------------------------------------------------------------------------------------------------------
PA=$(bid promoA); PB=$(bid promoB)
race "SELECT public.admin_billing_apply_promotion('$PA', 'CC5-ONE-SLOT', 'Concurrency test A')->>'redemption_id';" "SELECT public.admin_billing_apply_promotion('$PB', 'CC5-ONE-SLOT', 'Concurrency test B')->>'redemption_id';"
N=$($P -c "SELECT count(*) FROM public.billing_promotion_redemptions r JOIN public.billing_promotions p ON p.id = r.promotion_id WHERE p.code = 'CC5-ONE-SLOT'")
G=$($P -c "SELECT count(*) FROM public.billing_allowance_grants WHERE source = 'promotion' AND source_ref = 'CC5-ONE-SLOT'")
check "1: the first session got the promotion" "$(grep -qE '^[0-9a-f-]{36}' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "1: the second was told it was full, in plain words" "$(grep -q 'reached its limit of 1 businesses' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "1: exactly one redemption and one grant exist" "$([ "$N" = "1" ] && [ "$G" = "1" ] && echo true || echo false)" "redemptions=$N grants=$G"

# ----- Scenario 2: the same fee waived twice at once ---------------------------------------------------------------------------------------------------------------
W=$(bid waive); O=$($P -c "SELECT id FROM zz.cc WHERE scenario = 'waive' AND label = 'order'")
FEE=$($P -c "SELECT COALESCE(sum(charged_amount), 0) FROM public.order_billing_assessments WHERE order_id = '$O'")
race "SELECT public.admin_billing_waive_fee('$W', '$O', 'Concurrency test waiver A')->>'amount';" "SELECT public.admin_billing_waive_fee('$W', '$O', 'Concurrency test waiver B')->>'amount';"
NW=$($P -c "SELECT count(*) FROM public.billing_ledger_entries WHERE order_id = '$O' AND entry_type = 'fee_waiver'")
SW=$($P -c "SELECT COALESCE(sum(credit_amount), 0) FROM public.billing_ledger_entries WHERE order_id = '$O' AND entry_type = 'fee_waiver'")
check "2: the order's fee is 40.00" "$([ "$FEE" = "40.00" ] && echo true || echo false)" "$FEE"
check "2: the first administrator waived it" "$(grep -q '^40.00' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "2: the second was told there is no fee left to waive" "$(grep -q 'no fee left to waive' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "2: one waiver exists, for exactly the fee (never more than was charged)" "$([ "$NW" = "1" ] && [ "$SW" = "40.00" ] && echo true || echo false)" "waivers=$NW total=$SW"

# ----- Scenario 3: the same credit request sent twice at once --------------------------------------------------------------------------------------------------------
CB=$(bid credit)
race "SELECT public.admin_billing_apply_credit('$CB', 12, 'manual_credit', 'Concurrency test credit', 'cc5-credit-key-1')->>'replayed';" "SELECT public.admin_billing_apply_credit('$CB', 12, 'manual_credit', 'Concurrency test credit', 'cc5-credit-key-1')->>'replayed';"
NC=$($P -c "SELECT count(*) FROM public.billing_ledger_entries WHERE business_id = '$CB' AND entry_type = 'manual_credit'")
CR=$($P -c "SELECT credits_amount FROM public.billing_periods WHERE business_id = '$CB' AND NOT shadow AND period_start <= now() AND period_end > now()")
check "3: the first session recorded the credit" "$(grep -q '^false' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "3: the second was told it was already recorded (no error)" "$(grep -q '^true' "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "3: one credit exists and the period shows 12.00" "$([ "$NC" = "1" ] && [ "$CR" = "12.00" ] && echo true || echo false)" "credits=$NC period=$CR"

# ----- Scenario 4: the same free-order grant sent twice at once -------------------------------------------------------------------------------------------------
GB=$(bid grant)
race "SELECT public.admin_billing_grant_free_orders('$GB', 4, NULL, 'Concurrency test grant', 'cc5-grant-key-1')->>'replayed';" "SELECT public.admin_billing_grant_free_orders('$GB', 4, NULL, 'Concurrency test grant', 'cc5-grant-key-1')->>'replayed';"
NG=$($P -c "SELECT count(*) FROM public.billing_allowance_grants WHERE business_id = '$GB' AND source = 'admin'")
check "4: the first recorded the grant and the second was told it was already recorded" "$(grep -q '^false' "$A_OUT" && grep -q '^true' "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "A=$(cat "$A_OUT") B=$(cat "$B_OUT")"
check "4: one grant of 4 exists" "$([ "$NG" = "1" ] && echo true || echo false)" "grants=$NG"

# ----- Afterwards everything reconciles ------------------------------------------------------------------------------------------------------------------------------------
BAD=$($P -c "SELECT count(*) FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('billing_queue_stuck', 'period_not_invoiced_when_it_should_be')")
check "all: the reconciliation finds nothing wrong after the concurrent runs" "$([ "$BAD" = "0" ] && echo true || echo false)" "$($P -c "SELECT string_agg(check_name || '=' || finding_count, ';') FROM public.billing_reconcile() WHERE finding_count > 0")"

$P -c "UPDATE public.billing_settings SET mode = 'disabled'" >/dev/null
exit $fail
