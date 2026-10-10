// What an administrator does to a refund from the Payments screen: approve it (and send it), retry one that failed, cancel one, confirm one as refunded
// by hand (after checking the provider's dashboard), or mark one as not sent. The state changes are made by the database, which re-checks that the caller is an
// administrator; sending is the same code the reconciler uses. Nothing here can send money that was not approved.
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import { submitRefund } from "./refund-runner.js";
import type { PaymentProvider } from "./types.js";
import type { RpcFn } from "./webhook-handler.js";

export type AdminRefundDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  authenticate: (token: string) => Promise<string | null>;
  log: (message: string) => void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const REFUND_ACTIONS = [
  "approve",
  "retry",
  "cancel",
  "confirm_refunded",
  "mark_failed",
] as const;

export function createAdminRefundHandler(deps: AdminRefundDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
    const header = req.headers.authorization;
    if (!header?.startsWith("Bearer "))
      return res.status(401).json({ error: "Missing authorization" });
    const rpc = deps.createRpc();
    if (!rpc) return res.status(500).json({ error: "Server misconfigured" });
    const userId = await deps.authenticate(header.slice(7));
    if (!userId) return res.status(401).json({ error: "Invalid token" });
    const isAdmin = await rpc("payment_user_is_admin", { p_user_id: userId });
    if (isAdmin.error || isAdmin.data !== true) {
      return res.status(403).json({ error: "Only platform administrators can do this." });
    }
    let body: unknown = req.body;
    if (typeof body === "string") {
      try {
        body = JSON.parse(body);
      } catch {
        body = null;
      }
    }
    const input = (body ?? {}) as {
      refundId?: unknown;
      orderId?: unknown;
      action?: unknown;
      note?: unknown;
    };

    // "This order costs less than was paid and no refund is on the way": ask for a refund of the difference (a person's decision, after an earlier request was
    // cancelled or failed for good). It is only a REQUEST; it still waits for approval like every refund.
    if (input.action === "request_balance_refund") {
      if (typeof input.orderId !== "string" || !UUID.test(input.orderId)) {
        return res.status(400).json({ error: "A valid order is required." });
      }
      const requested = await rpc("admin_request_balance_refund", {
        p_admin_id: userId,
        p_order_id: input.orderId,
      });
      if (requested.error) return res.status(400).json({ error: requested.error.message });
      const result = (requested.data ?? {}) as {
        requested_minor?: number;
        unplaced_minor?: number;
      };
      return res.status(200).json({
        requestedMinor: result.requested_minor ?? 0,
        unplacedMinor: result.unplaced_minor ?? 0,
      });
    }

    if (typeof input.refundId !== "string" || !UUID.test(input.refundId)) {
      return res.status(400).json({ error: "A valid refund is required." });
    }
    if (
      typeof input.action !== "string" ||
      !(REFUND_ACTIONS as readonly string[]).includes(input.action)
    ) {
      return res.status(400).json({ error: "Unknown action." });
    }
    const note = typeof input.note === "string" ? input.note : null;

    const changed = await rpc("admin_refund_transition", {
      p_admin_id: userId,
      p_refund_id: input.refundId,
      p_action: input.action,
      p_note: note,
    });
    if (changed.error) return res.status(400).json({ error: changed.error.message });
    const result = (changed.data ?? {}) as { status?: string; needs_submission?: boolean };
    if (!result.needs_submission) return res.status(200).json({ status: result.status });

    // Approved (or retried): send it now rather than waiting for the next scheduled run.
    const configResult = deps.loadConfig();
    if (!configResult.ok) {
      return res.status(200).json({
        status: result.status,
        sent: false,
        message:
          "The refund is approved. It will be sent as soon as online payments are configured on the server.",
      });
    }
    const sent = await submitRefund(
      { provider: deps.createProvider(configResult.config), rpc, log: deps.log },
      input.refundId,
    );
    return res.status(200).json({
      status: result.status,
      sent: sent.sent,
      outcome: sent.sent ? sent.outcome : undefined,
      message: sent.sent ? sent.message : undefined,
    });
  };
}
