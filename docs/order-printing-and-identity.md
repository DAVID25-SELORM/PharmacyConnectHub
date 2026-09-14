# DrugXone order printing and public identity additions

These additions build on Phase 0. No historical migrations or live data were changed, and no deployment or push was performed.

## Printing

- Pharmacy: **My orders** -> **Print Order** on an order card.
- Wholesaler: **Incoming orders** -> **Print Order** on an order card.
- Shared `src/components/OrderPrintButton.tsx` fetches a fresh authorized document and displays a sandboxed iframe. The browser print command targets only that iframe. Closing it or changing signed-in user/business removes the private preview. No public route, download URL, storage object or unauthenticated endpoint is created.
- New forward migration: `20260914100000_private_order_print.sql`, after the Phase 0 corrective migration. The `get_order_print(business_id, order_id)` RPC is STABLE/read-only, explicitly checks authentication, owner/active membership, business type and the order's buyer/seller business. Admin role alone does not bypass this check. Execution is revoked from PUBLIC/anon/service_role and granted to authenticated users.
- The definer projection deliberately exposes only printable fields: no auth records, private verification contacts, internal IDs, audit metadata or session information. It can show the transaction party's public business contacts even if the counterparty is no longer catalogue-visible. Account private contact fields are not substituted.
- Prices and line names come from `order_items.unit_price_ghs` and `product_name`; line subtotals are computed with PostgreSQL NUMERIC; final total comes from `orders.total_ghs`. Decimal text is formatted as GH₵ without floating-point conversion. Catalogue price changes do not alter print values.
- A4 page margins, repeating table headers, wrapping text and row/page-break rules; separate buyer/seller sections, clear ORDER heading, support footer. It is not a tax invoice or proof of payment. No dashboard navigation, buttons or sidebar is included in the printed document.

### Available historical data

The additive print migration snapshots available brand, generic name, strength, form and pack size into `order_items.product_details` when canonical checkout creates a new item. The existing Phase 0 immutable-item trigger protects that snapshot. Printing itself does not write it. Earlier items remain NULL; no historical detail is fabricated from the current catalogue.

Older unsnapshotted details, separate discounts, delivery charges and pickup-method fields are omitted because they were not recorded. Product names already containing a strength remain intact. Order notes and the buyer's stored location description are shown when populated. Business contacts are current business records, explicitly labelled as such in the footer; they are not claimed to be historical address snapshots or a confirmed delivery destination.

## Official public identity

`src/lib/platform.ts` is typed public configuration, containing:

- DrugXone
- DAVENTRA Technologies
- David Selorm Gabion
- drugxone@gmail.com
- 0247654381

No physical address, website/domain or social account is invented. The footer, print document and receipt support information use this configuration. Platform contacts do not overwrite buyer or seller contacts.

## Cleanup inventory

| Location                                                 | Previous value                                                                                                         | Action                                                                                                |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Header, dashboard, authentication screens, page metadata | PharmaHub GH / PharmaHub / split Pharma + Hub GH                                                                       | DrugXone                                                                                              |
| Old raster logo and favicon                              | Image with embedded PharmaHub text                                                                                     | Removed old assets; neutral capsule SVG mark and DrugXone wordmark                                    |
| Footer                                                   | hello@pharmahub.gh                                                                                                     | drugxone@gmail.com via configuration                                                                  |
| Footer                                                   | +233 20 000 0000                                                                                                       | 0247654381 via configuration                                                                          |
| Footer                                                   | Accra, Ghana as platform address                                                                                       | Removed; no supplied physical address                                                                 |
| Footer                                                   | Missing company/contact attribution                                                                                    | DAVENTRA Technologies / David Selorm Gabion / Powered by attribution                                  |
| Signup/login/admin/staff inputs                          | example.com/business-domain example emails, fake phone examples, Jane Doe, sample business names/licence/address codes | Descriptive input prompts                                                                             |
| Landing page                                             | 240+ wholesalers, 12k+ SKUs, 98% on time, average 6 hours, same-day/FDA claims                                         | Removed sample statistics; neutral descriptions of existing workflows                                 |
| Receipt email                                            | Old brand/default sender label and configurable old support reply-to                                                   | DrugXone display name, official reply-to/support details; retain configured verified transport sender |
| Future platform audit events                             | PharmaHub GH organisation label                                                                                        | Additive replacement of audit trigger function label only                                             |
| Admin audit display                                      | Historic platform organisation label                                                                                   | Normalize known platform label on display; do not rewrite historical rows                             |
| Business invitation guidance                             | Owner must activate pending invitation                                                                                 | Recipient finishes password setup and accepts, matching Phase 0                                       |

No known fake public contact/address/social placeholders remain in the checked runtime source. Useful form guidance still exists (medicine/pack-size/import examples, city or working-hours examples, password length prompts). These are empty-input guidance, not business records or platform contact claims. Test fixtures, unused `mock-data.ts`, `.env.example` and historical setup/migration examples remain outside the production UI. The `pharmahub.active_business_id` storage key is deliberately preserved to avoid breaking sessions. Existing stored business/order data was not altered or rebranded.

## Provider-managed communications: manual follow-up, not applied

Supabase Auth templates are not stored in this repository. In the project's Authentication email templates, update **Confirm signup**, **Invite user**, **Magic link** (if enabled), **Change email**, and **Reset password** subjects/body/header/footer to DrugXone. Where support appears, use drugxone@gmail.com and 0247654381; company attribution is DAVENTRA Technologies and contact person David Selorm Gabion. Preserve Supabase confirmation/token/link variables. Do not add a physical address or social URL.

Review Supabase custom SMTP sender display name and provider project branding. Set the display name to DrugXone; use an authenticated/verified sending address configured with the email provider. Gmail is the official support/reply-to address, not an invented verified Resend sender domain. The repository receipt sender still requires `RECEIPT_FROM_EMAIL` or `MAIL_FROM_EMAIL`; its display name and reply-to are now taken from public configuration. No production environment variables or provider templates were changed. Approval/rejection and status notifications generated by repository SQL already use actual business/order details and had no platform contact placeholders.

## Verification

- `npm test`: 48 passed, 0 failed (includes print renderer, public-identity scan and receipt payload tests).
- `npm run test:db`: 38 reported tests including parent, 0 failed; all 30 exact migrations applied only to isolated PostgreSQL. Printing tests cover both owners, foreign IDs/context tampering, unauthenticated callers, pending/inactive staff denial, active staff access, historical prices after catalogue changes, actual parties and unchanged order/item/stock/history/audit/notification state.
- Browser: `npm run test:print-ui`, after `npm test` generates local documents and a local Vite server is running on 127.0.0.1:4180. Requires installed Chrome. Browser tests mock only session/data boundaries and block external network requests; PostgreSQL tests establish actual database authorization.
- Six browser checks passed: short A4 output, multipage output, pharmacy action, wholesaler action, denied preview, official footer. Preview print callback and cleanup were exercised; no mutation call was issued.
- PDF inspection: short order 1 A4 page; 65 lines 5 A4 pages, all populated. Repeating headers and intact rows visually checked. Browser screenshots/PDFs are ignored local test artifacts in `.tmp/print-qa`.
- Earlier test failures were fixture/assertion issues (synthetic business name contained its UUID, missing mock session method, and awaiting dialog-close animation) and two lingering form-example emails. Fixed and rerun successfully.

These additions do not change the previous NOT READY production verdict or resolve outstanding audit risks outside their scope.

## Final validation results

Final lint, TypeScript (including APIs), production build, and Git whitespace checks passed with exit code 0. Unit/API tests: 48 passed, 0 failed. Database suite: 37 subtests plus parent, 38 reported passed, 0 failed, 0 skipped. Browser suite: all six checks passed; no page errors. No production migration, data mutation, deployment, push, or provider configuration change was performed. Prior Phase 0 work remains in the same uncommitted working tree.
