# Scheduling the payment reconciler

The reconciler is one endpoint, `/api/payments/reconcile`, that a scheduler calls. It is **not** scheduled by anything in this repository yet: that is a
decision for you (the hosting plan decides what is possible), and nothing about online payments works without it being scheduled except the things
listed under "What happens without it".

## What it does

| Call | How often | What it does |
|---|---|---|
| `/api/payments/reconcile?job=frequent` | every 5 minutes | Asks the provider about payment attempts that could still turn out to have been paid (open ones every few minutes, closed ones hourly, for 48 hours), applies what the provider says, closes attempts open for 48 hours, and cancels online orders whose payment window is over (stock is returned through the normal cancellation path, the pharmacy is told). |
| `/api/payments/reconcile?job=daily` | once a day (for example 03:00) | Lists the provider's transactions for the last 25 hours and compares them with ours. Anything paid at the provider but not applied here is verified and applied; every other difference becomes an alert on **Admin > Payments**. |

Both calls do nothing, successfully, while online payments are switched off (no `PAYMENTS_MODE`), so scheduling them early is harmless.

## What you need

1. A long random secret in the server environment: **`CRON_SECRET`** (Vercel: Project Settings > Environment Variables). Without it the endpoint answers 503 and does nothing.
2. A scheduler that sends `Authorization: Bearer <CRON_SECRET>`.

## Option A: Vercel Cron (simplest)

Vercel sends `Authorization: Bearer $CRON_SECRET` to cron paths automatically when `CRON_SECRET` is set. Add to `vercel.json`:

```json
"crons": [
  { "path": "/api/payments/reconcile?job=frequent", "schedule": "*/5 * * * *" },
  { "path": "/api/payments/reconcile?job=daily", "schedule": "0 3 * * *" }
]
```

**Check your Vercel plan first.** On the Hobby plan Vercel only allows cron jobs that run once a day, and a schedule it does not allow makes the *deployment fail*.
That is why this is not already in `vercel.json`. On Pro, every-minute schedules are allowed.

## Option B: any external scheduler

Anything that can make an HTTPS request on a schedule works (a scheduled GitHub Actions workflow, a hosted cron service):

```bash
curl -fsS -H "Authorization: Bearer $CRON_SECRET" "https://YOUR-SITE/api/payments/reconcile?job=frequent"
```

Keep the secret in the scheduler's secret store, not in the workflow file.

## What happens without it (or when it runs rarely)

Nothing unsafe happens, but:

- **Unpaid online orders keep their stock reserved** until the pharmacy cancels them: nothing expires them.
- **A payment whose notification never arrived** is only found when the customer returns to the site (the return page checks) or an administrator presses *Re-verify*.
- **A late payment** (money arriving after an order was cancelled) is only noticed if its notification arrives.
- If it runs *less often than every 10 minutes*, orders past their window are not cancelled on time: an order is only cancelled when each of its open attempts was checked with the provider in the last 15 minutes, so the system raises "Order kept open" alerts instead of guessing.

**Do not use online payments with real money until this is scheduled (every 5 minutes) and you have watched it run in test mode.**

## Running it by hand

```bash
curl -i -H "Authorization: Bearer $CRON_SECRET" "https://YOUR-SITE/api/payments/reconcile?job=frequent"
```

The answer is a count: attempts checked, applied, provider errors, stale attempts closed, orders expired or kept open. It never contains payment details or keys.
