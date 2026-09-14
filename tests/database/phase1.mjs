import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";

export async function phase1Tests(t, ctx) {
  await t.test("P1 read-only review queries execute without repairs", async () => {
    await ctx.root.query(await readFile("supabase/phase1_read_only_review.sql", "utf8"));
  });
  const {
    root,
    auth,
    service,
    product,
    buyer,
    buyer2,
    seller,
    seller2,
    buyerBiz,
    buyer2Biz,
    sellerBiz,
    seller2Biz,
  } = ctx;
  const stock = async (p) =>
    (await root.query("SELECT stock FROM products WHERE id=$1", [p])).rows[0].stock;
  const moves = async (p, type) =>
    (
      await root.query(
        "SELECT * FROM inventory_movements WHERE product_id=$1 AND ($2::text IS NULL OR movement_type=$2) ORDER BY created_at,id",
        [p, type ?? null],
      )
    ).rows;
  const adjust = (p, op, n, expected = null, key = randomUUID(), who = seller) =>
    auth(who, "SELECT adjust_product_stock($1,$2,$3,$4,$5,$6) result", [
      p,
      op,
      n,
      key,
      expected,
      "Physical inventory test",
    ]);
  const checkout = (items, key = randomUUID(), who = buyer, biz = buyerBiz) =>
    service("SELECT create_marketplace_orders($1,$2,$3,$4) result", [
      who,
      biz,
      JSON.stringify(items),
      key,
    ]);
  const order = async (key) =>
    (await root.query("SELECT order_ids FROM checkout_requests WHERE id=$1", [key])).rows[0]
      .order_ids;
  const cancel = (id, who = seller) =>
    auth(who, "SELECT transition_order($1,'cancelled','Test cancellation')", [id]);
  async function imported(p, mode, n, key = randomUUID()) {
    // Match the import's existing default dosage form explicitly, as the UI does.
    await root.query("UPDATE products SET form='Tablet' WHERE id=$1 AND form IS NULL", [p]);
    const original = (await root.query("SELECT * FROM products WHERE id=$1", [p])).rows[0];
    const payload = JSON.stringify([
      {
        name: original.name,
        form: original.form,
        brand: original.brand,
        pack_size: original.pack_size,
        price_ghs: "7.25",
        stock: n,
      },
    ]);
    const preview = (
      await auth(seller, "SELECT preview_wholesaler_import($1,$2,$3) result", [
        sellerBiz,
        payload,
        mode,
      ])
    ).rows[0].result;
    assert.equal(preview.rows[0].id, p);
    const args = [sellerBiz, payload, mode, preview.token, key];
    const run = () => auth(seller, "SELECT preview_wholesaler_import($1,$2,$3,$4,$5) result", args);
    await run();
    return run;
  }
  await t.test(
    "P1 manual add 80 + 20 = 100 with exactly one attributed movement and safe retry",
    async () => {
      const p = await product(80),
        key = randomUUID();
      await adjust(p, "add", 20, null, key);
      await adjust(p, "add", 20, null, key);
      assert.equal(await stock(p), 100);
      const m = await moves(p, "manual_add");
      assert.equal(m.length, 1);
      assert.deepEqual(
        [
          m[0].quantity_before,
          m[0].quantity_after,
          Number(m[0].quantity_delta),
          m[0].actor_id,
          m[0].wholesaler_id,
        ],
        [80, 100, 20, seller, sellerBiz],
      );
      await assert.rejects(adjust(p, "add", 21, null, key), /different data/);
    },
  );
  await t.test("P1 remove 100 - 15 = 85; excess and negative manipulation rejected", async () => {
    const p = await product(100);
    await assert.rejects(adjust(p, "remove", 101), /available/);
    await assert.rejects(adjust(p, "remove", -15), /quantity/);
    await adjust(p, "remove", 15);
    assert.equal(await stock(p), 85);
    assert.equal((await moves(p, "manual_remove")).length, 1);
  });
  await t.test("P1 reconcile 100 to 93 records -7 and rejects stale reconciliation", async () => {
    const p = await product(100);
    await adjust(p, "reconcile", 93, 100);
    assert.equal(Number((await moves(p, "manual_reconciliation"))[0].quantity_delta), -7);
    await assert.rejects(adjust(p, "reconcile", 100, 100), /changed since/);
    assert.equal(await stock(p), 93);
  });
  await t.test("P1 blank adjustment rejected; explicit zero reconciliation allowed", async () => {
    const p = await product(10);
    await assert.rejects(adjust(p, "add", null), /nonblank/);
    await assert.rejects(adjust(p, "add", ""), /integer/);
    assert.equal(await stock(p), 10);
    await adjust(p, "reconcile", 0, 10);
    assert.equal(await stock(p), 0);
  });
  await t.test(
    "P1 price edit preserves 80 after checkout; stale whole form and service stock DML denied",
    async () => {
      const p = await product(100);
      await checkout([{ productId: p, quantity: 20 }]);
      await auth(seller, "UPDATE products SET price_ghs=9 WHERE id=$1", [p]);
      assert.equal(await stock(p), 80);
      await assert.rejects(
        auth(seller, "UPDATE products SET price_ghs=9,stock=100 WHERE id=$1", [p]),
        /permission denied/,
      );
      await assert.rejects(
        service("UPDATE products SET stock=100 WHERE id=$1", [p]),
        /permission denied/,
      );
      assert.equal(await stock(p), 80);
    },
  );
  await t.test(
    "P1 cross tenant add/remove/reconcile denied and private ledger unreadable",
    async () => {
      const p = await product(10, seller2Biz);
      for (const op of ["add", "remove", "reconcile"])
        await assert.rejects(adjust(p, op, 1, 10), /access denied/);
      assert.equal(
        (await auth(seller, "SELECT * FROM inventory_movements WHERE product_id=$1", [p])).rowCount,
        0,
      );
      assert.equal(
        (await auth(seller2, "SELECT * FROM inventory_movements WHERE product_id=$1", [p]))
          .rowCount,
        1,
      );
    },
  );
  await t.test(
    "P1 ledger and opening balances cannot be forged, updated or deleted by clients",
    async () => {
      for (const table of [
        "inventory_movements",
        "inventory_opening_balances",
        "inventory_operation_context",
        "checkout_requests",
        "stock_adjustment_requests",
      ]) {
        await assert.rejects(auth(seller, `DELETE FROM ${table}`), /permission denied/);
      }
      await assert.rejects(
        auth(seller, "UPDATE inventory_movements SET quantity_delta=999"),
        /permission denied/,
      );
      await assert.rejects(
        auth(
          seller,
          "INSERT INTO inventory_operation_context(transaction_id,movement_type) VALUES(txid_current(),'manual_add')",
        ),
        /permission denied/,
      );
      await assert.rejects(root.query("UPDATE inventory_movements SET reason=reason"), /immutable/);
    },
  );
  await t.test(
    "P1 checkout lost response retry returns original result, orders and movement",
    async () => {
      const p = await product(100),
        key = randomUUID(),
        items = [{ productId: p, quantity: 20 }];
      const a = await checkout(items, key);
      const ids = await order(key);
      const b = await checkout(items, key);
      assert.deepEqual(a.rows, b.rows);
      assert.deepEqual(await order(key), ids);
      assert.equal(await stock(p), 80);
      const m = await moves(p, "checkout_deduction");
      assert.equal(m.length, 1);
      assert.equal(m[0].actor_id, buyer);
      assert.equal(m[0].order_id, ids[0]);
    },
  );
  await t.test(
    "P1 checkout payload mismatch and another business/user reusing key rejected",
    async () => {
      const p = await product(100),
        key = randomUUID();
      await checkout([{ productId: p, quantity: 2 }], key);
      await assert.rejects(checkout([{ productId: p, quantity: 3 }], key), /different data/);
      await assert.rejects(
        checkout([{ productId: p, quantity: 2 }], key, buyer2, buyer2Biz),
        /different data/,
      );
      assert.equal(await stock(p), 98);
    },
  );
  await t.test("P1 concurrent same-key double click produces one logical checkout", async () => {
    const p = await product(10),
      key = randomUUID(),
      items = [{ productId: p, quantity: 8 }];
    const results = await Promise.all([checkout(items, key), checkout(items, key)]);
    assert.deepEqual(results[0].rows, results[1].rows);
    assert.equal(await stock(p), 2);
    assert.equal((await order(key)).length, 1);
    assert.equal((await moves(p, "checkout_deduction")).length, 1);
  });
  await t.test(
    "P1 concurrent buyers 8 of 10: one success, stock 2, one movement and no failed request",
    async () => {
      const p = await product(10),
        a = randomUUID(),
        b = randomUUID();
      const results = await Promise.allSettled([
        checkout([{ productId: p, quantity: 8 }], a),
        checkout([{ productId: p, quantity: 8 }], b, buyer2, buyer2Biz),
      ]);
      assert.equal(results.filter((x) => x.status === "fulfilled").length, 1);
      assert.equal(await stock(p), 2);
      assert.equal((await moves(p, "checkout_deduction")).length, 1);
      assert.equal(
        (await root.query("SELECT * FROM checkout_requests WHERE id IN ($1,$2)", [a, b])).rowCount,
        1,
      );
    },
  );
  await t.test(
    "P1 cancellation restores once, links actual deduction and actor, replay adds no movement",
    async () => {
      const p = await product(100),
        key = randomUUID();
      await checkout([{ productId: p, quantity: 20 }], key);
      const [id] = await order(key);
      await cancel(id);
      await cancel(id);
      const m = await moves(p, "order_cancellation_restore");
      assert.equal(m.length, 1);
      assert.deepEqual(
        [m[0].order_id, m[0].actor_id, m[0].quantity_before, m[0].quantity_after],
        [id, seller, 80, 100],
      );
      assert.equal(await stock(p), 100);
      assert.equal((await moves(p, "checkout_deduction")).length, 1);
    },
  );
  await t.test("P1 multi supplier retry returns same whole order set", async () => {
    const p = await product(100),
      q = await product(100, seller2Biz),
      key = randomUUID();
    const items = [
      { productId: p, quantity: 20 },
      { productId: q, quantity: 10 },
    ];
    await checkout(items, key);
    const ids = await order(key);
    await checkout([...items].reverse(), key);
    assert.equal(ids.length, 2);
    assert.deepEqual(await order(key), ids);
    assert.equal(await stock(p), 80);
    assert.equal(await stock(q), 90);
    assert.equal(
      (await moves(p, "checkout_deduction")).length + (await moves(q, "checkout_deduction")).length,
      2,
    );
  });
  await t.test(
    "P1 multi supplier stock failure rolls back all orders/movements/request",
    async () => {
      const p = await product(100),
        q = await product(1, seller2Biz),
        key = randomUUID();
      await assert.rejects(
        checkout(
          [
            { productId: p, quantity: 20 },
            { productId: q, quantity: 10 },
          ],
          key,
        ),
        /available/,
      );
      assert.equal(await stock(p), 100);
      assert.equal((await moves(p, "checkout_deduction")).length, 0);
      assert.equal(
        (await root.query("SELECT * FROM checkout_requests WHERE id=$1", [key])).rowCount,
        0,
      );
    },
  );
  await t.test(
    "P1 movement failure rolls back checkout orders, stock and durable request",
    async () => {
      const p = await product(100),
        key = randomUUID();
      await root.query(`CREATE FUNCTION phase1_test_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.movement_type='checkout_deduction' THEN RAISE EXCEPTION 'Injected ledger failure'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER test_fail BEFORE INSERT ON inventory_movements FOR EACH ROW EXECUTE FUNCTION phase1_test_failure()`);
      const before = (await root.query("SELECT count(*) FROM orders")).rows[0].count;
      try {
        await assert.rejects(
          checkout([{ productId: p, quantity: 20 }], key),
          /Injected ledger failure/,
        );
      } finally {
        await root.query(
          "DROP TRIGGER test_fail ON inventory_movements; DROP FUNCTION phase1_test_failure()",
        );
      }
      assert.equal(await stock(p), 100);
      assert.equal((await root.query("SELECT count(*) FROM orders")).rows[0].count, before);
      assert.equal(
        (await root.query("SELECT * FROM checkout_requests WHERE id=$1", [key])).rowCount,
        0,
      );
      await checkout([{ productId: p, quantity: 20 }], key);
      assert.equal(await stock(p), 80);
    },
  );
  await t.test(
    "P1 ledger failure rolls back cancellation and its restoration evidence",
    async () => {
      const p = await product(100),
        key = randomUUID();
      await checkout([{ productId: p, quantity: 20 }], key);
      const [id] = await order(key);
      await root.query(`CREATE FUNCTION phase1_test_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.movement_type='order_cancellation_restore' THEN RAISE EXCEPTION 'Injected restore failure'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER test_fail BEFORE INSERT ON inventory_movements FOR EACH ROW EXECUTE FUNCTION phase1_test_failure()`);
      try {
        await assert.rejects(cancel(id), /Injected restore failure/);
      } finally {
        await root.query(
          "DROP TRIGGER test_fail ON inventory_movements; DROP FUNCTION phase1_test_failure()",
        );
      }
      assert.equal(await stock(p), 80);
      assert.equal(
        (await root.query("SELECT restored_at FROM order_stock_deductions WHERE order_id=$1", [id]))
          .rows[0].restored_at,
        null,
      );
      await cancel(id);
      assert.equal(await stock(p), 100);
      assert.equal((await moves(p, "order_cancellation_restore")).length, 1);
    },
  );
  await t.test("P1 ledger failure rolls back stock import and request completion", async () => {
    const p = await product(100);
    await root.query(`CREATE FUNCTION phase1_test_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.movement_type='import_add' THEN RAISE EXCEPTION 'Injected import failure'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER test_fail BEFORE INSERT ON inventory_movements FOR EACH ROW EXECUTE FUNCTION phase1_test_failure()`);
    const before = (await root.query("SELECT count(*) FROM product_import_runs")).rows[0].count;
    try {
      await assert.rejects(imported(p, "add", "25"), /Injected import failure/);
    } finally {
      await root.query(
        "DROP TRIGGER test_fail ON inventory_movements; DROP FUNCTION phase1_test_failure()",
      );
    }
    assert.equal(await stock(p), 100);
    assert.equal(
      (await root.query("SELECT count(*) FROM product_import_runs")).rows[0].count,
      before,
    );
  });
  await t.test("P1 concurrent atomic manual adds preserve both changes", async () => {
    const p = await product(80);
    await Promise.all([adjust(p, "add", 20), adjust(p, "add", 10)]);
    assert.equal(await stock(p), 110);
    assert.equal((await moves(p, "manual_add")).length, 2);
  });
  for (const [mode, value, expected, type, delta] of [
    ["add", "25", 125, "import_add", 25],
    ["replace", "25", 25, "import_replace", -75],
    ["replace", "125", 125, "import_replace", 25],
    ["details", "25", 100, null, 0],
    ["replace", null, 100, null, 0],
    ["add", null, 100, null, 0],
    ["details", null, 100, null, 0],
  ])
    await t.test(
      `P1 import ${mode} + ${value ?? "blank"} preserves semantics and replay evidence`,
      async () => {
        const p = await product(100);
        const replay = await imported(p, mode, value);
        await replay();
        assert.equal(await stock(p), expected);
        const m = (await moves(p)).filter((x) => x.movement_type.startsWith("import_"));
        assert.equal(m.length, type ? 1 : 0);
        if (type) {
          assert.equal(m[0].movement_type, type);
          assert.equal(Number(m[0].quantity_delta), delta);
          assert.equal(m[0].actor_id, seller);
          assert.ok(m[0].import_run_id);
        }
      },
    );
  await t.test("P1 a separate intentional add import adds again", async () => {
    const p = await product(100);
    await imported(p, "add", "25");
    await imported(p, "add", "25");
    assert.equal(await stock(p), 150);
    assert.equal((await moves(p, "import_add")).length, 2);
  });
  await t.test("P1 new blank import starts at zero without fabricated movement", async () => {
    const name = randomUUID(),
      payload = JSON.stringify([{ name, price_ghs: "2", stock: null }]);
    const preview = (
      await auth(seller, "SELECT preview_wholesaler_import($1,$2,'add') r", [sellerBiz, payload])
    ).rows[0].r;
    await auth(seller, "SELECT preview_wholesaler_import($1,$2,'add',$3,$4)", [
      sellerBiz,
      payload,
      preview.token,
      randomUUID(),
    ]);
    const p = (await root.query("SELECT id,stock FROM products WHERE name=$1", [name])).rows[0];
    assert.equal(p.stock, 0);
    assert.equal((await moves(p.id)).length, 0);
  });
  await t.test(
    "P1 opening plus recorded deltas reconciles every current product; stock constraint active",
    async () => {
      const mismatches =
        await root.query(`SELECT p.id FROM products p JOIN inventory_opening_balances b ON b.product_id=p.id
      LEFT JOIN inventory_movements m ON m.product_id=p.id GROUP BY p.id,b.quantity HAVING p.stock<>b.quantity+coalesce(sum(m.quantity_delta),0)`);
      assert.equal(mismatches.rowCount, 0);
      const p = await product(1);
      await assert.rejects(
        root.query("UPDATE products SET stock=-1 WHERE id=$1", [p]),
        /check constraint/,
      );
    },
  );
}
