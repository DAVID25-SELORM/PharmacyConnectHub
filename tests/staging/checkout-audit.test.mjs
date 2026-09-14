import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import pg from "pg";
test("checkout audit actor: trusted attribution, replay, rollback and client boundary", async () => {
  const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
  if (new URL(cfg.DB_URL).host !== "127.0.0.1:56322")
    throw new Error("Isolated staging database required");
  const db = new pg.Client({ connectionString: cfg.DB_URL });
  await db.connect();
  try {
    await db.query("BEGIN");
    const migration = await readFile(
      "supabase/migrations/20260914130000_checkout_audit_actor.sql",
      "utf8",
    );
    await db.query(migration.replace(/^BEGIN;$/m, "").replace(/^COMMIT;$/m, ""));
    const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
    const p = (
      await db.query("SELECT id,stock FROM products WHERE wholesaler_id=$1 AND stock>=3 LIMIT 1", [
        users.seller.biz,
      ])
    ).rows[0];
    assert.ok(p);
    const key = randomUUID();
    await db.query("SET LOCAL ROLE service_role");
    const checkout = () =>
      db.query("SELECT public.create_marketplace_orders($1,$2,$3,$4)", [
        users.buyer.id,
        users.buyer.biz,
        JSON.stringify([{ productId: p.id, quantity: 2, actor_id: users.seller.id }]),
        key,
      ]);
    await checkout();
    await checkout();
    await db.query("RESET ROLE");
    const order = (
      await db.query("SELECT order_ids[1] id FROM checkout_requests WHERE id=$1", [key])
    ).rows[0].id;
    const audit = (
      await db.query(
        "SELECT performed_by,performed_by_email FROM audit_logs WHERE record_id=$1 AND activity='Order placed'",
        [order],
      )
    ).rows;
    assert.equal(audit.length, 1);
    assert.equal(audit[0].performed_by, users.buyer.id);
    assert.equal(audit[0].performed_by_email, users.buyer.email);
    const movement = (
      await db.query(
        "SELECT actor_id,quantity_delta FROM inventory_movements WHERE order_id=$1 AND movement_type='checkout_deduction'",
        [order],
      )
    ).rows;
    assert.equal(movement.length, 1);
    assert.equal(movement[0].actor_id, users.buyer.id);
    assert.equal(Number(movement[0].quantity_delta), -2);
    assert.equal(
      (await db.query("SELECT stock FROM products WHERE id=$1", [p.id])).rows[0].stock,
      p.stock - 2,
    );
    assert.equal((await db.query("SELECT * FROM server_audit_context")).rowCount, 0);
    for (const role of ["anon", "authenticated"])
      assert.equal(
        (
          await db.query(
            "SELECT has_function_privilege($1,'public.create_marketplace_orders(uuid,uuid,jsonb,uuid)','EXECUTE') ok",
            [role],
          )
        ).rows[0].ok,
        false,
      );
    await db.query("SAVEPOINT failure");
    await db.query("SET LOCAL ROLE service_role");
    await assert.rejects(
      db.query("SELECT public.create_marketplace_orders($1,$2,$3,$4)", [
        users.buyer.id,
        users.buyer.biz,
        JSON.stringify([{ productId: p.id, quantity: 2147483647 }]),
        randomUUID(),
      ]),
    );
    await db.query("ROLLBACK TO SAVEPOINT failure");
    assert.equal(
      (await db.query("SELECT stock FROM products WHERE id=$1", [p.id])).rows[0].stock,
      p.stock - 2,
    );
    await db.query("SAVEPOINT client");
    await db.query("SET LOCAL ROLE authenticated");
    await assert.rejects(
      db.query("INSERT INTO server_audit_context VALUES(txid_current(),$1)", [users.seller.id]),
      /permission denied/,
    );
    await db.query("ROLLBACK TO SAVEPOINT client");
  } finally {
    await db.query("ROLLBACK");
    await db.end();
  }
});
