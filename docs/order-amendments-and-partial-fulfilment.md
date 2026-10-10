# Item 4: Order amendments, partial fulfilment, back-orders and delivery reconciliation

Status: **Phase 0 (read-only production review) complete; decisions D1-D12 confirmed as proposed. Phase 1 in progress locally. Nothing has been applied to production.**
Written from a read-only review of the repository, its migrations and the local database (which has all repository migrations and the reconstructed production order guard, but NOT production-only objects; see section 9 and Phase 0).

Terms: "ordered" = what the pharmacy placed; "supplied" = what the wholesaler confirms it will send on this order; "dispatched" = physically sent; "received" = what the pharmacy reports receiving; "outstanding / back-ordered" = ordered, not cancelled, not yet sent.

---

## 1. What exists today (findings)

### 1.1 Order lifecycle and the legacy guard
- `orders.status`: `pending > accepted > picking > packed > ready_for_dispatch > dispatched > delivered`, plus `cancelled`.
- Production has a **legacy trigger `aa_phase0_order_integrity`** (`phase0_order_integrity()`). It makes these columns **immutable after insert: `id, pharmacy_id, wholesaler_id, order_number, total_ghs, payment_method, created_at`**, and it **only allows the existing status transitions** (no transition out of `delivered` or `cancelled`). The repository only patches its transition list.
- A second trigger (`handle_order_status_change`) stamps `*_at` columns and writes `order_status_history(from_status, to_status, changed_by, note)`.
- `enforce_wholesaler_staff_order_scope` restricts what warehouse and finance roles may change on an order row.
- **Consequence:** an amendment cannot change `orders.total_ghs`, cannot add a new `orders.status` value, and cannot move a `delivered` order back. The design must live beside the order, not inside those fields.

### 1.2 Inventory model (two independent counters, no reserved column)
- `products.stock` is **deducted in full at checkout** (inside `create_marketplace_orders`, under `FOR UPDATE` on the product rows). There is **no separate "reserved" quantity**: stock that is promised to an open order is simply already gone from `products.stock`.
- On cancellation, `restore_stock_for_cancelled_order()` adds back **the full `order_items.quantity` unconditionally**, with no check that the stock was ever deducted. (A returned `resolve_order_return` also adds accepted restockable units back to `products.stock`.)
- Batches are a second, physical layer: `confirm_order_picks()` (FEFO) decrements `product_batches.quantity_on_hand`, writes `order_batch_allocations` and `batch_movements('allocated')`. `_release_order_batches()` reverses it on cancel and when picks are re-confirmed. It is capped (`LEAST(.., quantity_received)`), so it is naturally idempotent.
- Dispatch itself moves no stock. So "partial dispatch deducts only what is dispatched" cannot be literal under the current model: the deduction already happened, in full, at checkout. A partial dispatch therefore means **returning (or deliberately keeping deducted) the quantity that is not dispatched**.
- **Production-only objects** (referenced by the repository but not defined in it): `order_stock_deductions` (per-order evidence of the checkout deduction), `inventory_operation_context(transaction_id, actor_id, movement_type, order_id)`, `server_audit_context`. The compatibility migration shows checkout writes a context row (`movement_type = 'checkout_deduction'`) around its stock update, which strongly suggests a production trigger rejects stock changes made without a context row. A production cancellation guard consumes the evidence rows. **Their definitions are unknown to me and must be reviewed before any stock-changing code is written (Phase 0).**

### 1.3 Pricing model
- `order_items.unit_price_ghs` is the **net price charged per unit** (after discounts). `base_unit_price_ghs` is the list price; `discount_amount_ghs`/`discount_source` record the discount. `orders.subtotal_ghs`, `discount_amount_ghs`, `delivery_fee_ghs` and `total_ghs` are stored.
- Some of those figures depend on **order size**: quantity-tier product discounts (`min_quantity`), customer discounts with `minimum_order_value`, fixed-amount customer discounts spread across lines, `wholesaler_order_terms` minimum order value, delivery fee and free-delivery threshold.
- **There is no tax or VAT concept anywhere in the data model.** "Recalculate applicable taxes" has nothing to act on today; amendments must not invent one.

### 1.4 Finance model
- For a **credit order**, checkout writes one ledger `invoice` debit (`goods + fee`) per order, **at placement, before the wholesaler has accepted anything**. So "an invoice that has not yet been issued" never exists for credit orders; the invoice is always already issued. Cash/COD orders have **no ledger entries**; they are settled by "Confirm payment" against `orders.total_ghs`.
- The ledger is append-only. Cancellation posts one `credit_note` guarded by a unique marker (`cancellation_order_id`). Exposure = ledger debits minus credits (`credit_exposure`). Payments are allocated per invoice.
- `credit_invoice_status()` sums `invoice` entries as the invoice total and treats **every credit as "paid"** (`paid = invoice - outstanding`). An amendment credit note would therefore make an invoice look "partially paid". This function feeds the registers, dashboards, reminders and statements.
- Credit orders have a due date (order-date or delivery-date based). A second, later `invoice` entry on the same order is already compatible with the status function (it sums them).

### 1.5 Who reads order totals and lines (blast radius)
- About **27 database functions** read `orders.total_ghs` (reports, statements, dashboard/accounting overview, order history, receipts, notifications, RFQ award) and about **22** read `order_items` quantities/prices. About **20 screens/API routes** read `total_ghs` (including `api/orders/confirm-payment.ts` and `send-receipt.ts`).
- Anything that keeps reading the original total will **overstate** an amended order's revenue, spend, statement, receipt and cash-to-collect.

### 1.6 Returns, delivery and timeline
- A **returns workflow already exists** (`order_returns`, `order_return_items`: request, wholesaler review, mark returned, inspection with per-line accepted quantity and restock flag, resolve as refund/credit/replacement/none). It restocks `products.stock` but **never posts a ledger credit note**, so on a credit order a resolved credit return does not reduce the invoice balance. (Pre-existing gap; see decision D9.)
- `order_deliveries` holds courier details and who received it. There is **no per-line receipt**.
- The "timeline" is a **fixed row of badges built from timestamp columns** (`OrderTimeline`), not an event log. `order_status_history` records status changes only.

### 1.7 Cross-cutting building blocks I can reuse
- Server-side permission helpers (`can_act_for_business`, `can_view_accounting`), `write_audit_log` (business-scoped audit centre with category/label maps), `notify_business` plus notification groups, the idempotent checkout pattern (`marketplace_checkout_requests` with a request id), `FOR UPDATE` lock ordering conventions, the append-only ledger with unique markers, and the in-place patch-with-fail-closed migration pattern.
- Test tooling: Vitest (unit), plain-SQL suites in `tests/local-supabase` run against a local Supabase, an optional production-guard fixture, and browser verification. There is no committed Playwright suite (an ad-hoc script exists).

---

## 2. Design constraints this drives

| # | Constraint | Source |
|---|---|---|
| C1 | `orders.total_ghs` and the lifecycle statuses cannot change; originals stay as placed | legacy guard; also your "preserve the original" rule |
| C2 | Back-order shipments after `delivered` need their own status machine; the parent order cannot be re-opened | guard has no exit from `delivered` |
| C3 | Any stock write must satisfy production's context/evidence mechanism | `order_stock_deductions`, `inventory_operation_context` |
| C4 | The ledger stays append-only; reductions are credit notes, increases are debit documents, each with a unique idempotency marker | credit ledger design |
| C5 | Amended orders must surface correctly in every total reader, not just the new screens | 27 functions, 20 screens |
| C6 | Finance-only access to credit data must be preserved | the readers locked down in item 1 |
| C7 | Existing orders and flows must behave identically when no amendment exists | your rule 4 |

---

## 3. Proposed architecture: an amendment layer beside an immutable order

Everything below is **additive**. Orders without an amendment never touch any of it.

### 3.1 New tables (all append-only or state-machine tables, written only by SECURITY DEFINER functions, readable by the two parties)
1. **`order_events`**: the activity timeline. `(order_id, event_type, actor_user_id, actor_side, amendment_id?, shipment_id?, summary, details jsonb, created_at)`. Every material event writes one row in the same transaction as the change it describes. A read function merges these with `order_status_history` so the UI shows one chronological timeline.
2. **`order_amendments`**: one proposal. `(order_id, version, kind ['partial_fulfilment','price_change'], status, reason, proposed_by/at, responded_by/at, response_choice, response_note, original_total_ghs, proposed_total_ghs, delta_ghs, request_id, ...)`. Statuses: `proposed -> accepted_cancel_remaining | accepted_backorder | rejected | clarification_requested | withdrawn -> (applied)`. `UNIQUE(order_id, request_id)` makes the proposal idempotent; a partial unique index allows only **one open proposal per order**.
3. **`order_amendment_lines`**: per product line `(order_item_id, ordered_qty, supplied_qty, short_qty, stock_treatment, original_unit_price, proposed_unit_price, line_note)` with CHECKs (`supplied + short = ordered`).
4. **`order_shipments`**: shipment 1 is the order itself (existing flow, unchanged); **back-order shipments are rows `sequence >= 2`** with their own status machine (`pending -> accepted -> picking -> packed -> dispatched -> delivered`), dispatch/receipt timestamps and courier details. **`order_shipment_lines(shipment_id, order_item_id, quantity)`** records what physically went in each. A line's outstanding quantity = approved - sum(shipped), computed, never stored twice.
5. **`order_stock_movements`**: an auditable record of every stock effect an amendment causes `(order_id, amendment_id|shipment_id, order_item_id, product_id, kind ['shortage_release','shortage_write_off','backorder_hold','backorder_release','backorder_ship'], quantity, created_by)` with `UNIQUE(source_id, order_item_id, kind)` so a movement can **never be applied twice**.
6. **`order_delivery_reports`** and **`order_delivery_report_lines`**: the pharmacy's receipt per shipment `(order_item_id, ordered/expected_qty, received_qty, missing_qty, damaged_qty, rejected_qty, reason, note)`; status `submitted -> under_review -> resolved | disputed`. It is a **claim**. It moves no stock and posts no financial entry by itself.

### 3.2 New columns on existing tables (additive, defaulted)
- `orders.effective_total_ghs NUMERIC NULL` (NULL = not amended, so every consumer can use `COALESCE(effective_total_ghs, total_ghs)`). It is not in the legacy guard's immutable list.
- `credit_ledger_entries.amendment_id`, `.shipment_id` (nullable) with partial unique indexes: **one credit note per amendment, one invoice/debit per back-order shipment**, preventing duplicates by construction.
- `credit_orders`: nothing else changes; `orders.credit_due_*` rules from item 3 are reused.

### 3.3 The state machines (server-enforced; the UI only mirrors them)

**Partial fulfilment**
1. *Wholesaler proposes* (owner, manager, cashier, warehouse: anyone who can process the order; a warehouse user finds the shortage at picking). Required: shortage reason; per-line available quantity; stock treatment per line. The function recomputes totals from the **agreed net unit prices** and stores original total, proposed total and delta. Notifies the pharmacy. Order goes no further than `packed`/`ready_for_dispatch`: a trigger **blocks the `dispatched` and `delivered` transitions while a proposal is open**.
2. *Pharmacy responds* (owner, manager, cashier of the pharmacy): **accept and cancel the rest**, **accept and back-order the rest**, **reject**, or **request clarification** (with a message). Reject leaves the order exactly as placed and the wholesaler must supply in full, cancel, or re-propose.
3. *Apply* (same transaction as acceptance): set `effective_total_ghs`; post the credit note (credit orders); record stock movements; reconcile batches; open back-order lines if chosen; write events, audit entries, notifications for both sides. Re-running the same response is a no-op.

**Price amendment** (separate kind, same shape): the wholesaler proposes new unit prices with a reason; original and proposed prices are both stored and shown; **only an explicit pharmacy approval applies it**, recording requester, approver, reason and timestamps. A decrease posts a credit note, an increase a debit entry (credit orders; see D5). An issued invoice is never edited; the correction is always a separate ledger document linked by `amendment_id`.

**Back-order shipments**: a back-order line is outstanding quantity on the parent order. When the wholesaler is ready, a new shipment (sequence 2, 3, ...) is created, moves through its own statuses, and its **own dispatch** posts one ledger `invoice` debit for the shipment's value (credit orders; limit and due-date rules below) with `shipment_id` as the idempotency marker. The pharmacy can cancel the remaining back-order at any time before dispatch (a credit note is not needed: it was never billed).

**Delivery reconciliation**: after a shipment is delivered the pharmacy submits a report (fully received / partial / missing / damaged / rejected, with reasons). The wholesaler's **owner or manager verifies** it; only then may the outcome be applied: a credit note for missing goods, or a **return** (reusing the existing returns workflow, with its inspection and restock decision) for damaged/rejected goods. Nothing automatic: no stock or financial effect from the report itself.

### 3.4 Effective totals everywhere (the C5 problem)
Add one helper, `order_effective_total(order)`, and move readers to `COALESCE(effective_total_ghs, total_ghs)` in phases: first the money-critical ones (statements, accounting overview and registers, cash payment confirmation, receipts, order history and detail, the credit invoice status), then reports. Orders with no amendment return exactly what they return today, so each patch is behaviour-neutral until an amendment exists and is verified by running every existing SQL suite after each patch.

---

## 4. Financial rules (each is a stated decision; see section 8 for your confirmation)

| Rule | Behaviour |
|---|---|
| Totals | `proposed total = sum(agreed net unit price x supplied qty) + delivery fee as charged`. Unit prices never change on a quantity reduction; no re-tiering; minimum order value is not re-checked. |
| Credit order, shortage accepted | One `credit_note` for the reduction, marker `amendment_id`; exposure and limit availability recalculate from the ledger automatically. |
| Credit order, back-order | Credit note now for the whole back-ordered value; the later shipment posts its own `invoice` debit. |
| Credit limit at back-order dispatch | Re-checked under the same credit-line lock as checkout; if there is no room, dispatch is blocked until it fits or an override exists. |
| Credit order, price decrease / increase | credit note / debit entry linked to the amendment. Increase needs available credit (or override) at approval. |
| Partial payments | Credit notes apply to the order's outstanding after payments; `credit_invoice_status` is extended so an amendment credit note **reduces the invoiced amount** instead of counting as a payment, keeping "paid" and "outstanding" honest. |
| Delivery-date due dates | Unchanged. A back-order shipment's debit follows the customer's configured due-date basis from its own dispatch/delivery. |
| Cash / COD | No ledger. `effective_total_ghs` is what must be collected; payment confirmation and receipts use it. |
| Cancellation after amendment | The existing cancel credit note credits only what is still outstanding, so it cannot double-credit. |

## 5. Inventory rules

| Rule | Behaviour |
|---|---|
| Never restore what was never deducted | The restore step is rewritten to act only on recorded movements for the order and is idempotent through `order_stock_movements` uniqueness. |
| Shortage line | The wholesaler chooses per line: **release** (units exist; return to sellable stock) or **write-off** (the units do not physically exist; do not re-inflate stock). Both are recorded movements. |
| Back-ordered units | **Held** (stay deducted); they are committed to the pharmacy and are not deducted again at later shipment. |
| Batches | After an accepted reduction, picks are re-confirmed for the supplied quantities (existing `confirm_order_picks` already releases and re-allocates). |
| Concurrency | One lock order everywhere: order row, then products by id, then batches by id (matches checkout). Applying an amendment re-validates its source state under the order lock. |
| Production context | Every stock write goes through whatever context mechanism Phase 0 reveals. |

## 6. Interface

Order detail gains a clear amendment panel showing, per line, **Ordered | Proposed supply | Approved | Dispatched | Received | Outstanding**, original and proposed totals side by side with the delta spelled out ("You will pay GH₵ X less. A credit note for GH₵ X will be issued; nothing else on your account changes."), the reason, and the actions. The existing fixed timeline stays and a real **activity timeline** (from `order_events`) sits under it. Notifications use the existing centre (new types in the orders group); audit labels join the credit/orders categories.

## 7. Phased plan (each phase ends with its own regression run and a review gate; nothing is deployed until you approve)

| Phase | Deliverable | Gate |
|---|---|---|
| **0** | **Read-only production catalog review**: definitions of the stock evidence/context mechanism and cancellation guard, triggers on `orders/products/order_items/product_batches`, constraints, policies, volumes. Settle decisions D1-D12. | Written findings; decisions confirmed |
| **1** | Foundation: `order_events`, event/timeline read function, `orders.effective_total_ghs`, ledger markers, notification/audit vocabulary. Zero behaviour change. | All existing SQL + unit suites unchanged |
| **2** | Partial fulfilment proposal/response (cancel-rest path), dispatch block, credit note, stock movements, batch reconciliation, `credit_invoice_status` netting. | New SQL suite + full credit/accounting regression |
| **3** | Back-orders and shipments (own statuses, own debit documents, limit re-check). | New suite + regression |
| **4** | Price amendments (explicit approval, debit/credit documents). | New suite + regression |
| **5** | Delivery reconciliation (reports, verification, credit note or return outcome); optionally close the returns-to-ledger gap (D9). | New suite + returns regression |
| **6** | Effective-total adoption across readers (statements, overview, reports, receipts, confirm-payment). | Each patch followed by every SQL suite |
| **7** | UI (amendment panel, activity timeline, notifications, mobile layout) and browser verification of every role. | Role matrix + responsive checks |
| **8** | Review pack: rollback scripts, rollout order, production dry-run queries. | Your review |

## 8. Decisions I need confirmed (or changed) before Phase 1

| # | Decision | My default |
|---|---|---|
| D1 | Stock for shortage lines | Wholesaler picks per line: **release** or **write-off**; back-ordered units are **held** |
| D2 | Delivery fee on a partial order | Unchanged; only a price amendment can change it |
| D3 | Unit prices when quantities fall | Unchanged (no re-tiering, no minimum-order re-check) |
| D4 | Back-order billing | Credit note now; separate debit at each back-order dispatch; credit limit re-checked then |
| D5 | Price **increase** on a credit order | Needs available credit (or an override) when the pharmacy approves |
| D6 | Who may act | Propose shortage: owner, manager, cashier, warehouse. Price proposals and verification of delivery claims: owner, manager. Pharmacy responses: owner, manager, cashier |
| D7 | Open proposals | No auto-expiry; the wholesaler may withdraw; reminder notification after 24 h |
| D8 | Reports | Use `COALESCE(effective_total_ghs, total_ghs)`; amended orders still report on their original order date |
| D9 | Returns not reaching the credit ledger (existing gap) | Fix it in Phase 5 so reconciliation and returns end in the same ledger documents |
| D10 | Taxes | None exist; amendments carry none, with an extension point noted |
| D11 | When amendments are allowed | Before dispatch only; after dispatch use delivery reconciliation / returns |
| D12 | Cash/COD orders | `effective_total_ghs` is the amount to collect and on the receipt |

## 9. Risks and mitigations

| Risk | Why it matters | Mitigation |
|---|---|---|
| Production stock guards | A stock write that production rejects, or evidence that drifts | **Resolved by Phase 0 (section 13):** the mechanism is now known and reproduced in a local fixture; every stock write follows it |
| `credit_invoice_status` change | Feeds registers, dashboards, reminders, statements | Extend, do not rewrite; run all nine credit/accounting suites plus statements after the patch; netting only applies to orders with an amendment credit note |
| Patching 27 total readers | Silent revenue/statement errors | Phase 6 patch-in-place, one function at a time, fail-closed, behaviour-neutral when `effective_total_ghs` is NULL, tested before and after |
| Legacy guard | Cannot change totals or statuses | Designed around it: new column, new tables, new shipment states; the guard is not edited |
| Double application | Duplicate credit notes or stock restores | Unique markers on ledger and stock movements; state checked under the order lock; idempotent request ids |
| Overselling under concurrency | Two actions racing on stock | Single lock order; re-validate under lock; tests with two concurrent sessions (as done for credit) |
| Credit exposure drift on back-order | Debit could exceed the limit | Limit re-check at dispatch under the credit-line lock |
| Scope and size | This is the largest change so far | Eight gated phases, each independently shippable and reversible |
| Local DB lacks production-only objects | Tests could pass here and fail there | Phase 0 findings turned into a local fixture (as done for the order guard) so tests exercise the same constraints |
| Wholesaler delays leave orders stuck | An open proposal blocks dispatch | Withdraw anytime, reminders, visible age; no hidden auto-actions |

## 10. Test strategy
- **Database**: one SQL suite per phase (state machines, permissions for every role on both sides, idempotency by repeating every call, concurrency with two sessions, exact ledger and stock arithmetic, mutation checks that each guard fails when removed). The nine existing credit/accounting suites, settlement, statements, reminders and returns are re-run after every phase and must match their current counts.
- **Unit (Vitest)**: all wording, quantity arithmetic and permission helpers.
- **End to end**: scripted browser runs against the local stack per role (wholesaler warehouse/cashier/manager/finance, pharmacy owner/cashier/accountant) covering propose, respond, dispatch block, back-order shipment, delivery report, verification; plus mobile width checks.
- **Production-like**: all of the above with the legacy-guard fixture and the Phase 0 stock fixture installed.

## 11. Rollback
- Every migration is additive (new tables and nullable columns); rolling back means stopping use of the new functions and UI, not editing history. Patched functions keep their previous definitions in the repository, so each patch can be reverted by re-applying the prior function body. `effective_total_ghs` is NULL for every untouched order, so removing the amendment features leaves reports and statements exactly as before. Ledger and stock history created by amendments is never deleted; if an amendment must be undone in production it is reversed by a new, visible compensating entry.

## 12. Phase 0 production review (read-only queries to run first)
See the companion query set in the conversation; it lists the stock evidence/context/audit-context table definitions, the triggers on the order and stock tables with their functions, any function that mentions the evidence tables, constraints and policies, and order/stock volumes.

---

## 13. Phase 0 findings: production catalog review (read-only, 8 Oct 2026)

Reviewed in the PharmacyConnectHub production database. Nothing was changed.

### 13.1 What production has that the repository does not define
| Object | What it does |
|---|---|
| `order_items` trigger `phase0_item_integrity` | **Order lines are fully immutable**: only INSERT is ever allowed, and only into a *pending* order for a product of the same wholesaler. Any UPDATE or DELETE raises "Historical order items are immutable." Approved/dispatched/received quantities therefore **cannot** live on `order_items`. (Confirms the amendment-layer design.) |
| `inventory_operation_context` (PK `transaction_id`; `actor_id, movement_type, order_id, import_run_id, request_id, reason`) | One context row per transaction; read by the stock trigger. |
| `products` trigger `phase1_inventory_movement` -> `phase1_record_inventory()` | On **every change to `products.stock`** it writes a row to `inventory_movements`, taking `movement_type`, actor, `order_id`, `request_id`, `reason` from the context row for the current transaction (defaults to `admin_adjustment` / `database_maintenance` when there is none). |
| `inventory_movements` | The stock audit ledger: `quantity_delta, quantity_before, quantity_after, movement_type, source_operation, ...`. **`movement_type` is restricted by a CHECK to**: `product_created, manual_add, manual_remove, manual_reconciliation, checkout_deduction, order_cancellation_restore, import_add, import_replace, admin_adjustment`. A unique index `inventory_order_movement_once` allows only one `checkout_deduction` and one `order_cancellation_restore` per (order, product). |
| `order_stock_deductions` (PK `order_id, product_id`; `quantity`, `restored_at`) | Per-order evidence written by checkout. |
| `restore_stock_for_cancelled_order()` (production version) | **Strict**: raises if the order has **no deduction evidence** ("Legacy order has no verified stock deduction"), raises if the evidence does not match `order_items` line for line, raises if already restored, then restores the **full** deduction through the context mechanism and stamps `restored_at`. |
| `adjust_product_stock()` | Idempotent manual adjustments (`stock_adjustment_requests`), owner/manager only. |
| `server_audit_context` | Actor context used by the audit writers during idempotent checkout. |
| `release_credit_on_order_cancel()` (production version) | Credits the order's **net remaining charges** (all non-payment entries, including earlier credit notes), so an amendment credit note posted earlier cannot be credited twice on a later cancellation. (Confirms rule: cancellation after amendment is safe.) |

### 13.2 Data volumes
5 orders in total (1 pending, 1 accepted, 1 dispatched, 2 delivered), 1 credit order, no batch allocations, 310 products in stock, 6 `admin_adjustment` movements, **0 `order_stock_deductions` rows**. **All 5 existing orders are "legacy": they have no deduction evidence.** No backfill is needed and migration risk is very low.

### 13.3 Design changes this forces (additions to sections 3-5)
1. **Legacy orders (no evidence):** an amendment may change the order financially, but **no stock write is made** for it (the treatment is forced to "none" and the order shows a note "no verified stock deduction; reconcile stock manually"). This matches production's own cancel rule and your "never restore what was never deducted".
2. **Net restore on cancel:** the evidence rows keep the **original** quantities (they are compared with the immutable `order_items`). Stock released or written off by an accepted amendment is recorded in `order_stock_movements`; `restore_stock_for_cancelled_order()` is **patched in place (fail-closed)** to restore `evidence quantity - released - written off`, leaving its other checks untouched. This prevents the double restore that would otherwise happen (release at amendment, full restore at cancel).
3. **New movement type:** the amendment release writes through the existing context mechanism with a new `movement_type = 'order_amendment_release'`, so the production `inventory_movements` audit ledger records it. That requires **extending the CHECK constraint** on `inventory_movements` (additive, applied in place and fail-closed) and adding a uniqueness guard per (order, product, amendment) so a release cannot be applied twice. A **write-off or hold changes no stock**, so it produces no `inventory_movements` row; it is recorded in `order_stock_movements` and the order event log.
4. **One context row per transaction:** an amendment that touches several products must insert, use and delete the context row around each stock write (the same loop pattern production's restore uses).
5. **Local fixture:** reproduce this mechanism locally (the tables, the trigger, the strict restore function, the immutable-items guard, and re-apply the checkout compatibility patch) so every new test runs against the same constraints as production. This is part of Phase 1.

### 13.4 Phase 1 scope (unchanged in intent; clarified)
Order event log and timeline reader, `orders.effective_total_ghs`, the ledger idempotency markers, the shared helper, the production-stock fixture, and tests. **No stock, financial or lifecycle behaviour changes in Phase 1.** The `inventory_movements` constraint extension and the cancel-restore patch arrive with Phase 2, where they are first used.

## 14. Phase 1 status (built locally, not deployed)

**Delivered (nothing applied to production):**
- `20261028100000_order_amendments_foundation.sql` - `orders.effective_total_ghs` (NULL = not amended; `total_ghs` untouched), append-only `order_events`, `record_order_event()` (not callable by users), `order_timeline()` (parties, staff and admins only; the other side's staff are shown by business name), credit-ledger markers `amendment_id` / `shipment_id` with unique indexes. Re-runnable.
- `20261029100000_order_item_classification_update.sql` - **fixes an existing production defect** found while reproducing production's guards: `phase0_item_integrity` rejects every UPDATE of an order line, so "change purchase classification" can never succeed in production. The guard is patched in place (fail-closed) to allow an update only when every column except `purchase_category` is unchanged; quantities, prices and products remain immutable and deletes stay refused. This is independent of amendments and can be applied on its own.
- UI: a collapsible "Activity" panel on every order detail, for both wholesaler and pharmacy.
- Tests: `order-amendments-foundation.sql` (49 checks), `production-stock-test.sql` (16 checks, includes the classification case), unit tests for the timeline helpers.

**Regression result against a production-like database (guard + stock fixtures installed):** 33 suites pass. The suites that still need attention are fixture-level incompatibilities with production's order-line guard (they insert or update order lines after the order has left `pending`), not feature defects: credit-terms, fulfillment-status-expansion, notifications, order-deliveries, order-history-filters (known earlier) and batches-expiry, inventory-insights, order-returns, pharmacy-price-history, reorder-lists, reports. `purchase-classification-required` failed before the classification fix and passes (33/0) after it. These ten fixtures need rewriting to create lines while the order is pending before they can run against production-like rules; production behaviour is unaffected.

## 15. Phase 2 status (partial fulfilment; built locally, not deployed)

**Migrations (in order):** `20261030100000_order_amendments_schema.sql` (proposals, lines, clarification messages, stock movements, append-only protections, helpers), `20261030110000_order_amendments_patches.sql` (fail-closed in-place patches: inventory ledger accepts `order_amendment_release`; cancel-restore restores only what is still deducted; `credit_invoice_status` nets amendment credit notes; pick suggestion/confirmation use the supplied quantity), `20261030120000_order_amendments_partial_fulfilment.sql` (propose, respond, answer, withdraw, read, dispatch block, cancel closes proposals, 24 h reminder).

**Decisions applied (from D1-D12):** proposers = owner/manager/cashier/warehouse; responders = pharmacy owner/manager/cashier; amendments only while accepted..ready for dispatch; delivery fee and unit prices unchanged; one credit note per amendment on credit orders; cash orders carry the effective total; a paid non-credit order cannot be amended (no refund process); legacy orders (no stock evidence) never get a stock write; no auto-expiry, one reminder after 24 h; a proposal is closed automatically if the order is cancelled.

**Built on the screens:** a Supply changes panel on both order views (propose dialog with live totals, stock treatment per line, answer / reject / ask / reply / withdraw), amended totals and supplied quantities on both order lists, pick & pack sheets and delivery notes with Ordered/Supply columns and a banner, invoice and order copy priced on what is supplied with the original total noted, notification type `order_amendment`, audit labels.

**Not yet adopted (Phase 6, and the reason Phases 2 and 6 must ship together):** receipt emails and the confirm-payment endpoint (`api/orders/*`), reports, dashboards, statements, accounting overview, and `list_pharmacy_order_history` still read the placed total. Credit orders are already correct everywhere that reads the ledger.

**Verified:** SQL suite 163/163, concurrency script 13/13, mutation checks, browser run through propose, question, reply, accept for both roles, mobile width (375 px) with no horizontal overflow, 371 unit tests, `tsc` clean.

## 16. Phase 6 status (readers adopt the effective total; built locally, not deployed)

**Migration:** `20261101100000_effective_total_readers.sql`. Every reader below is patched in place from its LIVE definition, must match the expected number of occurrences, and otherwise stops the migration without changing anything; it is safe to re-run. **A read-only dry run against the production catalog (9 Oct 2026) matched 36 of 36 patches** (34 of the original 35, after dropping `list_wholesaler_order_queue`, plus the two for `get_order_print`).

| Area | What changed |
|---|---|
| Wholesaler, pharmacy and platform-admin reports (overview, sales, orders, customers, supplier spend, GMV, payments, pharmacy activity) | totals use `COALESCE(effective_total_ghs, total_ghs)`; an amended order's row shows goods as supplied and no order-level discount; reports stay on the original order date |
| Units and line values (product, purchase and customer reports, stock velocity, customer detail) | `order_item_supplied_qty()` instead of the ordered quantity |
| Pharmacy order list | returns `effective_total_ghs` beside `total_ghs`, sorts by what is owed, counts supplied units |
| Customer statement | the placed order stays at its placed amount on its own date; each accepted reduction is a separate dated "adjustment" line, so an issued statement never changes retroactively; a cash order's payment line is the effective amount |
| Returns | `get_returnable_items` and `request_order_return` cap at what was supplied |
| Receipts | `confirm-payment` and `send-receipt` read `order_receipt_supply()` for an amended order and print supplied quantities and the effective total; if that cannot be read they stop before changing or sending anything |
| Dashboards | the order summaries use the effective total |
| Production-only | `get_order_print` (exists only in production, nothing in the repository calls it) is patched the same way and skipped where absent |

**Deliberately unchanged:** `pharmacy_price_history*` (the unit price paid is never changed by an amendment), `get_order_reorder_lines` (reordering what was ordered is the useful default), `get_credit_invoice` / `credit_invoice_status` (ledger based; the credit note is already there), `list_wholesaler_order_queue` (no screen calls it and its production definition differs from the repository's, so it could not be patched with confidence).

**Found on the way, not caused by this work:** `admin_report_wholesaler_performance` sums each order's total once per line item (an order with three lines counts three times). A separate task was raised to fix it; this migration does not touch that behaviour.

**Also granted:** the reports run as the signed-in user, so `order_item_supplied_qty` is now executable by signed-in users. It returns one integer for an order-line id the caller already holds; ids are random UUIDs.

**Verified:** `order-effective-total-readers.sql` 57/57, mutation checks, twelve legacy suites re-run with production's order guards off (they cannot run with them on) and all unchanged, 377 unit tests, `tsc` clean, browser check of the wholesaler dashboard (sales 3470, receivables 1850 from the ledger), customers list and statement.

## 17. Phase 3 status (back-orders and shipments; built locally, not deployed)

**Scope decisions you confirmed:** back-orders on **credit orders only** for now (cash orders keep "accept and cancel the rest" and "reject"; cash back-orders follow with per-shipment payment tracking); and the **stock rule** for back-ordered units is the same per-line choice as a shortage (release, or write off because the units are not here yet), with stock **deducted again, once, when the back-order shipment is dispatched**. This refines the earlier "held, stay deducted" default: held units would have counted as sellable again the moment the delayed goods were received into stock.

**Migrations (in order, after the Phase 2 and Phase 6 ones):** `20261102100000_order_backorders_schema.sql` (shipments, shipment lines, back-order cancellations, computed quantities, stock movements may belong to a shipment), `20261102110000_order_backorders_patches.sql` (fail-closed patches), `20261102120000_order_backorders_workflow.sql` (the workflow).

**Behaviour:**
- The pharmacy gains "Accept and back-order the rest". The available quantity is supplied now, one credit note removes the rest from the invoice (as for a cancelled remainder), the order total becomes the main shipment's total, and the rest stays on the **same order** as an outstanding back-order with its own state: open, partly sent, fulfilled, closed (rest cancelled) or cancelled.
- The wholesaler prepares back-order shipments (2, 3, ...) once the main shipment has gone out. Each has its own status (being prepared, packed, on its way, delivered, or cancelled before dispatch), its own pick sheet, delivery note and invoice copy.
- **Dispatching a shipment is the financial and stock moment**, in one transaction under the order lock and the customer's credit-line lock: the credit limit is re-checked as at checkout (a suspended, blocked or closed line, or going over the limit, refuses it; a one-time override can cover it and is consumed once), stock is deducted once for exactly the units sent (orders with verified deduction evidence only), ONE invoice entry is posted for the shipment (a unique marker refuses a second), the order's total rises by the shipment, and a paid order is reopened.
- **Due dates:** order-date terms are unchanged. Delivery-date terms: the shipment falls due its terms after delivery; the order's single due date moves only if nothing was owed on the order when the shipment was invoiced, so an unpaid earlier invoice never gets longer. This is a deliberate simplification of per-shipment due dates and is recorded on each shipment.
- Either side can cancel what has not yet been put into a shipment (reason required; nothing was invoiced, so no ledger or stock effect); cancelling the whole order closes its back-order automatically and restores stock net of what was released or written off.
- Reports, returns and the pharmacy order list count dispatched back-order units (`order_item_fulfilled_qty`); the statement shows each dispatched shipment as a charge on its dispatch date.

**An important gap this phase closes (in Phases 1 and 2 as built):** staff of the wholesaler can update their orders' rows, so they could have edited `effective_total_ghs` directly and changed what a pharmacy owes without its approval. A trigger now refuses any change to it except from inside the approved functions (a transaction-local marker, not callable through the API); the same marker lets an approved dispatch reopen a paid order's payment state, which warehouse staff otherwise may not touch. **Phase 2 must not be applied without this phase's migrations.**

**Not in this phase:** cash-order back-orders; batch allocation for back-order shipments (stock is deducted, but batch numbers are not recorded on them); per-shipment due dates in the credit registers (they still age per order); delivery reconciliation by the pharmacy (Phase 5).

**Verified:** `order-backorders.sql` 130/130; the earlier amendment suites (updated for the direct-edit guard and the new movement type) still pass; concurrency script 14/14 with a negative control; mutation checks; browser run for both roles (prepare, pack, dispatch, accept with a back-order, cancel remaining); 388 unit tests; `tsc` clean. A read-only check of the production catalog found the three fragments the new patches depend on in the expected form.

## 18. Phase 5 status (delivery reconciliation; built locally, not deployed)

**What it does:** after a delivery (the main one, or a back-order shipment), the pharmacy counts what arrived. It either confirms "received in full" or reports, per product, how many units were **missing, damaged or rejected**, with a reason. The report is a **claim**: it changes nothing in stock or in the amount owed. The wholesaler's **owner or a manager** then decides each problem:

| Problem | Outcomes the wholesaler can choose |
|---|---|
| Missing | Credit it, or reject the claim |
| Damaged / rejected | Take the goods back (opens a normal return), credit it, or reject the claim |

- **Credit** posts ONE credit note on the credit ledger (at the agreed unit price), lowers the order's effective total, and never touches stock. On an order already paid in cash, a credit is refused (no cash refunds yet).
- **Take the goods back** opens an approved return for the units, which then goes through the existing return inspection. Stock and money follow that return, not the claim.
- **Reject** needs a written note to the pharmacy. If every problem is rejected the report ends as "not accepted" and the pharmacy may report again.
- No automatic stock reversal and no automatic credit note ever happens without the wholesaler's decision.
- A pharmacy can withdraw a report until it is decided. Only one live report exists per delivery; reports can be made within 30 days of delivery. Units under a claim cannot also be returned separately.

**Gap closed (D9):** until now, resolving a return as refund or credit reduced the customer statement but never the credit ledger, so the two disagreed. A return resolved as refund or credit on a credit order now posts one ledger credit note linked to the return, and `credit_invoice_status` nets those notes against the invoice.

**Migrations (after Phase 3):** `20261103100000_delivery_reconciliation_schema.sql` (report, line and decision tables; ledger/return link columns; reconciled-quantity function), `20261103110000_delivery_reconciliation_patches.sql` (fail-closed patches to `resolve_order_return`, `credit_invoice_status`, the returnable-quantity functions and `customer_statement`), `20261103120000_delivery_reconciliation_workflow.sql` (submit, withdraw, resolve and read functions). **Apply order for production: Phase 2, Phase 6, Phase 3, then Phase 5**: the Phase 5 patches depend on functions the earlier phases create.

**Screens:** a "Delivery check" panel on each order for both sides (the pharmacy's "Check this delivery" dialog; the wholesaler's "Check and decide" dialog, which shows the credit that would result). Delivery problems appear in the order's activity, the audit centre, and the customer statement (dated credit line). The wholesaler's owner and managers are notified of a report.

**Not in this phase:** returns that were already resolved before this migration are **not back-filled** into the ledger; a returned item does not reduce the order's effective total (only a credit does); the return restock is still tagged `admin_adjustment`; no "send again / redeliver" outcome; no cash refunds; no reminders for reports nobody has decided.

**Verified:** `delivery-reconciliation.sql` 104/104; concurrency script 11/11 with a negative control; mutation checks; 420 unit tests; `tsc`, lint (new files) and build clean; browser run for both roles (report, decision validation, credit + return + reject outcome, ledger/total checked in the database). The Phase 5 patch fragments can only be dry-run against production once the earlier phases are applied there.

## 19. Phase 4 status (price amendments; built locally, not deployed)

**What it does:** while an order is being prepared (accepted up to ready for dispatch) the wholesaler's **owner or a manager** can propose new unit prices for one or more products, with a reason. **Only the pharmacy's explicit approval applies them** (pharmacy owner, manager or cashier); the pharmacy can also reject or ask a question, and the wholesaler can reply or withdraw. The original and proposed prices are both stored and shown. The order cannot be dispatched while a proposal is open, and only one proposal (of any kind) can be open on an order.

**How the money works (decisions D5, D6, D11, D12 applied):**
- The order's effective total moves by the sum of (new price - price now) x the units the wholesaler is committed to supply.
- **Credit order:** a decrease posts ONE credit note, an increase ONE debit note, each tagged with the amendment (a unique index refuses a second). An **increase is checked against the customer's credit line** when the pharmacy approves, under the same lock as checkout; a one-time credit override can cover it and is consumed once. An increase on a credit order that was already fully paid reopens it as unpaid.
- **Cash order:** the effective total is what is collected; no ledger. A cash order that is already paid cannot be amended (no refund process), including a proposal made before payment and approved after it.
- A proposal that no longer describes the order (the price or the committed quantity changed since) cannot be approved; the wholesaler proposes again.
- Stock is never touched by a price change.

**The price in force:** order lines are never edited (production's guard makes them immutable). The accepted price lives on the amendment line and is read through `order_item_effective_price()`, which returns exactly the placed price for any line no price amendment has touched. A second amendment starts from the price in force. Everything that values a quantity now reads it: partial-fulfilment shortages, back-order shipments, delivery reports and their credits, returns, the purchase / product / customer reports, the price history (it reports the price actually paid), receipts, printed documents and the order screens. The customer statement shows an accepted price change as its own dated line.

**Migrations (after Phase 5):** `20261104100000_price_amendments_schema.sql` (price column on amendment lines, the price in force, the extra response choice), `20261104110000_price_amendments_patches.sql` (22 fail-closed patches to existing functions; safe to re-run), `20261104120000_price_amendments_workflow.sql` (propose, respond, reply, withdraw). **Apply order for production: Phase 2, 6, 3, 5, then 4** (the Phase 4 patches change functions those phases create).

**Screens:** a "Price changes" section on every order for both sides (the wholesaler's "Propose new prices" dialog with live totals and the plain-words consequence; the pharmacy's approve / reject / ask dialogs), earlier proposals listed with their prices, price changes in the activity timeline, the audit centre and the statement.

**Not in this phase:** the delivery fee and quantities cannot be changed here (a supply change handles quantities); prices cannot be changed after dispatch (use delivery reconciliation or a return); the price of units still waiting in a back-order cannot be changed once the first dispatch has happened; `get_order_print` (production-only function) still prints placed prices; no per-line approval (the pharmacy approves or rejects the whole proposal).

**Verified:** `price-amendments.sql` 123/123; concurrency script 13/13 with negative controls; mutation checks M1-M5; 434 unit tests; `tsc`, lint (touched files) and build clean; browser run for both roles (approve, the dialog stating the debit note; propose with validation messages; withdraw; mobile width with no overflow). The patch fragments could not be dry-run against production in this session (the connected Supabase account cannot open the production project); each patch stops without changing anything if a function is not as expected.

## 20. Phase 7 status (UI consistency, notifications, role and mobile checks; built locally, not deployed)

This phase changes the screens only; no database change. It came out of walking every role through every panel.

**Fixed:**
- **Notifications now open the order.** The notification bell and the notifications page already opened the right tab, but not the order. They now add `&order=<id>` (from the notification's own `order_id`) and the pharmacy and wholesaler order lists open that order and scroll to it (the opening was verified for both sides; the scroll could not be observed because the browser pane was hidden). Older notifications behave as before. Links for anything other than the two order pages are untouched; a malformed id is ignored.
- **Wording that was only true for supply changes.** The order-list badges and the dispatch tooltip said "supply change" even for a price proposal; they now say "a change". The printed order copy said "Reduced by agreement (supply change accepted)" even after a price increase; it now says reduced, increased or "prices changed" by agreement. The statement footnote now names supply changes, price changes and delivery credits.
- **A real defect found while testing:** the pharmacy and wholesaler pages replaced themselves with a "Loading..." screen whenever the session store reported a background refresh (the browser re-announces the sign-in when you return to the tab). That unmounted everything, including an open dialog and anything typed in it. Seen twice while testing. The pages now show the loading screen only for the very first load (no business yet). I could not trigger the refresh on demand to prove the fix; I checked that a dialog with typed text stays mounted, and the logic is a one-line condition.

**Role matrix (browser, local database, one order of each kind: open supply proposal, open price proposal, delivered with a report awaiting a decision, delivered and settled, and one with no proposal open):**

| Role | Propose supply change | Propose prices | Reply / withdraw a proposal | Decide a delivery report | Approve / reject / ask |
|---|---|---|---|---|---|
| Wholesaler owner, manager | yes | yes | yes (both kinds) | yes | n/a |
| Wholesaler cashier, warehouse | yes | no | supply: yes; price: no | no | n/a |
| Wholesaler finance | no | no | no | no | n/a |
| Pharmacy owner, cashier | n/a | n/a | n/a | n/a (can report, withdraw) | yes (price, supply; back-order only on credit orders) |
| Pharmacy assistant | n/a | n/a | n/a | no | no |

Every "no" is also refused by the database (covered by the SQL suites); the screens only hide the buttons. Other businesses' staff and admins cannot read or act on an order they are not part of (covered by the SQL suites).

**Mobile (375 px):** no horizontal scroll with every panel open on both sides; the wholesaler's propose-supply, propose-prices, withdraw and decide-a-delivery-report dialogs fit the screen with the primary and cancel buttons stacked and reachable. The pharmacy's dialogs were checked on desktop only (the measuring script could not read a hidden pane reliably).

**Not done / for later:** the screens still use the word "Supply changes" as the section heading (it contains the price section and the back-order panel); a single "Changes to this order" heading is a possible later polish. The block-dispatch message from the database still says "supply change" (SQL, not changed here).
