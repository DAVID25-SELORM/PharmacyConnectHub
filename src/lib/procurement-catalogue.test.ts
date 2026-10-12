import { describe, it, expect } from "vitest";
import {
  catalogueLine,
  emptyMedicine,
  importProcurementRows,
  lineMinor,
} from "./procurement-catalogue";
import { supplyDraft, validateSupplyDraft } from "./external-supply-orders";
describe("procurement catalogue and imports", () => {
  it("snapshots a selected identity without sharing its mutable data", () => {
    const data = {
      ...emptyMedicine(),
      name: "Paracetamol",
      strength: "500 mg",
      dosage_form: "tablet",
      pack_size: "100",
    };
    const line = catalogueLine({ id: "a", source: "business", data, version: 1, archived: false });
    expect(line.name).toBe("Paracetamol / 500 mg / tablet / 100");
    expect(line.catalogue_source).toBe("business");
    expect(line.unit_price).toBeNull();
  });
  it("saves incomplete drafts but requires completeness before issue", () => {
    expect(validateSupplyDraft({ ...supplyDraft(), lines: [] })).toBeNull();
    expect(validateSupplyDraft({ ...supplyDraft(), lines: [] }, true)).toBeTruthy();
  });
  it("validates import units, quantities, prices and duplicates", () => {
    const rows = importProcurementRows([
      ["Medicine name", "Quantity", "Unit", "Unit price"],
      ["A", 2, "bottles", "0.10"],
      ["A", 2, "packs", 1],
      ["B", 0, "packs", 1],
      ["C", 1, "unknown", 1],
      ["D", 1, "packs", "1.001"],
    ]);
    expect(rows[0].issue).toBe("");
    expect(lineMinor(rows[0].line)).toBe(20);
    expect(rows.slice(1).every((r) => !!r.issue)).toBe(true);
  });
  it("does not turn missing prices into accepted prices", () => {
    expect(
      importProcurementRows([
        ["Medicine name", "Quantity"],
        ["A", 2],
      ])[0].line.unit_price,
    ).toBeNull();
  });
  it("bounds imports", () => {
    expect(() =>
      importProcurementRows([["name", "quantity"], ...Array.from({ length: 201 }, () => ["A", 1])]),
    ).toThrow("200");
  });
});
