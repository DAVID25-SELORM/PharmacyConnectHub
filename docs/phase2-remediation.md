# DrugXone Phase 2 remediation report

## Production Readiness

**NOT READY** for production. Local remediation is implemented; hosted configuration, real Storage/provider behavior, existing data and restore readiness remain unverified. No deployment, hosted migration, commit, push, environment change or DNS change was performed. Suitable for an authorized isolated staging rehearsal after reviewing the checklist.

## Phase 2 Changes Implemented

The Phase 0/1 regression suite was run before Phase 2 (67 reported tests passed). Their historical migrations remain unchanged. All corrections are in the new forward migration `20260914120000_phase2_production_readiness.sql`; Phase 1 changes already present remain in the working tree.

- **Imports and identity:** `src/lib/product-import.ts`, its dedicated worker, import tests, `src/routes/wholesaler.tsx`, package manifests and Vite worker configuration. Maintained parser distribution, bounded worker parsing, explicit columns, conservative identity and supplier checks prevent silent commercial-value shifts. `product_import_identity`, `phase2_identity_guard`, `phase2_offer_supplier_guard`, `list_marketplace_catalogue` and `preview_wholesaler_import` enforce the new write/read policy in PostgreSQL. Existing inconsistent master mappings fail closed in marketplace output until reviewed.
- **Platform governance:** `has_role`, `phase2_platform_guard`, `manage_platform_member`, `accept_platform_invitation`; platform invite/update/resend APIs and `admin.staff.tsx`. Effective admin authority comes from active platform_staff, not legacy roles or signup metadata. Owner-only management, immutable owner role, explicit pending acceptance and revoked direct writes prevent promotion/upsert attacks.
- **Audit:** internal `write_audit_log`, immutable audit trigger, `phase2_inventory_audit`, private `server_audit_context`, and `change_business_staff`. Human identity comes from validated authentication or private database context. Tenant invite/update APIs now use the controlled staff RPC. Clients and service APIs cannot invoke the general writer with fabricated actor values. Checkout has an attributed inventory-movement audit linked to order IDs; historical unattributed events are not rewritten.
- **Verification:** private Storage policies, limits, `phase2_document_guard`, `phase2_document_audit`, `license_document_versions`, `review_business_evidence`, `phase2_review_guard`; upload validation/onboarding and admin review UI. Metadata must point to a real object in the business folder. Replacement gets a new version and reopens verification. Review binds exact displayed version IDs.
- **Payments and receipts:** atomic `confirm_order_payment`, private `receipt_outbox`, service-only `claim_order_receipt`/`finish_order_receipt`, shared `api/_receipt-delivery.ts`, two receipt/payment endpoints, provider idempotency header. Payment and job creation commit together; email failure cannot undo payment.
- **Recovery/configuration:** recovery URL utility and tests, trusted server URL helper, Vercel headers, environment ignores, deprecated prototype warning, offline fresh-baseline generator and manifest, read-only review SQL, deployment checklist and bounded secret scan.

## Import Security

SheetJS **0.20.3**, official distribution URL in the lockfile, replaces the vulnerable registry release. PDF.js is **6.3.289**. Current npm audit reports zero vulnerabilities; this is a point-in-time advisory result, not proof of absence of defects. Transitive security updates and scoped overrides are retained and must be reviewed during future upgrades.

Imports accept CSV/TSV/TXT, XLS/XLSX and structurally explicit PDF tables. Maximum file/paste size is **5 MiB**, maximum **5,000 product rows**, **32 columns**, and **20 PDF pages**. A dedicated worker has a **10-second timeout** and is terminated on completion/error. Extensions, supplied MIME, file signatures and actual parsing are combined. Blank/generic MIME is tolerated only with other checks. Formula-bearing worksheets are rejected with a values-only export instruction; macros/formulas are never executed. Only the first sheet is imported. Multiline quoted records are unsupported and rejected rather than guessed.

Empty middle cells preserve their positions. Geometry/whitespace is not used to guess PDF columns; explicit pipe/tab structure is required. Ambiguous extraction must be corrected or exported to CSV. Invalid rows and database preview issues block confirmation. Preview distinguishes new/existing, before/after prices and stock; the server remains authoritative.

Retries retain the existing request ID and replay result. A deliberate new Add import uses a new ID and can add another delivery. The dialog explicitly explains this distinction. Similar-content detection across sessions is not implemented; it is advisory rather than required for replay correctness.

Residual boundary: compressed file expansion can consume memory inside the worker before the timeout or row check. A browser worker is isolation from the main UI thread, not a hard memory quota or antivirus sandbox. OCR and ambiguous geometric PDFs are not supported.

References: [official SheetJS distribution](https://docs.sheetjs.com/docs/getting-started/installation/frameworks/), [PDF.js security advisory](https://github.com/advisories/GHSA-hq66-cqwq-w95j).

## Product Identity

Active identity is the tuple of name, brand, dosage form and pack size, scoped to wholesaler for inventory. Each component is lowercased, trimmed and has repeated whitespace collapsed. Punctuation and meaningful pharmaceutical text remain intact. Strength embedded in the legacy name stays distinct; generic/strength fields absent from legacy inventory are not inferred. No fuzzy matching or unverified Tab/Tablet aliases are introduced. Missing form remains unknown rather than being silently assigned Tablet.

Manual inserts/identity changes and imports use the same database identity. Existing ambiguous duplicate records are retained; new ambiguous writes are rejected. Product reassignment remains prohibited by Phase 0. Offer seller must equal underlying product seller. Catalogue additionally verifies master identity and supplier mapping before exposing an offer. Checkout/printing continue to use underlying product seller and historical order prices. Legacy inaccurate master mappings may disappear from marketplace results until explicitly reconciled; this is a visible upgrade condition, not an automatic merge.

## Platform Governance

Owner: invite new admins, deactivate accepted admins, reactivate previously accepted admins. Admin: operational business review and existing admin functionality; cannot manage platform privilege hierarchy. Ordinary users: no platform privilege.

Owner role/identity cannot be altered or deleted through application operations; owner deactivation is blocked. An existing account is not overwritten or automatically attached by the invite API. New account invitations create pending membership; the verified invitee accepts it. Cancelling an unaccepted invitation cannot be used to reactivate it without acceptance. Pending-only resend uses a configured trusted recovery URL. Profile/email/password changes are not tenant/platform membership administration.

Existing legacy admin-only roles and hybrid platform/tenant accounts require manual review before rollout. No arbitrary first user is promoted. First-owner bootstrap and owner transfer are deliberately separate controlled administrative processes, not public application features. Cancelled unaccepted invitations and previously active legacy records lacking acceptance evidence may need administrative resolution; they are not silently trusted.

## Document Security

The licenses bucket remains private with a **10 MiB** maximum and PDF/JPEG/PNG MIME allowlist. Owner upload paths are user UUID/business UUID/unique filename. Cross-business read/write, overwrite and client deletion are denied. Admin read access remains authorized through RLS and short-lived signed URLs; no public document URL is introduced.

Client validation checks extension, MIME, magic signature and size. Bucket enforcement must be verified through the real hosted Storage API; local PostgreSQL tests emulate Storage tables/policies. Signature detection is not malware scanning.

Successful upload paths are remembered by business/file digest to retry metadata submission instead of generating another object. Metadata insertion requires a matching existing object. Old objects and version references remain retained. The immutable version archive records uploaded evidence; immutable audit review events retain the reviewer, status, timestamp and version/path reference, while the current document carries its latest review. Old files are initialized unreviewed; no historical approval is fabricated.

Concurrent review checks exact version IDs. Replacement triggers pending verification. Missing objects prevent review. Orphan/missing-object queries support an explicit retention/reconciliation process; cleanup is not automatic and unknown existing files are never deleted.

## Payment / Receipt Reliability

Manual COD payment allows **delivered + unpaid -> delivered + paid**. Repeated delivered/paid confirmation is idempotent. Other order states or payment states/methods are rejected. No refund or gateway workflow is invented. Order lifecycle remains pending -> accepted -> packed -> dispatched -> delivered, with controlled cancellation only from permitted nonterminal states. Delivered/cancelled remain terminal.

Order locking makes confirmation and outbox insertion atomic; one order owns one outbox job. Receipt states are pending, sending, sent, failed and uncertain. A two-minute claim lease prevents concurrent dispatch. The first payload is frozen, and the provider key is stable per order. Recorded sent state suppresses further sends. Provider failure leaves payment paid and records a retryable result. Provider success followed by tracking failure is retried with the same key after lease expiry.

[Resend retains idempotency keys for 24 hours](https://resend.com/docs/dashboard/emails/idempotency-keys). After 23 hours from first attempt, the application requires provider investigation instead of automatically resending an unknown outcome. Absolute exactly-once external email delivery cannot be guaranteed across provider outages/key expiry. Sender/template/environment changes between attempts can cause provider idempotency-payload conflicts; reconcile rather than issuing a new key. Retry is user/API initiated; no background scheduler was added.

## Migration Safety

Use the separate fresh baseline only for new environments. It omits demo catalogue seeds, hardcoded membership deletion, destructive duplicate cleanup and arbitrary owner backfill. The generated manifest records every source hash and exclusions. The empty-database test applies it without an approved wholesaler or demo fixtures and confirms no owner/stock seed is created.

Existing installations must compare applied history, review Phase 0/1/2 queries and apply only missing corrective migrations. Do not replay old seeds, run the fresh baseline on existing data, or run deprecated `supabase/schema.sql`. Migration history reconciliation after a fresh baseline is an explicit administrator step; the generator neither connects nor marks versions. See [deployment checklist](phase2-deployment-checklist.md).

## Production Configuration Checklist

The checklist covers applied migrations, effective RLS/grants, service-role isolation, email confirmation, recovery/redirect URLs, Storage privacy/limits, SMTP/rate limits, backups/PITR/restore, Vercel branch/environment, domains/HTTPS and response headers. All hosted items are **unverified**. Local Vercel configuration includes CSP, HSTS, no-referrer, nosniff, frame protection, Permissions-Policy and API no-store. Custom Supabase origins require explicit compatibility review.

## Tests

Final verification (14 September 2026):

- Application/API: **77 passed, 0 failed, 0 skipped**, 12 files. Includes 13 import/file-security cases, platform API authorization, receipt API recovery and recovery URL cleanup.
- PostgreSQL: **80 passed, 0 failed, 0 skipped**, including RLS, Phase 0/1 regression, Phase 2 governance/storage/payment/receipt cases, read-only inspection query execution and empty baseline. Concurrency includes competing buyers, stock adjustments/imports and duplicate payment confirmation.
- Browser: **6 printing/contact scenarios**, **4 stock scenarios**, **2 import/CSP checks**, **1 bundled production-worker scenario** passed. The production scenario parses CSV and explicit PDF under configured CSP and rejects ambiguous PDF; the dev-worker scenario covers CSV/XLSX and empty cells.
- Lint, TypeScript and production build: **PASS**. npm audit: **0 vulnerabilities**.
- Whitespace: **PASS** after normalizing mixed line endings in .gitignore.
- Secret scan: 180 tracked files, 28 untracked files at scan time, 416 reachable-history blobs <=2 MiB. All six grouped findings are documented SDK password examples or test fixtures; no confirmed private credential found. Pattern/size scope is limited; this is not a claim that all history is secret-free.

Intermediate failures were resolved: worker alias/output format and PDF protocol handling; formatting after dependency updates; stricter document fixtures; and missing Storage timestamp in the local test scaffold. Final runs above supersede those failed iterations. PostgreSQL counts include the parent test and nested cases; RLS, concurrency and Phase 0/1/2 assertions are included in that total and must not be added again as separate tests. Real hosted Storage/Auth/SMTP integration is not represented by local policy scaffolding and provider mocks.

## Existing Data Requiring Review

Run `supabase/phase2_read_only_review.sql` sections appropriate to the installed version. It lists platform authority/hybrid conflicts, missing objects, conservative duplicate identities, seller mismatches, invalid order references, payment/receipt anomalies, seed-time candidates, effective policies/EXECUTE grants, stale evidence approvals and orphaned objects. Phase 0/1 review queries remain required for stock/deduction/legacy order issues. Candidate rows are investigation leads, not proof of abuse. Deleted historical duplicates and old repeated-restoration events cannot always be reconstructed without backups/logs. No production-like record was automatically repaired.

## Remaining Risks

Hosted configuration/data and restore capability are unverified. Legacy catalogue identity conflicts need explicit reconciliation; existing approvals without reviewed evidence are reported but not fabricated or mass-revoked. Orphan cleanup, document retention and malware scanning need an operational policy. Browser resource limits are bounded but not hard memory isolation. Receipt delivery remains subject to provider semantics and manual uncertain-job review. Historical admin/membership records and earlier audit data require review. Original audit risks outside the authorized remediation cannot be declared closed from local tests alone.

## Focused Re-Audit

| Area                         | Result  | Evidence / remaining boundary                                                    |
| ---------------------------- | ------- | -------------------------------------------------------------------------------- |
| Spreadsheet security         | PASS    | Updated parser, bounded worker, XLS/XLSX/formula tests; resource boundary above  |
| PDF/table parsing            | PASS    | Explicit columns only; empty positions preserved; bundled browser PDF test       |
| Product identity             | WARNING | Safe active writes; existing legacy conflicts require review                     |
| Catalogue seller consistency | PASS    | Immutable product seller, offer guard, fail-closed catalogue filter              |
| Platform-admin governance    | WARNING | Owner-only tested operations; existing authority/bootstrap review required       |
| Audit attribution            | PASS    | Private writer/context; immutable history and known human attribution            |
| Verification storage         | WARNING | Local RLS tests pass; real Storage/content scanning unverified                   |
| Document lifecycle           | WARNING | Version-bound review; retention/orphan reconciliation remains operational        |
| Payment confirmation         | PASS    | Concurrent idempotent database transition                                        |
| Receipt reliability          | WARNING | Durable lease/key/state; provider integration and uncertain-job handling pending |
| Migration reproducibility    | PASS    | Empty baseline tested; rollout/history mapping still manual                      |
| Phase 0 regression           | PASS    | Existing authorization/order suite passes                                        |
| Phase 1 regression           | PASS    | Ledger/idempotency/concurrency suite passes                                      |
| Printing/contact regression  | PASS    | Browser/private-data regression passes                                           |

## Final Verdict

1. **Old spreadsheet parser path:** replaced; known old vulnerable release is no longer used. This is not a guarantee against all future parser defects.
2. **Empty columns shifting commercial values:** prevented by explicit positional parsing and required-value validation.
3. **Ambiguous products silently merged:** no fuzzy/strength inference in new paths; historical ambiguity still needs inspection.
4. **Catalogue vs checkout seller drift:** blocked/filtered by database seller and identity checks.
5. **Admin self-promotion to owner:** denied.
6. **Invitation demoting owner:** denied; existing accounts are not overwritten.
7. **Cross-business verification access:** denied by tested policies; confirm real hosted Storage deployment.
8. **Replacement requiring re-review:** yes, new version and pending verification.
9. **Duplicate authoritative payment transitions:** prevented by locking/idempotent transition.
10. **Knowingly resending recorded-success receipt:** suppressed; unknown external outcomes retain provider boundary.
11. **Historical migrations safe to replay fresh:** no. Use the tested fresh baseline instead.
12. **Safe existing upgrade documented:** yes; history comparison, read-only conflict review, backup/rehearsal and forward-only corrections.
13. **Phase 0 regression:** none observed in final local suite.
14. **Phase 1 regression:** none observed in final local suite.
15. **Printing/contact regression:** none observed in browser tests.
16. **Hosted checks remaining:** all items in the deployment checklist, especially effective grants/RLS, actual Storage limits, Auth URLs, SMTP/provider recovery, backup restore, migration history, environment and HTTPS/CSP.
17. **Ready for staging rehearsal:** yes, in an isolated authorized environment after manual preflight; not approved for production.

## Git Status

See `phase2-git-status.txt` for the exact modified/new file list, including preserved uncommitted Phase 1 work. No commit or push was performed.
