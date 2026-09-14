# DrugXone Phase 2 deployment checklist

No hosted configuration or data was inspected or changed. Complete this checklist in an isolated staging rehearsal first. Do not deploy based only on local test results.

## Existing-data upgrade

1. Take a restorable database and Storage backup; rehearse restore. Export migration history, policies, grants, and the read-only Phase 0/1/2 reports. Review all conflicts with the data owner; do not delete duplicates or fabricate stock history.
2. Confirm an explicitly approved active platform owner exists and does not also belong to a tenant. Phase 2 makes active platform_staff authoritative for admin access; legacy user_roles alone no longer grants admin. Resolve authority discrepancies through a separately reviewed administrative procedure before rollout. No account is automatically promoted.
3. Compare hosted migration history with the repository. Apply only unapplied corrective migrations in timestamp order to staging. Never blindly replay historical seed/deletion migrations. Phase 2 is 20260914120000_phase2_production_readiness.sql; Phase 0, private printing and Phase 1 must precede it.
4. Deploy matching API/browser changes together during a controlled maintenance window: Phase 1 removed keyless checkout; Phase 2 revokes older staff/payment paths. Review old clients and roll forward rather than reverting security grants.
5. Run postflight queries and smoke tests, then obtain separate deployment authorization. Legacy catalogue mismatches are hidden pending explicit reconciliation; historical ambiguous products are preserved.

## Fresh install

Use generated supabase/baseline/fresh-install.sql only on a new Supabase project with Auth/Storage schemas and roles available. It refuses an existing businesses table. The generator and SHA256 manifest preserve provenance without editing historical migrations. It excludes two demo catalogue seeds, a hardcoded membership deletion, duplicate-deletion CTEs, and arbitrary first-owner backfill. No demo account, approved wholesaler or owner is provisioned.

Run node scripts/build-fresh-baseline.mjs offline to reproduce it. Rehearse the baseline first. After confirming schema equivalence, a database administrator must explicitly reconcile Supabase migration history to the manifest through the supported migration-repair workflow before future db push operations. The baseline does not mark history automatically. Do not combine baseline execution with replay of its source migrations. Do not execute deprecated supabase/schema.sql.

Bootstrap the first owner only through a separately reviewed privileged database procedure targeting a verified, named Auth account with no tenant membership; record approver and audit evidence. Public signup and tenant APIs cannot bootstrap an owner. Owner transfer/removal is deliberately unsupported through application APIs.

## Supabase manual checks

- Confirm applied versions and effective RLS on every public/private table; compare pg_policies and EXECUTE grants with Phase 2 inspection output. anon/authenticated must not execute service checkout, staff mutation, receipt claim/finish or internal audit writers.
- Verify service-role keys exist only on server APIs. Verify requests authenticate their human caller and never expose keys in responses or VITE variables.
- Require Auth email confirmation; test invitation, recovery code/hash flows, token expiration and rate limits. Set the exact HTTPS Site URL and minimal redirect allowlist (no broad production wildcards).
- Verify licenses is private, 10 MiB maximum, PDF/JPEG/PNG MIME allowlist. Test real Storage upload size/type enforcement and signed URL expiry with two tenants; SQL tests use Storage schema doubles and do not replace real Storage API testing.
- Confirm signed URLs are short-lived; no public URLs. Inspect missing objects/orphans, preserve reviewed versions, and agree retention/privileged cleanup procedures. Signature checks are not antivirus; assess content scanning before allowing document preview in production.
- Review SMTP/from-domain, deliverability, provider credentials, API rate limits and abuse controls. Resend must support the stable idempotency key; exercise provider-success/tracking-failure recovery in staging.
- Verify automated backups, Storage backup coverage, retention, restore ownership and PITR availability/RPO/RTO. Database backup alone is not a Storage object backup.

## Vercel, domain and HTTPS manual checks

- Confirm production branch, build command, Node version, lockfile installation and preview/production separation. Review dependency overrides on upgrades.
- Verify SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SITE_URL, RESEND_API_KEY and sender variables against server code. Public VITE_SUPABASE values may contain only publishable/anon credentials. Never put service credentials in VITE_*.
- Confirm API environment points to the intended project and trusted SITE_URL; untrusted Origin/Host no longer selects email links.
- Verify DNS/domain ownership, certificate and HTTPS redirects. Do not change DNS during this task.
- Check deployed response headers (HSTS, CSP, nosniff, no-referrer, frame and permissions restrictions, API no-store). Test all app flows under CSP; add only required exact custom Supabase origins if using a custom domain. Avoid wildcards for script sources.
- Confirm recovery pages have no third-party analytics and remove credentials immediately. Review server access-log handling of query credentials; browser cleanup cannot retroactively erase upstream logs.
- Rehearse printing, contacts, import workers/PDF, verification previews, checkout, cancellation, payment and receipt retry with isolated data. Confirm operational monitoring and manual handling of uncertain receipt jobs; no background delivery scheduler is introduced here.

Provider boundary: Resend retains idempotency keys for 24 hours (https://resend.com/docs/dashboard/emails/idempotency-keys). DrugXone stops automatic retry after 23 hours from first attempt and requires provider review. This avoids knowingly creating a second delivery when an old outcome is unknown.
