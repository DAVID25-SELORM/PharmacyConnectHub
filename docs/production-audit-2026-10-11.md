# Production readiness audit — 2026-10-11

## Verdict

### Follow-up corrections

The local correction is `20261117100000_rfq_production_corrections.sql`; apply it after the existing migrations. It replaces the unsupported object length call, rejects null/structured proposal values, rejects negotiation responses on closed RFQs, and returns authorized issuer branding for document exports. Real negotiation request/revision/acceptance and invalid-value cases now run in the SQL regression suite.

Both pharmacy and wholesaler managers have a Document branding settings section in the RFQ workspace. RFQ exports use the issuing business identity, contact settings, notes and signature fields; PDF exports also use its logo and accent colour. Spreadsheet exports carry the identity as metadata.

The findings below describe the original audit. These code corrections still need the new migration applied and the production operational checks completed; they do not establish backup readiness or live workflow success.

Not ready for unconditional production sign-off. This audit combined public deployment checks with repository inspection and a local PostgreSQL reproduction. It did not have an authenticated production session or direct production database access.

## Release blocker

`supabase/migrations/20261115130000_enterprise_rfq_operations.sql:42` calls `jsonb_object_length(p_proposal)` in `rfq_negotiate`. Neither PostgreSQL's catalog nor the local release database defines this function, and no repository migration defines it. A direct local invocation returns `function jsonb_object_length(jsonb) does not exist`. The pharmacy UI invokes this RPC. Negotiation can therefore fail even though function creation and signature checks pass.

Correction needed: an additive migration replacing the negotiation function, using a supported object-key count after validating object type. Also reject JSON null proposal values explicitly. Exercise the actual negotiation RPC with authorized fixtures, valid proposals, malformed values and supplier responses before applying the correction in production. Do not rewrite an already applied migration as the deployment mechanism.

## Other findings

- The only mounted `DocumentBrandingSettings` component is in ExternalProcurement; wholesalers have no equivalent settings entry point in the inspected source.
- RFQ PDF/XLSX export uses a separate implementation in `src/lib/enterprise-rfq-documents.ts`; consistent business branding across all document types has not been established.

## Evidence that passed

- https://www.drugxone.com/ returned HTTP 200.
- Live responses include HTTPS HSTS, CSP, frame denial, nosniff and a referrer policy.
- Previous local verification: 770 unit tests, TypeScript, production build, four database suites, responsive RFQ mock browser checks and print pagination checks passed.
- User reports that all production postflight checks passed. This confirms the checks in that script, not execution of every RPC or successful scheduled reminder runs.

## Unverified production controls

- Authenticated pharmacy/supplier workflow and tenant separation in the deployed application.
- Successful hourly reminder execution and notification delivery, beyond job registration.
- Backup/restore readiness, production monitoring and error logs, and payment/provider configuration.
- Exact deployed source commit; public availability alone does not establish artifact parity.

The earlier local test results remain valid for their covered paths, but do not justify a full production-ready claim.
