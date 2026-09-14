import type { VercelRequest } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
export async function serverContext(req: VercelRequest) {
  const url = process.env.SUPABASE_URL,
    key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error("Server misconfigured");
  const token = req.headers.authorization?.startsWith("Bearer ")
    ? req.headers.authorization.slice(7)
    : "";
  const admin = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const {
    data: { user },
    error,
  } = await admin.auth.getUser(token);
  if (error || !user) throw new Error("Unauthorized");
  const caller = createClient(url, key, {
    accessToken: async () => token,
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { admin, caller, user };
}
export function trustedSiteUrl(path: string) {
  const site =
    process.env.SITE_URL || process.env.VITE_SITE_URL || process.env.VERCEL_PROJECT_PRODUCTION_URL;
  if (!site) throw new Error("Trusted SITE_URL is required");
  const base = new URL(site.startsWith("http") ? site : `https://${site}`);
  if (base.protocol !== "https:" && !["localhost", "127.0.0.1"].includes(base.hostname))
    throw new Error("HTTPS site URL required");
  return new URL(path, base).toString();
}
