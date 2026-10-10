-- Online payments (Pay Now), phase P2 part 2: fail-closed in-place patches so that checkout can create an online order, only while the
-- platform's switch is on. Each patch rebuilds the LIVE definition, must match exactly the expected number of times, otherwise
-- stops without changing anything, and is safe to re-run. With the switch off (the default) checkout behaves exactly as before.
--
--   1. create_marketplace_orders: "pay_now" becomes an accepted method, but is refused with the same message as before unless
--      public.online_payments_enabled(); an order placed with it is an online order (payment_method 'paystack'), unpaid.
--   2. notify_new_order: the wholesaler is not told about an online order until it is paid.
--   3. notify_payment_status_changed: ... and when it is paid, the wholesaler is told it is a new, paid order ready to accept.
--   4. change_order_settlement_method: an online-payment order keeps its payment method.
--   5. apply_payment_result: a repeated failed/abandoned report of an unchanged attempt is not logged again.

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

-- 1a. "pay_now" is a known method (refused below unless the switch is on).
SELECT public.apply_function_regex_patch('create_marketplace_orders',
  'WHERE m\.value NOT IN \(''cod'', ''credit'', ''bank_transfer'', ''momo'', ''cheque'', ''other''\) LIMIT 1;',
  'WHERE m.value NOT IN (''pay_now'', ''cod'', ''credit'', ''bank_transfer'', ''momo'', ''cheque'', ''other'') LIMIT 1;',
  1, 'm.value NOT IN (''pay_now''');

-- 1b. ... and refused with the old message while online payments are off.
SELECT public.apply_function_regex_patch('create_marketplace_orders',
  'IF v_bad_method IS NOT NULL THEN\s+IF v_bad_method = ''pay_now'' THEN RAISE EXCEPTION ''Online payment is not available yet\. Choose another payment method\.''; END IF;\s+RAISE EXCEPTION ''Invalid payment method\.'';\s+END IF;',
  'IF v_bad_method IS NOT NULL THEN' || E'\n'
  || '    RAISE EXCEPTION ''Invalid payment method.'';' || E'\n'
  || '  END IF;' || E'\n'
  || '  IF EXISTS (SELECT 1 FROM jsonb_each_text(_settlement_methods) m WHERE m.value = ''pay_now'') AND NOT public.online_payments_enabled() THEN' || E'\n'
  || '    RAISE EXCEPTION ''Online payment is not available yet. Choose another payment method.'';' || E'\n'
  || '  END IF;',
  1, 'AND NOT public.online_payments_enabled()');

-- 1c. An online order is stored as an online order.
SELECT public.apply_function_regex_patch('create_marketplace_orders',
  'v_discount_total, v_fee, v_goods \+ v_fee, ''cod'', v_use_credit,',
  'v_discount_total, v_fee, v_goods + v_fee, (CASE WHEN v_method = ''pay_now'' THEN ''paystack'' ELSE ''cod'' END)::public.payment_method, v_use_credit,',
  1, 'THEN ''paystack'' ELSE ''cod'' END');

-- 2. The wholesaler hears about an online order when it is paid, not when it is placed.
SELECT public.apply_function_regex_patch('notify_new_order',
  'BEGIN\s+SELECT name INTO v_pharmacy FROM public\.businesses WHERE id = NEW\.pharmacy_id;',
  'BEGIN' || E'\n'
  || '    IF NEW.payment_method::TEXT = ''paystack'' THEN RETURN NEW; END IF;' || E'\n'
  || '    SELECT name INTO v_pharmacy FROM public.businesses WHERE id = NEW.pharmacy_id;',
  1, 'IF NEW.payment_method::TEXT = ''paystack'' THEN RETURN NEW; END IF;');

-- 3. ... and when it is paid they are told it is a new order they can accept (they were not told when it was placed).
SELECT public.apply_function_regex_patch('notify_payment_status_changed',
  '''Payment received'',\s+''Online payment received for order #'' \|\| NEW\.order_number \|\| ''\.''',
  '''New paid order'',' || E'\n'
  || '          ''Order #'' || NEW.order_number || '' has been paid online and is ready for you to accept.''',
  1, '''New paid order''');

-- 4. An online-payment order keeps its payment method: it is paid through the provider or not at all. (Changing it to cash or
-- anything else would leave a paid-online order that nobody can accept, or a cash order the provider could still charge.)
SELECT public.apply_function_regex_patch('change_order_settlement_method',
  'o\.is_credit_order, o\.settlement_method\s+INTO v_order FROM public\.orders o WHERE o\.id = p_order_id FOR UPDATE;',
  'o.is_credit_order, o.settlement_method, o.payment_method' || E'\n'
  || '    INTO v_order FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;',
  1, 'o.settlement_method, o.payment_method');

SELECT public.apply_function_regex_patch('change_order_settlement_method',
  'IF v_order\.is_credit_order THEN\s+RAISE EXCEPTION ''A credit order''''s payment method can''''t be changed; it is backed by a credit invoice\.'';\s+END IF;',
  'IF v_order.is_credit_order THEN' || E'\n'
  || '    RAISE EXCEPTION ''A credit order''''s payment method can''''t be changed; it is backed by a credit invoice.'';' || E'\n'
  || '  END IF;' || E'\n'
  || '  IF v_order.payment_method::TEXT = ''paystack'' THEN' || E'\n'
  || '    RAISE EXCEPTION ''An online-payment order''''s payment method can''''t be changed. Cancel it and place a new order instead.'';' || E'\n'
  || '  END IF;',
  1, 'An online-payment order''s payment method');

-- 5. A failed or abandoned attempt that is reported again with the same status (the return page asks every few seconds) changes and
-- logs nothing the second time. (The payment core, P1, already settles such a repeat correctly; this only keeps the log readable.)
SELECT public.apply_function_regex_patch('apply_payment_result',
  'IF p_provider_status IN \(''failed'', ''abandoned''\) THEN\s+UPDATE public\.order_payment_attempts SET status = p_provider_status',
  'IF p_provider_status IN (''failed'', ''abandoned'') AND v_a.status = p_provider_status THEN' || E'\n'
  || '    RETURN jsonb_build_object(''outcome'', p_provider_status, ''attempt_id'', v_a.id, ''order_id'', v_order_id, ''repeat'', TRUE);' || E'\n'
  || '  END IF;' || E'\n'
  || '  IF p_provider_status IN (''failed'', ''abandoned'') THEN' || E'\n'
  || '    UPDATE public.order_payment_attempts SET status = p_provider_status',
  1, '''repeat'', TRUE');
