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

**Next (P2), once you have put a Paystack test key in the environment:** `initialize`, `verify`, the return page, "Pay now" in checkout behind a
test-mode-only flag, the rule that a wholesaler cannot accept an unpaid online order, and resuming payment.
