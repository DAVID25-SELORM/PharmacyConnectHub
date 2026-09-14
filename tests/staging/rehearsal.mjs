import assert from "node:assert/strict";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { randomUUID, randomBytes } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import pg from "pg";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.API_URL).hostname !== "127.0.0.1" || new URL(cfg.API_URL).port !== "56321")
  throw new Error("Not isolated staging");
const db = new pg.Client({ connectionString: cfg.DB_URL });
if (!["127.0.0.1", "localhost"].includes(new URL(cfg.DB_URL).hostname))
  throw new Error("Not local DB");
await db.connect();
const admin = createClient(cfg.API_URL, cfg.SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const makeClient = () =>
  createClient(cfg.API_URL, cfg.ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
const rows = [];
const users = {};
const run = async (name, fn) => {
  try {
    await fn();
    rows.push({ name, result: "PASS" });
    console.log("PASS " + name);
  } catch (e) {
    rows.push({ name, result: "FAIL", error: e.message });
    console.log("FAIL " + name + ": " + e.message);
  }
  await writeFile(".tmp/staging-rehearsal/results.json", JSON.stringify(rows, null, 2));
};
const ok = (r) => {
  if (r.error) throw new Error(r.error.message);
  return r.data;
};
const denied = (r) => assert.ok(r.error, "Expected denial");
async function signup(name, role, extra = {}) {
  const c = makeClient(),
    email = `${name}-${randomUUID()}@example.test`,
    password = randomBytes(24).toString("base64url") + "!9";
  const data = ok(
    await c.auth.signUp({
      email,
      password,
      options: {
        data: {
          role,
          business_name: name,
          full_name: "Staging " + name,
          phone: "0240000000",
          ...extra,
        },
      },
    }),
  );
  assert.ok(data.user);
  assert.equal(data.session, null);
  const link = ok(await admin.auth.admin.generateLink({ type: "magiclink", email }));
  ok(await c.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "magiclink" }));
  const b = ok(await c.from("businesses").select("*").eq("owner_id", data.user.id));
  return { id: data.user.id, email, password, c, biz: b?.[0]?.id };
}
async function api(u, path, body) {
  const session = ok(await u.c.auth.getSession()).session;
  const r = await fetch("http://127.0.0.1:4180/api/" + path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer " + session.access_token,
    },
    body: JSON.stringify(body),
  });
  return { status: r.status, data: await r.json() };
}
async function evidence(u) {
  const path = u.id + "/" + u.biz + "/" + randomUUID() + ".pdf";
  ok(
    await u.c.storage
      .from("licenses")
      .upload(path, new Blob(["%PDF-1.4\nstaging evidence"], { type: "application/pdf" })),
  );
  const doc = ok(
    await u.c
      .from("license_documents")
      .insert({ business_id: u.biz, doc_type: "business_registration", storage_path: path })
      .select()
      .single(),
  );
  return doc;
}
async function approve(u) {
  const docs = ok(
    await users.owner.c.from("license_documents").select("version_id").eq("business_id", u.biz),
  );
  ok(
    await users.owner.c.rpc("review_business_evidence", {
      _business_id: u.biz,
      _status: "approved",
      _versions: docs.map((d) => d.version_id),
    }),
  );
}
async function product(u, name, stock = 10) {
  return ok(
    await u.c
      .from("products")
      .insert({
        wholesaler_id: u.biz,
        name,
        brand: "Staging",
        form: "Tablet",
        pack_size: "20",
        price_ghs: 7.25,
        stock,
      })
      .select()
      .single(),
  );
}
try {
  await run("Empty baseline has no demo businesses/products/platform users", async () => {
    for (const t of ["businesses", "products", "platform_staff"])
      assert.equal(Number((await db.query("SELECT count(*) FROM " + t)).rows[0].count), 0);
  });
  await run(
    "Actual Auth manipulated first signup cannot provision platform privileges",
    async () => {
      for (const role of ["admin", "owner", "platform_admin"]) {
        const u = await signup("attack-" + role, role, { platform_role: "owner" });
        assert.equal(ok(await u.c.rpc("has_role", { _user_id: u.id, _role: "admin" })), false);
        assert.equal(
          (await db.query("SELECT * FROM platform_staff WHERE user_id=$1", [u.id])).rowCount,
          0,
        );
      }
    },
  );
  await run("Actual Auth representative owners and pending businesses", async () => {
    users.owner = await signup("platform-owner", "pharmacy", { is_staff_invite: true });
    await db.query(
      "INSERT INTO platform_staff(user_id,role,status,joined_at) VALUES($1,'owner','active',now())",
      [users.owner.id],
    );
    for (const [name, role] of [
      ["seller", "wholesaler"],
      ["seller2", "wholesaler"],
      ["buyer", "pharmacy"],
      ["buyer2", "pharmacy"],
    ]) {
      users[name] = await signup(name, role);
      assert.equal(
        ok(
          await users[name].c
            .from("businesses")
            .select("verification_status")
            .eq("id", users[name].biz)
            .single(),
        ).verification_status,
        "pending",
      );
    }
  });
  await run("Owner API invitation and real Auth invitee acceptance", async () => {
    const email = "admin-" + randomUUID() + "@example.test";
    const r = await api(users.owner, "platform-staff/invite", { email });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    const c = makeClient();
    const link = ok(await admin.auth.admin.generateLink({ type: "magiclink", email }));
    const data = ok(
      await c.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "magiclink" }),
    );
    ok(await c.rpc("accept_platform_invitation"));
    users.platformAdmin = { id: data.user.id, email, c };
    denied(
      await c.rpc("manage_platform_member", { _user_id: users.owner.id, _status: "inactive" }),
    );
    assert.equal(
      (await api(users.platformAdmin, "platform-staff/invite", { email: "denied@example.test" }))
        .status,
      403,
    );
    assert.equal(
      (await api(users.owner, "platform-staff/invite", { email: users.owner.email })).status,
      409,
    );
  });
  await run("Pending wholesaler inventory and pharmacy import denied", async () => {
    denied(
      await users.seller.c.rpc("preview_wholesaler_import", {
        _business_id: users.seller.biz,
        _products: [{ name: "x", price_ghs: 1 }],
        _mode: "add",
      }),
    );
    denied(
      await users.buyer.c.rpc("preview_wholesaler_import", {
        _business_id: users.buyer.biz,
        _products: [{ name: "x", price_ghs: 1 }],
        _mode: "add",
      }),
    );
  });
  let doc;
  await run("Real Storage upload/private access/type/size and evidence binding", async () => {
    doc = await evidence(users.seller);
    for (const u of [users.seller2, users.buyer]) {
      denied(await u.c.storage.from("licenses").download(doc.storage_path));
      denied(
        await u.c.storage
          .from("licenses")
          .upload(doc.storage_path, new Blob(["x"], { type: "application/pdf" }), { upsert: true }),
      );
    }
    denied(
      await users.seller.c.storage
        .from("licenses")
        .upload(
          users.seller.id + "/" + users.seller.biz + "/bad.html",
          new Blob(["<html>"], { type: "text/html" }),
        ),
    );
    denied(
      await users.seller.c.storage
        .from("licenses")
        .upload(
          users.seller.id + "/" + users.seller.biz + "/big.pdf",
          new Blob([new Uint8Array(10485761)], { type: "application/pdf" }),
        ),
    );
    denied(
      await users.seller.c.from("license_documents").insert({
        business_id: users.seller.biz,
        doc_type: "missing",
        storage_path: doc.storage_path + "missing",
      }),
    );
    const signed = ok(
      await users.owner.c.storage.from("licenses").createSignedUrl(doc.storage_path, 30),
    );
    assert.equal((await fetch(signed.signedUrl)).status, 200);
  });
  await run("Version-bound approval and replacement reopens review", async () => {
    denied(
      await users.seller.c.rpc("review_business_evidence", {
        _business_id: users.seller.biz,
        _status: "approved",
        _versions: [doc.version_id],
      }),
    );
    await approve(users.seller);
    const path = users.seller.id + "/" + users.seller.biz + "/" + randomUUID() + ".pdf";
    ok(
      await users.seller.c.storage
        .from("licenses")
        .upload(path, new Blob(["%PDF-1.4 new"], { type: "application/pdf" })),
    );
    ok(
      await users.seller.c
        .from("license_documents")
        .update({ storage_path: path })
        .eq("id", doc.id),
    );
    assert.equal(
      ok(
        await users.seller.c
          .from("businesses")
          .select("verification_status")
          .eq("id", users.seller.biz)
          .single(),
      ).verification_status,
      "pending",
    );
    denied(
      await users.owner.c.rpc("review_business_evidence", {
        _business_id: users.seller.biz,
        _status: "approved",
        _versions: [doc.version_id],
      }),
    );
    await approve(users.seller);
    for (const key of ["seller2", "buyer", "buyer2"]) {
      await evidence(users[key]);
      await approve(users[key]);
    }
  });
  let p;
  await run("Manual inventory, add/remove/reconcile and immutable detail stock", async () => {
    p = await product(users.seller, "Staging product", 80);
    const adjust = async (op, q, expected) =>
      ok(
        await users.seller.c.rpc("adjust_product_stock", {
          _product_id: p.id,
          _operation: op,
          _quantity: q,
          _request_id: randomUUID(),
          _expected_stock: expected ?? null,
          _reason: "Staging physical count",
        }),
      );
    assert.equal(await adjust("add", 20), 100);
    assert.equal(await adjust("remove", 15), 85);
    denied(
      await users.seller.c.rpc("adjust_product_stock", {
        _product_id: p.id,
        _operation: "remove",
        _quantity: 100,
        _request_id: randomUUID(),
      }),
    );
    assert.equal(await adjust("reconcile", 100, 85), 100);
    assert.equal(await adjust("reconcile", 93, 100), 93);
    denied(await users.seller.c.from("products").update({ stock: 100 }).eq("id", p.id));
    const m = (
      await db.query(
        "SELECT * FROM inventory_movements WHERE product_id=$1 ORDER BY created_at DESC LIMIT 1",
        [p.id],
      )
    ).rows[0];
    assert.equal(Number(m.quantity_delta), -7);
    assert.equal(m.actor_id, users.seller.id);
  });
  await run("Real import RPC preview, replay, intentional repeat and identity", async () => {
    const products = [
      {
        name: "Imported 2.5mg",
        brand: "Brand",
        form: "Tablet",
        pack_size: "20",
        price_ghs: 5,
        stock: 10,
      },
    ];
    const request = randomUUID();
    const preview = ok(
      await users.seller.c.rpc("preview_wholesaler_import", {
        _business_id: users.seller.biz,
        _products: products,
        _mode: "add",
      }),
    );
    const args = {
      _business_id: users.seller.biz,
      _products: products,
      _mode: "add",
      _confirm_token: preview.token,
      _request_id: request,
    };
    const first = ok(await users.seller.c.rpc("preview_wholesaler_import", args));
    assert.deepEqual(ok(await users.seller.c.rpc("preview_wholesaler_import", args)), first);
    const next = ok(
      await users.seller.c.rpc("preview_wholesaler_import", {
        _business_id: users.seller.biz,
        _products: products,
        _mode: "add",
      }),
    );
    ok(
      await users.seller.c.rpc("preview_wholesaler_import", {
        ...args,
        _confirm_token: next.token,
        _request_id: randomUUID(),
      }),
    );
    assert.equal(
      ok(
        await users.seller.c.from("products").select("stock").eq("name", "Imported 2.5mg").single(),
      ).stock,
      20,
    );
  });
  let order;
  await run(
    "Actual checkout API retries, authoritative prices, multivendor order split",
    async () => {
      const p2 = await product(users.seller2, "Second supplier", 10);
      const key = randomUUID();
      const body = {
        pharmacyId: users.buyer.biz,
        requestId: key,
        items: [
          { productId: p.id, quantity: 2, unitPrice: 0 },
          { productId: p2.id, quantity: 1 },
        ],
      };
      const a = await api(users.buyer, "orders/create", body);
      assert.equal(a.status, 200, JSON.stringify(a.data));
      const b = await api(users.buyer, "orders/create", body);
      assert.deepEqual(a, b);
      assert.notEqual(
        (
          await api(users.buyer, "orders/create", {
            ...body,
            items: [{ productId: p.id, quantity: 3 }],
          })
        ).status,
        200,
      );
      const ids = (await db.query("SELECT order_ids FROM checkout_requests WHERE id=$1", [key]))
        .rows[0].order_ids;
      assert.equal(ids.length, 2);
      order = (
        await db.query("SELECT id FROM orders WHERE id=ANY($1) AND wholesaler_id=$2", [
          ids,
          users.seller.biz,
        ])
      ).rows[0].id;
      assert.equal(
        Number(
          (await db.query("SELECT unit_price_ghs FROM order_items WHERE order_id=$1", [order]))
            .rows[0].unit_price_ghs,
        ),
        7.25,
      );
    },
  );
  await run("Concurrent actual HTTP buyers order 8 of 10", async () => {
    const item = await product(users.seller, "Concurrent product", 10);
    const send = (u) =>
      api(u, "orders/create", {
        pharmacyId: u.biz,
        requestId: randomUUID(),
        items: [{ productId: item.id, quantity: 8 }],
      });
    const result = await Promise.all([send(users.buyer), send(users.buyer2)]);
    assert.equal(result.filter((r) => r.status === 200).length, 1);
    assert.equal(
      ok(await users.seller.c.from("products").select("stock").eq("id", item.id).single()).stock,
      2,
    );
    assert.equal(
      (
        await db.query(
          "SELECT * FROM inventory_movements WHERE product_id=$1 AND movement_type='checkout_deduction'",
          [item.id],
        )
      ).rowCount,
      1,
    );
  });
  await run("Real-session cross-tenant/direct-write attacks", async () => {
    assert.equal(ok(await users.buyer2.c.from("orders").select().eq("id", order)).length, 0);
    denied(
      await users.buyer.c
        .from("orders")
        .insert({ pharmacy_id: users.buyer.biz, wholesaler_id: users.seller.biz, total_ghs: 1 }),
    );
    denied(
      await users.buyer.c.from("order_items").insert({
        order_id: order,
        product_id: p.id,
        product_name: "fake",
        quantity: 1,
        unit_price_ghs: 1,
      }),
    );
    denied(
      await users.buyer.c.from("audit_logs").insert({ activity: "fake", record_type: "fake" }),
    );
    denied(
      await users.seller2.c.rpc("adjust_product_stock", {
        _product_id: p.id,
        _operation: "add",
        _quantity: 10,
        _request_id: randomUUID(),
      }),
    );
    assert.equal(
      ok(await users.seller2.c.from("inventory_movements").select().eq("product_id", p.id)).length,
      0,
    );
  });
  await run("Printing RPC authorization and read-only snapshot", async () => {
    const before = (await db.query("SELECT row_to_json(o) data FROM orders o WHERE id=$1", [order]))
      .rows[0].data;
    for (const u of [users.buyer, users.seller])
      assert.ok(ok(await u.c.rpc("get_order_print", { _business_id: u.biz, _order_id: order })));
    for (const u of [users.buyer2, users.seller2])
      denied(await u.c.rpc("get_order_print", { _business_id: u.biz, _order_id: order }));
    assert.deepEqual(
      (await db.query("SELECT row_to_json(o) data FROM orders o WHERE id=$1", [order])).rows[0]
        .data,
      before,
    );
  });
  await run("Lifecycle and concurrent payment API, failed email keeps payment", async () => {
    assert.notEqual(
      (await api(users.seller, "orders/confirm-payment", { orderId: order })).status,
      200,
    );
    for (const status of ["accepted", "packed", "dispatched", "delivered"])
      ok(await users.seller.c.rpc("transition_order", { _order_id: order, _status: status }));
    const responses = await Promise.all([
      api(users.seller, "orders/confirm-payment", { orderId: order }),
      api(users.seller, "orders/confirm-payment", { orderId: order }),
    ]);
    for (const r of responses) assert.equal(r.status, 200);
    assert.equal(
      (await db.query("SELECT payment_status FROM orders WHERE id=$1", [order])).rows[0]
        .payment_status,
      "paid",
    );
    assert.equal(
      (await db.query("SELECT * FROM receipt_outbox WHERE order_id=$1", [order])).rowCount,
      1,
    );
    denied(
      await users.seller.c.rpc("transition_order", {
        _order_id: order,
        _status: "cancelled",
        _reason: "Invalid return",
      }),
    );
  });
  await run("Cancellation restores once and remains terminal", async () => {
    const key = randomUUID();
    assert.equal(
      (
        await api(users.buyer, "orders/create", {
          pharmacyId: users.buyer.biz,
          requestId: key,
          items: [{ productId: p.id, quantity: 2 }],
        })
      ).status,
      200,
    );
    const id = (await db.query("SELECT order_ids FROM checkout_requests WHERE id=$1", [key]))
      .rows[0].order_ids[0];
    for (let i = 0; i < 2; i++)
      ok(
        await users.buyer.c.rpc("transition_order", {
          _order_id: id,
          _status: "cancelled",
          _reason: "Staging cancellation",
        }),
      );
    assert.equal(
      (
        await db.query(
          "SELECT * FROM inventory_movements WHERE order_id=$1 AND movement_type='order_cancellation_restore'",
          [id],
        )
      ).rowCount,
      1,
    );
    denied(await users.seller.c.rpc("transition_order", { _order_id: id, _status: "accepted" }));
  });
  await run("Actual effective security and audit snapshot", async () => {
    const tables = (
      await db.query(
        "SELECT relname,relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND relkind='r'",
      )
    ).rows;
    assert.ok(tables.every((t) => t.relrowsecurity));
    const functions = (
      await db.query(
        "SELECT p.oid::regprocedure::text name,p.proconfig,has_function_privilege('anon',p.oid,'EXECUTE') anon,has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef",
      )
    ).rows;
    const policies = (
      await db.query("SELECT * FROM pg_policies WHERE schemaname IN ('public','storage')")
    ).rows;
    await writeFile(
      ".tmp/staging-rehearsal/effective-security.json",
      JSON.stringify({ tables, functions, policies }, null, 2),
    );
    const audit = (
      await db.query(
        "SELECT activity,performed_by,record_type,record_id,created_at FROM audit_logs ORDER BY created_at",
      )
    ).rows;
    await writeFile(".tmp/staging-rehearsal/audit-evidence.json", JSON.stringify(audit, null, 2));
    assert.ok(audit.some((a) => a.performed_by === users.seller.id));
  });
} finally {
  await mkdir(".tmp/staging-rehearsal", { recursive: true });
  await writeFile(
    ".tmp/staging-rehearsal/users.json",
    JSON.stringify(
      Object.fromEntries(
        Object.entries(users).map(([k, u]) => [
          k,
          {
            id: u.id,
            email: u.email,
            password: u.password,
            biz: u.biz,
            session: u.c ? null : null,
          },
        ]),
      ),
    ),
  );
  await db.end();
}
if (rows.some((r) => r.result === "FAIL")) process.exitCode = 1;
