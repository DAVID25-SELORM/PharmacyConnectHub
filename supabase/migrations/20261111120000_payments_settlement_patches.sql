-- Online payments (Pay Now), phase P5 part 3: checkout refuses "Pay now" for a supplier that cannot receive online payments yet (only while the platform is in split mode;
-- with the default settings nothing changes). A fail-closed in-place patch of the live six-argument create_marketplace_orders: it must match exactly once, otherwise it stops
-- without changing anything, and it is safe to re-run. Run docs/payments/inspect-settlement-functions.sql first (read-only) to see that it will match.

-- The same, for a function that has more than one version: names the exact argument list (as pg_get_function_identity_arguments prints it) and
-- changes only that version. Any other version is left exactly as it is. Fails closed in the same ways.
CREATE OR REPLACE FUNCTION public.apply_function_regex_patch_sig(
  p_function_name TEXT, p_identity_arguments TEXT, p_pattern TEXT, p_replacement TEXT, p_expected INTEGER, p_applied_marker TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_oids OID[];
  v_def TEXT;
  v_count INTEGER;
BEGIN
  SELECT array_agg(p.oid) INTO v_oids FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_function_name AND pg_get_function_identity_arguments(p.oid) = p_identity_arguments;
  IF v_oids IS NULL THEN
    RAISE EXCEPTION 'Function %(%) was not found. Nothing was changed.', p_function_name, p_identity_arguments;
  END IF;
  v_def := replace(pg_get_functiondef(v_oids[1]), E'\r', '');
  IF position(p_applied_marker IN v_def) > 0 THEN
    RETURN 'already patched';
  END IF;
  SELECT count(*) INTO v_count FROM regexp_matches(v_def, p_pattern, 'g');
  IF v_count <> p_expected THEN
    RAISE EXCEPTION 'Unexpected definition of % (expected % match(es) of %, found %). Nothing was changed.', p_function_name, p_expected, p_pattern, v_count;
  END IF;
  EXECUTE regexp_replace(v_def, p_pattern, p_replacement, 'g');
  RETURN 'patched';
END;
$$;
REVOKE ALL ON FUNCTION public.apply_function_regex_patch_sig(TEXT, TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;

-- The supplier named for "pay_now" must have an active settlement account (when the platform is in split mode). It is made at the same place as the "online payments are off"
-- refusal, so no order is created.
SELECT public.apply_function_regex_patch_sig('create_marketplace_orders', '_caller_id uuid, _pharmacy_id uuid, _items jsonb, _credit_wholesaler_ids uuid[], _require_classification boolean, _settlement_methods jsonb',
  'RAISE EXCEPTION ''Online payment is not available yet\. Choose another payment method\.'';\s+END IF;',
  'RAISE EXCEPTION ''Online payment is not available yet. Choose another payment method.'';' || E'\n'
  || '  END IF;' || E'\n'
  || '  IF EXISTS (SELECT 1 FROM jsonb_each_text(_settlement_methods) m WHERE m.value = ''pay_now'' AND m.key ~* ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''' || E'\n'
  || '             AND NOT public.payout_account_ready(m.key::UUID, ''paystack'', (SELECT s.mode FROM public.payments_settings s WHERE s.id))) THEN' || E'\n'
  || '    RAISE EXCEPTION ''A supplier in this order cannot take online payments yet. Choose another payment method for it.'';' || E'\n'
  || '  END IF;',
  1, 'payout_account_ready(m.key');
