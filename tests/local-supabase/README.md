# Real-schema validation on a local Supabase stack (Docker)

Never points at a hosted project. Uses throwaway local keys.

1. Make a scratch dir (NOT this repo, so `supabase/config.toml`'s production `project_id` is never used):
   `npx supabase init` there, set `project_id = "drugxone-local-validation"`, copy `supabase/migrations/` in.
2. Known problem: `20260419010000_seed_wholesaler_catalog_cash.sql` and
   `20260419011000_seed_wholesaler_catalog_retail_40th_quarter.sql` raise on an empty database
   ("No approved wholesaler found") so the full history does not build from scratch. Data-only seeds:
   move both out of the scratch copy to build the schema.
3. Baseline: apply migrations up to `20260920110000`, then `docker exec -i supabase_db_<project_id> psql -U postgres -f - < setup.sql` and `pre.sql`
   (reproduces the old NULL-role bypass on the previous functions).
4. Apply `20260921100000` (`npx supabase migration up --local`), rerun `setup.sql`, run `post1.sql` (43 checks) and `checkout1.sql`.
5. Apply the rest (or `npx supabase db reset --local`), rerun `setup.sql`, run `post2.sql` (17 checks).
6. `invite-api.local.mjs`: run with `npx tsx`, env `API_URL`, `ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (from `supabase status -o env`),
   `HANDLER_PATH=file:///.../api/staff/invite.ts`; users need passwords (see the UPDATE auth.users in the report/session).

7. `activity-log.sql` (33 checks on a 300k-row audit_logs) and `activity-log-explain.sql` (query plans): run after `setup.sql` with 20260921120000 applied.
