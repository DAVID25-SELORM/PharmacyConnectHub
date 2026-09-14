import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import pg from "pg";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.DB_URL).host !== "127.0.0.1:56322") throw new Error("Staging only");
const container = "supabase_db_drugxone-isolated-rehearsal",
  restore = "drugxone_restore_rehearsal_v2";
const started = Date.now();
const backup = execFileSync(
  "docker",
  ["exec", container, "pg_dump", "-U", "supabase_admin", "-d", "postgres", "-Fc"],
  { maxBuffer: 100 * 1024 * 1024 },
);
await writeFile(".tmp/staging-rehearsal/database.dump", backup);
execFileSync("docker", ["exec", container, "createdb", "-U", "supabase_admin", restore]);
execFileSync(
  "docker",
  [
    "exec",
    "-i",
    container,
    "pg_restore",
    "-U",
    "supabase_admin",
    "--no-owner",
    "--no-privileges",
    "-d",
    restore,
  ],
  { input: backup, maxBuffer: 10 * 1024 * 1024 },
);
const src = new pg.Client({ connectionString: cfg.DB_URL }),
  dst = new pg.Client({ connectionString: cfg.DB_URL.replace(/\/postgres$/, "/" + restore) });
await src.connect();
await dst.connect();
const checks = [];
for (const table of [
  "public.products",
  "public.orders",
  "public.order_items",
  "public.inventory_movements",
  "public.audit_logs",
  "public.license_documents",
  "auth.users",
  "storage.objects",
]) {
  const sql =
    "SELECT md5(coalesce(string_agg(row_to_json(t)::text,'' ORDER BY row_to_json(t)::text),'')) hash,count(*)::int count FROM " +
    table +
    " t";
  const a = (await src.query(sql)).rows[0],
    b = (await dst.query(sql)).rows[0];
  checks.push({ table, ...a, match: JSON.stringify(a) === JSON.stringify(b) });
}
await src.end();
await dst.end();
const report = {
  target: restore,
  seconds: (Date.now() - started) / 1000,
  bytes: backup.length,
  sha256: createHash("sha256").update(backup).digest("hex"),
  checks,
  note: "Same isolated cluster, logical data restore; not hosted PITR or full role/privilege recovery.",
};
await writeFile(".tmp/staging-rehearsal/restore-results.json", JSON.stringify(report, null, 2));
console.log(JSON.stringify(report));
