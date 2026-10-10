// Runs the real api/orders/create.ts and api/payments/{initialize,verify,webhook}.ts handlers, behind a real Node HTTP server, against the
// LOCAL Supabase stack with real GoTrue sessions and a stand-in for Paystack (no real keys). Walks the whole Pay Now flow:
// checkout, the checkout page, the return, the notification, and the failure cases.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-checkout-api.local.mjs
//
// Run right after payments-checkout.sql (it uses that suite's users, products and approvals, and switches the platform's online
// payments on and back off itself). Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { startFakePaystack } from "./fake-paystack.mjs";
import { startDevApiServer } from "./dev-api-server.mjs";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_checkout_check";

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

// ---- Environment: the stand-in for Paystack, and the real handlers pointed at it.
const dev = await startDevApiServer(0);
const fake = await startFakePaystack({ secret: SECRET, webhookUrl: `${dev.baseUrl}/api/payments/webhook` });
process.env.SITE_URL = "http://localhost:5173";
const configOn = () => {
  process.env.PAYMENTS_MODE = "test";
  process.env.PAYSTACK_SECRET_KEY = SECRET;
  process.env.PAYSTACK_BASE_URL = fake.baseUrl;
};
const configOff = () => {
  delete process.env.PAYMENTS_MODE;
  delete process.env.PAYSTACK_SECRET_KEY;
  delete process.env.PAYSTACK_BASE_URL;
};
const setSwitch = (on, mode = "test") => psql(`update public.payments_settings set online_enabled = ${on}, mode = '${mode}'`);
const post = async (path, bearer, body) => {
  const headers = { "content-type": "application/json" };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const r = await realFetch(`${dev.baseUrl}${path}`, { method: "POST", headers, body: JSON.stringify(body) });
  return { status: r.status, json: await r.json().catch(() => null) };
};

const t = { po: await token("po@zz.test"), px: await token("px@zz.test"), wo: await token("wo@zz.test") };
const ids = JSON.parse(
  psql(`select json_build_object('good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'pc', (select id from public.products where name='BO C'))`),
);
const checkout = (bearer, method) =>
  post("/api/orders/create", bearer, {
    pharmacyId: ids.good,
    requestId: randomUUID(),
    items: [{ productId: ids.pc, quantity: 1, category: "cash_private" }],
    settlementMethods: { [ids.alpha]: method },
  });
const state = (orderId) => psql(`select payment_status || '/' || status from public.orders where id = '${orderId}'`);
const attemptRows = (orderId) => psql(`select string_agg(status || ':' || reference, ',' order by initiated_at) from public.order_payment_attempts where order_id = '${orderId}'`);
const refOf = (orderId, status) => psql(`select reference from public.order_payment_attempts where order_id = '${orderId}' ${status ? `and status = '${status}'` : ""} order by initiated_at desc limit 1`);
const minorFor = 2000;

// ---- 1. Checkout.
setSwitch(false);
configOff();
let r = await checkout(t.po, "pay_now");
check("server not set up for online payment: Pay now is refused at the endpoint", r.status === 400 && /not available yet/.test(r.json?.error ?? ""), JSON.stringify(r));
configOn();
r = await checkout(t.po, "pay_now");
check("server set up but the platform switch is off: refused by the database with the same message", r.status === 400 && /not available yet/.test(r.json?.error ?? ""), JSON.stringify(r));
setSwitch(true);
r = await checkout(t.po, "cod");
check("an ordinary cash checkout is unchanged: no payment step is reported", r.status === 200 && r.json?.orderCount === 1 && !("awaitingPayment" in (r.json ?? {})), JSON.stringify(r));

const orders = [];
for (let i = 0; i < 6; i++) {
  r = await checkout(t.po, "pay_now");
  const w = r.json?.awaitingPayment?.[0];
  check(`Pay now checkout ${i + 1}: one order awaiting payment, for the right amount`, r.status === 200 && r.json.awaitingPayment.length === 1 && w.amountGhs === 20 && w.wholesalerId === ids.alpha, JSON.stringify(r));
  orders.push(w.orderId);
}
const [o1, o2, o3, o4, o5, o6] = orders;
check("the orders are stored unpaid, online, pending", psql(`select count(*) from public.orders where id in ('${orders.join("','")}') and payment_method = 'paystack' and payment_status = 'unpaid' and status = 'pending'`) === "6");

// ---- 2. Starting a payment.
r = await post("/api/payments/initialize", null, { orderId: o1 });
check("starting a payment needs a signed-in user", r.status === 401, JSON.stringify(r));
r = await post("/api/payments/initialize", t.px, { orderId: o1 });
check("another pharmacy cannot pay for the order", r.status === 403, JSON.stringify(r));
r = await post("/api/payments/initialize", t.wo, { orderId: o1 });
check("the wholesaler cannot pay for the order", r.status === 403, JSON.stringify(r));
r = await post("/api/payments/initialize", t.po, { orderId: "not-an-id" });
check("a malformed order id is refused", r.status === 400, JSON.stringify(r));

r = await post("/api/payments/initialize", t.po, { orderId: o1, amount: 1, amountMinor: 1 });
const ref1 = r.json?.reference;
check("the owner gets the provider's checkout address", r.status === 200 && /^http:\/\/127\.0\.0\.1:\d+\/checkout\/dx-test-/.test(r.json?.authorizationUrl ?? "") && r.json.resumed === false, JSON.stringify(r));
const p1 = fake.payments.get(ref1);
check("the provider was asked for the order's own amount (not the browser's), the payer's email and our return address",
  p1?.amount === minorFor && p1.email === "po@zz.test" && p1.callbackUrl === `http://localhost:5173/pay/return?order=${o1}`, JSON.stringify(p1));
check("the attempt is recorded as started and the checkout address is stored", psql(`select status || '/' || (authorization_url is not null) from public.order_payment_attempts where reference = '${ref1}'`) === "initiated/true");
r = await post("/api/payments/initialize", t.po, { orderId: o1 });
check("starting again resumes the same page (no second payment is created at the provider)", r.status === 200 && r.json.resumed === true && r.json.reference === ref1 && fake.payments.size === 1, JSON.stringify(r));

// ---- 3. Coming back without paying proves nothing.
r = await post("/api/payments/verify", t.po, { orderId: o1 });
check("returning without paying: the provider says nothing was paid, the order stays unpaid", r.status === 200 && r.json.status === "not_paid" && state(o1) === "unpaid/pending", JSON.stringify(r));
r = await post("/api/payments/verify", t.px, { orderId: o1 });
check("another pharmacy cannot ask about the order", r.status === 404, JSON.stringify(r));
r = await post("/api/payments/verify", t.wo, { orderId: o1 });
check("the wholesaler cannot trigger a verification", r.status === 404, JSON.stringify(r));

// ---- 4. Paying, with no notification: the return page's verification is enough.
await fake.complete(ref1, "success"); // the stand-in also sends the notification here; the duplicate path is checked below
await new Promise((resolve) => setTimeout(resolve, 400));
check("the signed notification Paystack sent paid the order (webhook path)", state(o1) === "paid/pending" && psql(`select status from public.order_payment_attempts where reference = '${ref1}'`) === "succeeded");
r = await post("/api/payments/verify", t.po, { orderId: o1 });
check("the return page then sees it paid", r.status === 200 && r.json.status === "paid", JSON.stringify(r));
const callsBefore = fake.calls.length;
await post("/api/payments/verify", t.po, { orderId: o1 });
check("asking again for a paid order does not bother the provider", fake.calls.length === callsBefore);
check("the wholesaler's staff were each told of a new paid order, once", psql(`select (count(*) > 0 and count(*) = count(distinct user_id))::text from public.notifications where title = 'New paid order' and metadata->>'order_id' = '${o1}'`) === "true");
r = await post("/api/payments/initialize", t.po, { orderId: o1 });
check("a paid order cannot be paid again", r.status === 400 && /already paid/.test(r.json?.error ?? ""), JSON.stringify(r));

// ---- 5. Paying, with the notification lost: the return page's verification alone pays the order.
r = await post("/api/payments/initialize", t.po, { orderId: o2 });
const ref2 = r.json.reference;
fake.payments.get(ref2).status = "success"; // Paystack took the money; the notification never arrives
r = await post("/api/payments/verify", t.po, { orderId: o2 });
check("with no notification at all, verifying with the provider marks the order paid", r.status === 200 && r.json.status === "paid" && state(o2) === "paid/pending", JSON.stringify(r));
const late = await fake.notify(ref2);
const lateJson = await late.json();
check("the notification that arrives afterwards is a harmless duplicate", late.status === 200 && state(o2) === "paid/pending" && (lateJson.outcome === "duplicate" || lateJson.duplicate === true), JSON.stringify(lateJson));
check("one payment, one success", psql(`select count(*) from public.order_payment_attempts where order_id = '${o2}' and status = 'succeeded'`) === "1");

// ---- 6. A forged notification changes nothing.
const forged = JSON.stringify({ event: "charge.success", data: { id: 1, reference: "dx-test-forged", domain: "test", status: "success" } });
const fr = await realFetch(`${dev.baseUrl}/api/payments/webhook`, { method: "POST", headers: { "content-type": "application/json", "x-paystack-signature": "00" }, body: forged });
check("a notification with a wrong signature is refused", fr.status === 401);

// ---- 7. The wrong amount is flagged, never paid.
r = await post("/api/payments/initialize", t.po, { orderId: o3 });
const ref3 = r.json.reference;
fake.payments.get(ref3).status = "success";
fake.payments.get(ref3).paidAmount = minorFor - 1;
r = await post("/api/payments/verify", t.po, { orderId: o3 });
check("a payment of the wrong amount is flagged, not applied", r.status === 200 && r.json.status === "flagged" && state(o3) === "unpaid/pending" && psql(`select status || '/' || flag_reason from public.order_payment_attempts where reference = '${ref3}'`) === "flagged/amount_mismatch", JSON.stringify(r));

// ---- 8. Declined, then tried again.
r = await post("/api/payments/initialize", t.po, { orderId: o4 });
const ref4 = r.json.reference;
fake.payments.get(ref4).status = "failed";
fake.payments.get(ref4).gatewayResponse = "Declined";
r = await post("/api/payments/verify", t.po, { orderId: o4 });
check("a declined card is reported as failed and the order stays unpaid", r.status === 200 && r.json.status === "failed" && state(o4) === "unpaid/pending" && psql(`select status from public.order_payment_attempts where reference = '${ref4}'`) === "failed", JSON.stringify(r));
r = await post("/api/payments/initialize", t.po, { orderId: o4 });
check("the customer can try again with a new payment page", r.status === 200 && r.json.resumed === false && r.json.reference !== ref4 && fake.payments.size >= 4, JSON.stringify(r));
const ref4b = r.json.reference;
fake.payments.get(ref4b).status = "success";
r = await post("/api/payments/verify", t.po, { orderId: o4 });
check("the second try pays the order", r.json?.status === "paid" && state(o4) === "paid/pending", JSON.stringify(r));

// ---- 9. Paid after the order was cancelled: the money is recorded for refund, the order stays cancelled.
r = await post("/api/payments/initialize", t.po, { orderId: o5 });
const ref5 = r.json.reference;
psql(`update public.orders set status = 'cancelled' where id = '${o5}'`);
r = await post("/api/payments/initialize", t.po, { orderId: o5 });
check("a cancelled order can no longer be paid", r.status === 400 && /cancelled/.test(r.json?.error ?? ""), JSON.stringify(r));
fake.payments.get(ref5).status = "success";
r = await post("/api/payments/verify", t.po, { orderId: o5 });
check("a payment that arrives after cancellation is flagged for refund and does not revive the order",
  r.status === 200 && r.json.status === "flagged" && state(o5) === "unpaid/cancelled"
  && psql(`select status || '/' || refund_required from public.order_payment_attempts where reference = '${ref5}'`) === "succeeded/true", JSON.stringify(r));

// ---- 10. The mode must match.
// The database refuses to switch live on without its go-live checks (P5); this scenario needs the platform to SAY live anyway, so the guard is lifted for it alone.
psql(`alter table public.payments_settings disable trigger trg_payments_settings_live_guard`);
setSwitch(true, "live");
r = await post("/api/payments/initialize", t.po, { orderId: o6 });
check("the platform switch says live while the server is in test mode: nothing starts", r.status === 400 && /not set up for this mode/.test(r.json?.error ?? "") && attemptRows(o6) === "", JSON.stringify(r));
setSwitch(true, "test");
psql(`alter table public.payments_settings enable trigger trg_payments_settings_live_guard`);
configOff();
r = await post("/api/payments/initialize", t.po, { orderId: o6 });
check("server environment off: nothing starts", r.status === 503 && attemptRows(o6) === "", JSON.stringify(r));
setSwitch(false);
configOn();
r = await post("/api/payments/initialize", t.po, { orderId: o6 });
check("platform switch off: nothing starts", r.status === 400 && /not available yet/.test(r.json?.error ?? "") && attemptRows(o6) === "", JSON.stringify(r));

// ---- 11. The provider is unreachable.
setSwitch(true);
process.env.PAYSTACK_BASE_URL = "http://127.0.0.1:1";
r = await post("/api/payments/initialize", t.po, { orderId: o6 });
check("provider unreachable: a friendly error, the attempt is marked failed", r.status === 502 && !/ECONN|fetch/i.test(JSON.stringify(r.json)) && /^failed:/.test(attemptRows(o6) ?? ""), JSON.stringify(r) + attemptRows(o6));
configOn();
r = await post("/api/payments/initialize", t.po, { orderId: o6 });
check("and a retry works once the provider is back", r.status === 200 && r.json.resumed === false, JSON.stringify(r));

setSwitch(false);
await fake.close();
await dev.close();
console.log(`${pass}/${total} checkout API checks passed`);
