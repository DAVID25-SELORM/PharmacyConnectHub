# Real-schema validation on a local Supabase stack (Docker)

Never points at a hosted project. Uses throwaway local keys.

1. Make a scratch dir (NOT this repo, so `supabase/config.toml`'s production `project_id` is never used):
   `npx supabase init` there, set `project_id = "drugxone-local-validation"`, copy `supabase/migrations/` in.
2. Known problem: `20260419010000_seed_wholesaler_catalog_cash.sql` and
   `20260419011000_seed_wholesaler_catalog_retail_40th_quarter.sql` raise on an empty database
   ("No approved wholesaler found") so the full history does not build from scratch. Data-only seeds:
   move both out of the scratch copy to build the schema.
3. Baseline: apply migrations up to `20260920110000`, then `docker exec -i supabase_db_<project_id> psql -U postgres -f - < setup.sql` and `pre.sql`
   (reproduces the old NULL-role bypass on the previous functions).
4. Apply `20260921100000` (`npx supabase migration up --local`), rerun `setup.sql`, run `post1.sql` (43 checks) and `checkout1.sql`.
5. Apply the rest (or `npx supabase db reset --local`), rerun `setup.sql`, run `post2.sql` (17 checks).
6. `invite-api.local.mjs`: run with `npx tsx`, env `API_URL`, `ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (from `supabase status -o env`),
   `HANDLER_PATH=file:///.../api/staff/invite.ts`; users need passwords (see the UPDATE auth.users in the report/session).

7. `activity-log.sql` (33 checks on a 300k-row audit_logs) and `activity-log-explain.sql` (query plans): run after `setup.sql` with 20260921120000 applied.

8. `reports.sql` (46 checks: KPIs, sales/wholesaler/pharmacy/customer/product rollups, keyset
   pagination, cross-tenant and staff access, pending-business self-access): run after `setup.sql`
   with 20260923100000 applied.

9. `credit-foundation.sql` (43 checks: ledger-based exposure, partial payments / credit notes freeing credit,
   cancellation release, suspend / block / reactivate) and `credit-concurrency.sh` (two real database
   sessions placing GHS 4,000 orders against a GHS 5,000 limit; exactly one may succeed, and the second
   must wait for the first). Run both after `setup.sql` with 20261016100000 applied. The shell script
   places its two orders on DIFFERENT products on purpose, so only the credit-relationship lock (not a
   shared product row lock) can make the second session wait. As a negative control, remove `FOR UPDATE`
   from the credit lookup in `create_marketplace_orders` and the script must FAIL (exposure 8,000).

   Use fresh fixtures separately for these two suites. The concurrency script accepts `DB_NAME`
   (default `postgres`) to target an isolated database within the local container. The SQL suite
   raises an exception if any recorded assertion fails; run psql with `ON_ERROR_STOP=1`.
   Cancellation coverage includes a manual credit note whose reason is `Order cancelled`: it must
   not suppress the automatic release, which uses a unique `cancellation_order_id` marker.

## Phase 3 continuation validation (2026-10-03)

- Unit suite: 284 tests passed after shared credit-status and payment-allocation validation fixes.
- TypeScript check and production build passed during the continuation.
- Targeted lint passes for credit components/helpers. The pharmacy route retains ten existing
  `no-explicit-any` errors; its formatting errors were corrected.
- Isolated copy of the local Supabase database: 43 credit-foundation assertions passed.
- Two-session concurrency suite: all 6 checks passed, using different products for each order.
- No hosted database migration or deployment was performed.

The migration preserves the existing due-date basis (order date plus agreed days). Historical
orders are not assigned guessed term snapshots. Browser/responsive validation and staging rollout
remain outstanding. Later phases should review cancellation after partial payment, reversal of
cancellation credits, and concurrent ledger adjustments as well as checkout concurrency.

Rollback: retain ledger entries and cancellation markers to preserve financial history. Restore
prior RPC/UI definitions only through a reviewed forward migration; do not delete posted release
entries or drop ledger data. Reverting to the previous order-total exposure calculation changes
available credit after partial payments and requires explicit financial review.

10. `credit-override.sql` (42 checks) and `credit-override-concurrency.sh`: the one-time over-limit credit
    override (grant / use once / expire / revoke, suspension still wins, fully audited) and the proof that
    two simultaneous over-limit orders cannot both consume the same override. Run after `setup.sql` with
    20261019100000 applied. Negative control: remove the `FOR UPDATE` locks on the credit line AND on
    the override lookup in `create_marketplace_orders`; the script must then FAIL (exposure 6,400).

11. Running against a production-like schema: install `production-guard-fixture.sql` (production's legacy
    order lifecycle guard) and re-apply `20261017110000_production_checkout_compatibility.sql`, which
    patches it. Tests must then walk real status transitions (pending -> accepted -> packed -> dispatched
    -> delivered) rather than jump; `settlement-method.sql` and `credit-foundation.sql` do.

12. `credit-effective-date.sql` (45 checks): credit terms that take effect on a future date (scheduled
    change applied lazily under the same row lock as checkout). Run after 20261020100000.

13. `accounting-registers.sql` (80 checks): the receivables / payables registers - the ageing rule at every
    boundary, filters, paging, payment register, finance-only access on both sides, cross-organisation
    isolation. Run after 20261021100000.

14. `credit-account-statements.sql` (61 checks): credit account statements - opening + charges - credits =
    closing with a running balance on every ledger line (invoices, payments, unallocated payments,
    reversals, credit notes, debit notes, write-offs), inclusive range boundaries, negative balances,
    the 2,000-line cap, the ageing block, the counterparty list, finance-only access on both sides and
    no probing of unrelated businesses. Run after 20261022100000. Mutation check: change the opening
    balance filter from `< p_from` to `<= p_from` and the one-day-range and truncation checks must fail.

15. `pharmacy-price-history.sql` (51 checks): the pharmacy price-history report - price paid per product,
    matched across suppliers on name + brand + form + pack size, change against the previous purchase
    from the SAME supplier (looking back before the range), "cheaper elsewhere", cancelled orders ignored,
    quantity-weighted average, filters, paging, the purchases behind a row, and access (owner and active
    staff only; another pharmacy, a wholesaler and suspended staff are refused). The test lifts production's
    `phase0_order_integrity` trigger only while dating the fixtures. Run after 20261023100000. Mutation
    checks: count cancelled orders, or drop `h.sid` from the `lag()` partition; checks must fail.
