// The two endpoints a signed-in customer uses to pay for an online order, separated from the endpoint files so they can be
// tested with stand-ins for the provider and the database.
//
//   initialize   start (or resume) a payment: the database checks who may pay and for what amount, the provider is asked for a
//                checkout page, and the address of that page is returned. The amount always comes from the order, never the browser.
//   verify       called by the return page: asks the PROVIDER what happened to the order's recent payment attempts and records
//                the answer. Coming back from the checkout page proves nothing; only this server-to-server check can mark an
//                order paid, through the same single database function the webhook uses.
//
// See docs/pay-now-paystack-plan.md (sections 4 to 6).
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import type { RpcFn } from "./webhook-handler.js";
import { ProviderError, type PaymentProvider } from "./types.js";
import { newPaymentReference } from "./paystack.js";
import { verifyAndApply, type AttemptRef } from "./verify-apply.js";

export type CheckoutDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  /** Resolves a bearer token to a user id, or null when it is not a valid session. */
  authenticate: (token: string) => Promise<string | null>;
  /** The page the provider sends the customer back to. */
  returnUrl: (orderId: string, purpose?: PaymentPurpose) => string | null;
  log: (message: string) => void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** "order": the payment that pays an order. "top_up": an extra payment for a price increase on an order that is already paid. */
export type PaymentPurpose = "order" | "top_up";

function parseBody(req: VercelRequest): { orderId: string | null; purpose: PaymentPurpose } {
  let body: unknown = req.body;
  if (typeof body === "string") {
    try {
      body = JSON.parse(body);
    } catch {
      return { orderId: null, purpose: "order" };
    }
  }
  const input = (body ?? {}) as { orderId?: unknown; purpose?: unknown };
  return {
    orderId: typeof input.orderId === "string" && UUID.test(input.orderId) ? input.orderId : null,
    purpose: input.purpose === "top_up" ? "top_up" : "order",
  };
}

/** The database speaks to people in plain sentences; this maps them onto status codes without ever passing internals on. */
function statusForDatabaseMessage(message: string): number {
  if (/permission/i.test(message)) return 403;
  if (/too many/i.test(message)) return 429;
  if (/not found/i.test(message)) return 404;
  return 400;
}

type Prepared = {
  provider: PaymentProvider;
  rpc: RpcFn;
  userId: string;
  orderId: string;
  purpose: PaymentPurpose;
};

async function prepare(
  deps: CheckoutDeps,
  req: VercelRequest,
  res: VercelResponse,
): Promise<Prepared | null> {
  if (req.method !== "POST") {
    res.status(405).json({ error: "Method not allowed" });
    return null;
  }
  const configResult = deps.loadConfig();
  if (!configResult.ok) {
    res.status(configResult.status).json({ error: configResult.error });
    return null;
  }
  const header = req.headers.authorization;
  if (!header || !header.startsWith("Bearer ")) {
    res.status(401).json({ error: "Missing authorization" });
    return null;
  }
  const rpc = deps.createRpc();
  if (!rpc) {
    res.status(500).json({ error: "Server misconfigured" });
    return null;
  }
  const userId = await deps.authenticate(header.slice(7));
  if (!userId) {
    res.status(401).json({ error: "Invalid token" });
    return null;
  }
  const { orderId, purpose } = parseBody(req);
  if (!orderId) {
    res.status(400).json({ error: "A valid order is required." });
    return null;
  }
  return { provider: deps.createProvider(configResult.config), rpc, userId, orderId, purpose };
}

export function createInitializeHandler(deps: CheckoutDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    const ready = await prepare(deps, req, res);
    if (!ready) return;
    const { provider, rpc, userId, orderId, purpose } = ready;

    const callbackUrl = deps.returnUrl(orderId, purpose);
    if (!callbackUrl) {
      deps.log("payments initialize: no site address is configured for the return page");
      return res.status(500).json({ error: "Server misconfigured" });
    }

    const begun = await rpc(purpose === "top_up" ? "begin_order_topup" : "begin_order_payment", {
      p_caller_id: userId,
      p_order_id: orderId,
      p_provider: provider.name,
      p_mode: provider.mode,
      p_reference: newPaymentReference(provider.mode),
    });
    if (begun.error) {
      return res
        .status(statusForDatabaseMessage(begun.error.message))
        .json({ error: begun.error.message });
    }
    const attempt = begun.data as {
      reused: boolean;
      attempt_id: string;
      reference: string;
      amount_minor: number;
      email?: string;
      order_number?: string;
      authorization_url?: string;
    };

    if (attempt.reused && attempt.authorization_url) {
      return res.status(200).json({
        authorizationUrl: attempt.authorization_url,
        reference: attempt.reference,
        resumed: true,
      });
    }

    const failAttempt = (reason: string) =>
      rpc("fail_payment_attempt", { p_attempt_id: attempt.attempt_id, p_reason: reason });

    try {
      const initialized = await provider.initialize({
        email: attempt.email ?? "",
        amountMinor: Number(attempt.amount_minor),
        reference: attempt.reference,
        callbackUrl,
        metadata: { order_id: orderId, order_number: attempt.order_number },
      });
      const stored = await rpc("record_attempt_authorization", {
        p_attempt_id: attempt.attempt_id,
        p_authorization_url: initialized.authorizationUrl,
        p_access_code: initialized.accessCode,
      });
      if (stored.error) throw new Error(stored.error.message);
      return res.status(200).json({
        authorizationUrl: initialized.authorizationUrl,
        reference: attempt.reference,
        resumed: false,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown error";
      deps.log(
        `payments initialize failed: ${error instanceof ProviderError ? "provider" : "database"}: ${message}`,
      );
      await failAttempt(error instanceof ProviderError ? message : "Could not start the payment");
      return res.status(502).json({ error: "We could not start the payment. Please try again." });
    }
  };
}

export type VerifyOutcome = "paid" | "pending" | "failed" | "flagged" | "not_paid";

export function createVerifyHandler(deps: CheckoutDeps) {
  return async function handler(req: VercelRequest, res: VercelResponse) {
    const ready = await prepare(deps, req, res);
    if (!ready) return;
    const { provider, rpc, userId, orderId } = ready;

    const listed = await rpc("payment_attempts_to_check", {
      p_caller_id: userId,
      p_order_id: orderId,
    });
    if (listed.error) {
      return res
        .status(statusForDatabaseMessage(listed.error.message))
        .json({ error: listed.error.message });
    }
    const {
      payment_status: paymentStatus,
      topup_due: topupDue,
      throttled,
      attempts,
    } = listed.data as {
      payment_status: string;
      /** The order is paid, but a price increase means an extra payment is still due. */
      topup_due?: boolean;
      throttled?: boolean;
      attempts: AttemptRef[];
    };
    if (paymentStatus === "paid" && !topupDue) {
      return res.status(200).json({ status: "paid" satisfies VerifyOutcome });
    }
    // Asked again within a few seconds: answer from what is known (still waiting) without bothering the provider.
    if (throttled) return res.status(200).json({ status: "pending" satisfies VerifyOutcome });

    let status: VerifyOutcome = "not_paid";
    let providerTrouble = false;
    for (const attempt of attempts) {
      // Only attempts made in the mode this server runs in, with the provider this server talks to.
      if (attempt.provider !== provider.name || attempt.mode !== provider.mode) continue;
      const result = await verifyAndApply({ provider, rpc }, attempt, "verify");
      if (!result.ok) {
        if (result.error === "other_mode") {
          deps.log(`payments verify ignored ${result.message}`);
          continue;
        }
        providerTrouble = true;
        deps.log(`payments verify failed: ${result.error}: ${result.message}`);
        continue;
      }
      // The provider not knowing a reference (the customer never reached the checkout page) is not a problem.
      if (result.orderPaid) {
        status = "paid";
        break;
      }
      if (result.outcome === "flagged" || result.outcome === "late") status = "flagged";
      else if (result.outcome === "pending" && status === "not_paid") status = "pending";
      else if (result.outcome === "failed" && status === "not_paid") status = "failed";
    }
    // The answer is "we could not check" rather than a guess, so the page keeps asking.
    if (providerTrouble && status !== "paid") {
      return res.status(502).json({ error: "We could not check the payment just now." });
    }
    return res.status(200).json({ status });
  };
}
