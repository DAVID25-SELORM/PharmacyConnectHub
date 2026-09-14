# Final blocker pass

Generic Order placed attribution is corrected by forward migration 20260914130000_checkout_audit_actor.sql. It inserts the validated service-only checkout caller into private server_audit_context immediately around order insertion, then removes it. No RPC parameters/grants or prior audit rows change. Movement attribution is preserved. The fresh baseline and manifest were regenerated.

Targeted test: 1 passed, 0 failed. Checks actor/email, spoofed item actor ignored, movement actor/delta, replay, stock rollback and client execution/context denial. Executed in a rolled-back transaction on loopback staging56322; migration was not persisted there. Targeted ESLint and TypeScript pass. No broad suite or restore repeat.

Historical snapshot: none found in repository/test assets. Ignored database.dump is the post-remediation synthetic staging backup, not representative legacy data. Obtain an authorized sanitized pre-Phase0 copy with original schema/migration history and Storage references; restore to an isolated project, run read-only preflights, apply only missing corrections in order, and compare stock/orders/items/memberships/references and effective permissions. Do not manufacture legacy evidence.

Additional local browser pass: all three required wholesaler document uploads PASS; real recovery-token consumption, immediate URL cleanup and password update PASS. Admin approval PASS after correcting the hard-coded business-name selector to use the actual staging business heading. Resubmission is asserted pending before admin approval. Latest targeted browser run: 3 PASS, 1 WARN, 0 FAIL; the earlier approval timeout was a test-selector issue. Approved businesses redirect away from onboarding. The existing controlled replacement path is Admin > Approved > business > Revoke (required reason, version-bound review RPC), then owner opens /onboarding and replaces evidence, followed by admin review/approval. Source inspection confirms the Revoke path; resubmission to pending and subsequent approval passed locally. Completed targeted evidence-only acceptance: 4 PASS, 0 FAIL. Browser Revoke, rejected state, denied inventory import, all three replacements, preservation of prior version IDs, pending state and current-version admin approval passed in one run. The test now waits for existing Replace controls and displayed admin evidence. Earlier unsuccessful approval was not reproduced; its exact response was not captured, so loading/version timing remains an inference. No application or migration correction required for this controlled workflow. Recovery and broad suites were not rerun. Targeted ESLint PASS. Synthetic upload files test transport, not document rendering. External emailed confirmation/recovery delivery and redirects still require hosted SMTP verification. Targeted test-file ESLint PASS after formatting correction; no application code changed in this resumed pass.

Hosted checklist: compare applied migrations including new130000 correction; effective pg_policies and RLS; EXECUTE grants on internal/service RPCs; confirmation enabled and exact HTTPS Site URL/recovery allowlist; private licenses bucket10MiB PDF/JPEG/PNG; server Supabase URL/service key, SITE_URL, RESEND_API_KEY/RECEIPT_FROM_EMAIL and public anon-only variables; HTTPS/deployed CSP/HSTS/nosniff/no-referrer/frame protections; backup retention/PITR/RPO/RTO.

Full restore remains independent database roles/privileges/extensions plus actual Storage bytes and metadata into a separate service, followed by Auth/RLS/download/inventory smoke tests. Local8-table restore evidence is retained, not repeated.

Provider test: use controlled test recipients; confirm signup and recovery email receipt, one-use/expired links and URL cleanup; then delivered COD confirmation, receipt success, simulated send failure and retry, provider-success/tracking-write failure with stable key, recorded-success no-resend, and >23-hour uncertain outcome requiring manual provider reconciliation. No operational customer email.

Recommendation: NOT READY FOR PRODUCTION. No commit, push, deployment or production access.





