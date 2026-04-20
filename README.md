# PharmaHub GH

PharmaHub GH is a Supabase-backed B2B pharmaceutical marketplace for wholesalers and retail pharmacies in Ghana.

## Current product scope

- Email auth with onboarding for pharmacies and wholesalers
- Admin review flow with approve, reject, and edit business details
- Verification gates that block unapproved businesses from using the marketplace
- Multi-wholesaler product catalog for pharmacies
- Cart, checkout, and cash-on-delivery order placement
- Wholesaler product CRUD and bulk CSV upload
- Order inbox and fulfillment status tracking
- Team management using Supabase RPC and row-level security

## Tech stack

- Vite + React 19
- TanStack Router
- Tailwind CSS v4 + shadcn/ui
- Supabase Auth, Postgres, Storage, and RLS
- Vercel static SPA deployment

## Local development

1. Install dependencies.

```bash
npm install
```

2. Create a `.env` file from `.env.example`.

3. Start the app.

```bash
npm run dev
```

4. Open `http://localhost:5173`.

## Required environment variables

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`
- `VITE_SITE_URL` for auth email redirects in non-local environments

## Supabase setup

Apply the SQL migrations in `supabase/migrations` to your Supabase project before using the app.

Additional setup notes live in `supabase/SETUP.md`.
Run `supabase/SMOKE_TEST.md` after setup to verify signup, approval, catalog, ordering, and notifications end to end.
