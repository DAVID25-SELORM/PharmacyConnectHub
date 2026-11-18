import { supabase } from "@/integrations/supabase/client";

type PushRow = {
  user_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  user_agent: string | null;
  last_seen_at: string;
};

// The push tables are newer than the generated Supabase types.
const pushTable = () =>
  (
    supabase as unknown as {
      from: (table: string) => {
        upsert: (
          row: PushRow,
          options: { onConflict: string },
        ) => PromiseLike<{ error: { message: string } | null }>;
      };
    }
  ).from("push_subscriptions");

/** Browsers hand the VAPID public key over as base64url; pushManager wants raw bytes. */
export function vapidKeyToBytes(key: string) {
  const base64 = key.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

export function subscriptionToRow(
  subscription: Pick<PushSubscription, "toJSON">,
  userId: string,
  userAgent: string | null,
  now = new Date(),
): PushRow | null {
  const json = subscription.toJSON();
  if (!json.endpoint || !json.keys?.p256dh || !json.keys?.auth) {
    return null;
  }
  return {
    user_id: userId,
    endpoint: json.endpoint,
    p256dh: json.keys.p256dh,
    auth: json.keys.auth,
    user_agent: userAgent,
    last_seen_at: now.toISOString(),
  };
}

async function save(subscription: PushSubscription, userId: string) {
  const row = subscriptionToRow(subscription, userId, navigator.userAgent || null);
  if (!row) {
    return false;
  }
  const { error } = await pushTable().upsert(row, { onConflict: "endpoint" });
  return !error;
}

/**
 * Subscribe this browser for closed-tab alerts and store the subscription for the signed-in user.
 * The table's row-level security only lets a user write their own rows, so no server function is
 * needed. If the browser's subscription already belongs to another account (shared device), it is
 * replaced with a fresh one for this user.
 */
export async function enableWebPush(vapidPublicKey: string, userId: string) {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return false;
  }

  const registration = await navigator.serviceWorker.register("/sw.js");
  const options = {
    userVisibleOnly: true,
    applicationServerKey: vapidKeyToBytes(vapidPublicKey),
  };

  let subscription = await registration.pushManager.subscribe(options);
  if (await save(subscription, userId)) {
    return true;
  }

  await subscription.unsubscribe();
  subscription = await registration.pushManager.subscribe(options);
  return save(subscription, userId);
}
