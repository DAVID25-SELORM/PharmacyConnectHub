# Pay Now (online payment) with Paystack: implementation plan

Status: **decisions S1 to S8 accepted as recommended (section 3). P1 is built locally and not deployed (section 12). No key has been used.** Written after the order-amendment work (design doc
sections 1 to 22 and the [review pack](order-amendments/review-pack.md)). Test mode first; live only after the gates in section 9.

## 1. Goal and the rules this plan is built around

A pharmacy can pay a supplier order online at checkout ("Pay now"). The rules that shape every choice below:

1. **An order is paid only when the server has verified the payment with the provider.** Never because the browser came back from the
   payment page, never because a button was pressed.
2. **Duplicate, late, out-of-order and missing notifications from the provider are normal**, and must never double-pay, double-refund or
   lose a payment.
3. **Failed and abandoned payments are handled**: the order does not stay half-alive, and the stock held for it comes back.
4. **Refunds are first-class**: when an amendment or a delivery problem reduces what a paid order is worth, the difference is refunded
   through a recorded, auditable process (this also removes today's "a paid order cannot be amended" refusal for pay-now orders).
5. **Reconciliation**: our records and the provider's can always be compared, and differences surface as alerts, not surprises.
6. **Provider-neutral**: Paystack sits behind a small adapter so another provider can be added without touching orders, refunds or screens.
7. **Wholesaler order payments and platform subscription payments are separate things.** They may share the provider adapter and the
   webhook entry point, never tables, ledgers, statuses or reports. (No subscription feature exists yet.)
8. **Settlement is investigated and decided before any live money moves to a wholesaler** (section 3).
9. Money-moving code is server-side only, idempotent, and tested against failure, as for every phase of the amendment work.

## 2. What exists today (verified in the repository)

- `orders.payment_method` (enum `cod | paystack`), `orders.paystack_reference` (unique where not null) and `orders.paystack_access_code`
  already exist from the first schema; **no code calls Paystack**. `orders.settlement_method` already has `pay_now` in its vocabulary.
- Checkout **refuses** `pay_now` in two places (the `api/orders/create.ts` endpoint and the database function), and the settlement list
  shows it disabled ("Online payment isn't available yet"). Removing that refusal is the last step of this plan, not the first.
- `orders.payment_status` is `unpaid | paid | refunded | failed`; a trigger already notifies both sides when an order becomes `paid` or
  `failed` (and tells the wholesaler "Online payment received" when `payment_method = 'paystack'`).
- The cash path (`api/orders/confirm-payment.ts`, `send-receipt.ts`) and the receipt email sender (`api/_order-receipts.ts`, which already
  accepts `paymentMethod: "cod" | "paystack"`) are reusable.
- Stock is deducted **at checkout**, with evidence in `order_stock_deductions`; cancelling an order restores it. An unpaid pay-now order
  therefore **holds stock**: abandoned payments must release it (section 5.3).
- The amendment features refuse to change an order that is already paid and not on credit ("changing it needs a refund, which is not
  supported yet"). Pay-now orders are paid before the wholesaler sees them, so **today none of them could be partly supplied, repriced or
  back-ordered**. Section 6 closes that.
- Hosting is Vercel serverless functions in `api/` plus Supabase; secrets live in Vercel environment variables.

## 3. Decisions needed from you (with my recommendation)

| # | Decision | Options | Recommendation |
|---|---|---|---|
| S1 | **Who receives the money?** The most important one. | (a) The platform's Paystack account receives everything and pays wholesalers out later; (b) each wholesaler has a **Paystack subaccount** and the buyer's payment is split at the time of payment, settling to the wholesaler's bank, with an optional platform share; (c) each wholesaler brings its own Paystack account and keys | **Test mode: one platform account, no split, to prove the flow. Live: (b)**, so the platform never holds wholesalers' money. (a) means the platform holds customer funds and pays out, which may need regulatory advice in Ghana. (c) multiplies key management and support |
| S2 | Who bears Paystack's fee, and is there a platform commission? | Pharmacy, wholesaler, platform; commission yes/no | Decide with the commercial model; the design carries the fee and the split on every payment record so it can change without code changes |
| S3 | **Several suppliers in one cart** | one payment per supplier order, or one combined payment | **One payment per order** at first (simple, each order independent). A "pay all" button that runs them one after another can follow |
| S4 | How long may a pay-now order wait for payment before it is cancelled and its stock released? | 15 to 120 minutes | **30 minutes**, then cancel and release (a later successful payment is then refunded automatically, section 5.4) |
| S5 | Refund approval | automatic when an amendment reduces a paid order, or a wholesaler owner/manager approves each | **Automatic** for amendments the pharmacy accepted (the pharmacy already agreed); **manual approval** for a delivery-problem credit, since the wholesaler decides it |
| S6 | Price **increase** on an order already paid online | take a second payment ("top-up") or refuse | **Top-up payment** before dispatch; the order cannot be dispatched until paid |
| S7 | Chargebacks / disputes | out of scope for the first live pilot, or in | Out of scope for the pilot; add a "disputed" state and an alert so one is never invisible |
| S8 | Pilot | which wholesaler(s) and pharmacy(ies), what transaction limit | One wholesaler, a few pharmacies, a low per-order cap, live only after section 9 |

**What I cannot do and will not do:** I cannot enter live payment keys, and I will not see any key. You (or whoever administers the
platform) put the Paystack **test** keys in Vercel (and a local `.env` for testing) and later the live keys; I only ever read their names.
Account verification with Paystack (business registration, settlement bank account, subaccount KYC) is yours.

## 4. Design

### 4.1 Where the work lives

```
Browser ──> POST /api/payments/initialize ──> Paystack  (returns an authorization URL)
Browser ──> Paystack hosted payment page ──> back to /pay/return?reference=...
Return page ──> POST /api/payments/verify ──> asks Paystack ──> apply_verified_payment()   (server verifies)
Paystack ──> POST /api/payments/webhook  ──> signature check ──> store event ──> verify with Paystack ──> apply_verified_payment()
Scheduler ──> /api/payments/reconcile ──> verify stale attempts, expire abandoned ones, compare with Paystack's list
```

The browser never reports a result. The return page only asks the server "is this paid yet?" and shows what the database says.

### 4.2 Data (all new, none of it touches existing order behaviour)

- **`payment_provider_events`**: one row per notification received (provider, event type, a dedupe key, raw payload, `signature_valid`,
  received / processed time, outcome, error). Unique on (provider, dedupe key). Written before anything else is done with it. Neutral: also
  serves subscriptions later.
- **`order_payment_attempts`**: one row per try to pay an order: order, provider, our unique `reference`, amount asked (in cedis and the
  provider's unit), currency, status (`initiated | pending | succeeded | failed | abandoned | expired | flagged`), the provider's own
  status, the verified amount, channel, fee, provider ids, authorization URL, access code (server side only), who started it, timestamps.
  Unique on (provider, reference). An order may have many attempts but at most one `succeeded`.
- **`order_payment_log`** (append-only): every state change and decision with who or what caused it (verify, webhook, reconcile, expiry).
- **`order_refunds`**: one row per refund: order, attempt, amount, reason, source (an accepted amendment, a delivery-problem credit, a late
  payment, a manual request), status (`requested | approved | processing | succeeded | failed | cancelled`), provider refund id, who
  requested and approved, timestamps. Unique per source (an amendment, a delivery report decision) so a source can refund once.
- **`orders`**: a small additive column set (paid amount, refunded amount) or a view; `payment_status` keeps its meaning.
- RLS as for the amendment tables: admins read; the two parties read through checked functions; **no direct writes**, everything through
  `SECURITY DEFINER` functions callable by the service role only (the endpoints), plus read functions for the screens.

### 4.3 The one function that marks an order paid

`apply_verified_payment(attempt, provider payload)`, service role only, idempotent, under the order lock:

1. The attempt must exist; if already `succeeded`, return (a duplicate is a no-op).
2. The provider must report `success`, in `GHS`, for **exactly the amount asked**, with a reference matching the attempt. Anything else
   marks the attempt `flagged`, **does not** mark the order paid, writes an alert and a log entry.
3. The order must still be awaiting payment. If it was cancelled or expired meanwhile: record the payment, mark it for automatic refund
   (section 5.4), do not revive the order.
4. Otherwise: attempt `succeeded`, order `payment_status = paid` (using the existing guard conventions), `paid_at`, a timeline event, the
   existing notifications fire, and the receipt email is queued.

Verification before this call is always a fresh server-to-provider "verify transaction" request: a webhook is treated as a hint to go and
check, not as proof, even when its signature is valid.

### 4.4 Provider adapter

A small interface: `initialize`, `verify`, `refund`, `listTransactions`, `parseAndVerifyWebhook`. `PaystackAdapter` is the only
implementation now. The adapter owns the unit conversion (cedis to pesewas, with integer arithmetic and tests), reference generation,
signature verification and the mapping of provider statuses to ours. Nothing outside it knows Paystack's field names.

### 4.5 Webhooks (what the plan relies on, from Paystack's documentation and engineering guides)

- Each event carries an `x-paystack-signature` header: an HMAC-SHA512 of the **raw request body** keyed with the secret key (there is no
  separate webhook secret). Compare in constant time. The function must read the raw body (Vercel Node functions need body parsing turned
  off for this route), not a re-serialised object.
- Source IPs are published and can be allow-listed as defence in depth, never as the only check (they can change).
- Test and live have separate webhook URLs and keys; configure both.
- Retries: live mode retries every 3 minutes for the first 4 tries, then hourly for up to 72 hours; test mode hourly for 10 hours.
  **Duplicates are therefore certain**: the dedupe key plus an idempotent `apply_verified_payment` handle them.
- Answer 200 quickly; do the work after storing the event (or in the same call if it is fast), because the sender waits only about 30 seconds.
- Events used: the charge success event (payment) and the refund events. The exact event names, and what a split refund looks like, are
  to be confirmed against Paystack's current reference and with Paystack support **before** the refund phase (my searches did not settle them).

## 5. Behaviour to get right

### 5.1 Checkout and the unpaid order
Choosing "Pay now" creates the order **unpaid, with `payment_method = paystack` and `settlement_method = pay_now`**, then the page calls
initialize and sends the pharmacy to Paystack. The wholesaler sees the order marked "Awaiting online payment" and **cannot accept it**
until it is paid (a database rule, not a hidden button). A pharmacy can resume payment from its order list ("Pay now") with a **new
attempt and a new reference**; older attempts are marked expired and any success on them is still honoured if the order is unpaid.

### 5.2 Failed and abandoned
A failed attempt is shown with its reason and a retry; the order stays awaiting payment until the window ends. An attempt the pharmacy
walked away from stays `initiated` or `pending` until the reconciler verifies it (Paystack reports it as abandoned or still pending) and
expires it.

### 5.3 Expiry and stock
When the window ends (S4) with no verified payment: cancel the order through the **existing cancellation path**, so stock is restored
exactly as for any cancelled order, and notify the pharmacy. The expiry runs from the reconciler, takes the order lock, and re-checks
"still unpaid" under that lock, so a payment arriving at that instant is not lost.

### 5.4 Late payments
A verified payment for an order that has since been cancelled or expired is never ignored: it is recorded and a **refund is created
automatically** (source: late payment), the pharmacy is told, and an admin alert is raised if the refund fails.

### 5.5 Amendments, delivery problems and refunds
Define the order's **money balance** as: effective total minus paid-net (paid less refunded). Then:

- effective total below what was paid (partial supply accepted, price decrease accepted, a back-order accepted, a delivery problem credited):
  a **refund** for the difference is created from that decision (unique per decision) and executed per S5;
- effective total above what was paid (a price increase): a **top-up payment** (S6) is required before dispatch;
- a back-order shipment on a paid order needs **no new payment** (its goods were paid for; only the refund for goods that will never come
  is created at acceptance), which also removes the per-shipment cash collection need for pay-now orders.

The amendment code changes are small and additive: the refusal "an order that is already paid needs a refund" becomes "an order paid online
creates a refund for the difference"; orders paid in cash keep today's refusal until a cash refund process exists.

### 5.6 Receipts, statements, reports
A verified online payment sends the existing receipt email (payment method paystack). The statement already shows a paid non-credit order's
payment on its paid date; refunds add a dated credit/debit line. The payment reports read the order-level payment status as today; refunded
amounts are shown separately so "paid" is never overstated.

### 5.7 Reconciliation
- A scheduled job (every few minutes) verifies attempts older than a short grace period that are not final, expires abandoned ones, and runs
  the order expiry of 5.3.
- A daily comparison lists Paystack's transactions and refunds for the day against ours: **unknown to us**, **ours but unknown to Paystack**,
  **amount or status mismatch**, **paid at Paystack but not applied**. Each becomes an alert on an admin "Payments" screen with a
  one-click "re-verify". Nothing is auto-corrected except through `apply_verified_payment`.

## 6. Security and operations

- Secret keys only in server environment variables, test and live in separate environment scopes; the code refuses to start a payment if
  the key prefix does not match the configured mode (a live key in test mode, or the reverse), and live mode needs an explicit second switch.
- No card or mobile-money data ever reaches our servers or logs (the hosted payment page takes it). Logs carry references, never keys or
  full payloads in clear text outside the stored event rows.
- Every endpoint re-checks the caller's permission on the order (pharmacy owner, manager or cashier may pay; nobody can pay or look at
  another business's order), recomputes the amount **on the server from the order's effective total** (the browser never sends an amount),
  and rate-limits initialize.
- Refund and webhook routes are server-to-server only; admin screens are admin-only.
- Alerts: signature failures, flagged attempts, refunds failing, paid-but-not-applied, daily reconciliation differences.

## 7. Testing plan

- **Unit**: pesewa conversion and rounding, reference generation, HMAC verification (valid, tampered, wrong key, re-serialised body),
  status mapping, the state machine, the money-balance arithmetic.
- **SQL suite and concurrency scripts** (as for the amendment phases, with negative controls and mutation checks): `apply_verified_payment`
  (success, duplicate, wrong amount, wrong currency, cancelled order, expired order), at most one success per order, webhook racing verify,
  two simultaneous initiates, expiry racing a payment, refund uniqueness per source, stock restored on expiry, existing suites unchanged.
- **Handler tests** against the real endpoint code with a stubbed provider, including signed webhooks built with our own HMAC and recorded
  Paystack payload fixtures; the receipt handlers are tested the way `cash-receipts-api.local.mjs` tests the cash ones.
- **Browser** per role on the local stack with the provider stubbed (checkout, pay, return page, resume, expiry, amendments on a paid order).
- **Paystack test mode end to end**: real test cards and test mobile-money flows from Paystack's test documentation, a public tunnel or a
  Vercel preview URL for webhooks, and deliberate failures (declined, abandoned, closed tab, duplicate and delayed webhook, wrong amount).
- **Regression sweep** after each phase, as before.

## 8. Phases

| Phase | Deliverable | Gate |
|---|---|---|
| **P0** | Decisions S1 to S8; Paystack test keys placed in Vercel / local env by you; chosen test webhook URL | Your confirmation |
| **P1** | Schema, provider adapter, webhook ingest (store, verify signature, no effect yet), `apply_verified_payment`, unit and SQL suites. No screen, no checkout change | New suites + full regression |
| **P2** | `initialize`, `verify`, return page, "Pay now" in checkout **behind a test-mode-only flag**, awaiting-payment rule for the wholesaler, resume payment | Browser run per role + Paystack test mode end to end |
| **P3** | Reconciler job, expiry and stock release, late-payment handling, alerts, admin Payments screen | Failure-injection run |
| **P4** | Refunds and amendment integration (paid orders amendable; top-up payments), refund screens | Amendment suites re-run on paid orders |
| **P5** | Settlement per S1 (subaccount creation and onboarding, split on initialize), refund-with-split behaviour confirmed with Paystack, live-readiness review (security, limits, runbooks, a rollback switch like the amendment switches) | **Your review; nothing live before it** |
| **P6** | Live pilot per S8 | Pilot review |

Each phase ends with a report and waits for your "commit and push", and nothing reaches production before the implementation and
regression tests have been reviewed. Migrations are applied by you in the SQL Editor, as before.

## 9. Gates before live money

1. S1, S2 and S4 to S8 decided in writing; Paystack business verification complete; subaccounts (if S1b) onboarded.
2. P1 to P4 reviewed; the full regression sweep and all payment suites green; the Paystack test-mode run recorded.
3. Refund-with-split behaviour confirmed with Paystack support in writing; the Paystack event names used by the code confirmed against their
   current reference.
4. A kill switch (in the style of `docs/order-amendments/switches/`) that stops new payments without touching in-flight ones, and a runbook
   for: a webhook outage, a stuck attempt, a wrong-amount flag, a failed refund and a reconciliation difference.
5. Live keys set by you in the live environment scope only; the live webhook URL configured in Paystack's live settings.

## 10. Out of scope for now

Platform subscription billing (separate tables and screens, built later on the same adapter and webhook entry point), other providers, saved
cards and recurring payments, payouts from the platform to wholesalers (only relevant under S1a), chargeback handling beyond an alert, and
cash refunds.

## 11. Risks I want you to see

- **S1** is a business and regulatory choice before it is a technical one; a wrong answer is expensive to change after launch.
- **Refunds on split payments**: how Paystack debits the subaccount versus the main account is not settled by anything I could find; it
  decides how P4 and P5 are built and must be confirmed with Paystack first.
- **Stock held by unpaid orders**: a short window protects stock but may cut off slow mobile-money payments; S4 balances the two, and late
  payments are refunded rather than lost.
- **Existing refusals** (paid orders cannot be amended) are safe today and become lifted only in P4, behind tests.
- Webhooks and the scheduler run on Vercel; a long outage of either is covered by the reconciler, but needs an alert so it is noticed.

Sources for the Paystack facts above: [Paystack webhooks documentation](https://paystack.com/docs/payments/webhooks/), [Paystack accept
payments](https://paystack.com/docs/payments/accept-payments/), [Paystack multi-split payments](https://docs-v2.paystack.com/payments/multi-split-payments),
[Hookdeck's Paystack webhook guide](https://hookdeck.com/webhooks/platforms/guide-to-paystack-webhooks-features-and-best-practices) and
[Paystack's help centre on transaction splits](https://support.paystack.com/en/articles/2132802). The official pages could not be fetched
directly from this environment, so the retry timings, IP list and fee-bearer options come from search summaries of those pages and must be
re-read on Paystack's site before P1 starts.

## 12. P1 status (built locally, not deployed): the provider-neutral core

**Decisions:** S1 to S8 were accepted exactly as recommended in section 3: one platform Paystack account in test mode (subaccounts with
splits for live); one payment per supplier order; unpaid pay-now orders cancelled and their stock released after 30 minutes; refunds
automatic for accepted amendments and manual for delivery-problem credits; a top-up payment for a price increase on a paid order;
chargebacks out of the pilot (alert only); pilot with one wholesaler and a low cap.

**What P1 contains (no screen, no checkout change; nothing a user can reach):**
- **Migrations** `20261106100000_payments_core_schema.sql` and `20261106110000_payments_core_workflow.sql`: `payment_provider_events` (every
  notification stored once, before anything else is done with it), `order_payment_attempts`, `order_payment_log` (append-only), and three
  service-role-only functions: `record_payment_provider_event`, `finish_payment_provider_event`, and **`apply_payment_result`**, the one function
  that can mark an attempt and an order paid.
- **`apply_payment_result` decides** (all under the order lock, idempotently): an unknown reference does nothing; a result from the other mode is
  refused; a repeat changes nothing; failed / abandoned / pending are recorded and leave the order alone; a success is applied **only** if the
  currency and the exact amount match, the order is an online order, its total has not changed, it is not cancelled and not already paid.
  Otherwise it is **flagged** (a person must look), or recorded as a **late payment** (order cancelled: money received, refund required, the order
  is never revived) or a **double payment** (already paid: refund required). At most one attempt per order can ever be the paying one (a database
  index, not only the function).
- **Cancelling an order that was paid online** marks the paying attempt refund-required (a trigger), so money is never held silently.
- **Adapter and endpoint** (`api/_payments/`, `api/payments/webhook.ts`): the Paystack adapter (exact pesewa conversion that refuses fractions of a
  pesewa, references, HMAC-SHA512 verification of the raw body in constant time, initialize / verify / list-transactions calls, status mapping), the
  settings loader (payments are off unless `PAYMENTS_MODE` is `test` or `live`; the key's prefix must match the mode; live needs a second switch,
  `PAYMENTS_LIVE_ENABLED=yes`), and the webhook handler: it checks the signature, ignores the other mode's events, stores the notification, then **asks
  Paystack what happened** and applies that, never the notification's own claim. A failure answers 500 so Paystack retries, which is safe.
- **Nothing is reachable until you set** `PAYMENTS_MODE=test` and `PAYSTACK_SECRET_KEY` (a test key) in the server environment: until then the
  endpoint answers 503 and the database functions are not callable by any user.

**Findings while building it that affect later phases:**
- Production's order guard forbids changing `payment_method` after an order is placed, so P2's checkout must create pay-now orders as online
  orders from the start (the tests switch that guard off for their fixtures only).
- The site's content-security policy allows a redirect to Paystack's hosted page (navigation is not restricted by it); an in-page Paystack popup
  would need the policy loosened, so P2 uses the redirect flow.
- The raw request body is needed for the signature. The handler reads it from the request stream without touching `req.body`; this was verified with
  a real Node HTTP server, but must be verified once on Vercel itself (a signed test request to a preview deployment) before P2 relies on it.
- Strict type-checking of the `api/` folder (which the main `tsc` does not cover) shows older errors in `api/platform-staff/*` that predate this work;
  the payment code and the receipt endpoints are clean.

**Verified:** `payments-core.sql` 63/63 (permissions, duplicate notifications, exact-amount rule, wrong currency, failed / abandoned / pending, a
failed attempt that later succeeds, late and double payments, a changed order, an ordinary cash order refused, cancellation after payment,
append-only records); `payments-core-concurrency.sh` 9/9 with a negative control (webhook and verify at once, a customer paying twice, cancellation
racing a payment); mutation checks PM1 to PM5; `payments-webhook-api.local.mjs` 17/17 (the real handler behind a real HTTP server with real
signatures); 483 unit tests including 39 for the adapter, settings and handler; lint clean.

**Next (P2):** `initialize`, `verify`, the return page, "Pay now" in checkout behind a
test-mode-only flag, the rule that a wholesaler cannot accept an unpaid online order, and resuming payment.

## 13. P2 status (built locally, not deployed): paying for an order

**Built without Paystack credentials.** You had no Paystack keys yet, so P2 was built and tested against a stand-in for Paystack (`tests/local-supabase/fake-paystack.mjs`:
the same initialize and verify calls, a checkout page with Pay / Decline / Close buttons, the redirect back, signed notifications). It is **off by default
in production** and nothing changes for any user until two things are both switched on (below). What has *not* been exercised is the real Paystack test
environment: that waits for your test keys (`PAYMENTS_MODE=test`, `PAYSTACK_SECRET_KEY=sk_test_...`) and is the first thing to do once you have them.

**The two switches (both must agree before anything works):**
1. **The platform switch in the database**, `payments_settings` (created OFF, test mode). Changed only by running a script in the SQL Editor
   (`docs/payments/switches/enable-online-payments-test-mode.sql`, `disable-online-payments.sql`); no screen and no API can flip it.
2. **The server environment** (`PAYMENTS_MODE`, `PAYSTACK_SECRET_KEY`; live also needs `PAYMENTS_LIVE_ENABLED=yes`). The key's prefix must match the mode.
   The database's mode and the server's mode must also match, or a payment cannot start.
Either one off: checkout refuses Pay now with the old message ("Online payment is not available yet. Choose another payment method."), the option shows
disabled with the same words, and no payment can be started. Payments already in flight are still verified and recorded when the provider confirms them.

**What P2 contains:**
- **Migrations** `20261107100000_payments_checkout_schema.sql` (the switch table and its two read functions), `20261107110000_payments_checkout_patches.sql`
  (fail-closed, re-runnable in-place patches, each of which refuses to change anything if the live definition is not what was expected) and
  `20261107120000_payments_checkout_workflow.sql` (starting a payment, the payment summary and the acceptance block). The patches: checkout accepts
  `pay_now` only while the switch is on and stores such an order as an online order (`payment_method = 'paystack'`, unpaid, pending, stock reserved);
  the wholesaler is **not** told about an online order when it is placed, only (as "New paid order") when it is paid; an online order's payment method
  cannot be changed afterwards; a repeated "abandoned" or "failed" report of an unchanged attempt is not logged again.
- **Starting a payment (`begin_order_payment`, server only):** checks the platform switch and mode; under the order lock requires an online, unpaid,
  not-cancelled order and a caller who may place orders for that pharmacy (owner, manager or cashier); takes the amount from the order (never from the
  browser); resumes a recent attempt for the same amount (25 minutes), otherwise closes older open attempts and records a new one; at most six attempts per
  order per hour. A payment that arrives later on a closed attempt is still verified and applied (and a second payment for the same order is flagged for
  refund), as in P1.
- **Acceptance block:** a trigger refuses to move an unpaid online order out of "pending" (accept, pick, pack ...). Cancelling it is still allowed by either
  side and returns its stock through the existing cancellation path. Once paid, the order is accepted like any other.
- **Endpoints:** `POST /api/payments/initialize` (start or resume; returns only the provider's checkout address) and `POST /api/payments/verify` (the return
  page's call: asks Paystack about the order's last three attempts and records the answer through `apply_payment_result`; it never trusts the redirect).
  `/api/orders/create` accepts `pay_now` only when the server is configured for payments and returns the orders now waiting for payment.
  The return address is built from the site's configured address (`SITE_URL`), never from request headers.
- **Screens:** "Pay now (online)" in the cart (enabled only while online payments are on, with a test-mode note); after checkout the customer is sent to
  the provider's page (one order) or told to pay each order from "My orders" (several); the pharmacy's order card shows "Awaiting online payment" and a
  **Pay now** button; the wholesaler's card shows "Awaiting online payment" and "Waiting for the pharmacy's online payment" instead of an Accept button; a
  cancelled unpaid online order reads "Not paid". New page `/pay/return`: asks the server to verify, keeps asking for about two minutes, and shows paid /
  waiting / failed / "we need to look at this" / "we could not check just now"; it never marks anything paid itself.
- **Local tools** (not shipped to production): `fake-paystack.mjs`, `dev-api-server.mjs` (serves the real `/api` handlers; Vite does not) and an optional
  `DEV_API_PROXY` setting in `vite.config.ts` that forwards `/api` to it for browser testing. `PAYSTACK_BASE_URL` redirects the server to the stand-in; it is honoured
  only in test mode and only for a local address, so a typo can never send the secret key to another host.

**Verified locally:** `payments-checkout.sql` 101/101; `payments-checkout-concurrency.sh` 9/9 with a negative control; `payments-checkout-api.local.mjs` 41/41
(the real handlers behind a real HTTP server, real sessions and the fake Paystack); 32 new handler unit tests; the P1 suites unchanged (63, 9, 17); mutation
checks (each safeguard removed makes the suite fail); the whole flow driven in the browser: cart, Pay now, the provider page, close without paying (not paid,
Pay now offered), pay (webhook applies it, the return page says "Payment received"), and the pharmacy's and wholesaler's order lists.

**Known gaps, all deliberate, all gates before any live money (none matters in test mode):**
- **Stock is held by an unpaid online order until it is paid or cancelled.** The 30-minute expiry that releases it is P3.
- **Amendments on a paid online order** (a short supply or a price change after payment) change what the order is worth but nothing yet refunds the
  difference. Refunds and top-ups are P4. Until then online orders must not be used for real money.
- **Reports** that count unpaid orders (the admin payments report, the supplier's customer list) will count an order awaiting online payment as unpaid;
  P3 separates "awaiting online payment" from "unpaid".
- **Late and double payments** are recorded and flagged (P1), but no person is alerted yet and there is no admin screen: P3.
- Verified with the stand-in, not with Paystack: the exact shape of Paystack's answers (initialize, verify, the `charge.success` notification and its
  signature header). Those follow Paystack's published documentation as of the P1 build; the first run against real test keys is the check.
- The verify endpoint is limited only by authentication and ownership (it asks Paystack about the caller's own order's last three attempts per call, and the return
  page calls it every four seconds for about two minutes). A per-order throttle is added with the reconciler in P3.

**Production finding when the P2 patches were first applied:** production has a second, older version of `create_marketplace_orders` (`_caller_id, _pharmacy_id, _items, _request_id`) that exists in no migration (service role only; the app does not call it). The checkout patches now name the exact argument list of the live six-argument version and change only that one (`apply_function_regex_patch_sig`), and refuse if it is missing or unexpected. A marker bug was also found and fixed (the settlement-change patch could insert its check again on every re-run). The stray older version has not been touched; whether to drop it is a separate decision once its definition has been reviewed.

## 14. P3 status (built locally, not deployed): operating it

**Decisions as accepted in section 3 (S4):** an unpaid online order is cancelled and its stock released **30 minutes after its last payment attempt started** (or after it
was placed, when none was started), and in any case 2 hours after it was placed. Every "Pay now" press restarts the 30 minutes, so a customer who is still on the provider's page
is not cancelled underneath; the 2-hour cap stops that from going on for ever.

**What P3 contains (online payments are still off by default; nothing here does anything while there are no online orders):**
- **Migrations** `20261108100000_payments_operations_schema.sql` (alerts table, `last_checked_at` / `check_requested_at` on attempts) and
  `20261108110000_payments_operations_workflow.sql` (the functions below). All of it is service-role or admin only.
- **Alerts** (`payment_alerts`): one open alert per problem (a repeat only counts it), never rewritten, never deleted, a resolved one is never reopened (a returning problem gets a new
  one). A flagged payment or money that must be refunded raises one automatically, whichever path recorded it (webhook, return page, reconciler, admin), tells the platform
  administrators, and tells the pharmacy ("do not pay again", promising nothing the system does not yet do). An alert about a payment closes by itself when that payment is applied.
- **The reconciler** (`/api/payments/reconcile`, called by a scheduler with `CRON_SECRET`): *frequent* (every ~5 minutes) asks the provider about attempts that could still turn out to have
  been paid (open ones every few minutes, closed or abandoned ones hourly, for 48 hours: this is how a late payment is found even when its notification never arrives), applies
  the answers through `apply_payment_result`, closes attempts open for 48 hours, and expires orders; *daily* lists the provider's transactions for the last 25 hours and compares them with ours
  (unknown at the provider, amount or status differences, paid at the provider but not applied, ours but missing there). Anything paid at the provider but not applied is verified and applied
  through the same function; **nothing is corrected any other way.**
- **Expiry safety:** an order is expired under its lock, re-checked as still unpaid and pending, and **never while one of its attempts could still be paid and has not been checked
  with the provider recently** (15 minutes for an open attempt, 70 for a closed one). The rule lives in the database, so a provider outage or a missed run cannot cancel an order that was in fact
  paid: it raises "Order kept open" instead. Expiry skips an order that is locked by a payment being recorded (it does not wait), so a payment and an expiry racing each other end with a paid
  order, never a cancelled paid one.
- **The return page** can no longer hammer the provider: each attempt is asked about at most once every 3 seconds; a faster request is answered "still waiting" without calling it.
- **Admin > Payments** (`/admin/payments`): counts (needing attention, refunds needed, awaiting payment, paid in 24 hours), the open alerts with **Re-verify** (asks the provider again about an
  order's attempts, recorded the same way as everywhere) and **Mark as dealt with** (a note is required, and it is audited), recently resolved alerts, and the recent attempts. It moves no money.
- **Docs:** `docs/payments/scheduling-the-reconciler.md` (what to schedule, how, and what happens without it), `docs/payments/runbook.md` (each alert and each situation: webhooks not arriving,
  a payment that is stuck, a late payment, the reconciler not running), `docs/payments/verify-payments-p3.sql` (read-only production check).

**Not scheduled yet, on purpose:** the reconciler is **not** in `vercel.json`. On Vercel's Hobby plan only once-a-day cron jobs are allowed and a disallowed schedule makes the deployment fail; whether
you are on Pro decides. See the scheduling document. Until it is scheduled, unpaid online orders hold their stock until cancelled by hand, and a lost notification is only found when the customer returns or an
administrator presses Re-verify.

**Verified locally:** `payments-operations.sql` 86/86; `payments-operations-concurrency.sh` 13/13 with a negative control (removing the lock makes a paid order get cancelled and its stock come back twice);
`payments-operations-api.local.mjs` 27/27 (the real handlers behind a real HTTP server with the fake Paystack, with failures injected: a notification that never arrives, an abandoned order, the
provider down, a payment after the order expired, a payment the provider has and we do not, an administrator's re-verify, the return page's throttle); 21 more handler unit tests (92 in all); eight
mutation checks (each safeguard removed makes the suite fail); the admin screen driven in the browser (counts, alerts, resolving with a note, Re-verify).

**Known gaps (unchanged by P3 unless stated):**
- **Refunds are still done by a person** in the Paystack dashboard; the alert tells the administrator exactly what to refund. Automatic refunds, refunds when an amendment lowers the price or supply of a
  paid online order, and top-up payments are P4. Online orders must still not be used for real money before then.
- The admin payments report and the supplier's customer list still count an order awaiting online payment as unpaid. Left alone deliberately: patching those two production functions carries risk for
  little value while online payments are in test mode.
- Verified with the stand-in, not with Paystack: the shape of its transaction list (the daily comparison) as well as initialize, verify and the notification. The first run against real test keys is the check.
- The daily comparison reads at most 2,000 transactions (20 pages of 100); with more, it says the list is incomplete and does not judge "ours but missing at the provider".

## 15. P4a status (built locally, not deployed): moving money back

P4 is split in two, as the amendment work was. **P4a (this section)** is the refund machinery and the refunds that are not in doubt (a payment after the order was cancelled, a second
payment for the same order, an order cancelled after it was paid). **P4b** (not started) connects it to amendments: refunding the difference when an accepted amendment lowers a paid online
order, and a top-up payment when a price rises.

**What P4a contains (online payments and refunds are still off by default; nothing here does anything while there are no refunds):**
- **Migrations** `20261109100000_payments_refunds_schema.sql` (the refund ledger, the `auto_refunds` setting, three new alert kinds) and `20261109110000_payments_refunds_workflow.sql` (the functions below). They patch no existing
  production function (only functions and views made in P2 and P3 are replaced), so there is no production-drift risk like the one found in P2.
- **The ledger** (`order_refunds`): one row per refund: the payment attempt being refunded, amount, reason, status, who approved it. Unique per *source* (for example "the full refund of attempt X"), so the same reason can never refund the
  same money twice, and **the refunds still alive for a payment can never add up to more than that payment received** (enforced in the function under the payment's lock *and* by a database trigger). Never edited (what it is
  for) and never deleted.
- **When a refund is requested:** automatically, the moment a payment is marked as one that cannot stay (late, double, or the order was cancelled after it was paid), whichever path recorded it. A partial refund can also be requested for a payment that stays valid (this is what
  P4b will use).
- **Approval:** every refund waits for a platform administrator **unless** `payments_settings.auto_refunds` is on (off by default; switched in the SQL Editor with `docs/payments/switches/`). Even with it on, only refunds that are not in doubt are approved
  automatically.
- **Sending:** an approved refund is *claimed* by exactly one worker (`submitting`) and sent to Paystack with the payment's own reference and the amount in pesewas, by the reconciler or immediately when an administrator approves it. The provider's answer
  is recorded: accepted -> `processing`; the real outcome arrives by a signed notification (`refund.processed` -> refunded, `refund.failed` -> failed, `refund.needs-attention` -> checked by a person).
- **The rule that matters most: an uncertain request is never retried by the system.** If it is not certain that Paystack received the request (no answer, a timeout, a server error, or the answer could not be written down) the refund becomes `unknown`
  with a critical alert saying to check Paystack's dashboard first; a refund stuck mid-send for 15 minutes becomes `unknown` too. Only a clear refusal (Paystack answered with a 4xx) makes it `failed`, which an administrator can retry. This is what prevents refunding a customer twice.
- **Administrator actions** (Admin > Payments > Refunds, `/api/payments/admin-refund`): approve and send, retry a failed one, cancel, *confirm as refunded by hand* (after checking the dashboard; a note is required), or *mark as not sent*. All audited. They move no money except through the same sending code.
- **When money comes back:** the order becomes "refunded" once an order that was paid and is cancelled has had everything returned; the alerts about it close by themselves; the pharmacy is told ("it can take several business days to reach your account"). A late or double payment's refund leaves the order as it was (cancelled/unpaid, or paid).
- **Notifications from Paystack that match nothing** (for example a refund made by hand in the dashboard) raise an alert and change nothing; one whose amount is stated in other units still matches when exactly one refund of that payment is in flight.
- **Overdue refunds raise alerts:** waiting for approval over a day, approved but not sent for hours (is the reconciler running?), processing for ten days.
- **What the two parties see** (pharmacy and wholesaler order cards, a small "Online payment" panel): what was paid, what was refunded, and any refund in progress, in plain words. The admin overview lists refunds with their actions.

**Paystack facts used, and how sure they are.** From Paystack's published documentation as found on 2026-10-10: `POST /refund` takes the transaction (our reference) and an optional amount in the smallest unit (no more than the original); the answer says the refund was queued, the real outcome comes later as
`refund.pending`, `refund.processing`, `refund.processed`, `refund.failed` and `refund.needs-attention` notifications (the notification carries the payment's `transaction_reference`); refunds are possible only within 180 days of the payment. **Not confirmed:** the exact fields of the refund notifications (so parsing is tolerant, and a
notification is matched by the payment's reference and, when stated, the amount), the full list of status words in the answer, whether `currency` and `merchant_note` are accepted on the request (if Paystack rejected them the refund would simply fail and show the reason), and how a refund behaves for a payment that was split between accounts (P5). A refund the system could not match is an alert, and an administrator can always confirm one by hand after looking at the dashboard.

**Verified locally:** `payments-refunds.sql` 85/85 (every state and transition, the cap, the same source twice, partial refunds, unmatched / other-mode / wrong events, stale refunds, who can see and do what, mutation checks: the cap, the claim, automatic approval, definite versus uncertain, the administrator check, the "refunded" order, the half-sent flag);
`payments-refunds-concurrency.sh` 12/12 with negative controls (two workers claiming, a notification racing a manual confirmation, racing requests that would exceed the payment, cancel racing send); `payments-refunds-api.local.mjs` 30/30 (the real handlers, real sessions and the fake Paystack: a paid order cancelled then refunded, a late payment auto-refunded by the reconciler,
a refusal retried, a lost answer never sent twice, a refund confirmed by hand, an unmatched and a forged notification); 47 more unit tests (118 in the payments folder, 566 in all); lint, type-check; the admin Refunds section and the order panel driven in the browser.

**Known gaps:**
- **Amendments on a paid online order (P4b):** an accepted short supply or price change still does not refund the difference, and a price rise cannot be topped up. Online orders must not be used for real money before P4b.
- A delivery-problem credit on a paid online order is not yet turned into a refund (P4b); it will wait for approval like the others.
- The first run against real Paystack test keys is still the check for everything above.

## 16. P4b status (built locally, not deployed): amendments on an order paid online

**What P4b does:** a supply change, a price change, or a delivery-problem credit can now be made on an order that was **paid online** (until now the "already paid, needs a refund" refusal blocked all of them). The money follows one rule that
lives in the database, so no screen can skip it:

> what the order costs now (its effective total) **versus** what has been paid for it and not given back (the payments that stay valid, top-ups included, less the refunds still alive)

- It now costs **less**: the difference is **refunded** (a refund request: approved by an administrator unless automatic refunds are on; a **delivery-problem credit always waits for an administrator**, even with automatic refunds on, as decided in S5).
- It now costs **more**: the pharmacy must pay the difference (a **top-up**, S6) and the order **cannot be dispatched** until it is paid. Preparing it (picking, packing, ready for dispatch) is not blocked.
- A price that **rises again while a refund for an earlier reduction has not been sent yet** nets it off: that refund is cancelled automatically and replaced by one for what is still due, so the pharmacy is never refunded and charged for the same money.

**What it contains:**
- **Migrations** `20261110100000_payments_adjustments_schema.sql` (a payment attempt now has a *purpose*: `order` or `top_up`; the one-paying-attempt rule applies to `order` only), `20261110110000_payments_adjustments_workflow.sql` (the balance, the trigger that settles the difference whenever an
  online paid order's effective total changes, the dispatch block, starting and applying an extra payment, the admin balance tools, the refreshed summary) and `20261110120000_payments_adjustments_patches.sql` (seven fail-closed, exact-signature patches: the "already paid" refusal no longer
  applies to an online order in `propose_partial_fulfilment`, `propose_price_amendment`, `respond_to_price_amendment` and `resolve_delivery_report`; a delivery credit is marked so its refund waits; `apply_payment_result` hands an extra payment to its own rules).
  **Run `docs/payments/inspect-amendment-functions.sql` in production first** (a read-only dry run that shows whether production has exactly the text the patches look for, as it did not for `create_marketplace_orders` in P2).
- **An extra payment** (`begin_order_topup`, `/api/payments/initialize` with `purpose: "top_up"`): same checks as paying an order (the platform switch and mode, who may pay, the amount taken from the database, resumed within 25 minutes, six an hour), but only for a paid, not-cancelled online order with something due, and for exactly what is due.
  Verified like every payment; judged by its own rules: an extra payment of the wrong amount, for an amount that no longer matches what is due (the price changed again), for an order whose price came back down (nothing due), or for an order cancelled meanwhile is **flagged and refunded**, never kept silently. The return page asks the server to verify, and an order that owes an extra payment is **not** reported paid until it is.
- **Back-orders are not available on an order paid online (yet):** "accept and back-order the rest" is refused with a clear message (cash orders collect each portion on its own, which does not fit an order paid in advance). The pharmacy can accept the shortage and have the rest cancelled (with a refund), or reject it. A rejected change leaves everything as it was.
- **A refund that was cancelled** leaves an order costing less than was paid with no refund on the way: the reconciler flags it, and an administrator can ask for the difference to be refunded (`admin_request_balance_refund`).
- **Screens:** the pharmacy's order card shows "A price change means this order now costs GH₵ X more" with a **Pay GH₵ X now** button (a top-up); the wholesaler's card says it is waiting for that payment and cannot be dispatched until it is paid; the existing "Online payment" panel shows paid, refunded and refunds in progress. The return page remembers it was an extra payment (retry works).
- **Cash and credit orders are unchanged:** a paid cash order still cannot be amended (no cash refunds), and the money rule ignores any order not paid online.

**Verified locally:** `payments-adjustments.sql` 72/72 (shortage refunded, automatic approval, a delivery credit that always waits, price decrease refunded, price increase and the dispatch block, every way an extra payment can be started or refused, every way one is flagged or late, back-orders refused,
netting of unsent refunds, an unrefunded balance, cash orders unchanged, permissions; seven mutation checks, all caught); `payments-adjustments-concurrency.sh` 6/6 (an extra payment racing a further price change, in both orders); `payments-adjustments-api.local.mjs` 26/26 (the real handlers, real sessions, the fake Paystack and the
real amendment functions called as the screens call them: a shortage refunded end to end, back-order refused, a price increase blocked from dispatch until paid, the extra payment found by return and by notification alone, a wrong-amount extra payment flagged); 7 more unit tests (125 in the payments folder);
the P1 to P4a suites unchanged; lint, type-check.

**Known gaps:**
- **Back-orders on an order paid online** (above), and **returns of goods** on a paid online order (an order return is separate from a delivery credit and has not been connected to refunds).
- **A refund is only as good as Paystack's refund** (see section 15): the first run against real test keys, including a refund of a payment that has had a top-up, is still the check.
- **Several refunds of one payment** (a shortage, then a price drop) are individual Paystack refunds of that payment; Paystack's rules for multiple partial refunds were not confirmed.
- Real money must still wait for the scheduled reconciler and the real Paystack test-mode run.

## 17. P5 status (built locally, not deployed): settlement and going live

**Decision carried out (S1b, as accepted):** in live mode each payment is split at the moment of payment, so a supplier's share settles to the **supplier's own** bank or mobile-money account and the platform never holds suppliers' money. In test mode the platform's own account can still receive everything (`split_mode = 'none'`), so the flow can be proved without any supplier accounts.

**What it contains:**
- **Migrations** `20261111100000_payments_settlement_schema.sql` (settings: `split_mode`, `platform_fee_bps`, `fee_bearer`, `max_order_ghs`, `split_refunds_confirmed`, the reconciler's last-run times; the `supplier_payout_accounts` table; a payment's recorded split and `prepared_at`, never changed once written), `20261111110000_payments_settlement_workflow.sql` (the functions below) and `20261111120000_payments_settlement_patches.sql` (one fail-closed, exact-signature patch of the six-argument `create_marketplace_orders`: checkout refuses "Pay now" for a supplier that cannot take online payments yet). **Run `docs/payments/inspect-settlement-functions.sql` in production first** (read-only; the lesson of P2 and P4b).
- **Supplier settlement accounts** (administrator only; Admin > Payments > "Supplier settlement accounts"): the server creates the account at Paystack (`POST /subaccount`, platform default share 0), the record is made *first* (it also refuses a second account for the same supplier and mode) and finished with the answer. A refusal is recorded as failed with Paystack's reason; a **lost answer** is recorded as failed with a warning to look at the Paystack dashboard before trying again (it may have been created). **The full account number is sent to Paystack once and appears nowhere else** (not stored, not logged, not returned; only the last four digits are kept). An account can be switched off (new payments for that supplier are refused) and on.
- **The last check before the provider** (`prepare_attempt_for_provider`, called by the server between starting a payment and asking Paystack): the **per-payment limit** (pilot cap), that the supplier can receive money online, and **what the payment is split with** (the supplier's subaccount, the platform's share = `floor(amount x commission)` in pesewas, who bears Paystack's fee). It is recorded on the payment and never changes afterwards, even if the commission is changed later. While a split or a limit is set, a payment that did not pass this check **cannot be given a checkout address** (defence in depth). A refusal closes the attempt and reaches the person in plain words.
- **Checkout** disables "Pay now" for a supplier without an active settlement account and for an order over the limit (with the reason), and the database enforces the supplier rule again at checkout (the patch) and both rules before the provider.
- **Refunds of a split payment never approve themselves** until a person records (`docs/payments/switches/confirm-split-refunds.sql`) that Paystack has confirmed in writing how it takes them (section 11). A delivery credit already always waited.
- **Settlement report** (Admin > Payments > "What should settle"): per supplier and mode, for 24 hours, 7 or 30 days: received, platform share, refunded, **to settle** (an estimate, before Paystack's fees) and **money that was not split** (should be nothing in live mode), for comparison with Paystack's own settlement report.
- **Going live:** `payments_readiness()` (shown on the same screen, with the server's own checks: mode, key kind, live switch, scheduler secret, site address, no local stand-in; yes/no only, never a value) lists what stands between the platform and live money. **The database refuses to switch live payments on** (`trg_payments_settings_live_guard`) while any blocking item is unmet: payments split to suppliers, a limit set, the reconciler ran in the last 30 minutes, a live settlement account exists, Paystack's split-refund behaviour is confirmed, no critical alert is open. While live, the split and the limit cannot be removed; **turning payments off is never blocked** and the reconciler's own timestamps never trip the guard. `docs/payments/switches/` has the scripts: `set-split-and-limit.sql`, `confirm-split-refunds.sql`, `enable-online-payments-live.sql`, and the existing off switch.
- **The reconciler notes that it ran** (even while online payments are off), so "is the scheduler alive" can be checked before going live.
- **One new endpoint file:** `api/payments/admin-payout.ts` (settlement accounts and the server checks). **Function count:** `api/` now has 16 endpoint files, above the 12 allowed on Vercel's Hobby plan. Production has been deploying the earlier payment endpoints (15 files), so the account is presumably not on Hobby, but this has not been confirmed: check the plan before relying on it.

**Verified locally:** `payments-settlement.sql` 120/120 (defaults change nothing; the limit; account lifecycle, immutability and history; who is ready; checkout refusal and acceptance; the split recorded, idempotent and immutable; commission and bearer; mode separation; refunds of split payments waiting; the live guard in every direction, the kill switch always working; readiness; the settlement report; permissions; nine mutation checks, all caught); `payments-settlement-concurrency.sh` 7/7 (two administrators creating one account; a retry racing the first preparation; negative control: removing `FOR UPDATE` in `prepare_attempt_for_provider` fails scenario 2); `payments-settlement-api.local.mjs` 36/36 (the real handlers, real sessions, the fake Paystack, which now takes subaccounts, lists banks and records exactly how each payment was split); 23 more unit tests (156 in the payments folder); the earlier phases unchanged; lint, type-check.

**What I could not confirm and you must (these are the real gates):**
1. **Paystack's subaccount and split fields.** The code sends `subaccount`, `transaction_charge` (the platform's share in pesewas) and `bearer` on `transaction/initialize`, and `business_name`, `settlement_bank`, `account_number`, `percentage_charge: 0` on `subaccount`, from what Paystack's reference says; none has been run against Paystack. The first real test-mode run must create a subaccount and make one split payment and check the amounts on the dashboard.
2. **How Paystack refunds a split payment** (section 11). Until confirmed in writing, refunds of split payments are manual.
3. **Whether a charge of zero is honoured** as "no platform share" (the account is created with 0%, so either reading gives the same result).
4. **Paystack business verification and each supplier's KYC** (yours), and the **commercial choices** (commission, who bears Paystack's fee; the defaults are no commission and the supplier bears the fee, so the platform's share is never negative).

**Known gaps:** a supplier cannot yet see its own settlement status (administrator only); settlement is *reported*, not reconciled against Paystack's settlement API; payouts, chargebacks and the live pilot itself (P6) are not built; and real money still waits for the scheduled reconciler and the real Paystack test run.
