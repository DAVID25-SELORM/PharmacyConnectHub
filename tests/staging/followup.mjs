import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import pg from "pg";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.API_URL).host !== "127.0.0.1:56321") throw new Error("Staging only");
const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
const admin = createClient(cfg.API_URL, cfg.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const db = new pg.Client({ connectionString: cfg.DB_URL });
await db.connect();
const results = [];
const ok = (r) => {
  if (r.error) throw new Error(r.error.message);
  return r.data;
};
for (const u of Object.values(users)) {
  if (!u.password) continue;
  u.c = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
  ok(await u.c.auth.signInWithPassword({ email: u.email, password: u.password }));
}
const run = async (name, fn) => {
  try {
    await fn();
    results.push({ name, result: "PASS" });
  } catch (e) {
    results.push({ name, result: "FAIL", error: e.message });
  }
  console.log(results.at(-1).result + " " + name);
};
const api = async (u, path, body) => {
  const token = ok(await u.c.auth.getSession()).session.access_token;
  const r = await fetch("http://127.0.0.1:4180/api/" + path, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: r.status, data: await r.json() };
};
try {
  await run("Authorized cancellation restores once and remains terminal", async () => {
    const o = (
      await db.query(
        "SELECT id FROM orders WHERE status='pending' AND wholesaler_id=$1 ORDER BY created_at DESC LIMIT 1",
        [users.seller.biz],
      )
    ).rows[0];
    assert.ok(o);
    for (let i = 0; i < 2; i++)
      ok(
        await users.seller.c.rpc("transition_order", {
          _order_id: o.id,
          _status: "cancelled",
          _reason: "Staging cancellation",
        }),
      );
    assert.equal(
      (
        await db.query(
          "SELECT * FROM inventory_movements WHERE order_id=$1 AND movement_type='order_cancellation_restore'",
          [o.id],
        )
      ).rowCount,
      1,
    );
    assert.ok(
      (await users.seller.c.rpc("transition_order", { _order_id: o.id, _status: "accepted" }))
        .error,
    );
  });
  await run(
    "Tenant invitation API and actual invitee acceptance for pharmacy cashier and wholesaler manager",
    async () => {
      for (const [name, role] of [
        ["buyer", "cashier"],
        ["seller", "manager"],
      ]) {
        const u = users[name],
          email = "staff-" + randomUUID() + "@example.test";
        const r = await api(u, "staff/invite", { businessId: u.biz, email, role });
        assert.equal(r.status, 200, JSON.stringify(r.data));
        const link = ok(await admin.auth.admin.generateLink({ type: "magiclink", email }));
        const c = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
        const auth = ok(
          await c.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "magiclink" }),
        );
        ok(await c.rpc("accept_business_invitations"));
        const member = (
          await db.query("SELECT * FROM business_staff WHERE user_id=$1", [auth.user.id])
        ).rows[0];
        assert.equal(member.status, "active");
        assert.equal(member.role, role);
        assert.equal(member.business_id, u.biz);
      }
    },
  );
  await run("Receipt provider-result simulation, durable sent suppression ", async () => {
    const order = (await db.query("SELECT id FROM orders WHERE payment_status='paid' LIMIT 1"))
      .rows[0].id;
    const claim = ok(
      await admin.rpc("claim_order_receipt", {
        _order_id: order,
        _caller_id: users.seller.id,
        _payload: { toEmail: "test@example.test" },
      }),
    );
    assert.equal(claim.status, "claimed");
    ok(
      await admin.rpc("finish_order_receipt", {
        _order_id: order,
        _claim_id: claim.claim_id,
        _provider_id: "staging-simulated-provider",
        _error: null,
      }),
    );
    const r = await api(users.seller, "orders/send-receipt", { orderId: order });
    assert.equal(r.status, 200);
    assert.equal(r.data.receiptSent, true);
    assert.equal(
      (await db.query("SELECT status FROM receipt_outbox WHERE order_id=$1", [order])).rows[0]
        .status,
      "sent",
    );
  });
  await run(
    "Auth session refresh, recovery token exchange, password update and logout",
    async () => {
      const u = users.buyer2;
      ok(await u.c.auth.refreshSession());
      const link = ok(await admin.auth.admin.generateLink({ type: "recovery", email: u.email }));
      const c = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
      ok(await c.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "recovery" }));
      ok(await c.auth.updateUser({ password: u.password + "New9!" }));
      ok(await c.auth.signOut());
      assert.equal(ok(await c.auth.getSession()).session, null);
    },
  );
  await run("Read-only review queries against actual staging schema", async () => {
    await db.query("BEGIN READ ONLY");
    try {
      for (const phase of [0, 1, 2])
        await db.query(await readFile("supabase/phase" + phase + "_read_only_review.sql", "utf8"));
    } finally {
      await db.query("ROLLBACK");
    }
  });
} finally {
  await db.end();
  await writeFile(".tmp/staging-rehearsal/followup-results.json", JSON.stringify(results, null, 2));
}
if (results.some((x) => x.result === "FAIL")) process.exitCode = 1;
