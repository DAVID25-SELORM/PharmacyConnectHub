// The scheduled job that keeps payments honest, separated from the endpoint file so it can be tested with stand-ins. Called by a scheduler with a
// shared secret (never by a browser).
//
//   job=frequent (every few minutes):  asks the provider about payment attempts that could still turn out to have been paid, applies what it says,
//                                      closes attempts that have been open for 48 hours, and cancels online orders whose payment window ended
//                                      (stock returns through the normal cancellation path). The database refuses to cancel an order whose attempts
//                                      have not been checked recently, so a provider outage cannot cancel an order that was in fact paid.
//   job=daily:                         lists the provider's transactions for the last day and compares them with ours; whatever is paid at the
//                                      provider but not applied here is verified and applied through the same function; every remaining difference
//                                      becomes an alert on the admin Payments screen. Nothing is "corrected" any other way.
// See docs/pay-now-paystack-plan.md (sections 5.3, 5.7 and 14).
import { createHash, timingSafeEqual } from "node:crypto";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import { submitRefund } from "./refund-runner.js";
import { ProviderError, type ListedTransaction, type PaymentProvider } from "./types.js";
import { verifyAndApply, type AttemptRef } from "./verify-apply.js";
import type { RpcFn } from "./webhook-handler.js";

export type ReconcileDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  /** The shared secret the scheduler sends as a bearer token. Unset means the job is not available. */
  cronSecret: () => string | undefined;
  now: () => Date;
  log: (message: string) => void;
};

const MAX_ATTEMPTS_PER_RUN = 25;
const MAX_REFUNDS_PER_RUN = 10;
const MAX_LIST_PAGES = 20;
const PAGE_SIZE = 100;
const MAX_VERIFY_FROM_COMPARISON = 50;

function secretMatches(given: string | undefined, expected: string): boolean {
  if (!given) return false;
  const a = createHash("sha256").update(given).digest();
  const b = createHash("sha256").update(expected).digest();
  return timingSafeEqual(a, b);
}

function toRow(t: ListedTransaction) {
  return {
    reference: t.reference,
    status: t.status,
    amount_minor: t.amountMinor,
    currency: t.currency,
  };
}

export function createReconcileHandler(deps: ReconcileDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    if (req.method !== "GET" && req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }
    const secret = deps.cronSecret();
    if (!secret) return res.status(503).json({ error: "The reconciler is not configured." });
    const header = req.headers.authorization;
    const given = header?.startsWith("Bearer ") ? header.slice(7) : undefined;
    if (!secretMatches(given, secret)) return res.status(401).json({ error: "Unauthorized" });

    const configResult = deps.loadConfig();
    if (!configResult.ok) {
      // Online payments being off is normal, not a failure of the scheduler.
      if (configResult.status === 503) return res.status(200).json({ skipped: configResult.error });
      return res.status(configResult.status).json({ error: configResult.error });
    }
    const rpc = deps.createRpc();
    if (!rpc) return res.status(500).json({ error: "Server misconfigured" });
    const provider = deps.createProvider(configResult.config);
    const jobParam = Array.isArray(req.query?.job) ? req.query.job[0] : req.query?.job;
    const job = jobParam === "daily" ? "daily" : "frequent";

    const reportProblem = (summary: string, details: Record<string, unknown>) =>
      rpc("report_payment_job_problem", {
        p_kind: "provider_unreachable",
        p_summary: summary,
        p_details: details,
        p_dedupe_key: `provider_unreachable:${provider.mode}`,
      });

    if (job === "frequent") {
      const due = await rpc("payment_attempts_due_for_check", { p_limit: MAX_ATTEMPTS_PER_RUN });
      if (due.error) {
        deps.log(`reconciler could not list attempts: ${due.error.message}`);
        return res.status(500).json({ error: "Could not list attempts to check" });
      }
      const attempts = (Array.isArray(due.data) ? due.data : []) as AttemptRef[];
      const summary = { checked: 0, applied: 0, providerErrors: 0, unknownAtProvider: 0 };
      for (const attempt of attempts) {
        if (attempt.provider !== provider.name || attempt.mode !== provider.mode) continue;
        const result = await verifyAndApply({ provider, rpc }, attempt, "reconcile");
        if (!result.ok) {
          summary.providerErrors += result.error === "provider" ? 1 : 0;
          deps.log(`reconciler: ${result.error}: ${result.message}`);
          continue;
        }
        summary.checked += 1;
        if (result.outcome === "applied") summary.applied += 1;
        if (result.unknownAtProvider) summary.unknownAtProvider += 1;
      }
      if (summary.providerErrors > 0) {
        await reportProblem("The payment provider could not be reached while checking payments.", {
          errors: summary.providerErrors,
        });
      }
      const closed = await rpc("close_stale_payment_attempts", {});
      // Expiry is always asked for: the database itself refuses to cancel an order whose attempts were not checked recently.
      const expired = await rpc("expire_unpaid_online_orders", {});
      if (expired.error) deps.log(`reconciler expiry failed: ${expired.error.message}`);

      // Approved refunds are sent here (each is claimed by exactly one worker; an uncertain answer is never retried), and refunds that have
      // been sitting too long raise alerts.
      const refunds = { sent: 0, failed: 0, unknown: 0 };
      const refundsDue = await rpc("refunds_to_submit", { p_limit: MAX_REFUNDS_PER_RUN });
      const toSend = (Array.isArray(refundsDue.data) ? refundsDue.data : []) as {
        refund_id: string;
      }[];
      for (const item of toSend) {
        const result = await submitRefund({ provider, rpc, log: deps.log }, item.refund_id);
        if (!result.sent) continue;
        if (result.outcome === "failed") refunds.failed += 1;
        else if (result.outcome === "unknown") refunds.unknown += 1;
        else refunds.sent += 1;
      }
      const stale = await rpc("flag_stale_refunds", {});
      // An order that costs less than was paid, with no refund on the way (an earlier refund was cancelled), raises an alert.
      const unrefunded = await rpc("flag_unrefunded_balances", {});
      return res.status(200).json({
        job,
        ...summary,
        closedStale: typeof closed.data === "number" ? closed.data : 0,
        expiry: expired.error ? null : expired.data,
        refunds,
        staleRefundsFlagged: typeof stale.data === "number" ? stale.data : 0,
        unrefundedBalances: typeof unrefunded.data === "number" ? unrefunded.data : 0,
      });
    }

    // ---- daily comparison
    const to = deps.now();
    const from = new Date(to.getTime() - 25 * 60 * 60 * 1000);
    const transactions: ListedTransaction[] = [];
    let complete = false;
    try {
      for (let page = 1; page <= MAX_LIST_PAGES; page += 1) {
        const listed = await provider.listTransactions({
          from: from.toISOString(),
          to: to.toISOString(),
          page,
          perPage: PAGE_SIZE,
        });
        transactions.push(...listed.transactions);
        if (!listed.hasMore) {
          complete = true;
          break;
        }
      }
    } catch (error) {
      deps.log(
        `daily comparison could not list transactions: ${error instanceof ProviderError ? "provider" : "other"}: ${
          error instanceof Error ? error.message : "unknown"
        }`,
      );
      await reportProblem("The daily payment comparison could not read the provider's list.", {
        job: "daily",
      });
      return res.status(502).json({ error: "Could not read the provider's transactions" });
    }
    const compare = (final: boolean) =>
      rpc("reconcile_provider_transactions", {
        p_provider: provider.name,
        p_mode: provider.mode,
        p_from: from.toISOString(),
        p_to: to.toISOString(),
        p_transactions: transactions.map(toRow),
        p_complete: complete,
        p_final: final,
      });
    const first = await compare(false);
    if (first.error) {
      deps.log(`daily comparison failed: ${first.error.message}`);
      return res.status(500).json({ error: "The comparison failed" });
    }
    const firstResult = (first.data ?? {}) as { to_verify?: string[]; checked?: number };
    let verified = 0;
    let applied = 0;
    for (const reference of (firstResult.to_verify ?? []).slice(0, MAX_VERIFY_FROM_COMPARISON)) {
      const result = await verifyAndApply(
        { provider, rpc },
        { provider: provider.name, mode: provider.mode, reference },
        "reconcile",
      );
      if (result.ok) {
        verified += 1;
        if (result.outcome === "applied") applied += 1;
      } else {
        deps.log(`daily comparison: ${result.error}: ${result.message}`);
      }
    }
    const final = await compare(true);
    if (final.error) {
      deps.log(`daily comparison (final pass) failed: ${final.error.message}`);
      return res.status(500).json({ error: "The comparison failed" });
    }
    const finalResult = (final.data ?? {}) as { alerts?: number };
    return res.status(200).json({
      job,
      listed: transactions.length,
      complete,
      considered: firstResult.checked ?? 0,
      verified,
      applied,
      alertsRaised: finalResult.alerts ?? 0,
    });
  };
}
