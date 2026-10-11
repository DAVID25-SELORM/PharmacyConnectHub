import { describe, it, expect, vi } from "vitest";
vi.mock("@/integrations/supabase/client", () => ({ supabase: {} }));
import {
  remainingRequirement,
  compareVersions,
  type Requirement,
  type Allocation,
  type AwardGroup,
  type QuoteVersion,
} from "./enterprise-rfq";
describe("RFQ allocation presentation", () => {
  it("counts provisional and confirmed quantities, releasing declined awards", () => {
    const item = { id: "item", quantity: 100, cancelled_quantity: 10 } as Requirement;
    const groups = [
      { id: "pending", status: "pending" },
      { id: "failed", status: "conversion_failed" },
      { id: "confirmed", status: "confirmed" },
      { id: "declined", status: "declined" },
    ] as AwardGroup[];
    const allocations = groups.map((g, i) => ({
      group_id: g.id,
      rfq_item_id: "item",
      requested_quantity: [20, 10, 30, 40][i],
    })) as Allocation[];
    expect(remainingRequirement(item, allocations, groups)).toBe(30);
  });
  it("compares landed totals including delivery, without mutating versions", () => {
    const versions = [
      {
        id: "a",
        snapshot: {
          quote: { total_ghs: 100, delivery_charge_ghs: 50, lead_time_days: 1 },
          items: [],
        },
      },
      {
        id: "b",
        snapshot: {
          quote: { total_ghs: 120, delivery_charge_ghs: 0, lead_time_days: 3 },
          items: [],
        },
      },
    ] as unknown as QuoteVersion[];
    expect(compareVersions(versions, "cost").map((v) => v.id)).toEqual(["b", "a"]);
    expect(compareVersions(versions, "delivery").map((v) => v.id)).toEqual(["a", "b"]);
    expect(versions[0].id).toBe("a");
  });
  it("counts offered quantities using explicit requested-unit conversions", () => {
    const versions = [
      {
        id: "a",
        snapshot: { quote: {}, items: [{ quantity: 2, requested_units_per_offered_unit: 10 }] },
      },
      {
        id: "b",
        snapshot: { quote: {}, items: [{ quantity: 15, requested_units_per_offered_unit: 1 }] },
      },
    ] as unknown as QuoteVersion[];
    expect(compareVersions(versions, "quantity")[0].id).toBe("a");
  });
});
