-- Order amendments: switch ON -- Supply changes (a wholesaler proposing to supply less)
-- Effect: Restores the ability to start new work, exactly as before.
-- Nothing is deleted or changed in any order, ledger entry or record; reading is untouched. The screens still show the
-- button; using it shows a 'switched off' message. Reverse it with the matching on-*.sql file.
-- Run it in the SQL Editor of the PRODUCTION project (check the project name and the PRODUCTION badge first).

GRANT EXECUTE ON FUNCTION public.propose_partial_fulfilment(UUID, TEXT, JSONB, UUID) TO authenticated;
