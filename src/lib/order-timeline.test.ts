import { describe, expect, it } from "vitest";
import {
  actorText,
  entryKind,
  groupTimelineByDay,
  localDay,
  type TimelineEntry,
} from "./order-timeline";

const entry = (overrides: Partial<TimelineEntry>): TimelineEntry => ({
  at: "2026-10-08T09:00:00",
  source: "event",
  event_type: "note_added",
  actor_side: "wholesaler",
  actor_label: "Alpha Wholesale",
  summary: "Something happened",
  details: {},
  ...overrides,
});

describe("actorText", () => {
  it("names who did it and on which side", () => {
    expect(actorText({ actor_side: "wholesaler", actor_label: "Alpha Wholesale" })).toBe(
      "Alpha Wholesale · Wholesaler",
    );
    expect(actorText({ actor_side: "pharmacy", actor_label: "po@x.test" })).toBe(
      "po@x.test · Pharmacy",
    );
  });

  it("says just the side when there is no name, and just System for the system", () => {
    expect(actorText({ actor_side: "pharmacy", actor_label: null })).toBe("Pharmacy");
    expect(actorText({ actor_side: "system", actor_label: "System" })).toBe("System");
    expect(actorText({ actor_side: "system", actor_label: null })).toBe("System");
  });
});

describe("grouping by day", () => {
  it("groups consecutive entries of the same local day and keeps their order", () => {
    const days = groupTimelineByDay([
      entry({ at: "2026-10-07T23:59:00", summary: "a" }),
      entry({ at: "2026-10-08T00:01:00", summary: "b" }),
      entry({ at: "2026-10-08T15:30:00", summary: "c" }),
    ]);
    expect(days.map((day) => day.day)).toEqual(["2026-10-07", "2026-10-08"]);
    expect(days[1].entries.map((item) => item.summary)).toEqual(["b", "c"]);
  });

  it("is empty for no entries", () => {
    expect(groupTimelineByDay([])).toEqual([]);
  });

  it("formats a local day with zero padding", () => {
    expect(localDay("2026-03-05T10:00:00")).toBe("2026-03-05");
  });
});

describe("entry kind", () => {
  it("separates placement, status changes and recorded events", () => {
    expect(entryKind({ source: "order", event_type: "placed" })).toBe("placed");
    expect(entryKind({ source: "status", event_type: "status_changed" })).toBe("status");
    expect(entryKind({ source: "event", event_type: "anything" })).toBe("event");
  });
});
