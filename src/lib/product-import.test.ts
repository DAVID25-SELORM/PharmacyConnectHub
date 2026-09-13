import { describe, expect, it } from "vitest";
import { parseProductImportText } from "./product-import";

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
