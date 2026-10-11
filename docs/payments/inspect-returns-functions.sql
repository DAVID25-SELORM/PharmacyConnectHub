-- Read-only DRY RUN for the Pay Now optional-gap patches (20261112120000_payments_returns_patches.sql). Run it in the SQL Editor of the PRODUCTION project (check the project name and the
-- PRODUCTION badge first). It changes nothing. For each function the patches rewrite it shows how many versions exist and how many times the text the patch looks for is present:
--   versions  must be 1;   matches  must be 1 for every row (or already_patched = true once the patch has been applied).
-- If any row is not as expected, DO NOT run the patches: tell me which row, and I will adapt them to what production really has (the patches would refuse anyway, but this shows why).
WITH defs AS (
  SELECT p.proname::text AS fn, pg_get_functiondef(p.oid) AS def, count(*) OVER (PARTITION BY p.proname) AS versions
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('resolve_order_return', 'orders_effective_total_money', 'order_money')
), probes(fn, what, pattern, marker) AS (VALUES
  ('resolve_order_return', 'the audit entry the refund is placed before', 'PERFORM public\.write_audit_log\(''Return resolved'', v_name,', '_refund_online_return('),
  ('orders_effective_total_money', 'the netting of unsent refunds', 'WHERE a\.order_id = NEW\.id AND rf\.status IN \(''requested'', ''approved''\) ORDER BY rf\.created_at DESC', 'AND rf.reason <>'),
  ('order_money', 'the balance (replaced whole: must be the P4b version)', 'AS alive\s+FROM public\.orders o WHERE o\.id = p_order_id', 'r.reason <> ')
)
SELECT pr.fn AS function_name, pr.what, COALESCE(max(d.versions), 0) AS versions,
       (SELECT count(*) FROM regexp_matches(max(d.def), pr.pattern, 'g')) AS matches,
       position(pr.marker IN max(d.def)) > 0 AS already_patched
FROM probes pr LEFT JOIN defs d ON d.fn = pr.fn
GROUP BY pr.fn, pr.what, pr.pattern, pr.marker
ORDER BY pr.fn;
