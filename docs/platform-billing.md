# Platform billing

How DrugXOne earns revenue from the businesses on it: subscriptions for pharmacies and wholesalers, and a small transaction fee on a wholesaler's delivered orders after its free allowances. Everything commercial (prices, trials, free orders, percentages, limits, features) is **configuration in the database**, never code.

Status: **Phases 1 (schema and configuration) and 2 (the engine, in shadow) are built. Nothing charges anyone**: billing is `disabled`, no business has a subscription, and the engine writes nothing while billing is disabled. Real (`active`) billing cannot be switched on yet.

## 1. Decisions (agreed 2026-10-11)

1. **Pay Now's platform commission** (`payments_settings.platform_fee_bps`) is **not used for billing**. Keep it at 0 and bill everything through this system, so a wholesaler is never charged twice. (Phase 6 adds a guard: real billing cannot go active while a split commission is set.)
2. **Credits after delivery reduce the fee.** A delivery credit or a return resolved as a refund creates an *adjustment* assessment for the change in value (never another free order).
3. **Billable amount** (`billable_gmv`) = `COALESCE(effective_total_ghs, total_ghs) − delivery_fee_ghs`: goods after discounts and accepted shortages, without the delivery fee. No tax is involved today; invoice lines will carry a nullable tax amount for later.
4. **Rolling billing periods** from each business's own start date (not calendar months). No proration; analytics use ledger dates.
5. **Shadow mode simulates free orders** so previews are accurate, but is kept completely separate from real counters (separate periods, assessments and ledger rows, `shadow = TRUE`).
6. **Anti-abuse:** the launch free-order grant is given **once per licence number and once per owner**; a plan may set a minimum billable order value below which an order is not fee-eligible and uses no free order.
7. Work happens on its own branch/worktree (`feat/platform-billing`), not in the shared working tree.

## 2. Definitions

- **Organization** = a row of `public.businesses` (type pharmacy or wholesaler). There is no separate organizations table.
- **Billable event** = an order's status becoming `delivered` (the existing final state; `orders.delivered_at` is stamped by a trigger and `order_status_history` records it). Pending, accepted, cancelled and rejected orders are never billed.
- **Eligible order** = a delivered marketplace order of a wholesaler on an active billing subscription, delivered **on or after `billing_starts_at`** (no historical charges), from a source DrugXOne produced (RFQ orders count; the separate external-supply orders do not).
- **Period** = `[start, end)` rolling monthly from `period_anchor_at`; boundaries are always computed from the anchor (anchor + n months), so a 31st anchor gives 28/29 Feb, 31 Mar, 30 Apr with no drift.
- **GMV** (reporting, Phase 3): created value, completed marketplace GMV (delivered, at effective value) and fee-eligible GMV are three different numbers; subscription revenue is never mixed with GMV; accrued, invoiced, paid and outstanding are four different numbers.

## 3. Data model (Phase 1)

| Table | Purpose |
|---|---|
| `billing_settings` | One row: platform `mode` (`disabled`, `shadow`, `active`), timezone (`Africa/Accra`), grace days, currency |
| `billing_feature_catalog` | The features a plan may grant (key, kind boolean/integer, business type). No `if (plan === 'Pro')` anywhere: code asks for a feature |
| `billing_plans` | A plan's identity: code, business type, standard/custom, name, active, publicly visible |
| `billing_plan_versions` | **Immutable** commercial terms: interval, currency, subscription amount, trial days, onboarding and monthly free orders, fee %, min/max per order, cycle cap, minimum billable order, max users/branches, entitlements. A price change publishes a new version; the old one is retired, never edited |
| `billing_subscriptions` | One per business: status, optional per-business mode (held back, never ahead of the platform), billing start and anchor, trial dates, paused, exempt-from-fees, grace |
| `billing_subscription_terms` | **Append-only** history of what a subscription is charged under from a date: the pinned plan version plus explicit overrides (a JSON key present with `null` means "no limit"; absent means "as the plan says") |
| `billing_allowance_grants` | Onboarding free orders granted (plan, promotion or admin). Use is evidenced on assessments, never a bare counter |
| `billing_periods` | One per business per period (real or shadow): totals, amount due and outstanding (calculated by the database), counts |
| `order_billing_assessments` | **Append-only** snapshot of how an order was billed: outcome, free source and number, terms used, percentage, calculated fee, cap adjustment, charged amount, rule version. One primary per order, plus numbered adjustments |
| `billing_ledger_entries` | **Append-only** money entries: subscription charge, transaction fee, free order, cap adjustment, credits, waivers, manual entries, refund, reversal. Idempotency key unique; a reversal is its own entry linked to the original and an entry can be reversed once |

Integrity the database enforces (not the screens): one real and one shadow primary assessment per order; each onboarding number used once per grant and each monthly number once per period; the launch grant once per licence and per owner; periods never overlap; a ledger entry is a charge or a credit, never both, never negative; manual and corrective entries must carry a reason; terms of a published version never change; nothing in the append-only tables can be updated or deleted.

**Security.** Every table has RLS and **no insert, update or delete grant for anyone signed in, administrators included**: all writes go through `SECURITY DEFINER` functions that check the caller. Owners, managers and finance/accounting staff of a business can read **its own** non-shadow billing; cashiers, pharmacies buying from a wholesaler and other businesses see nothing; shadow rows and settings are for platform administrators.

## 4. Phase 1 functions

Helpers (server only): `billing_period_bounds`, `billing_onboarding_keys`, `billing_resolve_terms` (plan version plus overrides at a moment), `billing_effective_mode` (the platform setting is the ceiling; a business can be held back, paused or ended, never pushed ahead). Entitlements for later wiring: `billing_feature_enabled`, `billing_limit`. **They restrict nothing unless billing is `active` for that business**, so wiring them in can never lock anyone out before billing is switched on.

Administrator operations (each needs a platform administrator, a stated reason of at least 5 characters, and writes an audit entry with previous and new values, against the business where there is one): `admin_billing_set_mode`, `admin_billing_create_plan`, `admin_billing_publish_plan_version`, `admin_billing_set_plan_availability`, `admin_billing_start_subscription`, `admin_billing_set_subscription_mode`. `active` mode cannot be switched on yet.

Seed: the feature catalog and two **example** plans (`wholesaler_example`, `retailer_example`), switched off and hidden. The wholesaler example mirrors the launch discussion (30-day trial, 5 launch free orders, 2 free orders a month, 0.75%, capped at GHS 1,500 a month, GHS 100 subscription). They are not commercial offers.

## 5. The rules the engine will follow (Phase 2)

**When an order is delivered** (trigger on `orders`, errors caught and queued so billing can never block a delivery), under a lock on the business's current period row:

1. Mode `disabled` → nothing. `shadow` → everything below, flagged shadow. `active` → real.
2. Before `billing_starts_at`, or already assessed (unique per order) → nothing.
3. Resolve the terms in force at `delivered_at` (`billing_resolve_terms`).
4. Outcome in this order: **exempt** (subscription exempt) → **excluded** (excluded source) → **below minimum** (billable under `min_billable_order_amount`) → **onboarding free** (a grant has numbers left: consume the next, record grant and number) → **monthly free** (free monthly orders used this period < allowance: consume the next) → **chargeable**. An order consumes at most one allowance. Onboarding is consumed first because it is cheaper for the platform than the reverse (an unused monthly allowance is lost, an unused onboarding allowance is not) and matches the agreed examples; onboarding never resets, monthly resets each period.
5. Chargeable: `fee = billable × percentage / 100`, then the per-order **minimum**, then the per-order **maximum**, rounded **half-up to 2 decimals once, per order, after the limits**. Then the **cycle cap**: `charged = LEAST(fee, cap − already charged this period)`, never below zero; the ledger records the calculated fee, the charged fee and a `fee_cap_adjustment` for the difference. A NULL limit means no limit. All arithmetic is `NUMERIC`.
6. Write the assessment (snapshot of the full resolved terms and the rule version) and the ledger entries, update the period totals and write the audit event, all in one transaction. A second attempt for the same order does nothing (unique index, not frontend state).
7. **Concurrency:** the period row is locked `FOR UPDATE` before the cap is read, so two orders delivered at the same moment queue instead of both seeing the remaining cap. Locks are per business only.

**Later changes in an order's value** (a delivery credit within 30 days, a back-order shipment dispatched after delivery, a return resolved as a refund) produce numbered **adjustment** assessments for the difference, priced under the original order's terms, never consuming another free order, never deleting history.

**Plan versioning.** Publishing creates version n+1 and retires n. Existing subscribers stay pinned to their version until an administrator moves them (immediately, or at their next period, with a reason); every assessment snapshots the terms it used, so history is never recalculated.

**Subscription charge.** A period's subscription is waived when the period starts before `trial_end`; otherwise it is charged at the start of the period. The trial and the free-order allowances are independent.

## 6. Rollout

Phase 1 (this): schema and configuration, mode `disabled`. Phase 2: the engine in **shadow**, reconciliation checks, concurrency tests. Phase 3: read-only billing pages (estimates, clearly labelled) for organizations and the admin dashboard. Phase 4: invoices and admin-confirmed manual payments (provider-neutral, so Paystack or Hubtel can be added later without touching calculation). Phase 5: promotions and administrator controls (extend a trial, add free orders, waive a fee, credits, price overrides, change plan, pause, exempt, mark a payment received), each with a reason and an audit entry. Phase 6: grace period, notifications, enforcement, `active`, activation at a period boundary.

Billing calculation and billing enforcement are separate: a business past due keeps working through a configurable grace period before any restriction.

## 7. Phase 2: what the engine does (built)

Migrations `20261202100000_platform_billing_engine_schema.sql` and `20261202110000_platform_billing_engine.sql`. Everything below is server-only (no signed-in user can call it) and does nothing while billing is `disabled`.

- **When an order is delivered** a trigger calls `billing_assess_order`; **when a delivered order's effective total changes** (a delivery credit, a back-order shipment) or **a return is resolved** it calls `billing_assess_order_change`. Each call is wrapped so that **any failure is caught, queued (`billing_engine_queue`) and retried, and never blocks the delivery, the value change or the return**.
- **Per business, one lock** (the subscription row, then the period row) serialises everything that spends a free order or the cap. Proved with real overlapping sessions: five GHS 4,000 orders delivered at once under a GHS 100 cap charge exactly GHS 100.00 (with the locks removed they charge GHS 180); four orders against two launch free orders give exactly two free numbers.
- **Decision order, as agreed:** exempt, excluded (paused; buyer and seller with the same owner; no billable value), below the plan's minimum order value, launch free order, monthly free order, otherwise chargeable. An order never uses two allowances. Billable value = effective total − delivery fee − returned goods credited or refunded, never below zero.
- **Fee:** `billing_compute_fee` is the only place the arithmetic lives: percentage, then per-order minimum, then maximum, rounded half-up to 2 decimals once. A zero percentage or a zero-value order has no fee whatever the minimum. The cycle cap is then applied: charged = LEAST(fee, cap − already charged this period). Cross-checked against an independent whole-number (BigInt) implementation over 5,000 cases, including every exact half-pesewa.
- **Evidence:** an immutable assessment per order (terms snapshot, rule version, free source and number, calculated fee, fee after limits, cap adjustment, charged) and ledger entries (`free_order`, `transaction_fee`, `fee_cap_adjustment`). Real assessments are audited against the business; shadow ones are not (no noise in the activity log).
- **Adjustments:** a later change in an order's value records the difference as numbered adjustment assessments, priced under the order's own original terms (never today's), landing in the period that contains the change. A drop is a `refund` credit entry; a rise is charged within the cap; an order that was free gets a `free_adjustment` (no money) and consumes no allowance.
- **Shadow versus real:** shadow rows are a separate world (own periods, assessments, ledger, free-order numbers). Real billing counts only orders delivered on or after `activated_at` (set at activation in Phase 6), so orders delivered during shadow are never billed for real.
- **Periods and state:** `billing_open_periods` opens each business's rolling periods and posts the subscription charge (waived while the period starts inside the trial or billing is paused), even for a business with no orders; `billing_advance_states` ends a trial (trialing becomes active) and makes cancel-at-period-end take effect; `billing_catch_up` assesses delivered orders the engine has not seen (oldest first, so free orders are used in delivery order); `billing_process_queue` retries failures up to 10 times, then marks them failed and reconciliation reports them.
- **Scheduled:** `billing_run_scheduled` (periods, states, queue, catch-up) runs every 15 minutes through `pg_cron` when available (it is in production); `admin_billing_run_now(reason)` runs it on demand, audited.
- **Reconciliation:** `billing_reconcile` / `admin_billing_reconciliation` report delivered orders not assessed, duplicate primaries, period totals that differ from the ledger (fees, credits, subscription), counters that differ from the assessments, assessments whose charge differs from the ledger, free numbers that are not contiguous, over-used grants, fees over the cap, and stuck queue entries.

Known simplifications: only the **seller** (wholesaler) is assessed for orders; a retailer's plan has a subscription but no per-order fee (a retailer fee is a later, explicit change). A fee credit (a drop in order value) does not free up cap space in the same period. An adjustment to an order assessed in an already-invoiced period lands in the current period (invoices arrive in Phase 4).

## 8. Verification

`docs/billing/verify-billing-p1.sql` (18 checks) and `docs/billing/verify-billing-p2.sql` (15 checks) are read-only: tables, RLS, absence of write grants, the append-only and uniqueness protections, the functions and their privileges, the triggers, that billing is off and that nothing has been billed.
