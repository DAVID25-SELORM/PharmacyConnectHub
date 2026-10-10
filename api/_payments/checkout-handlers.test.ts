import type { VercelRequest, VercelResponse } from "@vercel/node";
import { describe, expect, it } from "vitest";
import { createInitializeHandler, createVerifyHandler } from "./checkout-handlers";
import { loadPaymentsConfig } from "./config";
import { PaystackProvider } from "./paystack";
import { paymentReturnUrl } from "./return-url";
import type { RpcFn } from "./webhook-handler";

const SECRET = "sk_test_unit_test_key";
const ORDER = "11111111-2222-4333-8444-555555555555";
const USER = "99999999-2222-4333-8444-555555555555";

type RpcCall = { fn: string; args: Record<string, unknown> };
type RpcAnswer = { data: unknown; error: { message: string } | null };

function setup(
  kind: "initialize" | "verify",
  options: {
    config?: ReturnType<typeof loadPaymentsConfig>;
    method?: string;
    authorization?: string | null;
    userId?: string | null;
    body?: unknown;
    rpc?: (call: RpcCall) => RpcAnswer | undefined;
    paystack?: Record<string, { status?: number; body: unknown } | "offline">;
    initializeAnswer?: { status?: number; body: unknown } | "offline";
    returnUrl?: string | null;
    noRpc?: boolean;
  } = {},
) {
  const rpcCalls: RpcCall[] = [];
  const providerCalls: { url: string; init?: RequestInit }[] = [];
  const logs: string[] = [];
  const fetchImpl = (async (url: string, init?: RequestInit) => {
    providerCalls.push({ url, init });
    if (url.endsWith("/transaction/initialize")) {
      const a = options.initializeAnswer ?? {
        body: {
          status: true,
          data: {
            authorization_url: "https://checkout.paystack.test/abc",
            access_code: "ac_abc",
            reference: "x",
          },
        },
      };
      if (a === "offline") throw new Error("offline");
      return new Response(JSON.stringify(a.body), { status: a.status ?? 200 });
    }
    const ref = decodeURIComponent(url.split("/transaction/verify/")[1] ?? "");
    const a = options.paystack?.[ref];
    if (a === "offline") throw new Error("offline");
    if (!a)
      return new Response(JSON.stringify({ status: false, message: "not found" }), { status: 404 });
    return new Response(JSON.stringify(a.body), { status: a.status ?? 200 });
  }) as unknown as typeof fetch;
  const deps = {
    loadConfig: () =>
      options.config ?? loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
    createProvider: (config: { secretKey: string }) =>
      new PaystackProvider({ secretKey: config.secretKey, fetchImpl }),
    createRpc: () =>
      options.noRpc
        ? null
        : (((fn, args) => {
            const call = { fn, args };
            rpcCalls.push(call);
            const answer = options.rpc?.(call);
            if (answer) return Promise.resolve(answer);
            if (fn === "begin_order_payment" || fn === "begin_order_topup")
              return Promise.resolve({
                data: {
                  reused: false,
                  attempt_id: "att-1",
                  reference: args.p_reference,
                  amount_ghs: 100,
                  amount_minor: 10000,
                  email: "po@zz.test",
                  order_number: "ORD-1",
                },
                error: null,
              });
            if (fn === "record_attempt_authorization")
              return Promise.resolve({ data: true, error: null });
            return Promise.resolve({ data: null, error: null });
          }) as RpcFn),
    authenticate: async () => (options.userId === undefined ? USER : options.userId),
    returnUrl: (orderId: string, purpose?: string) =>
      options.returnUrl === undefined
        ? `https://app.test/pay/return?order=${orderId}${purpose === "top_up" ? "&purpose=top_up" : ""}`
        : options.returnUrl,
    log: (m: string) => logs.push(m),
  };
  const handler = kind === "initialize" ? createInitializeHandler(deps) : createVerifyHandler(deps);
  const headers: Record<string, string> = {};
  if (options.authorization !== null)
    headers.authorization = options.authorization ?? "Bearer token";
  const req = {
    method: options.method ?? "POST",
    headers,
    body: options.body === undefined ? { orderId: ORDER } : options.body,
  } as unknown as VercelRequest;
  let status = 0;
  let payload: unknown;
  const res = {
    status(code: number) {
      status = code;
      return res;
    },
    json(value: unknown) {
      payload = value;
      return res;
    },
  } as unknown as VercelResponse;
  return {
    run: async () => {
      await handler(req, res);
      return { status, payload: payload as Record<string, unknown> };
    },
    rpcCalls,
    providerCalls,
    logs,
  };
}

const verifyBody = (reference: string, extra: Record<string, unknown> = {}) => ({
  status: true,
  data: {
    id: 1,
    status: "success",
    reference,
    amount: 10000,
    currency: "GHS",
    channel: "card",
    fees: 150,
    domain: "test",
    ...extra,
  },
});

describe("common refusals", () => {
  for (const kind of ["initialize", "verify"] as const) {
    it(`${kind}: accepts only POST`, async () => {
      expect((await setup(kind, { method: "GET" }).run()).status).toBe(405);
    });
    it(`${kind}: does nothing while online payments are off`, async () => {
      const s = setup(kind, { config: loadPaymentsConfig({}) });
      expect((await s.run()).status).toBe(503);
      expect(s.rpcCalls).toHaveLength(0);
      expect(s.providerCalls).toHaveLength(0);
    });
    it(`${kind}: needs a signed-in user`, async () => {
      expect((await setup(kind, { authorization: null }).run()).status).toBe(401);
      expect((await setup(kind, { userId: null }).run()).status).toBe(401);
    });
    it(`${kind}: needs a real order id`, async () => {
      for (const body of [{}, { orderId: "nope" }, { orderId: 5 }, null]) {
        const s = setup(kind, { body });
        expect((await s.run()).status).toBe(400);
        expect(s.rpcCalls).toHaveLength(0);
      }
    });
    it(`${kind}: reports a missing database configuration`, async () => {
      expect((await setup(kind, { noRpc: true }).run()).status).toBe(500);
    });
  }
});

describe("starting a payment", () => {
  it("asks the database for the attempt and the provider for a page, and returns only the page address", async () => {
    const s = setup("initialize");
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toEqual({
      authorizationUrl: "https://checkout.paystack.test/abc",
      reference: expect.stringMatching(/^dx-test-/),
      resumed: false,
    });
    const begin = s.rpcCalls.find((c) => c.fn === "begin_order_payment")!;
    expect(begin.args).toMatchObject({
      p_caller_id: USER,
      p_order_id: ORDER,
      p_provider: "paystack",
      p_mode: "test",
    });
    const sent = JSON.parse(String(s.providerCalls[0].init?.body));
    expect(sent).toMatchObject({
      email: "po@zz.test",
      amount: 10000,
      currency: "GHS",
      callback_url: `https://app.test/pay/return?order=${ORDER}`,
      reference: begin.args.p_reference,
    });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "begin_order_payment",
      "prepare_attempt_for_provider",
      "record_attempt_authorization",
    ]);
  });

  it("asks the database for the last check before the provider, and sends nothing to the provider without a split when none is set", async () => {
    const s = setup("initialize");
    await s.run();
    const prepare = s.rpcCalls.find((c) => c.fn === "prepare_attempt_for_provider")!;
    expect(prepare.args).toEqual({ p_attempt_id: "att-1" });
    const sent = JSON.parse(String(s.providerCalls[0].init?.body));
    expect(sent).not.toHaveProperty("subaccount");
    expect(sent).not.toHaveProperty("transaction_charge");
    expect(sent).not.toHaveProperty("bearer");
  });

  it("splits the payment as the database says: the supplier's account, the platform's share in pesewas, and who bears the fee", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "prepare_attempt_for_provider"
          ? {
              data: {
                split: true,
                subaccount: "ACCT_abc",
                charge_minor: 250,
                bearer: "subaccount",
              },
              error: null,
            }
          : undefined,
    });
    expect((await s.run()).status).toBe(200);
    const sent = JSON.parse(String(s.providerCalls[0].init?.body));
    expect(sent).toMatchObject({
      subaccount: "ACCT_abc",
      transaction_charge: 250,
      bearer: "subaccount",
    });
    expect(sent.amount).toBe(10000);
  });

  it("a platform share of nothing is still stated", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "prepare_attempt_for_provider"
          ? {
              data: { split: true, subaccount: "ACCT_abc", charge_minor: 0, bearer: "account" },
              error: null,
            }
          : undefined,
    });
    await s.run();
    expect(JSON.parse(String(s.providerCalls[0].init?.body))).toMatchObject({
      transaction_charge: 0,
      bearer: "account",
    });
  });

  it("when the last check refuses (over the limit, supplier not ready), nothing is sent to the provider, the attempt is closed and the reason is given plainly", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "prepare_attempt_for_provider"
          ? {
              data: null,
              error: {
                message:
                  "This supplier cannot receive online payments yet. Please arrange another way to pay this order.",
              },
            }
          : undefined,
    });
    const r = await s.run();
    expect(r.status).toBe(400);
    expect(r.payload.error).toMatch(/cannot receive online payments yet/);
    expect(s.providerCalls).toHaveLength(0);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "begin_order_payment",
      "prepare_attempt_for_provider",
      "fail_payment_attempt",
    ]);
    expect(s.rpcCalls[2].args).toMatchObject({ p_attempt_id: "att-1" });
  });

  it("a resumed payment that already has its page is not checked or sent again", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "begin_order_payment"
          ? {
              data: {
                reused: true,
                attempt_id: "att-1",
                reference: "dx-test-r",
                authorization_url: "https://checkout.paystack.test/old",
              },
              error: null,
            }
          : undefined,
    });
    const r = await s.run();
    expect(r.payload).toMatchObject({ resumed: true });
    expect(s.rpcCalls.some((c) => c.fn === "prepare_attempt_for_provider")).toBe(false);
    expect(s.providerCalls).toHaveLength(0);
  });

  it("takes the amount from the database, whatever the browser sent", async () => {
    const s = setup("initialize", {
      body: { orderId: ORDER, amount: 1, amountMinor: 1, amount_ghs: 0.01 },
    });
    await s.run();
    expect(JSON.parse(String(s.providerCalls[0].init?.body)).amount).toBe(10000);
  });

  it("resumes an open attempt without asking the provider again", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "begin_order_payment"
          ? {
              data: {
                reused: true,
                attempt_id: "a",
                reference: "dx-test-old",
                amount_minor: 10000,
                authorization_url: "https://checkout.paystack.test/old",
              },
              error: null,
            }
          : undefined,
    });
    const r = await s.run();
    expect(r.payload).toEqual({
      authorizationUrl: "https://checkout.paystack.test/old",
      reference: "dx-test-old",
      resumed: true,
    });
    expect(s.providerCalls).toHaveLength(0);
  });

  it("passes the database's reasons on with the right status", async () => {
    const cases: [string, number][] = [
      ["You do not have permission to pay for this order.", 403],
      ["Too many payment attempts for this order. Please wait a little before trying again.", 429],
      ["Order not found.", 404],
      ["This order is already paid.", 400],
      ["Online payment is not available yet.", 400],
    ];
    for (const [message, status] of cases) {
      const s = setup("initialize", {
        rpc: (c) =>
          c.fn === "begin_order_payment" ? { data: null, error: { message } } : undefined,
      });
      const r = await s.run();
      expect(r.status).toBe(status);
      expect(r.payload).toEqual({ error: message });
      expect(s.providerCalls).toHaveLength(0);
    }
  });

  it("marks the attempt failed and says so when the provider cannot be reached or refuses", async () => {
    for (const initializeAnswer of [
      "offline" as const,
      { status: 400, body: { status: false, message: "Invalid key" } },
    ]) {
      const s = setup("initialize", { initializeAnswer });
      const r = await s.run();
      expect(r.status).toBe(502);
      expect(JSON.stringify(r.payload)).not.toContain("Invalid key");
      const failed = s.rpcCalls.find((c) => c.fn === "fail_payment_attempt");
      expect(failed?.args.p_attempt_id).toBe("att-1");
    }
  });

  it("marks the attempt failed when the database refuses the checkout address", async () => {
    const s = setup("initialize", {
      rpc: (c) =>
        c.fn === "record_attempt_authorization"
          ? { data: null, error: { message: "no secure address" } }
          : undefined,
    });
    expect((await s.run()).status).toBe(502);
    expect(s.rpcCalls.some((c) => c.fn === "fail_payment_attempt")).toBe(true);
  });

  it("fails clearly when the site's own address is not configured", async () => {
    const s = setup("initialize", { returnUrl: null });
    expect((await s.run()).status).toBe(500);
    expect(s.rpcCalls).toHaveLength(0);
  });

  it("starts an EXTRA payment for a price increase when asked for a top-up, and sends the customer back to a page that knows it", async () => {
    const s = setup("initialize", { body: { orderId: ORDER, purpose: "top_up" } });
    const r = await s.run();
    expect(r.status).toBe(200);
    const begin = s.rpcCalls.find((c) => c.fn === "begin_order_topup")!;
    expect(begin.args).toMatchObject({
      p_caller_id: USER,
      p_order_id: ORDER,
      p_provider: "paystack",
      p_mode: "test",
    });
    expect(s.rpcCalls.some((c) => c.fn === "begin_order_payment")).toBe(false);
    expect(JSON.parse(String(s.providerCalls[0].init?.body)).callback_url).toBe(
      `https://app.test/pay/return?order=${ORDER}&purpose=top_up`,
    );
  });

  it("anything other than top_up is the ordinary payment", async () => {
    for (const purpose of [undefined, "order", "refund", 5]) {
      const s = setup("initialize", { body: { orderId: ORDER, purpose } });
      await s.run();
      expect(s.rpcCalls.some((c) => c.fn === "begin_order_payment")).toBe(true);
      expect(s.rpcCalls.some((c) => c.fn === "begin_order_topup")).toBe(false);
    }
  });

  it("accepts a JSON string body", async () => {
    const s = setup("initialize", { body: JSON.stringify({ orderId: ORDER }) });
    expect((await s.run()).status).toBe(200);
  });
});

describe("verifying a payment", () => {
  const listed =
    (attempts: { reference: string }[], paymentStatus = "unpaid") =>
    (c: RpcCall) =>
      c.fn === "payment_attempts_to_check"
        ? {
            data: {
              payment_status: paymentStatus,
              attempts: attempts.map((a) => ({ provider: "paystack", mode: "test", ...a })),
            },
            error: null,
          }
        : undefined;

  it("asks the provider, applies the verified answer through the one function, and reports paid", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "apply_payment_result"
          ? { data: { outcome: "applied", order_paid: true }, error: null }
          : listed([{ reference: "dx-test-1" }])(c),
      paystack: { "dx-test-1": { body: verifyBody("dx-test-1") } },
    });
    const r = await s.run();
    expect(r.payload).toEqual({ status: "paid" });
    const applied = s.rpcCalls.find((c) => c.fn === "apply_payment_result")!;
    expect(applied.args).toMatchObject({
      p_provider: "paystack",
      p_mode: "test",
      p_reference: "dx-test-1",
      p_provider_status: "success",
      p_amount_minor: 10000,
      p_currency: "GHS",
      p_source: "verify",
    });
  });

  it("answers still-waiting without calling the provider when the database says the page asked again too soon", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? { data: { payment_status: "unpaid", throttled: true, attempts: [] }, error: null }
          : undefined,
    });
    const r = await s.run();
    expect(r.payload).toEqual({ status: "pending" });
    expect(s.providerCalls).toHaveLength(0);
  });

  it("marks each attempt as checked once the provider has answered, but not when it could not be reached", async () => {
    const ok = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? {
              data: {
                payment_status: "unpaid",
                attempts: [
                  { attempt_id: "a1", provider: "paystack", mode: "test", reference: "dx-test-1" },
                ],
              },
              error: null,
            }
          : c.fn === "apply_payment_result"
            ? { data: { outcome: "pending" }, error: null }
            : undefined,
      paystack: { "dx-test-1": { body: verifyBody("dx-test-1", { status: "ongoing" }) } },
    });
    await ok.run();
    expect(ok.rpcCalls.find((c) => c.fn === "mark_attempt_checked")?.args).toEqual({
      p_attempt_id: "a1",
    });
    const down = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? {
              data: {
                payment_status: "unpaid",
                attempts: [
                  { attempt_id: "a1", provider: "paystack", mode: "test", reference: "dx-test-1" },
                ],
              },
              error: null,
            }
          : undefined,
      paystack: { "dx-test-1": "offline" },
    });
    expect((await down.run()).status).toBe(502);
    expect(down.rpcCalls.some((c) => c.fn === "mark_attempt_checked")).toBe(false);
  });

  it("an order that is paid but owes an extra payment is NOT reported paid until that payment is verified", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? {
              data: {
                payment_status: "paid",
                topup_due: true,
                attempts: [
                  {
                    attempt_id: "t1",
                    provider: "paystack",
                    mode: "test",
                    reference: "dx-test-top-1",
                  },
                ],
              },
              error: null,
            }
          : c.fn === "apply_payment_result"
            ? { data: { outcome: "applied", order_paid: true }, error: null }
            : undefined,
      paystack: { "dx-test-top-1": { body: verifyBody("dx-test-top-1") } },
    });
    const r = await s.run();
    expect(r.payload).toEqual({ status: "paid" });
    expect(s.providerCalls).toHaveLength(1);
    expect(s.rpcCalls.some((c) => c.fn === "apply_payment_result")).toBe(true);
  });

  it("an extra payment that is still pending leaves the order's extra payment unpaid", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? {
              data: {
                payment_status: "paid",
                topup_due: true,
                attempts: [
                  {
                    attempt_id: "t1",
                    provider: "paystack",
                    mode: "test",
                    reference: "dx-test-top-1",
                  },
                ],
              },
              error: null,
            }
          : c.fn === "apply_payment_result"
            ? { data: { outcome: "pending" }, error: null }
            : undefined,
      paystack: { "dx-test-top-1": { body: verifyBody("dx-test-top-1", { status: "ongoing" }) } },
    });
    expect((await s.run()).payload).toEqual({ status: "pending" });
  });

  it("does not ask the provider again for an order that is already paid", async () => {
    const s = setup("verify", { rpc: listed([{ reference: "dx-test-1" }], "paid") });
    expect((await s.run()).payload).toEqual({ status: "paid" });
    expect(s.providerCalls).toHaveLength(0);
  });

  it("a successful redirect alone proves nothing: with the provider saying pending or failed the order is not paid", async () => {
    const pending = setup("verify", {
      rpc: (c) =>
        c.fn === "apply_payment_result"
          ? { data: { outcome: "pending" }, error: null }
          : listed([{ reference: "dx-test-1" }])(c),
      paystack: { "dx-test-1": { body: verifyBody("dx-test-1", { status: "ongoing" }) } },
    });
    expect((await pending.run()).payload).toEqual({ status: "pending" });
    const failed = setup("verify", {
      rpc: (c) =>
        c.fn === "apply_payment_result"
          ? { data: { outcome: "failed" }, error: null }
          : listed([{ reference: "dx-test-1" }])(c),
      paystack: {
        "dx-test-1": {
          body: verifyBody("dx-test-1", { status: "failed", gateway_response: "Declined" }),
        },
      },
    });
    expect((await failed.run()).payload).toEqual({ status: "failed" });
  });

  it("reports a flagged payment as needing a person, never as paid", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "apply_payment_result"
          ? {
              data: { outcome: "flagged", flag: "amount_mismatch", order_paid: false },
              error: null,
            }
          : listed([{ reference: "dx-test-1" }])(c),
      paystack: { "dx-test-1": { body: verifyBody("dx-test-1", { amount: 9999 }) } },
    });
    expect((await s.run()).payload).toEqual({ status: "flagged" });
  });

  it("skips a reference the provider has never heard of (the customer never reached the page)", async () => {
    const s = setup("verify", { rpc: listed([{ reference: "dx-test-never" }]) });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toEqual({ status: "not_paid" });
    expect(s.rpcCalls.some((c) => c.fn === "apply_payment_result")).toBe(false);
  });

  it("checks the newest attempts one by one and stops at the one that paid", async () => {
    const s = setup("verify", {
      rpc: (c) => {
        if (c.fn === "apply_payment_result")
          return {
            data:
              c.args.p_reference === "dx-test-2"
                ? { outcome: "applied", order_paid: true }
                : { outcome: "abandoned" },
            error: null,
          };
        return listed([
          { reference: "dx-test-3" },
          { reference: "dx-test-2" },
          { reference: "dx-test-1" },
        ])(c);
      },
      paystack: {
        "dx-test-3": { body: verifyBody("dx-test-3", { status: "abandoned" }) },
        "dx-test-2": { body: verifyBody("dx-test-2") },
        "dx-test-1": { body: verifyBody("dx-test-1") },
      },
    });
    expect((await s.run()).payload).toEqual({ status: "paid" });
    expect(s.providerCalls.map((c) => c.url.split("/").pop())).toEqual(["dx-test-3", "dx-test-2"]);
  });

  it("ignores attempts of the other mode or provider", async () => {
    const s = setup("verify", {
      rpc: (c) =>
        c.fn === "payment_attempts_to_check"
          ? {
              data: {
                payment_status: "unpaid",
                attempts: [
                  { provider: "paystack", mode: "live", reference: "dx-live-1" },
                  { provider: "other", mode: "test", reference: "o-1" },
                ],
              },
              error: null,
            }
          : undefined,
    });
    expect((await s.run()).payload).toEqual({ status: "not_paid" });
    expect(s.providerCalls).toHaveLength(0);
  });

  it("ignores an answer from the other mode", async () => {
    const s = setup("verify", {
      rpc: listed([{ reference: "dx-test-1" }]),
      paystack: { "dx-test-1": { body: verifyBody("dx-test-1", { domain: "live" }) } },
    });
    expect((await s.run()).payload).toEqual({ status: "not_paid" });
    expect(s.rpcCalls.some((c) => c.fn === "apply_payment_result")).toBe(false);
  });

  it("says it could not check (502) when the provider is unreachable, so the page keeps asking", async () => {
    const s = setup("verify", {
      rpc: listed([{ reference: "dx-test-1" }]),
      paystack: { "dx-test-1": "offline" },
    });
    const r = await s.run();
    expect(r.status).toBe(502);
    expect(r.payload).toEqual({ error: "We could not check the payment just now." });
  });

  it("only the paying side can verify: the database's refusal is passed on", async () => {
    const s = setup("verify", {
      rpc: (c) => ({ data: null, error: { message: "Order not found." } }),
    });
    expect((await s.run()).status).toBe(404);
  });
});

describe("the return address", () => {
  it("carries the purpose for an extra payment", () => {
    expect(paymentReturnUrl(ORDER, { SITE_URL: "https://drugxone.example" }, "top_up")).toBe(
      `https://drugxone.example/pay/return?order=${ORDER}&purpose=top_up`,
    );
    expect(paymentReturnUrl(ORDER, { SITE_URL: "https://drugxone.example" }, "order")).toBe(
      `https://drugxone.example/pay/return?order=${ORDER}`,
    );
  });

  it("is built from the site's configured address, not from anything the request says", () => {
    expect(paymentReturnUrl(ORDER, { SITE_URL: "https://drugxone.example/" })).toBe(
      `https://drugxone.example/pay/return?order=${ORDER}`,
    );
    expect(paymentReturnUrl(ORDER, { VERCEL_URL: "preview-abc.vercel.app" })).toBe(
      `https://preview-abc.vercel.app/pay/return?order=${ORDER}`,
    );
    expect(paymentReturnUrl(ORDER, {})).toBeNull();
    expect(paymentReturnUrl(ORDER, { SITE_URL: "not a url ::" })).toBeNull();
  });
});

describe("the local stand-in setting", () => {
  const base = { PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET };
  it("is honoured in test mode for a local address", () => {
    const r = loadPaymentsConfig({ ...base, PAYSTACK_BASE_URL: "http://127.0.0.1:4010/" });
    expect(r.ok && r.config.baseUrl).toBe("http://127.0.0.1:4010");
  });
  it("is refused for any other host, so a typo can never send the secret key elsewhere", () => {
    for (const url of [
      "https://api.paystack.co",
      "http://evil.example",
      "http://localhost.evil.example",
      "ftp://localhost",
    ]) {
      const r = loadPaymentsConfig({ ...base, PAYSTACK_BASE_URL: url });
      expect(r.ok).toBe(false);
    }
  });
  it("is refused in live mode", () => {
    const r = loadPaymentsConfig({
      PAYMENTS_MODE: "live",
      PAYSTACK_SECRET_KEY: "sk_live_x",
      PAYMENTS_LIVE_ENABLED: "yes",
      PAYSTACK_BASE_URL: "http://127.0.0.1:4010",
    });
    expect(r.ok).toBe(false);
  });
});
