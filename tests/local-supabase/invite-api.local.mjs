// Runs the real api/staff/invite.ts handler against the LOCAL Supabase stack with real GoTrue JWTs.
import { createRequire } from "node:module";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";

const API = process.env.API_URL;
const ANON = process.env.ANON_KEY;
process.env.SUPABASE_URL = API;
if (!API || !API.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");

const psql = (sql) =>
  execFileSync("docker", ["exec", "-i", "supabase_db_drugxone-local-validation", "psql", "-U", "postgres", "-At", "-c", sql]).toString().trim();

async function token(email) {
  const r = await fetch(`${API}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "LocalTest#123" }),
  });
  const j = await r.json();
  assert.ok(j.access_token, `sign-in failed for ${email}`);
  return j.access_token;
}
const biz = (name) => psql(`select id from public.businesses where name = '${name}'`);

const { default: handler } = await import(process.env.HANDLER_PATH);

async function call(bearer, body) {
  let status = 200, payload;
  const res = { status(c) { status = c; return res; }, json(p) { payload = p; return res; } };
  await handler({ method: "POST", headers: { authorization: `Bearer ${bearer}`, host: "localhost" }, body }, res);
  return { status, payload };
}

let pass = 0;
const expect = async (name, bearer, body, wantStatus, wantText) => {
  const { status, payload } = await call(bearer, body);
  const ok = status === wantStatus && (!wantText || JSON.stringify(payload).includes(wantText));
  console.log(`${ok ? "PASS" : "FAIL"} | ${name} -> ${status} ${JSON.stringify(payload)}`);
  if (!ok) process.exitCode = 1; else pass++;
};

const alpha = biz("Alpha Wholesale"), pend = biz("Pending Wholesale"), rej = biz("Rejected Wholesale");
const t = { wo: await token("wo@zz.test"), wp: await token("wp@zz.test"), wr: await token("wr@zz.test"), px: await token("px@zz.test"), admin: await token("admin@zz.test") };

await expect("approved owner -> allowed", t.wo, { businessId: alpha, email: "nb@zz.test", role: "assistant" }, 200, "existing-account");
await expect("pending owner -> 403", t.wp, { businessId: pend, email: "nb@zz.test", role: "assistant" }, 403, "must be verified");
await expect("rejected owner -> 403", t.wr, { businessId: rej, email: "nb@zz.test", role: "assistant" }, 403, "must be verified");
await expect("unrelated user -> 403", t.px, { businessId: alpha, email: "nb@zz.test", role: "assistant" }, 403, "Only the business owner");
await expect("unrelated user vs pending business -> 403 (ownership checked first)", t.px, { businessId: pend, email: "nb@zz.test", role: "assistant" }, 403, "Only the business owner");
await expect("platform admin -> allowed (admin exemption preserved)", t.admin, { businessId: pend, email: "nb@zz.test", role: "assistant" }, 200, "existing-account");
await expect("missing token -> 401", "", { businessId: alpha, email: "nb@zz.test", role: "assistant" }, 401);
console.log(`${pass}/7 API checks passed`);
