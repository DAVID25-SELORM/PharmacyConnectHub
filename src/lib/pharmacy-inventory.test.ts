import { describe, expect, it } from "vitest";
import { isLowStock, validateInventoryItemDraft, validateStockAdjustment } from "./pharmacy-inventory";

describe("validateStockAdjustment", () => {
  it("accepts a positive quantity for receive", () => {
    expect(validateStockAdjustment({ quantity: "10", kind: "receive" })).toEqual({ error: null, delta: 10 });
  });
  it("accepts a positive 'units to remove' for write_off and negates it", () => {
    expect(validateStockAdjustment({ quantity: "10", kind: "write_off" })).toEqual({ error: null, delta: -10 });
  });
  it("rejects a negative quantity for write_off (the field is a positive magnitude)", () => {
    expect(validateStockAdjustment({ quantity: "-10", kind: "write_off" }).error).toMatch(/positive/);
  });
  it("rejects a negative quantity for receive", () => {
    expect(validateStockAdjustment({ quantity: "-10", kind: "receive" }).error).toMatch(/positive/);
  });
  it("accepts a signed value for adjust (positive to add, negative to subtract)", () => {
    expect(validateStockAdjustment({ quantity: "-5", kind: "adjust" })).toEqual({ error: null, delta: -5 });
    expect(validateStockAdjustment({ quantity: "5", kind: "adjust" })).toEqual({ error: null, delta: 5 });
  });
  it("rejects zero", () => {
    expect(validateStockAdjustment({ quantity: "0", kind: "adjust" }).error).toBeTruthy();
  });
  it("rejects a non-integer", () => {
    expect(validateStockAdjustment({ quantity: "2.5", kind: "adjust" }).error).toBeTruthy();
  });
});

describe("validateInventoryItemDraft", () => {
  it("requires a name", () => {
    expect(validateInventoryItemDraft({ name: "  ", reorderLevel: "", unitCostGhs: "" }).error).toBeTruthy();
  });
  it("accepts a minimal valid draft", () => {
    expect(validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "", unitCostGhs: "" }).error).toBeNull();
  });
  it("rejects a negative starting stock", () => {
    expect(validateInventoryItemDraft({ name: "Paracetamol", stock: "-1", reorderLevel: "", unitCostGhs: "" }).error).toBeTruthy();
  });
  it("rejects a negative reorder level", () => {
    expect(validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "-1", unitCostGhs: "" }).error).toBeTruthy();
  });
  it("rejects a negative unit cost", () => {
    expect(validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "", unitCostGhs: "-1" }).error).toBeTruthy();
  });
});

describe("isLowStock", () => {
  it("is false when there is no reorder level set", () => {
    expect(isLowStock({ stock: 0, reorder_level: null })).toBe(false);
  });
  it("is true when stock is at or below the reorder level", () => {
    expect(isLowStock({ stock: 5, reorder_level: 5 })).toBe(true);
    expect(isLowStock({ stock: 4, reorder_level: 5 })).toBe(true);
  });
  it("is false when stock is above the reorder level", () => {
    expect(isLowStock({ stock: 6, reorder_level: 5 })).toBe(false);
  });
});
