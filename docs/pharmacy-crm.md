# Pharmacy Representatives / CRM

Apply `supabase/migrations/20261018100000_pharmacy_representative_crm.sql` before using `/pharmacy/contacts`. This additive migration requires no backfill. It has been tested locally; production migration application is a separate deployment step.

Verified pharmacy owners and managers can manage private representatives, companies, products/brands, interactions, follow-ups and explicit order/RFQ/quotation links. Representatives are external contacts, not staff accounts. Archive preserves history and clears designated-representative status; restore does not automatically re-designate a rep.

Visits and their follow-ups save atomically. Samples are descriptive and never update stock. No external messages or reminders are sent. Linked procurement records must belong to the pharmacy. Company and catalogue links are optional, supporting unregistered manufacturers and manually entered brands.

Lists have search, filters and 25-row pages; external selectors show up to 30 search matches. CRM reads use batches. Very large histories will benefit from server-side profile pagination in a subsequent scaling pass. Excel/PDF exports include the filtered representatives. Optional Excel import is deferred.

RLS covers every CRM table. Clients cannot write directly; the mutation RPC controls tenant and actor fields. Full before/after history stays in the private CRM; the general Audit Centre receives metadata only. Platform admins have no automatic CRM access.

Validation: `tests/local-supabase/pharmacy-crm.sql` (only against isolated credit_review_clean fixtures), `src/lib/pharmacy-crm.test.ts`, TypeScript, targeted ESLint, production build. Database tests roll back their data.

Chrome verification used an isolated mock-data preview: checked 25-row pagination, brand search, profile layout and visit form/save. No production CRM records or transactions were created.
