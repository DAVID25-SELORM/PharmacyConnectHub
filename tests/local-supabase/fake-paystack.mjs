// A stand-in for Paystack, for local testing only (no real keys, no network). It speaks the small part of Paystack's API this
// system uses (initialize, verify) and serves a checkout page with "Pay" and "Decline" buttons; after the customer chooses, it
// redirects back to the callback address and (optionally) sends a correctly signed notification to a webhook address, the way
// Paystack does.
//
//   import { startFakePaystack } from "./fake-paystack.mjs";
//   const fake = await startFakePaystack({ secret: "sk_test_x", webhookUrl: "http://127.0.0.1:3001/api/payments/webhook" });
//   fake.baseUrl   -> give to the server as PAYSTACK_BASE_URL (it only accepts a local address, in test mode)
//   fake.payments  -> Map of reference -> { amount, email, callbackUrl, status, ... }
//   fake.complete(reference, "success" | "failed")   -> as if the customer finished on the checkout page
//
// Run on its own for browser testing:  node tests/local-supabase/fake-paystack.mjs --port 4010 --secret sk_test_x --webhook http://127.0.0.1:3001/api/payments/webhook
import { createHmac } from "node:crypto";
import http from "node:http";
import { fileURLToPath } from "node:url";

export async function startFakePaystack({ secret, port = 0, webhookUrl = null, webhookDelayMs = 0 } = {}) {
  if (!secret || !secret.startsWith("sk_test_")) throw new Error("the stand-in only accepts a test key");
  const payments = new Map();
  const calls = [];
  let nextId = 5000;
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    const send = (status, body, type = "application/json") => {
      res.statusCode = status;
      res.setHeader("content-type", type);
      res.end(typeof body === "string" ? body : JSON.stringify(body));
    };
    const readBody = async () => {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      return Buffer.concat(chunks).toString("utf8");
    };
    calls.push(`${req.method} ${url.pathname}`);
    try {
      if (url.pathname === "/transaction/initialize" && req.method === "POST") {
        if (req.headers.authorization !== `Bearer ${secret}`) return send(401, { status: false, message: "Invalid key" });
        const body = JSON.parse(await readBody());
        if (!Number.isInteger(body.amount) || body.amount <= 0 || !body.email || !body.reference) {
          return send(400, { status: false, message: "Invalid request" });
        }
        if (payments.has(body.reference)) return send(400, { status: false, message: "Duplicate Transaction Reference" });
        payments.set(body.reference, {
          id: ++nextId,
          amount: body.amount,
          currency: body.currency ?? "GHS",
          email: body.email,
          callbackUrl: body.callback_url,
          metadata: body.metadata ?? null,
          status: "abandoned",
          gatewayResponse: null,
        });
        return send(200, {
          status: true,
          message: "Authorization URL created",
          data: { authorization_url: `${baseUrl}/checkout/${encodeURIComponent(body.reference)}`, access_code: `ac_${nextId}`, reference: body.reference },
        });
      }
      const verify = /^\/transaction\/verify\/(.+)$/.exec(url.pathname);
      if (verify && req.method === "GET") {
        if (req.headers.authorization !== `Bearer ${secret}`) return send(401, { status: false, message: "Invalid key" });
        const reference = decodeURIComponent(verify[1]);
        const p = payments.get(reference);
        if (!p) return send(404, { status: false, message: "Transaction reference not found" });
        return send(200, {
          status: true,
          message: "Verification successful",
          data: {
            id: p.id,
            status: p.status,
            reference,
            amount: p.status === "success" ? (p.paidAmount ?? p.amount) : p.amount,
            currency: p.currency,
            channel: "card",
            fees: Math.round(p.amount * 0.0195),
            gateway_response: p.gatewayResponse ?? (p.status === "success" ? "Successful" : "Pending"),
            paid_at: p.status === "success" ? new Date().toISOString() : null,
            domain: "test",
          },
        });
      }
      const checkout = /^\/checkout\/(.+)$/.exec(url.pathname);
      if (checkout && req.method === "GET") {
        const reference = decodeURIComponent(checkout[1]);
        const p = payments.get(reference);
        if (!p) return send(404, "Unknown payment", "text/plain");
        return send(
          200,
          `<!doctype html><html><head><meta charset="utf-8"><title>Fake Paystack checkout</title></head><body style="font-family:sans-serif;max-width:420px;margin:60px auto">
<h2>Fake Paystack (test)</h2><p>Pay <strong data-testid="amount">GHS ${(p.amount / 100).toFixed(2)}</strong> to DrugXOne</p><p>${p.email}</p><p><code>${reference}</code></p>
<form method="post" action="/_complete/${encodeURIComponent(reference)}?result=success"><button id="pay" type="submit">Pay</button></form>
<form method="post" action="/_complete/${encodeURIComponent(reference)}?result=failed"><button id="decline" type="submit">Decline</button></form>
<form method="post" action="/_complete/${encodeURIComponent(reference)}?result=abandon"><button id="close" type="submit">Close without paying</button></form>
</body></html>`,
          "text/html",
        );
      }
      const complete = /^\/_complete\/(.+)$/.exec(url.pathname);
      if (complete && req.method === "POST") {
        const reference = decodeURIComponent(complete[1]);
        const p = payments.get(reference);
        if (!p) return send(404, "Unknown payment", "text/plain");
        const result = url.searchParams.get("result") ?? "success";
        await fake.complete(reference, result === "abandon" ? "abandoned" : result);
        const back = new URL(p.callbackUrl);
        back.searchParams.set("reference", reference);
        back.searchParams.set("trxref", reference);
        res.statusCode = 303;
        res.setHeader("location", back.toString());
        return res.end();
      }
      return send(404, { status: false, message: "Not found" });
    } catch (error) {
      return send(500, { status: false, message: String(error) });
    }
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  const fake = {
    baseUrl,
    payments,
    calls,
    secret,
    /** The customer finished on the checkout page. */
    async complete(reference, result) {
      const p = payments.get(reference);
      if (!p) throw new Error(`unknown reference ${reference}`);
      p.status = result;
      p.gatewayResponse = result === "failed" ? "Declined" : null;
      if (result === "success" && webhookUrl) {
        const body = JSON.stringify({ event: "charge.success", data: { id: p.id, reference, domain: "test", status: "success", amount: p.amount, currency: p.currency } });
        const send = () =>
          fetch(webhookUrl, {
            method: "POST",
            headers: { "content-type": "application/json", "x-paystack-signature": createHmac("sha512", secret).update(body).digest("hex") },
            body,
          }).catch(() => {});
        if (webhookDelayMs > 0) setTimeout(send, webhookDelayMs);
        else await send();
      }
    },
    /** Send a signed charge.success notification for a reference, whatever its state (for tests). */
    async notify(reference, url = webhookUrl, extra = {}) {
      const p = payments.get(reference);
      const body = JSON.stringify({ event: "charge.success", data: { id: p?.id ?? 1, reference, domain: "test", status: "success", ...extra } });
      return fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", "x-paystack-signature": createHmac("sha512", secret).update(body).digest("hex") },
        body,
      });
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
  return fake;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const arg = (name, fallback) => {
    const i = process.argv.indexOf(`--${name}`);
    return i > -1 ? process.argv[i + 1] : fallback;
  };
  const fake = await startFakePaystack({ secret: arg("secret", "sk_test_local_fake"), port: Number(arg("port", "4010")), webhookUrl: arg("webhook", null), webhookDelayMs: Number(arg("webhook-delay", "0")) });
  console.log(`fake Paystack listening on ${fake.baseUrl}`);
}
