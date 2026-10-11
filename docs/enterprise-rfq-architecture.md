# Enterprise RFQ architecture and implementation review

Status: local implementation and repository push authorized. Production migrations remain for the user to apply.

## A. Existing architecture
React 19, TanStack file routes, Supabase Postgres/RLS/RPC, React Query, shadcn controls, Vitest and local Supabase SQL integration tests. RFQ routes and components already exist. Mutations run through privileged RPCs; table reads use RLS. In-app notifications are transactional database records. Vercel currently has twelve function entry points, so this work must not introduce additional serverless endpoints.

## B. Reuse and integration map
Reuse rfqs, rfq_items, rfq_invitees, rfq_quotes, rfq_quote_items and rfq_awards. Reuse master_products for requested identity and wholesaler_products/products for offered stock. Confirmed awards use create_marketplace_orders, preserving current credit exposure, scheduled terms, overrides, classification, stock deduction, order integrity triggers and settlement rules. Existing orders, procurements, order_items, credit ledger, cancellation, deliveries, receipts, returns, amendments and printable order documents remain authoritative. Reuse notify_business and write_audit_log. Keep the existing Excel parser and medicine picker, retaining canonical IDs rather than only labels.

## C. Gaps
Current RFQs publish immediately; drafts exist only in localStorage. Submitted quotations are overwritten. Awards immediately create orders through older duplicated stock/credit code. No supplier confirmation, immutable revision allocation, structured negotiation, deadline reminders, durable request deduplication or complete lifecycle. Inbox/history loads are unbounded. Broad administrative SELECT policies expose commercial data without an investigation audit. Medicine selections discard canonical identity. These must be addressed before considering the brief complete.

## D. Database design
Add fields to existing headers and requirements. Add immutable quotation snapshots, supplier-private draft payloads, confirmation groups referencing a specific revision, allocations with requested-unit quantities, structured negotiations, scoped events and private attachments. Existing rfq_awards continues to record committed order allocations. Serialize mutations on the RFQ header; deduplicate operations by request UUID and payload hash; bound JSON arrays. RLS grants only approved business participants access, with supplier-private rows and an explicit audited administrative investigation RPC.

## E. Lifecycle
Draft → open → evaluation → partially awarded → procurement in progress → completed. Pending supplier awards hold requested quantities, not inventory. Supplier decline releases allocation; supplier acceptance atomically creates an existing marketplace order and links the committed award. Conversion failure leaves a retryable award and records its error. Completion requires no pending awards or unresolved requested quantities and resolved linked orders. Cancellation of RFQ cannot cancel existing orders implicitly.

## F. Sequence
1. Add schema, authorization and server drafts/publication/invitations.
2. Immutable revisions, comparison and confirmation allocations.
3. Checkout adapter using locked server-held commercial terms, order/credit regression tests.
4. Negotiation, import identity review, repeat/history, documents and notifications.
5. Bounded reporting, scorecards and truthful price comparisons; responsive and integration verification.

## G. Risks and controls
Old award RPCs must not bypass supplier confirmation on new RFQs. Supplier quote drafts must never be visible to buyers. Lost suppliers must never learn competitor IDs through header award references. Every transition rechecks approval/membership. Authoritative decimal totals come from Postgres. Quote expiry and stock are revalidated at confirmation. Checkout customization must be narrowly guarded against unexpected deployed definitions and must never trust caller-supplied prices. Tests must exercise concurrent allocation, retries, cross-tenant reads and cancellation reversal. Existing production migrations are already applied and must not be rewritten.

## H. Defaults
Private, sealed invitations and supplier confirmation are the defaults in the brief. No binding quotation mode without agreed marketplace terms. No automatic therapeutic equivalence or substitution. Existing billing does not have a separate tax engine: prices remain tax-inclusive as applicable, with disclosed treatment; do not invent statutory rates. No fabricated savings or regulatory claims. No production changes in this authorization.

## I. Files and validation
Add migrations after 20261114100000; extend src/components/rfq, src/lib/rfq and the two RFQ routes. Add tests/local-supabase/enterprise-rfq.sql plus unit and browser checks. Validate new migrations against an isolated local database, existing RFQ/order/credit regressions, type checking, lint and production build. Staging and deployment verification remain separate from local completion.
