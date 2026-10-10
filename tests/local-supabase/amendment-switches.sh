#!/bin/bash
# Checks the "switch off new work" scripts in docs/order-amendments/switches against the local stack:
#   * after off-all.sql an authenticated user cannot START new work (the four propose / create / submit functions are refused), but can
#     still FINISH what is in progress (the responding, withdrawing, advancing and deciding functions are still callable);
#   * each single off-*.sql switches off only its own function;
#   * after on-all.sql everything is callable again, exactly as before;
#   * the service role keeps its access throughout.
# "Callable" means the call gets past the permission check: it may still fail for a normal reason (the id does not exist).
# Run on the local Docker stack after setup.sql and the migrations through 20261105120000 (no fixture data needed).
set -u
C=${DB_CONTAINER:-supabase_db_drugxone-local-validation}
D="$(cd "$(dirname "$0")/../.." && pwd)/docs/order-amendments/switches"
P="docker exec -i $C psql -U postgres -v ON_ERROR_STOP=1 -At"
fail=0
check() { if [ "$2" = "true" ]; then echo "PASS | $1"; else echo "FAIL | $1 ($3)"; fail=1; fi; }

# Prints "denied" or "callable" for one call made as an authenticated user (callable = it got past the permission check).
probe_msg() { $P <<SQL 2>&1 | grep -E "NOTICE:  (denied|callable)" | sed 's/.*NOTICE:  //' | tail -1
DO \$\$
BEGIN
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    PERFORM $1;
    RAISE NOTICE 'callable';
  EXCEPTION
    WHEN insufficient_privilege THEN RAISE NOTICE 'denied';
    WHEN OTHERS THEN RAISE NOTICE 'callable';
  END;
END \$\$;
SQL
}
U="gen_random_uuid()"
START=("public.propose_partial_fulfilment($U, 'x', '[]'::jsonb, $U)"
       "public.propose_price_amendment($U, 'x', '[]'::jsonb, $U)"
       "public.create_backorder_shipment($U, '[]'::jsonb, NULL, $U)"
       "public.submit_delivery_report($U, NULL, '[]'::jsonb, NULL, $U)")
FINISH=("public.respond_to_amendment($U, 'reject', NULL)"
        "public.withdraw_amendment($U, NULL)"
        "public.answer_amendment_clarification($U, 'x')"
        "public.respond_to_price_amendment($U, 'reject', NULL)"
        "public.withdraw_price_amendment($U, NULL)"
        "public.answer_price_clarification($U, 'x')"
        "public.advance_backorder_shipment($U, 'packed')"
        "public.cancel_backorder_shipment($U, 'x')"
        "public.cancel_backorder_remaining($U, 'x')"
        "public.withdraw_delivery_report($U)"
        "public.resolve_delivery_report($U, '[]'::jsonb, NULL)"
        "public.confirm_cash_collection($U, NULL)")
all_start() { # $1 expected (denied|callable)
  local ok=true detail=""
  for s in "${START[@]}"; do r=$(probe_msg "$s"); [ "$r" = "$1" ] || { ok=false; detail="$detail ${s%%(*}=$r"; }; done
  echo "$ok|$detail"
}
all_finish() {
  local ok=true detail=""
  for s in "${FINISH[@]}"; do r=$(probe_msg "$s"); [ "$r" = "callable" ] || { ok=false; detail="$detail ${s%%(*}=$r"; }; done
  echo "$ok|$detail"
}
apply() { $P < "$D/$1" >/dev/null; }

# Start from the normal state.
apply on-all.sql
r=$(all_start callable); check "normal state: all four ways to start new work are callable" "${r%%|*}" "${r#*|}"

apply off-all.sql
r=$(all_start denied); check "off-all: starting new work is refused (supply change, price change, back-order shipment, delivery report)" "${r%%|*}" "${r#*|}"
r=$(all_finish); check "off-all: everything already in progress can still be finished (12 functions still callable)" "${r%%|*}" "${r#*|}"
check "off-all: the service role keeps its access" "$([ "$($P -c "SELECT has_function_privilege('service_role', 'public.propose_partial_fulfilment(uuid, text, jsonb, uuid)', 'EXECUTE')")" = "t" ] && echo true || echo false)" ""
check "off-all: anonymous users never had access" "$([ "$($P -c "SELECT has_function_privilege('anon', 'public.propose_price_amendment(uuid, text, jsonb, uuid)', 'EXECUTE')")" = "f" ] && echo true || echo false)" ""

apply on-all.sql
r=$(all_start callable); check "on-all: everything is callable again" "${r%%|*}" "${r#*|}"

# Each single switch touches only its own function.
declare -A OWN=( [supply-changes]=0 [price-changes]=1 [backorder-shipments]=2 [delivery-reports]=3 )
for key in supply-changes price-changes backorder-shipments delivery-reports; do
  apply "off-$key.sql"
  ok=true; detail=""
  for i in 0 1 2 3; do
    r=$(probe_msg "${START[$i]}")
    if [ "$i" = "${OWN[$key]}" ]; then want=denied; else want=callable; fi
    [ "$r" = "$want" ] || { ok=false; detail="$detail ${START[$i]%%(*}=$r(want $want)"; }
  done
  check "off-$key: only its own function is refused" "$ok" "$detail"
  apply "on-$key.sql"
  r=$(all_start callable); check "on-$key: restored" "${r%%|*}" "${r#*|}"
done

# Leave the stack in the normal state.
apply on-all.sql
exit $fail
