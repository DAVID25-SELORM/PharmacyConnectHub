import { describe, expect, it } from "vitest";
import {
  acceptedValue,
  nextWholesalerAction,
  returnTimeline,
  validateReturnSelection,
  type ReturnItem,
} from "./returns";

describe("returns helpers", () => {
  it("shows progress up to the current step and stops early for rejected returns", () => {
    expect(
      returnTimeline("inspected")
        .filter((step) => step.done)
        .map((step) => step.key),
    ).toEqual(["requested", "approved", "returned", "inspected"]);
    expect(returnTimeline("rejected").map((step) => step.key)).toEqual(["requested", "rejected"]);
  });

  it("offers each next action only to the roles allowed to take it", () => {
    const cashier = { canProcess: true, canManage: false };
    const manager = { canProcess: true, canManage: true };
    const assistant = { canProcess: false, canManage: false };
    expect(nextWholesalerAction("requested", cashier)).toBe("review");
    expect(nextWholesalerAction("approved", cashier)).toBe("receive");
    expect(nextWholesalerAction("returned", cashier)).toBeNull();
    expect(nextWholesalerAction("returned", manager)).toBe("inspect");
    expect(nextWholesalerAction("inspected", manager)).toBe("resolve");
    expect(nextWholesalerAction("requested", assistant)).toBeNull();
    expect(nextWholesalerAction("resolved", manager)).toBeNull();
  });

  it("values accepted units at the price paid", () => {
    const items = [
      { id: "a", unit_price_ghs: 10 },
      { id: "b", unit_price_ghs: 5.5 },
    ] as ReturnItem[];
    expect(acceptedValue(items, { a: 3, b: 2 })).toBe(41);
    expect(acceptedValue(items, {})).toBe(0);
  });

  it("validates a return selection", () => {
    expect(validateReturnSelection([{ quantity: 0, available: 5, name: "A" }])).toMatch(
      /at least one/,
    );
    expect(validateReturnSelection([{ quantity: 6, available: 5, name: "A" }])).toMatch(/Only 5/);
    expect(validateReturnSelection([{ quantity: 1.5, available: 5, name: "A" }])).toMatch(
      /whole number/,
    );
    expect(
      validateReturnSelection([
        { quantity: 2, available: 5, name: "A" },
        { quantity: 0, available: 0, name: "B" },
      ]),
    ).toBeNull();
  });
});
