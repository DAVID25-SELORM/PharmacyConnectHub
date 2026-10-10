// Sends one approved refund to the provider and records exactly what happened. The one rule that matters: when it is NOT CERTAIN that the provider
// received the request (a timeout, a server error, a lost answer) the refund is recorded as "unknown" and is NEVER retried by this code; a person looks at
// the provider's dashboard first. Only a clear refusal (the provider answered with a 4xx) makes it "failed", which an administrator can retry.
import { ProviderError, type PaymentProvider } from "./types.js";
import type { RpcFn } from "./webhook-handler.js";

export type RefundRunResult =
  | {
      sent: false;
      reason: "not_claimable" | "provider_mismatch" | "database_error";
      message?: string;
    }
  | { sent: true; outcome: "processing" | "succeeded" | "failed" | "unknown"; message?: string };

type Claimed = {
  refund_id: string;
  provider: string;
  mode: string;
  transaction_reference: string;
  amount_minor: number;
  reason: string;
};

export async function submitRefund(
  deps: { provider: PaymentProvider; rpc: RpcFn; log: (message: string) => void },
  refundId: string,
): Promise<RefundRunResult> {
  const { provider, rpc, log } = deps;
  const claimed = await rpc("claim_refund_for_submission", { p_refund_id: refundId });
  if (claimed.error) {
    log(`refund ${refundId} could not be claimed: ${claimed.error.message}`);
    return { sent: false, reason: "database_error", message: claimed.error.message };
  }
  // Somebody else has it, or it is not approved any more: nothing to do.
  if (!claimed.data) return { sent: false, reason: "not_claimable" };
  const job = claimed.data as Claimed;
  if (job.provider !== provider.name || job.mode !== provider.mode) {
    // It was claimed for another provider or mode than this server runs: it cannot be sent from here, and must not be left "submitting".
    await rpc("record_refund_rejection", {
      p_refund_id: refundId,
      p_reason: `This server is set up for ${provider.mode} mode, the payment was made in ${job.mode} mode.`,
      p_definite: true,
    });
    return { sent: false, reason: "provider_mismatch" };
  }
  try {
    const result = await provider.refund({
      transactionReference: job.transaction_reference,
      amountMinor: Number(job.amount_minor),
      merchantNote: `DrugXOne refund (${job.reason.replace(/_/g, " ")})`,
    });
    const recorded = await rpc("record_refund_submission", {
      p_refund_id: refundId,
      p_provider_refund_id: result.providerRefundId,
      p_provider_status: result.status,
    });
    if (recorded.error) {
      // The provider has the request but we could not write that down: a person must check, never a second send.
      log(`refund ${refundId} was sent but could not be recorded: ${recorded.error.message}`);
      await rpc("record_refund_rejection", {
        p_refund_id: refundId,
        p_reason: "The refund was sent but the answer could not be recorded.",
        p_definite: false,
      });
      return { sent: true, outcome: "unknown", message: recorded.error.message };
    }
    const status = String(recorded.data);
    return {
      sent: true,
      outcome: status === "succeeded" || status === "failed" ? status : "processing",
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown error";
    // A refusal the provider put into words (a 4xx) is definite. Anything else (no answer, a 5xx, a timeout) is not.
    const status = error instanceof ProviderError ? error.options.status : undefined;
    const definite = typeof status === "number" && status >= 400 && status < 500;
    log(`refund ${refundId} ${definite ? "was refused" : "has an unknown outcome"}: ${message}`);
    const recorded = await rpc("record_refund_rejection", {
      p_refund_id: refundId,
      p_reason: definite
        ? message
        : `${message} (it is not known whether the provider received the request)`,
      p_definite: definite,
    });
    if (recorded.error) {
      log(`refund ${refundId}: the outcome could not be recorded: ${recorded.error.message}`);
      return { sent: true, outcome: "unknown", message: recorded.error.message };
    }
    return { sent: true, outcome: definite ? "failed" : "unknown", message };
  }
}
