import assert from "node:assert/strict";
import { chromium } from "@playwright/test";
const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
await page.route("**/*", (route) => {
  const u = new URL(route.request().url());
  return ["127.0.0.1", "localhost"].includes(u.hostname) ? route.continue() : route.abort();
});
await page.route("**/src/hooks/use-session.ts*", (route) =>
  route.fulfill({
    contentType: "application/javascript",
    body: `
const business={id:'seller',type:'wholesaler',name:'Test Seller',verification_status:'approved',staff_role:'owner'};
export function useSession(){return {loading:false,user:{id:'owner'},business,businesses:[business],roles:['wholesaler'],profile:{},refresh:async()=>{}};}`,
  }),
);
await page.route("**/src/integrations/supabase/client.ts*", (route) =>
  route.fulfill({
    contentType: "application/javascript",
    body: `
window.__writes=[];window.__calls=[];
const p={id:'product',wholesaler_id:'seller',name:'Test medicine',price_ghs:7.25,stock:100,brand:'Brand',form:'Tablet',pack_size:'20',category:'Other',active:true};
export const supabase={
from:(table)=>{let single=false;const q={select:()=>q,eq:()=>q,order:()=>q,limit:()=>q,single:()=>{single=true;return q},update:(v)=>{window.__writes.push(v);return q},then:r=>Promise.resolve({data:table==='products'?(single?{stock:80}:[p]):[],error:null}).then(r)};return q;},
rpc:async(name,args)=>{window.__calls.push({name,args});return {data:100,error:null};},
auth:{getSession:async()=>({data:{session:{user:{id:'owner'}}}}),signOut:async()=>({error:null})},
channel:()=>{const q={on:()=>q,subscribe:()=>q};return q},removeChannel:()=>{}};`,
  }),
);
try {
  await page.goto("http://127.0.0.1:4180/wholesaler");
  await page.getByRole("tab", { name: /My products/ }).click();
  await page.getByRole("button", { name: "Edit product", exact: true }).click();
  assert.equal(await page.locator("#e-stock").count(), 0);
  await page.locator("#e-price").fill("9.25");
  await page.getByRole("button", { name: /Save changes/ }).click();
  await page.getByRole("dialog").waitFor({ state: "hidden" });
  const writes = await page.evaluate(() => window.__writes);
  assert.equal(writes.length, 1);
  assert.equal("stock" in writes[0], false);
  console.log("PASS price editing excludes stock even after a stale 100 → 80 balance");
  await page.getByRole("button", { name: "Stock", exact: true }).click();
  await page.getByText("Current system stock: 80", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Confirm stock adjustment" }).click();
  assert.equal((await page.evaluate(() => window.__calls)).length, 0);
  console.log("PASS blank adjustment never invokes stock RPC");
  await page.getByLabel("Quantity", { exact: true }).fill("20");
  await page.getByRole("button", { name: "Confirm stock adjustment" }).click();
  await page.getByText("Stock operation completed", { exact: true }).waitFor();
  const call = (await page.evaluate(() => window.__calls))[0];
  assert.equal(call.name, "adjust_product_stock");
  assert.equal(call.args._quantity, 20);
  assert.equal(call.args._operation, "add");
  assert.ok(call.args._request_id);
  assert.equal(call.args._expected_stock, undefined);
  console.log(
    "PASS Add submits an explicit delta and durable request ID, never an absolute balance",
  );
  await page.getByLabel("Operation", { exact: true }).selectOption("reconcile");
  await page.getByLabel("New physical count", { exact: true }).fill("73");
  await page.getByText("Difference: -7", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Confirm reconciliation" }).click();
  await page.waitForFunction(() => window.__calls.length === 2);
  const reconciliation = (await page.evaluate(() => window.__calls))[1];
  assert.equal(reconciliation.args._expected_stock, 80);
  assert.equal(reconciliation.args._quantity, 73);
  console.log("PASS reconciliation previews the difference and submits expected stock separately");
  assert.deepEqual(errors, []);
} finally {
  await browser.close();
}
