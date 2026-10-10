// Paystack's notifications arrive here. The work is in api/_payments/webhook-handler.ts; this file only wires it to the real
// configuration, Paystack and the database. A notification is only a hint: the payment is verified with Paystack before anything is applied.
import { createClient } from "@supabase/supabase-js";
import { loadPaymentsConfig } from "../_payments/config.js";
import { PaystackProvider } from "../_payments/paystack.js";
import { createWebhookHandler, readRawBody, type RpcFn } from "../_payments/webhook-handler.js";

export default createWebhookHandler({
  loadConfig: () => loadPaymentsConfig(),
  createProvider: (config) => new PaystackProvider({ secretKey: config.secretKey }),
  createRpc: () => {
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) return null;
    const admin = createClient(url, key, {
      auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
    });
    return ((fn, args) => admin.rpc(fn, args)) as RpcFn;
  },
  readRawBody,
  log: (message) => console.warn(message),
});
