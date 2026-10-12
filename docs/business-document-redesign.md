# Business document redesign investigation

## Existing architecture
Order invoices/copies/delivery/pick lists use order-print.tsx inside a portalled Radix dialog. Bulk pick lists reuse the same component. BusinessDocument supplies a separate print-only shell. RFQ/quotation/award exports and external purchase orders use jsPDF plus AutoTable. Reports/statements use a landscape jsPDF exporter. Payment receipts are authenticated, payment-gated HTML emails in api/_order-receipts.ts; credit notes appear in accounting statements, without a standalone issued document renderer.

Branding uses business_document_branding and document_identity_snapshots. get_order_document_identity and rfq_document preserve issuer snapshots or explicitly return legacy identity. Logo storage uses business-document-logos. Rendering must not mutate transactions or generate identifiers.

## Defects established by code inspection
Order invoices repeated issuer contact blocks, identifiers and dates. Current catalogue values and live product relation fields were displayed alongside recorded item fields. The invoice table used a separate Details column and repeated currency prefixes, consuming scarce portrait width. Invoice preview had no physical page dimensions. Order PDF download was absent. Existing global print CSS already removes modal transforms/overflow and declares A4; missing @page is therefore not an established root cause. Browser reproduction remains required before assigning a definitive clipping cause.

## Implementation sequence and shared architecture
Reuse jsPDF/AutoTable, identity RPCs and existing totals helpers. Introduce a transaction-independent BusinessDocumentModel, shared HTML commercial layout and vector A4 PDF renderer. Adapt orders, RFQ exports and external procurement; retain operational pick-list semantics and payment receipt gating. Validate 1/5/20/50/100 lines, snapshots, rounding, long rows and A4 MediaBox. Browser print QA must be reported separately from unit tests.

## Integrity risks
Legacy orders do not necessarily contain historical strength/form/pack data or allocated payment amounts. Do not replace those with live catalogue values or derive payments from COD. Never invent invoice numbers, tax, payment confirmation, receipt identities or historical logos. Existing commercial records and migrations remain unchanged. Unrelated work is preserved. No push or deployment is included in this task.

## Implemented locally
- BusinessDocumentModel and shared vector A4 renderer; commercial HTML invoice/order-copy/delivery layout.
- Invoice header, recipient and metadata separated; repeated issuer blocks removed. Historical line details only. Missing prices are labelled rather than assumed zero.
- Download PDF and actual paginated PDF preview with page count and revoked blob URLs. No public document URLs.
- External request/PO and RFQ/quotation/award PDFs adapted to the shared renderer; authorized server fetches retained.
- Statement of account PDF download; standalone statement print CSS now explicitly requests A4, repeats headings and keeps summary blocks together.
- Text-only branding fallback; reusable aspect-preserving logo loader; no schema or commercial-record changes.

## Validation evidence
- Focused PDF tests: 8 passed, parsing actual PDF output using PDF.js. Tested 1, 5, 20, 50 and 100 lines, actual 595.28 x 841.89 pt MediaBox, unique item retention, page numbering and totals.
- Generated page counts respectively 1, 1, 2, 3 and 6. PyMuPDF extraction found zero out-of-bounds words. First/last pages rendered; five-item first page and hundred-item last page visually inspected.
- Initial production build passed. Final build and related tests tracked in the completion response.
- Full suite initial attempt: 85 files / 798 tests passed, four test files had worker-start timeouts. These are infrastructure errors, not a clean regression pass; retry required.

## Remaining acceptance work
Chrome automation repeatedly fails to load its request-header policy. Consequently the original browser print defect has NOT been reproduced, and Chrome/Edge print preview remains unverified. This is not a certified permanent A4 fix yet.
Payment receipt emails keep their existing authorized/paid-only sending flow; no new standalone receipt or credit-note issuance flow has been invented. Broad landscape analytical report exports retain their existing layout. Full receipt/report unification remains outstanding.
The compact HTML preview and PDF share data but have distinct layout implementations. The actual PDF preview is the authoritative paginated preview. Browser/printer margins and header/footer overrides must still be tested.
Legacy product/branding history and allocated payment amounts cannot be manufactured. Amount paid/balance display supports supplied authoritative values, but no new payment data RPC has been added.
Not pushed or deployed. No database migration required for these local changes. Production authenticated transaction testing from the earlier task remains unverified.

## Confirmed CSS defect
The compiled Tailwind v4 `.translate-x-[-50%]` rule uses the individual `translate` property. DialogContent applies this and the corresponding Y utility. Existing print rules cleared `transform` but left `translate` active on the modal ancestor, shifting the printable document by half its box. Print ancestors now reset translate, rotate, scale, animations, transitions and inset explicitly. This is confirmed from source and compiled CSS; physical/browser print reproduction remains pending connection recovery.

Final checks so far: TypeScript passed; focused related document tests 7 files/28 tests passed; worker retry 4 files/18 tests passed, completing the 816 tests across the original suite and retry. Production build passed with chunk-size/dynamic-import warnings. Subsequent print-only CSS reset requires browser verification.

## Release recheck
User authorized push. Fresh checks: npx tsc --noEmit passed; npm run build passed; npx vitest run --pool=threads --maxWorkers=2 passed all 89 files / 816 tests in one run. Browser print verification and remaining receipt/report scope above remain open. No migration required.
