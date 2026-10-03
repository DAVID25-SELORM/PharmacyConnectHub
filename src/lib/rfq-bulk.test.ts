import { describe, it, expect } from "vitest";
import { rfqRows, rfqRowIssues } from "./rfq-bulk";
describe("bulk RFQ entry", () => {
  it("keeps 150 manual medicines and notes without a catalogue id", () => {
    const rows = rfqRows([
      ["Medicine", "Quantity", "Notes"],
      ...Array.from({ length: 150 }, (_, i) => [`Medicine ${i}`, i + 1, "Pack of 10"]),
    ]);
    expect(rows).toHaveLength(150);
    expect(rows[149]).toEqual({
      productName: "Medicine 149",
      quantity: "150",
      notes: "Pack of 10",
    });
    expect(rfqRowIssues(rows).size).toBe(0);
  });
  it("rejects missing headers and empty imports", () => {
    expect(() => rfqRows([["Medicine"], ["Name"]])).toThrow();
    expect(() => rfqRows([["Medicine", "Quantity"]])).toThrow();
  });
  it("flags duplicates across pages and preserves invalid rows for correction", () => {
    const rows = rfqRows([
      ["Name", "Qty"],
      ["Test", 2],
      [" test ", 3],
      ["", 4],
      ["Other", 1.5],
      ["Last", 0],
    ]);
    expect(rows).toHaveLength(5);
    expect([...rfqRowIssues(rows).keys()]).toEqual([0, 1, 2, 3, 4]);
  });
});
