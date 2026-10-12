import { afterEach, expect, it, vi } from "vitest";
import { sendOrderReceiptEmail, type OrderReceiptPayload } from "./_order-receipts";
import { receiptDocumentModel } from "./_receipt-document";
import { businessDocumentHtml } from "../src/lib/business-document-html";
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";
const order: OrderReceiptPayload = {
  orderId: "test",
  orderNumber: "REC-001",
  totalGhs: 25,
  paidAt: "2026-10-12",
  deliveredAt: null,
  paymentMethod: "cod",
  items: [{ productName: "Recorded <medicine>", quantity: 2, unitPriceGhs: 12.5 }],
  parties: {
    pharmacy: { name: "Buyer", city: null, region: null },
    wholesaler: { name: "Supplier", city: null, region: null },
  },
  issuer: {
    name: "Snapshot supplier",
    address: "Historical address",
    branding: { footer_note: "Thank you" },
  },
};
afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});
it("escapes receipt markup and uses historical issuer and authoritative amount", () => {
  const model = receiptDocumentModel(order);
  const html = businessDocumentHtml(model, "javascript:alert(1)");
  expect(html).toContain("Recorded &lt;medicine&gt;");
  expect(html).not.toContain("javascript:");
  expect(html).toContain("Historical address");
  expect(model.summary).toContainEqual(["Amount received (GHS)", "25.00"]);
});
it("attaches a readable A4 receipt PDF to the mocked mail request without sending mail", async () => {
  vi.stubEnv("RESEND_API_KEY", "test");
  vi.stubEnv("RECEIPT_FROM_EMAIL", "test@example.invalid");
  vi.stubEnv("SUPABASE_URL", "");
  vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "");
  const mock = vi.fn().mockResolvedValue({ ok: true });
  vi.stubGlobal("fetch", mock);
  expect(await sendOrderReceiptEmail({ toEmail: "test@example.invalid", order })).toEqual({
    ok: true,
  });
  expect(mock).toHaveBeenCalledTimes(1);
  const body = JSON.parse(mock.mock.calls[0][1].body);
  const task = getDocument({
    data: new Uint8Array(Buffer.from(body.attachments[0].content, "base64")),
    useSystemFonts: true,
  });
  const doc = await task.promise;
  const page = await doc.getPage(1);
  expect(page.view[2]).toBeCloseTo(595.28, 1);
  const text = (await page.getTextContent()).items.map((i) => ("str" in i ? i.str : "")).join(" ");
  expect(text).toContain("Snapshot supplier");
  expect(text).toContain("25.00");
  expect(text).toContain("REC-001");
  await task.destroy();
});
