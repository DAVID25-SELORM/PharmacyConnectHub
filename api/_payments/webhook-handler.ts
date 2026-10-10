// The handler for Paystack's notifications, separated from the endpoint file so it can be tested with stand-ins.
// A notification is only ever a HINT to go and check: it is stored first, its signature is checked against the raw body, and then
// the payment is verified with Paystack (server to server) before anything is applied. Duplicates, retries and out-of-order
// notifications are harmless: the notification is stored once, and the database function that records the result is idempotent.
// See docs/pay-now-paystack-plan.md (sections 4 and 5).
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import { ProviderError, type PaymentProvider } from "./types.js";

export type RpcFn = (
  fn: string,
  args: Record<string, unknown>,
) => PromiseLike<{ data: unknown; error: { message: string } | null }>;

export type WebhookDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  readRawBody: (req: VercelRequest) => Promise<Buffer>;
  log: (message: string) => void;
};

/** The raw bytes of the request. The body must NOT be read through `req.body` first: parsing it would change the bytes the signature
 * was computed over. */
export async function readRawBody(req: VercelRequest): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of req as unknown as AsyncIterable<Buffer | string>) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

export function createWebhookHandler(deps: WebhookDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    if (req.method !== "POST") {
      return res.status(405).json({ error: "Method not allowed" });
    }
    const configResult = deps.loadConfig();
    if (!configResult.ok) {
      return res.status(configResult.status).json({ error: configResult.error });
    }
    const provider = deps.createProvider(configResult.config);

    const raw = await deps.readRawBody(req);
    const signature = req.headers["x-paystack-signature"];
    const parsed = provider.parseWebhook(raw, Array.isArray(signature) ? signature[0] : signature);
    if (!parsed.ok) {
      deps.log(`payments webhook refused: ${parsed.reason}`);
      return res
        .status(parsed.reason === "invalid_signature" ? 401 : 400)
        .json({ error: "Invalid notification" });
    }
    const { event } = parsed;

    // A notification from the other mode (a test notification reaching a live endpoint, or the reverse) is acknowledged and ignored.
    if (event.domain && event.domain !== provider.mode) {
      deps.log(
        `payments webhook ignored: ${event.domain}-mode event received in ${provider.mode} mode`,
      );
      return res.status(200).json({ ignored: "mode" });
    }

    const rpc = deps.createRpc();
    if (!rpc) {
      return res.status(500).json({ error: "Server misconfigured" });
    }

    // Store it before anything else is done with it.
    const recorded = await rpc("record_payment_provider_event", {
      p_provider: provider.name,
      p_dedupe_key: event.dedupeKey,
      p_event_type: event.event,
      p_reference: event.reference,
      p_mode: provider.mode,
      p_payload: JSON.parse(raw.toString("utf8")),
    });
    if (recorded.error || !recorded.data) {
      deps.log(`payments webhook could not be stored: ${recorded.error?.message ?? "no data"}`);
      return res.status(500).json({ error: "Could not store the notification" });
    }
    const stored = recorded.data as { event_id: string; already_processed: boolean };
    if (stored.already_processed) {
      return res.status(200).json({ duplicate: true });
    }

    const finish = (outcome: string, error?: string) =>
      rpc("finish_payment_provider_event", {
        p_event_id: stored.event_id,
        p_outcome: outcome,
        p_error: error ?? null,
      });

    // A refund notification: the signature has been checked, so it is believed (it moves money OUT, never in), and applied to the refund that was
    // sent. One that matches nothing becomes an alert for a person; it is never silently applied.
    if (event.event.startsWith("refund.")) {
      try {
        const applied = await rpc("apply_refund_event", {
          p_provider: provider.name,
          p_mode: provider.mode,
          p_transaction_reference: event.transactionReference ?? event.reference,
          p_event_type: event.event,
          p_provider_refund_id: event.refundId ?? null,
          p_amount_minor: event.amountMinor ?? null,
        });
        if (applied.error) throw new Error(applied.error.message);
        const outcome = String((applied.data as { outcome?: string } | null)?.outcome ?? "unknown");
        await finish(outcome);
        return res.status(200).json({ outcome });
      } catch (error) {
        const message = error instanceof Error ? error.message : "unknown error";
        deps.log(`payments webhook refund processing failed: ${message}`);
        await finish("error", message);
        return res.status(500).json({ error: "Could not process the notification" });
      }
    }

    // Only a successful charge matters here; every other kind is stored and acknowledged.
    if (event.event !== "charge.success" || !event.reference) {
      await finish("ignored");
      return res.status(200).json({ outcome: "ignored" });
    }

    try {
      // The notification is a hint: ask Paystack what really happened.
      const verified = await provider.verify(event.reference);
      const applied = await rpc("apply_payment_result", {
        p_provider: provider.name,
        p_mode: provider.mode,
        p_reference: event.reference,
        p_provider_status: verified.status,
        p_amount_minor: verified.amountMinor,
        p_currency: verified.currency,
        p_transaction_id: verified.transactionId,
        p_channel: verified.channel,
        p_fee_minor: verified.feeMinor,
        p_source: "webhook",
        p_event_id: stored.event_id,
        p_failure_reason: verified.failureReason,
      });
      if (applied.error) throw new Error(applied.error.message);
      const outcome = String((applied.data as { outcome?: string } | null)?.outcome ?? "unknown");
      await finish(outcome);
      return res.status(200).json({ outcome });
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      deps.log(
        `payments webhook processing failed: ${error instanceof ProviderError ? "provider" : "database"}: ${message}`,
      );
      await finish("error", message);
      // A 5xx makes Paystack send it again, which is safe: the result is applied at most once.
      return res.status(500).json({ error: "Could not process the notification" });
    }
  };
}
