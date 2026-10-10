// Runs the real api/payments/webhook.ts handler against the LOCAL Supabase stack, behind a real Node HTTP server (so the raw request
// body is read from a real stream, as on the platform), with real signatures and a stand-in for Paystack's verify call.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-webhook-api.local.mjs
//
// Needs the database as left by `setup.sql` + the migrations through 20261106110000 + the production fixtures (it creates its own
// orders and attempts). Refuses to run against anything but the local stack.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { execFileSync } from "node:child_process";
import http from "node:http";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
const SERVICE = process.env.SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
const SECRET = "sk_test_local_webhook_check";
process.env.SUPABASE_URL = API;
process.env.SUPABASE_PUBLISHABLE_KEY = ANON;
process.env.SUPABASE_SERVICE_ROLE_KEY = SERVICE;
process.env.PAYMENTS_MODE = "test";
process.env.PAYSTACK_SECRET_KEY = SECRET;

const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-c", sql]).toString().trim();

// ---- Stand-in for Paystack: what "verify" answers, per reference.
const verifyAnswers = new Map();
const verifyCalls = [];
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
  const m = /^https:\/\/api\.paystack\.co\/transaction\/verify\/(.+)$/.exec(String(url));
  if (m) {
    const reference = decodeURIComponent(m[1]);
    verifyCalls.push(reference);
    const data = verifyAnswers.get(reference);
    if (!data) return new Response(JSON.stringify({ status: false, message: "Transaction reference not found" }), { status: 404 });
    return new Response(JSON.stringify({ status: true, data }), { status: 200, headers: { "content-type": "application/json" } });
  }
  return realFetch(url, init);
};

const handler = (await import("../../api/payments/webhook.ts")).default;
const server = http.createServer((req, res) => {
  // The shim Vercel adds: res.status(code).json(body). req is the real, unparsed stream.
  const shim = {
    status(code) { res.statusCode = code; return shim; },
    json(body) { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(body)); return shim; },
  };
  handler(req, shim).catch((error) => { res.statusCode = 500; res.end(String(error)); });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

const post = async (body, signature, method = "POST") => {
  const headers = { "content-type": "application/json" };
  if (signature !== null) headers["x-paystack-signature"] = signature ?? createHmac("sha512", SECRET).update(body).digest("hex");
  const r = await realFetch(base, { method, headers, body: method === "GET" ? undefined : body });
  return { status: r.status, json: await r.json().catch(() => null) };
};
const event = (id, reference, extra = {}) => JSON.stringify({ event: "charge.success", data: { id, reference, domain: "test", status: "success", ...extra } });

let pass = 0;
let total = 0;
const check = (name, ok, detail = "") => {
  total++;
  console.log(`${ok ? "PASS" : "FAIL"} | ${name}${ok ? "" : ` -> ${detail}`}`);
  if (ok) pass++;
  else process.exitCode = 1;
};

// ---- Setup: three online orders awaiting payment (100.00 each), each with one attempt.
const ids = JSON.parse(
  psql(`select json_build_object('po', (select id from auth.users where email='po@zz.test'), 'good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'pa', (select id from public.products where name='BO A'))`),
);
const as = (uid) => `select set_config('request.jwt.claims', json_build_object('sub','${uid}','role','authenticated')::text,false), set_config('request.jwt.claim.sub','${uid}',false);`;
function makeOrder() {
  psql(`${as(ids.po)} select public.create_marketplace_orders('${ids.po}', '${ids.good}', jsonb_build_array(jsonb_build_object('productId','${ids.pa}','quantity',1,'category','cash_private')), '{}', true, jsonb_build_object('${ids.alpha}','cod'));`);
  const id = psql(`select id from public.orders order by created_at desc limit 1`);
  psql(`alter table public.orders disable trigger aa_phase0_order_integrity; update public.orders set payment_method='paystack', settlement_method='pay_now' where id='${id}'; alter table public.orders enable trigger aa_phase0_order_integrity;`);
  return id;
}
function makeAttempt(orderId, reference) {
  psql(`insert into public.order_payment_attempts(order_id, provider, mode, reference, amount_ghs, amount_minor) select o.id,'paystack','test','${reference}',o.total_ghs,public.payment_minor_from_ghs(o.total_ghs) from public.orders o where o.id='${orderId}'`);
}
const price = Number(psql(`select price_ghs from public.products where name='BO A'`));
const minor = Math.round(price * 100);
const RUN = Date.now().toString(36);
const ref = (n) => `dx-test-web-${RUN}-${n}`;
const o1 = makeOrder();
const o2 = makeOrder();
const o3 = makeOrder();
makeAttempt(o1, ref("0001"));
makeAttempt(o2, ref("0002"));
makeAttempt(o3, ref("0003"));
const state = (o) => psql(`select payment_status from public.orders where id='${o}'`);
const attempt = (ref) => psql(`select status||'/'||coalesce(flag_reason,'-') from public.order_payment_attempts where reference='${ref}'`);
const eventRow = (key) => psql(`select coalesce(outcome,'-')||'/'||(processed_at is not null) from public.payment_provider_events where dedupe_key='${key}'`);

// ---- The checks.
let r = await post(event(1, "x"), "00");
check("a wrong signature is refused (401) and stores nothing", r.status === 401 && psql(`select count(*) from public.payment_provider_events`) === "0", JSON.stringify(r));
r = await post(event(1, "x"), null);
check("a missing signature is refused (401)", r.status === 401, JSON.stringify(r));
r = await post("", "00", "GET");
check("only POST is accepted", r.status === 405, JSON.stringify(r));
r = await post("not json", createHmac("sha512", SECRET).update("not json").digest("hex"));
check("a signed body that is not JSON is refused (400)", r.status === 400, JSON.stringify(r));

// A real payment: Paystack confirms it for the exact amount.
verifyAnswers.set(ref("0001"), { id: 1001, status: "success", reference: ref("0001"), amount: minor, currency: "GHS", channel: "card", fees: 100, domain: "test" });
r = await post(event(1001, ref("0001")));
check("a real, verified payment is applied through the real handler (200)", r.status === 200 && r.json?.outcome === "applied", JSON.stringify(r));
check("the order is paid and the attempt succeeded", state(o1) === "paid" && attempt(ref("0001")) === "succeeded/-");
check("the notification was stored and marked processed", eventRow("charge.success:1001") === "applied/true", eventRow("charge.success:1001"));
check("Paystack was asked (the notification alone is not proof)", verifyCalls.includes(ref("0001")));
const callsBefore = verifyCalls.length;
r = await post(event(1001, ref("0001")));
check("the same notification delivered again is acknowledged without being processed again", r.status === 200 && r.json?.duplicate === true && verifyCalls.length === callsBefore, JSON.stringify(r));
check("still one paid order, one notification row", state(o1) === "paid" && psql(`select count(*) from public.payment_provider_events where dedupe_key='charge.success:1001'`) === "1");

// A notification that claims success when Paystack says otherwise changes nothing.
verifyAnswers.set(ref("0002"), { id: 1002, status: "failed", reference: ref("0002"), amount: minor, currency: "GHS", gateway_response: "Declined", domain: "test" });
r = await post(event(1002, ref("0002")));
check("a notification that says success while Paystack says failed does not pay the order", r.status === 200 && r.json?.outcome === "failed" && state(o2) === "unpaid" && attempt(ref("0002")) === "failed/-", JSON.stringify(r));

// A wrong amount is flagged, never paid.
verifyAnswers.set(ref("0003"), { id: 1003, status: "success", reference: ref("0003"), amount: minor - 1, currency: "GHS", channel: "card", domain: "test" });
r = await post(event(1003, ref("0003")));
check("a payment for the wrong amount is flagged, not applied", r.status === 200 && r.json?.outcome === "flagged" && state(o3) === "unpaid" && attempt(ref("0003")) === "flagged/amount_mismatch", JSON.stringify(r));

// Paystack cannot be reached: the notification is kept and Paystack is told to retry.
r = await post(event(1004, ref("9999")));
check("when Paystack cannot confirm (unknown reference), the answer is 500 so it retries", r.status === 500, JSON.stringify(r));
check("and the notification is kept, marked as an error to be retried", eventRow("charge.success:1004") === "error/true", eventRow("charge.success:1004"));
r = await post(event(1004, ref("9999")));
check("a retry of a notification that failed is processed again (not skipped as a duplicate)", r.status === 500 && r.json?.duplicate !== true, JSON.stringify(r));

// Other mode, other events.
r = await post(event(1005, ref("0001"), { domain: "live" }));
check("a live-mode notification reaching test mode is acknowledged and ignored", r.status === 200 && r.json?.ignored === "mode", JSON.stringify(r));
r = await post(JSON.stringify({ event: "transfer.success", data: { id: 77, reference: "t", domain: "test" } }));
check("an event it does not act on is stored and acknowledged", r.status === 200 && r.json?.outcome === "ignored" && eventRow("transfer.success:77") === "ignored/true", JSON.stringify(r));

server.close();
console.log(`${pass}/${total} webhook checks passed`);
