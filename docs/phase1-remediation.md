# DrugXone Phase 1 remediation

Production readiness: **NOT READY**. Phase 1 is a local remediation for review, not production certification. No historical migration was edited. No hosted database, environment, DNS, payment service, deployment or Git push was changed.

## Reconfirmation and plan

Before editing, inspected the latest Phase 0 migration, product edit/create forms, checkout API/client, import RPC, cancellation trigger and database harness. The unchanged 30-migration baseline passed 37 database subtests plus its parent (38 reported). This confirmed signup restrictions, pending verification, wholesaler type enforcement, staff identity isolation, canonical pricing, direct order-write revocation, lifecycle enforcement and verified at-most-once restoration.

The ordinary edit form submitted `stock: Number(form.stock || 0)`; direct product UPDATE grants allowed a stale absolute overwrite. Checkout's service-only three-argument RPC had no durable operation key. Imports already had preview confirmation, transactional locking and request replay protection. Products already had NOT NULL and `CHECK(stock >= 0)`. No duplicate stock constraint was added.

The plan was to preserve those existing protections, add a forward migration, restrict ordinary UPDATE to metadata, introduce explicit atomic adjustments, wrap checkout with durable request recovery, and attach transactional movement evidence to every stock change. The migration checks for invalid legacy stock and aborts without repairs. New-table constraints have no pre-existing rows to conflict with. Its product-table lock makes the opening balance and trigger cutover consistent with concurrent writes. Hosted conflicts were not inspected because production access was prohibited.

## Changes and affected paths

All SQL changes are in `supabase/migrations/20260914110000_phase1_inventory_integrity.sql` (one new migration, after the Phase 0 and private-print migrations).

| Change                      | Affected objects/files                                                                                                                                                       | Integrity benefit                                                                                                                                                               |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Separate metadata and stock | Products table/column UPDATE grants; `src/routes/wholesaler.tsx`                                                                                                             | Metadata edits cannot submit stock. Direct authenticated/service stock updates fail. Existing product RLS and Phase 0 restrictive policies remain.                              |
| Atomic explicit adjustments | `adjust_product_stock`; `stock_adjustment_requests`; `src/components/StockDialog.tsx`                                                                                        | Owner/active manager of an approved wholesaler only. Add/remove lock the row; reconcile compares the preview quantity after locking. Requests are durable and mismatch-checked. |
| Movement evidence           | `inventory_movements`, `inventory_opening_balances`, private `inventory_operation_context`; `phase1_inventory_movement` trigger                                              | Automatic transactional stock evidence, tenant-scoped reads, no normal writes or history deletion.                                                                              |
| Checkout replay             | Four-argument `create_marketplace_orders`; `checkout_requests`; `api/orders/create.ts`; `src/lib/order-actions.ts`; `src/lib/checkout-request.ts`; `src/routes/pharmacy.tsx` | Same key recovers the original supplier-order set/count. API derives human caller from validated Auth token. Database retains authoritative prices and locks.                   |
| Cancellation audit          | Replaced `restore_stock_for_cancelled_order`                                                                                                                                 | Keeps all Phase 0 evidence/relationship checks and one-time restoration, adding order-linked movement.                                                                          |
| Import audit                | Replaced `preview_wholesaler_import`                                                                                                                                         | Keeps existing preview/hash/replay behavior and records stock changes by import mode/run.                                                                                       |
| Product retention           | Wholesaler deactivation action; product DELETE revoked and evidence FKs restrict deletion                                                                                    | Historical product references remain reconstructable; deactivated products leave marketplace offers.                                                                            |
| Types and tests             | `src/integrations/supabase/types.ts`; API/unit and PostgreSQL test files                                                                                                     | Explicit typed RPC/history interfaces, no new `any` in stock/checkout logic.                                                                                                    |

`phase1_read_only_review.sql` provides investigation queries. Sections 1–4 work before Phase 1; sections 5–8 require the new ledger. Run them manually against a reviewed target, without automatically modifying results.

## Inventory movement design

`inventory_movements` records product, wholesaler, authenticated actor where available, order/import/request reference, movement type, signed bigint delta, before/after integers, reason/source and database `clock_timestamp()`. Its arithmetic check requires `after - before = delta`. A partial unique index permits only one checkout deduction and one cancellation restoration per order/product/type.

Types: `product_created`, `manual_add`, `manual_remove`, `manual_reconciliation`, `checkout_deduction`, `order_cancellation_restore`, `import_add`, `import_replace`, `admin_adjustment`.

`inventory_opening_balances` snapshots each existing product's actual migration-time stock without claiming how it arose. New products get a zero baseline, followed by a real creation/import movement if nonzero. Zero-change updates and details-only imports create no movement. Opening balance plus all deltas must equal current stock. Old order/import events are not backfilled.

All stock mutations run through an AFTER trigger. Failure to insert a movement aborts the stock-changing statement and enclosing transaction, including order creation, cancellation evidence, import run and audit activity. The private operation context is a table keyed by transaction ID, written/cleared by trusted operations. Clients cannot forge it with session settings or direct DML. Normal actors come from `auth.uid()`; checkout's actor comes from the token-validated service API caller. Seller identity comes from the actual product, never a supplied movement payload.

Privileged database maintenance without an operation context is recorded as `admin_adjustment` / `database_maintenance`. A missing human actor remains explicitly null and requires review; it is not fabricated. Database owners can ultimately bypass database protections, so operational access control is still required.

Authenticated tenant owners/active staff can read their wholesaler's history; no new platform-admin visibility is granted. Historical UPDATE/DELETE is revoked and guarded by immutable triggers. Products cannot be deleted out from under their history. The Stock dialog shows the latest 100 rows with timestamp, type, delta, before/after, references, actor UUID and reason. Older authorized history remains queryable; pagination is not implemented.

## Checkout idempotency design

The browser creates a UUID and persists it before sending, scoped to user/business and canonical cart payload. Unresolved cart payloads retain separate keys. Retrying the same cart after a lost response or reload reuses the key; a successful response clears it so an intentional new checkout can proceed. Storage failures fail before sending. Clearing browser storage, using a different device or deliberately generating a new key represents a different operation; idempotency cannot infer that two distinct keys are the same intent.

The API requires a UUID `requestId` and validates the caller token. The database globally reserves the key in `checkout_requests`, binds it to caller, pharmacy and normalized product/quantity payload, and locks it. Reuse by another account/business or a changed payload fails. Duplicate cart lines aggregate and line ordering is normalized. Fake prices/supplier fields remain ignored and cannot become authoritative.

Every supplier order belongs to one durable request. Its `order_ids` and count are saved in the same transaction as all orders, items, verified deductions and movements. Concurrent identical keys serialize and recover the same result. All products are locked in stable ID order before supplier order creation. Failure for any supplier or movement rolls back the whole logical checkout. Retrying after commit returns the original count without new orders/deductions/movements. Current business authorization is still required for recovery.

The keyless RPC is retired, not retained as a bypass. Review/deploy the API, client and migration together in a future authorized rollout. An old client fails closed until upgraded. No rollout was performed in this phase.

## Manual stock behavior

1. Editing a price cannot alter stock: it is absent from the edit form/payload and denied by column grants.
2. A stale whole-row form cannot restore deducted units: its stock UPDATE is rejected.
3. Blank adjustments are rejected, never converted to zero. Blank initial stock for a new product still deliberately initializes zero; blank imports preserve the existing specified semantics.
4. Add uses a locked database operation `stock + quantity`, with a positive whole quantity.
5. Remove uses `stock - quantity`; excess removal, negative input and overflow fail without a movement.
6. Reconciliation explicitly submits the physical count and expected stock. A changed balance rejects the action; refresh and recount/reconfirm. Before, after, difference, actor, time and optional reason are recorded. No arbitrary reason threshold was introduced.

Manual operations also have durable, actor/payload-bound keys. The browser retains failed operation keys in local storage and clears them only on success. Add/remove do not bind to a stale preview balance. Reconciliation binds to the exact preview intentionally.

## Import compatibility

For existing stock 100: Add 25 produces 125 (+25); Replace 25 produces 25 (-75); Details 25 preserves 100; blank Add/Replace/Details preserves 100. A new blank product starts at zero. Replay of the confirmed request returns its previous result before writing movements or audit activity; a new intentional request may add again. Replace above the old balance records a positive `import_replace`, not `manual_add`. Stock changes reference the committed import run through a deferred FK in the same transaction.

Existing identity/default-form behavior, broad import locking, file parsing and dependency risks remain unchanged. In particular a legacy product with null dosage form may not match an import defaulting to Tablet; this requires data review rather than silently merging identities.

## Existing data requiring review

- Negative/null stock or missing stock constraint in the actual hosted schema.
- Stock in inappropriate/unverified business workspaces and unusually large balances.
- Opening balance plus movements differing from current stock.
- Legacy or cancelled orders lacking verified deduction/movement evidence.
- Similar buyer/supplier carts placed close together; these are candidates, not proof of duplicate orders.
- Manual adjustments or latest product edits near checkout timestamps.
- Unattributed database maintenance movements.
- Earlier privileged-account, membership, approval, supplier-relationship and cancellation anomalies.

No production records were read, repaired, deleted or given fabricated historical movements. `products.updated_at` only identifies the latest edit, so older metadata edits cannot be reconstructed from it.

## Remaining risks

- Spreadsheet dependency/security (`xlsx`), ambiguous PDF/table parsing, file-size limits and product identity/default-form mismatches.
- Platform-owner/admin governance and existing suspect privileged accounts/memberships.
- Storage/document validation and incomplete verification evidence/expiry/suspension processes.
- Historical seed dependencies, destructive historical deduplication and prototype migration hazards.
- Payment confirmation/receipt delivery retries and outbox/reliable email delivery. No payment subsystem redesign was performed.
- Hosted effective schema/grants, Auth/provider templates, configuration, backups and restore procedures remain unverified.
- Legacy deduction gaps still block automatic cancellation; starting balances do not explain prior stock history.
- Import-wide locking may affect throughput. Request/history retention and monitoring require operational planning.
- Database maintenance human attribution may be absent; broader non-inventory audit gaps remain.

## Focused re-audit

| Area                         | Result |
| ---------------------------- | ------ |
| Manual stock integrity       | PASS   |
| Checkout idempotency         | PASS   |
| Inventory movement auditing  | PASS   |
| Checkout deduction integrity | PASS   |
| Cancellation restoration     | PASS   |
| Import stock integrity       | PASS   |
| Tenant isolation             | PASS   |
| Phase 0 regression           | PASS   |

PASS is limited to the implemented local paths and tested schema; unresolved production risks above remain. Phase 1 does not authorize deployment or certify historical data.

## Final verdict

1. Stale product edit can increase stock after checkout: **No**.
2. Normal product detail editing can alter stock: **No**.
3. Supported stock operations can produce negative stock: **No**.
4. Same-key checkout retry can duplicate orders: **No**.
5. Same-key checkout retry can deduct twice: **No**.
6. Normal wholesalers can alter historical movements: **No**.
7. Every new checkout deduction is auditable: **Yes**, transactionally.
8. Every new cancellation restoration is auditable: **Yes**, linked to verified deduction evidence.
9. Import stock changes are auditable: **Yes**, linked to run and actor.
10. One wholesaler can manipulate another's inventory: **No**, through the supported operations.
11. A Phase 0 protection regressed: **No** in the regression suite.
12. Ready for the next remediation phase: **Yes**, after manual review of this change; production remains **NOT READY**.

## Final validation results

| Check                                                               | Passed | Failed | Skipped |
| ------------------------------------------------------------------- | -----: | -----: | ------: |
| Application/unit/API (`npm test`, 9 files)                          |     56 |      0 |       0 |
| PostgreSQL/RLS (`npm run test:db`, includes parent)                 |     67 |      0 |       0 |
| Existing Phase 0/private-print regression subtests (included above) |     37 |      0 |       0 |
| Phase 1 subtests (included above)                                   |     29 |      0 |       0 |
| Concurrency subtests across both phases (included above)            |      5 |      0 |       0 |
| Stock browser checks (`node tests/browser/stock.mjs`)               |      4 |      0 |       0 |
| Print/browser regression (`npm run test:print-ui`)                  |      6 |      0 |       0 |

Totals: 123 test-runner results (including one parent), plus 10 browser checks; zero failed or skipped in the final runs. Concurrency covers competing buyers, simultaneous cancellation, identical-key double click, Phase 1 competing buyers with ledger assertions, and atomic manual additions.

Lint, TypeScript (including APIs), production build (2,409 modules) and Git whitespace checks passed. All 31 exact migrations ran only against isolated local PostgreSQL 17 with synthetic Auth/Storage and real database roles/RLS. The database cluster was stopped after testing. Browser checks use synthetic intercepted data and block external requests; they do not certify hosted Auth/PostgREST configuration.

During development, four import cases initially failed because null-form fixture products did not match the importer's existing Tablet default. Fixtures now explicitly match and assert the target product ID. A browser mock assertion initially confused an undefined optional field with an absent property; the assertion now checks the value sent to serialization. Final runs pass. No security assertion was removed or weakened.

## Git status for manual review

Modified: `api/orders/create.ts`, `src/integrations/supabase/types.ts`, `src/lib/order-actions.ts`, `src/routes/pharmacy.tsx`, `src/routes/wholesaler.tsx`, `tests/database/phase0.mjs`.

New: `api/orders/create.test.ts`, `docs/phase1-remediation.md`, `src/components/StockDialog.tsx`, `src/lib/checkout-request.test.ts`, `src/lib/checkout-request.ts`, `supabase/migrations/20260914110000_phase1_inventory_integrity.sql`, `supabase/phase1_read_only_review.sql`, `tests/browser/stock.mjs`, `tests/database/phase1.mjs`.

All changes remain local and uncommitted. No push or deployment was performed.
