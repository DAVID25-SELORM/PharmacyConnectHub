import { chromium } from "@playwright/test";
import { readFile, writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
const browser = await chromium.launch({ channel: "chrome", headless: true });
const results = [];
try {
  for (const role of ["buyer", "seller"]) {
    const page = await browser.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.route("**/*", (r) =>
      ["127.0.0.1", "localhost"].includes(new URL(r.request().url()).hostname)
        ? r.continue()
        : r.abort(),
    );
    await page.goto("http://127.0.0.1:4180/login");
    await page.getByLabel("Email", { exact: true }).fill(users[role].email);
    await page.getByLabel("Password", { exact: true }).fill(users[role].password);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.waitForURL("**/dashboard", { timeout: 20000 });
    await page.goto("http://127.0.0.1:4180/" + (role === "buyer" ? "pharmacy" : "wholesaler"));
    await page.reload();
    if (role === "buyer") await page.getByRole("tab", { name: /My orders/ }).click();
    await page.getByRole("button", { name: /Print/ }).first().waitFor({ timeout: 20000 });
    await page.getByRole("button", { name: /Print/ }).first().click();
    await page.getByRole("dialog").waitFor();
    assert.ok(await page.getByRole("dialog").innerText());
    await page.screenshot({ path: ".tmp/staging-rehearsal/" + role + "-print.png" });
    await page
      .getByRole("dialog")
      .getByRole("button", { name: "Close", exact: true })
      .click()
      .catch(() => page.keyboard.press("Escape"));
    results.push({
      name: role + " real login, restored session and own-order print",
      result: "PASS",
      consoleErrors: errors,
    });
    if (role === "buyer") {
      await page.getByRole("tab", { name: /Catalog/ }).click();
      const details = page.locator("details").first();
      await details.locator("summary").click();
      await details.getByRole("button", { name: "Add", exact: true }).first().click();
      await page.getByRole("button", { name: /Cart/ }).first().click();
      const response = page.waitForResponse((r) => r.url().endsWith("/api/orders/create"));
      await page.getByRole("button", { name: /Place order/ }).click();
      assert.equal((await response).status(), 200);
      results.push({ name: "Browser catalogue -> cart -> canonical checkout", result: "PASS" });
    }
    await page.close();
  }
} catch (e) {
  results.push({ name: "Real browser golden flow", result: "FAIL", error: e.message });
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(".tmp/staging-rehearsal/browser-results.json", JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results));
}
