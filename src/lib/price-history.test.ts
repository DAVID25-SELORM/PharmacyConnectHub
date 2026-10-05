import { describe, expect, it } from "vitest";
import {
  EMPTY_PRICE_HISTORY_FILTERS,
  describeChange,
  priceHistoryArgs,
  priceHistoryDetailArgs,
  priceHistoryExport,
  productDescriptor,
  type PriceHistoryRow,
} from "./price-history";

const range = { p_range: "30d", p_from: null, p_to: null };

const row: PriceHistoryRow = {
  sample_product_id: "p1",
  product_name: "Amoxicillin 500mg",
  brand: "Generic",
  form: "CAPSULE",
  pack_size: " 100S",
  purchases: "3",
  units: "40",
  spend_ghs: "4420.00",
  avg_paid_ghs: "110.50",
  min_paid_ghs: "90.00",
  max_paid_ghs: "121.00",
  suppliers: "2",
  latest_paid_ghs: "121.00",
  latest_at: "2026-10-03T09:30:00Z",
  latest_supplier_id: "w1",
  latest_supplier_name: "Alpha Wholesale",
  previous_paid_ghs: "110.00",
  change_pct: "10.0",
  cheaper_paid_ghs: "90.00",
  cheaper_supplier_name: "Other Wholesale",
  total_count: 1,
};

describe("price history requests", () => {
  it("sends blank filters as null and asks for one bounded page", () => {
    expect(priceHistoryArgs("b1", range, EMPTY_PRICE_HISTORY_FILTERS)).toEqual({
      p_business_id: "b1",
      p_range: "30d",
      p_from: null,
      p_to: null,
      p_wholesaler_id: null,
      p_purchase_category: null,
      p_search: null,
      p_limit: 200,
      p_offset: 0,
    });
  });

  it("passes the supplier, category and search through, trimmed", () => {
    expect(
      priceHistoryArgs("b1", range, { supplierId: "w1", category: "nhis", search: "  amox " }),
    ).toMatchObject({ p_wholesaler_id: "w1", p_purchase_category: "nhis", p_search: "amox" });
  });

  it("builds the detail request for one product with the same range and filters", () => {
    expect(
      priceHistoryDetailArgs("b1", "p1", range, {
        supplierId: "",
        category: "cash_private",
        search: "x",
      }),
    ).toEqual({
      p_business_id: "b1",
      p_product_id: "p1",
      p_range: "30d",
      p_from: null,
      p_to: null,
      p_wholesaler_id: null,
      p_purchase_category: "cash_private",
      p_limit: 200,
    });
  });
});

describe("describing a price change in words", () => {
  it("says up, down, no change, or nothing", () => {
    expect(describeChange("10.0")).toEqual({ direction: "up", label: "Up 10.0%" });
    expect(describeChange(-4.54)).toEqual({ direction: "down", label: "Down 4.5%" });
    expect(describeChange(0)).toEqual({ direction: "same", label: "No change" });
    expect(describeChange(null)).toEqual({ direction: "none", label: "—" });
    expect(describeChange(undefined)).toEqual({ direction: "none", label: "—" });
    expect(describeChange("abc")).toEqual({ direction: "none", label: "—" });
  });
});

describe("product descriptor", () => {
  it("joins what is known and trims stray spaces", () => {
    expect(productDescriptor(row)).toBe("Generic · CAPSULE · 100S");
    expect(productDescriptor({ brand: null, form: "  ", pack_size: "10s" })).toBe("10s");
    expect(productDescriptor({ brand: null, form: null, pack_size: null })).toBe("");
  });
});

describe("price history export", () => {
  it("keeps numbers as numbers and leaves unknowns blank", () => {
    const sheet = priceHistoryExport([
      row,
      {
        ...row,
        product_name: "Bandage",
        previous_paid_ghs: null,
        change_pct: null,
        cheaper_paid_ghs: null,
        cheaper_supplier_name: null,
        brand: null,
      },
    ]);
    expect(sheet.filenamePrefix).toBe("pharmacy-price-history");
    expect(sheet.rows[0]).toEqual([
      "Amoxicillin 500mg",
      "Generic",
      "CAPSULE",
      "100S",
      3,
      40,
      4420,
      110.5,
      90,
      121,
      2,
      121,
      "2026-10-03",
      "Alpha Wholesale",
      110,
      10,
      90,
      "Other Wholesale",
    ]);
    expect(sheet.rows[1].slice(14)).toEqual(["", "", "", ""]);
    for (const line of sheet.rows) expect(line).toHaveLength(sheet.headers.length);
  });
});
