import { createServer } from "node:http";
import { readFile, readdir } from "node:fs/promises";
import { resolve, extname } from "node:path";
import assert from "node:assert/strict";
import { chromium } from "@playwright/test";
const config = JSON.parse(await readFile("vercel.json", "utf8"));
const headers = Object.fromEntries(config.headers[0].headers.map((h) => [h.key, h.value]));
const server = createServer(async (req, res) => {
  try {
    const path = resolve(
      "dist",
      "." + (req.url === "/" ? "/index.html" : new URL(req.url, "http://localhost").pathname),
    );
    if (!path.startsWith(resolve("dist") + "\\")) throw new Error("Path");
    const data = await readFile(path);
    res.writeHead(200, {
      ...headers,
      "Content-Type":
        {
          ".html": "text/html",
          ".js": "application/javascript",
          ".mjs": "application/javascript",
          ".css": "text/css",
          ".svg": "image/svg+xml",
        }[extname(path)] ?? "application/octet-stream",
    });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(4182, "127.0.0.1", r));
const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  const page = await browser.newPage();
  await page.route("**/*", (r) =>
    new URL(r.request().url()).hostname === "127.0.0.1" ? r.continue() : r.abort(),
  );
  await page.goto("http://127.0.0.1:4182/");
  const worker = (await readdir("dist/assets")).find((n) => n.startsWith("product-import.worker-"));
  const result = await page.evaluate(async (worker) => {
    const parse = (file) =>
      new Promise((resolve, reject) => {
        const w = new Worker("/assets/" + worker, { type: "module" });
        const timer = setTimeout(() => {
          w.terminate();
          reject(new Error("timeout"));
        }, 15000);
        w.onmessage = (e) => {
          if (!("result" in e.data) && !("error" in e.data)) return;
          clearTimeout(timer);
          w.terminate();
          e.data.error ? reject(new Error(e.data.error)) : resolve(e.data.result);
        };
        w.onerror = (e) => {
          clearTimeout(timer);
          w.terminate();
          reject(new Error(e.message));
        };
        w.postMessage(file);
      });
    const pdf = (lines) => {
      let text = "%PDF-1.4\n";
      const content =
        "BT /F1 12 Tf 50 750 Td " +
        lines.map((s, i) => (i ? "0 -20 Td " : "") + "(" + s + ") Tj").join("\n") +
        " ET";
      const objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Length " + content.length + " >>\nstream\n" + content + "\nendstream",
      ];
      const offsets = [0];
      for (let i = 0; i < objects.length; i++) {
        offsets.push(text.length);
        text += i + 1 + " 0 obj\n" + objects[i] + "\nendobj\n";
      }
      const x = text.length;
      text +=
        "xref\n0 6\n0000000000 65535 f \n" +
        offsets
          .slice(1)
          .map((n) => String(n).padStart(10, "0") + " 00000 n \n")
          .join("") +
        "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n" +
        x +
        "\n%%EOF";
      return new File([text], "stock.pdf", { type: "application/pdf" });
    };
    const csv = await parse(new File(["name,price,stock\nDrug,10,25"], "stock.csv"));
    const good = await parse(pdf(["name | brand | price | stock", "Drug | Brand | 10 | 25"]));
    let ambiguous = false;
    try {
      await parse(pdf(["name brand price stock", "Drug Brand 10 25"]));
    } catch {
      ambiguous = true;
    }
    return { csv: csv.products[0].stock, pdf: good.products[0].stock, ambiguous };
  }, worker);
  assert.deepEqual(result, { csv: 25, pdf: 25, ambiguous: true });
  console.log("PASS production worker under CSP: CSV, explicit PDF, ambiguous PDF rejected");
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
}
