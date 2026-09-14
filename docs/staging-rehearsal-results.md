# DrugXone staging rehearsal results � 14 September 2026

## Staging Environment

**Local real Supabase stack**, project `drugxone-isolated-rehearsal`; application 127.0.0.1:4180, API 127.0.0.1:56321, PostgreSQL 127.0.0.1:56322, Mailpit 127.0.0.1:56324. Real GoTrue, PostgREST, Storage and PostgreSQL were used. No production project was linked, queried or mutated. Local synthetic accounts and generated credentials are confined to ignored `.tmp/staging-rehearsal`. No real customer emails or payment service calls were made.

Docker initially was stopped. After startup and image download, the CLI published wildcard bindings despite a localhost-default network. Containers with published ports were recreated with explicit loopback bindings before synthetic user creation. Gateway certificate-file ownership was restored after recreation. These were infrastructure retries, not migration failures. Final services were healthy; published ports were verified loopback-only.

## Migration Results

PASS: one supported fresh-baseline migration applied, version `20260914120000`, name `fresh_baseline`. It incorporates 29 source migrations in timestamp order from a 32-file manifest, excluding the two demo-stock seeds and hardcoded membership deletion. All manifest hashes matched; source order is recorded in `supabase/baseline/manifest.json`. No seed business, product or platform user existed before tests. No migration failure/retry occurred. Prototype schema was not used.

Do not confuse this single baseline history entry with an existing installation's individual migration history. Future migration-history reconciliation still requires a reviewed procedure. A representative historical snapshot was not supplied: existing-data upgrade is **WARN/unrehearsed**, not PASS.

## Hosted Security Verification

Hosted Supabase and Vercel were not inspected; this is local staging evidence only. Actual local table RLS, policies, grants, SECURITY DEFINER search paths and sensitive RPC execution were queried. All public application tables had RLS enabled. The checked service-only checkout/staff/receipt/internal audit RPCs were not executable by anon/authenticated. No missing pinned search path was found in the inspected security-definer functions. Detailed snapshots remain in `.tmp/staging-rehearsal/effective-security.json` and `security-review.json`.

Local Auth email confirmation was enabled. Signup returned no session before verification. Recovery and invitations used actual Auth token verification, with administrative link generation as a test-inbox shortcut. This does not fully validate clicking SMTP confirmation/recovery links in a deployed browser. Local redirect configuration is not hosted redirect evidence.

## End-to-End Results

Real-service scenarios passed: manipulated first signup; legitimate owners and pending businesses; owner invitation plus platform-admin acceptance; denied unapproved inventory; actual private Storage; evidence review/replacement; stock operations; import preview/replay; multivendor checkout; concurrent HTTP buyers; cross-tenant attacks; private print RPC; lifecycle; concurrent payment confirmation; wholesaler cancellation; tenant cashier/manager invitation acceptance; recovery/password/login/refresh/logout; read-only review queries.

Real browser scenarios passed: buyer login/session restoration/own-order print; catalogue -> cart -> canonical checkout; seller login/session restoration/own-order print; CSV, XLS and XLSX preview/commit; pasted-table commit; missing-middle-price confirmation blocked. Captured browser JavaScript errors for the login/printing scenarios: zero.

Harness corrections were required: login redirects to dashboard before workspace navigation; pharmacy orders require selecting My orders; cancellation belongs to the wholesaler; resetting to the same password is correctly rejected. Corrected targeted runs passed. Initial raw failed-attempt logs are retained; they are not hidden or counted as application regressions.

### Required matrix

| Area                       | Result | Evidence / limitation                                                                                                                        |
| -------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Clean migration install    | PASS   | Actual fresh baseline, zero initial demo rows                                                                                                |
| Existing-data upgrade      | WARN   | No representative pre-remediation snapshot                                                                                                   |
| Authentication             | PASS   | Actual signup/token verification/login/refresh/logout                                                                                        |
| Signup privilege isolation | PASS   | admin/owner/platform_admin metadata denied privileges                                                                                        |
| Platform governance        | PASS   | Owner API invite/accept; admin and owner-overwrite denials                                                                                   |
| Business verification      | PASS   | Version-bound RPC review; replacement pending                                                                                                |
| Storage isolation          | PASS   | Real Storage cross-tenant, type/size and signed access tests                                                                                 |
| Product import             | WARN   | Real CSV/XLS/XLSX/paste commits pass; PDF and full malformed/resource matrix remain previous isolated parser tests, not full staging commits |
| Product identity           | PASS   | Real preview matching/replay and seller split; full ambiguity regression exists separately                                                   |
| Inventory adjustment       | PASS   | 80+20=100;100-15=85;100->93; excess removal denied                                                                                           |
| Inventory ledger           | PASS   | Before/delta/after, actor and movements verified                                                                                             |
| Checkout                   | PASS   | Browser checkout and actual multivendor API                                                                                                  |
| Checkout concurrency       | PASS   | Two buyers order8 from10: one success, final2, one deduction                                                                                 |
| Checkout idempotency       | PASS   | Same HTTP key recovers result; changed cart rejected                                                                                         |
| Order lifecycle            | PASS   | Accepted/packed/dispatched/delivered; prohibited reversal denied                                                                             |
| Cancellation restoration   | PASS   | Authorized seller cancellation twice, one restoration                                                                                        |
| Payment confirmation       | PASS   | Concurrent actual APIs, one paid transition/job                                                                                              |
| Receipt retry              | WARN   | Failure and simulated-provider success/sent suppression pass; external provider not exercised                                                |
| Pharmacy order printing    | PASS   | Real session, own-order preview and foreign-order RPC denial                                                                                 |
| Wholesaler order printing  | PASS   | Real session, own-order preview and foreign-order RPC denial                                                                                 |
| Cross-tenant isolation     | PASS   | Actual sessions and direct database API attacks                                                                                              |
| Audit attribution          | WARN   | Business/stock/review/payment actor present; Order placed actor absent, linked movement carries buyer                                        |
| Recovery flow              | WARN   | Real Auth recovery/password works; full emailed browser recovery link untested                                                               |
| Security headers           | WARN   | Prior production-bundle CSP test; no hosted HTTPS/header inspection                                                                          |
| Secret exposure            | PASS   | 12 built assets pattern-scanned; no private credential matches; bounded scan                                                                 |
| Backup/restore             | WARN   | Logical restore matches8 table hashes; Storage archive extracted; hosted/PITR/full stack restore untested                                    |
| Branding/placeholders      | PASS   | Real print previews retain DrugXone; prior contact regression passes; import sample rows are intentional examples                            |

### Golden workflow coverage

1 register wholesaler PASS (Auth); 2 upload evidence PASS (Storage API); 3 admin approve PASS (RPC); 4 import products PASS (browser); 5 adjust stock PASS (RPC); 6 register pharmacy PASS (Auth); 7 browse catalogue PASS (browser); 8 add cart PASS; 9 checkout PASS; 10 deduction PASS; 11 wholesaler receives order PASS; 12 both print PASS; 13 accept PASS; 14 pack PASS; 15 dispatch PASS; **18 deliver PASS before16**; 16 payment PASS; 17 receipt-state workflow PASS with external send simulated; 19 historical order PASS; 20 movement history PASS; 21 audit linkage PASS with attribution warning above. This is a composite real-service/browser rehearsal, not one uninterrupted all-browser onboarding sequence. Required onboarding document types and administrative review UI still need a complete acceptance run.

Cancellation flow: place order PASS; deduction PASS; authorized seller cancellation PASS; one restoration PASS; repeated cancellation PASS; no second restoration PASS; movement history PASS; audit actor PASS; reactivation denied PASS.

## Concurrency Results

Two real HTTP buyers requested eight units from stock10 concurrently. Exactly one succeeded; final stock2 and one checkout movement. Same-key network retries returned the same result; a changed cart with that key was rejected. Two payment-confirmation APIs returned safely with one durable payment/outbox state.

## Cross-Tenant Security Results

Foreign order reads returned no rows, foreign private print RPCs denied access, foreign inventory history was hidden, foreign stock changes were rejected, and direct orders/items/audit/stock writes were rejected. Pharmacies and unapproved wholesalers could not import. Storage access and overwrite attempts across tenants failed.

## Payment/Receipt Results

COD confirmation before delivery was rejected. Delivered confirmation became paid atomically and remained paid when email was unconfigured. A controlled test-provider result was recorded through service receipt RPCs; the actual retry API recognized sent state and did not knowingly send again. No real Resend request was made. Provider-success/tracking-loss recovery and external idempotency remain deployment acceptance requirements.

## Order Printing Results

Actual pharmacy and wholesaler browsers displayed their own order previews. RPC foreign-order access was denied; before/after order snapshots were unchanged. Screenshots: `.tmp/staging-rehearsal/buyer-print.png`, `seller-print.png`. Prior Phase2 rendering tests also verified historical prices, contacts and no mutation; no new print redesign occurred.

## Storage Results

Actual private licenses bucket:10MiB, PDF/JPEG/PNG. Cross-business read/overwrite, unsupported HTML and oversized PDF failed. Missing-object metadata failed. Authorized30-second signed download worked. Replacement generated a new version and pending status; stale version review failed. Unknown files were not deleted.

## Audit Results

Business approvals, staff invitations through API, stock changes, imports, cancellation, payment and evidence replacement carried actors. Checkout movement audits carried buyers and order IDs. Generic Order placed events and signup-created submission/owner-membership events had null actors; signup-created events arise before an authenticated session. Administrative owner bootstrap was a documented test-only SQL action. Do not represent every event as fully attributed.

## Backup/Restore Results

Database custom-format dump restored into separate local database `drugxone_restore_rehearsal_v2` in6.544 seconds. Eight compared tables matched row counts/content hashes: products, orders, items, movements, audit, document metadata, Auth users and Storage objects. Ordinary postgres restore first failed on Supabase-owned objects; local supabase_admin retry succeeded. This used the same isolated cluster and no-owner/no-privileges restore, not an independent roles/grants/PITR disaster recovery exercise.

Storage was separately archived (25,088 bytes), extracted to a separate folder, with five files present. It was not attached to a second Storage service. Hosted RPO/RTO, encrypted backup access, retention, off-machine restore and PITR remain unresolved. Timing is local test evidence, not a production RTO commitment.

## Branding/Placeholder Results

DrugXone and DAVENTRA branding remained in real print previews. Approved platform contacts remain covered by previous regression evidence. Staging names, `@example.test` emails and import template examples are intentional; no real customer confidential data was used. No physical platform address was invented.

## Existing Data Findings

Representative test data included2 wholesalers,2 legitimate pharmacies plus3 attack-signup pharmacies, platform owner/admin, tenant cashier/manager, multiple products/orders, cancelled/delivered/paid/unpaid states and replaced evidence. Phase0/1/2 read-only queries executed against staging. No historical customer snapshot existed; production legacy findings cannot be inferred from synthetic data.

## Production Blockers

### Code blocker

Complete remaining browser acceptance coverage for required evidence onboarding/admin review, recovery email consumption and PDF/error import paths. Resolve or explicitly accept the generic order-audit attribution gap with linked movement evidence; no demonstrated authorization/stock-integrity regression was found in this rehearsal.

### Data blocker

Representative existing-data upgrade and production read-only conflict review remain outstanding, including platform authority, legacy product/catalogue identity and stock/order evidence.

### Supabase configuration blocker

Hosted migration history, effective grants/RLS, Auth confirmation/redirects, Storage configuration and abuse limits remain unverified.

### Vercel configuration blocker

No safe hosted staging deployment was configured; production environment isolation, HTTPS/domain, deployed headers/CSP and API configuration remain unverified.

### Backup/operations blocker

Independent full database/roles/Storage restore and agreed production RPO/RTO/PITR/monitoring are not established by this same-cluster logical test.

### External-provider blocker

Safe email-provider sandbox delivery, failure/tracking-loss/idempotency acceptance and sender configuration remain unverified. No live banking integration was used.

## Production Deployment Readiness

**NOT READY FOR PRODUCTION**. Substantial local real-service coverage passed; hosted and upgrade/operations evidence is still required.

## Proposed Deployment Runbook

See `staging-rehearsal-runbook.md` for preflight, backup, integrity review, ordered corrections, coordinated API/frontend deployment, smoke/security checks, monitoring and explicit rollback checkpoints. It is a proposal only and was not executed.

## Git Status

Only staging harness/documentation additions were made during this rehearsal; earlier Phase1/2 work remains uncommitted. No application feature or historical migration was changed. Full status is in `staging-git-status.txt`. No commit, push, hosted deployment, production mutation, environment-variable change or DNS change occurred.
