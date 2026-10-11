# External requests and purchase orders

External procurement now begins before delivery. The pharmacy can prepare a request for availability/quotation or a purchase order, download an issued PDF and share it manually. No email, WhatsApp message, supplier account, marketplace order or payment is created.

## User workflow

1. External purchases → Requests & orders → New request / order.
2. Enter the intended supplier/contact, delivery details, exact medicine/strength/pack names and pack quantities. Request prices may remain blank. A purchase order requires agreed prices before issue.
3. Save a draft, review it and issue it. Issuance freezes document content and issuer branding. Issued documents cannot be edited; cancel and create a replacement if necessary.
4. Download PDF to share. Download does not mark it shared. After sharing outside the app, use Mark as shared manually. Purchase orders also allow Record supplier confirmation.
5. An issued request can create a new purchase-order draft with a reference to its originating request.
6. Record delivery against order prepopulates only outstanding quantities. For partial delivery, reduce quantities and matching batches, and remove undelivered lines. Record the actual seller, original source, batches, invoice and costs through the existing receipt form.
7. Existing evidence/reviewer approval is still required before saleable inventory is posted. Payment recording remains separate.

## Integrity and semantics

- Pharmacy permissions and RLS protect plans and their event history. Mutations require existing purchase-processing permission.
- Issuance, sharing, confirmation, cancellation and draft edits have an actor/timestamp audit trail. Version checks reject stale changes.
- Request keys make creates/retries idempotent. A pharmacy transaction lock serializes receipt allocation, cancellation and edits. Concurrent receipts cannot exceed ordered quantities.
- Linked receipts cannot be detached or moved to another order. The old receipt implementation is private and callable only through the checked wrapper by normal clients.
- Received means physical delivery recorded, including unreviewed/rejected goods. Returns do not reopen order quantities. A replacement delivery needs a new order.
- Cancellation stops new deliveries; existing receipts remain available. Corrections on a cancelled order cannot increase allocated quantities.
- A linked receipt preserves the exact ordered medicine name. Inventory mapping remains available; replacing its catalogue identity and adding unrelated lines are blocked. Record additional/substituted goods separately.
- Supplier details are entered as document text; they do not establish a verified original source. Receipt source starts unknown until explicitly recorded.
- List cards show document issuance status; receipt progress is displayed in the detail view. Documents are paginated in groups of 20.
- Financial amounts are GHS goods prices. Freight/tax terms can be described in instructions; this does not introduce a tax-calculation or supplier settlement engine.

## Verification

- 793 tests across 85 files passed, including new component, allocation/validation and multipage PDF tests.
- TypeScript and production build passed. Existing chunk-size/mixed-import build warnings remain.
- The migration applied to fresh isolated local databases. Nineteen rollback-only workflow/authorization assertions passed.
- Existing external-procurement SQL regression checks passed, covering stock approval, payments, returns, consumption, RLS and marketplace isolation.
- Two concurrent integration scenarios passed: excess competing receipts reject one writer; duplicate receipt requests create one receipt.
- The actual PDF renderer generated a 90-line, five-page sample. All five pages were visually inspected for wrapping, repeated headings, totals and page numbers.
- Chrome's disconnected fixture displayed the order detail and confirmed 20 ordered minus 12 received prepares 8 packs. Browser control subsequently stalled while dismissing the fixture alert. Full browser workflow, mobile interaction and production integration are not claimed verified.

## Release

This branch is based on `feat/central-document-branding` and depends on its reviewed `20261119100000_central_document_branding.sql` migration and client/API changes. Neither feature is implicitly approved for production deployment.

Apply `20261120100000_external_supply_orders.sql` in staging after its predecessors, then deploy the matching client. It is a one-time migration: it renames the old receipt function and installs an authorized wrapper. Do not rerun it or apply it out of order. No existing purchase business records are rewritten.

Before production release, verify authenticated staging creation → issue → PDF download → manual-sharing status → partial receipts → normal stock review, including inactive and unrelated users. Complete desktop/mobile interaction checks. Production deployment requires separate approval.

Local checks:

```powershell
npx vitest run
npx tsc --noEmit
npm run build
# Only on an isolated fixture database:
$env:EXTERNAL_ORDER_TEST_DB='external_orders_validation_20261011'
node tests/local-supabase/external-supply-orders-concurrency.mjs
# Disconnected browser fixture:
npx vite --config tests/browser/supply.config.ts --host 127.0.0.1 --port 5178
```

The browser fixture is at `/tests/browser/supply.html`. It uses in-memory sample data, not production credentials.
