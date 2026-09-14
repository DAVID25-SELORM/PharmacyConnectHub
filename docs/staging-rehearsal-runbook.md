# DrugXone isolated staging rehearsal

Target: local Supabase project `drugxone-isolated-rehearsal` in `.tmp/staging-rehearsal`, API `http://127.0.0.1:56321`, PostgreSQL `127.0.0.1:56322`, local email capture `127.0.0.1:56324`, application `127.0.0.1:4180`. No hosted link. Docker network `drugxone-rehearsal-local` defaults host bindings to 127.0.0.1. Status/credentials and synthetic user passwords stay under ignored `.tmp`; never commit them.

The repository's original Supabase configuration and `.env` are not staging configuration and must not be used by these scripts. The server rejects any API target other than the dedicated loopback port and overrides public/server Supabase values from the isolated stack. Outbound receipt API credentials are removed; no operational customer email is sent.

## Reproduction

1. Start Docker Linux engine. Initialize a separate Supabase workspace, set unique project ID and ports, Auth confirmation enabled, local-only redirect URLs and no seeds. Create a Docker bridge with `com.docker.network.bridge.host_binding_ipv4=127.0.0.1`.
2. Copy the supported `supabase/baseline/fresh-install.sql` as the only staging migration. Manifest verification is `node tests/staging/preflight.mjs`; source history must not be replayed alongside the baseline.
3. Start the isolated stack with the separate `--workdir` and network; never `link` a hosted project. Capture CLI status JSON into `.tmp/staging-rehearsal/status.json` without displaying credentials.
4. Confirm Docker published ports, API health and database identity before tests mutate anything.
5. `node tests/staging/server.mjs` starts the actual application and API handlers against local Auth/Storage/PostgREST. No API behavior is mocked in this server. Vercel hosting itself is not emulated.
6. On a fresh isolated database run `node tests/staging/rehearsal.mjs`, then `node tests/staging/browser.mjs`. The former creates synthetic `@example.test` users, uses actual signup/OTP sessions, bootstraps a named test owner through direct administrative SQL, and calls API/RPC/Storage endpoints. Link generation is a test inbox shortcut; separate browser recovery verification is required.
7. Results/security snapshots and screenshots stay under `.tmp/staging-rehearsal`. Never reuse the account file against a hosted project.

## Scope distinctions

A local Supabase rehearsal uses real GoTrue, Storage and PostgREST services, but cannot establish hosted SMTP, custom domains, HTTPS, Vercel environment or hosted backup/PITR readiness. Synthetic baseline data is not a representative pre-remediation production snapshot. Do not report upgrade PASS without such a snapshot.

The current COD state machine requires delivery before payment confirmation. The golden flow must follow that order; confirming before delivery is a negative test.

## Proposed production runbook � do not execute

1. Record production project/branch/version and obtain deployment authorization. Confirm named owner and authority discrepancies before granting active platform membership.
2. Backup database and Storage objects separately, record checksums/restore locations, and successfully rehearse restoration to an isolated target. Establish RPO/RTO with operations.
3. Snapshot migration history, effective grants/policies and data counts. Run Phase 0/1/2 read-only checks. Resolve blockers by reviewed procedures; never auto-delete suspect rows or fabricate stock history.
4. Rehearse missing corrective migrations on a representative historical copy. Freeze writes for coordinated rollout and verify backup checkpoint before proceeding.
5. Apply only missing corrections, in order: Phase 0, private printing, Phase 1, Phase 2 (preceded by any required safe import/catalogue corrections confirmed absent). Do not replay seeds or execute the fresh baseline on production.
6. Deploy matching API then frontend under maintenance controls. The old keyless checkout and unrestricted writes must stay disabled; old clients cannot safely be retained.
7. Verify effective RLS/EXECUTE grants, Auth and recovery, private Storage uploads/downloads, verified wholesalers, checkout prices/idempotency/concurrency, cancellation, printing and payment/receipt state.
8. Monitor authorization failures, integrity exceptions, orphan/missing-document findings and receipt leases/uncertain jobs. Release maintenance only after explicit smoke-test acceptance.

Rollback checkpoints: before migration, restore rehearsed snapshots if needed. After migration but before opening writes, keep maintenance active and prefer a reviewed forward correction; do not reintroduce unsafe historical grants. After new writes, restoring an old database requires reconciliation of new orders, inventory, Storage and email outcomes and an agreed data-loss window. Never blindly restore stock or resend receipts. A failed critical security check means stop rollout and preserve evidence.
