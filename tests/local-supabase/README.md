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
