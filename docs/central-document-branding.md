# Central document branding — implementation review

Branch: `feat/central-document-branding`. Reviewed for repository push; not approved for production deployment.

## Implemented

- Shared `/settings` workspace route with registered business identity and manager-only branding editor. RFQ and External Purchases editors now link here.
- Upload, replacement, removal, saved/draft state, discard, defaults, navigation warning, business-switch warning, retry and sample document selector.
- Server image decoding using Sharp, actual-format and dimension checks, 2 MB limits, metadata stripping and static WebP output. Existing staff route family hosts the authenticated upload endpoint.
- Tenant authorization before upload. Direct authenticated writes to the logo bucket prohibited. Validated asset registry; removal preserves assets rather than deleting historical references.
- Presentation RPC preserves legacy payment/signatory values; a database trigger prevents changing them through the old RPC. No new payment-destination or signature editor.
- Branding modification audit events and upload result events. No raw image payloads in audit records.
- Identity snapshots for new order copies/invoices at order creation, delivery notes at dispatch, first RFQ submission, quotation revisions and awards. Receipt identity captured at first preparation. Legacy receipts already marked sent are not retrospectively snapshotted.
- Order previews use authorized identity readers, block printing while loading, and await image decoding. Legacy order/RFQ exports identify current-branding fallback.
- Shared identity in report PDFs, account statements, inventory, CRM, goods received exports and receipt email headers. Report PDFs have page numbers; browser print CSS uses A4 margin-box page counters.
- Contrast-safe text color resolution and broken-logo initial fallback.

## Validation

- Full suite: 786 tests across 83 files passed.
- Final review fixed editable checkboxes during save; all 11 targeted branding tests passed again.
- TypeScript passed after export-call fixes. Production build passed (existing large-chunk warning remains).
- Three additional editor tests passed for logo removal, discard, failed-save recovery and organization switching.
- Migration applied to an isolated local database; 19 rollback-only SQL assertions passed, covering authorization, markup, upload bypass, logo selection/removal/retention, historical identity and audit records.
- Image decoder tests cover PNG/JPEG/WebP, corrupted/unsupported input, size and dimensions.
- Chrome disconnected fixture inspected at desktop and 375 px mobile. Normal viewport restored. Sample-table spacing corrected after inspection.
- Interactive browser input checks repeatedly failed when Chrome detached, including a fresh tab; do not treat upload/save browser interactions as verified.

## Remaining acceptance gaps / limitations

This is not a complete immutable document archive. Snapshots preserve issuer branding, not a frozen copy of all transaction contents or recipients. Existing authoritative transaction rendering remains unchanged.

- Invoice identity is captured at order creation because the existing print workflow uses the order reference/date and has no distinct universal invoice issuance event. It is not a new invoice issuance workflow.
- RFQ identity is frozen at first submission. The current enterprise editor permits draft edits only; a future post-publication revision workflow would need versioned identity lookup. Recipient-specific historical snapshots and archived report/statement exports are not implemented.
- Receipt preparation can precede successful email delivery; back-order receipts use the collection ID as their snapshot key. Each cash collection now has its own identity snapshot.
- Existing uploaded logos are not retrospectively revalidated. They remain usable if unchanged; newly selected logos require validated asset records.
- PDF template-version dispatch, multiple styles, secondary colors, signature assets and financial-destination editing are not implemented. One classic presentation is supported.
- Sample previews demonstrate presentation; they are not all the actual transaction renderers. Full A4 multipage visual verification remains outstanding. Browser margin-box page numbering depends on browser support.
- Bulk pick-pack printing now resolves the supplier identity and waits for image decoding; it still needs an end-to-end print-dialog check. Do not claim universal print coverage.
- Successful upload audit failures now prevent a success response; rejected direct database RPC calls cannot persist audit events in their rolled-back transaction.
- No cleanup process for unselected uploads; retained assets intentionally favor document integrity. A retention policy is needed before cleanup.
- No production database/security inspection or mutation was performed during implementation. Separate staging API/upload tests remain necessary.

## Migration and release order

1. Review `20261119100000_central_document_branding.sql` against production schema and migration history. This is a one-time migration, not a rerunnable seed; it renames the previous RFQ document function.
2. Verify storage restrictive policies alongside existing policies in staging. Test owner, manager, inactive staff, non-manager and unrelated organizations via API and database.
3. Test Sharp packaging in the Vercel runtime and authenticated upload end-to-end; validate authorization revocation and audit failure handling.
4. Complete outstanding snapshot semantics and visual acceptance checks above.
5. Obtain explicit production approval. Apply migration, then deploy the matching API/client together. Old clients' direct logo uploads will stop working after migration.
6. Read-only production smoke checks: settings load, authorized document preview, legacy notices, issuer identity and download output. Do not send receipts or modify live branding as a test.

Rollback must not delete snapshots or assets. Rolling back only the client will restore the old upload path, which the new storage policies intentionally deny. Prefer a forward fix; plan coordinated API/client rollback if necessary.

## Unrelated files preserved

`docs/production-audit-2026-10-11.md`, `docs/pharmacy-orders-audit-2026-10-11.md`, and `docs/production-payment-catalog-check.sql` were already modified/untracked and are not part of this implementation.

## Files changed

- `api/_branding-image.test.ts`
- `api/_branding-image.ts`
- `api/_branding-upload.ts`
- `api/_cash-portions.ts`
- `api/_order-receipts.ts`
- `api/staff/[action].ts`
- `docs/central-document-branding.md`
- `package-lock.json`
- `package.json`
- `src/components/DashboardShell.tsx`
- `src/components/accounting/AccountingPage.tsx`
- `src/components/accounting/StatementPanel.tsx`
- `src/components/crm/PharmacyCrm.tsx`
- `src/components/documents/BusinessDocument.tsx`
- `src/components/documents/DocumentBrandingSettings.test.tsx`
- `src/components/documents/DocumentBrandingSettings.tsx`
- `src/components/order-print.tsx`
- `src/components/procurement/ExternalProcurement.tsx`
- `src/components/reports/ReportsHeader.tsx`
- `src/components/rfq/EnterpriseRfqWorkspace.tsx`
- `src/components/statements/StatementView.tsx`
- `src/lib/document-branding.test.ts`
- `src/lib/document-branding.ts`
- `src/lib/document-identity.ts`
- `src/lib/enterprise-rfq-documents.ts`
- `src/lib/reports.ts`
- `src/lib/statement.ts`
- `src/routeTree.gen.ts`
- `src/routes/pharmacy_.inventory.tsx`
- `src/routes/settings.tsx`
- `src/routes/wholesaler.tsx`
- `src/styles.css`
- `supabase/migrations/20261119100000_central_document_branding.sql`
- `tests/browser/branding-supabase.ts`
- `tests/browser/branding.config.ts`
- `tests/browser/branding.html`
- `tests/browser/branding.tsx`
- `tests/local-supabase/central-document-branding.sql`
