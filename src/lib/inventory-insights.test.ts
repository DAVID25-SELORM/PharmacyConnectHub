import { describe, expect, it } from "vitest";
import { daysRemainingLabel } from "./inventory-insights";

describe("daysRemainingLabel", () => {
  it("handles empty stock, no sales, long cover and normal values", () => {
    expect(daysRemainingLabel({ current_stock: 0, days_remaining: null })).toBe("0 days");
    expect(daysRemainingLabel({ current_stock: 5, days_remaining: null })).toBe("No recent sales");
    expect(daysRemainingLabel({ current_stock: 5000, days_remaining: 5000 })).toBe("Over a year");
    expect(daysRemainingLabel({ current_stock: 10, days_remaining: 4.5 })).toBe("4.5 days");
    expect(daysRemainingLabel({ current_stock: 50, days_remaining: 42 })).toBe("42 days");
  });
});
