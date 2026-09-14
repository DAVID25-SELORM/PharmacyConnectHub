import { readFile, readdir, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
const manifest = JSON.parse(await readFile("supabase/baseline/manifest.json", "utf8"));
const mismatches = [];
for (const entry of manifest) {
  const hash = createHash("sha256")
    .update(await readFile("supabase/migrations/" + entry.file))
    .digest("hex");
  if (hash !== entry.sha256) mismatches.push(entry.file);
}
const privatePatterns = [
  ["private_key", /-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ["service_role_jwt", /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g],
  ["private_provider_key", /\b(?:sb_secret_|sk_live_|re_)[A-Za-z0-9_-]{24,}/],
];
const findings = [];
let scanned = 0;
for (const name of await readdir("dist/assets")) {
  if (!/\.(js|mjs|css|map)$/.test(name)) continue;
  scanned++;
  const text = await readFile("dist/assets/" + name, "utf8");
  for (const [key, re] of privatePatterns) {
    if (key === "service_role_jwt") {
      for (const match of text.match(re) ?? []) {
        try {
          if (JSON.parse(Buffer.from(match.split(".")[1], "base64url")).role === "service_role")
            findings.push({ file: name, key });
        } catch {}
      }
    } else if (re.test(text)) findings.push({ file: name, key });
  }
}
const report = {
  baselineSources: manifest.length,
  includedSources: manifest.filter((x) => !x.excluded).length,
  excludedSources: manifest.filter((x) => x.excluded).map((x) => x.file),
  hashMismatches: mismatches,
  browserAssetsScanned: scanned,
  privateCredentialFindings: findings,
  scope:
    "Pattern scan of built JS/MJS/CSS/maps; no secret values printed. Does not prove absence of all possible secret formats.",
};
await writeFile(".tmp/staging-rehearsal/local-preflight.json", JSON.stringify(report, null, 2));
console.log(JSON.stringify(report));
