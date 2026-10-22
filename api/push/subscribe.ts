import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

export default async function subscribe(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return res.status(503).json({ error: "Push notifications are not configured." });
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, "");
  if (!token) return res.status(401).json({ error: "Sign in first." });
  const admin = createClient(url, key, { auth: { persistSession: false } });
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return res.status(401).json({ error: "Sign in again." });
  const sub = req.body?.subscription;
  if (!sub || typeof sub.endpoint !== "string" || typeof sub.keys?.p256dh !== "string" || typeof sub.keys?.auth !== "string")
    return res.status(400).json({ error: "Invalid push subscription." });
  const { error } = await admin.from("push_subscriptions").upsert({ user_id: user.id, endpoint: sub.endpoint, p256dh: sub.keys.p256dh, auth: sub.keys.auth, user_agent: req.headers["user-agent"] ?? null, last_seen_at: new Date().toISOString() }, { onConflict: "endpoint" });
  if (error) return res.status(500).json({ error: "Could not save push subscription." });
  return res.status(204).end();
}
