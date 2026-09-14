import { chromium } from "@playwright/test";
import { readFile, writeFile } from "node:fs/promises";
import * as XLSX from "xlsx";
import assert from "node:assert/strict";
const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
const browser = await chromium.launch({ channel: "chrome", headless: true });
const results = [];
try {
  const page = await browser.newPage();
  await page.route("**/*", (r) =>
    ["127.0.0.1", "localhost"].includes(new URL(r.request().url()).hostname)
      ? r.continue()
      : r.abort(),
  );
  await page.goto("http://127.0.0.1:4180/login");
  await page.getByLabel("Email", { exact: true }).fill(users.seller.email);
  await page.getByLabel("Password", { exact: true }).fill(users.seller.password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL("**/dashboard");
  await page.goto("http://127.0.0.1:4180/wholesaler");
  await page.getByRole("tab", { name: /My products/ }).click();
  const files = [
    {
      name: "browser.csv",
      mimeType: "text/csv",
      buffer: Buffer.from("name,brand,form,price_ghs,stock\nBrowser CSV,Test,Tablet,12,15"),
    },
  ];
  for (const bookType of ["xls", "xlsx"]) {
    const b = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(
      b,
      XLSX.utils.aoa_to_sheet([
        ["name", "brand", "form", "price_ghs", "stock"],
        ["Browser " + bookType, "Test", "Tablet", 12, 15],
      ]),
      "Products",
    );
    files.push({
      name: "browser." + bookType,
      mimeType:
        bookType === "xls"
          ? "application/vnd.ms-excel"
          : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      buffer: XLSX.write(b, { type: "buffer", bookType }),
    });
  }
  for (const file of files) {
    await page.getByRole("button", { name: "Bulk upload" }).click();
    await page.locator("input[type=file]").setInputFiles(file);
    await page.getByRole("button", { name: "Preview import", exact: true }).click();
    await page.getByRole("button", { name: "Confirm Import", exact: true }).waitFor();
    const response = page.waitForResponse(
      (r) =>
        r.url().includes("/rpc/preview_wholesaler_import") &&
        r.request().postData()?.includes("_confirm_token"),
    );
    await page.getByRole("button", { name: "Confirm Import", exact: true }).click();
    assert.equal((await response).status(), 200);
    await page.getByRole("dialog").waitFor({ state: "hidden" });
    results.push({ name: file.name + " real browser preview and database commit", result: "PASS" });
  }
  await page.getByRole("button", { name: "Bulk upload" }).click();
  await page.getByRole("tab", { name: "Paste table" }).click();
  await page.locator("textarea").fill("name,brand,price,stock\nEmpty price,Brand,,25");
  await page.getByRole("button", { name: "Preview import", exact: true }).click();
  await page.getByRole("button", { name: "Confirm Import", exact: true }).waitFor();
  assert.ok(await page.getByRole("button", { name: "Confirm Import", exact: true }).isDisabled());
  results.push({ name: "Empty middle price cannot be committed", result: "PASS" });
  await page
    .locator("textarea")
    .fill("name,brand,form,price,stock\nBrowser pasted,Brand,Tablet,10,25");
  await page.getByRole("button", { name: /Preview import|Refresh preview/ }).click();
  await page.getByRole("button", { name: "Confirm Import", exact: true }).click();
  await page.getByRole("dialog").waitFor({ state: "hidden" });
  results.push({ name: "Pasted table commits through real preview RPC", result: "PASS" });
} catch (e) {
  results.push({ name: "Browser import flow", result: "FAIL", error: e.message });
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(".tmp/staging-rehearsal/import-results.json", JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results));
}
