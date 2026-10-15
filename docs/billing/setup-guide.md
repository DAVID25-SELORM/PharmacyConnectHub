# Billing Setup: a guide for the platform administrator

Open **Admin, then Billing, then Setup**. It is the first tab. Everything you need to launch billing is on that one page, in four stages. Nothing on it charges anyone until the last stage, and the last stage stays locked until the first three are complete.

## The page at the top

A single summary tells you where you stand: how much is ready (as a percentage), **what prevents activation** in plain words, and the four stages as tiles marked *Complete*, *In progress*, *Needs attention* or *Pending*. Click a tile to jump to that stage. Billing stays off until every required item is done.

## Stage 1: Configure Billing

One form for **wholesalers** (and a second, folded away, for **pharmacies**, needed only if pharmacies will be billed). Fill in:

| Box | Meaning |
|---|---|
| Subscription per billing period | What the business pays each period. 0 means no subscription charge. |
| Billing period (months) | Usually 1. |
| Free trial (days) | Free time at the start. |
| Launch free orders / Free orders each period | Orders that are not charged a fee. |
| Platform fee (%) | Charged to the wholesaler on each delivered order after free orders. |
| Smallest / largest fee per order | Optional limits on one order's fee. Empty means none. |
| Most in fees per period | The monthly cap. Empty means none. |

Write a reason and press **Save pricing**. The page tells you what it will do before you press it ("publish version 2, replacing version 1"). A price change is always a **new version**; businesses already on the plan keep the version they are on until you move them (Organizations, open the business, *Change the plan*). The plan's other settings (its feature entitlements) are carried over automatically.

If saving stops part-way (for example a network failure), the message says which step failed and what was already done. Press **Save pricing** again: it carries on from where it stopped and never creates a second plan.

Paystack's platform commission must also be zero (set under Payments), so a business is never charged twice.

## Stage 2: Set Up Invoices

Who invoices are from (name, address, contact) and **how to pay**. Both the name and the payment instructions are required. Days to pay and the delay before an invoice is issued are here too.

## Stage 3: Run 14-Day Shadow Test

1. **Start the shadow test.** Billing then records what each business *would* be charged. Nobody is charged, and businesses cannot see it.
2. **Add a business to the test** (pilot wholesalers, and a pharmacy if you will bill them). Each starts in shadow.
3. Wait. The page shows *Day N of 14*, how many orders have been assessed, and what the figures would have been. **Run billing now** runs the same job as the 15-minute schedule, immediately.

**You do not calculate anything by hand.** Two automatic checks run every time the page opens, and again when you press *Run the checks again*:

- **Consistency checks.** Every total, count, invoice and payment is compared with the records it is built from.
- **Recalculation.** Every shadow fee is worked out again from the order value and the plan terms, separately from the billing engine. If one differs, the page lists the order, the business, the recorded fee, the recalculated fee and the difference.

A difference stops activation and changes nothing: it is shown so that you can look into it. (An order whose value changed and has not been adjusted yet is shown as *advice*; the next billing run adjusts it.)

The test counts as successful only when: the schedule has been running, real orders have been assessed (a quiet fortnight proves nothing), 14 days have passed, and both automatic checks agree.

*What billing calculated for each business* shows the estimated fees and subscription per business, so you can read the result directly.

## Stage 4: Activate Pilot Businesses

Locked until stages 1 to 3 are complete. Then:

1. **Switch real billing on.** You type `ACTIVATE BILLING` and give a reason. **Every business starts held back in shadow**, and this page cannot change that. Nobody is charged yet.
2. **Put the pilot businesses live one at a time** (choose a date up to 90 days ahead or leave it empty for now). A business's first real bill starts at that moment, its free trial restarts, and no earlier order is ever charged.
3. Widen the rollout only after the pilot's first invoices and payments look right (Invoices tab and Reconciliation).

## If something looks wrong

- **Stop new charges:** Go live tab, *Switch billing off*. Nothing already billed is changed.
- A check that **cannot run** counts as not agreeing, so a broken check never lets billing through by silence.
- Every action here needs a reason and is recorded in the audit log.

## What this page does not do

It does not change any billing rule, charge anyone or take any payment. It uses the same audited operations as the other tabs. The other tabs (Organizations, Invoices, Plans, Promotions, Go live, Reconciliation) remain for detailed work.
