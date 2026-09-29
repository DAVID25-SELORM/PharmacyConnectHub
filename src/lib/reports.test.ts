import { describe, expect, it } from "vitest";
import {
  formatGHSCell,
  rangeToRpcArgs,
  reportCsvExports,
  reportExportSheets,
  reportFilename,
  rowsToCsv,
} from "./reports";

describe("rangeToRpcArgs", () => {
  it("passes named ranges through with no from/to", () => {
    expect(rangeToRpcArgs({ range: "30d", from: "", to: "" })).toEqual({
      p_range: "30d",
      p_from: null,
      p_to: null,
    });
    expect(rangeToRpcArgs({ range: "all", from: "", to: "" }).p_range).toBe("all");
  });

  it("only sends from/to for a custom range, as day-start/day-end UTC bounds", () => {
    const args = rangeToRpcArgs({ range: "custom", from: "2026-09-01", to: "2026-09-03" });
    expect(args.p_range).toBe("custom");
    expect(args.p_from).toBe("2026-09-01T00:00:00.000Z");
    expect(args.p_to).toBe("2026-09-03T23:59:59.999Z");
  });

  it("ignores from/to when the range isn't custom", () => {
    const args = rangeToRpcArgs({ range: "7d", from: "2026-09-01", to: "2026-09-03" });
    expect(args.p_from).toBeNull();
    expect(args.p_to).toBeNull();
  });
});

describe("formatGHSCell", () => {
  it("formats with a currency prefix and two decimals", () => {
    expect(formatGHSCell(1234.5)).toBe("GHS 1,234.50");
    expect(formatGHSCell(null)).toBe("GHS 0.00");
    expect(formatGHSCell("75")).toBe("GHS 75.00");
  });
});

describe("rowsToCsv", () => {
  it("neutralises formula injection and escapes quotes, same as the Activity Log export", () => {
    const csv = rowsToCsv(["Name", "Note"], [['=HYPERLINK("x")', 'He said "hi"']]);
    expect(csv).toContain(`"'=HYPERLINK(""x"")"`);
    expect(csv).toContain(`"He said ""hi"""`);
    expect(csv.split("\r\n")).toHaveLength(2);
  });
});

describe("reportFilename", () => {
  it("defaults to csv and accepts an explicit extension", () => {
    expect(reportFilename("orders")).toMatch(/^drugxone-orders-\d{4}-\d{2}-\d{2}\.csv$/);
    expect(reportFilename("orders", "xlsx")).toMatch(/^drugxone-orders-\d{4}-\d{2}-\d{2}\.xlsx$/);
  });
});

describe("reportExportSheets", () => {
  it("wraps a single-table payload as one 'Report' sheet", () => {
    const sheets = reportExportSheets({
      filenamePrefix: "orders",
      headers: ["A"],
      rows: [["1"]],
    });
    expect(sheets).toEqual([{ name: "Report", headers: ["A"], rows: [["1"]] }]);
  });

  it("passes a multi-sheet payload through unchanged", () => {
    const input = [
      { name: "Wholesalers", headers: ["A"], rows: [["1"]] },
      { name: "Pharmacies", headers: ["B"], rows: [["2"]] },
    ];
    expect(reportExportSheets({ filenamePrefix: "businesses", sheets: input })).toBe(input);
  });
});

describe("reportCsvExports", () => {
  it("emits one file with the plain prefix for a single-table payload", () => {
    const exports = reportCsvExports({ filenamePrefix: "orders", headers: ["A"], rows: [["1"]] });
    expect(exports).toHaveLength(1);
    expect(exports[0].filename).toMatch(/^drugxone-orders-\d{4}-\d{2}-\d{2}\.csv$/);
    expect(exports[0].csv).toBe(rowsToCsv(["A"], [["1"]]));
  });

  it("emits one suffixed file per sheet for a multi-sheet payload, since CSV can't hold both", () => {
    const exports = reportCsvExports({
      filenamePrefix: "businesses",
      sheets: [
        { name: "Wholesalers", headers: ["A"], rows: [["1"]] },
        { name: "Top Pharmacies", headers: ["B"], rows: [["2"]] },
      ],
    });
    expect(exports.map((e) => e.filename)).toEqual([
      expect.stringMatching(/^drugxone-businesses-wholesalers-\d{4}-\d{2}-\d{2}\.csv$/),
      expect.stringMatching(/^drugxone-businesses-top-pharmacies-\d{4}-\d{2}-\d{2}\.csv$/),
    ]);
  });
});
