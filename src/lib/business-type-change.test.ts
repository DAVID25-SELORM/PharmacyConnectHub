import { describe, expect, it } from "vitest";
import {
  OTHER_REASON,
  TYPE_CHANGE_REASONS,
  businessTypeLabel,
  describeBlockers,
  otherBusinessType,
  resolveTypeChangeReason,
} from "@/lib/business-type-change";

describe("resolveTypeChangeReason", () => {
  it("uses the label of a preset reason and ignores stray text", () => {
    expect(resolveTypeChangeReason("wrong_type", "ignored")).toBe("Signed up as the wrong type");
  });

  it("needs written text when Other is chosen", () => {
    expect(resolveTypeChangeReason(OTHER_REASON, "   ")).toBeNull();
    expect(resolveTypeChangeReason(OTHER_REASON, "  Duplicate registration ")).toBe(
      "Duplicate registration",
    );
  });

  it("returns null for an unknown choice and keeps Other last in the list", () => {
    expect(resolveTypeChangeReason("nonsense", "")).toBeNull();
    expect(TYPE_CHANGE_REASONS[TYPE_CHANGE_REASONS.length - 1].value).toBe(OTHER_REASON);
  });
});

describe("business type change helpers", () => {
  it("offers the opposite type", () => {
    expect(otherBusinessType("pharmacy")).toBe("wholesaler");
    expect(otherBusinessType("wholesaler")).toBe("pharmacy");
  });

  it("labels types for people", () => {
    expect(businessTypeLabel("pharmacy")).toBe("Pharmacy");
    expect(businessTypeLabel("wholesaler")).toBe("Wholesaler");
  });

  it("groups blockers by table, sums counts and flags capped counts", () => {
    expect(
      describeBlockers([
        { source_table: "orders", source_column: "pharmacy_id", row_count: 4 },
        { source_table: "orders", source_column: "wholesaler_id", row_count: 2 },
        { source_table: "pharmacy_saved_carts", source_column: "pharmacy_id", row_count: 1000 },
      ]),
    ).toEqual([
      { label: "orders", count: 6, capped: false },
      { label: "pharmacy saved carts", count: 1000, capped: true },
    ]);
  });

  it("returns nothing when the business is empty", () => {
    expect(describeBlockers([])).toEqual([]);
  });
});
