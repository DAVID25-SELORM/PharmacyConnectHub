import { describe, expect, it } from "vitest";
import {
  hasOrderDetails,
  LatestOrderRequest,
  mergeOrderSummary,
  orderDateRange,
} from "./order-history";

describe("order history integrity", () => {
  it("retains full document details after an order is filtered out and back", () => {
    const detail = {
      id: "a",
      order_items: [{ product_name: "A", quantity: 2 }],
      wholesaler: { name: "Supplier", city: "Accra" },
      accepted_at: "2026-10-01",
      pharmacy: { id: "p" },
    };
    const cache = new Map([["a", detail]]);
    const restored = mergeOrderSummary(
      { id: "a", item_count: 1, wholesaler_name: "Supplier", total_ghs: 10 },
      cache.get("a"),
    );
    expect(restored.order_items).toEqual(detail.order_items);
    expect(restored.wholesaler).toEqual(detail.wholesaler);
    expect(restored.accepted_at).toBe(detail.accepted_at);
    expect(hasOrderDetails(restored)).toBe(true);
  });
  it("does not permit documents from summaries or mismatched detail counts", () => {
    expect(hasOrderDetails(mergeOrderSummary({ item_count: 2 }))).toBe(false);
    expect(hasOrderDetails(mergeOrderSummary({ item_count: 2 }, { order_items: [{}] }))).toBe(
      false,
    );
    expect(hasOrderDetails({ detailLoaded: true, order_items: [] })).toBe(false);
  });
  it("rejects superseded requests including a switch away and back", () => {
    const requests = new LatestOrderRequest();
    const a = requests.start();
    const b = requests.start();
    expect(requests.current(a)).toBe(false);
    expect(requests.current(b)).toBe(true);
    requests.invalidate();
    expect(requests.current(b)).toBe(false);
  });
  it("uses exclusive Ghana day bounds and validates dates", () => {
    expect(orderDateRange("2026-10-11", "2026-10-11")).toEqual({
      from: "2026-10-11T00:00:00.000Z",
      to: "2026-10-12T00:00:00.000Z",
    });
    expect(orderDateRange("2026-10-12", "2026-10-11").error).toMatch(/Start date/);
    expect(orderDateRange("2026-02-30", "2026-03-01").error).toMatch(/valid/);
    expect(orderDateRange("", "2026-03-01").error).toMatch(/both/);
  });
});
