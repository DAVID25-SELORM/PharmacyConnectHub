// Runs the real payment handlers behind a real Node HTTP server against the LOCAL Supabase stack with real sessions and a stand-in for Paystack, and the REAL return functions called the way the
// screens call them (PostgREST, signed in as the pharmacy and the wholesaler): a return resolved as a refund on an order PAID ONLINE is approved by an administrator, sent to the provider,
// confirmed by the provider's notification, and shows in the supplier's own online-payments view.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-returns-api.local.mjs
//
// Run right after payments-checkout.sql (it uses that suite's users, products and approvals; run pw.sql after it). It switches the platform's online payments on and back off itself.
// Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { startFakePaystack } from "./fake-paystack.mjs";
import { startDevApiServer } from "./dev-api-server.mjs";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_returns_check";

const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-c", sql]).toString().trim();
const realFetch = globalThis.fetch;

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
async function rpc(bearer, fn, args = {}) {
  const r = await realFetch(`${API}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: ANON, Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const body = await r.json().catch(() => null);
  return { ok: r.ok, body, error: r.ok ? null : (body?.message ?? JSON.stringify(body)) };
}

let pass = 0;
let total = 0;
const check = (name, ok, detail = "") => {
  total++;
  console.log(`${ok ? "PASS" : "FAIL"} | ${name}${ok ? "" : ` -> ${detail}`}`);
  if (ok) pass++;
  else process.exitCode = 1;
};

const dev = await startDevApiServer(0);
const fake = await startFakePaystack({ secret: SECRET, webhookUrl: `${dev.baseUrl}/api/payments/webhook` });
process.env.SITE_URL = "http://localhost:5173";
process.env.PAYMENTS_MODE = "test";
process.env.PAYSTACK_SECRET_KEY = SECRET;
process.env.PAYSTACK_BASE_URL = fake.baseUrl;
psql(`update public.payments_settings set online_enabled = true, mode = 'test', auto_refunds = true, split_mode = 'none', max_order_ghs = null`);

const post = async (path, bearer, body) => {
  const headers = { "content-type": "application/json" };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const r = await realFetch(`${dev.baseUrl}${path}`, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
  return { status: r.status, json: await r.json().catch(() => null) };
};
const t = { po: await token("po@zz.test"), wo: await token("wo@zz.test"), admin: await token("admin@zz.test") };
const ids = JSON.parse(
  psql(`select json_build_object('good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'pa', (select id from public.products where name='BO A'))`),
);

// An order paid online (1000.00) through the real handlers, then moved to delivered.
let r = await post("/api/orders/create", t.po, {
  pharmacyId: ids.good,
  requestId: randomUUID(),
  items: [{ productId: ids.pa, quantity: 10, category: "cash_private" }],
  settlementMethods: { [ids.alpha]: "pay_now" },
});
assert.equal(r.status, 200, JSON.stringify(r));
const orderId = r.json.awaitingPayment[0].orderId;
const init = await post("/api/payments/initialize", t.po, { orderId });
assert.equal(init.status, 200, JSON.stringify(init));
const ref = init.json.reference;
fake.payments.get(ref).status = "success";
r = await post("/api/payments/verify", t.po, { orderId });
assert.equal(r.json?.status, "paid", JSON.stringify(r));
for (const s of ["accepted", "picking", "packed", "ready_for_dispatch", "dispatched", "delivered"]) psql(`update public.orders set status = '${s}' where id = '${orderId}'`);
check("(setup) the order is paid online and delivered", psql(`select status || '/' || payment_status from public.orders where id = '${orderId}'`) === "delivered/paid");

// ---- the return, through the real functions
const itemId = psql(`select id from public.order_items where order_id = '${orderId}' limit 1`);
r = await rpc(t.po, "request_order_return", { p_order_id: orderId, p_reason: "damaged", p_note: "Box crushed", p_items: [{ order_item_id: itemId, quantity: 3 }] });
check("the pharmacy requests a return of 3 units", r.ok && typeof r.body === "string", r.error);
const retId = r.body;
r = await rpc(t.wo, "review_order_return", { p_return_id: retId, p_approve: true, p_note: null });
check("the wholesaler approves it", r.ok, r.error);
r = await rpc(t.wo, "mark_order_return_returned", { p_return_id: retId });
check("and marks the goods as returned", r.ok, r.error);
const returnItem = psql(`select id from public.order_return_items where return_id = '${retId}'`);
r = await rpc(t.wo, "inspect_order_return", { p_return_id: retId, p_items: [{ return_item_id: returnItem, quantity_accepted: 3, restock: true }] });
check("and inspects it (3 accepted)", r.ok, r.error);
r = await rpc(t.wo, "resolve_order_return", { p_return_id: retId, p_resolution: "refund", p_note: "Refund the card" });
check("resolving it as a refund works and is worth GHS 300", r.ok && Number(r.body) === 300, r.error + JSON.stringify(r.body));
const refundRow = psql(`select id || '|' || status || '|' || amount_minor || '|' || reason from public.order_refunds where order_id = '${orderId}'`).split("|");
check("a refund of 300.00 was requested for the return and is waiting (automatic refunds are on, but a return always waits)", refundRow[1] === "requested" && refundRow[2] === "30000" && refundRow[3] === "order_return", refundRow.join("|"));
const money = await rpc(t.po, "order_payment_summary", { p_order_id: orderId });
check("the pharmacy sees the refund in progress and nothing due", money.ok && money.body.topup_due_ghs === 0, JSON.stringify(money.body));

// ---- the administrator approves, the system sends it to the provider
const before = fake.refundCalls.length;
r = await post("/api/payments/admin-refund", t.admin, { refundId: refundRow[0], action: "approve" });
check("an administrator approves it: it is sent to the provider for exactly 300 against the order's payment",
  r.status === 200 && fake.refundCalls.length === before + 1 && fake.refundCalls.at(-1).transaction === ref && fake.refundCalls.at(-1).amount === 30000, JSON.stringify(r) + JSON.stringify(fake.refundCalls.at(-1)));
check("the provider's note says what it was for", /order return/.test(fake.refundCalls.at(-1).merchant_note ?? ""), JSON.stringify(fake.refundCalls.at(-1)));
await fake.finishRefund(ref, "processed");
await new Promise((resolve) => setTimeout(resolve, 600));
check("the provider's notification confirms it: refunded", psql(`select status from public.order_refunds where id = '${refundRow[0]}'`) === "succeeded");
check("the order stays delivered and paid (only part of it came back)", psql(`select status || '/' || payment_status from public.orders where id = '${orderId}'`) === "delivered/paid");

// ---- the supplier's own view
const view = await rpc(t.wo, "supplier_settlement_overview", { p_wholesaler_id: ids.alpha, p_from: new Date(Date.now() - 86400000).toISOString(), p_to: new Date(Date.now() + 86400000).toISOString() });
const rec = (view.body?.recent ?? []).find((x) => Number(x.refunded_ghs) === 300);
check("the supplier's own view shows the payment and its GHS 300 refund", view.ok && rec && Number(rec.amount_ghs) === 1000, JSON.stringify(view.body?.recent));
check("and what should settle to it drops accordingly", view.ok && view.body.summary.refunded_ghs >= 300, JSON.stringify(view.body?.summary));
const other = await rpc(t.po, "supplier_settlement_overview", { p_wholesaler_id: ids.alpha, p_from: new Date(Date.now() - 86400000).toISOString(), p_to: new Date(Date.now() + 86400000).toISOString() });
check("a pharmacy cannot read it", !other.ok && /permission/.test(other.error ?? ""), other.error);

psql(`update public.payments_settings set online_enabled = false, auto_refunds = false`);
await fake.close();
await dev.close();
console.log(`${pass}/${total} returns API checks passed`);
