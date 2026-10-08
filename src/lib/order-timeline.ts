// The order activity timeline (order_timeline RPC): one chronological list per order combining its placement, every
// status change and every recorded event. These helpers only group and word what the database returns.

export type TimelineSide = "wholesaler" | "pharmacy" | "system";

export type TimelineEntry = {
  at: string;
  source: "order" | "status" | "event";
  event_type: string;
  actor_side: TimelineSide;
  actor_label: string | null;
  summary: string;
  details: Record<string, unknown>;
};

export const SIDE_LABELS: Record<TimelineSide, string> = {
  wholesaler: "Wholesaler",
  pharmacy: "Pharmacy",
  system: "System",
};

/** "Alpha Wholesale · Wholesaler", "afin@x.test · Wholesaler", or just "System". */
export function actorText(entry: Pick<TimelineEntry, "actor_side" | "actor_label">): string {
  const side = SIDE_LABELS[entry.actor_side] ?? "System";
  if (entry.actor_side === "system" && (!entry.actor_label || entry.actor_label === "System"))
    return "System";
  return entry.actor_label ? `${entry.actor_label} · ${side}` : side;
}

/** Local calendar day of a timestamp, as yyyy-mm-dd. */
export function localDay(iso: string): string {
  const date = new Date(iso);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

export type TimelineDay = { day: string; entries: TimelineEntry[] };

/** Entries grouped by local day, oldest day first, each day's entries in the order they arrived. */
export function groupTimelineByDay(entries: TimelineEntry[]): TimelineDay[] {
  const days: TimelineDay[] = [];
  for (const entry of entries) {
    const day = localDay(entry.at);
    const last = days[days.length - 1];
    if (last && last.day === day) last.entries.push(entry);
    else days.push({ day, entries: [entry] });
  }
  return days;
}

/** A short key the screen maps to an icon; unknown event types fall back to "event". */
export function entryKind(entry: Pick<TimelineEntry, "source" | "event_type">): string {
  if (entry.source === "order") return "placed";
  if (entry.source === "status") return "status";
  return "event";
}
