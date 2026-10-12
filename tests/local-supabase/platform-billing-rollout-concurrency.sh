#!/bin/bash
# The rollout under concurrency, with real overlapping database sessions.
#
#   1. TWO ADMINISTRATORS ACTIVATE BILLING AT THE SAME MOMENT: it is switched on once; the second is told it is already on; one audit entry exists and the hold-back was applied once.
#   2. TWO ADMINISTRATORS PUT THE SAME BUSINESS LIVE AT THE SAME MOMENT: it goes live once (one audit entry, one trial restart); the second is told it already started.
#   3. THE ACCOUNT-STATUS STEP RUNS TWICE AT ONCE (a scheduled run overlapping an administrator's "run now"): the business becomes past due once (one audit entry).
#   4. THE NOTICE STEP RUNS TWICE AT ONCE: every notice reaches people once (no duplicate in anyone's bell).
#   In every case the reconciliation must find nothing wrong afterwards.
#
# Run on the local Docker stack after setup.sql, the migrations through 20261206110000, and the production guard and stock fixtures.
# Negative controls (each makes a scenario fail): scenario 1, remove the "FOR UPDATE" on the settings row in admin_billing_activate_platform (two activations); scenario 2, remove the "FOR UPDATE" in
# _billing_lock_subscription (two go-lives); scenario 3, remove the "FOR UPDATE" on the subscription in billing_advance_enforcement (two status changes and two audit entries).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

ADMIN=$($P -c "SELECT id FROM zz.u WHERE k = 'admin'")
$P <<SQL >/dev/null
DROP TABLE IF EXISTS zz.cc;
UPDATE public.billing_settings SET mode = 'shadow', live_since = NULL, enforcement = 'none', grace_days = 7, issuer = '{"name": "DrugXOne Ltd", "payment_instructions": "Pay by bank transfer and quote the invoice number."}'::jsonb;
CREATE TABLE zz.cc(scenario TEXT, label TEXT, id UUID);
DO \$\$
DECLARE
  v_u UUID; v_b UUID; v_plan UUID; v_ver UUID; v_sub UUID; s TEXT; v_start TIMESTAMPTZ;
BEGIN
  INSERT INTO public.billing_plans(code, business_type, name, active) VALUES ('cc6_plan', 'wholesaler', 'CC6 plan', TRUE) RETURNING id INTO v_plan;
  INSERT INTO public.billing_plan_versions(plan_id, version, subscription_amount, free_trial_days, transaction_fee_percentage, reason) VALUES (v_plan, 1, 100, 30, 1, 'Concurrency test') RETURNING id INTO v_ver;
  FOREACH s IN ARRAY ARRAY['golive', 'status'] LOOP
    v_u := gen_random_uuid();
    v_start := CASE s WHEN 'status' THEN now() - interval '40 days' ELSE now() - interval '10 days' END;
    INSERT INTO auth.users(id, instance_id, aud, role, email, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
    VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cc6' || s || '@zz.test', '{}', '{"provider":"email"}', now(), now());
    INSERT INTO public.businesses(owner_id, type, name, license_number, verification_status) VALUES (v_u, 'wholesaler', 'CC6 ' || s, 'CC6LIC-' || s, 'approved') RETURNING id INTO v_b;
    INSERT INTO public.billing_subscriptions(business_id, status, billing_starts_at, period_anchor_at) VALUES (v_b, 'active', v_start, v_start) RETURNING id INTO v_sub;
    INSERT INTO public.billing_subscription_terms(subscription_id, effective_from, plan_version_id, reason) VALUES (v_sub, v_start, v_ver, 'Concurrency test');
    INSERT INTO zz.cc VALUES (s, 'business', v_b);
  END LOOP;
END \$\$;
SELECT public.billing_run_scheduled(now());
SQL

bid() { $P -c "SELECT id FROM zz.cc WHERE scenario = '$1' AND label = 'business'"; }
as_admin() { echo "SELECT set_config('request.jwt.claims', '{\"sub\":\"$ADMIN\",\"role\":\"authenticated\"}', true); SELECT set_config('request.jwt.claim.sub', '$ADMIN', true); SET LOCAL ROLE authenticated;"; }

race() {  # $1 first statement (held 3 seconds), $2 second statement (starts 1.2 seconds later), $3 'internal' to run as the system rather than as an administrator
  A_OUT=$(mktemp); B_OUT=$(mktemp)
  local who; if [ "${3:-}" = internal ]; then who=""; else who="$(as_admin)"; fi
  ( $P > "$A_OUT" 2>&1 <<SQL
BEGIN;
$who
$1
SELECT pg_sleep(3);
COMMIT;
SQL
  ) &
  local pid=$!
  sleep 1.2
  $P > "$B_OUT" 2>&1 <<SQL
BEGIN;
$who
$2
COMMIT;
SQL
  wait $pid
}

# ----- Scenario 1: two administrators activate billing at once -----------------------------------------------------------------------------------------------------
race "SELECT public.admin_billing_activate_platform(TRUE, 'ACTIVATE BILLING', 'Concurrency test A')->>'mode';" "SELECT public.admin_billing_activate_platform(TRUE, 'ACTIVATE BILLING', 'Concurrency test B')->>'mode';"
NA=$($P -c "SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing activated'")
check "1: the first administrator switched real billing on" "$(grep -q '^active' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "1: the second was told it is already on" "$(grep -q 'already switched on' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "1: one audit entry exists and every business was held back in shadow" "$([ "$NA" = "1" ] && [ "$($P -c "SELECT count(*) FROM public.billing_subscriptions WHERE billing_mode = 'shadow' AND activated_at IS NULL")" -ge 2 ] && echo true || echo false)" "audit=$NA"

# ----- Scenario 2: two administrators put the same business live at once ---------------------------------------------------------------------------------------
G=$(bid golive)
race "SELECT public.admin_billing_go_live_business('$G', NULL, 'Concurrency test A')->>'status';" "SELECT public.admin_billing_go_live_business('$G', NULL, 'Concurrency test B')->>'status';"
NG=$($P -c "SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing business went live' AND business_id = '$G'")
check "2: the first administrator put the business live (trial restarted)" "$(grep -q '^trialing' "$A_OUT" && echo true || echo false)" "$(cat "$A_OUT")"
check "2: the second was told real billing has already started" "$(grep -q 'has already started for this business' "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "2: one go-live is recorded, and the trial restarts exactly once (30 days from the single go-live)" "$([ "$NG" = "1" ] && [ "$($P -c "SELECT trial_end = activated_at + interval '30 days' FROM public.billing_subscriptions WHERE business_id = '$G'")" = "t" ] && echo true || echo false)" "audit=$NG"

# ----- Scenario 3: the account-status step runs twice at once ---------------------------------------------------------------------------------------------------------
S=$(bid status)
$P <<SQL >/dev/null
UPDATE public.billing_subscriptions SET activated_at = billing_starts_at, billing_mode = NULL, status = 'active', trial_start = NULL, trial_end = NULL WHERE business_id = '$S';
SELECT public.billing_open_periods(now());
SELECT public.billing_issue_invoices(now());
SELECT public.billing_mark_overdue(now() + interval '15 days');
SQL
INVN=$($P -c "SELECT count(*) FROM public.billing_invoices WHERE business_id = '$S' AND status = 'overdue'")
race "SELECT public.billing_advance_enforcement(now() + interval '15 days')->>'status_changes';" "SELECT public.billing_advance_enforcement(now() + interval '15 days')->>'status_changes';" internal
NP=$($P -c "SELECT count(*) FROM public.audit_logs WHERE activity = 'Billing account past due' AND business_id = '$S'")
STATUS=$($P -c "SELECT status FROM public.billing_subscriptions WHERE business_id = '$S'")
check "3: the setup has an overdue invoice" "$([ "$INVN" -ge 1 ] && echo true || echo false)" "overdue=$INVN"
check "3: the business is past due" "$([ "$STATUS" = "past_due" ] && echo true || echo false)" "$STATUS"
check "3: the second run changed nothing" "$(grep -q '^0' "$B_OUT" && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "A=$(cat "$A_OUT") B=$(cat "$B_OUT")"
check "3: one status change, one audit entry" "$([ "$NP" = "1" ] && echo true || echo false)" "audit=$NP"

# ----- Scenario 4: the notice step runs twice at once ------------------------------------------------------------------------------------------------------------------------
race "SELECT public.billing_send_notifications(now() + interval '15 days')->>'notices_sent';" "SELECT public.billing_send_notifications(now() + interval '15 days')->>'notices_sent';" internal
DUP=$($P -c "SELECT count(*) FROM (SELECT user_id, metadata ->> 'event_key' k FROM public.notifications WHERE type = 'billing' GROUP BY 1, 2 HAVING count(*) > 1) d")
SENT=$($P -c "SELECT count(*) FROM public.billing_notifications_sent")
UNIQ=$($P -c "SELECT count(DISTINCT event_key) FROM public.billing_notifications_sent")
check "4: the first run sent the notices" "$([ "$(grep -E '^[0-9]+$' "$A_OUT" | head -1)" -gt 0 ] 2>/dev/null && echo true || echo false)" "$(cat "$A_OUT")"
check "4: the second, racing it, sent none of the same notices and raised no error" "$([ "$(grep -E '^[0-9]+$' "$B_OUT" | head -1)" = "0" ] && ! grep -q ERROR "$B_OUT" && echo true || echo false)" "$(cat "$B_OUT")"
check "4: nobody received the same notice twice, and every event is recorded once" "$([ "$DUP" = "0" ] && [ "$SENT" = "$UNIQ" ] && echo true || echo false)" "dup=$DUP sent=$SENT unique=$UNIQ"

# ----- Afterwards everything reconciles ----------------------------------------------------------------------------------------------------------------------------------------------
BAD=$($P -c "SELECT count(*) FROM public.billing_reconcile() WHERE finding_count > 0 AND check_name NOT IN ('billing_queue_stuck', 'period_not_invoiced_when_it_should_be', 'invoice_overdue_but_not_marked')")
check "all: the reconciliation finds nothing wrong after the concurrent runs" "$([ "$BAD" = "0" ] && echo true || echo false)" "$($P -c "SELECT string_agg(check_name || '=' || finding_count, ';') FROM public.billing_reconcile() WHERE finding_count > 0")"

$P -c "UPDATE public.billing_settings SET mode = 'disabled', live_since = NULL" >/dev/null
exit $fail
