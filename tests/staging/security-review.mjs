import { readFile, writeFile } from "node:fs/promises";
import pg from "pg";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.DB_URL).host !== "127.0.0.1:56322") throw new Error("Staging only");
const db = new pg.Client({ connectionString: cfg.DB_URL });
await db.connect();
const sql = `SELECT p.oid::regprocedure::text name,p.prosecdef,p.proconfig,has_function_privilege('anon',p.oid,'EXECUTE') anon,has_function_privilege('authenticated',p.oid,'EXECUTE') authenticated,has_function_privilege('service_role',p.oid,'EXECUTE') service FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prosecdef`;
const functions = (await db.query(sql)).rows;
const violations = [];
for (const f of functions) {
  if (!f.proconfig?.some((x) => x.startsWith("search_path=")))
    violations.push({ name: f.name, issue: "missing pinned search_path" });
  if (
    /^(create_marketplace_orders|change_business_staff|claim_order_receipt|finish_order_receipt|write_audit_log)\(/.test(
      f.name,
    ) &&
    (f.anon || f.authenticated)
  )
    violations.push({ name: f.name, issue: "client execution" });
}
const audit = (
  await db.query(
    "SELECT activity,count(*)::int count,count(performed_by)::int attributed FROM audit_logs GROUP BY activity ORDER BY activity",
  )
).rows;
const grants = (
  await db.query(
    "SELECT table_name,privilege_type,grantee FROM information_schema.role_table_grants WHERE table_schema='public' AND grantee IN ('anon','authenticated','service_role')",
  )
).rows;
const migration = (await db.query("SELECT version,name FROM supabase_migrations.schema_migrations"))
  .rows;
const bucket = (
  await db.query(
    "SELECT id,public,file_size_limit,allowed_mime_types FROM storage.buckets WHERE id='licenses'",
  )
).rows;
const counts = (
  await db.query(
    "SELECT (SELECT count(*) FROM auth.users)::int users,(SELECT count(*) FROM businesses WHERE type='wholesaler')::int wholesalers,(SELECT count(*) FROM businesses WHERE type='pharmacy')::int pharmacies,(SELECT count(*) FROM products)::int products,(SELECT count(*) FROM orders)::int orders",
  )
).rows[0];
await db.end();
const report = { violations, functions, grants, audit, migration, bucket, counts };
await writeFile(".tmp/staging-rehearsal/security-review.json", JSON.stringify(report, null, 2));
console.log(JSON.stringify({ violations, audit, migration, bucket, counts }));
