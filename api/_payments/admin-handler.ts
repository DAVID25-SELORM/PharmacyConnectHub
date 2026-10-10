// "Re-verify" on the admin Payments screen: a platform administrator asks the provider again about the payment attempts of one order and the answer
// is recorded through the same function as everywhere else. It can only ever move an order towards what the provider says; it cannot mark anything
// paid by itself and it does not move money.
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import type { PaymentProvider } from "./types.js";
import { verifyAndApply, type AttemptRef } from "./verify-apply.js";
import type { RpcFn } from "./webhook-handler.js";

export type AdminReverifyDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  authenticate: (token: string) => Promise<string | null>;
  log: (message: string) => void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function createAdminReverifyHandler(deps: AdminReverifyDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
    const configResult = deps.loadConfig();
    if (!configResult.ok)
      return res.status(configResult.status).json({ error: configResult.error });
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
    const orderId = (body as { orderId?: unknown } | null)?.orderId;
    if (typeof orderId !== "string" || !UUID.test(orderId)) {
      return res.status(400).json({ error: "A valid order is required." });
    }
    const provider = deps.createProvider(configResult.config);
    const listed = await rpc("admin_attempts_to_reverify", {
      p_admin_id: userId,
      p_order_id: orderId,
    });
    if (listed.error) return res.status(400).json({ error: listed.error.message });
    const attempts = (Array.isArray(listed.data) ? listed.data : []) as AttemptRef[];
    const outcomes: { reference: string; outcome: string }[] = [];
    let orderPaid = false;
    for (const attempt of attempts) {
      if (attempt.provider !== provider.name || attempt.mode !== provider.mode) continue;
      const result = await verifyAndApply({ provider, rpc }, attempt, "reconcile");
      if (!result.ok) {
        deps.log(`admin re-verify: ${result.error}: ${result.message}`);
        outcomes.push({ reference: attempt.reference, outcome: `could_not_check_${result.error}` });
        continue;
      }
      outcomes.push({ reference: attempt.reference, outcome: result.outcome });
      if (result.orderPaid) {
        orderPaid = true;
        break;
      }
    }
    return res.status(200).json({ orderPaid, outcomes });
  };
}
