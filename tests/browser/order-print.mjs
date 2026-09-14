import assert from "node:assert/strict";
import { chromium } from "@playwright/test";
import { readFile, mkdir } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

// Local browser UI checks with synthetic data. All external requests are blocked.
const browser = await chromium.launch({ channel: "chrome", headless: true });
const dir = ".tmp/print-qa";
await mkdir(dir, { recursive: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
const consoleErrors = [];
page.on("pageerror", (error) => consoleErrors.push(error.message));
await page.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (url.protocol === "file:" || url.hostname === "127.0.0.1" || url.hostname === "localhost")
    return route.continue();
  return route.abort();
});
try {
  for (const name of ["order", "multipage"]) {
    await page.goto(pathToFileURL(resolve(`${dir}/${name}.html`)).href);
    await page.emulateMedia({ media: "print" });
    assert.equal(await page.locator("h1").innerText(), "ORDER");
    assert.equal(
      await page.locator("body").evaluate((el) => el.scrollWidth <= window.innerWidth),
      true,
      "no horizontal clipping",
    );
    await page.pdf({ path: `${dir}/${name}.pdf`, preferCSSPageSize: true, printBackground: true });
    await page.screenshot({ path: `${dir}/${name}.png`, fullPage: true });
    console.log(`PASS ${name}: A4 PDF and screenshot rendered without horizontal clipping`);
  }
  await page.emulateMedia({ media: "screen" });
  let type = "pharmacy";
  let denied = false;
  const calls = [];
  const printable = {
    order_number: "ORD-100001",
    created_at: "2026-09-14T09:30:00Z",
    status: "accepted",
    payment_status: "unpaid",
    payment_method: "cod",
    total_ghs: "14.50",
    notes: "Call before delivery.",
    buyer: {
      name: "Buyer Pharmacy",
      phone: "0241112222",
      email: "buyer@registered.test",
      address: null,
      city: null,
      region: null,
      location_description: null,
    },
    seller: {
      name: "Seller Wholesale",
      phone: "0243334444",
      email: "seller@registered.test",
      address: null,
      city: null,
      region: null,
      location_description: null,
    },
    items: [
      {
        product_name: "Recorded medicine name",
        quantity: 2,
        unit_price_ghs: "7.25",
        line_subtotal_ghs: "14.50",
      },
    ],
  };
  await page.route("**/src/hooks/use-session.ts*", (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `
    const business={id:'business-${type}',type:'${type}',name:'${type === "pharmacy" ? "Buyer Pharmacy" : "Seller Wholesale"}',verification_status:'approved',staff_role:'owner'};
    export function useSession(){return {loading:false,user:{id:'signed-in-user',email:'owner@registered.test'},business,businesses:[business],roles:['${type}'],profile:{full_name:'Account owner'},setActiveBusiness:()=>{},refresh:async()=>{}};}
  `,
    }),
  );
  await page.route("**/src/integrations/supabase/client.ts*", (route) =>
    route.fulfill({
      contentType: "application/javascript",
      body: `
    window.__rpcCalls=[];window.__mutations=[];
    const order={id:'order-owned',...${JSON.stringify(printable)},total_ghs:14.5,order_items:[{product_name:'Recorded medicine name',quantity:2,unit_price_ghs:7.25}],pharmacy:{name:'Buyer Pharmacy'},wholesaler:{name:'Seller Wholesale'}};
    export const supabase={
      rpc:async(name,args)=>{window.__rpcCalls.push({name,args});return {data:name==='get_order_print'?${denied ? "null" : JSON.stringify(printable)}:[],error:name==='get_order_print'&&${denied}?{message:'access denied'}:null}},
      from:(table)=>{const result={data:table==='orders'?[order]:[],error:null};const q={select:()=>q,eq:()=>q,order:()=>q,limit:()=>q,update:(v)=>{window.__mutations.push(v);return q},then:r=>Promise.resolve(result).then(r)};return q},
      auth:{getSession:async()=>({data:{session:null},error:null}),signOut:async()=>({error:null})},channel:()=>{const q={on:()=>q,subscribe:()=>q};return q},removeChannel:()=>{}
    };
  `,
    }),
  );
  for (type of ["pharmacy", "wholesaler"]) {
    await page.goto(`http://127.0.0.1:4180/${type}`);
    if (type === "pharmacy") await page.getByRole("tab", { name: /My orders/ }).click();
    await page.getByRole("button", { name: "Print Order", exact: true }).click();
    const frame = page.frameLocator('iframe[title="DrugXone order print preview"]');
    await frame.getByRole("heading", { name: "ORDER", exact: true }).waitFor();
    assert.equal(await frame.getByText("Buyer Pharmacy", { exact: true }).count(), 1);
    assert.equal(await frame.getByText("Seller Wholesale", { exact: true }).count(), 1);
    assert.equal(await frame.getByText("GH₵ 7.25", { exact: true }).count(), 1);
    const frameHandle = await page.locator("iframe").elementHandle();
    const inner = await frameHandle.contentFrame();
    await inner.evaluate(() => {
      window.print = () => {
        window.__printCalled = true;
      };
    });
    await page.getByRole("button", { name: "Print / Save PDF" }).click();
    assert.equal(await inner.evaluate(() => window.__printCalled), true);
    const rpcCalls = await page.evaluate(() => window.__rpcCalls);
    assert.deepEqual(rpcCalls.find((x) => x.name === "get_order_print").args, {
      _business_id: `business-${type}`,
      _order_id: "order-owned",
    });
    assert.deepEqual(await page.evaluate(() => window.__mutations), []);
    await page.screenshot({ path: `${dir}/${type}-preview.png`, fullPage: true });
    await page.getByRole("button", { name: "Close", exact: true }).click();
    await page.locator("iframe").waitFor({ state: "detached" });
    assert.equal(await page.locator("iframe").count(), 0, "private document removed on close");
    calls.push(
      `PASS ${type}: print entry, own context, historical price, buyer/seller, print action, no mutations, preview cleanup`,
    );
  }
  denied = true;
  await page.reload();
  await page.getByRole("button", { name: "Print Order", exact: true }).click();
  await page
    .getByText("This order is not available for printing in your current workspace.")
    .waitFor();
  assert.equal(await page.locator("iframe").count(), 0);
  calls.push("PASS denied print: no private preview exposed");
  await page.goto("http://127.0.0.1:4180/");
  const footer = page.locator("footer");
  for (const value of [
    "DrugXone",
    "DAVENTRA Technologies",
    "David Selorm Gabion",
    "drugxone@gmail.com",
    "0247654381",
  ])
    assert.ok((await footer.innerText()).includes(value));
  assert.equal((await footer.innerText()).includes("Accra, Ghana"), false);
  await footer.screenshot({ path: `${dir}/footer.png` });
  calls.push("PASS official footer contacts without invented address");
  assert.deepEqual(consoleErrors, []);
  console.log(calls.join("\n"));
} finally {
  await browser.close();
}
