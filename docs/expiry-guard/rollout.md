# Expiry sales guard: rollout

Units in a batch past its expiry date must not be sold. This adds a guard with three modes, **off**, **observe** and **enforce**, switched by a platform administrator on the Admin Console (under **Expired stock**) with a reason, no deployment needed.

## What changes, and when

| Stage | What happens to a sale |
|---|---|
| **Observe** (the mode it starts in) | Nothing is blocked. If a sale would have needed expired units, it is recorded (product, wholesaler, quantity, stock, expired units, what could have been sold). Pharmacies see exactly what they see today. |
| **Enforce** | A sale that needs expired units is refused with a message ("Only 12 unit(s) of X can be sold: 8 unit(s) are past their expiry date."). Pharmacies are shown only the number that can be sold, so they are never told "available" and then refused. |
| **Off** | Nothing is checked. |

"Sellable stock" is the stock minus the units in batches whose expiry date has passed, never below zero. A batch is still good **on** its expiry date. A product with no batches is unaffected, and units that were never put into a batch stay sellable. Writing off expired units lowers stock and the expired batch together, so it does not change what can be sold.

It applies to marketplace checkout, request-for-quotation awards (whole quote and by line), back-order shipment dispatch, and the pharmacy storefront catalogue. Picking was already skipping expired batches and is unchanged.

## Steps, in order

1. **Pre-flight (read-only):** run [preflight.sql](preflight.sql) in the production SQL Editor. Every row of the first result must say `ok = true` with `matches = 1`, and `already_patched = false`. If any row is not, stop: the migration would also stop, changing nothing, and I need to see the result.
2. **Apply** `supabase/migrations/20261209100000_expiry_sales_guard.sql`. It is one transaction: all of it or none of it. Applying it again changes nothing.
3. **Verify (read-only):** run [verify.sql](verify.sql). Every row should say `true`.
4. **Deploy the screens.** They work with or without the database update: before it is applied the Admin Console card says so, and the wholesaler product list simply omits the expired figure.
5. **Observe for about two weeks** (it starts in observe). On the Admin Console, **Expired stock** shows the products holding expired units, how many are still orderable, how many products have more units in batches than in stock, and each sale that would have been refused.
6. **Put right the stock that does not match its batches.** This is the wholesaler's job (write off expired units, or correct the stock or the batch). The guard cannot tell which figure is right, so it does not guess.
7. **Enforce** when the list of would-be refusals contains only real expired stock. Switch to Enforced on the Admin Console, with a reason.

## Going back

Switch to **Observe** or **Off** on the Admin Console. It takes effect on the next sale. No migration and no deployment.

## Things to know

- In **enforce** mode a refused sale rolls back, and with it any record of the attempt: the buyer sees the message, but nothing is logged. Observe mode is where attempts are counted.
- The guard looks at the batches a wholesaler has recorded. A wholesaler who does not use batches is not affected.
- An order placed before a batch expired is unaffected by this change. At picking, expired batches are still skipped as before.
- Pharmacies can infer how much a wholesaler has expired from the gap between stock and sellable stock only in enforce mode, and the catalogue shows them the sellable number as the stock, so no separate figure is exposed. Only a product's own staff and administrators are told the expired figure.
