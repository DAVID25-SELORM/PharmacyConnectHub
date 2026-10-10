// "Re-verify" on the admin Payments screen. The work is in api/_payments/admin-handler.ts; this file only wires it to the real configuration,
// Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createAdminReverifyHandler } from "../_payments/admin-handler.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { authenticateBearer, createAdminRpc } from "../_payments/wiring.js";

export default createAdminReverifyHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  authenticate: authenticateBearer,
  log: (message) => console.warn(message),
});
