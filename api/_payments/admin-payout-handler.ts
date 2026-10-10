// What an administrator does about where suppliers' money settles, and the server half of the go-live checks:
//   banks      the banks and mobile money operators a settlement account can be paid into (asked of the provider)
//   register   create a supplier's settlement account at the provider. The full account number goes to the provider and nowhere else: it is not stored, not logged,
//              not returned. Only its last four digits are kept.
//   set_active switch a supplier's settlement account off or back on
//   checks     what the server's own configuration says about being ready (names and yes/no only; never a key's value)
// Every action requires a platform administrator, re-checked by the database.
import type { VercelRequest, VercelResponse } from "@vercel/node";
import type { PaymentsConfig, PaymentsConfigResult } from "./config.js";
import { modeFromSecretKey } from "./paystack.js";
import { ProviderError, type PaymentProvider } from "./types.js";
import type { RpcFn } from "./webhook-handler.js";

export type AdminPayoutDeps = {
  loadConfig: () => PaymentsConfigResult;
  createProvider: (config: PaymentsConfig) => PaymentProvider;
  createRpc: () => RpcFn | null;
  authenticate: (token: string) => Promise<string | null>;
  env: () => Record<string, string | undefined>;
  log: (message: string) => void;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BANK_CODE = /^[A-Za-z0-9_-]{1,20}$/;
const ACCOUNT_NUMBER = /^[0-9]{6,20}$/;

/** The server's own readiness, as yes/no answers. Nothing here reveals a value. */
export function serverChecks(env: Record<string, string | undefined>) {
  const mode = env.PAYMENTS_MODE;
  const key = env.PAYSTACK_SECRET_KEY?.trim();
  let keyMode: string | null = null;
  try {
    keyMode = key ? modeFromSecretKey(key) : null;
  } catch {
    keyMode = null;
  }
  const checks = [
    {
      key: "mode_set",
      ok: mode === "test" || mode === "live",
      detail: "PAYMENTS_MODE is set to test or live.",
    },
    {
      key: "key_present",
      ok: !!key && keyMode !== null,
      detail: "A Paystack secret key is set and looks like a test or live key.",
    },
    {
      key: "key_matches_mode",
      ok: keyMode !== null && keyMode === mode,
      detail: "The key's kind (test or live) matches PAYMENTS_MODE.",
    },
    {
      key: "live_switch",
      ok: mode !== "live" || env.PAYMENTS_LIVE_ENABLED === "yes",
      detail: "For live mode, PAYMENTS_LIVE_ENABLED is yes (the second server switch).",
    },
    {
      key: "cron_secret",
      ok: !!env.CRON_SECRET?.trim(),
      detail: "CRON_SECRET is set (the scheduler's shared secret).",
    },
    {
      key: "site_address",
      ok: !!(
        env.SITE_URL?.trim() ||
        env.VITE_SITE_URL?.trim() ||
        env.VERCEL_PROJECT_PRODUCTION_URL?.trim()
      ),
      detail: "The site's own address is configured (where customers return after paying).",
    },
    {
      key: "no_local_stand_in",
      ok: !env.PAYSTACK_BASE_URL?.trim(),
      detail: "No local stand-in address for the provider is configured.",
    },
  ];
  return { mode: mode === "test" || mode === "live" ? mode : null, checks };
}

export function createAdminPayoutHandler(deps: AdminPayoutDeps) {
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
    const input = (body ?? {}) as Record<string, unknown>;

    if (input.action === "checks") {
      return res.status(200).json(serverChecks(deps.env()));
    }

    // The rest talk to the provider (or at least need to know its mode), so the server must be configured for it.
    const configResult = deps.loadConfig();
    if (!configResult.ok && input.action !== "set_active") {
      return res.status(configResult.status).json({ error: configResult.error });
    }

    if (input.action === "banks") {
      if (!configResult.ok)
        return res.status(503).json({ error: "Online payments are not configured." });
      try {
        const banks = await deps.createProvider(configResult.config).listBanks();
        return res.status(200).json({ banks });
      } catch (error) {
        deps.log(`payout banks failed: ${error instanceof ProviderError ? "provider" : "other"}`);
        return res.status(502).json({ error: "Could not read the list of banks just now." });
      }
    }

    if (input.action === "set_active") {
      if (
        typeof input.accountId !== "string" ||
        !UUID.test(input.accountId) ||
        typeof input.active !== "boolean"
      ) {
        return res.status(400).json({ error: "A valid settlement account is required." });
      }
      const changed = await rpc("admin_set_payout_account_status", {
        p_admin_id: userId,
        p_id: input.accountId,
        p_active: input.active,
      });
      if (changed.error) return res.status(400).json({ error: changed.error.message });
      return res.status(200).json({ status: changed.data });
    }

    if (input.action === "register") {
      if (!configResult.ok)
        return res.status(503).json({ error: "Online payments are not configured." });
      const businessName = typeof input.businessName === "string" ? input.businessName.trim() : "";
      const accountNumber =
        typeof input.accountNumber === "string" ? input.accountNumber.replace(/[\s-]/g, "") : "";
      if (typeof input.wholesalerId !== "string" || !UUID.test(input.wholesalerId)) {
        return res.status(400).json({ error: "Choose a supplier." });
      }
      if (businessName.length < 2 || businessName.length > 120) {
        return res
          .status(400)
          .json({ error: "Enter the account's business name (2 to 120 letters)." });
      }
      if (typeof input.bankCode !== "string" || !BANK_CODE.test(input.bankCode)) {
        return res.status(400).json({ error: "Choose a bank or mobile money operator." });
      }
      if (!ACCOUNT_NUMBER.test(accountNumber)) {
        return res
          .status(400)
          .json({ error: "Enter the account number using digits only (6 to 20)." });
      }
      const provider = deps.createProvider(configResult.config);
      // The record is made first (it also refuses a second account), then the provider is asked, then the record is finished with the answer.
      const begun = await rpc("begin_payout_account", {
        p_admin_id: userId,
        p_wholesaler_id: input.wholesalerId,
        p_mode: provider.mode,
        p_business_name: businessName,
        p_bank_code: input.bankCode,
        p_account_last4: accountNumber.slice(-4),
      });
      if (begun.error) return res.status(400).json({ error: begun.error.message });
      const id = begun.data as string;
      let created: { subaccountCode: string };
      try {
        created = await provider.createSubaccount({
          businessName,
          bankCode: input.bankCode,
          accountNumber,
        });
      } catch (error) {
        const refused =
          error instanceof ProviderError &&
          typeof error.options.status === "number" &&
          error.options.status >= 400 &&
          error.options.status < 500;
        deps.log(
          `payout register failed: ${error instanceof ProviderError ? "provider" : "other"}`,
        );
        // A refusal is final. If the answer was lost, the provider may have created it: say so, so a person checks its dashboard before trying again.
        const reason = refused
          ? `The provider refused it: ${error instanceof Error ? error.message : "no reason given"}`.slice(
              0,
              400,
            )
          : "No answer from the provider. It may have been created: check the provider's dashboard before trying again.";
        await rpc("finish_payout_account", {
          p_id: id,
          p_subaccount_code: null,
          p_failure: reason,
        });
        return res.status(refused ? 400 : 502).json({ error: reason });
      }
      const finished = await rpc("finish_payout_account", {
        p_id: id,
        p_subaccount_code: created.subaccountCode,
        p_failure: null,
      });
      if (finished.error) {
        deps.log("payout register: the provider created the account but it could not be recorded");
        return res.status(500).json({
          error:
            "The account was created at the provider but could not be recorded. Contact engineering before trying again.",
        });
      }
      return res.status(200).json({ id, status: finished.data });
    }

    return res.status(400).json({ error: "Unknown action." });
  };
}
