import { describe, expect, it } from "vitest";
import { groupOf, safeInternalLink, timeAgoShort, typesForGroup } from "./notifications";

describe("notification helpers", () => {
  it("groups every notification type the database can create", () => {
    const types = [
      "new_order",
      "order_status",
      "payment_update",
      "return_requested",
      "return_update",
      "delivery_update",
      "low_stock",
      "expiry_alert",
      "business_approved",
      "business_rejected",
      "verification_pending",
    ];
    expect(types.map(groupOf).every(Boolean)).toBe(true);
    expect(groupOf("something_new")).toBeNull();
    expect(typesForGroup("returns")).toEqual(["return_requested", "return_update"]);
    expect(typesForGroup("unread")).toBeNull();
  });

  it("only follows same-site links", () => {
    expect(safeInternalLink("/pharmacy?tab=returns")).toBe("/pharmacy?tab=returns");
    expect(safeInternalLink("https://evil.example")).toBeNull();
    expect(safeInternalLink("//evil.example")).toBeNull();
    expect(safeInternalLink("/\\evil.example")).toBeNull();
    expect(safeInternalLink("javascript:alert(1)")).toBeNull();
    expect(safeInternalLink(null)).toBeNull();
  });

  it("describes age in short form", () => {
    const now = new Date("2026-09-26T12:00:00Z").getTime();
    expect(timeAgoShort("2026-09-26T11:59:40Z", now)).toBe("just now");
    expect(timeAgoShort("2026-09-26T11:30:00Z", now)).toBe("30m ago");
    expect(timeAgoShort("2026-09-26T09:00:00Z", now)).toBe("3h ago");
    expect(timeAgoShort("2026-09-23T12:00:00Z", now)).toBe("3d ago");
  });
});
