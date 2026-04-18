# Supabase setup

This repo now boots the Supabase-backed router app from `src/main.tsx`.
The legacy `src/App.tsx` + `server.ts` prototype is no longer the active frontend entrypoint.

## 1. Apply the database schema

In the Supabase SQL editor for your project, run the migration files in this order:

1. `supabase/migrations/20260418020126_9c479796-cb89-4d6c-9caf-0bb04a77bf15.sql`
2. `supabase/migrations/20260418020137_9bde4aff-ea64-4c26-a749-dbfe0e9d0e53.sql`
3. `supabase/migrations/20260418021718_2cdc1fd4-5ee9-4953-8ad4-6e1a83e54eb9.sql`
4. `supabase/migrations/20260418030000_add_business_staff.sql`

`supabase/schema.sql` is an older prototype schema and should not be used for the current Supabase app.

## 2. Configure environment variables

Client-side variables required for the Supabase app:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

Server-side variables required for server handlers:

- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `PAYSTACK_SECRET_KEY`

The current staff-management flow uses direct Supabase RPC calls from the client for existing users,
so staff additions do not depend on the `api/staff/*` handlers.

## 3. Hosting assumptions

The app now reads auth and business data directly from Supabase.

However, payment flows still use server handlers at:

- `/api/paystack/init`
- `/api/paystack/verify`
- `/api/paystack/webhook`

If you deploy as a static frontend only, those payment endpoints will not exist.
To keep payments working, deploy a server runtime that supports those handlers or move them to Supabase Edge Functions.
