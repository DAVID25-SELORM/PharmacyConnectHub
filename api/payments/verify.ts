// Asks Paystack what happened to an order's recent payment attempts and records the answer (the return page calls this). The work
// is in api/_payments/checkout-handlers.ts; this file only wires it to the real configuration, Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createVerifyHandler } from "../_payments/checkout-handlers.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { paymentReturnUrl } from "../_payments/return-url.js";
import { authenticateBearer, createAdminRpc } from "../_payments/wiring.js";

export default createVerifyHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  authenticate: authenticateBearer,
  returnUrl: (orderId) => paymentReturnUrl(orderId),
  log: (message) => console.warn(message),
});
