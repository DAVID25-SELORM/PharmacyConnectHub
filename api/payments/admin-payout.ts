// Settlement accounts and the server's go-live checks, for platform administrators. The work is in api/_payments/admin-payout-handler.ts; this file only wires
// it to the real configuration, Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createAdminPayoutHandler } from "../_payments/admin-payout-handler.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { authenticateBearer, createAdminRpc } from "../_payments/wiring.js";

export default createAdminPayoutHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  authenticate: authenticateBearer,
  env: () => process.env,
  log: (message) => console.warn(message),
});
