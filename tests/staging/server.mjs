import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { build } from "esbuild";
import { createServer as createViteServer } from "vite";
const config = JSON.parse(await readFile(".tmp/staging-rehearsal/status.json", "utf8"));
const url = new URL(config.API_URL);
if (url.hostname !== "127.0.0.1" || url.port !== "56321")
  throw new Error("Refusing non-staging API");
process.env.SUPABASE_URL = config.API_URL;
process.env.SUPABASE_SERVICE_ROLE_KEY = config.SERVICE_ROLE_KEY;
process.env.VITE_SUPABASE_URL = config.API_URL;
process.env.VITE_SUPABASE_PUBLISHABLE_KEY = config.ANON_KEY;
process.env.SITE_URL = "http://127.0.0.1:4180";
delete process.env.RESEND_API_KEY;
const routes = [
  "orders/create",
  "orders/confirm-payment",
  "orders/send-receipt",
  "platform-staff/invite",
  "platform-staff/update",
  "platform-staff/resend-invite",
  "staff/invite",
  "staff/update",
];
const handlers = {};
for (const route of routes) {
  await build({
    entryPoints: ["api/" + route + ".ts"],
    outfile: ".tmp/staging-rehearsal/api/" + route + ".mjs",
    bundle: true,
    platform: "node",
    format: "esm",
    packages: "external",
  });
  handlers["/api/" + route] = (
    await import("../../.tmp/staging-rehearsal/api/" + route + ".mjs")
  ).default;
}
const vite = await createViteServer({
  server: { middlewareMode: true },
  envDir: ".tmp/staging-rehearsal",
  appType: "spa",
});
const server = createServer(async (req, res) => {
  const handler = handlers[new URL(req.url, "http://127.0.0.1").pathname];
  if (!handler) return vite.middlewares(req, res);
  let body = "";
  for await (const c of req) body += c;
  req.body = body ? JSON.parse(body) : {};
  res.status = (n) => {
    res.statusCode = n;
    return res;
  };
  res.json = (data) => {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(data));
  };
  try {
    await handler(req, res);
  } catch {
    res.status(500).json({ error: "Staging API error" });
  }
});
server.listen(4180, "127.0.0.1", () =>
  console.log("Isolated staging application listening on 127.0.0.1:4180; external email disabled"),
);
