# Pricing controls: what changed and how to roll it out

Migration: `supabase/migrations/20261210100000_billing_pricing_controls.sql`
Screen: Admin → Billing → **Pricing & Plans** (replaces the old Plans tab).
Nothing here switches billing on, charges anyone, or edits an issued invoice, ledger entry or assessment.

## What the Super Admin can now do

| Need | Where |
| --- | --- |
| See every plan, what is in force, what is scheduled | Current plans table |
| Create a plan | New plan |
| Change a price, trial, free orders, commission %, minimum, maximum, monthly cap | Change pricing (always a new version; old versions never change) |
| Use the approved starting wholesaler terms (GH₵ 50/month, 30-day trial, 10 launch + 5 monthly free orders, 1% commission, GH₵ 50 max per order) | "Use the recommended starting terms" button in Change pricing: it only fills the form |
| Make a change now, or schedule it for a future date | Change pricing → When |
| Choose who it reaches: new subscribers only, or new and existing | Change pricing → Who |
| Keep or replace negotiated (custom) pricing | Change pricing → custom pricing choice |
| See which businesses are affected, and when each moves, before saving | The review step (nothing is saved until the confirmation) |
| Cancel a scheduled change before it starts | Scheduled changes → Cancel |
| Turn subscriptions and commissions on/off separately | Subscriptions and commissions → Change |
| Turn a plan on/off for new subscribers | On / off |
| See who changed what and why, and how many businesses are on each version | History |
| Promotions and one business's custom pricing | Already existed; the screen links to them |

Only the platform owner (Super Admin) can change any of this. Other platform administrators see the same screen read-only.
This is enforced in the database (one check that every billing write goes through), not only in the screen.

## The rules the database enforces

* **A future price never takes effect early.** A version dated in the future must be *scheduled*; the database refuses to store it as published. (Before this change a future-dated version was stored but took effect at once.)
* **New subscribers** get the version in force on *their* start date.
* **Existing subscribers** stay on their version. If the change was scheduled for existing subscribers too, each one moves at the start of their *own* next billing cycle, never earlier and never backwards. Negotiated pricing is kept unless the Super Admin chose to replace it. Businesses with later terms already, or ended subscriptions, are skipped and listed.
* **Cancel before activation**, with a reason, fully audited. Once the start moment has come it cannot be cancelled (publish a new change instead).
* **No retroactive change.** Invoices, ledger entries and order assessments are append-only and untouched. A switch or a new price changes only what is assessed afterwards.
* **Switches:** subscriptions off → new periods are recorded as waived; commissions off → new orders are recorded as exempt. Each can be turned on again.

## Before you apply it to production

1. Run `preflight.sql` (read-only) in the production SQL Editor. Every row must be `true`. Row 1 matters most: after this change only the platform owner can change billing, so an active owner with the administrator role must exist (the migration refuses to apply without one). Row 3 catches any version already dated in the future, which would behave differently afterwards. Rows 7 confirm the seven billing functions the migration replaces are exactly the versions it was built against.
2. Apply the migration (one file, one transaction).
3. Run `verify.sql`. Every row should say `true`.
4. Push the app change to `main` (the screen calls the new functions, so apply the migration first).

The shadow test is unaffected: billing stays disabled/shadow, and the 14-day rule for going live is not touched.

## Tests (local)

* `tests/local-supabase/platform-billing-pricing.sql`: 103 checks (Super Admin only on all 12 billing writes, scheduling, cancellation, new vs existing subscribers, cycle transitions, custom pricing, switches, history immutability, duplicate-run safety, shadow and real separation).
* All existing billing suites still pass with their original counts.
* `src/lib/billing-pricing.test.ts` (16) and `src/components/billing/PricingPlans.test.tsx` (18); full vitest 94 files / 980 tests.
* Mutation checks: six deliberate breakages of the migration were each caught by the suite.

## Accounting policies that are NOT decided (reported, not invented)

1. **Back-order shipments:** commission is added when the order's effective total rises, i.e. when the shipment is recorded, not when the buyer confirms receipt.
2. **Returns:** only returns resolved as a refund or credit reduce the commissionable value. Replacements do not.
3. **Payment status:** commission is assessed when an order is delivered, whether or not the buyer has paid. Unpaid credit orders, and payment refunds that do not go through a return or an order amendment, are not reflected.

## Known limits

* The owner-only gate is also shown in the UI on the Pricing & Plans screen only; the other billing tabs show the database's refusal message to a non-owner who tries to change something.
* The database treats the 14-day shadow rule as advisory; the Go live screen is stricter.
