import { afterEach, expect, it, vi } from "vitest";
import { sendOrderReceiptEmail } from "./_order-receipts";
import { PLATFORM } from "../src/lib/platform";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});
it("receipt communications separate transaction parties and use official platform support", async () => {
  vi.stubEnv("RESEND_API_KEY", "test-only-key");
  vi.stubEnv("RECEIPT_FROM_EMAIL", "verified-sender@mailer.test");
  vi.stubEnv("RECEIPT_FROM_NAME", "Legacy sender name");
  vi.stubEnv("RECEIPT_REPLY_TO_EMAIL", "old-contact@example.test");
  const fetch = vi.fn().mockResolvedValue(new Response("{}", { status: 200 }));
  vi.stubGlobal("fetch", fetch);
  const result = await sendOrderReceiptEmail({
    toEmail: "buyer@registered.test",
    order: {
      orderId: "internal",
      orderNumber: "ORD-42",
      totalGhs: 14.5,
      deliveredAt: null,
      paidAt: null,
      paymentMethod: "cod",
      items: [{ productName: "Recorded medicine", quantity: 2, unitPriceGhs: 7.25 }],
      parties: {
        pharmacy: { name: "Real Buyer", city: null, region: null },
        wholesaler: { name: "Real Seller", city: null, region: null },
      },
    },
  });
  expect(result.ok).toBe(true);
  const body = JSON.parse(fetch.mock.calls[0][1].body);
  expect(body.from).toBe("DrugXone <verified-sender@mailer.test>");
  expect(body.reply_to).toBe(PLATFORM.email);
  for (const value of [
    PLATFORM.company,
    PLATFORM.contactPerson,
    PLATFORM.phone,
    PLATFORM.email,
    "Real Buyer",
    "Real Seller",
  ]) {
    expect(body.html).toContain(value);
    expect(body.text).toContain(value);
  }
  expect(body.html).not.toContain("Legacy sender name");
  expect(body.html).not.toContain("old-contact");
});
