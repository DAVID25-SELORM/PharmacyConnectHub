// Runs the real api/orders/confirm-payment.ts and send-receipt.ts handlers against the LOCAL Supabase stack with real GoTrue JWTs, on
// cash orders collected portion by portion (cash back-orders) and on an ordinary cash order. The receipt email provider is
// replaced by a stub that records what would have been sent.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/cash-receipts-api.local.mjs
//
// Needs the database to be in the state left by cash-backorders.sql PLUS one extra order built by this script's own setup
// (below), so run it right after a fresh `cash-backorders.sql` run. It refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
const SERVICE = process.env.SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
process.env.SUPABASE_URL = API;
process.env.SUPABASE_PUBLISHABLE_KEY = ANON;
process.env.SUPABASE_SERVICE_ROLE_KEY = SERVICE;
process.env.RESEND_API_KEY = "test-key";
process.env.RECEIPT_FROM_EMAIL = "receipts@example.test";
process.env.SITE_URL = "http://localhost";

const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-c", sql]).toString().trim();

// The receipt provider: record the request instead of sending it.
const sent = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
  if (String(url).includes("api.resend.com")) {
    sent.push(JSON.parse(init.body));
    return new Response(JSON.stringify({ id: "stub" }), { status: 200, headers: { "content-type": "application/json" } });
  }
  return realFetch(url, init);
};

async function token(email) {
  const r = await realFetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "Passw0rd!x" }),
  });
  const j = await r.json();
  assert.ok(j.access_token, `sign-in failed for ${email}`);
  return j.access_token;
}

const confirm = (await import("../../api/orders/confirm-payment.ts")).default;
const resend = (await import("../../api/orders/send-receipt.ts")).default;

async function call(handler, bearer, body) {
  let status = 200;
  let payload;
  const res = { status(c) { status = c; return res; }, json(p) { payload = p; return res; } };
  await handler({ method: "POST", headers: { authorization: `Bearer ${bearer}`, host: "localhost" }, body }, res);
  return { status, payload };
}

let pass = 0;
let total = 0;
const check = (name, ok, detail = "") => {
  total++;
  console.log(`${ok ? "PASS" : "FAIL"} | ${name}${ok ? "" : ` -> ${detail}`}`);
  if (ok) pass++;
  else process.exitCode = 1;
};
const mailBody = (mail) => String(mail.html ?? "") + String(mail.text ?? "");

const t = { wo: await token("wo@zz.test"), wc: await token("wc@zz.test"), ww: await token("ww@zz.test"), po: await token("po@zz.test") };

// ---- Setup: a cash order D with a back-order of 6 units (BO A at 100): main 400 delivered, shipment 2 (300) delivered, shipment 3 (300)
// dispatched. Built through the real functions, as the pharmacy and wholesaler owners.
const sql = (file) => psql(file);
const ids = JSON.parse(
  psql(`select json_build_object('po', (select id from auth.users where email='po@zz.test'), 'wo', (select id from auth.users where email='wo@zz.test'),
    'good', (select id from public.businesses where name='Good Pharmacy'), 'alpha', (select id from public.businesses where name='Alpha Wholesale'),
    'pa', (select id from public.products where name='BO A'))`),
);
const as = (uid) => `select set_config('request.jwt.claims', json_build_object('sub','${uid}','role','authenticated')::text,false), set_config('request.jwt.claim.sub','${uid}',false);`;
const run = (statements) => psql(statements.join(" "));
run([
  as(ids.po),
  `select public.create_marketplace_orders('${ids.po}', '${ids.good}', jsonb_build_array(jsonb_build_object('productId','${ids.pa}','quantity',10,'category','cash_private')), '{}', true, jsonb_build_object('${ids.alpha}','cod'));`,
]);
const D = psql(`select id from public.orders order by created_at desc limit 1`);
psql(`update public.orders set status='accepted' where id='${D}'`);
const line = psql(`select id from public.order_items where order_id='${D}' limit 1`);
const amendment = psql(`${as(ids.wo)} select public.propose_partial_fulfilment('${D}','Short',jsonb_build_array(jsonb_build_object('order_item_id','${line}','supplied_qty',4,'stock_treatment','release')),gen_random_uuid())->>'amendment_id'`).split("\n").pop();
psql(`${as(ids.po)} select public.respond_to_amendment('${amendment}','accept_backorder',null)`);
for (const s of ["picking", "packed", "ready_for_dispatch", "dispatched", "delivered"]) psql(`update public.orders set status='${s}' where id='${D}'`);
const mk = () =>
  psql(`${as(ids.wo)} select public.create_backorder_shipment('${D}', jsonb_build_array(jsonb_build_object('order_item_id','${line}','quantity',3)), null, gen_random_uuid())->>'shipment_id'`).split("\n").pop();
const s2 = mk();
const s3 = mk();
for (const step of ["packed", "dispatched", "delivered"]) psql(`${as(ids.wo)} select public.advance_backorder_shipment('${s2}','${step}')`);
for (const step of ["packed", "dispatched"]) psql(`${as(ids.wo)} select public.advance_backorder_shipment('${s3}','${step}')`);
check("setup: the order is delivered and unpaid at 1000", psql(`select status||'/'||payment_status||'/'||effective_total_ghs from public.orders where id='${D}'`) === "delivered/unpaid/1000.00");

// ---- Who may confirm.
let r = await call(confirm, t.ww, { orderId: D });
check("a warehouse user is refused (403)", r.status === 403, JSON.stringify(r));
r = await call(confirm, t.po, { orderId: D });
check("the pharmacy owner is refused (403)", r.status === 403 || r.status === 404, JSON.stringify(r));

// ---- The main delivery.
sent.length = 0;
r = await call(confirm, t.wc, { orderId: D });
check("a cashier confirms the main delivery: 200 and the receipt is emailed", r.status === 200 && r.payload.receiptSent === true, JSON.stringify(r));
check("the main collection is recorded: 400", psql(`select amount_ghs from public.order_collections where order_id='${D}' and shipment_id is null`) === "400.00");
check("exactly one receipt email went out, for the main delivery only (400, 4 units)", sent.length === 1 && /400\.00/.test(mailBody(sent[0])) && !/shipment/.test(mailBody(sent[0]).toLowerCase()), JSON.stringify(sent.map(mailBody)).slice(0, 300));
check("the order is still unpaid (two shipments owed)", psql(`select payment_status from public.orders where id='${D}'`) === "unpaid");

// ---- A shipment.
sent.length = 0;
r = await call(confirm, t.wo, { orderId: D, shipmentId: s2 });
check("the owner confirms shipment 2: 200", r.status === 200 && r.payload.receiptSent === true, JSON.stringify(r));
check("its receipt is labelled with the shipment and carries 300", sent.length === 1 && /shipment 2/.test(mailBody(sent[0])) && /300\.00/.test(mailBody(sent[0])), mailBody(sent[0] ?? {}).slice(0, 300));
r = await call(confirm, t.wo, { orderId: D, shipmentId: s3 });
check("shipment 3 cannot be confirmed before it is delivered (400)", r.status === 400 && /delivered/.test(JSON.stringify(r.payload)), JSON.stringify(r));
psql(`${as(ids.wo)} select public.advance_backorder_shipment('${s3}','delivered')`);
sent.length = 0;
r = await call(confirm, t.wo, { orderId: D, shipmentId: s3 });
check("shipment 3 is confirmed once delivered: 200", r.status === 200, JSON.stringify(r));
check("now the whole order is paid with three collections (400 + 300 + 300)", psql(`select payment_status||'/'||(select count(*)||'/'||sum(amount_ghs) from public.order_collections where order_id='${D}') from public.orders where id='${D}'`) === "paid/3/1000.00");

// ---- Resending.
sent.length = 0;
r = await call(resend, t.wo, { orderId: D, shipmentId: s2 });
check("the receipt for shipment 2 can be sent again", r.status === 200 && r.payload.sent === true && sent.length === 1 && /shipment 2/.test(mailBody(sent[0])), JSON.stringify(r));
check("the collection records when it was sent", psql(`select receipt_sent_to is not null from public.order_collections where shipment_id='${s2}'`) === "t");
sent.length = 0;
r = await call(resend, t.wo, { orderId: D });
check("the main delivery's receipt can be sent again (400, not the order total)", r.status === 200 && sent.length === 1 && /400\.00/.test(mailBody(sent[0])) && !/1000\.00/.test(mailBody(sent[0])), JSON.stringify(r));
r = await call(resend, t.ww, { orderId: D });
check("a warehouse user cannot resend (403)", r.status === 403, JSON.stringify(r));

// ---- An ordinary cash order is untouched by all this.
const N = psql(`select id from public.orders where not is_credit_order and id not in (select order_id from public.order_collections) and status = 'accepted' order by created_at desc limit 1`);
if (N) {
  for (const s of ["picking", "packed", "ready_for_dispatch", "dispatched", "delivered"]) psql(`update public.orders set status='${s}' where id='${N}'`);
  sent.length = 0;
  r = await call(confirm, t.wo, { orderId: N });
  check("an ordinary cash order is confirmed and receipted as before", r.status === 200 && r.payload.receiptSent === true && psql(`select payment_status from public.orders where id='${N}'`) === "paid", JSON.stringify(r));
  r = await call(confirm, t.wo, { orderId: N, shipmentId: s2 });
  check("a shipment id on an ordinary order is refused (400)", r.status === 400, JSON.stringify(r));
} else {
  console.log("SKIP | no ordinary cash order available");
}

console.log(`${pass}/${total} API checks passed`);
