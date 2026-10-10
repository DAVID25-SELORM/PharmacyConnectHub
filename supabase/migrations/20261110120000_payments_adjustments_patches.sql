-- Online payments (Pay Now), phase P4b part 3: fail-closed in-place patches, so that amendments are allowed on an order that was PAID ONLINE (the money consequences are
-- handled by the rule in 20261110110000: a refund of what the order no longer costs, a top-up for what it now costs more). Each patch rebuilds the LIVE definition, must
-- match exactly the expected number of times, otherwise stops without changing anything, and is safe to re-run. Cash and credit orders behave exactly as before.
-- Run AFTER 20261110100000 and 20261110110000 (the patches call order_is_online and _apply_topup_success).
--
--   1-3. propose_partial_fulfilment, propose_price_amendment, respond_to_price_amendment: the "already paid, needs a refund" refusal no longer applies to an online order.
--   4.   resolve_delivery_report: the same refusal for a delivery-problem credit; and the credit is marked as a delivery credit so its refund always waits for an administrator.
--   5-6. apply_payment_result: an extra payment (top-up) is judged on its own rules (a repeat of a settled one changes nothing; a new one goes to _apply_topup_success).

-- The patch helper (the same definition as in the earlier payments migrations, repeated so this file runs on its own).
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

-- 1. A supply change can be proposed on an order paid online.
SELECT public.apply_function_regex_patch('propose_partial_fulfilment',
  'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing it needs a refund',
  'IF NOT v_order.is_credit_order AND v_order.payment_status = ''paid'' AND NOT public.order_is_online(v_order.id) THEN' || E'\n'
  || '    RAISE EXCEPTION ''This order has already been paid. Changing it needs a refund',
  1, 'AND NOT public.order_is_online(v_order.id)');

-- 2. A price change can be proposed on an order paid online.
SELECT public.apply_function_regex_patch('propose_price_amendment',
  'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing its price needs a refund',
  'IF NOT v_order.is_credit_order AND v_order.payment_status = ''paid'' AND NOT public.order_is_online(v_order.id) THEN' || E'\n'
  || '    RAISE EXCEPTION ''This order has already been paid. Changing its price needs a refund',
  1, 'AND NOT public.order_is_online(v_order.id)');

-- 3. ... and accepted.
SELECT public.apply_function_regex_patch('respond_to_price_amendment',
  'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing its price needs a refund',
  'IF NOT v_order.is_credit_order AND v_order.payment_status = ''paid'' AND NOT public.order_is_online(v_order.id) THEN' || E'\n'
  || '    RAISE EXCEPTION ''This order has already been paid. Changing its price needs a refund',
  1, 'AND NOT public.order_is_online(v_order.id)');

-- 4a. A delivery problem can be credited on an order paid online.
SELECT public.apply_function_regex_patch('resolve_delivery_report',
  'IF v_credit > 0 AND NOT v_order\.is_credit_order\s+AND \(v_order\.payment_status = ''paid''',
  'IF v_credit > 0 AND NOT v_order.is_credit_order AND NOT public.order_is_online(v_order.id)' || E'\n'
  || '     AND (v_order.payment_status = ''paid''',
  1, 'AND NOT public.order_is_online(v_order.id)');

-- 4b. ... and the refund it causes is marked as a delivery credit, which always waits for an administrator's approval.
SELECT public.apply_function_regex_patch('resolve_delivery_report',
  'PERFORM public\._allow_order_total_change\(\);\s+UPDATE public\.orders SET effective_total_ghs = GREATEST\(COALESCE\(v_order\.effective_total_ghs, v_order\.total_ghs\) - v_credit, 0\) WHERE id = v_order_id;',
  'PERFORM set_config(''drugxone.refund_reason'', ''delivery_credit'', TRUE);' || E'\n'
  || '    PERFORM public._allow_order_total_change();' || E'\n'
  || '    UPDATE public.orders SET effective_total_ghs = GREATEST(COALESCE(v_order.effective_total_ghs, v_order.total_ghs) - v_credit, 0) WHERE id = v_order_id;',
  1, 'drugxone.refund_reason');

-- 5. A repeat of an extra payment that already settled changes nothing, and counts as paid only if it succeeded.
SELECT public.apply_function_regex_patch('apply_payment_result',
  '-- Something already settled: a repeat changes nothing\.',
  '-- An extra payment that already settled: a repeat changes nothing, and it counts as paid only if it succeeded.' || E'\n'
  || '  IF v_a.purpose = ''top_up'' AND v_a.status IN (''succeeded'', ''flagged'') THEN' || E'\n'
  || '    RETURN jsonb_build_object(''outcome'', ''duplicate'', ''attempt_id'', v_a.id, ''order_id'', v_order_id, ''order_paid'', v_a.status = ''succeeded'' AND NOT v_a.refund_required);' || E'\n'
  || '  END IF;' || E'\n'
  || E'\n'
  || '  -- Something already settled: a repeat changes nothing.',
  1, 'v_a.purpose = ''top_up'' AND v_a.status IN');

-- 6. A new extra payment is judged on its own rules.
SELECT public.apply_function_regex_patch('apply_payment_result',
  '-- ----- the provider says success: every check must hold',
  '-- ----- an extra payment for a price change is judged on its own rules' || E'\n'
  || '  IF v_a.purpose = ''top_up'' THEN' || E'\n'
  || '    RETURN public._apply_topup_success(v_a.id, v_order_id, p_amount_minor, p_currency, p_transaction_id, p_channel, p_fee_minor, v_source, p_event_id);' || E'\n'
  || '  END IF;' || E'\n'
  || E'\n'
  || '  -- ----- the provider says success: every check must hold',
  1, 'public._apply_topup_success(');
