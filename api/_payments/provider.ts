// The one place a configured provider is built, so the webhook and the checkout endpoints cannot differ.
import type { PaymentsConfig } from "./config.js";
import { PaystackProvider } from "./paystack.js";
import type { PaymentProvider } from "./types.js";

export function createPaymentProvider(config: PaymentsConfig): PaymentProvider {
  return new PaystackProvider({
    secretKey: config.secretKey,
    ...(config.baseUrl ? { baseUrl: config.baseUrl } : {}),
  });
}
