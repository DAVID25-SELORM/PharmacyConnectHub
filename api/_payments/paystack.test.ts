import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { loadPaymentsConfig } from "./config";
import {
  PaystackProvider,
  ghsToPesewas,
  mapPaystackStatus,
  modeFromSecretKey,
  newPaymentReference,
  pesewasToGhs,
  verifyWebhookSignature,
} from "./paystack";
import { ProviderError } from "./types";

const SECRET = "sk_test_unit_test_key";
const sign = (body: string, secret = SECRET) =>
  createHmac("sha512", secret).update(body).digest("hex");

describe("money", () => {
  it("converts cedis to pesewas exactly", () => {
    expect(ghsToPesewas("100.00")).toBe(10000);
    expect(ghsToPesewas("12.34")).toBe(1234);
    expect(ghsToPesewas("0.5")).toBe(50);
    expect(ghsToPesewas("1999.99")).toBe(199999);
    expect(ghsToPesewas(7)).toBe(700);
    expect(ghsToPesewas(0.3)).toBe(30);
  });

  it("refuses anything that is not an exact amount of cedis and pesewas", () => {
    expect(() => ghsToPesewas(0.1 + 0.2)).toThrow();
    expect(() => ghsToPesewas("10.005")).toThrow();
    expect(() => ghsToPesewas("-5")).toThrow();
    expect(() => ghsToPesewas("1e3")).toThrow();
    expect(() => ghsToPesewas("")).toThrow();
    expect(() => ghsToPesewas("ten")).toThrow();
  });

  it("converts back", () => {
    expect(pesewasToGhs(10000)).toBe("100.00");
    expect(pesewasToGhs(5)).toBe("0.05");
    expect(pesewasToGhs(199999)).toBe("1999.99");
    expect(() => pesewasToGhs(1.5)).toThrow();
  });
});

describe("keys and references", () => {
  it("knows the mode of a key from its prefix and refuses anything else", () => {
    expect(modeFromSecretKey("sk_test_abc")).toBe("test");
    expect(modeFromSecretKey("sk_live_abc")).toBe("live");
    expect(() => modeFromSecretKey("pk_test_abc")).toThrow();
    expect(() => modeFromSecretKey("abc")).toThrow();
  });

  it("makes unique, URL-safe references that say their mode", () => {
    const a = newPaymentReference("test");
    const b = newPaymentReference("test");
    expect(a).not.toBe(b);
    expect(a).toMatch(/^dx-test-[0-9a-f-]{36}$/);
    expect(a).toMatch(/^[A-Za-z0-9.=-]{8,100}$/);
    expect(newPaymentReference("live")).toMatch(/^dx-live-/);
  });
});

describe("webhook signatures", () => {
  const body = JSON.stringify({ event: "charge.success", data: { id: 1, reference: "dx-test-1" } });

  it("accepts the signature of the exact bytes received", () => {
    expect(verifyWebhookSignature(body, sign(body), SECRET)).toBe(true);
    expect(verifyWebhookSignature(Buffer.from(body), sign(body).toUpperCase(), SECRET)).toBe(true);
  });

  it("refuses a tampered body, another key, a missing, short or non-hex signature", () => {
    expect(verifyWebhookSignature(body + " ", sign(body), SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, sign(body, "sk_test_other"), SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, undefined, SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, "", SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, sign(body).slice(0, 100), SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, "zz".repeat(64), SECRET)).toBe(false);
    expect(verifyWebhookSignature(body, sign(body), "")).toBe(false);
  });

  it("is computed over the raw bytes, not a re-serialised object", () => {
    const raw = '{"event":"charge.success",  "data":{"id":1}}';
    const reserialised = JSON.stringify(JSON.parse(raw));
    expect(verifyWebhookSignature(raw, sign(raw), SECRET)).toBe(true);
    expect(verifyWebhookSignature(reserialised, sign(raw), SECRET)).toBe(false);
  });
});

describe("status mapping", () => {
  it("maps Paystack's statuses to ours and never guesses", () => {
    expect(mapPaystackStatus("success")).toBe("success");
    expect(mapPaystackStatus("failed")).toBe("failed");
    expect(mapPaystackStatus("abandoned")).toBe("abandoned");
    for (const pending of ["pending", "ongoing", "processing", "queued"])
      expect(mapPaystackStatus(pending)).toBe("pending");
    expect(mapPaystackStatus("reversed")).toBe("unknown");
    expect(mapPaystackStatus(undefined)).toBe("unknown");
  });
});

describe("reading a notification", () => {
  const provider = new PaystackProvider({
    secretKey: SECRET,
    fetchImpl: (() => Promise.reject(new Error("no network"))) as unknown as typeof fetch,
  });
  const body = JSON.stringify({
    event: "charge.success",
    data: { id: 4099260516, reference: "dx-test-abc", domain: "test", status: "success" },
  });

  it("returns the event, its dedupe key, reference and mode once the signature is right", () => {
    const parsed = provider.parseWebhook(body, sign(body));
    expect(parsed).toEqual({
      ok: true,
      event: {
        event: "charge.success",
        dedupeKey: "charge.success:4099260516",
        reference: "dx-test-abc",
        domain: "test",
      },
    });
  });

  it("refuses a wrong signature before reading anything", () => {
    expect(provider.parseWebhook(body, "00")).toEqual({ ok: false, reason: "invalid_signature" });
    expect(provider.parseWebhook(body, undefined)).toEqual({
      ok: false,
      reason: "invalid_signature",
    });
  });

  it("refuses a correctly signed body that is not a notification", () => {
    const junk = "not json";
    expect(provider.parseWebhook(junk, sign(junk))).toEqual({ ok: false, reason: "invalid_json" });
    const noEvent = JSON.stringify({ data: {} });
    expect(provider.parseWebhook(noEvent, sign(noEvent))).toEqual({
      ok: false,
      reason: "no_event",
    });
  });

  it("still gives a stable dedupe key when the notification has no id or reference", () => {
    const bare = JSON.stringify({ event: "transfer.success", data: {} });
    const first = provider.parseWebhook(bare, sign(bare));
    const second = provider.parseWebhook(bare, sign(bare));
    expect(first.ok && second.ok && first.event.dedupeKey === second.event.dedupeKey).toBe(true);
  });
});

type Call = { url: string; init: RequestInit };
const stub = (responses: Array<{ status?: number; body: unknown }>) => {
  const calls: Call[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const next = responses.shift() ?? { body: {} };
    return new Response(JSON.stringify(next.body), {
      status: next.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
};

describe("talking to Paystack", () => {
  it("initializes with the amount in pesewas, GHS, our reference and the secret key", async () => {
    const { fetchImpl, calls } = stub([
      {
        body: {
          status: true,
          data: {
            authorization_url: "https://checkout.paystack.com/abc",
            access_code: "abc",
            reference: "dx-test-1",
          },
        },
      },
    ]);
    const provider = new PaystackProvider({ secretKey: SECRET, fetchImpl });
    const result = await provider.initialize({
      email: "buyer@example.com",
      amountMinor: 12345,
      reference: "dx-test-1",
      callbackUrl: "https://app.example/pay/return",
      metadata: { order_id: "o1" },
    });
    expect(result).toEqual({
      reference: "dx-test-1",
      authorizationUrl: "https://checkout.paystack.com/abc",
      accessCode: "abc",
    });
    expect(calls[0].url).toBe("https://api.paystack.co/transaction/initialize");
    expect(calls[0].init.method).toBe("POST");
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe(
      `Bearer ${SECRET}`,
    );
    expect(JSON.parse(calls[0].init.body as string)).toEqual({
      email: "buyer@example.com",
      amount: 12345,
      currency: "GHS",
      reference: "dx-test-1",
      callback_url: "https://app.example/pay/return",
      metadata: { order_id: "o1" },
    });
  });

  it("refuses to initialize a payment that is not a whole number of pesewas", async () => {
    const provider = new PaystackProvider({ secretKey: SECRET, fetchImpl: stub([]).fetchImpl });
    await expect(
      provider.initialize({
        email: "a@b.c",
        amountMinor: 10.5,
        reference: "dx-test-1",
        callbackUrl: "x",
      }),
    ).rejects.toThrow(/whole number/);
    await expect(
      provider.initialize({
        email: "a@b.c",
        amountMinor: 0,
        reference: "dx-test-1",
        callbackUrl: "x",
      }),
    ).rejects.toThrow();
  });

  it("verifies a payment and reads what the provider says", async () => {
    const { fetchImpl, calls } = stub([
      {
        body: {
          status: true,
          data: {
            id: 99,
            status: "success",
            reference: "dx-test-1",
            amount: 10000,
            currency: "GHS",
            channel: "mobile_money",
            fees: 150,
            paid_at: "2026-10-10T10:00:00Z",
            domain: "test",
          },
        },
      },
    ]);
    const provider = new PaystackProvider({ secretKey: SECRET, fetchImpl });
    const verified = await provider.verify("dx-test-1");
    expect(verified).toEqual({
      reference: "dx-test-1",
      status: "success",
      amountMinor: 10000,
      currency: "GHS",
      transactionId: "99",
      channel: "mobile_money",
      feeMinor: 150,
      failureReason: null,
      paidAt: "2026-10-10T10:00:00Z",
      domain: "test",
    });
    expect(calls[0].url).toBe("https://api.paystack.co/transaction/verify/dx-test-1");
  });

  it("reads a failed payment's reason", async () => {
    const { fetchImpl } = stub([
      {
        body: {
          status: true,
          data: {
            status: "failed",
            reference: "r",
            amount: 100,
            currency: "GHS",
            gateway_response: "Declined",
          },
        },
      },
    ]);
    const verified = await new PaystackProvider({ secretKey: SECRET, fetchImpl }).verify("r");
    expect(verified.status).toBe("failed");
    expect(verified.failureReason).toBe("Declined");
  });

  it("turns an HTTP error, a not-found and a network failure into a ProviderError", async () => {
    const notFound = new PaystackProvider({
      secretKey: SECRET,
      fetchImpl: stub([
        { status: 404, body: { status: false, message: "Transaction reference not found" } },
      ]).fetchImpl,
    });
    await expect(notFound.verify("nope")).rejects.toMatchObject({
      name: "ProviderError",
      options: { notFound: true },
    });
    const serverError = new PaystackProvider({
      secretKey: SECRET,
      fetchImpl: stub([{ status: 500, body: {} }]).fetchImpl,
    });
    await expect(serverError.verify("x")).rejects.toBeInstanceOf(ProviderError);
    const down = new PaystackProvider({
      secretKey: SECRET,
      fetchImpl: (() => Promise.reject(new Error("offline"))) as unknown as typeof fetch,
    });
    await expect(down.verify("x")).rejects.toThrow(/could not be reached/);
  });

  it("lists transactions for reconciliation", async () => {
    const { fetchImpl, calls } = stub([
      {
        body: {
          status: true,
          data: [
            {
              id: 1,
              reference: "a",
              status: "success",
              amount: 100,
              currency: "GHS",
              paid_at: "2026-10-10T00:00:00Z",
              channel: "card",
            },
            { id: 2, reference: "b", status: "abandoned", amount: 200, currency: "GHS" },
          ],
          meta: { page: 1, pageCount: 3 },
        },
      },
    ]);
    const result = await new PaystackProvider({ secretKey: SECRET, fetchImpl }).listTransactions({
      from: "2026-10-10",
      to: "2026-10-11",
    });
    expect(result.transactions.map((t) => [t.reference, t.status, t.amountMinor])).toEqual([
      ["a", "success", 100],
      ["b", "abandoned", 200],
    ]);
    expect(result.hasMore).toBe(true);
    expect(calls[0].url).toContain("/transaction?");
    expect(calls[0].url).toContain("perPage=100");
  });

  it("refuses a key that is not a Paystack secret key", () => {
    expect(() => new PaystackProvider({ secretKey: "pk_test_nope" })).toThrow();
  });
});

describe("payment settings", () => {
  it("is off unless a mode is chosen", () => {
    expect(loadPaymentsConfig({})).toMatchObject({ ok: false, status: 503 });
    expect(loadPaymentsConfig({ PAYMENTS_MODE: "off", PAYSTACK_SECRET_KEY: SECRET })).toMatchObject(
      { ok: false, status: 503 },
    );
  });

  it("needs a key", () => {
    expect(loadPaymentsConfig({ PAYMENTS_MODE: "test" })).toMatchObject({ ok: false, status: 503 });
  });

  it("refuses a key of the other mode, or one that is not a key", () => {
    expect(
      loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: "sk_live_abc" }),
    ).toMatchObject({ ok: false, status: 500 });
    expect(
      loadPaymentsConfig({
        PAYMENTS_MODE: "live",
        PAYSTACK_SECRET_KEY: "sk_test_abc",
        PAYMENTS_LIVE_ENABLED: "yes",
      }),
    ).toMatchObject({ ok: false, status: 500 });
    expect(
      loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: "oops" }),
    ).toMatchObject({ ok: false, status: 500 });
  });

  it("starts test mode with a test key", () => {
    expect(loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET })).toEqual({
      ok: true,
      config: { mode: "test", secretKey: SECRET },
    });
  });

  it("needs a second, explicit switch before live mode does anything", () => {
    const live = { PAYMENTS_MODE: "live", PAYSTACK_SECRET_KEY: "sk_live_abc" };
    expect(loadPaymentsConfig(live)).toMatchObject({ ok: false, status: 503 });
    expect(loadPaymentsConfig({ ...live, PAYMENTS_LIVE_ENABLED: "true" })).toMatchObject({
      ok: false,
      status: 503,
    });
    expect(loadPaymentsConfig({ ...live, PAYMENTS_LIVE_ENABLED: "yes" })).toMatchObject({
      ok: true,
    });
  });
});
