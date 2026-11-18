// Core of the closed-tab push delivery job. No runtime-specific imports, so it is unit-tested
// under Node (src/lib/push-dispatch.test.ts) and used unchanged by the Deno edge function.

export type PushNote = {
  id: string;
  user_id: string;
  title: string | null;
  body: string | null;
  link: string | null;
};

export type PushSub = {
  id: string;
  user_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
};

export type PushPayload = { title: string; body: string; link: string; tag: string };

export type Delivery = { notification_id: string; subscription_id: string };

export type DispatchDeps = {
  /** Unread notifications from the last 24 hours, newest first, capped by the caller. */
  loadNotes: () => Promise<PushNote[]>;
  loadSubscriptions: (userIds: string[]) => Promise<PushSub[]>;
  loadDeliveries: (noteIds: string[]) => Promise<Delivery[]>;
  /** Throws an error carrying statusCode 404/410 when the browser has dropped the subscription. */
  send: (sub: PushSub, payload: PushPayload) => Promise<void>;
  recordDeliveries: (rows: Delivery[]) => Promise<void>;
  removeSubscriptions: (ids: string[]) => Promise<void>;
};

export type DispatchResult = {
  notifications: number;
  sent: number;
  failed: number;
  removed: number;
};

export function buildPayload(note: PushNote): PushPayload {
  return {
    title: note.title || "DrugXOne",
    body: note.body || "You have a new notification.",
    link: note.link || "/notifications",
    tag: note.id,
  };
}

/** Every (notification, subscription) pair for the same user that has not been delivered yet. */
export function pendingPairs(notes: PushNote[], subs: PushSub[], delivered: Delivery[]) {
  const done = new Set(delivered.map((d) => `${d.notification_id}:${d.subscription_id}`));
  const subsByUser = new Map<string, PushSub[]>();
  for (const sub of subs) {
    subsByUser.set(sub.user_id, [...(subsByUser.get(sub.user_id) ?? []), sub]);
  }
  const pairs: Array<{ note: PushNote; sub: PushSub }> = [];
  for (const note of notes) {
    for (const sub of subsByUser.get(note.user_id) ?? []) {
      if (!done.has(`${note.id}:${sub.id}`)) {
        pairs.push({ note, sub });
      }
    }
  }
  return pairs;
}

const GONE = new Set([404, 410]);

export async function runDispatch(deps: DispatchDeps, concurrency = 10): Promise<DispatchResult> {
  const notes = await deps.loadNotes();
  if (notes.length === 0) {
    return { notifications: 0, sent: 0, failed: 0, removed: 0 };
  }

  const userIds = Array.from(new Set(notes.map((n) => n.user_id)));
  const [subs, delivered] = await Promise.all([
    deps.loadSubscriptions(userIds),
    deps.loadDeliveries(notes.map((n) => n.id)),
  ]);
  const pairs = pendingPairs(notes, subs, delivered);

  const delivery: Delivery[] = [];
  const gone = new Set<string>();
  let failed = 0;

  for (let i = 0; i < pairs.length; i += concurrency) {
    await Promise.all(
      pairs.slice(i, i + concurrency).map(async ({ note, sub }) => {
        try {
          await deps.send(sub, buildPayload(note));
          delivery.push({ notification_id: note.id, subscription_id: sub.id });
        } catch (error) {
          const status = (error as { statusCode?: number } | null)?.statusCode;
          if (status !== undefined && GONE.has(status)) {
            gone.add(sub.id);
          } else {
            failed += 1;
          }
        }
      }),
    );
  }

  // Record what was sent first, so a failure removing dead subscriptions cannot cause a resend.
  if (delivery.length > 0) {
    await deps.recordDeliveries(delivery);
  }
  if (gone.size > 0) {
    await deps.removeSubscriptions(Array.from(gone));
  }

  return { notifications: notes.length, sent: delivery.length, failed, removed: gone.size };
}
