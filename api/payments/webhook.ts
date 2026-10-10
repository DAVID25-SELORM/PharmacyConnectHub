// Paystack's notifications arrive here. The work is in api/_payments/webhook-handler.ts; this file only wires it to the real
// configuration, Paystack and the database. A notification is only a hint: the payment is verified with Paystack before anything is applied.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { createWebhookHandler, readRawBody } from "../_payments/webhook-handler.js";
import { createAdminRpc } from "../_payments/wiring.js";

export default createWebhookHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  readRawBody,
  log: (message) => console.warn(message),
});
