import { describe, expect, it, vi } from "vitest";
import {
  buildPayload,
  pendingPairs,
  runDispatch,
  type Delivery,
  type DispatchDeps,
  type PushNote,
  type PushSub,
} from "../../supabase/functions/push-dispatch/dispatch";

const note = (id: string, user: string, extra: Partial<PushNote> = {}): PushNote => ({
  id,
  user_id: user,
  title: "Title " + id,
  body: "Body " + id,
  link: "/orders",
  ...extra,
});
const sub = (id: string, user: string): PushSub => ({
  id,
  user_id: user,
  endpoint: "https://push.example/" + id,
  p256dh: "p",
  auth: "a",
});

function deps(
  over: Partial<DispatchDeps> & { notes?: PushNote[]; subs?: PushSub[]; delivered?: Delivery[] },
) {
  const calls = { sent: [] as string[], recorded: [] as Delivery[], removed: [] as string[] };
  const d: DispatchDeps = {
    loadNotes: async () => over.notes ?? [],
    loadSubscriptions: async () => over.subs ?? [],
    loadDeliveries: async () => over.delivered ?? [],
    send: async (s, p) => {
      calls.sent.push(`${s.id}:${p.tag}`);
    },
    recordDeliveries: async (rows) => {
      calls.recorded.push(...rows);
    },
    removeSubscriptions: async (ids) => {
      calls.removed.push(...ids);
    },
    ...over,
  };
  return { d, calls };
}

describe("buildPayload", () => {
  it("falls back to defaults for missing text and tags with the notification id", () => {
    expect(buildPayload(note("n1", "u1", { title: null, body: null, link: null }))).toEqual({
      title: "DrugXOne",
      body: "You have a new notification.",
      link: "/notifications",
      tag: "n1",
    });
  });
});

describe("pendingPairs", () => {
  it("pairs each note with its own user's subscriptions and skips delivered ones", () => {
    const pairs = pendingPairs(
      [note("n1", "u1"), note("n2", "u2")],
      [sub("s1", "u1"), sub("s2", "u1"), sub("s3", "u2")],
      [{ notification_id: "n1", subscription_id: "s1" }],
    );
    expect(pairs.map((p) => `${p.note.id}:${p.sub.id}`)).toEqual(["n1:s2", "n2:s3"]);
  });

  it("never sends a note to another user's device", () => {
    expect(pendingPairs([note("n1", "u1")], [sub("s9", "u2")], [])).toEqual([]);
  });
});

describe("runDispatch", () => {
  it("does nothing and loads nothing else when there are no notifications", async () => {
    const loadSubscriptions = vi.fn(async () => []);
    const { d } = deps({ loadSubscriptions });
    expect(await runDispatch(d)).toEqual({ notifications: 0, sent: 0, failed: 0, removed: 0 });
    expect(loadSubscriptions).not.toHaveBeenCalled();
  });

  it("sends, records each delivery once and reports counts", async () => {
    const { d, calls } = deps({
      notes: [note("n1", "u1")],
      subs: [sub("s1", "u1"), sub("s2", "u1")],
    });
    const result = await runDispatch(d);
    expect(result).toEqual({ notifications: 1, sent: 2, failed: 0, removed: 0 });
    expect(calls.recorded).toHaveLength(2);
  });

  it("does not resend what was already delivered", async () => {
    const { d, calls } = deps({
      notes: [note("n1", "u1")],
      subs: [sub("s1", "u1")],
      delivered: [{ notification_id: "n1", subscription_id: "s1" }],
    });
    expect((await runDispatch(d)).sent).toBe(0);
    expect(calls.sent).toEqual([]);
    expect(calls.recorded).toEqual([]);
  });

  it("removes subscriptions the browser has dropped (404/410) and does not record them", async () => {
    const { d, calls } = deps({
      notes: [note("n1", "u1")],
      subs: [sub("dead", "u1"), sub("gone", "u1"), sub("ok", "u1")],
      send: async (s) => {
        if (s.id === "dead") throw Object.assign(new Error("gone"), { statusCode: 410 });
        if (s.id === "gone") throw Object.assign(new Error("missing"), { statusCode: 404 });
      },
    });
    const result = await runDispatch(d);
    expect(result).toEqual({ notifications: 1, sent: 1, failed: 0, removed: 2 });
    expect(calls.removed.sort()).toEqual(["dead", "gone"]);
    expect(calls.recorded).toEqual([{ notification_id: "n1", subscription_id: "ok" }]);
  });

  it("counts other failures but keeps them for the next run (not recorded, not removed)", async () => {
    const { d, calls } = deps({
      notes: [note("n1", "u1")],
      subs: [sub("s1", "u1")],
      send: async () => {
        throw Object.assign(new Error("push service down"), { statusCode: 503 });
      },
    });
    expect(await runDispatch(d)).toEqual({ notifications: 1, sent: 0, failed: 1, removed: 0 });
    expect(calls.recorded).toEqual([]);
    expect(calls.removed).toEqual([]);
  });

  it("sends in batches of the given concurrency", async () => {
    let active = 0;
    let peak = 0;
    const { d } = deps({
      notes: [note("n1", "u1")],
      subs: Array.from({ length: 7 }, (_, i) => sub("s" + i, "u1")),
      send: async () => {
        active += 1;
        peak = Math.max(peak, active);
        await new Promise((r) => setTimeout(r, 5));
        active -= 1;
      },
    });
    expect((await runDispatch(d, 3)).sent).toBe(7);
    expect(peak).toBeLessThanOrEqual(3);
  });
});
