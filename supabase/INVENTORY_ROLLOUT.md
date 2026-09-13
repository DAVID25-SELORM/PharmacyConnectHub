# Safe inventory import and master catalogue rollout

## Verification

Local checks:

```powershell
npm test
npx tsc --noEmit
npm run build
npm install --prefix .tmp/import-db --no-save @electric-sql/pglite
node tests/safe-import-db.mjs
```

The database test uses isolated PostgreSQL in WASM with minimal auth/business fixtures. It executes both real migration files, exercises permissions, rollback, blank/zero quantities, modes, duplicate and existing-collision rejection, stale previews, retry idempotency, audit values, catalogue backfill, synchronization and visibility. It does not connect to hosted Supabase or replace staging concurrency/RLS/UI checks.

Browser checks use fake authentication and intercepted Supabase responses; they send no live orders or imports. On Windows with Chrome installed, start Vite with the dummy URL, then run the test in another terminal:

```powershell
npm install --prefix .tmp/import-db --no-save @electric-sql/pglite playwright
$env:VITE_SUPABASE_URL='http://127.0.0.1:54399'
$env:VITE_SUPABASE_PUBLISHABLE_KEY='test-publishable-key'
npm run dev -- --host 127.0.0.1 --port 5178
# In a second terminal:
node tests/inventory-ui.mjs
```

The browser checks cover preview versus confirmation requests, invalidated previews, invalid-row blocking, supplier grouping, the selected supplier in the cart, navigation errors and mobile overflow. Screenshots are written under the ignored `.tmp` directory.

## Staging checks

- Apply the two September migrations in order after every prior migration. Keep a database backup and deploy the corresponding frontend.
- Check every legacy product has a matching offer and matching price/status. No legacy product or order reference should be deleted or reassigned.
- Inspect normalized collisions using the query below. Resolve ambiguous records manually; imports refuse to choose one or merge stock automatically.
- With an approved owner/manager, preview a mixed file containing new, existing, blank, zero, invalid and repeated rows. Confirm is disabled for invalid/duplicate rows. Preview must not change inventory or audit records.
- Verify Replace, Add, and Details-only mode against known balances. New details-only products start at zero; inactive offers remain inactive.
- Preview a replacement, place an order in another session, then confirm: confirmation must reject the stale preview. Refresh and review again.
- Retry a successful Add confirmation with the same request ID: stock and audit entries must not duplicate. Concurrent confirmations should serialize; no overselling or lost stock updates.
- Confirm sales staff, another business's users, pending wholesalers, and anonymous clients cannot import. Verify authenticated catalogue access using actual Supabase RLS.
- Confirm audit logs contain the actor, request ID, mode, before and after product records.
- Find one medicine offered by two approved suppliers: it should have one result and two supplier choices. Each Add action must retain that supplier's legacy product ID through cart and checkout.
- Check narrow mobile screens, large previews, file imports, pasted tables, keyboard confirmation and failure messages.

```sql
select wholesaler_id,
       public.product_import_identity(name, brand, form, pack_size) as identity,
       array_agg(id) as product_ids, count(*)
from public.products
group by wholesaler_id, public.product_import_identity(name, brand, form, pack_size)
having count(*) > 1;

select p.id from public.products p
left join public.wholesaler_products w on w.id = p.id
where w.id is null or w.selling_price <> p.price_ghs or w.active <> p.active;
```

## Deliberate boundaries

- Matching uses name, brand, form and pack size, normalized for ASCII case, spaces and most punctuation. Decimal points, fractions, combination markers and percentages remain significant. This is not clinical equivalence matching. Missing strengths/generic names are not inferred. The shared catalogue still needs human curation for aliases and incomplete names.
- Existing collisions are retained, not automatically deduplicated. Multiple legacy offers for the same supplier can remain visible until reviewed.
- Up to 5,000 rows per import. Confirmations briefly lock product writes to atomically recheck preview and apply changes, including new identities. Measure contention in staging before increasing volume; the later batch/reservation architecture should use narrower inventory locks.
- Existing inactive products stay inactive during import. Active products only appear when their wholesaler and master identity are also active/approved.
- A preview includes before/after stock and price; confirmation records detailed audits. Other omitted product fields retain the existing import defaults (for example category Other and dosage form Tablet); review source headers carefully.
- The bridge adds tables instead of renaming products, so existing order creation/cancellation behavior stays in place. Batch FEFO, explicit reservations and movements, document renewal and commercial pricing are subsequent phases, not completed features.
- Rollback of the UI should be coordinated with the database: the old unsafe importer is intentionally unavailable. Retain the new tables and product IDs; do not drop data to roll back presentation changes.
