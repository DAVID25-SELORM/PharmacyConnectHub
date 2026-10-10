// Runs the real api/payments/admin-refund.ts, webhook.ts and reconcile.ts handlers behind a real Node HTTP server against the LOCAL Supabase stack with real
// sessions and a stand-in for Paystack (which takes refunds, refuses them, or takes them and loses the answer, and sends signed refund notifications).
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-refunds-api.local.mjs
//
// Run right after payments-checkout.sql (it uses that suite's users, products and approvals; run pw.sql after it). It switches the platform's online payments
// on and back off itself. Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { startFakePaystack } from "./fake-paystack.mjs";
import { startDevApiServer } from "./dev-api-server.mjs";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_refunds_check";
const CRON = "local-cron-secret";

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
process.env.CRON_SECRET = CRON;
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
const t = { po: await token("po@zz.test"), admin: await token("admin@zz.test") };
const ids = JSON.parse(
  psql(`select json_build_object('good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'pc', (select id from public.products where name='BO C'))`),
);
async function paidOrder() {
  const r = await post("/api/orders/create", t.po, {
    pharmacyId: ids.good,
    requestId: randomUUID(),
    items: [{ productId: ids.pc, quantity: 1, category: "cash_private" }],
    settlementMethods: { [ids.alpha]: "pay_now" },
  });
  assert.equal(r.status, 200, JSON.stringify(r));
  const orderId = r.json.awaitingPayment[0].orderId;
  const init = await post("/api/payments/initialize", t.po, { orderId });
  assert.equal(init.status, 200, JSON.stringify(init));
  const ref = init.json.reference;
  fake.payments.get(ref).status = "success";
  const v = await post("/api/payments/verify", t.po, { orderId });
  assert.equal(v.json?.status, "paid", JSON.stringify(v));
  return { orderId, ref };
}
const state = (o) => psql(`select status || '/' || payment_status from public.orders where id = '${o}'`);
const refundOf = (ref) => psql(`select r.id from public.order_refunds r join public.order_payment_attempts a on a.id = r.attempt_id where a.reference = '${ref}' order by r.created_at limit 1`);
const rstate = (ref) => psql(`select r.status || '/' || r.amount_minor || '/' || coalesce(r.provider_refund_id, '-') from public.order_refunds r join public.order_payment_attempts a on a.id = r.attempt_id where a.reference = '${ref}' order by r.created_at limit 1`);
const alerts = (kind, o) => Number(psql(`select count(*) from public.payment_alerts where kind = '${kind}' and status = 'open' ${o ? `and order_id = '${o}'` : ""}`));
const act = (refundId, action, note, bearer = t.admin) => post("/api/payments/admin-refund", bearer, { refundId, action, note });
const ageAttempt = (ref, minutes) =>
  psql(`alter table public.order_payment_attempts disable trigger trg_order_payment_attempts_protect; update public.order_payment_attempts set initiated_at = now() - interval '${minutes} minutes', last_checked_at = null where reference = '${ref}'; alter table public.order_payment_attempts enable trigger trg_order_payment_attempts_protect`);

// ---- 1. A paid order is cancelled: approve, send, confirm.
let { orderId: o1, ref: ref1 } = await paidOrder();
psql(`update public.orders set status = 'cancelled' where id = '${o1}'`);
check("a paid order that is cancelled asks for its full refund, waiting for approval", rstate(ref1) === "requested/2000/-" && alerts("refund_required", o1) === 1, rstate(ref1));
const rf1 = refundOf(ref1);
let r = await act(rf1, "approve", null, t.po);
check("a pharmacy owner cannot approve a refund (403)", r.status === 403, JSON.stringify(r));
r = await act(rf1, "approve", null, null);
check("approving needs a session (401)", r.status === 401, JSON.stringify(r));
r = await act(rf1, "launch");
check("an unknown action is refused (400)", r.status === 400, JSON.stringify(r));
check("nothing was sent to the provider by those", fake.refundCalls.length === 0);
r = await act(rf1, "approve");
check("an administrator approves it and it is sent at once", r.status === 200 && r.json.sent === true && r.json.outcome === "processing", JSON.stringify(r));
check("the provider was asked to refund the payment's own reference for exactly the amount", fake.refundCalls.length === 1 && fake.refundCalls[0].transaction === ref1 && fake.refundCalls[0].amount === 2000, JSON.stringify(fake.refundCalls));
check("the refund is processing, with the provider's id", /^processing\/2000\/\d+$/.test(rstate(ref1)), rstate(ref1));
check("the order is not marked refunded until the provider says so", state(o1) === "cancelled/paid");
r = await act(rf1, "approve");
check("approving again does not send a second refund", fake.refundCalls.length === 1, JSON.stringify(r));
let hook = await fake.finishRefund(ref1, "processed");
check("the provider's signed notification completes the refund", hook.status === 200 && rstate(ref1).startsWith("succeeded/") && state(o1) === "cancelled/refunded", rstate(ref1));
check("the refund alert closed itself and the pharmacy was told", alerts("refund_required", o1) === 0
  && Number(psql(`select count(*) from public.notifications where title = 'Refund sent' and metadata->>'order_id' = '${o1}'`)) > 0);
hook = await fake.finishRefund(ref1, "processed");
check("the same notification delivered again is acknowledged and changes nothing", hook.status === 200 && (await hook.json()).duplicate === true && rstate(ref1).startsWith("succeeded/"));

// ---- 2. A late payment, with automatic refunds on, is refunded by the reconciler.
psql(`update public.payments_settings set auto_refunds = true`);
let o2 = await (async () => {
  const rr = await post("/api/orders/create", t.po, { pharmacyId: ids.good, requestId: randomUUID(), items: [{ productId: ids.pc, quantity: 1, category: "cash_private" }], settlementMethods: { [ids.alpha]: "pay_now" } });
  return rr.json.awaitingPayment[0].orderId;
})();
const ref2 = (await post("/api/payments/initialize", t.po, { orderId: o2 })).json.reference;
psql(`update public.orders set status = 'cancelled' where id = '${o2}'`); // the order was cancelled while the customer was still on the provider's page
fake.payments.get(ref2).status = "success";
ageAttempt(ref2, 10);
r = await post("/api/payments/reconcile?job=frequent", CRON, {});
check("the reconciler finds the late payment, requests its refund, approves it by the setting, and sends it in the same run", r.status === 200 && r.json.refunds?.sent === 1, JSON.stringify(r));
check("the provider was asked to refund it", fake.refundCalls.at(-1)?.transaction === ref2 && rstate(ref2).startsWith("processing/2000/"), rstate(ref2));
check("the order itself stays cancelled and unpaid", state(o2) === "cancelled/unpaid");
await fake.finishRefund(ref2, "processed");
check("and the provider's notification completes it", rstate(ref2).startsWith("succeeded/") && state(o2) === "cancelled/unpaid", rstate(ref2));
psql(`update public.payments_settings set auto_refunds = false`);

// ---- 3. The provider refuses a refund; a person retries it.
let { orderId: o3, ref: ref3 } = await paidOrder();
psql(`update public.orders set status = 'cancelled' where id = '${o3}'`);
const rf3 = refundOf(ref3);
fake.refundBehavior = "reject";
r = await act(rf3, "approve");
check("a refusal from the provider fails the refund, with its reason, and raises an alert", r.json?.outcome === "failed" && rstate(ref3).startsWith("failed/")
  && psql(`select failure_reason from public.order_refunds where id = '${rf3}'`) === "Transaction is not eligible for refund" && alerts("refund_failed", o3) === 1, JSON.stringify(r));
const callsBefore = fake.refundCalls.length;
await post("/api/payments/reconcile?job=frequent", CRON, {});
check("a failed refund is not sent again by the reconciler", fake.refundCalls.length === callsBefore);
fake.refundBehavior = "accept";
r = await act(rf3, "retry");
check("an administrator's retry sends it again and it is accepted", r.json?.outcome === "processing" && rstate(ref3).startsWith("processing/") && alerts("refund_failed", o3) === 0, JSON.stringify(r));
await fake.finishRefund(ref3, "failed");
check("a later 'failed' notification fails it again, with an alert", rstate(ref3).startsWith("failed/") && alerts("refund_failed", o3) === 1);
r = await act(rf3, "cancel", "Refunded by bank transfer");
check("it can be cancelled by an administrator", r.json?.status === "cancelled" && alerts("refund_failed", o3) === 0, JSON.stringify(r));

// ---- 4. The answer is lost: never sent twice.
let { orderId: o4, ref: ref4 } = await paidOrder();
psql(`update public.orders set status = 'cancelled' where id = '${o4}'`);
const rf4 = refundOf(ref4);
fake.refundBehavior = "drop";
const before4 = fake.refundCalls.length;
r = await act(rf4, "approve");
check("when the provider's answer is lost, the outcome is 'unknown' and a critical alert says to check the dashboard first", r.json?.outcome === "unknown" && rstate(ref4).startsWith("unknown/") && alerts("refund_stuck", o4) === 1, JSON.stringify(r));
check("the provider did receive exactly one request", fake.refundCalls.length === before4 + 1);
fake.refundBehavior = "accept";
await post("/api/payments/reconcile?job=frequent", CRON, {});
await post("/api/payments/reconcile?job=frequent", CRON, {});
r = await act(rf4, "retry");
check("neither the reconciler nor a retry sends it again: it is waiting for a person", fake.refundCalls.length === before4 + 1 && r.status === 400, `${fake.refundCalls.length - before4} ${JSON.stringify(r)}`);
await fake.finishRefund(ref4, "processed");
check("if the provider's notification arrives, the refund completes and its alerts close", rstate(ref4).startsWith("succeeded/") && alerts("refund_stuck", o4) === 0 && state(o4) === "cancelled/refunded", rstate(ref4));

// ---- 5. By hand, and what the provider does that we did not ask for.
let { orderId: o5, ref: ref5 } = await paidOrder();
psql(`update public.orders set status = 'cancelled' where id = '${o5}'`);
const rf5 = refundOf(ref5);
r = await act(rf5, "confirm_refunded");
check("confirming as refunded by hand needs a note", r.status === 400, JSON.stringify(r));
r = await act(rf5, "confirm_refunded", "Refunded from the Paystack dashboard, reference RF-55");
check("an administrator confirms a refund made by hand: succeeded, and the order is refunded", r.json?.status === "succeeded" && state(o5) === "cancelled/refunded" && fake.refundCalls.length === before4 + 1, JSON.stringify(r) + state(o5));
let { orderId: o6, ref: ref6 } = await paidOrder();
fake.refunds.set(999, { id: 999, transaction: ref6, amount: 2000, status: "pending" });
hook = await fake.finishRefund(ref6, "processed");
check("a refund the provider reports that this system did not send raises an alert and changes nothing", hook.status === 200 && alerts("refund_unmatched", o6) === 1 && state(o6) === "pending/paid");
const forged = JSON.stringify({ event: "refund.processed", data: { id: 1, transaction_reference: ref6, amount: 2000, domain: "test" } });
const fr = await realFetch(`${dev.baseUrl}/api/payments/webhook`, { method: "POST", headers: { "content-type": "application/json", "x-paystack-signature": createHmac("sha512", "sk_test_wrong").update(forged).digest("hex") }, body: forged });
check("a refund notification with a wrong signature is refused", fr.status === 401);

psql(`update public.payments_settings set online_enabled = false`);
await fake.close();
await dev.close();
console.log(`${pass}/${total} refunds API checks passed`);
