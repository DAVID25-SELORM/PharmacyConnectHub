// Runs the real payment handlers (settlement accounts, initialize with a split, the limit, the readiness checks, the reconciler's note) behind a real Node HTTP server
// against the LOCAL Supabase stack with real sessions and a stand-in for Paystack that records exactly what it was asked.
//
//   source env.sh      # API_URL, ANON_KEY, SERVICE_ROLE_KEY for the local stack
//   npx tsx tests/local-supabase/payments-settlement-api.local.mjs
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
const SECRET = "sk_test_local_settlement_check";
const CRON = "cron-secret-for-the-settlement-check";
const NUMBER = "0123456789012";

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
process.env.CRON_SECRET = CRON;
psql(
  `update public.payments_settings set online_enabled = true, mode = 'test', auto_refunds = false, split_mode = 'none', platform_fee_bps = 0, fee_bearer = 'subaccount', max_order_ghs = null, split_refunds_confirmed = false, reconciler_frequent_at = null`,
);

const post = async (path, bearer, body, extraHeaders = {}) => {
  const headers = { "content-type": "application/json", ...extraHeaders };
  if (bearer) headers.authorization = `Bearer ${bearer}`;
  const r = await realFetch(`${dev.baseUrl}${path}`, { method: "POST", headers, body: JSON.stringify(body ?? {}) });
  return { status: r.status, json: await r.json().catch(() => null) };
};
const t = { po: await token("po@zz.test"), wo: await token("wo@zz.test"), admin: await token("admin@zz.test") };
const ids = JSON.parse(
  psql(`select json_build_object('good', (select id from public.businesses where name='Good Pharmacy'),
    'alpha', (select id from public.businesses where name='Alpha Wholesale'), 'other', (select id from public.businesses where name='Other Wholesale'),
    'pa', (select id from public.products where name='BO A'))`),
);
const payout = (body, bearer = t.admin) => post("/api/payments/admin-payout", bearer, body);
async function placeOrder() {
  const r = await post("/api/orders/create", t.po, {
    pharmacyId: ids.good,
    requestId: randomUUID(),
    items: [{ productId: ids.pa, quantity: 10, category: "cash_private" }],
    settlementMethods: { [ids.alpha]: "pay_now" },
  });
  return r;
}

// ---- 1. The server's own checks, and who may ask
let r = await payout({ action: "checks" });
const byKey = Object.fromEntries((r.json?.checks ?? []).map((c) => [c.key, c.ok]));
check("an administrator sees the server checks; mode, key, secret and address are all in order here", r.status === 200 && byKey.mode_set && byKey.key_present && byKey.key_matches_mode && byKey.cron_secret && byKey.site_address, JSON.stringify(r.json));
check("the local stand-in setting is reported (it must not be present in production)", byKey.no_local_stand_in === false);
check("no key, secret or address value is in the answer", !JSON.stringify(r.json).includes(SECRET) && !JSON.stringify(r.json).includes(CRON) && !JSON.stringify(r.json).includes("localhost"));
r = await payout({ action: "checks" }, t.po);
check("a pharmacy cannot ask", r.status === 403);
r = await payout({ action: "checks" }, null);
check("nor can someone not signed in", r.status === 401);

// ---- 2. Banks
r = await payout({ action: "banks" });
check("the administrator reads the banks from the provider", r.status === 200 && r.json?.banks?.length === 2 && r.json.banks[0].code === "GCB", JSON.stringify(r.json));

// ---- 3. Registering settlement accounts
r = await payout({ action: "register", wholesalerId: ids.alpha, businessName: "Alpha Wholesale Ltd", bankCode: "GCB", accountNumber: "12ab" });
check("a bad account number is refused before anything is sent", r.status === 400 && fake.subaccounts.size === 0, JSON.stringify(r));
r = await payout({ action: "register", wholesalerId: ids.alpha, businessName: "Alpha Wholesale Ltd", bankCode: "GCB", accountNumber: NUMBER }, t.po);
check("a pharmacy cannot register one", r.status === 403 && fake.subaccounts.size === 0);
r = await payout({ action: "register", wholesalerId: ids.alpha, businessName: "Alpha Wholesale Ltd", bankCode: "GCB", accountNumber: NUMBER });
check("registering creates the account at the provider and records it as active", r.status === 200 && r.json?.status === "active" && fake.subaccounts.size === 1, JSON.stringify(r));
const sent = [...fake.subaccounts.values()][0];
check("the provider received the full number and a default share of nothing", sent.account_number === NUMBER && sent.percentage_charge === 0 && sent.settlement_bank === "GCB");
const row = psql(`select row_to_json(a) from public.supplier_payout_accounts a where wholesaler_id = '${ids.alpha}' and status = 'active'`);
check("the database keeps the code and the last four digits only: the number is nowhere in the row", row.includes("ACCT_fake1") && row.includes('"account_last4":"9012"') && !row.includes(NUMBER) && !row.includes(NUMBER.slice(0, 9)), row);
check("and nowhere else in the database", psql(`select count(*) from (select row_to_json(x)::text t from public.supplier_payout_accounts x union all select row_to_json(l)::text from public.order_payment_log l union all select row_to_json(e)::text from public.payment_alerts e) q where t like '%${NUMBER}%'`) === "0");
r = await payout({ action: "register", wholesalerId: ids.alpha, businessName: "Alpha Again", bankCode: "GCB", accountNumber: NUMBER });
check("a second account for the same supplier is refused, and the provider is not asked", r.status === 400 && /already has a settlement account/.test(r.json?.error ?? "") && fake.subaccounts.size === 1, JSON.stringify(r));
fake.subaccountBehavior = "reject";
r = await payout({ action: "register", wholesalerId: ids.other, businessName: "Other Wholesale Ltd", bankCode: "GCB", accountNumber: NUMBER });
check("a refusal by the provider is recorded as failed with its reason", r.status === 400 && psql(`select status || '/' || failure_reason from public.supplier_payout_accounts where wholesaler_id = '${ids.other}' order by created_at desc limit 1`).startsWith("failed/The provider refused it"), JSON.stringify(r));
fake.subaccountBehavior = "drop";
r = await payout({ action: "register", wholesalerId: ids.other, businessName: "Other Wholesale Ltd", bankCode: "GCB", accountNumber: NUMBER });
check("a lost answer is recorded as failed, with the warning to look at the provider's dashboard", r.status === 502 && /dashboard/.test(r.json?.error ?? "") && /dashboard/.test(psql(`select failure_reason from public.supplier_payout_accounts where wholesaler_id = '${ids.other}' order by created_at desc limit 1`)), JSON.stringify(r));
fake.subaccountBehavior = "accept";

// ---- 4. Who can be paid online
r = await rpc(t.po, "suppliers_ready_for_online_payment", { p_wholesaler_ids: [ids.alpha, ids.other] });
check("with no split, every supplier is ready", r.ok && r.body.length === 2, JSON.stringify(r.body));
psql(`update public.payments_settings set split_mode = 'subaccount', platform_fee_bps = 250, max_order_ghs = 2000`);
r = await rpc(t.po, "suppliers_ready_for_online_payment", { p_wholesaler_ids: [ids.alpha, ids.other] });
check("in split mode only the supplier with an active account is ready", r.ok && r.body.length === 1 && r.body[0] === ids.alpha, JSON.stringify(r.body));
r = await rpc(t.po, "online_payments_status");
check("the checkout screen is told the limit", r.ok && r.body.max_order_ghs === 2000 && r.body.enabled === true, JSON.stringify(r.body));

// ---- 5. A payment is split exactly as the database says
r = await placeOrder();
check("checkout takes Pay now for the supplier that has an account", r.status === 200 && r.json.awaitingPayment?.length === 1, JSON.stringify(r));
const o1 = r.json.awaitingPayment[0].orderId;
r = await post("/api/payments/initialize", t.po, { orderId: o1 });
check("the payment starts", r.status === 200 && r.json?.authorizationUrl, JSON.stringify(r));
const ref1 = r.json.reference;
const p1 = fake.payments.get(ref1);
check("the provider was asked to split it: the supplier's account, GHS 25.00 (2.5%) for the platform, the supplier bearing the fee",
  p1.split?.subaccount === "ACCT_fake1" && p1.split.transaction_charge === 2500 && p1.split.bearer === "subaccount" && p1.amount === 100000, JSON.stringify(p1.split));
check("and the payment records the same", psql(`select split_subaccount || '/' || split_charge_minor || '/' || split_bearer from public.order_payment_attempts where reference = '${ref1}'`) === "ACCT_fake1/2500/subaccount");
p1.status = "success";
r = await post("/api/payments/verify", t.po, { orderId: o1 });
check("it is verified and the order is paid", r.json?.status === "paid", JSON.stringify(r));

// ---- 6. The report
r = await rpc(t.admin, "admin_settlement_report", { p_from: new Date(Date.now() - 86400000).toISOString(), p_to: new Date(Date.now() + 86400000).toISOString(), p_mode: "test" });
const alphaRow = (r.body?.suppliers ?? []).find((s) => s.name === "Alpha Wholesale");
check("the settlement report counts the split payment (1000 received, 25 to the platform; earlier unsplit test payments are shown separately)", r.ok && alphaRow && alphaRow.received_ghs - alphaRow.not_split_ghs === 1000 && alphaRow.platform_share_ghs === 25, JSON.stringify(alphaRow));
r = await rpc(t.po, "admin_settlement_report", { p_from: new Date(Date.now() - 86400000).toISOString(), p_to: new Date(Date.now() + 86400000).toISOString() });
check("a pharmacy cannot read it", !r.ok && /Only platform administrators/.test(r.error ?? ""));

// ---- 7. Switching an account off stops new payments for that supplier at checkout and at the provider
const acct = psql(`select id from public.supplier_payout_accounts where wholesaler_id = '${ids.alpha}' and status = 'active'`);
r = await payout({ action: "set_active", accountId: acct, active: false });
check("an administrator switches the account off", r.status === 200 && r.json?.status === "inactive", JSON.stringify(r));
r = await placeOrder();
check("checkout then refuses Pay now for that supplier, in plain words", r.status === 400 && /cannot take online payments yet/.test(r.json?.error ?? ""), JSON.stringify(r));
r = await payout({ action: "set_active", accountId: acct, active: true });
check("and it can be switched back on", r.status === 200 && r.json?.status === "active", JSON.stringify(r));

// ---- 8. The limit
r = await placeOrder();
const o2 = r.json?.awaitingPayment?.[0]?.orderId;
psql(`update public.payments_settings set max_order_ghs = 500`);
const before = fake.payments.size;
r = await post("/api/payments/initialize", t.po, { orderId: o2 });
check("a payment above the limit is refused with the limit named, and nothing reaches the provider", r.status === 400 && /above the limit for online payments \(GH.? ?500\.00\)/.test(r.json?.error ?? "") && fake.payments.size === before, JSON.stringify(r));
check("the attempt is closed, not left open", psql(`select count(*) from public.order_payment_attempts where order_id = '${o2}' and status in ('initiated','pending')`) === "0");

// ---- 9. The scheduler's note and the readiness check
r = await rpc(t.admin, "payments_readiness");
const item = (key) => (r.body?.items ?? []).find((i) => i.key === key);
check("the readiness check says not ready for live: the scheduler has never run", r.ok && r.body.ready_for_live === false && item("reconciler_alive")?.ok === false && item("split_on")?.ok === true && item("cap_set")?.ok === true, JSON.stringify(r.body));
r = await realFetch(`${dev.baseUrl}/api/payments/reconcile`, { method: "POST", headers: { authorization: `Bearer ${CRON}` } });
check("the scheduler calls the reconciler", r.status === 200, String(r.status));
r = await rpc(t.admin, "payments_readiness");
check("and the readiness check now sees it running", item("reconciler_alive")?.ok === true, JSON.stringify(item("reconciler_alive")));
r = await realFetch(`${dev.baseUrl}/api/payments/reconcile`, { method: "POST", headers: { authorization: "Bearer wrong" } });
const stamp = psql(`select reconciler_frequent_at from public.payments_settings`);
check("a call with the wrong secret is refused", r.status === 401);
r = await rpc(t.po, "payments_readiness");
check("a pharmacy cannot read the readiness check", !r.ok && /Only platform administrators/.test(r.error ?? ""));
check("live payments cannot be switched on from here: the live items are unmet", psql(`select 1`) === "1" && (() => { try { psql(`update public.payments_settings set online_enabled = true, mode = 'live'`); return false; } catch (e) { return /Live payments cannot be switched on yet/.test(String(e.stderr)); } })());

psql(`update public.payments_settings set online_enabled = false, mode = 'test', split_mode = 'none', platform_fee_bps = 0, max_order_ghs = null`);
await fake.close();
await dev.close();
console.log(`${pass}/${total} settlement API checks passed (${stamp ? "scheduler stamp present" : "no stamp"})`);
