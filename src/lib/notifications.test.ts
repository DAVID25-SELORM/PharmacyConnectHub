import { describe, expect, it } from "vitest";
import {
  groupOf,
  linkedOrderId,
  notificationLink,
  safeInternalLink,
  timeAgoShort,
  typesForGroup,
} from "./notifications";

describe("notification helpers", () => {
  it("groups every notification type the database can create", () => {
    const types = [
      "new_order",
      "order_status",
      "order_amendment",
      "payment_update",
      "credit_reminder",
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

  it("a notification about an order opens that order", () => {
    const id = "0a1b2c3d-1111-4222-8333-444455556666";
    expect(notificationLink({ link: "/pharmacy?tab=orders", metadata: { order_id: id } })).toBe(
      `/pharmacy?tab=orders&order=${id}`,
    );
    expect(notificationLink({ link: "/wholesaler?tab=orders", metadata: { order_id: id } })).toBe(
      `/wholesaler?tab=orders&order=${id}`,
    );
  });

  it("leaves other links alone: no order, a bad id, another page, an unsafe link", () => {
    const id = "0a1b2c3d-1111-4222-8333-444455556666";
    expect(notificationLink({ link: "/pharmacy?tab=orders", metadata: null })).toBe(
      "/pharmacy?tab=orders",
    );
    expect(notificationLink({ link: "/pharmacy?tab=orders", metadata: { order_id: "x" } })).toBe(
      "/pharmacy?tab=orders",
    );
    expect(notificationLink({ link: "/accounting", metadata: { order_id: id } })).toBe(
      "/accounting",
    );
    expect(
      notificationLink({ link: "https://evil.example", metadata: { order_id: id } }),
    ).toBeNull();
    expect(notificationLink({ link: null, metadata: { order_id: id } })).toBeNull();
  });

  it("reads the order a page was asked to open, only when it is a real id", () => {
    const id = "0a1b2c3d-1111-4222-8333-444455556666";
    expect(linkedOrderId(`?tab=orders&order=${id}`)).toBe(id);
    expect(linkedOrderId("?tab=orders&order=not-an-id")).toBeNull();
    expect(linkedOrderId("?tab=orders")).toBeNull();
    expect(linkedOrderId("")).toBeNull();
  });
});
