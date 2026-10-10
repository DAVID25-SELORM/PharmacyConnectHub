# Order amendments: review pack

For: whoever reviews, operates or has to switch off the order-amendment features. The design is in
[`../order-amendments-and-partial-fulfilment.md`](../order-amendments-and-partial-fulfilment.md) (sections 1 to 21); this pack is the
short, practical companion: what exists, in what order it was applied, how to check it, how to stop it, and what is still open.

## 1. What was built

| Phase | What a user can do | Commit | Migrations (file names sort in apply order) |
|---|---|---|---|
| 1 Foundation | See an activity timeline on every order; fix an order line's purchase classification under production's line guard | `09c390d` | `20261028100000_order_amendments_foundation`, `20261029100000_order_item_classification_update` |
| 2 Partial fulfilment | Wholesaler proposes to supply less; pharmacy accepts (cancel the rest), rejects or asks a question | `14a721a` | `20261030100000_..._schema`, `20261030110000_..._patches`, `20261030120000_..._partial_fulfilment` |
| 6 Readers | Every report, list, statement, receipt and document shows an amended order's real total and quantities | `c0b7c3a` | `20261101100000_effective_total_readers` |
| 3 Back-orders | "Accept and back-order the rest" on a credit order; the rest ships in numbered shipments, each invoiced at dispatch | `ae0ad81` | `20261102100000_..._schema`, `20261102110000_..._patches`, `20261102120000_..._workflow` |
| 5 Delivery check | Pharmacy reports missing / damaged / rejected goods; wholesaler credits, takes back or rejects each problem | `fac6406` | `20261103100000_..._schema`, `20261103110000_..._patches`, `20261103120000_..._workflow` |
| 4 Price changes | Wholesaler proposes new unit prices before dispatch; pharmacy approves, rejects or asks | `2418f10` | `20261104100000_..._schema`, `20261104110000_..._patches`, `20261104120000_..._workflow` |
| 7 Screens | Notifications open the order; wording covers every kind of change; a background session refresh no longer wipes an open dialog | `6b86890` | none (screens only) |
| 3b Cash back-orders | Back-orders on cash (pay on delivery) orders; each portion collected and receipted separately | `6f98301` | `20261105100000_..._schema`, `20261105110000_..._patches`, `20261105120000_..._workflow` |
| 8 Review pack | This pack, the verification query, the switches | (this commit) | none |

Phase numbers are the design's, not the apply order. **Apply order is the order of the file names**: 1, 2, 6, 3, 5, 4, 3b.

## 2. Decisions the design rests on

The twelve decisions D1 to D12 (design doc, section 8) were confirmed as proposed. The ones that shape behaviour:

- The order and its lines are **never edited**. An amendment lives beside them; `orders.effective_total_ghs` (NULL = never amended) and
  `order_item_effective_price()` / `order_item_supplied_qty()` give the figures now in force.
- **Nothing happens without the other side**: a supply change or price change applies only when the pharmacy explicitly accepts; a
  delivery problem moves no stock and no money until the wholesaler's owner or manager decides it.
- **One open proposal per order**, no dispatch while one is open, no auto-expiry (one reminder after 24 h).
- **Money**: credit orders post one credit note or debit note per amendment (a unique index refuses a second); cash orders carry the
  effective total, no ledger. An increase on a credit order is checked against the credit line under its lock, with the one-time override.
- **Stock**: a shortage is released or written off, per line, by the wholesaler's choice; stock for a back-order is deducted once, at dispatch.
- Decisions made later, with you: back-orders first on credit orders only, then on cash orders with **each shipment paid and receipted
  separately** and the pharmacy able to cancel what is waiting at any time before it is dispatched.

## 3. Rollout state and how to check it

All phases above are applied to the production project. Phases 5, 4 and 3b were confirmed with the read-only checks you ran; Phases 2, 6
and 3 were confirmed during their own rollout. **One query now checks all of them at once:**

- [`verify-all-phases.sql`](verify-all-phases.sql): read-only; 136 checks (tables, columns, functions, triggers, indexes and fragments of
  patched function definitions); returns one row per phase with `checks`, `passed` and a `missing` list. Every row should show
  `passed = checks` and an empty `missing`. **Run it once on production and keep the result with this pack.** Check the project name
  (PharmacyConnectHub, `ywpntuioeqpreouauuir`) and the PRODUCTION badge first: an earlier check was run on the wrong project and returned all
  zeros.
- Every patch migration is fail-closed (it rebuilds the live function definition, must match an exact expected number of times, otherwise
  stops without changing anything) and safe to re-run (a second run reports "already patched"). Re-applying a migration is therefore harmless.

## 4. Switching things off (rollback)

**Principle.** These features hold financial and stock history in append-only tables, and every in-place change to an existing function
returns exactly what it returned before for an order that was never amended. So the safe rollback is **stop new work, let work in progress
finish, delete nothing**. Dropping the tables, or reverting the patched readers, would destroy history or make reports wrong for orders
that have already been amended; no script here does either, deliberately.

The scripts are in [`switches/`](switches/). Each one only changes who may *call* a function; nothing in any order, ledger entry or record
changes, and reading is untouched.

| To stop | Run | What stops | What still works |
|---|---|---|---|
| New supply-change proposals | `off-supply-changes.sql` | `propose_partial_fulfilment` | answering, questioning, withdrawing and applying open proposals |
| New price proposals | `off-price-changes.sql` | `propose_price_amendment` | answering, questioning, withdrawing and applying open proposals |
| New back-order shipments | `off-backorder-shipments.sql` | `create_backorder_shipment` | packing, dispatching, delivering, cancelling prepared shipments; cancelling the remaining back-order |
| New delivery reports | `off-delivery-reports.sql` | `submit_delivery_report` | withdrawing and deciding submitted reports |
| All four | `off-all.sql` | the four above | everything in progress |
| Turn back on | `on-all.sql`, or the matching `on-*.sql` | | restores exactly the previous access |

- **Why only "new work".** An open proposal blocks dispatch, and a delivered cash shipment waits for its cash to be confirmed. Revoking the
  answering or collecting functions would strand those orders, so they are never switched off.
- **Cash collection has no switch** for the same reason. To stop *new* cash back-orders, switch off supply changes (the pharmacy can then
  no longer be offered one) and back-order shipments.
- **What users see.** The button remains; using it shows "This action is switched off for now" (one shared message for all four panels).
- [`switches/open-items.sql`](switches/open-items.sql): read-only; counts what is still in progress (open proposals, submitted reports,
  waiting back-orders, undelivered shipments, uncollected cash). Run it before and after a switch.
- [`switches/emergency-guards.sql`](switches/emergency-guards.sql): every line commented out. Disabling a guard trigger is a last resort,
  documented per guard, and `trg_protect_effective_total` must never be disabled to work around a screen.
- **Undoing the screens** is a normal code revert of the relevant commit(s) and a Vercel redeploy; the database objects stay (they are
  harmless without the screens). Reverting a phase's screens while its migrations remain applied is supported; the reverse is not (do not
  revert a migration's code while its tables hold data).
- The switches are tested against the local stack ([`tests/local-supabase/amendment-switches.sh`](../../tests/local-supabase/amendment-switches.sh),
  14 checks): off refuses exactly the right functions and keeps the 12 "finish" functions callable; each single switch touches only its own
  function; on restores everything; the service role keeps access.

## 5. What was tested, and what was not

**Local database (the production-like local stack with production's order-line guard and stock fixtures installed):**

| Suite | Checks |
|---|---|
| `order-amendments-foundation.sql`, `production-stock-test.sql` | 50, 16 |
| `order-partial-fulfilment.sql` (+ concurrency) | 162 (+13) |
| `order-effective-total-readers.sql` | 57 |
| `order-backorders.sql` (+ concurrency) | 128 (+14) |
| `delivery-reconciliation.sql` (+ concurrency) | 104 (+11) |
| `price-amendments.sql` (+ concurrency) | 123 (+13) |
| `cash-backorders.sql` (+ concurrency, + real receipt handlers) | 69 (+11, +18) |
| `amendment-switches.sh` | 14 |

- Every concurrency script runs real overlapping database sessions; each has a **negative control** (removing a lock makes a named
  scenario fail), and each suite was **mutation-checked** (a deliberately broken function makes named checks fail).
- The unit-test suite and `tsc` / build run clean (the unit count is in the commit history of each phase; 444 at the time of writing).
- **Browser**, built-in browser against the local stack: both sides of every flow (propose, ask, reply, accept, reject, withdraw, ship,
  report, decide), the role matrix (section 20 of the design doc), phone width for the wholesaler's dialogs and every panel at rest.
- **Regression**: the full local sweep after every phase. The same **12 older suites fail on every run** because their fixtures edit orders
  and order lines in ways production's guard refuses (they fail identically without any amendment code); with the guards switched off, 11
  of them pass. The twelfth, `batches-expiry.sql`, still fails one check ("audit log covers receive, allocate and write-off") with a
  legacy-order stock-deduction error; it failed the same way when first observed in the Phase 5 run and nothing in these phases touches
  batches, but **it was not proven to predate Phase 1**, so treat it as an open question (section 6).

**Not tested, or tested only partly:**
- The pharmacy's dialogs at phone width (the measuring script could not read a hidden browser pane reliably); the scroll-to-order after a
  notification link (opening was verified, scrolling was not observable).
- The cash-collection and receipt buttons in the browser (the receipt endpoints only run on Vercel; the real handlers were run against the
  local stack with a stubbed email provider instead).
- Production-only objects that are not in the repository could not be read at build time: `get_order_print` (still prints placed prices,
  patched only for total and quantities), `order_stock_deductions`, `inventory_operation_context`. Each patch that touches a production-only
  definition is fail-closed.
- Real email delivery of per-portion receipts.

## 6. Known limitations and open items

1. **`batches-expiry.sql`** (see above): find out whether it fails on a checkout of the commit before Phase 1. If it does, record it as
   pre-existing; if it does not, it is a regression to fix.
2. **No refunds.** A paid cash order cannot be amended, a collected cash portion cannot be credited, and prepaid (Paystack) orders cannot be
   amended at all. This is refused with a clear message; it is not a silent gap.
3. **Order-level payment reports** count a partly collected order as unpaid until it is fully collected (as partly paid credit orders
   already are).
4. **Returns** that were resolved before Phase 5 are not back-filled into the credit ledger; a returned item does not reduce an order's
   effective total (only a credit does); the return restock movement is still tagged `admin_adjustment`.
5. **Prices**: the delivery fee and quantities cannot change in a price proposal; no price change after dispatch; the price of back-ordered
   units cannot change once the first dispatch has happened; a pharmacy approves or rejects a whole price proposal, not line by line.
6. **Receipts** for a portion list what that portion supplied; a credit applied later lowers the total but not the lines.
7. **Back-order batch allocation**: stock is deducted for a back-order shipment but batch numbers are not recorded on it.
8. **Due dates**: per-shipment due dates are not tracked in the credit registers (they still age per order); no reminders for delivery
   reports nobody has decided, or for delivered shipments whose cash is unpaid.
9. **Screens**: the section heading is still "Supply changes" although it also holds price changes and the back-order panel; the database
   message that blocks dispatch still says "supply change" for a price proposal.
10. **Platform**: the notification link now carries `&order=<id>`; notifications created before it keep the old behaviour. The pages no
    longer show a full "Loading..." screen on a background session refresh (the cause was seen twice; the fix could not be triggered on
    demand to prove it).

## 7. Reviewer checklist

- **Who can do what** (design doc section 3.3 and each phase's section): proposers, responders and deciders per role; every "no" is enforced
  in the function body (`can_act_for_business`), not only by hiding a button. The role matrix in section 20 and the SQL permission checks
  in each suite are the evidence.
- **All writes go through `SECURITY DEFINER` functions** with `SET search_path = public`; the amendment tables allow no direct writes
  (RLS: admins read; the two parties read through checked functions). Check one: `order_collections`, `order_amendments`,
  `order_delivery_reports`.
- **Append-only**: lines, messages, stock movements, collections, delivery lines and decisions have update/delete triggers that raise.
- **Idempotency**: every financial or stock action has a unique marker (`request_id`, `amendment_id`, `shipment_id`, `delivery_report_id`,
  `return_id`, one collection per portion) and a replay returns the first result.
- **Lock order** (documented in each workflow migration): order row, then the proposal / shipment / report row, then the customer's credit
  terms row, then products by id, then batches. Check that no new function takes them in another order.
- **The order total guard** (`trg_protect_effective_total`): only an approved function can change `effective_total_ghs`; the wholesaler's
  staff can update their orders' rows, so this trigger is what stops them editing what a pharmacy owes.
- **Fail-closed patches**: read one patch migration's helper (`apply_function_regex_patch`) and one patch call.

## 8. Where everything is

| What | Where |
|---|---|
| Migrations | `supabase/migrations/20261028100000` to `20261105120000` |
| Verification of all phases | `docs/order-amendments/verify-all-phases.sql` |
| Switches, open-items, emergency guards | `docs/order-amendments/switches/` |
| SQL suites, concurrency scripts, API and switch checks | `tests/local-supabase/` (README entries 20 to 28) |
| Screens | `src/components/orders/` (`SupplyChangePanel`, `PriceChangeSection`, `BackorderPanel`, `DeliveryCheckPanel`, `OrderActivityTimeline`), `src/routes/pharmacy.tsx`, `src/routes/wholesaler.tsx` |
| Libraries | `src/lib/order-amendments.ts`, `price-amendment.ts`, `order-backorder.ts`, `delivery-report.ts`, `order-supply.ts`, `amendment-errors.ts` |
| Receipt endpoints | `api/orders/confirm-payment.ts`, `api/orders/send-receipt.ts`, `api/_cash-portions.ts` |
