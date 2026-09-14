import { expect, it, vi } from "vitest";
import * as XLSX from "xlsx";
import {
  parseProductImportFileDirect,
  parseProductImportText,
  splitPdfLine,
  MAX_IMPORT_BYTES,
} from "./product-import";
import { validateVerificationFile } from "./verification-file";
it("uses the maintained SheetJS distribution", () => expect(XLSX.version).toBe("0.20.3"));
it.each(["xlsx", "xls"] as const)("imports a valid %s workbook", async (bookType) => {
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(
    workbook,
    XLSX.utils.aoa_to_sheet([
      ["name", "price_ghs", "stock"],
      ["Drug", 10, 25],
    ]),
    "Products",
  );
  const file = new File(
    [XLSX.write(workbook, { type: "array", bookType })],
    "products." + bookType,
  );
  expect((await parseProductImportFileDirect(file)).products[0].stock).toBe(25);
});
it("imports valid CSV", async () =>
  expect(
    (await parseProductImportFileDirect(new File(["name,price,stock\nDrug,10,25"], "p.csv")))
      .products,
  ).toHaveLength(1));
it("rejects unsupported file types", async () =>
  await expect(parseProductImportFileDirect(new File(["x"], "p.exe"))).rejects.toThrow(
    /Unsupported/,
  ));
it("rejects oversized files before reading bytes", async () => {
  const file = new File(["x"], "p.xlsx");
  Object.defineProperty(file, "size", { value: MAX_IMPORT_BYTES + 1 });
  const read = vi.spyOn(file, "arrayBuffer");
  await expect(parseProductImportFileDirect(file)).rejects.toThrow(/5MB/);
  expect(read).not.toHaveBeenCalled();
});
it("rejects excessive text row count", () =>
  expect(() =>
    parseProductImportText("name,price\n" + Array(5001).fill("Drug,10").join("\n")),
  ).toThrow(/5,000/));
it("rejects malformed workbook predictably", async () =>
  await expect(
    parseProductImportFileDirect(new File(["not a workbook"], "p.xlsx")),
  ).rejects.toThrow(/Malformed/));
it("preserves empty middle cells in tab and PDF delimiter extraction", () => {
  expect(splitPdfLine("Drug|Brand||25")).toEqual(["Drug", "Brand", "", "25"]);
  expect(splitPdfLine("Drug\tBrand\t\t25")).toEqual(["Drug", "Brand", "", "25"]);
  expect(
    parseProductImportText("name\tbrand\tprice\tstock\nDrug\tBrand\t\t25").invalidRows,
  ).toEqual([2]);
});
it("rejects ambiguous whitespace-only tables", () => {
  expect(() => splitPdfLine("Drug    Brand    25")).toThrow(/Ambiguous/);
  expect(() => parseProductImportText("name  price  stock\nDrug  25")).toThrow(/Ambiguous/);
});
it("rejects formula cells rather than executing or trusting cached results", async () => {
  const sheet = XLSX.utils.aoa_to_sheet([
    ["name", "price"],
    ["Drug", 10],
  ]);
  sheet.B2 = { t: "n", v: 10, f: 'HYPERLINK("https://malicious.test")' };
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, sheet, "Products");
  await expect(
    parseProductImportFileDirect(
      new File([XLSX.write(workbook, { type: "array", bookType: "xlsx" })], "p.xlsx"),
    ),
  ).rejects.toThrow(/Formula/);
});
it("verification files enforce size, extension, MIME and signature", async () => {
  await expect(
    validateVerificationFile(new File(["%PDF-1.7"], "e.pdf", { type: "application/pdf" })),
  ).resolves.toBe("application/pdf");
  await expect(
    validateVerificationFile(new File(["<script>"], "e.html", { type: "text/html" })),
  ).rejects.toThrow(/Only PDF/);
  await expect(
    validateVerificationFile(new File(["not PDF"], "e.pdf", { type: "application/pdf" })),
  ).rejects.toThrow(/content/);
  const file = new File(["%PDF-"], "e.pdf");
  Object.defineProperty(file, "size", { value: 10485761 });
  await expect(validateVerificationFile(file)).rejects.toThrow(/10MB/);
});
it("rejects contradictory MIME before workbook parsing", async () => {
  await expect(
    parseProductImportFileDirect(new File(["PKfake"], "stock.xlsx", { type: "text/html" })),
  ).rejects.toThrow(/MIME/);
});
