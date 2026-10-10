// Reads the payment settings from the server environment, and refuses to start a payment when they are inconsistent.
// Nothing here is read by the browser; the secret key only ever lives in the server environment.
import { modeFromSecretKey } from "./paystack.js";
import type { ProviderMode } from "./types.js";

export type PaymentsConfig = { mode: ProviderMode; secretKey: string; baseUrl?: string };

export type PaymentsConfigResult =
  { ok: true; config: PaymentsConfig } | { ok: false; status: number; error: string };

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

/**
 * PAYMENTS_MODE        "test" | "live"; anything else (or unset) means online payments are off.
 * PAYSTACK_SECRET_KEY  the secret key of that mode (sk_test_... for test, sk_live_... for live).
 * PAYMENTS_LIVE_ENABLED "yes" as a second, explicit switch before live mode does anything.
 * PAYSTACK_BASE_URL    only for local testing against a stand-in for Paystack: honoured in test mode, and only for a local address.
 *                      Anywhere else it makes the configuration invalid (a typo must never send a secret key to another host).
 *
 * The key's prefix must match the mode: a live key in test mode, or a test key in live mode, is refused outright.
 */
export function loadPaymentsConfig(
  env: Record<string, string | undefined> = process.env,
): PaymentsConfigResult {
  const mode = env.PAYMENTS_MODE;
  if (mode !== "test" && mode !== "live") {
    return { ok: false, status: 503, error: "Online payments are not enabled." };
  }
  const secretKey = env.PAYSTACK_SECRET_KEY?.trim();
  if (!secretKey) {
    return { ok: false, status: 503, error: "Online payments are not configured." };
  }
  let keyMode: ProviderMode;
  try {
    keyMode = modeFromSecretKey(secretKey);
  } catch {
    return { ok: false, status: 500, error: "Online payments are misconfigured." };
  }
  if (keyMode !== mode) {
    return { ok: false, status: 500, error: "Online payments are misconfigured." };
  }
  if (mode === "live" && env.PAYMENTS_LIVE_ENABLED !== "yes") {
    return { ok: false, status: 503, error: "Online payments are not enabled." };
  }
  let baseUrl: string | undefined;
  const rawBase = env.PAYSTACK_BASE_URL?.trim();
  if (rawBase) {
    try {
      const url = new URL(rawBase);
      if (mode !== "test" || !LOCAL_HOSTS.has(url.hostname) || !/^https?:$/.test(url.protocol)) {
        throw new Error("not allowed");
      }
      baseUrl = rawBase.replace(/\/+$/, "");
    } catch {
      return { ok: false, status: 500, error: "Online payments are misconfigured." };
    }
  }
  return { ok: true, config: { mode, secretKey, ...(baseUrl ? { baseUrl } : {}) } };
}
