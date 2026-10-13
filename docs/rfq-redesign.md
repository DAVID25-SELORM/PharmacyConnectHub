# RFQ redesign, stage 1: create/edit screen and the request's item list

**Why:** the create screen was a long stack of unstyled boxes: every medicine was a tall block of inputs, paged only by 20, with the supplier list and import tools scattered between them. A request with hundreds of lines was hard to scan, edit or check.

**Limits (unchanged, enforced in the database):** 500 medicines and 100 invited suppliers per RFQ. The screen shows both limits. Raising them means changing the save, quote and award functions, so it is a separate decision.

## What changed
- **Create/Edit** (`EnterpriseRfqEditor.tsx`) is four clear sections: 1 Request details, 2 Medicines, 3 Suppliers, then Review, with a sticky bar showing counts, problems and the actions.
- **Medicines** (`RfqMedicineTable.tsx`) is one compact table, not a block per medicine: quick add (name, quantity, unit), search and filter (all / needs attention / not in catalogue), 25/50/100 rows per page with page jump, select rows (page or whole view) and change unit, shelf life, partial supply, alternatives or cold chain in one go, remove selected (with a second confirmation), and "Combine duplicates". Per-line extras (storage, notes, flags) sit in an Options popover.
- **Adding in bulk** (`RfqAddTools.tsx`): spreadsheet import with a preview (matched vs needs review) and a template, past purchases (multi-select), and the catalogue, each in its own dialog.
- **Suppliers** (`RfqSupplierPicker.tsx`): a searchable table with view tabs, select-all-on-page, favourites, history, and the 100 limit.
- **The saved request** (`RfqItemsTable.tsx`, used by `EnterpriseRfqDetail.tsx`): numbered, searchable and paged.
- `MedicationPicker.tsx` now searches only when a field is in use. Before, every row on screen ran its own catalogue search the moment it appeared.
- Logic lives in `src/lib/rfq-lines.ts` (filter, paging, bulk edit, merge, append and the limit), with tests. Nothing about what is saved or how changed: the payload is the same, and a client-only row id is stripped before saving.

## Checked
Unit tests (`rfq-lines.test.ts`, `RfqMedicineTable.test.tsx`), plus a browser run against the local stack: a 479-row import, duplicates combined, bad quantity flagged and fixed, bulk cold chain on all 477 lines, jump to page 20, supplier invite, validation message, review, a real save through `save_enterprise_rfq`, the saved request's list, Edit draft reloading 477 lines, and phone width (no horizontal overflow).

## Stage 2: the supplier's quote editor
**Why:** one tall card per requested medicine, each with its own product search that ran as soon as it appeared, and no help for a supplier answering hundreds of lines.

- `EnterpriseQuoteEditor.tsx` is now: request summary (reference, respond by, delivery needed, deliver to), 1 Lines, 2 Terms, and a sticky bar with lines quoted, problems, an estimated total, **Save private draft** and **Submit quotation**. Submitting asks for confirmation first, because a submitted version is final.
- `RfqQuoteTable.tsx`: one row per requested medicine (what is asked, the shelf life, cold chain / full quantity / alternatives flags) with your product, units, price, discount and expiry inline and the rest (alternative, batch, availability date, cold chain, handling, notes) in a Details popover. Search, filter (all / quoted / not quoting / needs attention), 25/50/100 per page, select rows and set discount or expiry, offer the full quantity, confirm cold chain, fill empty prices from catalogue list prices (explicit and never overwriting), or stop quoting.
- **Match my catalogue** fills lines whose requested medicine has exactly one active product in your catalogue under the same catalogue identity. Several candidates or none are left for you; nothing is inferred beyond that.
- `QuoteProductCombobox.tsx` searches your catalogue only while it is open (it used to search on every line at once).
- **Problems are shown before submitting**, mirroring the server's rules (`src/lib/rfq-quote-lines.ts`): whole units, no more than requested and the full quantity when partial supply is not allowed, price above zero, discount below 100, expiry beyond the buyer's shelf life at the delivery date, cold chain confirmed, alternatives only where allowed, and a different catalogue medicine must be marked as an alternative. The database still checks everything again. A stale conversion factor on a normal (non-alternative) line is no longer sent, which used to make the server refuse it.
- The estimated total uses the server's two-step rounding. In the local check it matched the stored total exactly (62,890.86 for 22 lines).
- `TablePager.tsx` is the shared pager now used by all three RFQ lists.
- What is saved and how is unchanged: same payload, same `save_enterprise_quote` function, same draft table.

**Checked:** unit and component tests, and a browser run on the local stack as a supplier: match 22 lines, bulk fill prices / expiry / discount / cold chain, validation messages, the submit confirmation, a real submit (22 lines stored; total equal to the estimate), reopening as a revision (loads the submitted lines, asks for a reason), and phone width.

## Stage 3: the buyer's comparison and award
**Why:** every supplier's whole quotation was printed as its own table (several suppliers x hundreds of lines), followed by a second matrix of the same data, with award boxes scattered through both and one block at the very end. Comparing suppliers meant scrolling thousands of rows.

- **Overview** (`RfqQuoteOverview.tsx`): one row per supplier's latest quotation: how many lines it answers (with a bar and how many in full quantity), goods, delivery, landed total with a **Lowest total** tag, lead time, validity, payment terms and credit position. Revision history, "Choose the whole quotation", "Ask for revised terms" and the quotation PDF are in each row's menu. Sorting is unchanged (lowest landed total, fastest delivery, highest offered quantity, longest credit term).
- **Requirement by requirement** (`RfqComparisonMatrix.tsx`): one row per requested medicine, one column per supplier, paged 25/50/100 with search and filters (all, still to decide, with a choice, alternatives offered, nobody quoted). Each cell shows the offered product, price (with the struck-through list price), quantity, expiry, a **Lowest price** tag, an Info popover for lot, availability, cold chain, handling, observed stock and notes, and the award box. A requirement already fully allocated says so.
- **Choosing and awarding** (`RfqEvaluation.tsx`, `src/lib/rfq-evaluation.ts`): problems are shown on the cell before anything is sent, mirroring what the database enforces (whole units, no more than offered, no more than is still needed across suppliers, full quantity where partial supply is not allowed, alternatives need explicit acceptance, 500 lines per award). **Start from lowest prices** is only a starting point: it fills each open requirement from the lowest price per requested unit upward, never picks an alternative on its own, and gives a full-quantity-only requirement to the cheapest quote that covers all of it. A sticky bar shows lines chosen, suppliers, value with delivery and any problems. **Review allocations** opens a summary by supplier (goods, delivery, total) with order classification and settlement, then **Confirm pending awards**. Nothing is awarded without that step, and suppliers still have to confirm.
- **Revised terms** (`RfqNegotiateDialog.tsx`): asking a supplier to change one term is a small dialog with a field that matches the term (price, quantity, date or text). Previously it shared one "Reason" box with the cancel and decline actions, whose input type changed with the chosen term. That box is now always plain text.
- **Supplier's own view** (`RfqSubmittedQuote.tsx`): terms summary, searchable paged lines and revision history instead of one long table.
- Nothing about what is saved or how changed: the same `propose_rfq_awards` and `rfq_negotiate` calls, with the same request shape. The order classification values and settlement values are unchanged; only their labels are friendlier.

**Checked:** unit tests for the evaluation rules (20) and component tests for the comparison and award flow (5), plus a browser run on the local stack with two suppliers quoting the same RFQ: overview, matrix, lowest-price tags, start-from-lowest-prices, review, a real award (two pending award groups created, RFQ moved to partially awarded), over-allocation blocked with a plain message, fully-allocated lines, and the supplier's own view.

## Not yet redesigned
The RFQ list page and the award confirmation, order links, negotiations and status-action sections at the bottom of the detail page still use the older plain layout.
