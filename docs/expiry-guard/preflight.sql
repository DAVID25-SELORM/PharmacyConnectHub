-- READ-ONLY pre-flight for 20261209100000_expiry_sales_guard.sql. Run in the PRODUCTION SQL Editor (PharmacyConnectHub) BEFORE applying. Nothing here writes.
-- The migration changes five functions by exact text and stops, changing nothing, if any text is not found exactly once.
-- This runs the same test: every row should say ok = true. On a database that has not had the migration, ok = true means the text was found exactly once (matches = 1) and already_patched = false.
WITH f(label, sig, fragment) AS (VALUES
  ('checkout (marketplace orders)', 'public.create_marketplace_orders(uuid,uuid,jsonb,uuid[],boolean,jsonb)'::regprocedure, E'    IF v_product.stock < v_product.quantity THEN RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name; END IF;\n'),
  ('RFQ award, whole quote', 'public.award_rfq_quote(uuid,uuid,boolean)'::regprocedure, E'    IF v_item.stock < v_item.quantity THEN\n      RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_item.stock, v_item.product_name;\n    END IF;\n'),
  ('RFQ award, by line', 'public.award_rfq_lines(uuid,jsonb,boolean)'::regprocedure, E'      IF v_product.stock < v_line.qty THEN\n        RAISE EXCEPTION ''Only % unit(s) of % are currently available.'', v_product.stock, v_product.name;\n      END IF;\n'),
  ('storefront catalogue', 'public.list_marketplace_catalogue()'::regprocedure, E'        SELECT jsonb_agg(to_jsonb(p) || jsonb_build_object(
          ''minimum_order_quantity'', w.minimum_order_quantity,'),
  ('back-order shipment', 'public.advance_backorder_shipment(uuid,text)'::regprocedure, E'        IF v_stock < v_line.quantity THEN\n          RAISE EXCEPTION ''Not enough stock of % to dispatch this shipment (% in stock, % needed). Receive the goods into stock first.'',\n            v_line.product_name, v_stock, v_line.quantity;\n        END IF;\n')
), body AS (
  SELECT label, replace(pg_get_functiondef(sig), E'', '') AS def, replace(fragment, E'', '') AS fragment FROM f
)
SELECT label AS check_name,
       (length(def) - length(replace(def, fragment, ''))) / length(fragment) AS matches,
       (length(def) - length(replace(def, fragment, ''))) / length(fragment) = 1
         OR strpos(def, '_expiry_guard') > 0 OR strpos(def, 'available_stock') > 0 AS ok,
       strpos(def, '_expiry_guard') > 0 OR strpos(def, 'available_stock') > 0 AS already_patched
FROM body
UNION ALL
SELECT 'batches table exists', 1, to_regclass('public.product_batches') IS NOT NULL, false
UNION ALL
SELECT 'helper functions exist (has_role, can_act_for_business, write_audit_log)', 3,
       to_regprocedure('public.has_role(uuid,public.app_role)') IS NOT NULL
         AND to_regprocedure('public.can_act_for_business(uuid,text)') IS NOT NULL
         AND to_regprocedure('public.write_audit_log(text,text,text,uuid,text,jsonb,uuid,text,text,uuid)') IS NOT NULL, false
UNION ALL
SELECT 'guard tables not already present', 0, to_regclass('public.expiry_guard_policy') IS NULL, to_regclass('public.expiry_guard_policy') IS NOT NULL
UNION ALL
SELECT 'this is pre-flight v2 (line-ending safe)', 0, true, false;

-- If the first query shows already_patched = true for every row, the migration was already applied: do not apply it again.
