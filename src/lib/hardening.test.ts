// Phase 7 hardening: edge cases across the import, export, RFQ, audit and dashboard helpers.
import { describe, expect, it } from "vitest";
import { auditCategory, auditCategoryLabel } from "./audit-centre";
import { inventoryItemsToPdfSheet, type PharmacyInventoryItem } from "./pharmacy-inventory";
import { isRealCalendarDate, parsePharmacyInventoryImportText } from "./product-import";
import { formatReportDate, formatReportDateTime, rowsToCsv } from "./reports";
import { roundMoney } from "./rfq";

describe("isRealCalendarDate", () => {
  it("accepts real dates including a leap day", () => {
    expect(isRealCalendarDate("2027-06-30")).toBe(true);
    expect(isRealCalendarDate("2028-02-29")).toBe(true);
  });
  it("rejects impossible dates and wrong formats", () => {
    for (const bad of [
      "2026-02-31",
      "2027-02-29",
      "2026-13-01",
      "2026-00-10",
      "2026-04-31",
      "30/06/2027",
      "2026-6-1",
      "",
    ]) {
      expect(isRealCalendarDate(bad)).toBe(false);
    }
  });
});

describe("inventory import: impossible expiry dates", () => {
  it("flags the row rather than letting the database reject the whole batch", () => {
    const result = parsePharmacyInventoryImportText("name,expiry\nGood,2027-06-30\nBad,2026-02-31");
    expect(result.invalidRows).toEqual([3]);
    expect(result.items.map((item) => item.name)).toEqual(["Good"]);
  });
});

describe("rowsToCsv numbers vs text", () => {
  it("keeps negative numbers numeric but still neutralises formula-looking text", () => {
    const csv = rowsToCsv(
      ["Adjustment", "Note"],
      [
        [-12.5, "-12.5"],
        [3, "+SUM(A1)"],
        [0, "@cmd"],
      ],
    );
    const lines = csv.split("\r\n");
    expect(lines[1]).toBe(`"-12.5","'-12.5"`);
    expect(lines[2]).toBe(`"3","'+SUM(A1)"`);
    expect(lines[3]).toBe(`"0","'@cmd"`);
  });
});

describe("report date formatting", () => {
  it("shows a dash for missing or unparseable values", () => {
    expect(formatReportDate(null)).toBe("—");
    expect(formatReportDate(undefined)).toBe("—");
    expect(formatReportDate("not a date")).toBe("—");
    expect(formatReportDateTime("")).toBe("—");
  });
  it("formats a valid ISO date", () => {
    expect(formatReportDate("2026-10-02T12:00:00Z")).toMatch(/02 Oct 2026/);
  });
});

describe("roundMoney", () => {
  it("rounds to pesewas without floating-point drift", () => {
    expect(roundMoney(1.005)).toBe(1.01);
    expect(roundMoney(0.1 + 0.2)).toBe(0.3);
    expect(roundMoney(19.999)).toBe(20);
  });
});

describe("audit categories", () => {
  it("groups known events and falls back to other for unknown ones", () => {
    expect(auditCategory("RFQ awarded")).toBe("rfq");
    expect(auditCategory("Credit payment recorded")).toBe("credit");
    expect(auditCategory("Pharmacy inventory stock adjusted")).toBe("inventory");
    expect(auditCategory("Business approved")).toBe("verification");
    expect(auditCategory("Order classification recorded")).toBe("order");
    expect(auditCategory("Order classification changed")).toBe("order");
    expect(auditCategory("Order payment method changed")).toBe("order");
    expect(auditCategory("Something new")).toBe("other");
    expect(auditCategoryLabel("RFQ created")).toBe("RFQ");
  });
});

describe("inventory PDF sheet", () => {
  const item = {
    name: "Gloves",
    item_type: "medical_consumable",
    category: null,
    stock: 4,
    reorder_level: 10,
    unit_cost_ghs: 2.5,
    selling_price_ghs: null,
    expiry_date: "2027-01-31",
    batch_number: "B7",
    supplier: null,
  } as unknown as PharmacyInventoryItem;

  it("has one cell per header and combines expiry with batch", () => {
    const sheet = inventoryItemsToPdfSheet([item]);
    expect(sheet.rows[0]).toHaveLength(sheet.headers.length);
    expect(sheet.rows[0]).toContain("2027-01-31 / B7");
    expect(sheet.rows[0][0]).toBe("Gloves");
  });
  it("is an empty table, not an error, for no items", () => {
    expect(inventoryItemsToPdfSheet([]).rows).toEqual([]);
  });
});
