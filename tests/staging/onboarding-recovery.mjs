import { chromium } from "@playwright/test";
import { readFile, writeFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import assert from "node:assert/strict";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.API_URL).host !== "127.0.0.1:56321") throw new Error("Staging only");
const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
const admin = createClient(cfg.API_URL, cfg.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const browser = await chromium.launch({ channel: "chrome", headless: true });
const results = [];
browser.on("page", (p) => p.setDefaultTimeout(10000));
async function pageFor(u) {
  const p = await browser.newPage();
  await p.route("**/*", (r) =>
    ["127.0.0.1", "localhost"].includes(new URL(r.request().url()).hostname)
      ? r.continue()
      : r.abort(),
  );
  await p.goto("http://127.0.0.1:4180/login");
  await p.getByLabel("Email", { exact: true }).fill(u.email);
  await p.getByLabel("Password", { exact: true }).fill(u.password);
  await p.getByRole("button", { name: "Sign in", exact: true }).click();
  await p.waitForURL("**/dashboard");
  return p;
}
try {
  console.log("Starting onboarding");
  const reviewer = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
  await reviewer.auth.signInWithPassword({
    email: users.owner.email,
    password: users.owner.password,
  });
  const evidence = await reviewer
    .from("license_documents")
    .select("version_id")
    .eq("business_id", users.seller.biz);
  const initial = await reviewer
    .from("businesses")
    .select("name,verification_status")
    .eq("id", users.seller.biz)
    .single();
  if (initial.error) throw initial.error;
  if (!process.argv.includes("--resume-replacement")) {
    assert.equal(
      initial.data.verification_status,
      "approved",
      "Revoke test requires approved staging seller",
    );
    const revoker = await pageFor(users.owner);
    await revoker.goto("http://127.0.0.1:4180/admin");
    await revoker.getByRole("tab", { name: /^Approved/ }).click();
    const approvedCard = revoker
      .locator(".bg-card")
      .filter({ has: revoker.getByRole("heading", { name: initial.data.name, exact: true }) })
      .first();
    await approvedCard
      .getByRole("button", { name: "business_registration", exact: true })
      .waitFor();
    await approvedCard.getByRole("button", { name: "Revoke", exact: true }).click();
    await revoker
      .getByRole("dialog")
      .getByLabel("Reason")
      .fill("Local staging evidence replacement");
    const revoked = revoker.waitForResponse((r) =>
      r.url().includes("/rpc/review_business_evidence"),
    );
    await revoker
      .getByRole("dialog")
      .getByRole("button", { name: "Confirm reject", exact: true })
      .click();
    assert.ok((await revoked).ok());
    const revokedBusiness = await reviewer
      .from("businesses")
      .select("verification_status")
      .eq("id", users.seller.biz)
      .single();
    assert.equal(revokedBusiness.data.verification_status, "rejected");
    const supplier = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
    const supplierLogin = await supplier.auth.signInWithPassword({
      email: users.seller.email,
      password: users.seller.password,
    });
    if (supplierLogin.error) throw supplierLogin.error;
    const denied = await supplier.rpc("preview_wholesaler_import", {
      _business_id: users.seller.biz,
      _products: [{ name: "Denied test", price_ghs: 1, stock: 1 }],
      _mode: "add",
    });
    assert.match(denied.error?.message ?? "", /approved wholesaler/i);
    results.push({
      name: "Browser revocation removes approval and blocks inventory import",
      result: "PASS",
    });
  }
  const seller = await pageFor(users.seller);
  await seller.goto("http://127.0.0.1:4180/onboarding");
  await seller.getByText("Replace", { exact: true }).nth(2).waitFor({ timeout: 10000 });
  for (const type of ["wholesale_license", "fda_certificate", "business_registration"]) {
    const response = seller
      .waitForResponse(
        (r) =>
          r.url().includes("/rest/v1/license_documents") &&
          ["POST", "PATCH"].includes(r.request().method()),
        { timeout: 10000 },
      )
      .catch(() => null);
    await seller.locator("#file-" + type).setInputFiles({
      name: type + ".pdf",
      mimeType: "application/pdf",
      buffer: Buffer.from("%PDF-1.4\nLocal test evidence"),
    });
    const completed = await response;
    if (!completed)
      throw new Error(
        "Upload metadata absent: " + (await seller.locator("body").innerText()).slice(-2200),
      );
    assert.ok(completed.ok(), await completed.text());
  }
  results.push({
    name: "All three wholesaler evidence types uploaded through onboarding UI",
    result: "PASS",
  });
  const retained = await reviewer
    .from("license_document_versions")
    .select("version_id")
    .in(
      "version_id",
      evidence.data.map((d) => d.version_id),
    );
  if (retained.error) throw retained.error;
  assert.equal(retained.data.length, evidence.data.length);
  console.log("Uploads completed");
  const business = await reviewer
    .from("businesses")
    .select("name,verification_status")
    .eq("id", users.seller.biz)
    .single();
  if (business.error) throw business.error;
  assert.equal(business.data.verification_status, "pending");
  const owner = await pageFor(users.owner);
  await owner.goto("http://127.0.0.1:4180/admin");
  const card = owner
    .locator(".bg-card")
    .filter({ has: owner.getByRole("heading", { name: business.data.name, exact: true }) })
    .first();
  await card.getByRole("button", { name: "Approve", exact: true }).waitFor({ timeout: 10000 });
  for (const docType of ["wholesale_license", "fda_certificate", "business_registration"]) {
    await card.getByRole("button", { name: docType, exact: true }).waitFor();
  }
  const review = owner.waitForResponse((r) => r.url().includes("/rpc/review_business_evidence"));
  await card.getByRole("button", { name: "Approve", exact: true }).click();
  const reviewed = await review;
  assert.ok(reviewed.ok(), await reviewed.text());
  results.push({ name: "Admin UI approves current evidence versions", result: "PASS" });
  results.push({
    name: "Approved document replacement via onboarding UI",
    result: "PASS",
    reason:
      "Existing admin revocation, owner replacement and current-evidence approval workflow passed.",
  });
} catch (e) {
  results.push({ name: "Onboarding/admin acceptance", result: "FAIL", error: e.message });
}
if (!process.argv.includes("--evidence-only"))
  try {
    console.log("Starting recovery");
    const u = users.buyer2;
    const link = await admin.auth.admin.generateLink({ type: "recovery", email: u.email });
    if (link.error) throw link.error;
    const page = await browser.newPage();
    await page.route("**/*", (r) =>
      ["127.0.0.1", "localhost"].includes(new URL(r.request().url()).hostname)
        ? r.continue()
        : r.abort(),
    );
    await page.goto(
      "http://127.0.0.1:4180/reset-password?type=recovery&token_hash=" +
        encodeURIComponent(link.data.properties.hashed_token),
    );
    await page.getByLabel("New password", { exact: true }).waitFor();
    assert.equal(new URL(page.url()).search, "");
    u.password += "Next9!";
    await page.getByLabel("New password", { exact: true }).fill(u.password);
    await page.getByLabel("Confirm password", { exact: true }).fill(u.password);
    await page.locator("button[type=submit]").click();
    await page.waitForURL("**/dashboard", { timeout: 15000 });
    await writeFile(".tmp/staging-rehearsal/users.json", JSON.stringify(users));
    results.push({
      name: "Real recovery token browser consumption, immediate URL cleanup and password update",
      result: "PASS",
    });
  } catch (e) {
    results.push({ name: "Recovery browser acceptance", result: "FAIL", error: e.message });
  }
await browser.close();
await writeFile(
  ".tmp/staging-rehearsal/onboarding-recovery-results.json",
  JSON.stringify(results, null, 2),
);
console.log(JSON.stringify(results));
if (results.some((r) => r.result === "FAIL")) process.exitCode = 1;
