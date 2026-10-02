import { describe, expect, it } from "vitest";
import {
  ITEM_TYPE_FIELDS,
  ITEM_TYPE_OPTIONS,
  isLowStock,
  validateInventoryItemDraft,
  validateStockAdjustment,
} from "./pharmacy-inventory";

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
  it("rejects a negative selling price", () => {
    expect(
      validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "", unitCostGhs: "", sellingPriceGhs: "-1" }).error,
    ).toBeTruthy();
  });
  it("accepts a zero-or-more selling price, and tolerates it being omitted", () => {
    expect(
      validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "", unitCostGhs: "", sellingPriceGhs: "6.50" }).error,
    ).toBeNull();
    expect(validateInventoryItemDraft({ name: "Paracetamol", reorderLevel: "", unitCostGhs: "" }).error).toBeNull();
  });
});

describe("ITEM_TYPE_FIELDS", () => {
  it("has an entry for every option in ITEM_TYPE_OPTIONS", () => {
    for (const opt of ITEM_TYPE_OPTIONS) {
      expect(ITEM_TYPE_FIELDS[opt.value]).toBeDefined();
    }
  });
  it("only shows dosage-form and generic/strength fields for medicine", () => {
    expect(ITEM_TYPE_FIELDS.medicine.form).toBe(true);
    expect(ITEM_TYPE_FIELDS.medicine.genericName).toBe(true);
    expect(ITEM_TYPE_FIELDS.medical_consumable.form).toBe(false);
    expect(ITEM_TYPE_FIELDS.medical_equipment.genericName).toBe(false);
    expect(ITEM_TYPE_FIELDS.non_medical.genericName).toBe(false);
  });
  it("only shows model/serial/warranty for equipment", () => {
    expect(ITEM_TYPE_FIELDS.medical_equipment.model).toBe(true);
    expect(ITEM_TYPE_FIELDS.medical_equipment.serialNumber).toBe(true);
    expect(ITEM_TYPE_FIELDS.medical_equipment.warranty).toBe(true);
    for (const type of ["medicine", "medical_consumable", "non_medical"] as const) {
      expect(ITEM_TYPE_FIELDS[type].model).toBe(false);
      expect(ITEM_TYPE_FIELDS[type].serialNumber).toBe(false);
      expect(ITEM_TYPE_FIELDS[type].warranty).toBe(false);
    }
  });
  it("only shows batch/expiry for medicine and consumables, never equipment or non-medical", () => {
    expect(ITEM_TYPE_FIELDS.medicine.batch).toBe(true);
    expect(ITEM_TYPE_FIELDS.medical_consumable.expiry).toBe(true);
    expect(ITEM_TYPE_FIELDS.medical_equipment.batch).toBe(false);
    expect(ITEM_TYPE_FIELDS.non_medical.expiry).toBe(false);
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
