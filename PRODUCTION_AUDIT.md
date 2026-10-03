# Production readiness audit — 2026-10-03

Verdict: **not ready for an unconditional production sign-off**.

## Remediation update

The following database fixes were applied to production project `ywpntuioeqpreouauuir` through the authenticated Chrome SQL editor and verified with catalog queries:

- `20261017100000_checkout_idempotency.sql`: new atomic checkout wrapper, request/payload matching, replay authorization and private request storage. Confirmed installed; authenticated clients cannot execute the privileged wrapper or read the request table. The API authenticates the caller before invoking it with the service role.
- `20261017110000_production_checkout_compatibility.sql`: current six-argument checkout now writes the stock-deduction evidence required by production cancellation and sets inventory movement attribution. The production-only older four-argument checkout already had separate idempotency, but the current API did not use that overload. Both existing overloads were preserved.
- The production-only `phase0_order_integrity` guard now permits picking and ready-for-dispatch transitions, while preserving immutable financial fields and existing cancellation eligibility. Catalog verification returned `stock_evidence_fixed=true` and `lifecycle_fixed=true`.

Local validation: replay creates only one order, stock deduction and debt entry; mismatched payloads and unauthorized replays are rejected. Two simultaneous requests with the same ID returned one result, with the second waiting for the first transaction. Exposure increased by GHS100 once, one deduction record exists, and temporary audit/inventory contexts were cleared. The full fulfilment chain passed; invalid cancellation and historical financial edits remained blocked.

Application fixes prepared: persistent checkout request IDs, XLSX 0.20.3 from the official SheetJS distribution, PDF.js 6.3.289, updated dependency lockfile, CSP/anti-framing/nosniff/referrer headers, and statement printing without inline JavaScript. Chrome successfully parsed one XLSX and one PDF sample under the configured CSP. The unit suite passed 287 tests and TypeScript passed. Application deployment status is recorded below after verification.

Current `npm audit --omit=dev`: zero high/critical/moderate findings, one low esbuild tooling advisory. The full development dependency tree still has advisories and needs a separate toolchain upgrade; no claim is made that every advisory is a demonstrated live exploit.

Additional live check: no public regular tables readable by anon/authenticated have RLS disabled. This is coverage only, not proof of policy correctness. Production currently has zero credit orders. No production business orders, payments, invitations or emails were created by this remediation.

Still unverified: complete migration/schema parity (history table absent), controlled-account tenant-isolation tests, backups/restore rehearsal, alert delivery, all authenticated workflows, and clean repository-wide lint. The user confirmed paid amounts should remain account credit. Migration `20261017120000_cancelled_credit_account_balance.sql` was applied and verified in production: cancellation releases invoice charges while retaining payments; direct reversal of cancellation credits is rejected. Local real-payment tests passed, including a subsequent purchase using the retained balance. Checkout versus adjustment/reversal concurrency remains to be verified. The findings below retain the initial audit evidence and should be read with this remediation update.

Scope: public production HTTP checks on drugxone.com (redirects to www.drugxone.com), repository commit d08c1a1, local tests and isolated database reproduction. No production business records were changed. This is not a penetration test or proof that every production workflow is correct.

## Findings

1. **High — checkout retries can duplicate orders.** `api/orders/create.ts` and `create_marketplace_orders` have no request identifier or deduplication mechanism. In the isolated local database, two identical GHS 100 requests each returned one created order; exposure rose from GHS 4,000 to GHS 4,200. The reproduction was rolled back. A lost response followed by retry can reserve stock and create debt twice. Add a pharmacy-scoped idempotency key, payload matching and an atomic stored result; test concurrent retries. Exact production function parity remains unverified.

2. **High — import dependency advisories require remediation and reachability review.** Fresh `npm audit --omit=dev` reports six high and one low dependency findings, not seven demonstrated live exploits. Installed `xlsx` 0.18.5 parses supplied spreadsheets in `src/lib/product-import.ts:189`; its prototype-pollution and ReDoS advisories need a supported replacement or patched distribution. Installed `pdfjs-dist` 5.6.205 falls in an affected range. The application uses text extraction through `getDocument`, not a full PDF viewer: arbitrary JavaScript execution through this specific path was NOT demonstrated. Other findings include build tooling and must not be represented as equivalent public-site vulnerabilities.

   References: https://github.com/advisories/GHSA-4r6h-8v6p-xvw6 and https://github.com/advisories/GHSA-hq66-cqwq-w95j.

3. **Medium — browser response protections missing.** The tested live HTML routes have HSTS, but no Content-Security-Policy, X-Frame-Options or X-Content-Type-Options headers. The HTML has no CSP meta tag either. Define and validate an application-compatible CSP with frame-ancestors and add nosniff; verify PDF workers, fonts and Supabase connections still work.

4. **Sign-off blocker — production database parity/security not established.** The configured management token returned 401 in this session. The user reported no `supabase_migrations.schema_migrations` table. Their CSV confirms seven credit-foundation object-presence checks, not complete migration coverage, bodies, grants, RLS policies, data backfills or constraints. Obtain a read-only catalog export and compare the final expected definitions, accounting for superseded migrations and intentional production changes. Do not replay all migrations blindly.

5. **Remaining financial concurrency review.** Checkout serializes against other credit checkouts, but the reviewed adjustment and reversal RPCs do not acquire the same relationship lock before changing exposure. This is a source-level concurrency concern, not a reproduced production incident. Test checkout racing with debit adjustments and reversals. Also establish and test cancellation treatment for paid amounts and reversal of cancellation credits.

## Confirmed checks

- Production `/`, `/login`, `/pharmacy`, `/wholesaler`: HTTP 200 HTML shell. This does not prove authenticated screens render correctly.
- Both tested order endpoints reject GET with 405.
- All nine staff, platform-staff and order API endpoints tested with empty unauthenticated POST requests return 401. No orders, payments, invitations or emails were created by these checks.
- Live main JavaScript asset returns 200 and contains `set_credit_status` and the suspended-credit message. This establishes feature presence, not the exact Vercel commit or deployment Ready state.
- Fresh unit suite: 284 passing tests across 31 files.
- Fresh TypeScript check and production build passed. The build warns about large bundles.
- Full `npm run lint` did not finish in the audit window and was stopped; its configuration does not exclude the local `.tmp` artifacts. Earlier targeted lint confirmed ten existing `no-explicit-any` errors in the pharmacy route. A clean full lint gate is not established.
- The narrower `eslint src api` completed with 7,919 errors and seven warnings: 7,897 formatting findings, 22 explicit-any errors, one unclassified message and hook/refresh warnings. Most findings are formatting, not demonstrated runtime defects; the source lint gate still fails. Machine-readable evidence: `.tmp/production-source-lint.json`.
- Earlier same-session validation: 43 local credit assertions and six two-session concurrency assertions passed; these are not production RLS tests.

## Required before sign-off

- Fix duplicate checkout retry behavior and verify concurrent retries.
- Resolve import dependency findings or document verified mitigations for each reachable advisory.
- Compare production catalog definitions and permissions; verify cross-tenant and suspended-account access using controlled accounts.
- Complete authenticated checkout/payment/receipt/import/RFQ smoke tests and desktop/mobile browser checks.
- Verify backups and restore rehearsal, monitoring/alert delivery, and exact deployment status.

Raw local evidence is in ignored `.tmp/production-http-audit.json`, `.tmp/production-auth-audit.json`, `.tmp/production-audit-dependencies.json`, `.tmp/production-audit-lint.log`, and `.tmp/production-audit-build.log`. No runtime fixes or production deployment were performed as part of this audit.
