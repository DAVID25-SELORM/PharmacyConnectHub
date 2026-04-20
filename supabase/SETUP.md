# Supabase setup

This repo now boots the Supabase-backed router app from `src/main.tsx`.
The app is a client-side Vite SPA backed directly by Supabase.

## 1. Apply the database schema

In the Supabase SQL editor for your project, run the migration files in this order:

1. `supabase/migrations/20260418020126_9c479796-cb89-4d6c-9caf-0bb04a77bf15.sql`
2. `supabase/migrations/20260418020137_9bde4aff-ea64-4c26-a749-dbfe0e9d0e53.sql`
3. `supabase/migrations/20260418021718_2cdc1fd4-5ee9-4953-8ad4-6e1a83e54eb9.sql`
4. `supabase/migrations/20260418030000_add_business_staff.sql`
5. `supabase/migrations/20260418043000_harden_verification_controls.sql`
6. `supabase/migrations/20260419000000_add_notifications.sql`
7. `supabase/migrations/20260419000100_fix_notification_triggers.sql`
8. `supabase/migrations/20260419000200_bootstrap_business_on_signup.sql`

`supabase/schema.sql` is an older prototype schema and should not be used for the current Supabase app.

## 2. Configure environment variables

Required client-side variables:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`
- `VITE_SITE_URL` for password reset and email confirmation redirects

## 3. Hosting assumptions

The app reads auth, business, product, and order data directly from Supabase.

The current checkout flow is cash on delivery only. No Express server or custom staff API handlers are required for the live app.

## 4. Important notes

- `supabase/schema.sql` is legacy reference material, not the source of truth.
- The active business-staff flows rely on the `add_business_staff_by_email`, `list_business_staff`, and `get_user_business_context` RPC functions from the migrations.
- The notifications UI depends on the notification migrations and the checked-in Supabase types in `src/integrations/supabase/types.ts`.
- If you add server-side notifications later, prefer Supabase Edge Functions over reintroducing a separate Express backend.

## 5. Smoke test

After the migrations are applied, run the live verification checklist in [SMOKE_TEST.md](./SMOKE_TEST.md).
