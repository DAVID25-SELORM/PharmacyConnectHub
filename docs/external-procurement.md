# External procurement and supplier traceability

The pharmacy workspace now has **External purchases**, separate from marketplace checkout.
Inventory, Reports and Accounting link to the same private workflow. Each existing pharmacy
business is its own workspace; there is no new shared branch hierarchy. The Workspaces report
compares authorized pharmacy businesses, with a pharmacy/branch selector and date filters.
Authorization is checked in the database for every workspace returned.

## Workflow

1. Reuse a private CRM person/company or record a new contact. Contacts never create auth users,
   business accounts, marketplace offers, wholesaler roles, RFQs or orders.
2. Record purchase date, invoice/receipt, seller/deliverer and original source separately.
   Original sources can reference an approved platform wholesaler without creating an order.
3. Search the shared master catalogue, or record a pharmacy-local product description. Explicitly
   map an existing pharmacy inventory item before posting, or create a local item at approval.
   No fuzzy stock matching or shared catalogue creation occurs. A product can have multiple lots.
4. Save the receipt, attach invoice evidence, record payments if authorized, and submit for review.
   All recorded lots start outside saleable stock. Unknown sources become unverified/quarantined.
5. An explicitly assigned active reviewer approves, requests information, quarantines or rejects.
   Approval requires a known original source, an invoice/product invoice/purchase receipt attachment,
   a batch number and future expiry for every lot. Review notes are mandatory.
6. Approval atomically posts each remaining lot to the existing pharmacy movement ledger. A unique
   receipt-movement index plus purchase locking prevents double posting. No marketplace stock changes.

Workflow verification is not a legal compliance determination. Reviewer assignment records the
owner's authorization; it does not independently establish professional credentials.

## Permissions and privacy

- Existing `process` permissions can record receipts and procurement contacts. Accounting roles
  can read procurement and maintain payments. Assigned active reviewers can read and review.
- Only the pharmacy owner assigns/revokes reviewers and configures optional identity references.
  No owner/manager is implicitly a reviewer. Inactive membership revokes reviewer access immediately.
- Identity references are disabled by default. No identity-document uploads are requested.
- Private CRM records are reused, with procurement-specific projections that exclude unrelated
  interactions and notes. Seller/source snapshots preserve the purchase history after contact edits.
- Every new table has tenant RLS and no authenticated mutation grants. RPCs check authorization.
  Composite foreign keys protect purchase/item/batch/contact/inventory ownership.
- No blanket platform-admin access is granted to procurement tables or documents. Existing
  pharmacy inventory administration permissions are unchanged for inventory records themselves.
- Evidence uses the private `external-procurement` bucket (PDF/JPEG/PNG/WebP, 10 MB maximum).
  Object policies validate the tenant and purchase; downloads use 60-second signed links.
  Evidence cannot be overwritten/deleted through storage policies. Removing a draft attachment
  marks its metadata and logs the action; the retained object preserves evidence history.
- Detailed purchase events stay tenant-private. The existing business audit writer receives only
  event metadata. Payments, returns and events are protected against update/delete by triggers.

## Inventory and corrections

`external_purchase_batches.remaining` records the receipt-lot balance, separate from disposition.
Only saleable lots contribute to pharmacy `stock`. Purchase approval, batch holds/releases, returns,
quantity corrections and write-offs update the lot, inventory, movement ledger and audit atomically.
Recall references/reasons can be recorded on a hold or write-off. Expired lots cannot be released.

Posted receipts cannot be edited. Negative corrections/returns refer to the specific lot; additional
received units require a new receipt referencing the original. Review history remains intact.
Legacy manual adjustments/imports can still change unbatched inventory, but cannot reduce total stock
below the sum of tracked saleable lot balances. Use Record stock consumption for traced units
dispensed/used, or the reviewer correction/return action for other reductions. Consumption has
its own counter and cannot use expired/quarantined stock. Select the actual lot; earliest expiry
is recommended but not automatically allocated. Approval recalculates the inventory moving
weighted-average unit cost from existing stock and each received lot (rounded to inventory
currency precision). If previous unit cost is unknown, the incoming cost is the fallback.
Inventory mapping searches and pages through all items rather than preloading a truncated list.
There is no automatic migration/backfill of historical stock or automatic marketplace receipt sync.

Expiry is displayed and warned on receipt details; automatic scheduled expiry holds and a global
recall registry are not introduced. Pharmacy inventory is still the existing standalone inventory,
not a retail checkout/dispensing system.

## Finance and reporting

External payables use their own append-only payment receipts and reversals because marketplace
credit foreign keys require platform wholesalers/orders. Accounting shows combined marketplace/external payable totals and aging, plus external supplier
balances. Supplier profiles export chronological statements with purchases, payments, reversals,
return credits and running balances. The existing marketplace invoice/payment registers retain
their own scope. Paying a supplier never changes source verification.

Balance = purchase cost - net payments - agreed return credits. Negative balances display the
supplier refund/credit owed. Reversal preserves the original payment. Creation, payments, batch
returns, holds and consumption have request IDs. Review actions require the exact displayed
receipt version; evidence changes increment it. Stale review attempts fail before stock posting.

External report filters include date, contact, source, channel, review, verification and payment.
Search covers reference, invoice, product, batch, manufacturer, seller and phone. Reports have
server-side totals and paged results; CSV/Excel exports fetch all filtered pages. Receipt-level
traceability exports include batches, costs, evidence filenames, receiver and reviewer, with an
internal goods-received PDF and signature spaces.

Product procurement history combines marketplace and external items without joining batch/document
rows into financial totals. Marketplace quantities use `order_item_fulfilled_qty`, prices use
`order_item_effective_price`, and resolved returns are separate. External drafts/rejections are
excluded, pending/quarantined receipts remain explicitly labelled, and gross cost/weighted unit
prices are separated from returned units. Weighted prices, min/max and last prices are grouped
by exact catalogue/inventory identity and supplier; unrelated medicines are never averaged into
a channel price. Product/manufacturer/unit-price filters apply server-side before totals.
Both receipt exports and combined history exports retrieve every filtered page. Existing marketplace-only reports retain their semantics;
the Reports link opens the combined history.

## Migration and rollout

Apply, in order, after the repository's prior migrations:

1. `20261113100000_external_procurement_schema.sql`
2. `20261113110000_external_procurement_workflow.sql`
3. `20261113120000_external_procurement_reports.sql`
4. `20261113130000_external_procurement_batch_holds.sql`
5. `20261114100000_external_procurement_completion.sql`

The dates follow the repository's existing migration sequence, not deployment dates. Do not run an
unreviewed blanket production reset. Changes are additive except for the inventory balance guard;
test existing import/adjustment workflows during rollout. Deploy database migrations before using
the new frontend, then have each pharmacy owner assign its reviewers in Settings.

No hosted database migration is executed by the code push. Forward fixes should preserve receipts,
payments, reviews, evidence and movements. Do not drop the new tables or reverse stock by deleting
history. To pause rollout, remove access to the entry point while preserving database records and
the guard protecting already-posted lots.

## Validation

- `npm test`: full Vitest suite (749 tests at implementation).
- `npx tsc --noEmit`, targeted ESLint, and `npm run build`.
- `tests/local-supabase/external-procurement.sql`: transactionally rolled-back real SQL assertions
  using existing `zz.cc`/`zz.u` fixtures. Covers RLS and storage isolation, direct-write denial,
  no admin bypass, reviewer activation/revocation, contacts without roles, source/evidence rules,
  two-batch posting, idempotency, returns, credit, holds/releases, immutable audit, search, analytics,
  legacy unbatched adjustment and marketplace checkout isolation.
- `tests/local-supabase/external-procurement-concurrency.mjs`: two real database sessions test
  duplicate approval, same-request payment/consumption retries and competing returns. Defaults to the isolated
  local `external_procurement_review` database; accepts `EXTERNAL_TEST_DB=external_procurement_release`.
  Requires all five external migrations. Fixture rows use unique IDs. The transactional suite can
  run before or after concurrency tests without assuming an empty procurement database.
- `tests/external-procurement-ui.mjs`: Playwright desktop/mobile HTTP contract tests. Run Vite on
  port 5186 with `VITE_SUPABASE_URL=http://127.0.0.1:54399` and a dummy public key. No hosted API is used.
  Uses the repository's existing `.tmp/import-db/node_modules/playwright` test installation.

SQL validation used an isolated copy of the local fixture database with the required existing
accounting, order-amendment, backorder and effective-price schema helpers, then the new migrations.
This is not a verification of hosted-schema drift or a complete rebuild of every historical seed.
Browser tests use mocked HTTP; actual database authorization is covered by the SQL suites.

## Completion validation

The five external migrations were applied in order to a fresh isolated copy of the local
`credit_review_clean` fixture, after its missing accounting/order-amendment/backorder/price
prerequisites. The expanded SQL suite covers stale evidence revisions, consumption retry and
quarantine guards, weighted-cost replenishment, statement reconciliation, structured filters,
workspace authorization and the existing posting/payment/return/RLS regression checks.
No hosted migration was applied. The user will apply the five files above after all earlier
pending repository migrations. Do not skip the completion migration: the frontend sends its
review-version and analytics-filter parameters.

Final validation: 749 unit tests, TypeScript, targeted ESLint, production build, real SQL
regressions and concurrency checks, and desktop/mobile HTTP browser checks passed. The build
retains the existing large-chunk warning. Browser HTTP is mocked; hosted deployment and
production-schema compatibility must be checked when applying migrations.
