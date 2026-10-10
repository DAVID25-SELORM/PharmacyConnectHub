-- Order amendments: switch OFF -- Back-order shipments (preparing a new shipment for goods still owed)
-- Effect: Nobody can prepare a new back-order shipment. Shipments already prepared can still be packed, dispatched, delivered or cancelled, and the remaining back-order can still be cancelled.
-- Nothing is deleted or changed in any order, ledger entry or record; reading is untouched. The screens still show the
-- button; using it shows a 'switched off' message. Reverse it with the matching on-*.sql file.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first).

REVOKE EXECUTE ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_backorder_shipment(UUID, JSONB, TEXT, UUID) TO service_role;
