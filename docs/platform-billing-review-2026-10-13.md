# Platform billing review ? 13 October 2026

Verdict: do not sign off for real billing activation yet. Three high-priority defects were independently reproduced. No production configuration, orders, payments, billing data or deployed code was changed.

## P1: Capped fees can produce credits larger than the fee charged

Location: `supabase/migrations/20261202110000_platform_billing_engine.sql`, billing_assess_order_change, lines 316?328.

The adjustment compares the new theoretical fee with prior fee_after_limits, then assigns the full negative difference to charged_amount. It does not account for the cycle-cap reduction or limit the credit to the net fee actually charged on that order.

Reproduction in a transaction: create a zero-subscription plan with 1% fee and GHS 10 cycle cap; deliver a GHS 10,000 order; reduce its effective value to zero. Primary assessment: theoretical fee 100.00, charged 10.00, cap adjustment 90.00. Adjustment: charged_amount -100.00. The ledger contains 10.00 charged and 100.00 credited. Transaction rolled back.

Correction required: derive credits from actual net assessed charges, including previous credits, cap reductions and fee waivers; define and test partial decreases and later increases. An order must never return more fee than was actually charged.

## P1: Follow-platform mode bypasses go-live and bills shadow history

Locations: `supabase/migrations/20261206110000_platform_billing_rollout.sql`, admin_billing_set_subscription_mode line 92 and billing_open_periods line 130; `20261202110000_platform_billing_engine.sql`, billing_assess_order line 160.

A subscription held in shadow can be changed to NULL (follow platform) while the platform is active, without setting activated_at or invoking the go-live routine. The engine falls back to billing_starts_at when activated_at is absent.

Reproduction through authenticated administrator RPCs: create a shadow subscription beginning 90 days ago with GHS 100 monthly subscription; set its mode to NULL; run billing. Result: activated_at remains NULL, three real periods accrue GHS 300, and two historical periods are invoiced. Transaction rolled back.

Correction required: reject transitions into real mode until explicit go-live, and enforce non-NULL activation dates in every real assessment/period entry point. Preserve the deliberate go-live anchor and trial restart.

## P1: Activation does not enforce the documented zero-commission requirement

Location: `supabase/migrations/20261206110000_platform_billing_rollout.sql`, admin_billing_readiness and admin_billing_activate_platform, lines 716?795.

The documented commercial rule says Paystack platform_fee_bps must remain zero when billing is activated. Neither readiness nor activation checks payments_settings. Payment split preparation separately uses platform_fee_bps in `20261111110000_payments_settlement_workflow.sql` line 102.

Reproduction: install the actual payments settings schema and its split_mode/platform_fee_bps definitions in the isolated test transaction, set online_enabled=true, mode=live, split_mode=subaccount, platform_fee_bps=100; readiness returns true and the authenticated activation RPC switches billing to active. No provider request or payment was made. Transaction rolled back.

Correction required: enforce the invariant at activation and prevent later settings changes from enabling both revenue mechanisms; cover concurrent changes as well as the UI path.

## Verification performed

- All 11 billing migrations applied successfully to a separate local database (`billing_audit_20261013`) cloned from the local procurement validation database.
- Existing rollout SQL suite: 149 assertions passed, zero failures in zz.results.
- Billing unit suites: 4 files, 51 tests passed.
- TypeScript: npx tsc --noEmit passed.
- Production build passed, with the existing large-chunk warning.
- Additional transactional reproductions above exposed cases not covered by those passing suites.
- Reviewed server-side admin authorization, RLS/direct-write revocations, append-only records, invoice/payment locking and replay handling, shadow separation, scheduler, notifications and client RPC integration.

## Limits and environment notes

This is not a production or browser certification. The local baseline is an earlier procurement validation schema with the current billing migrations applied. Its existing zz fixtures were used: rerunning setup.sql stopped at a pre-existing credit-ledger foreign key before fixture reconstruction. The rollout test itself then completed successfully. The commission reproduction explicitly installed only the relevant real payment settings definitions; it did not execute a live provider checkout. The full historical phase-by-phase SQL suites and multi-session concurrency scripts were not rerun in this review.

The initial attempt to dump the shared local postgres database failed because it contains orphaned zz function namespace references. Review used a separate cloned validation database instead and did not repair or modify the shared database.

No implementation changes or push were made for this review. The pre-existing modification to src/routeTree.gen.ts was left untouched. Keep real billing disabled or in shadow until the defects are corrected and the new regressions pass.

## Remediation ? 13 October 2026

All three reproduced defects are fixed locally by `20261207100000_platform_billing_audit_fixes.sql`. Apply it after both Phase 6 billing migrations and the existing Paystack payment settings migrations. It preserves ledger history and does not activate billing.

- Credits use the actual remaining charged fee and account for fee waivers. A reduction that still leaves the theoretical fee above the cap earns no credit; subsequent decreases cannot credit the same fee again. Later increases still obey the original cycle-cap budget (credits do not recycle that budget).
- Follow-platform cannot activate an unactivated shadow business. Assessment, catch-up, period creation, effective mode and manual real-period access independently enforce the activation date. Use the explicit go-live action.
- Readiness includes zero Paystack platform commission. Both settings tables enforce the invariant with triggers and a shared transaction lock; activation and mode changes acquire that lock before their settings row lock.

Validation: the migration applied successfully to two isolated local databases. All 149 rollout checks pass after the fix; focused SQL regressions cover capped/full/partial/repeated refunds, waivers, increases, the shadow bypass, engine defences, explicit go-live, historical orders, activation and direct settings changes. Two overlapping-session scenarios passed (activation first, commission first). No hosted migrations or live payment tests were run.

Use `docs/billing/verify-billing-audit-fixes.sql` for read-only rollout verification. Existing incorrect historical credits or periods are detected but not automatically rewritten. Conflicting active billing and nonzero commission makes the migration fail explicitly; correct the commission setting before retrying. The new tests are under `tests/local-supabase/platform-billing-audit-fixes.sql` and `platform-billing-audit-concurrency.py`.
