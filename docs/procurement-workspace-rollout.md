# Procurement workspace rollout

Apply these new migrations in this order, in the same Supabase project as the application:

1. `supabase/migrations/20261121100000_procurement_workspace_catalogue.sql`
2. `supabase/migrations/20261122100000_procurement_templates_reports.sql`
3. `supabase/migrations/20261123100000_external_receipt_unit_conversion.sql`

The previously applied `20261120100000_external_supply_orders.sql` is a prerequisite. Do not rerun it. Earlier central branding and external procurement migrations must already be installed. Do not apply the unrelated platform billing migration as part of this release.

Run each complete file, including BEGIN and COMMIT. A successful migration normally reports success with no result rows. Stop at any error; do not deploy the client until all three finish successfully. These are one-time migrations, not idempotent rerun scripts.

After migration, deploy the matching feature-branch client and perform an authenticated smoke test using authorized test data: catalogue search/create/reload, supplier reuse, save/reopen incomplete draft, issue complete document and download PDF, then partial receipt with explicit conversion. Inventory remains subject to the existing review/posting workflow. Confirm roles without process permission cannot create catalogue or procurement documents.

Production verification has not been performed. Full local regression and database results are in procurement-workspace-investigation.md. Roll back the client first if necessary; retain new catalogue/template tables and document history. Do not restore the older receiving function without considering converted receipts.
