# DrugXone Phase 0 remediation plan

Approved attribution: Powered by Daventra Technologies. Branding changes are deferred.

## Reconfirmed paths before edits

- P0-01: latest handle_new_user in 20260422070000 trusts admin metadata and bootstraps first user.
- P0-02: api/staff/invite.ts attaches existing users; update.ts modifies global Auth and profiles; business_staff policies and add_business_staff_by_email expose alternate membership writes.
- P0-03: 20260418043000 verification trigger runs only on UPDATE; products policies omit business type.
- P0-04: original/staff order and item INSERT policies remain; seller UPDATE permits all fields. create_marketplace_orders in 20260421030000 already locks and prices in PostgreSQL.
- P0-05: cancellation trigger restores unproven quantities on every transition into cancelled. No state machine.

## Safe implementation

Add one forward migration after both September 13 migrations. Preserve historical migrations and rows. Revoke direct client order/item/history writes and client membership mutations; explicitly revoke unsafe RPC execution for anon/authenticated. Replace signup and verification triggers. Retain controlled admin provisioning without adding/removing existing admins.

Canonical checkout records its actual deductions in a small private table in the same transaction. No backfill guesses that legacy orders reserved stock. Cancellation of legacy orders without evidence fails closed for manual investigation. No existing row constraints are validated or data deleted to make deployment pass. New item relationships are checked by triggers; immutable historical items are not rewritten.

Lifecycle: pending -> accepted -> packed -> dispatched -> delivered; pending/accepted -> cancelled. Same-state retries are no-ops. Delivered/cancelled are terminal. Payment acknowledgement remains available through a controlled RPC.

Existing unrelated accounts cannot be attached by tenant invitation APIs. New invited accounts remain pending until the account itself accepts; tenant administrators cannot activate pending invitations. Account profile fields become read-only in tenant staff editing.

Run read-only preflight on the target separately; no hosted DB connection or migration application is authorized. Test against isolated PostgreSQL including role/RLS and simultaneous transactions, then lint/typecheck/build and focused re-audit.

## Verification and handoff

The new migration is `20260914090000_phase0_production_blockers.sql`; apply only through a separately authorized release after both September 13 migrations and a target-data review. Historical migrations were not edited. Deploy the updated application and migration together in a maintenance window: old clients using direct order updates will correctly receive permission errors after the migration. No rollback should restore those insecure grants.

Read-only investigation queries: `supabase/phase0_read_only_review.sql`. Sections 1-8 run before migration; section 9 requires the new deduction table. They cover admins, platform roles, approvals, missing evidence, malformed orders, supplier mismatches, duplicates, cancellation history, multi-business users and suspicious memberships. Findings are investigation leads, not proof. No production queries were run. Existing invalid rows remain unchanged and are not granted fabricated deduction evidence.

Tests use PostgreSQL 17 in an isolated local cluster with synthetic Auth/Storage schemas and real database roles/RLS. All 29 exact migration files are applied. A synthetic approved wholesaler is inserted before the historical seeds because the existing migration chain cannot bootstrap without it. The test also inserts invalid historical order data before Phase 0 and verifies preservation. Supabase Auth email delivery and hosted PostgREST configuration are not end-to-end tested.

Commands: `npm test` (38 unit/API tests), `npm run test:db` (36 database subtests plus parent: 37 reported), `npm run typecheck` (includes server APIs), `npm run lint`, `npm run build`. Database tests cover all 25 requested cases; concurrent buyers genuinely wait on PostgreSQL locks before competing for stock. The local PostgreSQL process is stopped; temporary synthetic clusters are retained for diagnosis. No production connection variables are read by the runner.

An initial database run found a PL/pgSQL variable/alias collision in restoration; fixed and rerun successfully. An initial unit run discovered the Node database suite as a Vitest file; renamed the runner and reran successfully. Including API files in type checking exposed two pre-existing Supabase client annotation errors in platform staff helpers; only their type annotations changed.

## Focused re-audit

| Area                               | Phase 0 result | Limit                                                                                                                                                  |
| ---------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authentication                     | PASS           | Public signup cannot create privileged roles, including first account; existing privileged accounts require review                                     |
| Authorization                      | WARNING        | Targeted caller boundaries pass; broader platform-admin governance findings remain                                                                     |
| Business verification              | PASS           | Insert forced pending; ordinary approval/audit edits rejected; identity/contact/document changes reopen review; wholesale writes enforce business type |
| Organisation isolation             | PASS           | Tested tenant API/RLS/checkout/cancellation paths reject cross-business changes; existing compromised accounts and hosted policies remain unverified   |
| Order creation                     | PASS           | Client writes revoked; service-only checkout owns prices, parties, stock and deduction evidence                                                        |
| Order lifecycle                    | PASS           | Controlled seller RPC and database state machine; terminal states cannot reopen                                                                        |
| Inventory cancellation/restoration | PASS           | Private actual-deduction evidence, transactional at-most-once restoration; legacy cancellation without evidence fails closed                           |

PASS applies to the implemented and tested Phase 0 boundary, not the entire production deployment.

## Remaining risks: NOT READY

- Existing privileged accounts, approvals, memberships and stock/order anomalies need manual review. No administrators were added, removed or silently promoted.
- Legacy orders lack provable deductions; automatic cancellation is blocked until deliberate reconciliation. Existing invalid rows are preserved, not repaired.
- Manual stock edits still permit stale absolute overwrites; full stock reconciliation/adjustment auditing is outside this phase.
- Checkout lacks durable request idempotency; retry after a lost response can create another otherwise-valid order. Receipt email/outbox retry integrity is still incomplete.
- Vulnerable XLSX dependency, ambiguous PDF/table parsing, file limits, product identity differences and import-wide locking remain.
- Historical seeds/destructive deduplication, prototype schema, broader platform privilege inconsistencies, storage validation and incomplete audit attribution remain.
- Approval now invalidates on evidence changes but does not implement a complete document-review/expiry/suspension system.
- Production Auth configuration, grants, backups, effective schema and environment remain unverified.
- Existing-account staff invitation is intentionally rejected. New invitation requires the verified recipient to accept during password setup. Tenant global profile fields are read-only. Memberships deactivated before acceptance cannot be reactivated by an owner.
- Receipt tracking without a service-role server key remains unavailable after direct writes are revoked; payment acknowledgement uses its RPC. Production checkout already requires that key; none was added or changed.

No deployment, push, commit, production migration application, environment modification, redesign or new marketplace feature was performed.

## Final check results

- `npm run lint`: exit 0, no errors or warnings. Generated `.vercel` and local `.tmp` artifacts are excluded; an initial scan was interrupted while traversing generated output. Four formatting errors were then corrected and the full lint rerun passed.
- `npm run typecheck`: exit 0, including API files.
- `npm test`: exit 0; 5 files, 38 tests passed, 0 failed.
- `npm run test:db`: exit 0; 36 subtests plus parent, 37 passed, 0 failed, 0 skipped. PostgreSQL contention demonstrated exactly one successful purchase of 8 from stock 10, final stock 2.
- `npm run build`: exit 0; 2,405 modules transformed.
- `git diff --check`: exit 0.

Final production verdict: **NOT READY**. Changes remain uncommitted and unapplied to production.
