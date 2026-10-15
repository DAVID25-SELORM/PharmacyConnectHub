# Billing go-live runbook

How to take DrugXOne from "billing built and switched off" to "real businesses are being billed", one safe step at a time.

**Written 13 October 2026.** It describes the system as built through Phase 6 plus the audit-fix migration. Anything about what is in production is a thing to **check** (Step 1), not an assumption.

## The short version

1. **Check where production stands**, read-only (Step 1).
2. **The audit-fix migration** (Step 2). It was applied to production and verified on 14 October 2026, so there is nothing to apply. Step 2 explains how to confirm it.
3. **Decide the commercial terms** (Step 3). Nobody can do this for you.
4. **Configure** plans, invoice details and a pilot group (Step 4), on the Platform Billing screens.
5. **Run shadow billing for at least 14 days** and check the numbers by hand (Step 5). Nobody is charged.
6. **Activate the platform with every business held back** (Step 7). Still nobody is charged.
7. **Put the pilot businesses live, one at a time** (Step 8), and watch them through their **first invoice and first recorded payment** before widening (Steps 9 to 10).

Real billing never looks backwards: a business is only ever charged for orders delivered **after** its own go-live moment.

---

> **Update, 15 October 2026: the guided Billing Setup tab.** Admin, Billing, **Setup** now walks through everything below in four stages (Configure Billing, Set Up Invoices, Run 14-Day Shadow Test, Activate Pilot Businesses), shows what prevents activation, runs the reconciliation and an independent recalculation of shadow fees automatically, and keeps real billing locked until the shadow test has really run. See `docs/billing/setup-guide.md`. The steps and SQL below still work and explain what each stage does; the hand checks in Step 5 are now done by the page.

## Where each step is done

Everything in this runbook has a screen, under **Admin, then Billing**. Every action asks for a written reason and writes an audit entry; the database refuses anything that is not allowed and its message is shown as it is.

| Needed for go-live | Where |
|---|---|
| Create a plan, publish a new version of its terms, switch it on or off | **Plans** tab: *New plan*, *New version*, *Availability* |
| Set the invoice details (who it is from, how to pay) | **Invoices** tab: invoice settings card |
| Start a business on a plan | **Organizations** tab: *Start a subscription* |
| Change one business's mode (follow the platform, shadow, off) | **Organizations**, open the business, *Change billing mode* |
| Switch the platform to **shadow** or **off**, and run the billing job now | **Go live** tab: *Billing mode and scheduled run* |
| Switch real billing on, put businesses live | **Go live** tab: the checklist and *Put businesses live* |

The SQL in Appendix B does the same operations and still works. Use it only if a screen is unavailable.

---

## Step 1: Check where production stands (read-only, 5 minutes)

Open the SQL Editor of **PharmacyConnectHub** (project `ywpntuioeqpreouauuir`; check the project name and the PRODUCTION badge first). Run the status query in Appendix A and send me the CSV, or read it yourself against this table:

| Column | You expect | If it is different |
|---|---|---|
| `billing_mode` | `disabled` (or `shadow` if you already started) | `active` means someone switched it on: stop and tell me |
| `real_billing_ever_started` | `false` | `true` means a business has already gone live |
| `order_restriction` | `none` | Leave it `none` for launch (warnings only) |
| `grace_days` | `7` | Fine; change later if you wish |
| `subscriptions` / `businesses_live` | `0` / `0` before Step 4 | |
| `plans_switched_on` | `0` before Step 4 (the two example plans are off) | |
| `invoice_details_set` | `false` before Step 4 | |
| `scheduler_last_run` | within the last 15 minutes, or empty if it has never run | If it is old, the billing job is not running: tell me |
| `paystack_commission_bps` | **`0`** | Anything else must be corrected before Step 2 (see below) |
| `audit_fix_applied_triggers` | **`4`** | `0` means the audit-fix migration is not applied: do Step 2 |

Also re-run the read-only verification files for Phases 1 to 6 if you have any doubt they are all in (`docs/billing/verify-billing-p1.sql` … `p6.sql`). Each should report every check passed.

---

## Step 2: Apply the audit-fix migration

> **Status: already applied to production and verified on 14 October 2026.** All four triggers exist, every redefined function carries the new code, and the three money checks (no commission conflict, no real period without a go-live date, no order credited more than it was charged) all returned zero. **Do not apply it again**: a second run fails on `CREATE TRIGGER` and rolls back harmlessly. The rest of this step is kept for the record, and for rebuilding a copy of production.

**Why this is not optional.** An independent review on 13 October found three serious defects in the billing code written in the earlier phases. None has hurt anyone, because billing has never been on. All three would have hurt the first time real billing ran:

1. **Over-refunds.** When a delivered order's value was reduced after the monthly fee cap had applied, the fee credit could be larger than the fee actually charged (in the review's example: GH₵ 10 charged, GH₵ 100 credited).
2. **A back door around go-live.** Changing a business held in shadow to "follow the platform" while the platform was active could bill its old shadow history for real, bypassing the go-live step.
3. **Double charging.** Nothing stopped billing being activated while the Paystack platform commission was still above zero, so a wholesaler could be charged twice.

The fix is `supabase/migrations/20261207100000_platform_billing_audit_fixes.sql`. It is already in the code on `main`; the database change is applied by you, as before.

**Do this**

1. If `paystack_commission_bps` is not `0`, set it to `0` first (the migration refuses to apply otherwise, deliberately).
2. Apply `20261207100000_platform_billing_audit_fixes.sql` in the SQL Editor. It must go **after** both Phase 6 files.
3. Run `docs/billing/verify-billing-audit-fixes.sql` (read-only). Every `findings` value must be `0`, and the trigger list must show the four revenue-policy triggers. Send me the CSV.
4. Re-run the Appendix A status query: `audit_fix_applied_triggers` should now be `4`.

**One caution.** I did not write that migration and I have not reviewed it line by line. It was validated by the session that wrote it (149 rollout checks plus new regressions, all passing locally). Because it changes how money is calculated, I recommend I review it and run its tests myself **before** you apply it. Say the word and I will.

---

## Step 3: Decide the commercial terms

These are the decisions only you can make. Everything is configuration, never code, and any term can be changed later by publishing a new plan version (existing subscribers stay on their version until you move them).

| Decision | The earlier discussion suggested (an example, **not** a decision) | Your decision |
|---|---|---|
| Wholesaler monthly subscription | GH₵ 100 | |
| Wholesaler free trial | 30 days | |
| Free launch orders (once per business) | 5 | |
| Free orders each month | 2 | |
| Platform fee on a delivered order | 0.75% | |
| Highest fee in one month (cap) | GH₵ 1,500 | |
| Lowest and highest fee on one order | none | |
| Smallest order that earns a fee | none | |
| Pharmacy plan (subscription only, no per-order fee) | amount? | |
| Days to pay an invoice | 14 | |
| Hours between a period ending and its invoice | 24 | |
| Grace period after the due date | 7 days | |
| What happens after the grace period | warnings only at launch (agreed) | stays `none` |
| Who pays by what method | manual: bank transfer or mobile money, recorded by you | |
| Invoice issuer details | name, address, email, phone, **how to pay**, tax note | |
| The pilot group | 3 to 5 businesses you know and trust | |

Already agreed and built, so you do not need to decide again: no historical orders are ever charged; the free trial restarts at go-live; notices are in-app only; a pilot group goes first; Paystack commission stays at 0 and billing is the only revenue mechanism.

**Pick the pilot well.** Choose wholesalers that deliver a steady number of orders (so you see the fee, the free orders and the cap in action), plus one or two that deliver very few, plus at least one pharmacy. Tell each of them what is coming **before** you go live, in your own words and your own channel: DrugXOne's notices only start once a business is live.

---

## Step 4: Configure

Use the screens named in each item. (If you must use SQL, Appendix B has a block for each; a number left as `__DECIDE__` makes the statement fail on purpose, but the text fields have no such protection, so read each block before you run it.)

1. **Invoice details and timing:** Invoices tab, invoice settings. Without who the invoice is from and how to pay, activation is blocked.
2. **Create the plans** (Plans tab, *New plan*), **publish their terms** (*New version*; the first version is the plan's opening terms), then **switch them on** (*Availability*). A plan cannot be switched on before it has a published version. Terms are never edited afterwards: a price change is a new version, and businesses already on the plan keep the version they are on until you move them. The two seeded example plans stay off.
3. **Start each pilot business on its plan in shadow** (Organizations tab, *Start a subscription*, billing mode *Shadow*). Start in shadow **even though the platform is not yet in shadow**: a business started this way can never be billed for real by accident.
4. **Check the result on screen:** Platform Billing, then Organizations. Each pilot should show its plan, its billing start, and "Held back (shadow)".

Starting a business grants its launch free orders once per licence number and once per owner. A second business with the same owner or licence will not receive them again.

---

## Step 5: Shadow billing, for at least 14 days

Shadow billing runs the entire engine on real deliveries and records what **would** have been charged, in a completely separate set of records. Nothing is billed, nothing is invoiced, and businesses cannot see it.

**Start it:** switch the platform to shadow (Go live tab, *Billing mode and scheduled run*, *Switch to shadow*). *Run billing now* runs the same job immediately if you want to see a result before the next 15-minute run. The billing job runs every 15 minutes by itself.

**Every working day, for 14 days:**

1. Platform Billing, then **Reconciliation**. It must say "Everything agrees". Any finding: stop, screenshot it, and tell me. Do not go live with an open finding.
2. Platform Billing, then **Overview**, with the **Shadow (estimated)** switch on. Note estimated revenue, free orders used, and fee-eligible sales.
3. **Go live** tab: the "last scheduled run" must be recent.

**Check three orders by hand (do this at least twice during the 14 days).** Open Organizations, then a pilot, then an order that was billed. Work it out yourself:

- *Billable value* = the order's total after discounts and accepted shortages, **minus the delivery fee**.
- *Fee* = billable value times the fee percentage, then raised to the per-order minimum or lowered to the per-order maximum if you set them, rounded to two decimals.
- *Free orders:* a launch free order is used first, then a monthly free order. A free order has no fee.
- *Cap:* once the month's fees reach the cap, further orders show a "cap adjustment" and are charged zero.

Your number must match the system's to the pesewa. If it does not, stop and tell me.

**Test a few awkward cases on purpose** (use real deliveries that happen anyway): an order with a delivery credit after delivery; a return resolved as a refund. In shadow the system should create an *adjustment* for the change, never another free order, and never a credit bigger than the fee charged (that is exactly what the audit fix repaired).

**Gate to move on (all must be true):**

- At least 14 days of shadow data, with real orders from every pilot business.
- Reconciliation clean on each of the last 7 days.
- Your hand checks matched.
- The estimated revenue is roughly what you expected. If it is far off, change the plan terms now (publish a new version) rather than after launch.
- You are comfortable with what a typical pilot would be invoiced.

---

## Step 6: Before activation (a day or two ahead)

- Tell each pilot business when billing will start and what it will cost, using their own plan terms.
- Confirm Paystack commission is still 0 (the system now refuses activation otherwise).
- Decide who records payments and how they will tell you a payment was made (bank statement, MoMo message). Keep the reference: the system refuses the same reference twice for the same method.
- Run the Appendix A status query again.
- Read the **Go live** tab, card **"Before real billing is switched on"**: the readiness checklist has six blocking ("must") items, plus some advice. The six must all show green:
  1. at least one subscription exists;
  2. reconciliation finds nothing critical;
  3. the billing job has run in the last 2 hours;
  4. invoice details are filled in;
  5. a plan is switched on and has a published version;
  6. Paystack platform commission is zero.

---

## Step 7: Activate the platform, with every business held back

On the **Go live** tab, find the card **"Before real billing is switched on"**. When every "must" item is green:

- Keep **"Hold every business back in shadow (recommended)"** ticked. (If you untick it, every subscribed business goes live at that moment. Do not.)
- Type the exact phrase `ACTIVATE BILLING` and give a reason.
- Press **Switch real billing on**. The button stays disabled until the checklist is green, the phrase is exact and a reason is given.

What happens: the platform mode becomes **active**; the moment is recorded once as the start of real billing; every business stays in shadow, so **nobody is billed**. What it unlocks: you can now put a business live.

You cannot go back to shadow once any business is live, but you can always switch the platform **off** (see "If something goes wrong").

---

## Step 8: Put the pilot businesses live, one at a time

On the **Go live** tab, the table of businesses has a **Go live** button on each row (the business's own page under Organizations has "Put this business live"). Use it for the first pilot, with the go-live moment **now** (or a date up to 90 days ahead), and give a reason.

What it does, so there are no surprises:

- The business's first real billing period starts at that moment. **Nothing before it is ever charged**, even by catch-up.
- Its free trial **restarts** from go-live (a longer extension you gave earlier is kept).
- Its launch free orders are untouched. Shadow used its own counters.
- Its shadow history is kept, unchanged, for comparison.
- It now sees its real billing on its own Billing page, and starts receiving in-app notices.

**Go live with one business first. Wait a day. Then the next.**

**After each go-live, check within the hour:**

1. The business's page says live, with the right plan and go-live date.
2. Have them (or you, acting as they) open the Billing tab: the plan, trial end, free orders left.
3. Reconciliation: clean.
4. The first real delivery after go-live produces a **real** assessment (free, or a fee), and the first-day figures agree with your hand calculation.

**Expect no money for a while.** With a 30-day trial the first period is free of the subscription. The first invoice is issued about a day after the first billing month ends. Fees appear on it only if there were chargeable orders beyond the free ones. So the first real money arrives roughly **a month after go-live, and a subscription charge about two months in**. Plan your patience and your pilot businesses' expectations around that.

---

## Step 9: The first invoice and first payment (do not skip)

This is the part of the system that has only ever been tested with test data, so treat the first real one as a test.

1. When the first invoice is issued (Invoices tab), open it. Check the lines add up, the issuer and "how to pay" are right, and the due date is what you decided.
2. The business should see it on its Billing page and receive an "invoice ready" notice.
3. When they pay, **record the payment** against the invoice (amount, method, their reference, the date received, and a reason). The invoice should flip to paid; the business should see it and get a "payment received" notice.
4. If you record something wrong, **reverse** it (never delete) and record it again with a new reference.
5. Reconciliation again: clean.

Only widen once this has worked end to end for at least two pilot businesses.

---

## Step 10: Widening, and the weekly routine

**Widen in batches** (for example 5, then 10, then everyone) using **Go live** per business, or start new businesses directly on a plan once real billing is running: a new subscription that follows the platform is live from its start and cannot start in the past.

**Every day** (2 minutes): Go live tab (last scheduled run recent, nothing stuck), Reconciliation clean.

**Every week:**

- Collections on the Overview: invoiced, collected, outstanding, and what is overdue.
- Anything overdue: contact the business yourself. The system moves an account to **past due** after the due date, **suspended** after the grace period (7 days), and restores it when nothing is overdue. At launch this only produces warnings. The option to refuse **new** orders from or to a suspended business exists and is **off**; turn it on only after you have seen the warnings working for a few weeks.
- Disputes: see "Fixing mistakes".
- Look at the audit log for the billing actions taken.

**Each month:** compare the invoiced total with the Overview's accrued revenue for the real period. They should agree.

---

## Fixing mistakes (all from the business's page, each needs a reason, nothing is ever edited or deleted)

| Problem | What to do |
|---|---|
| A fee was wrong for one order | **Waive the order's fee** (credits what was charged, never more) |
| An invoice is wrong | **Give a credit** or **add a charge** on the current bill. An issued invoice is never edited; a credit larger than the bill carries forward to the next invoice |
| A payment was recorded wrongly | **Reverse the payment**, then record it again |
| A business needs more time | **Extend the trial**, **grant free orders**, **extend the grace period** |
| A promotion or special price | **Apply a promotion**, **temporary change**, **custom pricing** |
| A business should not pay per-order fees | **Exempt from fees** (its orders are recorded as exempt and use no free order) |
| A business is leaving | **Pause**, or **end the subscription at the end of the period** |
| A business was put live too early | You cannot send it back to shadow. **Pause** it and credit what it was charged |

---

## If something goes wrong

**Stop new charges immediately:** switch the platform to **off** (Go live tab, *Switch billing off*). The engine then writes nothing new.

Be aware of two things:

- Orders delivered while billing is off are **not forgiven**. When you switch it on again through the checklist, orders delivered since each business's go-live moment are assessed (oldest first). If you want to forgive that gap, waive or credit it afterwards.
- Invoices already issued stay issued. Payments already recorded stay recorded.

**If a business reports a wrong charge:** do not argue from memory. Open its page, look at the assessment for that order (it records exactly which terms, free order and cap were used), and use the table above.

**If Reconciliation reports a finding:** stop going live with anyone else, screenshot it, and tell me. Findings are reported, never auto-fixed, because a wrong "fix" to money is worse than a visible finding.

---

## What billing does not do yet (so nobody is surprised)

- **No email or SMS.** Notices appear only in the in-app notification bell, and only for live businesses.
- **A business cannot pay or report a payment inside DrugXOne.** You record payments by hand.
- **No tax is calculated.** The invoice has a free-text tax note.
- **A pharmacy has a subscription but no per-order fee.** Only wholesalers are charged per delivered order.
- **Plan features are not wired up.** A plan's user and branch limits and feature switches exist as data but do not restrict anything yet.
- **The "refuse new orders" restriction is built but off.**
- **Pay Now (Paystack) money is separate from billing.** Platform commission on Pay Now stays 0.

---

## Appendix A: Status check (read-only; safe to run any time)

```sql
SELECT
 (SELECT mode FROM public.billing_settings WHERE id) AS billing_mode,
 (SELECT live_since IS NOT NULL FROM public.billing_settings WHERE id) AS real_billing_ever_started,
 (SELECT enforcement FROM public.billing_settings WHERE id) AS order_restriction,
 (SELECT grace_days FROM public.billing_settings WHERE id) AS grace_days,
 (SELECT count(*) FROM public.billing_subscriptions) AS subscriptions,
 (SELECT count(*) FROM public.billing_subscriptions WHERE activated_at IS NOT NULL) AS businesses_live,
 (SELECT count(*) FROM public.billing_plans WHERE active) AS plans_switched_on,
 (SELECT count(*) FROM public.billing_plan_versions WHERE status = 'published') AS published_plan_versions,
 (SELECT COALESCE(issuer ->> 'name', '') <> '' AND COALESCE(issuer ->> 'payment_instructions', '') <> '' FROM public.billing_settings WHERE id) AS invoice_details_set,
 (SELECT last_run_at FROM public.billing_run_status WHERE id) AS scheduler_last_run,
 (SELECT platform_fee_bps FROM public.payments_settings WHERE id) AS paystack_commission_bps,
 (SELECT count(*) FROM pg_trigger WHERE tgname IN ('billing_revenue_policy_lock', 'billing_revenue_policy_guard')) AS audit_fix_applied_triggers;
```

## Appendix B: Administrator operations in SQL (fallback)

Every operation here has a screen (see "Where each step is done"). Use this appendix only if a screen is unavailable.

**How to use.** These run in the production SQL Editor. Each block does two things: it makes the database treat you as the platform administrator you are (the functions refuse anyone else), and it calls one operation, which needs a written reason (at least 5 characters) and writes an audit entry. Run **one block at a time**, read the result, then go on.

First, find your administrator id (read-only):

```sql
SELECT u.id, u.email
FROM auth.users u JOIN public.user_roles r ON r.user_id = u.id
WHERE r.role = 'admin';
```

Every block below starts with the same three lines. Replace `YOUR_ADMIN_ID` with your id (keep the quotes).

```sql
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'YOUR_ADMIN_ID', true);
SELECT set_config('request.jwt.claims', json_build_object('sub', 'YOUR_ADMIN_ID', 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
-- the operation goes here
COMMIT;
```

If the operation fails, the whole block is rolled back and nothing changes. Without a valid administrator id the operations are refused ("Only platform administrators can do this").

### B1. Invoice details and timing

```sql
-- operation:
SELECT public.admin_billing_set_invoice_settings(
  14,   -- days to pay an invoice
  24,   -- hours between a period ending and its invoice
  jsonb_build_object(
    'name', '__DECIDE__',
    'address', '__DECIDE__',
    'email', '__DECIDE__',
    'phone', '__DECIDE__',
    'payment_instructions', '__DECIDE__',
    'tax_note', ''),
  'Set the invoice issuer details before launch');
```

(Remove any line you do not want shown, for example `tax_note`. The name is required.)

### B2. Create a plan, publish its terms, switch it on

```sql
-- 1. Create (once per plan):
SELECT public.admin_billing_create_plan(
  'wholesaler_standard', 'wholesaler', 'Wholesaler Standard',
  'The standard plan for wholesalers', 'standard', 'Create the launch wholesaler plan');
```

```sql
-- 2. Publish the terms. A key left out means "none / zero". Money is in GHS.
SELECT public.admin_billing_publish_plan_version(
  (SELECT id FROM public.billing_plans WHERE code = 'wholesaler_standard'),
  jsonb_build_object(
    'subscription_amount', '__DECIDE__',
    'free_trial_days', '__DECIDE__',
    'onboarding_free_orders', '__DECIDE__',
    'monthly_free_orders', '__DECIDE__',
    'transaction_fee_percentage', '__DECIDE__',
    'transaction_fee_cycle_cap', '__DECIDE__'
    -- optional: 'transaction_fee_min', 'transaction_fee_max', 'min_billable_order_amount'
  ),
  'Launch terms for the wholesaler plan');
```

```sql
-- 3. Switch it on (second true/false: whether businesses can see it; use false for now):
SELECT public.admin_billing_set_plan_availability(
  (SELECT id FROM public.billing_plans WHERE code = 'wholesaler_standard'),
  true, false, 'Make the launch plan available');
```

Repeat with `'pharmacy_standard'` and `'pharmacy'` for the pharmacy plan (a pharmacy plan only has a subscription amount and trial; it has no per-order fee).

### B3. Start a pilot business on a plan, in shadow

```sql
SELECT public.admin_billing_start_subscription(
  (SELECT id FROM public.businesses WHERE name = '__BUSINESS NAME__'),  -- check it returns exactly one business first
  'wholesaler_standard',
  now(),
  'shadow',
  'Pilot business, shadow only until go-live');
```

(Only an **approved** business can be started, and a business can only have one subscription.)

### B4. Switch the platform to shadow (Step 5) or off (emergency)

```sql
SELECT public.admin_billing_set_mode('shadow', 'Start measuring what billing would charge');
-- to stop all new charges:
-- SELECT public.admin_billing_set_mode('disabled', 'Pause billing while we investigate');
```

(You cannot switch directly to `active`: that is the Go live tab's checklist, Step 7.)

### B5. Run the billing job now (instead of waiting up to 15 minutes)

```sql
SELECT public.admin_billing_run_now('Run billing now to check the result');
```

---

## Appendix C: The files this runbook relies on

| File | What it is |
|---|---|
| `docs/platform-billing.md` | The full design: rules, tables, phases 1 to 6 |
| `docs/platform-billing-review-2026-10-13.md` | The audit that found the three defects, and the fix |
| `supabase/migrations/20261207100000_platform_billing_audit_fixes.sql` | The fix (Step 2) |
| `docs/billing/verify-billing-p1.sql` … `p6.sql` | Read-only checks that each phase is in production |
| `docs/billing/verify-billing-audit-fixes.sql` | Read-only check of the audit fix |
