// Reads the payment settings from the server environment, and refuses to start a payment when they are inconsistent.
// Nothing here is read by the browser; the secret key only ever lives in the server environment.
import { modeFromSecretKey } from "./paystack.js";
import type { ProviderMode } from "./types.js";

export type PaymentsConfig = { mode: ProviderMode; secretKey: string };

export type PaymentsConfigResult =
  { ok: true; config: PaymentsConfig } | { ok: false; status: number; error: string };

/**
 * PAYMENTS_MODE        "test" | "live"; anything else (or unset) means online payments are off.
 * PAYSTACK_SECRET_KEY  the secret key of that mode (sk_test_... for test, sk_live_... for live).
 * PAYMENTS_LIVE_ENABLED "yes" as a second, explicit switch before live mode does anything.
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
  return { ok: true, config: { mode, secretKey } };
}
