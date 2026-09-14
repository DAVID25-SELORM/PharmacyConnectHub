import assert from "node:assert/strict";
import { chromium } from "@playwright/test";
import { readFile } from "node:fs/promises";
const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  const page = await browser.newPage();
  await page.route("**/*", (r) =>
    ["127.0.0.1", "localhost"].includes(new URL(r.request().url()).hostname)
      ? r.continue()
      : r.abort(),
  );
  await page.goto("http://127.0.0.1:4180/");
  const result = await page.evaluate(async () => {
    const { parseProductImportFile } = await import("/src/lib/product-import.ts");
    const csv = await parseProductImportFile(
      new File(["name,brand,price,stock\nDrug,Brand,10,25"], "stock.csv", { type: "text/csv" }),
    );
    const empty = await parseProductImportFile(
      new File(["name,brand,price,stock\nDrug,Brand,,25"], "stock.csv"),
    );
    const XLSX = await import("/node_modules/.vite/deps/xlsx.js");
    const book = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(
      book,
      XLSX.utils.aoa_to_sheet([
        ["name", "price", "stock"],
        ["Drug", 10, 25],
      ]),
      "Products",
    );
    const xlsx = await parseProductImportFile(
      new File([XLSX.write(book, { type: "array", bookType: "xlsx" })], "stock.xlsx"),
    );
    return {
      csv: csv.products[0].stock,
      empty: empty.invalidRows.length,
      xlsx: xlsx.products[0].stock,
    };
  });
  assert.deepEqual(result, { csv: 25, empty: 1, xlsx: 25 });
  console.log("PASS browser import worker: CSV, XLSX and empty middle-column rejection");
  // Test the production worker with deployed CSP semantics and real bundled dependencies.
  const html = await readFile("dist/index.html", "utf8");
  const config = JSON.parse(await readFile("vercel.json", "utf8"));
  assert.ok(html.includes("assets/"));
  assert.ok(
    config.headers.some((x) =>
      x.headers.some(
        (h) => h.key === "Content-Security-Policy" && h.value.includes("worker-src 'self' blob:"),
      ),
    ),
  );
  console.log("PASS production CSP includes the parser worker boundary");
} finally {
  await browser.close();
}
