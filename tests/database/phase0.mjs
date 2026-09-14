import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readFile, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import EmbeddedPostgres from "embedded-postgres";

// Always creates a disposable LOCAL cluster. Never reads DATABASE_URL or Supabase secrets.
test("Phase 0 migrated PostgreSQL authorization and integrity", { timeout: 180000 }, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "drugxone-phase0-"));
  const cluster = new EmbeddedPostgres({
    databaseDir: join(dir, "db"),
    port: 55439,
    user: "postgres",
    password: randomUUID(),
    persistent: true,
    postgresFlags: ["-h", "127.0.0.1"],
    onLog: () => {},
    onError: console.error,
  });
  let root;
  const clients = [];
  try {
    await cluster.initialise();
    await cluster.start();
    root = cluster.getPgClient("postgres", "127.0.0.1");
    await root.connect();
    await root.query(`
      CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN BYPASSRLS;
      CREATE SCHEMA auth; CREATE SCHEMA storage;
      CREATE TABLE auth.users(id uuid PRIMARY KEY, email text UNIQUE, raw_user_meta_data jsonb DEFAULT '{}',
        raw_app_meta_data jsonb DEFAULT '{}', email_confirmed_at timestamptz, created_at timestamptz DEFAULT now());
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.role',true),'') $$;
      CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean);
      CREATE TABLE storage.objects(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),bucket_id text,name text);
      ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
      CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT string_to_array($1,'/') $$;
      GRANT USAGE ON SCHEMA public,auth,storage TO anon,authenticated,service_role;
      GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO anon,authenticated,service_role;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon,authenticated,service_role;
      ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon,authenticated,service_role;
    `);
    const seedUser = randomUUID();
    let legacyConflict;
    const files = (await readdir("supabase/migrations")).filter((f) => f.endsWith(".sql")).sort();
    for (const file of files) {
      // Historical seed migrations require an approved wholesaler. Supply synthetic data only.
      if (file.startsWith("20260419010000")) {
        await root.query(
          `INSERT INTO auth.users(id,email,raw_user_meta_data) VALUES($1,'migration-fixture@example.test',
          '{"role":"wholesaler","full_name":"Migration Fixture","phone":"0241234567"}')`,
          [seedUser],
        );
        await root.query(
          `INSERT INTO public.businesses(owner_id,type,name,verification_status) VALUES($1,'wholesaler','Synthetic migration fixture','approved')`,
          [seedUser],
        );
      }
      if (file.startsWith("20260914090000")) {
        const oldSupplier = (
          await root.query("SELECT id FROM businesses WHERE owner_id=$1 LIMIT 1", [seedUser])
        ).rows[0].id;
        const wrongBiz = (
          await root.query(
            "INSERT INTO businesses(owner_id,type,name,verification_status) VALUES($1,'pharmacy','Legacy bad fixture','approved') RETURNING id",
            [seedUser],
          )
        ).rows[0].id;
        const wrongProduct = (
          await root.query(
            "INSERT INTO products(wholesaler_id,name,price_ghs,stock) VALUES($1,'Legacy bad relationship',1,10) RETURNING id",
            [wrongBiz],
          )
        ).rows[0].id;
        legacyConflict = (
          await root.query(
            "INSERT INTO orders(pharmacy_id,wholesaler_id,total_ghs) VALUES($1,$2,-1) RETURNING id",
            [wrongBiz, oldSupplier],
          )
        ).rows[0].id;
        await root.query(
          "INSERT INTO order_items(order_id,product_id,product_name,quantity,unit_price_ghs) VALUES($1,$2,'Legacy duplicate',1,-1),($1,$2,'Legacy duplicate',2,-1)",
          [legacyConflict, wrongProduct],
        );
      }
      try {
        await root.query(await readFile(join("supabase/migrations", file), "utf8"));
      } catch (error) {
        throw new Error(`Migration ${file}: ${error.message}`, { cause: error });
      }
    }
    console.log(
      `Applied ${files.length} exact migration files to isolated PostgreSQL (synthetic historical seed prerequisite).`,
    );
    async function asRole(role, user, sql, params = []) {
      const c = cluster.getPgClient("postgres", "127.0.0.1");
      await c.connect();
      try {
        await c.query(`SET ROLE ${role}`);
        await c.query(
          "SELECT set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claim.role',$2,false)",
          [user ?? "", role],
        );
        return await c.query(sql, params);
      } finally {
        await c.end();
      }
    }
    const auth = (user, sql, params) => asRole("authenticated", user, sql, params);
    const service = (sql, params) => asRole("service_role", null, sql, params);
    async function signup(role, extra = {}) {
      const id = randomUUID();
      await root.query(
        "INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data) VALUES($1,$2,now(),$3)",
        [
          id,
          `${id}@example.test`,
          JSON.stringify({
            role,
            full_name: "Test Owner",
            phone: "0241234567",
            business_name: `Test ${id}`,
            ...extra,
          }),
        ],
      );
      return id;
    }
    const business = async (user) =>
      (await root.query("SELECT id FROM businesses WHERE owner_id=$1", [user])).rows[0].id;
    const approve = async (id) =>
      service("UPDATE businesses SET verification_status='approved' WHERE id=$1", [id]);
    const scalar = async (sql, params) => (await root.query(sql, params)).rows[0];
    const buyer = await signup("pharmacy"),
      buyer2 = await signup("pharmacy"),
      seller = await signup("wholesaler"),
      seller2 = await signup("wholesaler");
    const buyerBiz = await business(buyer),
      buyer2Biz = await business(buyer2),
      sellerBiz = await business(seller),
      seller2Biz = await business(seller2);
    await Promise.all([buyerBiz, buyer2Biz, sellerBiz, seller2Biz].map(approve));
    async function product(stock = 10, wholesaler = sellerBiz) {
      return (
        await root.query(
          "INSERT INTO products(wholesaler_id,name,price_ghs,stock) VALUES($1,$2,7.25,$3) RETURNING id",
          [wholesaler, randomUUID(), stock],
        )
      ).rows[0].id;
    }
    async function checkout(p, quantity = 3, who = buyer, biz = buyerBiz) {
      await service("SELECT create_marketplace_orders($1,$2,$3)", [
        who,
        biz,
        JSON.stringify([
          {
            productId: p,
            quantity,
            unit_price_ghs: 0.01,
            total_ghs: 0.01,
            wholesalerId: seller2Biz,
          },
        ]),
      ]);
      return (
        await root.query(
          "SELECT order_id FROM order_stock_deductions WHERE product_id=$1 ORDER BY order_id",
          [p],
        )
      ).rows[0].order_id;
    }
    const transition = (id, status, who = seller) =>
      auth(who, "SELECT transition_order($1,$2)", [id, status]);
    const stock = async (p) =>
      Number((await scalar("SELECT stock FROM products WHERE id=$1", [p])).stock);
    await t.test(
      "migration preserves suspect historical rows without silently repairing them",
      async () => {
        assert.equal(
          (await scalar("SELECT total_ghs::text FROM orders WHERE id=$1", [legacyConflict]))
            .total_ghs,
          "-1.00",
        );
        assert.equal(
          (
            await scalar("SELECT count(*)::int n FROM order_items WHERE order_id=$1", [
              legacyConflict,
            ])
          ).n,
          2,
        );
        assert.equal(
          (
            await scalar("SELECT count(*)::int n FROM order_stock_deductions WHERE order_id=$1", [
              legacyConflict,
            ])
          ).n,
          0,
        );
      },
    );
    await t.test(
      "read-only investigation queries execute against the migrated schema",
      async () => {
        await root.query(await readFile("supabase/phase0_read_only_review.sql", "utf8"));
      },
    );
    await t.test("first registered account receives no automatic administrator role", async () => {
      await root.query("BEGIN");
      try {
        await root.query("TRUNCATE auth.users CASCADE");
        const first = await signup("pharmacy");
        assert.equal((await scalar("SELECT count(*)::int n FROM auth.users")).n, 1);
        assert.equal(
          (
            await scalar(
              "SELECT count(*)::int n FROM user_roles WHERE user_id=$1 AND role='admin'",
              [first],
            )
          ).n,
          0,
        );
        assert.equal(
          (await scalar("SELECT count(*)::int n FROM platform_staff WHERE user_id=$1", [first])).n,
          0,
        );
      } finally {
        await root.query("ROLLBACK");
      }
    });
    await t.test("01 admin signup metadata cannot assign admin", async () => {
      const id = await signup("admin");
      assert.equal(
        (
          await scalar("SELECT count(*)::int n FROM user_roles WHERE user_id=$1 AND role='admin'", [
            id,
          ])
        ).n,
        0,
      );
    });
    await t.test("02 manipulated metadata cannot provision platform roles", async () => {
      const id = await signup("admin", {
        platform_role: "owner",
        is_platform_staff: true,
        is_staff_invite: true,
      });
      assert.equal(
        (await scalar("SELECT count(*)::int n FROM platform_staff WHERE user_id=$1", [id])).n,
        0,
      );
      assert.equal(
        (
          await scalar("SELECT count(*)::int n FROM user_roles WHERE user_id=$1 AND role='admin'", [
            id,
          ])
        ).n,
        0,
      );
    });
    await t.test("03 legitimate pharmacy signup", async () =>
      assert.equal(
        (await scalar("SELECT type FROM businesses WHERE id=$1", [buyerBiz])).type,
        "pharmacy",
      ),
    );
    await t.test("04 legitimate wholesaler signup", async () =>
      assert.equal(
        (await scalar("SELECT type FROM businesses WHERE id=$1", [sellerBiz])).type,
        "wholesaler",
      ),
    );
    await t.test("05 forged approved business insertion becomes pending", async () => {
      const r = await auth(
        buyer,
        "INSERT INTO businesses(owner_id,type,name,verification_status,verified_at,rejection_reason) VALUES($1,'pharmacy','Forged','approved',now(),'forged') RETURNING verification_status,verified_at,rejection_reason",
        [buyer],
      );
      assert.deepEqual(r.rows[0], {
        verification_status: "pending",
        verified_at: null,
        rejection_reason: null,
      });
    });
    await t.test("06 pharmacy cannot write wholesaler inventory or import", async () => {
      await assert.rejects(
        auth(buyer, "INSERT INTO products(wholesaler_id,name,price_ghs) VALUES($1,'Forbidden',1)", [
          buyerBiz,
        ]),
        /row-level security/,
      );
      await assert.rejects(
        auth(buyer, "SELECT preview_wholesaler_import($1,'[]','add')", [buyerBiz]),
        /approved wholesaler/,
      );
    });
    await t.test(
      "07 owner cannot self-approve",
      async () =>
        await assert.rejects(
          auth(buyer, "UPDATE businesses SET verification_status='rejected' WHERE id=$1", [
            buyerBiz,
          ]),
          /Only administrators/,
        ),
    );
    await t.test(
      "08 owner cannot change verification audit fields",
      async () =>
        await assert.rejects(
          auth(buyer, "UPDATE businesses SET verified_at=now()+interval '1 day' WHERE id=$1", [
            buyerBiz,
          ]),
          /Only administrators/,
        ),
    );
    await t.test(
      "09 tenant cannot modify global auth identity",
      async () =>
        await assert.rejects(
          auth(seller, "UPDATE auth.users SET email=$1 WHERE id=$2", [
            "attacker@example.test",
            buyer,
          ]),
          /permission denied/,
        ),
    );
    await t.test("10 tenant cannot attach existing account via table or legacy RPC", async () => {
      await assert.rejects(
        auth(
          seller,
          "INSERT INTO business_staff(business_id,user_id,role,status) VALUES($1,$2,'manager','active')",
          [sellerBiz, buyer],
        ),
        /permission denied/,
      );
      await assert.rejects(
        auth(seller, "SELECT add_business_staff_by_email($1,$2,'manager')", [
          sellerBiz,
          `${buyer}@example.test`,
        ]),
        /permission denied/,
      );
    });
    await t.test(
      "11 cross-business membership modification rejected",
      async () =>
        await assert.rejects(
          auth(seller, "UPDATE business_staff SET role='manager' WHERE business_id=$1", [
            seller2Biz,
          ]),
          /permission denied/,
        ),
    );
    await t.test(
      "12 direct buyer order insertion rejected",
      async () =>
        await assert.rejects(
          auth(buyer, "INSERT INTO orders(pharmacy_id,wholesaler_id) VALUES($1,$2)", [
            buyerBiz,
            sellerBiz,
          ]),
          /permission denied/,
        ),
    );
    const p = await product(10);
    const order = await checkout(p);
    await t.test(
      "13 direct buyer item insertion rejected",
      async () =>
        await assert.rejects(
          auth(
            buyer,
            "INSERT INTO order_items(order_id,product_id,product_name,quantity,unit_price_ghs) VALUES($1,$2,'Fake',1,0.01)",
            [order, p],
          ),
          /permission denied/,
        ),
    );
    await t.test("14 canonical checkout deducts stock with private evidence", async () => {
      assert.equal(await stock(p), 7);
      assert.equal(
        (await scalar("SELECT quantity FROM order_stock_deductions WHERE order_id=$1", [order]))
          .quantity,
        3,
      );
    });
    await t.test("15 fake monetary and supplier payload ignored", async () =>
      assert.deepEqual(
        await scalar("SELECT total_ghs::text,wholesaler_id FROM orders WHERE id=$1", [order]),
        { total_ghs: "21.75", wholesaler_id: sellerBiz },
      ),
    );
    await t.test("16 foreign supplier product rejected even for privileged insert", async () => {
      const other = await product(10, seller2Biz);
      await assert.rejects(
        root.query(
          "INSERT INTO order_items(order_id,product_id,product_name,quantity,unit_price_ghs) VALUES($1,$2,'Foreign',1,7.25)",
          [order, other],
        ),
        /must belong/,
      );
    });
    await t.test(
      "17-20 two concurrent buyers order 8 of stock 10; exactly one succeeds",
      async () => {
        const last = await product(10);
        const lock = cluster.getPgClient("postgres", "127.0.0.1");
        await lock.connect();
        clients.push(lock);
        await lock.query("BEGIN");
        await lock.query("SELECT id FROM products WHERE id=$1 FOR UPDATE", [last]);
        const args = (who) => [
          who,
          who === buyer ? buyerBiz : buyer2Biz,
          JSON.stringify([{ productId: last, quantity: 8 }]),
        ];
        const attempts = [
          service("SELECT create_marketplace_orders($1,$2,$3)", args(buyer)),
          service("SELECT create_marketplace_orders($1,$2,$3)", args(buyer2)),
        ];
        const results = Promise.allSettled(attempts);
        // Wait until both real database sessions contend on locks, not merely Promise scheduling.
        let waiting = 0;
        for (let n = 0; n < 100; n++) {
          waiting = (
            await scalar(
              "SELECT count(*)::int n FROM pg_stat_activity WHERE query LIKE 'SELECT create_marketplace_orders%' AND wait_event_type='Lock'",
            )
          ).n;
          if (waiting === 2) break;
          await new Promise((r) => setTimeout(r, 20));
        }
        assert.equal(waiting, 2, "both checkout sessions reached PostgreSQL locks");
        await lock.query("COMMIT");
        const r = await results;
        assert.equal(r.filter((x) => x.status === "fulfilled").length, 1);
        assert.equal(r.filter((x) => x.status === "rejected").length, 1);
        assert.equal(await stock(last), 2);
      },
    );
    await t.test("21 first cancellation restores exact deduction", async () => {
      await transition(order, "cancelled");
      assert.equal(await stock(p), 10);
    });
    await t.test("22 repeated cancellation is idempotent", async () => {
      await transition(order, "cancelled");
      assert.equal(await stock(p), 10);
    });
    await t.test("23 cancelled -> accepted -> cancelled rejected", async () => {
      await assert.rejects(transition(order, "accepted"), /Invalid order transition/);
      assert.equal(await stock(p), 10);
    });
    await t.test("24 delivered -> cancelled rejected", async () => {
      const q = await product();
      const o = await checkout(q);
      for (const state of ["accepted", "packed", "dispatched", "delivered"])
        await transition(o, state);
      await assert.rejects(transition(o, "cancelled"), /Invalid order transition/);
      assert.equal(await stock(q), 7);
      await auth(seller, "SELECT confirm_order_payment($1)", [o]);
      await assert.rejects(
        auth(seller, "SELECT confirm_order_payment($1)", [o]),
        /Only delivered unpaid/,
      );
    });
    await t.test("25 cancellation cannot change another supplier inventory", async () => {
      const q = await product(20, seller2Biz);
      const o = await checkout(q);
      await assert.rejects(transition(o, "cancelled", seller), /access denied/);
      assert.equal(await stock(q), 17);
      await transition(o, "cancelled", seller2);
      assert.equal(await stock(q), 20);
    });
    await t.test("legacy order cancellation fails closed without stock proof", async () => {
      const q = await product();
      const o = (
        await root.query(
          "INSERT INTO orders(pharmacy_id,wholesaler_id) VALUES($1,$2) RETURNING id",
          [buyerBiz, sellerBiz],
        )
      ).rows[0].id;
      await root.query(
        "INSERT INTO order_items(order_id,product_id,product_name,quantity,unit_price_ghs) VALUES($1,$2,'Legacy',4,7.25)",
        [o, q],
      );
      await assert.rejects(transition(o, "cancelled"), /no verified stock deduction/);
      assert.equal(await stock(q), 10);
    });
    await t.test("immutable parties/items and duplicate items rejected", async () => {
      await assert.rejects(
        root.query("UPDATE orders SET total_ghs=1 WHERE id=$1", [order]),
        /immutable/,
      );
      await assert.rejects(
        root.query("UPDATE order_items SET quantity=50 WHERE order_id=$1", [order]),
        /immutable/,
      );
      const q = await product();
      const o = await checkout(q);
      await assert.rejects(
        root.query(
          "INSERT INTO order_items(order_id,product_id,product_name,quantity,unit_price_ghs) VALUES($1,$2,'Duplicate',3,7.25)",
          [o, q],
        ),
        /Duplicate order product/,
      );
    });
    await t.test("direct seller order updates and impersonated checkout RPC rejected", async () => {
      await assert.rejects(
        auth(seller, "UPDATE orders SET status='accepted' WHERE id=$1", [order]),
        /permission denied/,
      );
      await assert.rejects(
        auth(seller, "SELECT create_marketplace_orders($1,$2,$3)", [buyer, buyerBiz, "[]"]),
        /permission denied/,
      );
    });
    await t.test("sensitive business identity changes reopen verification", async () => {
      await auth(seller, "UPDATE businesses SET license_number='changed' WHERE id=$1", [sellerBiz]);
      assert.equal(
        (await scalar("SELECT verification_status FROM businesses WHERE id=$1", [sellerBiz]))
          .verification_status,
        "pending",
      );
      await assert.rejects(
        auth(seller, "UPDATE businesses SET type='pharmacy' WHERE id=$1", [sellerBiz]),
        /cannot be changed/,
      );
    });
    await t.test("only invited verified account can activate pending membership", async () => {
      const invitee = await signup("pharmacy", { is_staff_invite: true });
      await service(
        "INSERT INTO business_staff(business_id,user_id,role,status) VALUES($1,$2,'assistant','pending')",
        [sellerBiz, invitee],
      );
      await assert.rejects(
        service("UPDATE business_staff SET status='active' WHERE business_id=$1 AND user_id=$2", [
          sellerBiz,
          invitee,
        ]),
        /must accept/,
      );
      await service(
        "UPDATE business_staff SET status='inactive' WHERE business_id=$1 AND user_id=$2",
        [sellerBiz, invitee],
      );
      await assert.rejects(
        service(
          "UPDATE business_staff SET status='active',joined_at=now() WHERE business_id=$1 AND user_id=$2",
          [sellerBiz, invitee],
        ),
        /must accept/,
      );
      await service(
        "UPDATE business_staff SET status='pending' WHERE business_id=$1 AND user_id=$2",
        [sellerBiz, invitee],
      );
      await auth(invitee, "SELECT accept_business_invitations()");
      assert.equal(
        (
          await scalar("SELECT status FROM business_staff WHERE business_id=$1 AND user_id=$2", [
            sellerBiz,
            invitee,
          ])
        ).status,
        "active",
      );
    });
    await t.test("simultaneous cancellation restores once", async () => {
      await approve(sellerBiz);
      const q = await product(10);
      const o = await checkout(q);
      const outcomes = await Promise.allSettled([
        transition(o, "cancelled"),
        transition(o, "cancelled"),
      ]);
      assert.equal(outcomes.filter((x) => x.status === "fulfilled").length, 2);
      assert.equal(await stock(q), 10);
    });
    await t.test("failed checkout rolls back all prior deductions and orders", async () => {
      const q = await product(10);
      const empty = await product(0);
      const before = (await scalar("SELECT count(*)::int n FROM orders")).n;
      await assert.rejects(
        service("SELECT create_marketplace_orders($1,$2,$3)", [
          buyer,
          buyerBiz,
          JSON.stringify([
            { productId: q, quantity: 3 },
            { productId: empty, quantity: 1 },
          ]),
        ]),
        /out of stock/,
      );
      assert.equal(await stock(q), 10);
      assert.equal((await scalar("SELECT count(*)::int n FROM orders")).n, before);
      assert.equal(
        (
          await scalar("SELECT count(*)::int n FROM order_stock_deductions WHERE product_id=$1", [
            q,
          ])
        ).n,
        0,
      );
    });
    await t.test("duplicate cart lines aggregate and restore exactly their deduction", async () => {
      const q = await product(20);
      await service("SELECT create_marketplace_orders($1,$2,$3)", [
        buyer,
        buyerBiz,
        JSON.stringify([
          { productId: q, quantity: 2 },
          { productId: q, quantity: 3 },
        ]),
      ]);
      const o = (
        await scalar("SELECT order_id FROM order_stock_deductions WHERE product_id=$1", [q])
      ).order_id;
      assert.equal(await stock(q), 15);
      await transition(o, "cancelled");
      assert.equal(await stock(q), 20);
      assert.equal(
        (await scalar("SELECT count(*)::int n FROM order_items WHERE order_id=$1", [o])).n,
        1,
      );
    });
    await t.test(
      "approved owners and managers retain legitimate product and import access",
      async () => {
        const result = await auth(
          seller,
          "INSERT INTO products(wholesaler_id,name,price_ghs,stock) VALUES($1,$2,2,10) RETURNING id",
          [sellerBiz, randomUUID()],
        );
        assert.equal(result.rows.length, 1);
        const manager = await signup("wholesaler", { is_staff_invite: true });
        await service(
          "INSERT INTO business_staff(business_id,user_id,role,status) VALUES($1,$2,'manager','pending')",
          [sellerBiz, manager],
        );
        await auth(manager, "SELECT accept_business_invitations()");
        await auth(manager, "UPDATE products SET price_ghs=3 WHERE id=$1", [result.rows[0].id]);
        const args = [sellerBiz, JSON.stringify([{ name: randomUUID(), price_ghs: 5, stock: 4 }])];
        const preview = await auth(
          manager,
          "SELECT preview_wholesaler_import($1,$2,'add') result",
          args,
        );
        assert.ok(preview.rows[0].result);
      },
    );
    await t.test("private identity and document replacement invalidate approval", async () => {
      await approve(sellerBiz);
      await auth(
        seller,
        "UPDATE business_private_contacts SET owner_full_name='Changed owner details' WHERE business_id=$1",
        [sellerBiz],
      );
      assert.equal(
        (await scalar("SELECT verification_status FROM businesses WHERE id=$1", [sellerBiz]))
          .verification_status,
        "pending",
      );
      await approve(sellerBiz);
      await auth(
        seller,
        "INSERT INTO license_documents(business_id,doc_type,storage_path) VALUES($1,'business_license','test/new-document')",
        [sellerBiz],
      );
      assert.equal(
        (await scalar("SELECT verification_status FROM businesses WHERE id=$1", [sellerBiz]))
          .verification_status,
        "pending",
      );
    });
    await t.test(
      "private order printing: buyer/seller ownership, RLS boundary, historical pricing and no writes",
      async () => {
        await approve(sellerBiz);
        const q = await product(12);
        await root.query(
          "UPDATE products SET brand='Recorded Brand',form='Tablet',pack_size='20 tablets' WHERE id=$1",
          [q],
        );
        await root.query(
          "UPDATE master_products SET generic_name='Recorded Generic',strength='5 mg' WHERE id=(SELECT product_id FROM wholesaler_products WHERE id=$1)",
          [q],
        );
        const own = await checkout(q, 2);
        const q2 = await product(12, seller2Biz);
        const other = await checkout(q2, 2, buyer2, buyer2Biz);
        await root.query(
          "UPDATE businesses SET phone='0241112222',public_email='buyer-real@example.test' WHERE id=$1",
          [buyerBiz],
        );
        await root.query(
          "UPDATE businesses SET phone='0243334444',public_email='seller-real@example.test' WHERE id=$1",
          [sellerBiz],
        );
        await root.query(
          "UPDATE products SET price_ghs=99,name='Changed catalogue name',brand='New Brand',form='Capsule',pack_size='40 capsules' WHERE id=$1",
          [q],
        );
        const before =
          await scalar(`SELECT jsonb_build_object('orders',(SELECT jsonb_agg(o) FROM orders o),
        'items',(SELECT jsonb_agg(i) FROM order_items i),'products',(SELECT jsonb_agg(p) FROM products p),
        'deductions',(SELECT jsonb_agg(d) FROM order_stock_deductions d),'history',(SELECT jsonb_agg(h) FROM order_status_history h),
        'audit',(SELECT count(*) FROM audit_logs),'notifications',(SELECT count(*) FROM notifications)) snapshot`);
        const print = async (user, biz, id) =>
          (await auth(user, "SELECT get_order_print($1,$2) result", [biz, id])).rows[0].result;
        const buyerPrint = await print(buyer, buyerBiz, own);
        const sellerPrint = await print(seller, sellerBiz, own);
        assert.deepEqual(buyerPrint, sellerPrint);
        assert.equal(buyerPrint.items[0].unit_price_ghs, "7.25");
        assert.equal(buyerPrint.total_ghs, "14.50");
        assert.equal(buyerPrint.items[0].brand, "Recorded Brand");
        assert.equal(buyerPrint.items[0].generic_name, "Recorded Generic");
        assert.equal(buyerPrint.items[0].strength, "5 mg");
        assert.equal(buyerPrint.items[0].dosage_form, "Tablet");
        assert.equal(buyerPrint.items[0].pack_size, "20 tablets");
        assert.notEqual(buyerPrint.items[0].product_name, "Changed catalogue name");
        assert.equal(buyerPrint.buyer.email, "buyer-real@example.test");
        assert.equal(buyerPrint.seller.email, "seller-real@example.test");
        assert.equal(
          buyerPrint.buyer.name,
          (await scalar("SELECT name FROM businesses WHERE id=$1", [buyerBiz])).name,
        );
        assert.equal(
          buyerPrint.seller.name,
          (await scalar("SELECT name FROM businesses WHERE id=$1", [sellerBiz])).name,
        );
        await assert.rejects(print(buyer, buyerBiz, other), /access denied/);
        await assert.rejects(print(buyer, buyer2Biz, other), /access denied/);
        await assert.rejects(print(seller, sellerBiz, other), /access denied/);
        await assert.rejects(print(seller, seller2Biz, other), /access denied/);
        await assert.rejects(print(buyer, sellerBiz, own), /access denied/);
        await assert.rejects(
          asRole("anon", null, "SELECT get_order_print($1,$2)", [buyerBiz, own]),
          /permission denied/,
        );
        await assert.rejects(
          auth(null, "SELECT get_order_print($1,$2)", [buyerBiz, own]),
          /access denied/,
        );
        const after =
          await scalar(`SELECT jsonb_build_object('orders',(SELECT jsonb_agg(o) FROM orders o),
        'items',(SELECT jsonb_agg(i) FROM order_items i),'products',(SELECT jsonb_agg(p) FROM products p),
        'deductions',(SELECT jsonb_agg(d) FROM order_stock_deductions d),'history',(SELECT jsonb_agg(h) FROM order_status_history h),
        'audit',(SELECT count(*) FROM audit_logs),'notifications',(SELECT count(*) FROM notifications)) snapshot`);
        assert.deepEqual(before, after);
        assert.equal(Object.hasOwn(buyerPrint, "pharmacy_id"), false);
        assert.equal(Object.hasOwn(buyerPrint.buyer, "owner_id"), false);
        assert.equal(Object.hasOwn(buyerPrint.items[0], "product_id"), false);
        const staff = await signup("pharmacy", { is_staff_invite: true });
        await service(
          "INSERT INTO business_staff(business_id,user_id,role,status) VALUES($1,$2,'assistant','pending')",
          [buyerBiz, staff],
        );
        await assert.rejects(print(staff, buyerBiz, own), /access denied/);
        await auth(staff, "SELECT accept_business_invitations()");
        assert.deepEqual(await print(staff, buyerBiz, own), buyerPrint);
        await service(
          "UPDATE business_staff SET status='inactive' WHERE business_id=$1 AND user_id=$2",
          [buyerBiz, staff],
        );
        await assert.rejects(print(staff, buyerBiz, own), /access denied/);
      },
    );
    await t.test("audit writer and deduction evidence cannot be forged by clients", async () => {
      await assert.rejects(
        auth(buyer, "SELECT write_audit_log('x','x','x',null,'x')"),
        /permission denied/,
      );
      await assert.rejects(
        auth(buyer, "UPDATE order_stock_deductions SET restored_at=null"),
        /permission denied/,
      );
    });
  } finally {
    for (const c of clients) await c.end();
    if (root) await root.end();
    await cluster.stop();
    console.log("Stopped isolated PostgreSQL. Temporary test cluster retained at " + dir);
  }
});
