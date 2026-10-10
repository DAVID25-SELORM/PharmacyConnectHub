// The real database and session wiring shared by the payment endpoints. Kept apart from the handlers so those can be tested with stand-ins.
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { RpcFn } from "./webhook-handler.js";

function adminClient(): SupabaseClient | null {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return null;
  return createClient(url, key, {
    auth: { storage: undefined, persistSession: false, autoRefreshToken: false },
  });
}

export function createAdminRpc(): RpcFn | null {
  const admin = adminClient();
  if (!admin) return null;
  return ((fn, args) => admin.rpc(fn, args)) as RpcFn;
}

export async function authenticateBearer(token: string): Promise<string | null> {
  const admin = adminClient();
  if (!admin) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user.id;
}
