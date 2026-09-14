import { execFileSync } from "node:child_process";
import { writeFile, mkdir, readFile, readdir } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
const cfg = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
if (new URL(cfg.API_URL).host !== "127.0.0.1:56321") throw new Error("Not staging");
const archive = execFileSync(
  "docker",
  ["exec", "supabase_storage_drugxone-isolated-rehearsal", "tar", "cf", "-", "-C", "/mnt", "."],
  { maxBuffer: 20 * 1024 * 1024 },
);
await writeFile(".tmp/staging-rehearsal/storage.tar", archive);
await mkdir(".tmp/staging-rehearsal/storage-restore", { recursive: true });
execFileSync("tar", [
  "xf",
  ".tmp/staging-rehearsal/storage.tar",
  "-C",
  ".tmp/staging-rehearsal/storage-restore",
]);
let files = 0;
async function count(dir) {
  for (const f of await readdir(dir, { withFileTypes: true })) {
    if (f.isDirectory()) await count(dir + "/" + f.name);
    else files++;
  }
}
await count(".tmp/staging-rehearsal/storage-restore");
const users = JSON.parse(await readFile(".tmp/staging-rehearsal/users.json", "utf8"));
const admin = createClient(cfg.API_URL, cfg.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const u = users.buyer2,
  c = createClient(cfg.API_URL, cfg.ANON_KEY, { auth: { persistSession: false } });
const link = await admin.auth.admin.generateLink({ type: "recovery", email: u.email });
if (link.error) throw link.error;
const verified = await c.auth.verifyOtp({
  token_hash: link.data.properties.hashed_token,
  type: "recovery",
});
if (verified.error) throw verified.error;
u.password = u.password + "New9!";
const changed = await c.auth.updateUser({ password: u.password });
if (changed.error) throw changed.error;
await c.auth.signOut();
await writeFile(".tmp/staging-rehearsal/users.json", JSON.stringify(users));
const login = await c.auth.signInWithPassword({ email: u.email, password: u.password });
if (login.error) throw login.error;
await c.auth.refreshSession();
await c.auth.signOut();
const result = {
  storage: {
    archiveBytes: archive.length,
    sha256: createHash("sha256").update(archive).digest("hex"),
    restoredFiles: files,
    note: "Extracted separately; not restored into a second Storage service",
  },
  recovery: {
    result: "PASS",
    steps: ["real recovery OTP", "different password accepted", "login", "refresh", "logout"],
  },
};
await writeFile(
  ".tmp/staging-rehearsal/storage-recovery-results.json",
  JSON.stringify(result, null, 2),
);
console.log(JSON.stringify(result));
