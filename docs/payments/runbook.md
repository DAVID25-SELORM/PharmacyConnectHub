# Online payments runbook

Where to look: **Admin > Payments** (alerts, refunds needed, recent attempts). Every alert says what happened and which order it concerns. Marking an alert
"dealt with" records who did it and what they did; it does **not** move money. **Refunds** are made from the **Refunds** section of the same screen: every refund waits for an
administrator's approval (unless automatic refunds were switched on), is sent to Paystack by the system, and is followed until Paystack says it was returned. Refunds for amendments
to a paid online order are not built yet: until they are, refund the difference by hand and record it with **Already refunded**.

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
