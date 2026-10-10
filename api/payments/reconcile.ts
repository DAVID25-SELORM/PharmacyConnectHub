// The scheduled reconciler: checks open payments with the provider, cancels online orders whose payment window ended, and compares the day's
// transactions with ours. Called by a scheduler with a shared secret (CRON_SECRET); see docs/payments/scheduling-the-reconciler.md. The work is in
// api/_payments/reconcile-handler.ts; this file only wires it to the real configuration, Paystack and the database.
import { loadPaymentsConfig } from "../_payments/config.js";
import { createPaymentProvider } from "../_payments/provider.js";
import { createReconcileHandler } from "../_payments/reconcile-handler.js";
import { createAdminRpc } from "../_payments/wiring.js";

export default createReconcileHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: createPaymentProvider,
  createRpc: createAdminRpc,
  cronSecret: () => process.env.CRON_SECRET?.trim() || undefined,
  now: () => new Date(),
  log: (message) => console.warn(message),
});
