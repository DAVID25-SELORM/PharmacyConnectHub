// Serves the real /api handlers on a local port for browser testing (Vite does not serve /api). Local use only: it refuses to run
// against anything but the local Supabase stack. Vite proxies /api here when started with DEV_API_PROXY=http://127.0.0.1:<port>.
//
//   source env.sh
//   PAYMENTS_MODE=test PAYSTACK_SECRET_KEY=sk_test_x PAYSTACK_BASE_URL=http://127.0.0.1:4010 SITE_URL=http://localhost:5173 \
//     npx tsx tests/local-supabase/dev-api-server.mjs 3001
import http from "node:http";
import { fileURLToPath } from "node:url";

const routes = {
  "/api/orders/create": "../../api/orders/create.ts",
  "/api/orders/confirm-payment": "../../api/orders/confirm-payment.ts",
  "/api/orders/send-receipt": "../../api/orders/send-receipt.ts",
  "/api/payments/initialize": "../../api/payments/initialize.ts",
  "/api/payments/verify": "../../api/payments/verify.ts",
  "/api/payments/webhook": "../../api/payments/webhook.ts",
  "/api/payments/reconcile": "../../api/payments/reconcile.ts",
  "/api/payments/admin-reverify": "../../api/payments/admin-reverify.ts",
  "/api/payments/admin-refund": "../../api/payments/admin-refund.ts",
  "/api/payments/admin-payout": "../../api/payments/admin-payout.ts",
};

export async function startDevApiServer(port = 0) {
  const api = process.env.API_URL;
  if (!api || !api.startsWith("http://127.0.0.1")) throw new Error("refusing to run: not a local stack");
  process.env.SUPABASE_URL = api;
  process.env.SUPABASE_PUBLISHABLE_KEY = process.env.ANON_KEY;
  process.env.SUPABASE_SERVICE_ROLE_KEY = process.env.SERVICE_ROLE_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  const handlers = {};
  for (const [path, file] of Object.entries(routes)) handlers[path] = (await import(file)).default;
  const server = http.createServer(async (req, res) => {
    const parsed = new URL(req.url, "http://x");
    const path = parsed.pathname;
    req.query = Object.fromEntries(parsed.searchParams.entries());
    const handler = handlers[path];
    if (!handler) {
      res.statusCode = 404;
      return res.end("not found");
    }
    // The shim Vercel adds. The webhook reads the raw stream itself, so its body is left alone; the others get parsed JSON.
    if (path !== "/api/payments/webhook") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const text = Buffer.concat(chunks).toString("utf8");
      try {
        req.body = text ? JSON.parse(text) : undefined;
      } catch {
        req.body = text;
      }
    }
    const shim = {
      status(code) { res.statusCode = code; return shim; },
      json(body) { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(body)); return shim; },
      send(body) { res.end(body); return shim; },
      setHeader(k, v) { res.setHeader(k, v); return shim; },
      end(b) { res.end(b); return shim; },
    };
    handler(req, shim).catch((error) => {
      console.error(error);
      res.statusCode = 500;
      res.end(String(error));
    });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return { server, baseUrl: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((resolve) => server.close(resolve)) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dev = await startDevApiServer(Number(process.argv[2] ?? "3001"));
  console.log(`dev API listening on ${dev.baseUrl}`);
}
