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

16. `credit-reminders.sql` (52 checks): credit due-date reminders - every level boundary (due in 1-3 days,
    due today, 1-6 / 7-29 / 30+ days overdue), one grouped notification per business per level, each invoice
    announced once per level and again only on escalation, paid / cancelled / disputed invoices skipped
    (a lifted dispute is announced), part-paid invoices reminded for what is left, recipients limited to the
    owner plus active staff who can open Accounting, the wholesaler told only about overdue invoices, no
    cross-organisation leakage, the generator not callable by users, and the finance-only throttled
    page-load entry point. Run after 20261024100000. Mutation checks: stop skipping `disputed`, or drop the
    `credit_reminders_sent` check; checks must fail. (`pg_cron` is not installed locally: the daily schedule
    is not exercised here.)

17. `accounting-overview.sql` (42 checks): the numbers behind the finance part of the dashboard - totals,
    overdue, due-soon (today..+7 days), disputed, the five aging buckets (checked against
    `credit_aging_summary` AND the Credit tab's own `wholesaler_ar_summary` / `pharmacy_ap_summary`, so every
    screen uses one aging rule), top overdue counterparties, payments in the last 30 days, money on account
    not matched to an invoice, both sides, finance-only access and isolation. Run after 20261025100000.
    Mutation checks: widen the due-soon window, or widen the payments window; checks must fail.

18. `credit-reads-finance-only.sql` (44 checks): the older Credit-tab readers (`list_credit_invoices`,
    `get_credit_invoice`, `wholesaler_ar_summary`, `pharmacy_ap_summary`) now require `can_view_accounting()`:
    finance roles are served and get the same data as before; cashiers, assistants, warehouse users, suspended
    staff and other organisations are refused on both sides; the payment writer keeps its own rules. Run after
    20261026100000. Mutation check: put `get_credit_invoice` back on `can_act_for_business(..., 'read')` and
    the cashier / warehouse / assistant checks must fail. The migration patches the live function bodies in
    place and fails closed (no change) if a fragment does not match exactly once; it is safe to re-run.

19. `delivery-due-dates.sql` (41 checks): delivery-based credit due dates - the per-customer setting
    (owner/manager only, validated, audited, notifies the pharmacy), no due date at checkout (not overdue,
    "current" aging, no reminders), the due date set on delivery = delivery date + terms (checked against an
    order backdated 10 days), the basis copied onto each order so later switches affect only new orders,
    other creation paths (direct credit insert, as an RFQ award does), cancelled orders, cash orders, the
    audit entries and the extended readers. Run after 20261027100000. It lifts production's order guard only to
    backdate fixtures. Mutation checks: stop clearing the due date, or count from the order date; checks must
    fail. After this migration the older credit suites (foundation, override, effective-date, settlement,
    registers, reminders, overview, reads, statements) were re-run and match their previous counts.

20. `production-stock-test.sql`: documents how production's stock mechanism behaves (checkout deduction + evidence +
    movement, plain stock changes recorded as admin adjustments, insert-only order lines, cancellation restore
    exactly once, legacy orders refused). Needs `production-guard-fixture.sql` and `production-stock-fixture.sql`
    installed first (and the checkout compatibility migration 20261017110000 re-applied). Run after 20261029100000
    to see the classification change work under production's order-line guard.

21. `order-amendments-foundation.sql`: Phase 1 of order amendments - `orders.effective_total_ghs` (the immutable
    `total_ghs` is untouched), the append-only `order_events` log (RLS, no direct writes), `order_timeline()`
    (access rules, actor labels, ordering) and the credit-ledger idempotency markers. Run after 20261028100000.

22. `order-partial-fulfilment.sql` (163 checks) and `order-partial-fulfilment-concurrency.sh` (13 checks): partial
    fulfilment. Roles on both sides (warehouse/manager/cashier propose; finance, pharmacy, other businesses and
    admins refused; only the pharmacy's owner/manager/cashier respond), every validation, idempotent replays,
    the dispatch block, clarification and rejection, acceptance (effective total, one credit note, stock release /
    write-off, inventory ledger movement, batch reconciliation, audit, events, notifications), legacy orders (no
    stock write), a paid cash order refused, a credit order with a payment (invoice status nets the credit note),
    sequential amendments, cancellation restoring only what is still deducted, withdrawal, the 24-hour reminder,
    append-only records. The `.sh` runs real overlapping sessions: two simultaneous acceptances, an acceptance racing
    a cancellation, a proposal racing a dispatch. Needs the production guard + stock fixtures and migrations through
    20261030120000. Mutation checks: unpatch the cancel-restore, `credit_invoice_status`, `confirm_order_picks`, or
    drop the dispatch trigger, and the suite fails; remove the order/proposal locks and the concurrency replay check
    fails (the unique constraints still stop the double effects).

23. `order-effective-total-readers.sql` (57 checks): Phase 6. Seven orders, two of them amended through the real
    propose/accept flow, then every patched reader is checked against hand-worked figures: wholesaler, pharmacy and
    platform-admin reports (totals, units, order rows, product / customer / supplier tables, inventory velocity),
    customers list and detail, the pharmacy order list (placed + effective total, sort, unit count), the customer
    statement (placed order unchanged, accepted reduction as its own "adjustment" line, cash payment at the
    effective amount, same balance for both sides), returns capped at what was supplied, receipt data access, and the
    patch helper (idempotent, fail-closed, skips missing functions). Run after 20261101100000. Mutation checks: put
    `wholesaler_report_overview`, `request_order_return` or `customer_statement` back and the suite fails.
    The legacy suites whose fixtures edit order lines (reports, order-returns, inventory-insights, reorder-lists,
    pharmacy-price-history, order-history-filters, credit-terms, fulfillment-status-expansion, notifications,
    order-deliveries, purchase-reports, customer-statement-credit-ledger) were re-run with production's order
    guards switched off (they cannot run with the guards on) and all pass: the reader patches change nothing for
    orders that were never amended.

24. `order-backorders.sql` (130 checks) and `order-backorders-concurrency.sh` (14 checks): Phase 3, back-orders and
    shipments on credit orders. Accepting with a back-order (cash orders refused, per-line stock choice, one credit note, effective
    total), preparing shipments (roles, validation, idempotent request ids, outstanding arithmetic), the status machine, dispatch
    (credit limit re-checked, suspended / blocked / closed lines refused, a one-time override consumed once, stock needed and
    deducted once, one invoice entry per shipment, the order total raised, a paid order reopened even when a warehouse user
    dispatches), delivery and the due-date rule (earlier unpaid balance keeps its date; a fully paid order takes the new one),
    cancelling a shipment or the remaining back-order (either side), cancelling the order closing its back-order with a net stock
    restore, a legacy order (no stock write), the direct-edit guard on the order total, append-only records, the read functions,
    the statement and the reports. The `.sh` runs real overlapping sessions: the same shipment dispatched twice, two shipments that
    together exceed the credit limit (exactly one goes out), a shipment prepared while the rest is cancelled. Needs migrations
    through 20261102120000 and the production fixtures. Mutation checks: wrong invoice amount, dropped total guard, renamed statement
    line and skipped stock deduction each fail the suite; removing the credit-line lock fails concurrency scenario 2.

25. `delivery-reconciliation.sql` (104 checks) and `delivery-reconciliation-concurrency.sh` (11 checks): Phase 5, the pharmacy's
    delivery check. Permissions (pharmacy owner/manager/cashier report, assistants and other pharmacies cannot; only wholesaler
    owner/manager decide), validation (delivered orders only, 30-day window, one live report per delivery, counts add up, a reason
    for every problem, units already in a return or claim), "received in full", withdrawing, decision validation (every discrepancy
    decided, a note for a rejection), credit (one credit note, the effective total lowered, stock untouched), returns opened for
    damaged / rejected goods, replay of a decision, immutability of the records, cash orders (an already-paid order refuses a
    credit), a disputed claim, shipment reports, and the read function. Also covers the returns-to-ledger gap (D9): a return resolved
    as refund or credit on a credit order now posts one credit note. The `.sh` runs real overlapping sessions: two submissions for
    the same delivery, two simultaneous decisions (one credit note, one return), and a withdrawal racing a decision. Needs migrations
    through 20261103120000 and the production fixtures. Mutation checks: a dropped credit note, a double credit note and a skipped
    lock each fail; removing the order lock in `submit_delivery_report` fails concurrency scenario 1.

26. `price-amendments.sql` (123 checks) and `price-amendments-concurrency.sh` (13 checks): Phase 4, price amendments. Who may
    propose (owner / manager only), validation (reason, lines, price format, zero / same price refused), a paid cash order refused,
    the proposal itself (prices at the time and proposed, quantities untouched, nothing applied), one open proposal per order and no
    dispatch while one is open, questions and replies, approval (credit limit and a one-time override for an increase, blocked and
    closed credit lines, one debit note or credit note per amendment, effective total, price in force, stock untouched), replay,
    stacking a second amendment on the price in force (a net-zero change moves no money), rejection, withdrawal, cancelling the order,
    cash orders (effective total, no ledger; paid in the meantime refused), a stale proposal refused, legacy orders, price changes
    with a back-order (the shortage and the shipment are valued at the price in force), later readers (delivery reports, returns,
    reports, price history, statement) using the price in force, and append-only records. The `.sh` runs real overlapping sessions:
    the same proposal approved twice (one debit note), approval racing withdrawal, two proposals at once (one open), and two
    increases that together exceed the credit limit (exactly one applied). Needs migrations through 20261104120000 and the production
    fixtures. Mutation checks: a doubled debit note, a removed stale check, a removed credit-limit check, a widened role and a removed
    paid-order check each fail the suite; removing the credit-line lock fails concurrency scenario 4, and removing the order and
    proposal locks fails scenario 1.
