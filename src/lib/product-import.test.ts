import { describe, expect, it } from "vitest";
import { parsePharmacyInventoryImportText, parseProductImportText } from "./product-import";

describe("safe inventory import parsing", () => {
  it("rejects extra cells rather than shifting inventory columns", () => {
    expect(() => parseProductImportText("name,price_ghs,stock\nDrug A,10,1,000")).toThrow(
      /more columns/,
    );
  });
  it("rejects duplicate quantity headers including aliases", () => {
    expect(() => parseProductImportText("name,price_ghs,stock,quantity\nDrug A,10,1,2")).toThrow(
      /Duplicate/,
    );
  });
  it("rejects unterminated quotes", () => {
    expect(() => parseProductImportText('name,price_ghs,stock\n"Drug A,10,2')).toThrow(/Unclosed/);
  });
  it("does not shift tab-separated fields when the product name is blank", () => {
    expect(parseProductImportText("name\tprice_ghs\tstock\n\t10\t2").invalidRows).toEqual([2]);
  });
  it("distinguishes blank stock from explicit zero", () => {
    const result = parseProductImportText("name,price_ghs,stock\nDrug A,10,\nDrug B,12,0");
    expect(result.products.map((row) => row.stock)).toEqual([null, 0]);
    expect(result.products.map((row) => row.source_row)).toEqual([2, 3]);
  });
  it("preserves omitted stock as null", () => {
    expect(parseProductImportText("name,price_ghs\nDrug A,10").products[0].stock).toBeNull();
  });
  it.each(["-1", "1.5", "unknown", "12 packs", "2147483648"])(
    "rejects unsafe stock %s",
    (stock) => {
      expect(
        parseProductImportText(`name,price_ghs,stock\nDrug A,10,${stock}`).invalidRows,
      ).toEqual([2]);
    },
  );
  it.each(["free", "-10", "0", "12oops", "100000000"])("rejects invalid prices %s", (price) => {
    expect(parseProductImportText(`name,price_ghs,stock\nDrug A,${price},10`).invalidRows).toEqual([
      2,
    ]);
  });
  it("reads quoted formatted prices and preserves duplicate rows for server validation", () => {
    const result = parseProductImportText(
      'name,price_ghs,stock\nDrug A,"GHS 1,200.50",10\nDrug A,20,15',
    );
    expect(result.products).toHaveLength(2);
    expect(result.products[0].price_ghs).toBe(1200.5);
  });
});

describe("pharmacy inventory import parsing", () => {
  it("accepts a row with no cost column at all, unlike the wholesaler parser", () => {
    const result = parsePharmacyInventoryImportText("name,stock\nParacetamol 500mg,25");
    expect(result.invalidRows).toEqual([]);
    expect(result.items).toHaveLength(1);
    expect(result.items[0]).toMatchObject({ name: "Paracetamol 500mg", stock: 25, unitCostGhs: null });
  });
  it("maps reorder level aliases", () => {
    const result = parsePharmacyInventoryImportText(
      "name,stock,reorder level\nParacetamol 500mg,25,10",
    );
    expect(result.items[0].reorderLevel).toBe(10);
  });
  it("maps cost aliases", () => {
    const result = parsePharmacyInventoryImportText("name,unit cost\nParacetamol 500mg,4.50");
    expect(result.items[0].unitCostGhs).toBe(4.5);
  });
  it("preserves omitted stock as null (leave unchanged), distinct from explicit zero", () => {
    const result = parsePharmacyInventoryImportText("name,stock\nDrug A,\nDrug B,0");
    expect(result.items.map((row) => row.stock)).toEqual([null, 0]);
  });
  it("rejects a blank name", () => {
    expect(parsePharmacyInventoryImportText("name,stock\n,10").invalidRows).toEqual([2]);
  });
  it("rejects an unsafe stock value", () => {
    expect(parsePharmacyInventoryImportText("name,stock\nDrug A,-5").invalidRows).toEqual([2]);
  });
  it("rejects a negative cost", () => {
    expect(parsePharmacyInventoryImportText("name,unit cost\nDrug A,-5").invalidRows).toEqual([2]);
  });
});

describe("pharmacy inventory import: item type and new fields", () => {
  it("leaves itemType null when the column is absent (the RPC defaults to medicine)", () => {
    const result = parsePharmacyInventoryImportText("name,stock\nParacetamol 500mg,25");
    expect(result.items[0].itemType).toBeNull();
  });
  it("normalizes known item type spellings and casing", () => {
    const result = parsePharmacyInventoryImportText(
      "name,item type\nA,Medicine\nB,Medical Consumable\nC,medical_equipment\nD,non-medical item",
    );
    expect(result.items.map((row) => row.itemType)).toEqual([
      "medicine",
      "medical_consumable",
      "medical_equipment",
      "non_medical",
    ]);
  });
  it("rejects a row with an unrecognized item type", () => {
    expect(parsePharmacyInventoryImportText("name,item type\nDrug A,surgical_tape").invalidRows).toEqual([2]);
  });
  it("rejects an expiry date that isn't YYYY-MM-DD", () => {
    expect(parsePharmacyInventoryImportText("name,expiry\nDrug A,30/06/2027").invalidRows).toEqual([2]);
  });
  it("accepts a well-formed expiry date", () => {
    const result = parsePharmacyInventoryImportText("name,expiry\nDrug A,2027-06-30");
    expect(result.invalidRows).toEqual([]);
    expect(result.items[0].expiryDate).toBe("2027-06-30");
  });
  it("rejects a negative or out-of-range selling price", () => {
    expect(parsePharmacyInventoryImportText("name,selling price\nDrug A,-5").invalidRows).toEqual([2]);
  });
  it("maps the new equipment and consumable field aliases", () => {
    const result = parsePharmacyInventoryImportText(
      "name,item type,model,serial number,warranty,barcode,unit\nBP Monitor,Medical Equipment,HEM-7120,SN-1,2 years,,",
    );
    expect(result.items[0]).toMatchObject({
      itemType: "medical_equipment",
      model: "HEM-7120",
      serialNumber: "SN-1",
      warrantyInfo: "2 years",
    });
  });
});
