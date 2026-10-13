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

## Not yet redesigned
The RFQ list page, the supplier's quote editor, quote comparison and the award/confirmation screens still use the older plain layout.
