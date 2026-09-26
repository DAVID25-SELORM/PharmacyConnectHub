import { describe, expect, it } from "vitest";
import {
  canRecordDispatch,
  canRecordProof,
  hasDispatchDetails,
  hasProof,
  toDateTimeLocal,
} from "./delivery";

describe("delivery helpers", () => {
  it("allows dispatch details until delivery and proof once dispatched", () => {
    expect(
      ["pending", "accepted", "packed", "dispatched", "delivered", "cancelled"].map(
        canRecordDispatch,
      ),
    ).toEqual([false, true, true, true, false, false]);
    expect(
      ["pending", "accepted", "packed", "dispatched", "delivered", "cancelled"].map(canRecordProof),
    ).toEqual([false, false, false, true, true, false]);
  });

  it("detects what has been recorded", () => {
    expect(hasDispatchDetails({})).toBe(false);
    expect(hasDispatchDetails({ driver_phone: "0245550202" })).toBe(true);
    expect(hasProof({ received_by_name: "John" })).toBe(false);
    expect(hasProof({ received_by_name: "John", received_at: "2026-09-26T10:00:00Z" })).toBe(true);
  });

  it("formats datetime-local values and tolerates bad input", () => {
    expect(toDateTimeLocal(null)).toBe("");
    expect(toDateTimeLocal("not a date")).toBe("");
    expect(toDateTimeLocal("2026-09-26T10:30:00Z")).toMatch(/^2026-09-2[5-7]T\d\d:\d\d$/);
  });
});
