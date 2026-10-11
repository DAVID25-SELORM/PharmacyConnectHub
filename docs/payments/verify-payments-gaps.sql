-- Online payments, optional gaps (the supplier's own settlement view; refunds of returned goods): read-only verification.
-- Run in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first). It only reads the catalog and counts rows.
-- One row: passed should equal checks and "missing" should be empty. A missing piece is listed in "missing" and never stops the query.
WITH
  fns  AS (SELECT p.proname::text AS name, pg_get_functiondef(p.oid) AS def FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'),
  checks(item, ok) AS (VALUES
  ('function supplier_settlement_overview', EXISTS (SELECT 1 FROM fns WHERE name = 'supplier_settlement_overview')),
  ('the supplier view is limited to owner, manager, finance and accounting staff', EXISTS (SELECT 1 FROM fns WHERE name = 'supplier_settlement_overview' AND def LIKE '%''owner'', ''manager'', ''finance'', ''accountant''%')),
  ('the supplier view can be called by signed-in people and not by anonymous visitors',
    to_regprocedure('public.supplier_settlement_overview(uuid,timestamptz,timestamptz)') IS NOT NULL
    AND has_function_privilege('authenticated', 'public.supplier_settlement_overview(uuid,timestamptz,timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.supplier_settlement_overview(uuid,timestamptz,timestamptz)', 'EXECUTE')),
  ('function _refund_online_return', EXISTS (SELECT 1 FROM fns WHERE name = '_refund_online_return')),
  ('_refund_online_return is not callable by customers',
    to_regprocedure('public._refund_online_return(uuid,uuid,numeric)') IS NOT NULL AND NOT has_function_privilege('authenticated', 'public._refund_online_return(uuid,uuid,numeric)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public._refund_online_return(uuid,uuid,numeric)', 'EXECUTE')),
  ('the refund ledger accepts the reason order_return', EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'order_refunds_reason_check' AND pg_get_constraintdef(oid) LIKE '%order_return%')),
  ('resolving a return as a refund asks for the refund on an order paid online', EXISTS (SELECT 1 FROM fns WHERE name = 'resolve_order_return' AND def LIKE '%_refund_online_return(%')),
  ('return refunds are kept out of the order''s price balance', EXISTS (SELECT 1 FROM fns WHERE name = 'order_money' AND def LIKE '%r.reason <> ''order_return''%')),
  ('a price that rises again leaves return refunds alone', EXISTS (SELECT 1 FROM fns WHERE name = 'orders_effective_total_money' AND def LIKE '%rf.reason <> ''order_return''%'))
  )
SELECT count(*) AS checks, count(*) FILTER (WHERE ok) AS passed, COALESCE(string_agg(item, '; ') FILTER (WHERE NOT ok), '') AS missing,
       (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'resolve_order_return') AS resolve_versions
FROM checks;
