// Run after: npm install --prefix .tmp/import-db --no-save @electric-sql/pglite
// Isolated PostgreSQL WASM database; never connects to a deployed Supabase project.
import { PGlite } from "../.tmp/import-db/node_modules/@electric-sql/pglite/dist/index.js";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
const db = new PGlite();
const owner = "00000000-0000-0000-0000-000000000001";
const business = "00000000-0000-0000-0000-000000000002";
await db.exec(`
  CREATE ROLE authenticated; CREATE SCHEMA auth;
  CREATE TABLE auth.users(id UUID PRIMARY KEY);
  INSERT INTO auth.users VALUES ('${owner}');
  CREATE FUNCTION auth.uid() RETURNS UUID LANGUAGE SQL AS $$ SELECT nullif(current_setting('test.user', true), '')::UUID $$;
  CREATE TABLE public.businesses(id UUID PRIMARY KEY, owner_id UUID, name TEXT, type TEXT, verification_status TEXT);
  INSERT INTO public.businesses VALUES ('${business}', '${owner}', 'Test wholesaler', 'wholesaler', 'approved');
  CREATE FUNCTION public.get_staff_role(UUID, UUID) RETURNS TEXT LANGUAGE SQL AS $$ SELECT nullif(current_setting('test.role', true), '') $$;
  CREATE TABLE public.products(id UUID PRIMARY KEY DEFAULT gen_random_uuid(), wholesaler_id UUID, name TEXT, brand TEXT, category TEXT, form TEXT, pack_size TEXT, price_ghs NUMERIC(10,2), stock INTEGER, image_hue INTEGER, active BOOLEAN DEFAULT TRUE);
  CREATE TABLE public.audit_logs(details JSONB);
  CREATE FUNCTION public.write_audit_log(TEXT, TEXT, TEXT, UUID, TEXT, JSONB) RETURNS VOID LANGUAGE SQL AS $$ INSERT INTO public.audit_logs VALUES ($6) $$;
  SELECT set_config('test.user', '${owner}', false);
`);
await db.exec(
  await readFile(
    new URL("../supabase/migrations/20260913090000_safe_wholesaler_import.sql", import.meta.url),
    "utf8",
  ),
);
const product = (stock = null, name = "Augmentin 625 mg", price = 20) => ({
  name,
  brand: "GSK",
  form: "Tablet",
  pack_size: "14",
  category: "Antibiotics",
  price_ghs: price,
  stock,
  source_row: 2,
});
let request = 0;
const id = () => `10000000-0000-0000-0000-${String(++request).padStart(12, "0")}`;
async function rpc(products, mode = "replace", token = null, requestId = null) {
  return (
    await db.query("SELECT public.preview_wholesaler_import($1, $2::JSONB, $3, $4, $5) result", [
      business,
      JSON.stringify(products),
      mode,
      token,
      requestId,
    ])
  ).rows[0].result;
}
async function apply(products, mode = "replace") {
  const preview = await rpc(products, mode);
  assert.equal(preview.issues.length, 0);
  return rpc(products, mode, preview.token, id());
}
const stock = async () =>
  (await db.query("SELECT stock FROM products ORDER BY name LIMIT 1")).rows[0].stock;
await rpc([product(10)]);
assert.equal(
  (await db.query("SELECT count(*)::INT n FROM products")).rows[0].n,
  0,
  "preview is read-only",
);
await apply([product(10)]);
await apply([product(null, "AUGMENTIN 625MG", 25)]);
assert.equal(await stock(), 10, "blank stock preserves inventory with normalized matching");
assert.equal((await db.query("SELECT count(*)::INT n FROM products")).rows[0].n, 1);
await apply([product(5)], "add");
assert.equal(await stock(), 15);
await apply([product(99)], "details");
assert.equal(await stock(), 15);
await apply([product(0)]);
assert.equal(await stock(), 0);
await apply([product(null)]);
assert.equal(await stock(), 0);
await apply([product(7)], "add");
const retryPreview = await rpc([product(3)], "add");
const retryId = id();
const first = await rpc([product(3)], "add", retryPreview.token, retryId);
const retry = await rpc([product(3)], "add", retryPreview.token, retryId);
assert.deepEqual(first, retry);
assert.equal(await stock(), 10, "retry must not double-add");
await assert.rejects(rpc([product(4)], "add", retryPreview.token, retryId), /different data/);
const stale = await rpc([product(30)]);
await db.exec("UPDATE products SET stock = stock - 2");
await assert.rejects(rpc([product(30)], "replace", stale.token, id()), /Inventory changed/);
assert.equal(await stock(), 8);
const duplicates = await rpc([product(1), { ...product(2, "Augmentin-625 MG"), source_row: 3 }]);
assert.match(duplicates.issues[0].message, /Duplicate/);
await assert.rejects(
  rpc(
    [product(1), { ...product(2, "Augmentin-625 MG"), source_row: 3 }],
    "replace",
    duplicates.token,
    id(),
  ),
  /Fix all/,
);
await apply([product(null, "New drug")]);
assert.equal(
  (await db.query("SELECT stock FROM products WHERE name = 'New drug'")).rows[0].stock,
  0,
);
await apply([product(100, "Details-only drug")], "details");
assert.equal(
  (await db.query("SELECT stock FROM products WHERE name = 'Details-only drug'")).rows[0].stock,
  0,
);
await db.exec("UPDATE products SET active = false WHERE name = 'Augmentin 625 mg'");
await apply([product(null)]);
assert.equal(
  (await db.query("SELECT active FROM products WHERE name = 'Augmentin 625 mg'")).rows[0].active,
  false,
);
const decimals = await db.query(
  "SELECT public.product_import_identity('Drug 2.5 mg', '', '', '') <> public.product_import_identity('Drug 25 mg', '', '', '') different",
);
assert.equal(decimals.rows[0].different, true);
for (const bad of [-1, 1.5, "unknown", 2147483648])
  assert.ok((await rpc([product(bad)])).issues.length);
await db.exec(`SELECT set_config('test.user', '00000000-0000-0000-0000-000000000099', false)`);
await assert.rejects(rpc([product(2)]), /owners and managers/);
await db.exec("SELECT set_config('test.role', 'manager', false)");
await rpc([product(2)]);
await db.exec(
  `SELECT set_config('test.user', '${owner}', false); UPDATE businesses SET verification_status = 'pending'`,
);
await assert.rejects(rpc([product(2)]), /approved wholesaler/);
await db.exec("UPDATE businesses SET verification_status = 'approved'");
const before = await db.query("SELECT * FROM products ORDER BY id");
const logsBefore = (await db.query("SELECT count(*)::INT n FROM audit_logs")).rows[0].n;
// Force a failure on the second write to demonstrate all-or-nothing rollback, including audit entries.
await db.exec("ALTER TABLE products ADD CONSTRAINT fail_test CHECK (name <> 'Fail write')");
await assert.rejects(
  apply([product(88), { ...product(3, "Fail write"), source_row: 3 }]),
  /fail_test/,
);
assert.deepEqual((await db.query("SELECT * FROM products ORDER BY id")).rows, before.rows);
assert.equal((await db.query("SELECT count(*)::INT n FROM audit_logs")).rows[0].n, logsBefore);
await db.exec(
  "INSERT INTO products(wholesaler_id, name, brand, form, pack_size, price_ghs, stock) SELECT wholesaler_id, 'AUGMENTIN625MG', brand, form, pack_size, price_ghs, stock FROM products WHERE name = 'Augmentin 625 mg'",
);
assert.match((await rpc([product(2)])).issues[0].message, /Multiple existing/);
assert.ok((await db.query("SELECT details FROM audit_logs LIMIT 1")).rows[0].details.after);

// Apply phase 2 to the populated legacy database, including a legacy collision.
await db.exec(`
  CREATE ROLE service_role;
  ALTER TABLE businesses ADD COLUMN city TEXT, ADD COLUMN region TEXT;
  CREATE FUNCTION public.has_role(UUID, TEXT) RETURNS BOOLEAN LANGUAGE SQL AS $$ SELECT FALSE $$;
`);
await db.exec(
  await readFile(
    new URL("../supabase/migrations/20260913100000_master_product_catalogue.sql", import.meta.url),
    "utf8",
  ),
);
const counts = (
  await db.query(
    "SELECT (SELECT count(*)::INT FROM products) legacy, (SELECT count(*)::INT FROM wholesaler_products) offers",
  )
).rows[0];
assert.equal(counts.legacy, counts.offers, "every legacy product must retain an offer");
const otherBusiness = "00000000-0000-0000-0000-000000000003";
await db.exec(
  `INSERT INTO businesses(id, owner_id, name, type, verification_status) VALUES ('${otherBusiness}', '${owner}', 'Supplier B', 'wholesaler', 'approved')`,
);
await db.query(
  "INSERT INTO products(wholesaler_id, name, brand, form, pack_size, category, price_ghs, stock) VALUES ($1, 'Augmentin 625MG', 'GSK', 'Tablet', '14', 'Antibiotics', 18, 40)",
  [otherBusiness],
);
assert.equal(
  (
    await db.query(
      "SELECT count(DISTINCT w.product_id)::INT n FROM wholesaler_products w JOIN products p ON p.id = w.id WHERE p.name ILIKE '%augmentin%'",
    )
  ).rows[0].n,
  1,
  "suppliers must share a master identity",
);
let catalogue = (await db.query("SELECT list_marketplace_catalogue() data")).rows[0].data;
assert.equal(catalogue.filter((entry) => entry.name.toLowerCase().includes("augmentin")).length, 1);
await db.exec(
  "UPDATE products SET price_ghs = 19 WHERE wholesaler_id = '00000000-0000-0000-0000-000000000003'",
);
assert.equal(
  Number(
    (
      await db.query("SELECT selling_price FROM wholesaler_products WHERE wholesaler_id = $1", [
        otherBusiness,
      ])
    ).rows[0].selling_price,
  ),
  19,
  "manual edits sync offers",
);
await db.exec(
  "UPDATE master_products SET generic_name = 'Reviewed generic' WHERE name ILIKE '%augmentin%'",
);
await db.exec(
  "UPDATE products SET price_ghs = 21 WHERE wholesaler_id = '00000000-0000-0000-0000-000000000003'",
);
assert.equal(
  (await db.query("SELECT generic_name FROM master_products WHERE name ILIKE '%augmentin%'"))
    .rows[0].generic_name,
  "Reviewed generic",
  "legacy writes must not overwrite curated identity",
);
await db.exec(
  "UPDATE businesses SET verification_status = 'pending' WHERE id = '00000000-0000-0000-0000-000000000003'",
);
catalogue = (await db.query("SELECT list_marketplace_catalogue() data")).rows[0].data;
assert.ok(
  catalogue.every((entry) => entry.offers.every((offer) => offer.wholesaler_id !== otherBusiness)),
  "unapproved suppliers are excluded",
);
await db.exec("UPDATE master_products SET active = false WHERE name ILIKE '%augmentin%'");
catalogue = (await db.query("SELECT list_marketplace_catalogue() data")).rows[0].data;
assert.ok(
  catalogue.every((entry) => !entry.name.toLowerCase().includes("augmentin")),
  "inactive master identities are excluded",
);
await db.exec("DELETE FROM products WHERE wholesaler_id = '00000000-0000-0000-0000-000000000003'");
assert.equal(
  (
    await db.query("SELECT count(*)::INT n FROM wholesaler_products WHERE wholesaler_id = $1", [
      otherBusiness,
    ])
  ).rows[0].n,
  0,
  "legacy deletion removes offer without deleting master",
);
await db.exec("SELECT set_config('test.user', '', false)");
assert.deepEqual(
  (await db.query("SELECT list_marketplace_catalogue() data")).rows[0].data,
  [],
  "catalogue requires authentication",
);
console.log(
  "Master catalogue PostgreSQL tests passed: backfill, grouping, synchronization, curated metadata, visibility and deletion.",
);
await db.close();
console.log(
  "Safe import PostgreSQL tests passed: preview, modes, blanks, normalization, collisions, retries, stale stock, permissions, audit and rollback.",
);
