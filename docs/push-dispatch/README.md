# Closed-tab push alerts on the free Vercel plan

Vercel's free (Hobby) plan rejects the every-5-minute cron job that `5c71565` added to
`vercel.json` ("Hobby accounts are limited to daily cron jobs"), and caps the number of server
functions. Every deployment of `main` failed because of it. The delivery now runs in Supabase:

| Before (Vercel)                         | Now                                                                           |
| --------------------------------------- | ----------------------------------------------------------------------------- |
| `api/push/subscribe.ts`                 | The browser saves its own subscription (row-level security already allows it) |
| `api/push/dispatch.ts` + Vercel cron    | Edge function `push-dispatch`, called every 5 minutes by `pg_cron` + `pg_net`  |

The Vercel `api/` folder is back to 12 functions and `vercel.json` has no `crons`.

## Steps (in this order)

1. **Merge the pull request.** Vercel deploys again. Nothing changes for users yet.
2. **Set the function secrets** (Supabase dashboard, Edge Functions, Secrets, or `supabase secrets set`):
   `PUSH_CRON_SECRET` (new long random value), `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (copy the
   same values currently in Vercel's environment variables) and optionally `VAPID_SUBJECT`.
   `VITE_VAPID_PUBLIC_KEY` stays in Vercel.
3. **Deploy the function** from a clean checkout of `main` (never from a stale or scratch branch):

   ```bash
   npx supabase@2.117.0 functions deploy push-dispatch --project-ref ywpntuioeqpreouauuir --no-verify-jwt
   ```

4. **Schedule it:** fill in the two placeholders in `schedule-push-dispatch.sql` and run it once in the SQL editor.
5. **Verify** with `verify-push-dispatch.sql`, then turn on alerts in a browser, close the tab and
   create a notification (for example place a test order) to see the alert arrive.

If the 20261212100000 migration (the `push_subscriptions` tables) is not applied yet, apply it first.
