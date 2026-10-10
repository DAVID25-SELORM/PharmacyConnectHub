# Online payments runbook

Where to look: **Admin > Payments** (alerts, refunds needed, recent attempts). Every alert says what happened and which order it concerns. Marking an alert
"dealt with" records who did it and what they did; it does **not** move money. **Refunds** are made from the **Refunds** section of the same screen: every refund waits for an
administrator's approval (unless automatic refunds were switched on), is sent to Paystack by the system, and is followed until Paystack says it was returned. When an order paid online is
**amended** (a shortage accepted, a price lowered, a delivery problem credited) the difference is requested as a refund automatically; a price **increase** makes the pharmacy pay the difference (an "extra payment") before the order can be dispatched.

**To stop new online payments at once:** run `docs/payments/switches/disable-online-payments.sql` in the SQL Editor. Payments already in flight are still
verified and recorded; orders already paid stay paid.

## What each alert means and what to do

| Alert | Means | Do this |
|---|---|---|
| **Payment not applied** (`flagged_payment`) | The provider confirmed a payment, but it could not be applied to the order automatically: the amount or currency was different from what was asked, or the order had changed. | Open the order and the Paystack transaction. If the customer paid the wrong amount, refund it in Paystack and contact the pharmacy; the pharmacy can pay again from *My orders*. Press **Re-verify** only if you believe the provider's answer has changed. Then mark the alert dealt with and say what you did. |
| **Refund needed** (`refund_required`) | Money was received that the order cannot keep: a payment after the order was cancelled or expired, a second payment for an order already paid, or an order cancelled after it was paid. | A refund for the full amount has already been requested: find it under **Refunds** and press **Approve and send**. The alert closes by itself when Paystack confirms the refund. If you refunded it by hand in the Paystack dashboard instead, press **Already refunded** and put the Paystack refund reference in the note. |
| **Refund failed** (`refund_failed`) | Paystack refused the refund (for example the payment is too old, or already reversed), or later reported that it failed. | Read the reason on the refund. If it can be fixed, press **Retry**. Otherwise refund by hand in the dashboard and press **Already refunded**, or **Cancel** and explain in the alert note. |
| **Refund needs checking** (`refund_stuck`) | It is **not known** whether a refund request reached Paystack (no answer, a timeout, or the provider asked for more details), or a refund has been waiting or processing for too long. | **Check Paystack's dashboard before anything else. Never send it again until you know.** If the refund is there, press **Confirm refunded** (note the reference). If it is not, press **Not sent** and then **Retry**. |
| **Unmatched refund** (`refund_unmatched`) | Paystack reports a refund that this system did not send (for example one made by hand in the dashboard). | Find the payment's order. If the money was meant to go back, press **Already refunded** on that order's refund (create nothing twice). Otherwise investigate in the dashboard. Then mark the alert dealt with. |
| **Paid, not applied** (`paid_not_applied`) | The daily comparison found a payment the provider shows as successful that this system still could not apply, even after checking it again. | Open the order. Press **Re-verify**; if it stays, treat it like "Payment not applied". |
| **Unknown payment** (`unknown_at_provider`) | The provider shows a successful payment with one of our references that this system has no record of. | Find who paid in the Paystack dashboard (reference, email). It may be a payment started in another environment, or a lost record. Do not refund until it is understood. |
| **Missing at provider** (`missing_at_provider`) | This system has an attempt as paid, but the provider's list for the period does not contain it. | Search the Paystack dashboard for the reference. If the payment is really there (a listing delay), re-run the comparison the next day. If it is not, the order was marked paid without money: contact engineering at once. |
| **Status differs** (`status_mismatch`) / **Amount differs** (`amount_mismatch`) | This system and the provider disagree about whether, or how much, was paid. | Treat as serious: compare in the Paystack dashboard; do not dispatch against the order until it is understood. |
| **Provider unreachable** (`provider_unreachable`) | The reconciler could not reach the provider. Nothing was cancelled on a guess. | Check Paystack's status page. It closes itself in practice when the next run succeeds: mark it dealt with once it has. If it keeps coming back, check the secret key in the environment. |
| **Order kept open** (`expiry_blocked`) | An online order is past its payment window but was not cancelled, because one of its attempts has not been checked with the provider recently. | Usually it clears by itself on the next run. If it does not, the reconciler is not running or the provider is unreachable: see below. |

## Situations

**Webhooks are not arriving.** The return page and the reconciler find payments anyway: the customer sees "Payment received" on return, and the reconciler applies
anything missed within about 5 minutes. Check that the webhook URL in Paystack's settings is `https://YOUR-SITE/api/payments/webhook` for the right mode, and that the
secret key in the environment is the one for that mode.

**A pharmacy says it paid, but the order says awaiting payment.** Open **Admin > Payments**, find the order, press **Re-verify**. If the provider confirms it, the order is
paid at once. If the provider does not show it, the payment did not complete: ask the pharmacy to pay again from *My orders* (do not ask them to send proof of payment;
the provider is the evidence).

**A payment is stuck "pending".** Mobile-money payments can take a few minutes. The reconciler keeps asking for 48 hours, then closes the attempt. A customer who still pays on
an old page afterwards is handled as a late payment (it is recorded and raises a refund alert).

**An order was cancelled but the customer paid.** That is a late payment: it is recorded, the order is **not** revived, and a **Refund needed** alert is raised. Refund it.

**The reconciler is not running.** See `docs/payments/scheduling-the-reconciler.md`. Run it by hand with the `curl` command there to catch up.

**Something looks wrong with money.** Switch online payments off (above) first, then look. The switch never touches payments already in flight.

## Amendments on an order paid online

**A shortage, a lower price or a delivery credit on an order that was paid online.** The difference appears under **Refunds** (reason "Order reduced after payment" or "Delivery problem credit"). A delivery-problem credit **always** waits for your approval, even with automatic refunds on, because
the wholesaler decides it. Approve it once you agree it is due.

**A price went up on a paid order.** The pharmacy sees "A price change means this order now costs GH₵ X more" with a **Pay now** button; the wholesaler sees that it is waiting for payment and cannot dispatch the order until it is paid. If the pharmacy says it paid and the order is still blocked,
press **Re-verify** on the order (the same check as for any payment). An extra payment that is flagged (wrong amount, or the price changed again meanwhile) is refunded and the pharmacy can pay again for what is now due.

**"Order costs less than was paid and no refund is on the way" alert** (`refund_required`, warning). A refund for a change was cancelled or failed for good. Press **Request refund for the difference** on the alert: it creates a new refund for exactly what is owed back, which then waits for approval under **Refunds** like any other (or refund by hand and confirm it as already refunded).

**A pharmacy wants to back-order the rest on an order it paid online.** That choice is refused for now (the screen shows why). The pharmacy can accept the shortage and have the rest cancelled (the money for it is refunded), or reject the change.

## Settlement and going live

**Where a supplier's money goes.** In split mode every online payment settles to the supplier's own account (a Paystack *subaccount*). Add the account on **Admin > Payments > Supplier settlement accounts**: choose the bank or mobile money operator, enter the account name and number carefully (the number goes to Paystack once and is not kept here). Without an active account the supplier cannot be paid online: checkout refuses "Pay now" for them and says so.

**A settlement account says "Not created".** Read the reason. If Paystack refused it (for example the account number is invalid), correct it and add it again. If the reason says there was **no answer**, look in the Paystack dashboard first: it may have been created. Do not add it a second time until you have looked.

**A payment above the limit.** The pharmacy is told the limit and that this order must be paid another way (the order stays unpaid and expires, or the supplier can agree another method with the pharmacy). Raise the limit only deliberately, with `docs/payments/switches/set-split-and-limit.sql`.

**"Not split" is not zero in the settlement report (live mode).** Money reached the platform's own account instead of being split. Stop new payments (`disable-online-payments.sql`), then find the payments in the Paystack dashboard and settle that money to the supplier by hand. This should not be possible while the checks in `prepare_attempt_for_provider` hold; treat it as a serious fault.

**The report does not match Paystack's settlement report.** The report here is an estimate before Paystack's fees and counts payments by the day they were received; settlements arrive on Paystack's schedule. Compare payment by payment (reference) before concluding anything is wrong.

**Switching a supplier off.** Press **Switch off** on their account. New payments for them are refused; payments already made are untouched.

**Before live money (all of these, in order):** the **Ready for live money?** card on Admin > Payments must say **Ready**, and the **This server** list must be all green; Paystack's business verification and each supplier's account are in place; the split-refund behaviour is confirmed with Paystack in writing and recorded (`confirm-split-refunds.sql`); the reconciler is scheduled; you have made one split test payment and one refund in test mode against real Paystack test keys. Then run `enable-online-payments-live.sql`. The database will name anything still missing. **To stop at any moment:** `disable-online-payments.sql` (never blocked).
