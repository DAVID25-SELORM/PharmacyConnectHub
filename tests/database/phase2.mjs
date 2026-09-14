import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
export async function phase2Tests(
  t,
  { root, auth, service, product, buyer, buyerBiz, seller, sellerBiz, seller2, seller2Biz },
) {
  const newAccount = async () => {
    const id = randomUUID();
    await root.query(
      "INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data) VALUES($1,$2,now(),'{\"is_staff_invite\":true}')",
      [id, id + "@example.test"],
    );
    return id;
  };
  const owner = await newAccount(),
    admin = await newAccount();
  await root.query(
    "INSERT INTO platform_staff(user_id,role,status) VALUES($1,'owner','active'),($2,'admin','active')",
    [owner, admin],
  );
  await t.test(
    "P2 governance: admin cannot promote self, invite, demote owner or write roles",
    async () => {
      await assert.rejects(
        auth(admin, "UPDATE platform_staff SET role='owner' WHERE user_id=$1", [admin]),
        /permission denied/,
      );
      await assert.rejects(
        auth(admin, "SELECT manage_platform_member($1,'inactive')", [owner]),
        /Only the platform owner/,
      );
      await assert.rejects(
        auth(admin, "INSERT INTO user_roles(user_id,role) VALUES($1,'admin')", [seller]),
        /permission denied/,
      );
      await assert.rejects(
        auth(admin, "SELECT manage_platform_member($1,'pending')", [seller]),
        /Only the platform owner/,
      );
    },
  );
  await t.test(
    "P2 owner protected from upsert, deletion, deactivation and role changes",
    async () => {
      await assert.rejects(
        auth(owner, "SELECT manage_platform_member($1,'inactive')", [owner]),
        /Protected owner/,
      );
      await assert.rejects(
        root.query("UPDATE platform_staff SET role='admin' WHERE user_id=$1", [owner]),
        /immutable/,
      );
      await assert.rejects(
        service(
          "INSERT INTO platform_staff(user_id,role,status) VALUES($1,'admin','active') ON CONFLICT(user_id) DO UPDATE SET role='admin'",
          [owner],
        ),
        /permission denied/,
      );
      await assert.rejects(
        root.query("DELETE FROM platform_staff WHERE user_id=$1", [owner]),
        /owners cannot be removed/,
      );
    },
  );
  await t.test(
    "P2 owner invites pending admin; only verified invitee accepts; revoke/reactivate audited",
    async () => {
      const u = await newAccount();
      await auth(owner, "SELECT manage_platform_member($1,'pending')", [u]);
      await assert.rejects(
        auth(owner, "SELECT manage_platform_member($1,'active')", [u]),
        /must accept/,
      );
      await auth(u, "SELECT accept_platform_invitation()");
      assert.equal((await auth(u, "SELECT has_role($1,'admin') ok", [u])).rows[0].ok, true);
      await auth(owner, "SELECT manage_platform_member($1,'inactive')", [u]);
      assert.equal((await auth(u, "SELECT has_role($1,'admin') ok", [u])).rows[0].ok, false);
      await auth(owner, "SELECT manage_platform_member($1,'active')", [u]);
      assert.ok(
        (
          await root.query(
            "SELECT 1 FROM audit_logs WHERE performed_by=$1 AND record_type='platform_staff'",
            [owner],
          )
        ).rowCount > 0,
      );
    },
  );
  await t.test("P2 tenant account cannot acquire platform membership", async () => {
    await assert.rejects(
      auth(owner, "SELECT manage_platform_member($1,'pending')", [seller]),
      /remain separate/,
    );
    await assert.rejects(
      auth(seller, "SELECT manage_platform_member($1,'pending')", [admin]),
      /Only the platform owner/,
    );
  });
  await t.test(
    "P2 conservative identity preserves punctuation and strength; collapses case/space",
    async () => {
      const result = (
        await root.query(
          "SELECT product_import_identity(' Drug  A ',' BRAND ','Tablet',' 20 ') = product_import_identity('drug a','brand','tablet','20') same, product_import_identity('Drug 2.5mg','','Tablet','') <> product_import_identity('Drug 25mg','','Tablet','') distinct_strength, product_import_identity('A+B','','','') <> product_import_identity('AB','','','') distinct_punctuation",
        )
      ).rows[0];
      assert.deepEqual(result, { same: true, distinct_strength: true, distinct_punctuation: true });
      const name = randomUUID();
      await auth(
        seller,
        "INSERT INTO products(wholesaler_id,name,price_ghs,form) VALUES($1,$2,2,$3)",
        [sellerBiz, name + " drug", "Tablet"],
      );
      await assert.rejects(
        auth(seller, "INSERT INTO products(wholesaler_id,name,price_ghs,form) VALUES($1,$2,2,$3)", [
          sellerBiz,
          " " + name.toUpperCase() + "  DRUG ",
          "tablet",
        ]),
        /identity already exists/,
      );
      const preview = (
        await auth(seller, "SELECT preview_wholesaler_import($1,$2,'details') p", [
          sellerBiz,
          JSON.stringify([
            { name: " " + name.toUpperCase() + " DRUG ", form: "tablet", price_ghs: "3" },
          ]),
        ])
      ).rows[0].p;
      assert.equal(preview.rows[0].kind, "existing");
    },
  );
  await t.test(
    "P2 offer supplier cannot drift from underlying immutable product supplier",
    async () => {
      const p = await product();
      await assert.rejects(
        root.query("UPDATE wholesaler_products SET wholesaler_id=$1 WHERE id=$2", [seller2Biz, p]),
        /supplier/,
      );
      await assert.rejects(
        root.query("UPDATE products SET wholesaler_id=$1 WHERE id=$2", [seller2Biz, p]),
        /immutable/,
      );
    },
  );
  let doc, version;
  const path = seller + "/" + sellerBiz + "/" + randomUUID() + ".pdf";
  await t.test(
    "P2 private storage owner insert/read; cross-business/pharmacy reads and overwrite denied",
    async () => {
      await auth(seller, "INSERT INTO storage.objects(bucket_id,name) VALUES('licenses',$1)", [
        path,
      ]);
      assert.equal(
        (await auth(seller, "SELECT * FROM storage.objects WHERE name=$1", [path])).rowCount,
        1,
      );
      for (const u of [seller2, buyer]) {
        assert.equal(
          (await auth(u, "SELECT * FROM storage.objects WHERE name=$1", [path])).rowCount,
          0,
        );
        assert.equal(
          (await auth(u, "UPDATE storage.objects SET name=name WHERE name=$1", [path])).rowCount,
          0,
        );
        await assert.rejects(
          auth(u, "INSERT INTO storage.objects(bucket_id,name) VALUES('licenses',$1)", [
            path + "x.pdf",
          ]),
          /row-level security/,
        );
      }
      assert.equal(
        (await auth(seller, "DELETE FROM storage.objects WHERE name=$1", [path])).rowCount,
        0,
      );
      await assert.rejects(
        auth(seller, "INSERT INTO storage.objects(bucket_id,name) VALUES('licenses',$1)", [
          seller + "/" + sellerBiz + "/bad.exe",
        ]),
        /row-level security/,
      );
      const bucket = (await root.query("SELECT * FROM storage.buckets WHERE id='licenses'"))
        .rows[0];
      assert.equal(bucket.public, false);
      assert.equal(Number(bucket.file_size_limit), 10485760);
      assert.deepEqual(bucket.allowed_mime_types, ["application/pdf", "image/jpeg", "image/png"]);
    },
  );
  await t.test(
    "P2 document metadata cannot reference a missing object; content replacement requires rereview",
    async () => {
      await assert.rejects(
        auth(
          seller,
          "INSERT INTO license_documents(business_id,doc_type,storage_path) VALUES($1,'p2',$2)",
          [sellerBiz, path + "missing"],
        ),
        /existing object/,
      );
      const row = (
        await auth(
          seller,
          "INSERT INTO license_documents(business_id,doc_type,storage_path) VALUES($1,'p2',$2) RETURNING *",
          [sellerBiz, path],
        )
      ).rows[0];
      doc = row.id;
      version = row.version_id;
      assert.equal(
        (await root.query("SELECT verification_status FROM businesses WHERE id=$1", [sellerBiz]))
          .rows[0].verification_status,
        "pending",
      );
      await assert.rejects(
        auth(
          seller,
          "UPDATE license_documents SET reviewed_by=$1,review_status='approved' WHERE id=$2",
          [seller, doc],
        ),
        /permission denied/,
      );
      const versions = (
        await root.query("SELECT version_id FROM license_documents WHERE business_id=$1", [
          sellerBiz,
        ])
      ).rows.map((x) => x.version_id);
      await auth(admin, "SELECT review_business_evidence($1,'approved',$2)", [sellerBiz, versions]);
      const next = seller + "/" + sellerBiz + "/" + randomUUID() + ".pdf";
      await auth(seller, "INSERT INTO storage.objects(bucket_id,name) VALUES('licenses',$1)", [
        next,
      ]);
      await auth(seller, "UPDATE license_documents SET storage_path=$1 WHERE id=$2", [next, doc]);
      assert.equal(
        (await root.query("SELECT verification_status FROM businesses WHERE id=$1", [sellerBiz]))
          .rows[0].verification_status,
        "pending",
      );
      await assert.rejects(
        auth(admin, "SELECT review_business_evidence($1,'approved',$2)", [sellerBiz, versions]),
        /Evidence changed/,
      );
      assert.equal(
        (await root.query("SELECT * FROM license_document_versions WHERE version_id=$1", [version]))
          .rowCount,
        1,
      );
      const current = (
        await root.query("SELECT version_id FROM license_documents WHERE business_id=$1", [
          sellerBiz,
        ])
      ).rows.map((x) => x.version_id);
      await auth(admin, "SELECT review_business_evidence($1,'approved',$2)", [sellerBiz, current]);
    },
  );
  let paymentOrder;
  await t.test(
    "P2 concurrent payment confirmation has one transition and one durable receipt job",
    async () => {
      const p = await product();
      const key = randomUUID();
      await service("SELECT create_marketplace_orders($1,$2,$3,$4)", [
        buyer,
        buyerBiz,
        JSON.stringify([{ productId: p, quantity: 2 }]),
        key,
      ]);
      paymentOrder = (
        await root.query("SELECT order_ids FROM checkout_requests WHERE id=$1", [key])
      ).rows[0].order_ids[0];
      for (const status of ["accepted", "packed", "dispatched", "delivered"])
        await auth(seller, "SELECT transition_order($1,$2)", [paymentOrder, status]);
      await Promise.all([
        auth(seller, "SELECT confirm_order_payment($1)", [paymentOrder]),
        auth(seller, "SELECT confirm_order_payment($1)", [paymentOrder]),
      ]);
      await auth(seller, "SELECT confirm_order_payment($1)", [paymentOrder]);
      assert.equal(
        (await root.query("SELECT * FROM receipt_outbox WHERE order_id=$1", [paymentOrder]))
          .rowCount,
        1,
      );
      assert.equal(
        (await root.query("SELECT payment_confirmed_by FROM orders WHERE id=$1", [paymentOrder]))
          .rows[0].payment_confirmed_by,
        seller,
      );
    },
  );
  await t.test(
    "P2 receipt claim lease, failed retry, immutable payload and recorded-success suppression",
    async () => {
      const payload = { toEmail: "receipt@example.test" };
      const claim = async () =>
        (await service("SELECT claim_order_receipt($1,$2,$3) j", [paymentOrder, seller, payload]))
          .rows[0].j;
      const a = await claim();
      assert.equal(a.status, "claimed");
      assert.equal((await claim()).status, "sending");
      await service("SELECT finish_order_receipt($1,$2,NULL,$3)", [
        paymentOrder,
        a.claim_id,
        "test provider unavailable",
      ]);
      assert.equal(
        (await root.query("SELECT payment_status FROM orders WHERE id=$1", [paymentOrder])).rows[0]
          .payment_status,
        "paid",
      );
      const b = await claim();
      assert.deepEqual(b.payload, payload);
      await service("SELECT finish_order_receipt($1,$2,$3,NULL)", [
        paymentOrder,
        b.claim_id,
        "provider-test",
      ]);
      assert.equal((await claim()).status, "sent");
      await assert.rejects(
        service("SELECT claim_order_receipt($1,$2,$3)", [paymentOrder, seller2, payload]),
        /access denied/,
      );
    },
  );
  await t.test("P2 audit writer/table cannot be forged, historical records immutable", async () => {
    await assert.rejects(
      service("SELECT write_audit_log('fake','fake','fake',NULL,'fake')"),
      /permission denied/,
    );
    await assert.rejects(
      auth(seller, "INSERT INTO audit_logs(activity,record_type) VALUES('fake','fake')"),
      /permission denied/,
    );
    await assert.rejects(root.query("UPDATE audit_logs SET activity='fake'"), /immutable/);
  });
}
