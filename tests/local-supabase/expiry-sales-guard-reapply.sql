-- Run after expiry-sales-guard.sql AND a second application of 20261209100000_expiry_sales_guard.sql: applying it again must change nothing.
SELECT zz.check('re-applying leaves exactly one guard call in each selling function',
  (SELECT count(*) FROM pg_proc WHERE proname IN ('create_marketplace_orders', 'award_rfq_quote', 'award_rfq_lines', 'advance_backorder_shipment')
     AND (length(prosrc) - length(replace(prosrc, '_expiry_guard(', ''))) / length('_expiry_guard(') = 1) = 4);
SELECT zz.check('re-applying does not reset the mode an administrator chose', public.expiry_guard_mode() = 'observe');
SELECT zz.check('re-applying keeps the record of what the guard saw', (SELECT count(*) FROM public.expiry_guard_events) >= 4);
