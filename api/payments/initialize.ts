// Starts (or resumes) the online payment of an order. The work is in api/_payments/checkout-handlers.ts; this file only wires it to
// the real configuration, Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createInitializeHandler } from "../_payments/checkout-handlers.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { paymentReturnUrl } from "../_payments/return-url.js";
import { authenticateBearer, createAdminRpc } from "../_payments/wiring.js";

export default createInitializeHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  authenticate: authenticateBearer,
  returnUrl: (orderId) => paymentReturnUrl(orderId),
  log: (message) => console.warn(message),
});
