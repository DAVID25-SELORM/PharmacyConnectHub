-- Order amendments: switch OFF -- Supply changes (a wholesaler proposing to supply less)
-- Effect: Nobody can start a new supply-change proposal. Proposals already open can still be answered, questioned, withdrawn or applied.
-- Nothing is deleted or changed in any order, ledger entry or record; reading is untouched. The screens still show the
-- button; using it shows a 'switched off' message. Reverse it with the matching on-*.sql file.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first).

REVOKE EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) TO service_role;
