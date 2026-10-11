-- Online payments (Pay Now), optional gap 2 part 2: two fail-closed in-place patches (each rebuilds the LIVE definition, must match exactly once, otherwise stops without changing
-- anything, and is safe to re-run). Run docs/payments/inspect-returns-functions.sql first (read-only).
--   1. resolve_order_return: resolving a return as "refund" on an order paid online asks for the refund (_refund_online_return).
--   2. orders_effective_total_money: the netting of unsent refunds when a price rises again leaves return refunds alone.

-- The patch helper (the same definition as in the effective-total migration, repeated so this file runs on its own).
CREATE OR REPLACE FUNCTION public.apply_function_regex_patch(
  p_function_name TEXT, p_pattern TEXT, p_replacement TEXT, p_expected INTEGER, p_applied_marker TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_oids OID[];
  v_def TEXT;
  v_count INTEGER;
BEGIN
  SELECT array_agg(p.oid) INTO v_oids FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_function_name;
  IF v_oids IS NULL THEN
    RETURN 'not present';
  END IF;
  IF array_length(v_oids, 1) <> 1 THEN
    RAISE EXCEPTION 'Function % has % overloads; patch it by signature instead. Nothing was changed.', p_function_name, array_length(v_oids, 1);
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
REVOKE ALL ON FUNCTION public.apply_function_regex_patch(TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;

-- 1. Resolving a return as a refund on an order paid online asks for the refund (the rest of the function is untouched).
SELECT public.apply_function_regex_patch('resolve_order_return',
  'PERFORM public\.write_audit_log\(''Return resolved'', v_name,',
  'IF p_resolution = ''refund'' THEN PERFORM public._refund_online_return(v_return.id, v_return.order_id, v_total); END IF;' || E'\n'
  || '  PERFORM public.write_audit_log(''Return resolved'', v_name,',
  1, '_refund_online_return(');

-- 2. A price that rises again never cancels a refund that is for a returned item.
SELECT public.apply_function_regex_patch('orders_effective_total_money',
  'WHERE a\.order_id = NEW\.id AND rf\.status IN \(''requested'', ''approved''\) ORDER BY rf\.created_at DESC',
  'WHERE a.order_id = NEW.id AND rf.status IN (''requested'', ''approved'') AND rf.reason <> ''order_return'' ORDER BY rf.created_at DESC',
  1, 'AND rf.reason <>');
