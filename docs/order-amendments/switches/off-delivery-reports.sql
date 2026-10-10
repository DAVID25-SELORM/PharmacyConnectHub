-- Order amendments: switch OFF -- Delivery reports (a pharmacy reporting missing, damaged or rejected goods)
-- Effect: Nobody can submit a new delivery report. Reports already submitted can still be withdrawn or decided.
-- Nothing is deleted or changed in any order, ledger entry or record; reading is untouched. The screens still show the
-- button; using it shows a 'switched off' message. Reverse it with the matching on-*.sql file.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first).

REVOKE EXECUTE ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_delivery_report(UUID, UUID, JSONB, TEXT, UUID) TO service_role;
