# Procurement workspace investigation

## Existing architecture

The master_products catalogue is shared and active records are readable by authenticated users. wholesaler_products attaches commercial offers to that identity; products and batch ledgers remain inventory sources. Neither is suitable for automatically publishing pharmacy-created private medicines. pharmacy_inventory_items represents physical stock and must not be used for catalogue-only creation. RFQs already accept named snapshot lines and optional master IDs. External receipts use master IDs or local product snapshots, with separate reviewer-controlled inventory posting.

Suppliers already persist in pharmacy_crm_companies and pharmacy_crm_representatives. Existing external procurement RPCs authorize pharmacy processing, review and accounting independently. Supply documents persist JSON snapshots, request hashes, optimistic versions, immutable issued data, issuer branding, EPO references and events. Draft validation currently incorrectly requires completed supplier and medicine details; the editor repeats large cards and lacks catalogue or supplier selection. Quantities historically mean packs.

## Implementation boundaries

Reuse master identities, CRM supplier companies, supply-order tables, branding and audit events. Add a business-private catalogue (optional master association, structured attributes, aliases, archived/versioned records) because no non-stock private product catalogue exists. Add bounded authenticated search and permission-checked writes. Never write global identities or stock when creating catalogue items.

Preserve historical JSON snapshots and treat missing unit as packs. New documents record their unit; the pharmacy receiver must explicitly retain the ordered unit, with no implicit conversions. Expand document preparation authorization to approved wholesalers as confirmed by the user, without widening pharmacy receiving permissions. Reuse CRM companies through narrow business-scoped procurement RPCs; other CRM policies remain unchanged.

The follow-up authorizes a feature-branch push. Production migrations and deployment are still pending. Unrelated audit documents and the platform billing migration are preserved.


## Implemented scope by phase

| Phase | Local implementation |
| --- | --- |
| 0 | Existing master catalogue, stock ledgers, CRM companies, document snapshots, permissions and receiving contracts reviewed. |
| 1, 4 | Spacious responsive editor, compact desktop rows, mobile stacked inputs, sticky save/preview, explicit units and minor-unit totals. |
| 2, 3 | Debounced paginated private/master search, keyboard selection, match highlighting, indexed identity search, inline creation, exact identity deduplication, edit/archive/restore. |
| 5 | Existing CRM company table reused for private supplier selection and creation, contact snapshots retained. |
| 6 | Incomplete drafts, saved-state display, continue/edit/remove, in-app preview and confirmations; issuance validates completeness and preserves immutable snapshots. |
| 7 | Recent/frequent catalogue selections, fresh revised drafts with cleared prices, reusable private lists with replace/archive actions. |
| 8 | CSV/XLSX review, exact matching, duplicate/invalid-row feedback, row removal, explicit private creation option. Partial catalogue saves retain IDs for retries. |
| 9, 10 | Database tenant checks/RLS, optimistic versions, advisory locks, audit logs; no stock creation from catalogue/draft/issue. Existing receipt transaction retained. |
| 11 | Paginated date/supplier/medicine/reference report using document snapshots and actual linked receipts. |
| 12 | Automated regression, local database integration, desktop/mobile disconnected browser checks. Limits below. |
| 13, 14 | Local branch only, additive migrations, rollout and rollback guidance, verification evidence. |

Wholesalers receive catalogue and document preparation only, as requested. The existing multi-wholesaler RFQ editor can reuse catalogue descriptions; its existing singular units remain authoritative and other presentations are explicitly described as one unit. Private catalogue creation does not publish a global medicine or create a marketplace offer.

## Migration order and rollback

These files have been applied only to isolated local databases:

1. Existing migrations through `20261120100000_external_supply_orders.sql` (including central branding and external procurement dependencies).
2. `20261121100000_procurement_workspace_catalogue.sql`: private catalogue, identity search indexes, supplier RPCs, document preparation authorization, incomplete drafts and unit-aware receiving guard.
3. `20261122100000_procurement_templates_reports.sql`: private reusable lists and document-line report.
4. `20261123100000_external_receipt_unit_conversion.sql`: explicit inventory-packs-per-ordered-unit conversion, immutable after the first linked receipt, with ordered quantities retained for partial-delivery checks.
5. Matching client, only after all three migrations succeed.

Do not rerun the old external-supply-orders migration: it contains non-idempotent table creation and function renaming. The three new migrations are likewise versioned migrations, not repeatable scripts. A clean local copy was used to verify application order.

No destructive rollback script is supplied. Roll back the frontend first and retain new tables and audit history. Before restoring older document RPC bodies, assess new wholesaler documents, incomplete drafts and non-pack units; blindly restoring old pack-only receiving could misinterpret quantities. Prefer a corrective forward migration. Search index creation can lock tables while building: measure production table sizes and schedule an appropriate window before deployment.

## Verification evidence (2026-10-12)

- `npx vitest run --pool=threads --maxWorkers=2`: **88 files, 808 tests passed**.
- `npx tsc --noEmit`: passed.
- `npx vite build`: passed, 3446 modules. Existing mixed static/dynamic import warnings remain for document modules.
- `git diff --check`: passed (Windows line-ending notices only).
- Local Postgres container: `supabase_db_drugxone-local-validation`; clean database `procurement_workspace_review_20261012`, copied from existing integration fixture `external_orders_final_20261011`.
- Applied migration 21 then 22 then 23 with `psql -U supabase_admin -d procurement_workspace_review_20261012 -v ON_ERROR_STOP=1` through `docker exec -i`.
- `Get-Content tests/local-supabase/procurement-workspace.sql -Raw | docker exec -i supabase_db_drugxone-local-validation psql -U supabase_admin -d procurement_workspace_review_20261012 -v ON_ERROR_STOP=1`: **25 checks passed**, transaction rolled back. Covers private creation/retry, aliases/generics/strength, draft issue validation, immutable snapshots, stale writes, direct-write denial, supplier/template retry, report data, invalid source, tenant isolation and wholesaler scope.
- Same command with `tests/local-supabase/external-supply-orders.sql`: **27 checks passed**, transaction rolled back. Existing idempotent receipts, partial delivery, over-receipt rejection, cancellation, history and stock separation remain compatible.
- Disconnected Chrome fixture `tests/browser/supply.html`: desktop editor inspected; 390x844 mobile editor inspected, edited quantity/name and displayed draft preview. Mobile dialog clientWidth and scrollWidth both 357px. Supplier search adjusted to a full row on mobile.
- Chrome disconnected during the subsequent tablet viewport check. Tablet visual QA and confirmation of temporary viewport reset remain unverified; no production page was changed.

## Explicit limitations and release gates

- **Feature-branch push authorized; not deployed or production verified.** Production migration/application and authenticated end-to-end release smoke tests remain pending.
- Database persistence and tenant isolation were verified through authenticated-role SQL fixtures. Logout/login and a second physical device were not exercised.
- Documents support packs, boxes, bottles, tubes, vials, ampoules and pieces. Non-pack receiving now requires an explicit positive whole number of inventory packs per ordered unit. The first linked receipt freezes that conversion. Users enter actual inventory packs, batch quantities and cost per inventory pack. Allocations retain ordered units and inventory packs separately; no stock is inferred. Fractional ordered-unit deliveries and fractional packs-per-unit are rejected; use the smallest practical inventory pack definition.
- Recent/frequent views count saved document selections, not stock movements. Shared master products lack dedicated alias/ingredient fields; private entries support both, while master search uses existing available identity fields.
- Imports preserve valid rows in review and can save private identities explicitly; invalid rows can be removed or corrected in the source spreadsheet and reimported. No automatic fuzzy identity merging occurs.
- Supplier editing/archive remains in the existing pharmacy CRM. Wholesalers can create/reuse suppliers for document preparation; this does not grant pharmacy CRM/receiving access.
- No claim of WCAG certification, production-scale latency benchmarking, real multi-session concurrency stress, or full tablet QA. Keyboard/error/retry behavior has automated coverage and SQL locking/uniqueness remains authoritative.
- Save before closing/reloading a browser tab. Unsaved local fields are not autosaved; route/workspace changes use in-app protections. Saved drafts are database-backed.

Unrelated audit documentation and the platform billing migration remain untouched by this task. Earlier in-app-confirmation work is retained in the working tree and documented separately in `in-app-workflow-actions.md`.


## Follow-up receiving correction

Conversion regression coverage includes missing conversion rejection, two boxes versus ten inventory packs, retry idempotency, fixed conversion across receipts, over-delivery and fractional-order-unit rejection, exact partial fulfilment and unchanged stock. The UI exposes conversion alongside actual received packs and per-pack acquisition cost. Chrome inventory was empty on the follow-up, so tablet visual verification remains a release check rather than a claimed pass.
