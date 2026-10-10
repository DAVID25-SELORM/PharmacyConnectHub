// Runs the real /api/payments/reconcile and /api/payments/admin-reverify handlers (and the return page's verify) behind a real Node HTTP server against
// the LOCAL Supabase stack with real sessions and a stand-in for Paystack, with the failures injected that the reconciler exists for: a notification
// that never arrives, a customer who walks away, a provider that is down, a payment that comes after the order expired, a payment the provider has but we
// do not.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-operations-api.local.mjs
//
// Run right after payments-checkout.sql (it uses that suite's users, products and approvals; run pw.sql after it). It switches the platform's online
// payments on and back off itself. Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { startFakePaystack } from "./fake-paystack.mjs";
import { startDevApiServer } from "./dev-api-server.mjs";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_operations_check";
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
const fake = await startFakePaystack({ secret: SECRET }); // no webhook: every notification is "lost"
process.env.SITE_URL = "http://localhost:5173";
process.env.CRON_SECRET = CRON;
process.env.PAYMENTS_MODE = "test";
process.env.PAYSTACK_SECRET_KEY = SECRET;
process.env.PAYSTACK_BASE_URL = fake.baseUrl;
psql(`update public.payments_settings set online_enabled = true, mode = 'test'`);

const post = async (path, bearer, body, method = "POST") => {
  const headers = { "content-type": "application/json" };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const r = await realFetch(`${dev.baseUrl}${path}`, { method, headers, body: method === "GET" ? undefined : JSON.stringify(body ?? {}) });
  return { status: r.status, json: await r.json().catch(() => null) };
};
const job = (which, bearer = CRON) => post(`/api/payments/reconcile?job=${which}`, bearer, {});

const t = { po: await token("po@zz.test"), admin: await token("admin@zz.test") };
const ids = JSON.parse(
  psql(`select json_build_object('good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'pc', (select id from public.products where name='BO C'))`),
);
async function newOrder() {
  const r = await post("/api/orders/create", t.po, {
    pharmacyId: ids.good,
    requestId: randomUUID(),
    items: [{ productId: ids.pc, quantity: 1, category: "cash_private" }],
    settlementMethods: { [ids.alpha]: "pay_now" },
  });
  assert.equal(r.status, 200, JSON.stringify(r));
  return r.json.awaitingPayment[0].orderId;
}
async function start(orderId) {
  const r = await post("/api/payments/initialize", t.po, { orderId });
  assert.equal(r.status, 200, JSON.stringify(r));
  return r.json.reference;
}
const state = (o) => psql(`select status || '/' || payment_status from public.orders where id = '${o}'`);
const attempt = (ref) => psql(`select status || '/' || refund_required || '/' || check_count from public.order_payment_attempts where reference = '${ref}'`);
const alerts = (kind, o) => Number(psql(`select count(*) from public.payment_alerts where kind = '${kind}' and status = 'open' ${o ? `and order_id = '${o}'` : ""}`));
const ageOrder = (o, minutes) =>
  psql(`alter table public.orders disable trigger aa_phase0_order_integrity; update public.orders set created_at = now() - interval '${minutes} minutes' where id = '${o}'; alter table public.orders enable trigger aa_phase0_order_integrity`);
const ageAttempt = (ref, minutes, checked = "null") =>
  psql(`alter table public.order_payment_attempts disable trigger trg_order_payment_attempts_protect; update public.order_payment_attempts set initiated_at = now() - interval '${minutes} minutes', last_checked_at = ${checked}, check_requested_at = null where reference = '${ref}'; alter table public.order_payment_attempts enable trigger trg_order_payment_attempts_protect`);
const stock = () => Number(psql(`select stock from public.products where id = '${ids.pc}'`));
const verifyCalls = () => fake.calls.filter((c) => c.startsWith("GET /transaction/verify")).length;

// ---- 1. Who may call the job.
let r = await job("frequent", "wrong");
check("a wrong secret is refused (401)", r.status === 401, JSON.stringify(r));
r = await post("/api/payments/reconcile?job=frequent", null, {}, "POST");
check("no secret is refused (401)", r.status === 401, JSON.stringify(r));
r = await post("/api/payments/reconcile?job=frequent", t.po, {});
check("a signed-in user's session is not a secret (401)", r.status === 401, JSON.stringify(r));
await job("frequent"); // warm-up: the SQL suite that ran before leaves old attempts, which the reconciler checks (the stand-in has never heard of them) once
r = await job("frequent");
check("with the secret and nothing to do it answers 200 and reports nothing",r.status === 200 && r.json.checked === 0 && r.json.expiry?.expired === 0, JSON.stringify(r));
delete process.env.CRON_SECRET;
r = await job("frequent", CRON);
check("with no secret configured the job is unavailable (503)", r.status === 503, JSON.stringify(r));
process.env.CRON_SECRET = CRON;

// ---- 2. The notification never arrives: the reconciler finds the payment.
let o = await newOrder();
let ref = await start(o);
fake.payments.get(ref).status = "success"; // paid at the provider; no webhook, and the customer never came back
r = await job("frequent");
check("too young to check: a payment made a moment ago is left to the webhook and the return page", r.json.checked === 0 && state(o) === "pending/unpaid", JSON.stringify(r.json));
ageAttempt(ref, 10);
r = await job("frequent");
check("a payment whose notification never arrived is found and applied by the reconciler", r.status === 200 && r.json.applied === 1 && state(o) === "pending/paid", JSON.stringify(r));
check("the attempt is marked checked", attempt(ref) === "succeeded/false/1", attempt(ref));
r = await job("frequent");
check("running it again finds nothing more to do", r.json.checked === 0 && r.json.applied === 0, JSON.stringify(r.json));

// ---- 3. The customer walks away: the order expires and its stock comes back.
o = await newOrder();
ref = await start(o);
const stockBefore = stock();
ageOrder(o, 45);
ageAttempt(ref, 40);
r = await job("frequent");
check("an abandoned order is cancelled once its payment window is over (the provider was asked first)", r.json.checked === 1 && r.json.expiry?.expired === 1 && state(o) === "cancelled/unpaid", JSON.stringify(r));
check("its stock came back and the pharmacy was told", stock() === stockBefore + 1
  && psql(`select count(*) from public.notifications where title = 'Order cancelled: payment not completed' and metadata->>'order_id' = '${o}'`) !== "0");

// ---- 4. The provider is down: nothing is cancelled on a guess.
o = await newOrder();
ref = await start(o);
ageOrder(o, 45);
ageAttempt(ref, 40);
const realBase = process.env.PAYSTACK_BASE_URL;
process.env.PAYSTACK_BASE_URL = "http://127.0.0.1:1";
r = await job("frequent");
check("with the provider down the order is NOT cancelled, the failure is reported", r.status === 200 && r.json.providerErrors === 1 && r.json.expiry?.expired === 0 && r.json.expiry?.blocked === 1 && state(o) === "pending/unpaid", JSON.stringify(r));
check("an alert says the provider could not be reached, and one says why the order was kept", alerts("provider_unreachable") === 1 && alerts("expiry_blocked", o) === 1);
process.env.PAYSTACK_BASE_URL = realBase;
r = await job("frequent");
check("once the provider is back, the same order is checked and then cancelled", r.json.checked === 1 && state(o) === "cancelled/unpaid", JSON.stringify(r));

// ---- 5. A payment arrives after the order was cancelled: found, recorded, to be refunded.
fake.payments.get(ref).status = "success";
ageAttempt(ref, 90, "now() - interval '2 hours'");
psql(`alter table public.order_payment_attempts disable trigger trg_order_payment_attempts_protect; update public.order_payment_attempts set status = 'expired' where reference = '${ref}'; alter table public.order_payment_attempts enable trigger trg_order_payment_attempts_protect`);
r = await job("frequent");
check("a payment for an order that was already cancelled is found by the reconciler", r.json.checked >= 1 && state(o) === "cancelled/unpaid", JSON.stringify(r));
check("it is recorded, marked for refund, and the order is not revived", attempt(ref).startsWith("succeeded/true/"), attempt(ref));
check("an alert raises the refund and the pharmacy is told not to pay again", alerts("refund_required", o) === 1
  && psql(`select count(*) from public.notifications where title = 'A payment needs attention' and metadata->>'order_id' = '${o}'`) !== "0");

// ---- 6. The daily comparison.
o = await newOrder();
ref = await start(o);
fake.payments.get(ref).status = "success";
fake.payments.set("dx-test-ghost-0001", { id: 9001, amount: 5000, currency: "GHS", email: "x@y.test", callbackUrl: "http://x/", metadata: null, status: "success", gatewayResponse: null });
r = await job("daily");
check("the daily comparison lists the provider's transactions and finds the payment that was never applied", r.status === 200 && r.json.complete === true && r.json.applied === 1 && state(o) === "pending/paid", JSON.stringify(r));
check("a successful payment at the provider that we have no record of is a critical alert", alerts("unknown_at_provider") === 1
  && psql(`select severity from public.payment_alerts where kind = 'unknown_at_provider' and status = 'open'`) === "critical");
r = await job("daily");
check("running the comparison again does not duplicate the alert", alerts("unknown_at_provider") === 1 && r.json.applied === 0, JSON.stringify(r));
check("the platform admins were told", Number(psql(`select count(*) from public.notifications where title = 'Payment problem: action needed'`)) >= 2);

// ---- 7. The admin's re-verify.
o = await newOrder();
ref = await start(o);
fake.payments.get(ref).status = "success";
r = await post("/api/payments/admin-reverify", t.po, { orderId: o });
check("a pharmacy owner cannot use re-verify (403)", r.status === 403, JSON.stringify(r));
r = await post("/api/payments/admin-reverify", null, { orderId: o });
check("re-verify needs a session (401)", r.status === 401, JSON.stringify(r));
r = await post("/api/payments/admin-reverify", t.admin, { orderId: "nope" });
check("re-verify needs a real order (400)", r.status === 400, JSON.stringify(r));
r = await post("/api/payments/admin-reverify", t.admin, { orderId: o });
check("an administrator's re-verify asks the provider and records the answer", r.status === 200 && r.json.orderPaid === true && state(o) === "pending/paid", JSON.stringify(r));

// ---- 8. The return page cannot hammer the provider.
o = await newOrder();
ref = await start(o);
const c0 = verifyCalls();
r = await post("/api/payments/verify", t.po, { orderId: o });
const c1 = verifyCalls();
const first = r.json?.status;
r = await post("/api/payments/verify", t.po, { orderId: o });
const c2 = verifyCalls();
check("the second check within a few seconds is answered without asking the provider again", c1 === c0 + 1 && c2 === c1 && r.json?.status === "pending" && first !== undefined, `${c0} ${c1} ${c2} ${JSON.stringify(r)}`);
fake.payments.get(ref).status = "success";
await new Promise((resolve) => setTimeout(resolve, 3500));
r = await post("/api/payments/verify", t.po, { orderId: o });
check("a few seconds later it asks again and the payment is found", r.json?.status === "paid" && state(o) === "pending/paid", JSON.stringify(r));

psql(`update public.payments_settings set online_enabled = false`);
await fake.close();
await dev.close();
console.log(`${pass}/${total} operations API checks passed`);
