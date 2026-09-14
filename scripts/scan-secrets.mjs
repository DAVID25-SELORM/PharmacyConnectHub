import { execFileSync } from "node:child_process";
import { readFile, writeFile, mkdir } from "node:fs/promises";
const git = (args) =>
  execFileSync("git", ["-c", "safe.directory=D:/APPS/pharma-hub-connect", ...args], {
    encoding: "utf8",
    maxBuffer: 50 * 1024 * 1024,
  });
const patterns = [
  ["private_key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ["supabase_secret", /\bsb_secret_[A-Za-z0-9_-]{15,}/],
  ["provider_private_key", /\b(?:sk_live_|re_)[A-Za-z0-9_-]{24,}/],
  ["github_token", /\b(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}/],
  [
    "credential_assignment",
    /(?:password|smtp_pass|service_role_key|api_secret)\s*[:=]\s*["'][^"'\s]{16,}["']/i,
  ],
];
function scan(text, file, scope) {
  const findings = [];
  for (const [key, re] of patterns)
    if (re.test(text)) {
      const examples =
        key === "credential_assignment" &&
        [...text.matchAll(new RegExp(re.source, "ig"))].every((m) =>
          /["'](?:attacker-password|current-password|new-password|your-new-password|example-password|your-password-here)["']$/.test(
            m[0],
          ),
        );
      findings.push({
        file,
        key,
        status: examples ? "DOCUMENTED_EXAMPLE_OR_TEST" : "REVIEW",
        scope,
      });
    }
  for (const token of text.match(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g) ?? [])
    try {
      if (
        JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString()).role === "service_role"
      )
        findings.push({ file, key: "service_role_jwt", status: "REVIEW", scope });
    } catch {
      /* not a JWT */
    }
  return findings;
}
const files = git(["ls-files", "-z"]).split("\0").filter(Boolean);
const untracked = git(["ls-files", "--others", "--exclude-standard", "-z"])
  .split("\0")
  .filter(Boolean);
const findings = [];
for (const file of [...files, ...untracked]) {
  if (file === "package-lock.json") continue;
  try {
    findings.push(...scan(await readFile(file, "utf8"), file, "working-tree"));
  } catch {
    /* deleted file */
  }
}
const blobs = git(["rev-list", "--objects", "--all"]).trim().split("\n");
let scanned = 0;
for (const entry of blobs) {
  const [oid, ...path] = entry.split(" ");
  if (!path.length) continue;
  try {
    if (git(["cat-file", "-t", oid]).trim() !== "blob") continue;
    const size = Number(git(["cat-file", "-s", oid]));
    if (size > 2 * 1024 * 1024) continue;
    findings.push(...scan(git(["cat-file", "blob", oid]), path.join(" "), "reachable-git-history"));
    scanned++;
  } catch {
    /* binary/unreadable blob */
  }
}
await mkdir("docs", { recursive: true });
const result = {
  trackedFiles: files.length,
  untrackedFiles: untracked.length,
  historyBlobsScanned: scanned,
  scope:
    "Reachable refs, blobs <=2MiB; pattern scan, not a guarantee of absence. Values never printed.",
  findings,
};
await writeFile("docs/phase2-secret-scan.json", JSON.stringify(result, null, 2) + "\n");
console.log(JSON.stringify(result));
