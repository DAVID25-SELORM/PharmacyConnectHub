// Asks the provider (server to server) what happened to one payment attempt and records the answer through the one database function that can mark
// an order paid. Shared by the return page's check, the reconciler and the admin's "re-verify", so all three behave the same way: the provider's
// answer, never a redirect or a notification, is the evidence.
import { ProviderError, type PaymentProvider } from "./types.js";
import type { RpcFn } from "./webhook-handler.js";

export type AttemptRef = { attempt_id?: string; provider: string; mode: string; reference: string };

export type VerifyApplyResult =
  | {
      ok: true;
      outcome: string;
      orderPaid: boolean;
      /** The provider has never heard of this reference (the customer never reached the checkout page). */
      unknownAtProvider: boolean;
    }
  | { ok: false; error: "provider" | "database" | "other_mode"; message: string };

export async function verifyAndApply(
  deps: { provider: PaymentProvider; rpc: RpcFn },
  attempt: AttemptRef,
  source: "verify" | "reconcile",
): Promise<VerifyApplyResult> {
  const { provider, rpc } = deps;
  const markChecked = async () => {
    if (attempt.attempt_id) await rpc("mark_attempt_checked", { p_attempt_id: attempt.attempt_id });
  };
  let verified;
  try {
    verified = await provider.verify(attempt.reference);
  } catch (error) {
    // The provider not knowing a reference is an answer ("nothing was paid"); anything else means we do not know.
    if (error instanceof ProviderError && error.options.notFound) {
      await markChecked();
      return {
        ok: true,
        outcome: "unknown_at_provider",
        orderPaid: false,
        unknownAtProvider: true,
      };
    }
    return {
      ok: false,
      error: "provider",
      message: error instanceof Error ? error.message : "unknown error",
    };
  }
  if (verified.domain && verified.domain !== provider.mode) {
    return {
      ok: false,
      error: "other_mode",
      message: `a ${verified.domain}-mode answer in ${provider.mode} mode`,
    };
  }
  const applied = await rpc("apply_payment_result", {
    p_provider: provider.name,
    p_mode: provider.mode,
    p_reference: attempt.reference,
    p_provider_status: verified.status,
    p_amount_minor: verified.amountMinor,
    p_currency: verified.currency,
    p_transaction_id: verified.transactionId,
    p_channel: verified.channel,
    p_fee_minor: verified.feeMinor,
    p_source: source,
    p_event_id: null,
    p_failure_reason: verified.failureReason,
  });
  if (applied.error) return { ok: false, error: "database", message: applied.error.message };
  await markChecked();
  const result = (applied.data ?? {}) as { outcome?: string; order_paid?: boolean };
  return {
    ok: true,
    outcome: String(result.outcome ?? "unknown"),
    orderPaid: result.order_paid === true,
    unknownAtProvider: false,
  };
}
