# Recent migration preflight

## Scope

The eight enterprise RFQ migrations dated 20261115 and business document branding migration dated 20261116 were applied successfully in filename order to an isolated local database copy. The copy included the external procurement release and the earlier delivery reconciliation schema prerequisite. Production schema drift was not checked and no production migrations were applied.

## Corrections

- Fixed branding read/storage policies calling functions unavailable to authenticated users; branding writes go through the authorized RPC.
- Rejected nonexistent and cross-business logo references; wrapped the branding migration in a transaction.
- Preserved registered issuer names, isolated branding/RFQ state when switching businesses, and blocked saving branding after a failed load.
- Enforced the RFQ prohibition on partial awards on the server.
- Fixed modal print clipping and blank pages, bulk document separation, and ordinary report printing.

## Validation

- 79 unit test files, 770 tests passed.
- TypeScript and production build passed again before push.
- RFQ, RFQ failure cases, external procurement and branding SQL regression suites passed against the final isolated database, and passed again before push.
- Chrome PDF regression passed for short modal documents, long tables, bulk invoices and ordinary reports.
- Chrome RFQ editor/detail checks passed at widths 390, 768, 1024 and 1440, including private/open draft and publication contracts with mocked HTTP responses.

## Application notes

Apply all unapplied migrations in timestamp order, including prerequisite migrations. Do not rerun already applied migrations manually. These checks used a local release fixture, not a complete reset of the entire historical migration chain.

The local database does not enable pg_cron, so scheduled reminder execution remains unverified; workspace-triggered reminders remain available. The production build reports a large JavaScript bundle warning.
