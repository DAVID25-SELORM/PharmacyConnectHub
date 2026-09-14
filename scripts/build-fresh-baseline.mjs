import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import { createHash } from "node:crypto";
// Offline generator only. Never connects to a database or marks migration history.
export async function buildFreshBaseline() {
  const files = (await readdir("supabase/migrations")).filter((f) => f.endsWith(".sql")).sort();
  const excluded = new Set([
    "20260419010000_seed_wholesaler_catalog_cash.sql",
    "20260419011000_seed_wholesaler_catalog_retail_40th_quarter.sql",
    "20260421110000_remove_xtalcfc_from_ideal_pharmacy_team.sql",
  ]);
  const manifest = [];
  const parts = [];
  for (const file of files) {
    let sql = await readFile("supabase/migrations/" + file, "utf8");
    manifest.push({
      file,
      sha256: createHash("sha256").update(sql).digest("hex"),
      excluded: excluded.has(file),
    });
    if (excluded.has(file)) continue;
    if (
      file === "20260422171000_add_import_wholesaler_products_rpc.sql" ||
      file === "20260422170000_enforce_license_document_replacement.sql"
    ) {
      const offset = sql.indexOf("CREATE UNIQUE INDEX");
      if (offset < 0) throw new Error("Historical boundary changed: " + file);
      sql = sql.slice(offset);
    }
    if (file === "20260421020000_add_platform_staff.sql")
      sql = sql.replace(
        /WITH ranked_admins AS \([\s\S]*?ON CONFLICT \(user_id\) DO NOTHING;/,
        "-- Fresh baseline provisions no platform owner. Use a controlled reviewed bootstrap.",
      );
    parts.push(
      "-- Source: " + file + "\n" + sql.replace(/^BEGIN;\s*$/gm, "").replace(/^COMMIT;\s*$/gm, ""),
    );
  }
  const sql =
    `-- GENERATED FRESH DATABASE ONLY. Never use on an existing installation.\nBEGIN;\nDO $$ BEGIN IF to_regclass('public.businesses') IS NOT NULL THEN RAISE EXCEPTION 'Fresh baseline requires an empty application schema.'; END IF; END $$;\n` +
    parts.join("\n") +
    "\nCOMMIT;\n";
  await mkdir("supabase/baseline", { recursive: true });
  await writeFile("supabase/baseline/fresh-install.sql", sql);
  await writeFile("supabase/baseline/manifest.json", JSON.stringify(manifest, null, 2) + "\n");
  return sql;
}
if (process.argv[1]?.replaceAll("\\", "/").endsWith("scripts/build-fresh-baseline.mjs"))
  await buildFreshBaseline();
