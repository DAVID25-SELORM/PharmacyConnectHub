// Runs the real payment handlers (initialize with a top-up, verify, webhook, admin-refund) behind a real Node HTTP server against the LOCAL Supabase stack with real
// sessions, a stand-in for Paystack, and the REAL amendment functions called the way the screens call them (as the wholesaler and the pharmacy), on orders that were
// PAID ONLINE: a shortage is refunded, a price increase must be paid (a top-up) before dispatch.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-adjustments-api.local.mjs
//
// Run right after payments-checkout.sql (it uses that suite's users, products and approvals; run pw.sql after it). It switches the platform's online payments on and
// back off itself. Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { startFakePaystack } from "./fake-paystack.mjs";
import { startDevApiServer } from "./dev-api-server.mjs";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_adjustments_check";

const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-c", sql]).toString().trim();
// Runs SQL and returns "OK" or the database's error message (the part after "ERROR:").
const psqlTry = (sql) => {
  try {
    psql(sql);
    return "OK";
  } catch (error) {
    return String(error.stderr ?? error.message).replace(/^[\s\S]*?ERROR:\s*/, "").split("\n")[0];
  }
};
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
// A database function called the way the app calls it (PostgREST, as the signed-in person).
async function rpc(bearer, fn, args) {
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
psql(`update public.payments_settings set online_enabled = true, mode = 'test', auto_refunds = false`);

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
// A paid online order for ten units at 100 = 1000.00, accepted by the wholesaler.
async function paidAcceptedOrder() {
  const r = await post("/api/orders/create", t.po, {
    pharmacyId: ids.good,
    requestId: randomUUID(),
    items: [{ productId: ids.pa, quantity: 10, category: "cash_private" }],
    settlementMethods: { [ids.alpha]: "pay_now" },
  });
  assert.equal(r.status, 200, JSON.stringify(r));
  const orderId = r.json.awaitingPayment[0].orderId;
  const init = await post("/api/payments/initialize", t.po, { orderId });
  assert.equal(init.status, 200, JSON.stringify(init));
  fake.payments.get(init.json.reference).status = "success";
  const v = await post("/api/payments/verify", t.po, { orderId });
  assert.equal(v.json?.status, "paid", JSON.stringify(v));
  psql(`update public.orders set status = 'accepted' where id = '${orderId}'`);
  return { orderId, ref: init.json.reference };
}
const itemOf = (orderId) => psql(`select id from public.order_items where order_id = '${orderId}' and product_name = 'BO A'`);
const state = (o) => psql(`select status || '/' || payment_status || '/' || coalesce(effective_total_ghs, total_ghs) from public.orders where id = '${o}'`);
const due = (o) => Number(psql(`select public.order_topup_due_minor('${o}')`));
const refunds = (o) => psql(`select coalesce(string_agg(status || '/' || amount_minor || '/' || reason, ',' order by created_at, amount_minor), '-') from public.order_refunds where order_id = '${o}'`);
const reqId = () => randomUUID();

// ---- 1. A shortage on an order paid online is refunded.
let { orderId: o1, ref: ref1 } = await paidAcceptedOrder();
let r = await rpc(t.wo, "propose_partial_fulfilment", { p_order_id: o1, p_reason: "Supplier short", p_lines: [{ order_item_id: itemOf(o1), supplied_qty: 7, stock_treatment: "release" }], p_request_id: reqId() });
check("the wholesaler can propose a supply change on an order paid online", r.ok && r.body?.amendment_id, JSON.stringify(r.body));
const a1 = r.body?.amendment_id;
r = await rpc(t.po, "respond_to_amendment", { p_amendment_id: a1, p_choice: "accept_cancel_remaining", p_note: null });
check("the pharmacy accepts it: the order now costs 700 and stays paid", r.ok && state(o1) === "accepted/paid/700.00", r.error + state(o1));
check("the 300 difference is a refund waiting for approval; nothing is due from the pharmacy", refunds(o1) === "requested/30000/amendment_reduction" && due(o1) === 0, refunds(o1));
const rf1 = psql(`select id from public.order_refunds where order_id = '${o1}'`);
const refundCallsBefore = fake.refundCalls.length;
r = await post("/api/payments/admin-refund", t.admin, { refundId: rf1, action: "approve" });
check("an administrator approves it and it is sent to the provider for exactly 300", r.status === 200 && r.json.outcome === "processing" && fake.refundCalls.length === refundCallsBefore + 1
  && fake.refundCalls.at(-1).transaction === ref1 && fake.refundCalls.at(-1).amount === 30000, JSON.stringify(r) + JSON.stringify(fake.refundCalls.at(-1)));
await fake.finishRefund(ref1, "processed");
check("the provider confirms it: refunded, and the order is still PAID (it was only reduced, not cancelled)", refunds(o1).startsWith("succeeded/30000/") && state(o1) === "accepted/paid/700.00");
const summary = await rpc(t.po, "order_payment_summary", { p_order_id: o1 });
check("the pharmacy sees paid 1000, refunded 300, nothing due", summary.ok && summary.body.paid_ghs === 1000 && summary.body.refunded_ghs === 300 && summary.body.topup_due_ghs === 0, JSON.stringify(summary.body));

// ---- 2. Back-ordering the rest is refused for an order paid online.
let { orderId: o2 } = await paidAcceptedOrder();
r = await rpc(t.wo, "propose_partial_fulfilment", { p_order_id: o2, p_reason: "Supplier short", p_lines: [{ order_item_id: itemOf(o2), supplied_qty: 6, stock_treatment: "release" }], p_request_id: reqId() });
r = await rpc(t.po, "respond_to_amendment", { p_amendment_id: r.body?.amendment_id, p_choice: "accept_backorder", p_note: null });
check("accepting a shortage by back-ordering the rest is refused for an order paid online", !r.ok && /Back-ordering the rest is not available for an order paid online/.test(r.error ?? ""), r.error);
check("and nothing was changed", state(o2) === "accepted/paid/1000.00" && refunds(o2) === "-");

// ---- 3. A price increase must be paid (a top-up) before dispatch.
let { orderId: o3 } = await paidAcceptedOrder();
r = await rpc(t.wo, "propose_price_amendment", { p_order_id: o3, p_reason: "Supplier price revised", p_lines: [{ order_item_id: itemOf(o3), unit_price_ghs: 110 }], p_request_id: reqId() });
check("the wholesaler can propose a price increase on an order paid online", r.ok && r.body?.amendment_id, JSON.stringify(r.body));
r = await rpc(t.po, "respond_to_price_amendment", { p_amendment_id: r.body?.amendment_id, p_choice: "accept", p_note: null });
check("the pharmacy accepts: the order costs 1100, stays paid, and 100.00 more is due", r.ok && state(o3) === "accepted/paid/1100.00" && due(o3) === 10000, r.error + state(o3));
psql(`update public.orders set status = 'picking' where id = '${o3}'; update public.orders set status = 'packed' where id = '${o3}'; update public.orders set status = 'ready_for_dispatch' where id = '${o3}'`);
check("it can be prepared but NOT dispatched while the extra payment is due", /must be paid online before it can be dispatched/.test(psqlTry(`update public.orders set status = 'dispatched' where id = '${o3}'`)));
const summary3 = await rpc(t.po, "order_payment_summary", { p_order_id: o3 });
check("the pharmacy's summary shows 100.00 due", summary3.body?.topup_due_ghs === 100, JSON.stringify(summary3.body));

r = await post("/api/payments/initialize", null, { orderId: o3, purpose: "top_up" });
check("starting the extra payment needs a signed-in user", r.status === 401);
r = await post("/api/payments/initialize", t.wo, { orderId: o3, purpose: "top_up" });
check("the wholesaler cannot start it", r.status === 403, JSON.stringify(r));
r = await post("/api/payments/initialize", t.po, { orderId: o3 });
check("the ordinary 'pay for the order' start refuses a paid order", r.status === 400 && /already paid/.test(r.json?.error ?? ""), JSON.stringify(r));
r = await post("/api/payments/initialize", t.po, { orderId: o3, purpose: "top_up" });
const topRef = r.json?.reference;
check("the pharmacy starts the extra payment: the provider is asked for exactly 100.00, with a return page that knows it", r.status === 200 && fake.payments.get(topRef)?.amount === 10000
  && fake.payments.get(topRef)?.callbackUrl === `http://localhost:5173/pay/return?order=${o3}&purpose=top_up`, JSON.stringify(r) + JSON.stringify(fake.payments.get(topRef)));
check("it is recorded as a top-up", psql(`select purpose || '/' || status from public.order_payment_attempts where reference = '${topRef}'`) === "top_up/initiated");
r = await post("/api/payments/verify", t.po, { orderId: o3 });
check("coming back without paying: the extra payment is not reported as paid, and it is still due", r.json?.status !== "paid" && due(o3) === 10000, JSON.stringify(r));
fake.payments.get(topRef).status = "success";
await new Promise((resolve) => setTimeout(resolve, 3500));
r = await post("/api/payments/verify", t.po, { orderId: o3 });
check("after paying, verifying with the provider applies the extra payment", r.json?.status === "paid" && due(o3) === 0, JSON.stringify(r));
check("the order itself was already paid and still is; the original payment is untouched", psql(`select string_agg(purpose || '/' || status, ',' order by purpose) from public.order_payment_attempts where order_id = '${o3}' and status = 'succeeded'`) === "order/succeeded,top_up/succeeded");
check("and now it can be dispatched", psqlTry(`update public.orders set status = 'dispatched' where id = '${o3}'`) === "OK");
r = await post("/api/payments/initialize", t.po, { orderId: o3, purpose: "top_up" });
check("nothing more can be paid on it", r.status === 400 && /nothing more to pay/.test(r.json?.error ?? ""), JSON.stringify(r));

// ---- 4. The extra payment found by the provider's notification alone.
let { orderId: o4 } = await paidAcceptedOrder();
r = await rpc(t.wo, "propose_price_amendment", { p_order_id: o4, p_reason: "Supplier price revised", p_lines: [{ order_item_id: itemOf(o4), unit_price_ghs: 105 }], p_request_id: reqId() });
await rpc(t.po, "respond_to_price_amendment", { p_amendment_id: r.body?.amendment_id, p_choice: "accept", p_note: null });
check("a smaller increase: 50.00 is due", due(o4) === 5000, String(due(o4)));
const ref4 = (await post("/api/payments/initialize", t.po, { orderId: o4, purpose: "top_up" })).json.reference;
await fake.complete(ref4, "success"); // the provider's signed notification reaches the webhook
await new Promise((resolve) => setTimeout(resolve, 600));
check("the signed notification alone applies the extra payment", due(o4) === 0 && psql(`select status from public.order_payment_attempts where reference = '${ref4}'`) === "succeeded");

// ---- 5. An extra payment of the wrong amount is flagged and refunded; the amount is still due.
let { orderId: o5 } = await paidAcceptedOrder();
r = await rpc(t.wo, "propose_price_amendment", { p_order_id: o5, p_reason: "Supplier price revised", p_lines: [{ order_item_id: itemOf(o5), unit_price_ghs: 110 }], p_request_id: reqId() });
await rpc(t.po, "respond_to_price_amendment", { p_amendment_id: r.body?.amendment_id, p_choice: "accept", p_note: null });
const ref5 = (await post("/api/payments/initialize", t.po, { orderId: o5, purpose: "top_up" })).json.reference;
fake.payments.get(ref5).status = "success";
fake.payments.get(ref5).paidAmount = 9999;
r = await post("/api/payments/verify", t.po, { orderId: o5 });
check("an extra payment of the wrong amount is flagged, not applied; the amount is still due", r.json?.status === "flagged" && due(o5) === 10000
  && psql(`select status || '/' || flag_reason from public.order_payment_attempts where reference = '${ref5}'`) === "flagged/amount_mismatch", JSON.stringify(r));
check("its money is recorded for refund", Number(psql(`select count(*) from public.order_refunds r join public.order_payment_attempts a on a.id = r.attempt_id where a.reference = '${ref5}'`)) === 1);

psql(`update public.payments_settings set online_enabled = false`);
await fake.close();
await dev.close();
console.log(`${pass}/${total} adjustments API checks passed`);
