import { chromium } from "../.tmp/import-db/node_modules/playwright/index.mjs";
import assert from "node:assert/strict";
const browser = await chromium.launch({
  executablePath: "C:/Program Files/Google/Chrome/Application/chrome.exe",
  headless: true,
});
const user = {
  id: "00000000-0000-0000-0000-000000000001",
  email: "test@example.com",
  aud: "authenticated",
  role: "authenticated",
  app_metadata: {},
  user_metadata: {},
  created_at: "2026-01-01T00:00:00Z",
};
const session = {
  access_token: [
    "eyJhbGciOiJIUzI1NiJ9",
    Buffer.from(JSON.stringify({ sub: user.id, exp: 9999999999, role: "authenticated" })).toString(
      "base64url",
    ),
    "test",
  ].join("."),
  refresh_token: "test",
  expires_at: 9999999999,
  expires_in: 3600,
  token_type: "bearer",
  user,
};
let role = "wholesaler";
let confirmations = 0;
let previews = 0;
const product = {
  id: "p1",
  name: "Augmentin 625 mg",
  brand: "GSK",
  category: "Antibiotics",
  form: "Tablet",
  pack_size: "14",
  price_ghs: 20,
  stock: 40,
  active: true,
  image_hue: 200,
  wholesaler_id: "supplier-a",
  wholesaler: {
    id: "supplier-a",
    name: "Supplier A",
    city: "Accra",
    verification_status: "approved",
  },
};
const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
await context.addInitScript(
  (session) => localStorage.setItem("sb-127-auth-token", JSON.stringify(session)),
  session,
);
await context.route("http://127.0.0.1:54399/**", async (route) => {
  const path = new URL(route.request().url()).pathname;
  const business = {
    id: "b1",
    name: "Test business",
    type: role,
    verification_status: "approved",
    staff_role: "owner",
    city: "Accra",
    region: "Greater Accra",
  };
  let data = [];
  if (path.endsWith("/user")) data = user;
  else if (path.endsWith("/user_roles")) data = [{ role }];
  else if (path.endsWith("/business_staff")) data = [{ role: "owner", business }];
  else if (path.endsWith("/businesses")) data = [business];
  else if (path.endsWith("/products")) data = [product];
  else if (path.endsWith("/rpc/preview_wholesaler_import")) {
    const payload = route.request().postDataJSON();
    if (payload._confirm_token) confirmations++;
    else previews++;
    data = {
      token: "preview-token",
      issues: [],
      rows: payload._products.map((p) => ({
        row: p.source_row,
        kind: "existing",
        name: p.name,
        price_before: 20,
        price_after: p.price_ghs,
        stock_before: 40,
        stock_after: p.stock ?? 40,
      })),
      inserted_count: 0,
      updated_count: 1,
    };
  } else if (path.endsWith("/rpc/list_marketplace_catalogue"))
    data = [
      {
        id: "m1",
        name: product.name,
        generic_name: null,
        strength: null,
        brand_name: "GSK",
        dosage_form: "Tablet",
        pack_size: "14",
        category: "Antibiotics",
        offers: [
          product,
          {
            ...product,
            id: "p2",
            price_ghs: 18,
            wholesaler_id: "supplier-b",
            wholesaler: { ...product.wholesaler, id: "supplier-b", name: "Supplier B" },
          },
        ],
      },
    ];
  await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });
});
const page = await context.newPage();
const errors = [];
page.on("pageerror", (error) => errors.push(error.message));
try {
  await page.goto("http://127.0.0.1:5178/wholesaler");
  await page.getByRole("tab", { name: /My products/ }).click();
  await page.getByRole("button", { name: "Bulk upload", exact: true }).click();
  await page.getByRole("tab", { name: "Paste table", exact: true }).click();
  await page.locator("textarea").fill("name,price_ghs,stock\nAugmentin 625 mg,25,");
  assert.equal(confirmations, 0);
  await page.getByRole("button", { name: "Preview import", exact: true }).click();
  await page.getByRole("button", { name: "Confirm Import", exact: true }).waitFor();
  assert.equal(previews, 1);
  assert.equal(confirmations, 0, "preview must never send a confirmation");
  await page.screenshot({ path: ".tmp/import-preview-desktop.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "Confirm Import", exact: true }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".tmp/import-preview-mobile.png", animations: "disabled" });
  assert.ok(
    await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    "mobile page overflow",
  );
  await page.locator("textarea").fill("name,price_ghs,stock\nAugmentin 625 mg,25,-1");
  assert.equal(
    await page.getByRole("button", { name: "Confirm Import", exact: true }).count(),
    0,
    "editing input invalidates preview",
  );
  await page.getByRole("button", { name: "Preview import", exact: true }).click();
  await page.getByText(/Invalid rows:/).waitFor();
  assert.ok(await page.getByRole("button", { name: "Confirm Import", exact: true }).isDisabled());
  await page.locator("textarea").fill("name,price_ghs,stock\nAugmentin 625 mg,25,");
  await page.getByRole("button", { name: "Preview import", exact: true }).click();
  await page.getByRole("button", { name: "Confirm Import", exact: true }).click();
  await page.getByRole("dialog").waitFor({ state: "hidden" });
  assert.equal(confirmations, 1);
  role = "pharmacy";
  await page.goto("http://127.0.0.1:5178/pharmacy");
  await page.getByText("2 verified suppliers").waitFor();
  assert.equal(
    await page.getByRole("heading", { name: "Augmentin 625 mg", exact: true }).count(),
    1,
  );
  await page.locator("summary").filter({ hasText: "Compare suppliers" }).click();
  await page
    .getByRole("row")
    .filter({ hasText: "Supplier B" })
    .getByRole("button", { name: "Add", exact: true })
    .click();
  await page.getByRole("button", { name: /Cart/ }).click();
  await page.getByRole("dialog").getByText("Supplier B", { exact: true }).waitFor();
  await page.keyboard.press("Escape");
  await page.getByRole("dialog").waitFor({ state: "hidden" });
  await page.locator("summary").scrollIntoViewIfNeeded();
  await page.screenshot({ path: ".tmp/catalogue-mobile.png", animations: "disabled" });
  assert.ok(
    await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    "catalogue mobile overflow",
  );
  assert.deepEqual(errors, []);
  console.log(
    "Browser checks passed: read-only preview, invalidation, validation, explicit confirmation, mobile layout, grouped suppliers and correct supplier cart.",
  );
} finally {
  await browser.close();
}
