// What an administrator does to a refund (approve and send it, retry, cancel, confirm as refunded, mark as not sent). The work is in
// api/_payments/admin-refund-handler.ts; this file only wires it to the real configuration, Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createAdminRefundHandler } from "../_payments/admin-refund-handler.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { authenticateBearer, createAdminRpc } from "../_payments/wiring.js";

export default createAdminRefundHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  authenticate: authenticateBearer,
  log: (message) => console.warn(message),
});
