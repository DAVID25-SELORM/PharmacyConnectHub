// Supabase Edge Function: sends closed-tab Web Push alerts for unread notifications.
//
// Runs outside Vercel on purpose: Vercel's free (Hobby) plan rejects cron jobs that run more than
// once a day and caps the number of server functions. A database schedule (pg_cron + pg_net, see
// docs/push-dispatch-to-apply/schedule-push-dispatch.sql) calls this every 5 minutes.
//
// Secrets (Supabase > Edge Functions > Secrets): PUSH_CRON_SECRET, VAPID_PUBLIC_KEY,
// VAPID_PRIVATE_KEY, optional VAPID_SUBJECT. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// provided by the platform. Deploy with --no-verify-jwt: the caller is the database scheduler and
// authenticates with PUSH_CRON_SECRET instead of a user token.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";
import { runDispatch, type PushSub } from "./dispatch.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function sameSecret(given: string, expected: string) {
  if (given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const secret = Deno.env.get("PUSH_CRON_SECRET");
  const given = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!secret || !sameSecret(given, secret)) return json({ error: "Unauthorized" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY");
  const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!url || !key || !vapidPublic || !vapidPrivate) {
    return json({ error: "Push notifications are not configured." }, 503);
  }

  webpush.setVapidDetails(
    Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@drugxone.com",
    vapidPublic,
    vapidPrivate,
  );
  const db = createClient(url, key, { auth: { persistSession: false } });

  try {
    const result = await runDispatch({
      loadNotes: async () => {
        const { data, error } = await db
          .from("notifications")
          .select("id,user_id,title,body,link")
          .eq("read", false)
          .gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
          .order("created_at", { ascending: false })
          .limit(500);
        if (error) throw error;
        return data ?? [];
      },
      loadSubscriptions: async (userIds) => {
        const { data, error } = await db
          .from("push_subscriptions")
          .select("id,user_id,endpoint,p256dh,auth")
          .in("user_id", userIds);
        if (error) throw error;
        return data ?? [];
      },
      loadDeliveries: async (noteIds) => {
        const { data, error } = await db
          .from("push_notification_deliveries")
          .select("notification_id,subscription_id")
          .in("notification_id", noteIds);
        if (error) throw error;
        return data ?? [];
      },
      send: async (sub: PushSub, payload) => {
        await webpush.sendNotification(
          { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
          JSON.stringify(payload),
        );
      },
      recordDeliveries: async (rows) => {
        const { error } = await db
          .from("push_notification_deliveries")
          .upsert(rows, { onConflict: "notification_id,subscription_id", ignoreDuplicates: true });
        if (error) throw error;
      },
      removeSubscriptions: async (ids) => {
        const { error } = await db.from("push_subscriptions").delete().in("id", ids);
        if (error) throw error;
      },
    });
    return json(result);
  } catch (error) {
    console.error("push-dispatch failed", error);
    return json({ error: "Push dispatch failed." }, 500);
  }
});
