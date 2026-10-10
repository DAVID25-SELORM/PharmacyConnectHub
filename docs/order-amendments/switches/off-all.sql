-- Order amendments: switch OFF -- all four kinds of new work
-- Effect: Stops all NEW work of the four kinds above (supply changes, price changes, back-order shipments, delivery reports). Everything already in progress can still be finished or closed.
-- Nothing is deleted or changed in any order, ledger entry or record; reading is untouched. The screens still show the
-- button; using it shows a 'switched off' message. Reverse it with the matching on-*.sql file.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first).

REVOKE EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) TO service_role;
REVOKE EXECUTE ON FUNCTION public.propose_price_amendment(UUID, TEXT, JSONB, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_price_amendment(UUID, TEXT, JSONB, UUID) TO service_role;
REVOKE EXECUTE ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) TO service_role;
REVOKE EXECUTE ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) TO service_role;
