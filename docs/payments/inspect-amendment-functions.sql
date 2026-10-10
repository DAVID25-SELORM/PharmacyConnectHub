-- Read-only DRY RUN for the Pay Now P4b patches (20261110120000_payments_adjustments_patches.sql). Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION
-- badge first). It changes nothing. For each function the patches rewrite it shows how many versions exist and how many times the text the patch looks for is present:
--   versions  must be 1;   matches  must be 1 for every row (or already_patched = true once the patch has been applied).
-- If any row is not as expected, DO NOT run the patches: tell me which row, and I will adapt them to what production really has (the patches would refuse anyway, but this shows why).
WITH defs AS (
  SELECT p.proname::text AS fn, pg_get_functiondef(p.oid) AS def, count(*) OVER (PARTITION BY p.proname) AS versions
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname IN ('propose_partial_fulfilment', 'propose_price_amendment', 'respond_to_price_amendment', 'resolve_delivery_report', 'apply_payment_result')
), probes(fn, what, pattern, marker) AS (VALUES
  ('propose_partial_fulfilment', 'the "already paid" refusal',
     'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing it needs a refund', 'AND NOT public.order_is_online(v_order.id)'),
  ('propose_price_amendment', 'the "already paid" refusal',
     'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing its price needs a refund', 'AND NOT public.order_is_online(v_order.id)'),
  ('respond_to_price_amendment', 'the "already paid" refusal',
     'IF NOT v_order\.is_credit_order AND v_order\.payment_status = ''paid'' THEN\s+RAISE EXCEPTION ''This order has already been paid\. Changing its price needs a refund', 'AND NOT public.order_is_online(v_order.id)'),
  ('resolve_delivery_report', 'the credit refusal',
     'IF v_credit > 0 AND NOT v_order\.is_credit_order\s+AND \(v_order\.payment_status = ''paid''', 'AND NOT public.order_is_online(v_order.id)'),
  ('resolve_delivery_report', 'the order total update for a credit',
     'PERFORM public\._allow_order_total_change\(\);\s+UPDATE public\.orders SET effective_total_ghs = GREATEST\(COALESCE\(v_order\.effective_total_ghs, v_order\.total_ghs\) - v_credit, 0\) WHERE id = v_order_id;', 'drugxone.refund_reason'),
  ('apply_payment_result', 'the "already settled" comment', '-- Something already settled: a repeat changes nothing\.', 'v_a.purpose = ''top_up'' AND v_a.status IN'),
  ('apply_payment_result', 'the "every check must hold" comment', '-- ----- the provider says success: every check must hold', 'public._apply_topup_success(')
)
SELECT pr.fn AS function_name, pr.what, COALESCE(max(d.versions), 0) AS versions,
       (SELECT count(*) FROM regexp_matches(max(d.def), pr.pattern, 'g')) AS matches,
       position(pr.marker IN max(d.def)) > 0 AS already_patched
FROM probes pr LEFT JOIN defs d ON d.fn = pr.fn
GROUP BY pr.fn, pr.what, pr.pattern, pr.marker
ORDER BY pr.fn, pr.what;
