import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import webpush from "web-push";

export default async function dispatch(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const cronSecret = process.env.PUSH_CRON_SECRET || process.env.CRON_SECRET;
  if (!cronSecret || req.headers.authorization !== `Bearer ${cronSecret}`) return res.status(401).json({ error: "Unauthorized" });
  const { SUPABASE_URL: url, SUPABASE_SERVICE_ROLE_KEY: key, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT = "mailto:admin@drugxone.com" } = process.env;
  if (!url || !key || !VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) return res.status(503).json({ error: "Push notifications are not configured." });
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
  const db = createClient(url, key, { auth: { persistSession: false } });
  const { data: notes } = await db.from("notifications").select("id,user_id,title,body,link,created_at").eq("read", false).gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()).limit(500);
  let sent = 0;
  for (const note of notes ?? []) {
    const { data: subs } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", note.user_id);
    for (const sub of subs ?? []) {
      const { data: prior } = await db.from("push_notification_deliveries").select("notification_id").eq("notification_id", note.id).eq("subscription_id", sub.id).maybeSingle();
      if (prior) continue;
      try { await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, JSON.stringify({ title: note.title, body: note.body, link: note.link || "/notifications", tag: note.id })); await db.from("push_notification_deliveries").insert({ notification_id: note.id, subscription_id: sub.id }); sent++; }
      catch (e: any) { if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("push_subscriptions").delete().eq("id", sub.id); }
    }
  }
  return res.status(200).json({ sent });
}
