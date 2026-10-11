# Pharmacy orders remediation

Implements the 18 findings in the 11 October 2026 orders audit. Changes are on `fix/pharmacy-orders-audit`; production records have not been changed.

| Findings | Implementation |
| --- | --- |
| F01 | Detail cache survives filtering; incomplete details cannot produce documents; full supplier details are retained. |
| F02 | Cards use the same effective settlement method and payment description as details. |
| F03 | New authorized, pharmacy-scoped list/detail readers; document buyer returned by the server. |
| F04–F05 | Workspace-wide counts independent of filters/pagination; all active stages included; transit means dispatched. |
| F06 | Header and order actions wrap; compact mobile metrics and filters. |
| F07 | Named filters, selected status semantics and order-specific action labels. |
| F08–F09 | Honest receipt-not-sent wording and explicit missing delivery details. |
| F10 | Server-derived return eligibility disables expired return actions with explanatory wording. |
| F11 | Supplied-quantity line amounts use the same helper as documents. |
| F12 | Debounced search, latest-request guard, loading/error states and retry. |
| F13 | Tab/filter/page state stored in the URL; clear filters available with matching results. |
| F14 | Unambiguous Ghana dates without duplication; available current catalogue specifications explicitly labeled as current rather than historical snapshots. |
| F15 | Invoice/order-copy dialog description added. |
| F16 | Authorized linked order fetched independently of the current result page. |
| F17 | Supply lookup errors block financial documents and mark amounts unverified. |
| F18 | Validated UTC/Ghana date bounds with exclusive next-day end; time-dependent SQL helper marked STABLE with Ghana timezone. |

## Validation

- Full unit/component suite: 779 tests across 81 files passed.
- New database regression suite: 16 assertions passed against an isolated Docker database copied from local fixtures. Includes authorized multi-business isolation, unrelated user/inactive staff rejection, authoritative buyer identity, pagination/aggregate behavior and date validation. Transactional fixtures rolled back.
- TypeScript and production build passed. Build retains the existing large-chunk advisory.
- Disconnected browser fixture: desktop rendering inspected. Narrow-screen screenshot verification was interrupted by Chrome debugger detachment; mobile styling is implemented but final mobile browser sign-off remains outstanding.
- Existing route lint debt: 11 `no-explicit-any` errors were already present. No claim of repository-wide lint cleanliness.

## Release order

1. Apply `supabase/migrations/20261118100000_pharmacy_orders_audit.sql` in staging, then run `tests/local-supabase/pharmacy-orders-audit.sql` against isolated fixtures only.
2. Verify the UI on staging, especially 320/390/768 widths, invoice completeness, role changes and multi-workspace switching.
3. Apply the additive migration before deploying this client. The client requires `list_pharmacy_orders_scoped` and `get_pharmacy_order_scoped`; without them it fails closed with a retryable list error.
4. Deploy only after migration verification. Keep the old reader functions for old clients. To roll back the UI, retain the additive readers; do not delete financial records.

Local disconnected responsive fixture:

```powershell
npx vite --config tests/browser/orders.config.ts --host 127.0.0.1 --port 5175
```

Open `/tests/browser/orders.html`. Its Supabase/session imports are replaced by local stubs; it cannot access production.

Production migration application and deployment are not performed by pushing this remediation branch.
