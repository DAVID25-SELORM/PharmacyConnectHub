import { createHmac } from "node:crypto";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { describe, expect, it } from "vitest";
import { createAdminRefundHandler } from "./admin-refund-handler";
import { loadPaymentsConfig } from "./config";
import { PaystackProvider } from "./paystack";
import { createReconcileHandler } from "./reconcile-handler";
import { submitRefund } from "./refund-runner";
import { ProviderError } from "./types";
import { createWebhookHandler, type RpcFn } from "./webhook-handler";

const SECRET = "sk_test_unit_test_key";
const REFUND = "11111111-2222-4333-8444-555555555555";
const ADMIN = "99999999-2222-4333-8444-555555555555";

type RpcCall = { fn: string; args: Record<string, unknown> };
type RpcAnswer = { data: unknown; error: { message: string } | null };

function providerWith(
  answer: { status?: number; body: unknown } | "offline",
  calls: { url: string; init?: RequestInit }[] = [],
) {
  const fetchImpl = (async (url: string, init?: RequestInit) => {
    calls.push({ url, init });
    if (answer === "offline") throw new Error("offline");
    return new Response(JSON.stringify(answer.body), { status: answer.status ?? 200 });
  }) as unknown as typeof fetch;
  return new PaystackProvider({ secretKey: SECRET, fetchImpl });
}

function rpcRecorder(handler: (call: RpcCall) => RpcAnswer | undefined) {
  const calls: RpcCall[] = [];
  const rpc = ((fn, args) => {
    calls.push({ fn, args });
    return Promise.resolve(handler({ fn, args }) ?? { data: null, error: null });
  }) as RpcFn;
  return { rpc, calls };
}

const claimed = (extra: Record<string, unknown> = {}) => ({
  refund_id: REFUND,
  provider: "paystack",
  mode: "test",
  transaction_reference: "dx-test-pay-0001",
  amount_minor: 2000,
  reason: "late_payment",
  ...extra,
});

describe("the provider's refund call", () => {
  it("sends the payment's reference and the amount in pesewas, and reads the answer", async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const provider = providerWith(
      { body: { status: true, message: "queued", data: { id: 77, status: "Pending" } } },
      calls,
    );
    const r = await provider.refund({
      transactionReference: "dx-test-1",
      amountMinor: 2000,
      merchantNote: "late payment",
    });
    expect(r).toEqual({ providerRefundId: "77", status: "pending" });
    expect(calls[0].url).toMatch(/\/refund$/);
    expect(calls[0].init?.method).toBe("POST");
    expect(JSON.parse(String(calls[0].init?.body))).toEqual({
      transaction: "dx-test-1",
      amount: 2000,
      currency: "GHS",
      merchant_note: "late payment",
    });
  });
  it("refuses an amount that is not a whole number of pesewas before calling anything", async () => {
    const calls: { url: string }[] = [];
    const provider = providerWith({ body: {} }, calls);
    await expect(
      provider.refund({ transactionReference: "x", amountMinor: 20.5 }),
    ).rejects.toThrow();
    await expect(provider.refund({ transactionReference: "x", amountMinor: 0 })).rejects.toThrow();
    expect(calls).toHaveLength(0);
  });
  it("turns the provider's refusal into an error that carries its status", async () => {
    const provider = providerWith({
      status: 400,
      body: { status: false, message: "Transaction has already been fully reversed" },
    });
    const error = await provider
      .refund({ transactionReference: "x", amountMinor: 100 })
      .catch((e) => e);
    expect(error).toBeInstanceOf(ProviderError);
    expect(error.options.status).toBe(400);
  });
});

describe("refund notifications", () => {
  const sign = (body: string) => createHmac("sha512", SECRET).update(body).digest("hex");
  it("reads the payment reference, the refund id and the amount from a refund notification", () => {
    const body = JSON.stringify({
      event: "refund.processed",
      data: {
        id: 9,
        status: "processed",
        transaction_reference: "dx-test-1",
        refund_reference: "rf-1",
        amount: 2000,
      },
    });
    const parsed = providerWith({ body: {} }).parseWebhook(body, sign(body));
    expect(parsed.ok && parsed.event).toMatchObject({
      event: "refund.processed",
      reference: "dx-test-1",
      transactionReference: "dx-test-1",
      refundId: "rf-1",
      amountMinor: 2000,
      dedupeKey: "refund.processed:9",
    });
  });
  it("copes with the payment reference being nested, and with no id at all", () => {
    const body = JSON.stringify({
      event: "refund.pending",
      data: { status: "pending", transaction: { reference: "dx-test-2" } },
    });
    const parsed = providerWith({ body: {} }).parseWebhook(body, sign(body));
    expect(parsed.ok && parsed.event).toMatchObject({
      transactionReference: "dx-test-2",
      refundId: null,
      dedupeKey: "refund.pending:dx-test-2",
    });
  });
  it("leaves a charge notification exactly as before", () => {
    const body = JSON.stringify({
      event: "charge.success",
      data: { id: 555, reference: "dx-test-abc", domain: "test" },
    });
    const parsed = providerWith({ body: {} }).parseWebhook(body, sign(body));
    expect(parsed.ok && parsed.event).toEqual({
      event: "charge.success",
      dedupeKey: "charge.success:555",
      reference: "dx-test-abc",
      domain: "test",
    });
  });

  function webhook(rpcHandler: (c: RpcCall) => RpcAnswer | undefined) {
    const { rpc, calls } = rpcRecorder((c) => {
      if (c.fn === "record_payment_provider_event")
        return { data: { event_id: "e1", already_processed: false }, error: null };
      return rpcHandler(c);
    });
    const handler = createWebhookHandler({
      loadConfig: () => loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
      createProvider: (c) =>
        new PaystackProvider({
          secretKey: c.secretKey,
          fetchImpl: (async () => {
            throw new Error("must not be called");
          }) as unknown as typeof fetch,
        }),
      createRpc: () => rpc,
      readRawBody: async () => Buffer.from(bodyText),
      log: () => {},
    });
    let status = 0;
    let payload: unknown;
    const res = {
      status(c: number) {
        status = c;
        return res;
      },
      json(v: unknown) {
        payload = v;
        return res;
      },
    } as unknown as VercelResponse;
    return {
      run: async () => {
        await handler(
          {
            method: "POST",
            headers: { "x-paystack-signature": sign(bodyText) },
          } as unknown as VercelRequest,
          res,
        );
        return { status, payload: payload as Record<string, unknown> };
      },
      calls,
    };
  }
  let bodyText = "";

  it("applies a signed refund notification to the refund that was sent, without calling the provider", async () => {
    bodyText = JSON.stringify({
      event: "refund.processed",
      data: {
        id: 9,
        transaction_reference: "dx-test-1",
        refund_reference: "rf-1",
        amount: 2000,
        domain: "test",
      },
    });
    const w = webhook((c) =>
      c.fn === "apply_refund_event" ? { data: { outcome: "succeeded" }, error: null } : undefined,
    );
    const r = await w.run();
    expect(r.status).toBe(200);
    expect(r.payload).toEqual({ outcome: "succeeded" });
    expect(w.calls.find((c) => c.fn === "apply_refund_event")?.args).toEqual({
      p_provider: "paystack",
      p_mode: "test",
      p_transaction_reference: "dx-test-1",
      p_event_type: "refund.processed",
      p_provider_refund_id: "rf-1",
      p_amount_minor: 2000,
    });
    expect(w.calls.at(-1)).toMatchObject({
      fn: "finish_payment_provider_event",
      args: { p_outcome: "succeeded" },
    });
  });
  it("answers 500 (so the provider retries) when the refund could not be recorded", async () => {
    bodyText = JSON.stringify({
      event: "refund.failed",
      data: { id: 9, transaction_reference: "dx-test-1" },
    });
    const w = webhook((c) =>
      c.fn === "apply_refund_event" ? { data: null, error: { message: "db down" } } : undefined,
    );
    expect((await w.run()).status).toBe(500);
    expect(w.calls.at(-1)).toMatchObject({
      fn: "finish_payment_provider_event",
      args: { p_outcome: "error" },
    });
  });
});

describe("sending a refund", () => {
  const run = async (
    provider: PaystackProvider,
    handler: (c: RpcCall) => RpcAnswer | undefined,
  ) => {
    const { rpc, calls } = rpcRecorder(handler);
    const logs: string[] = [];
    const result = await submitRefund({ provider, rpc, log: (m) => logs.push(m) }, REFUND);
    return { result, calls, logs };
  };
  const claim = (c: RpcCall) =>
    c.fn === "claim_refund_for_submission" ? { data: claimed(), error: null } : undefined;

  it("claims it, sends the payment's reference and amount, and records the provider's answer", async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const { result, calls: rpcCalls } = await run(
      providerWith({ body: { status: true, data: { id: 5, status: "pending" } } }, calls),
      (c) =>
        claim(c) ??
        (c.fn === "record_refund_submission" ? { data: "processing", error: null } : undefined),
    );
    expect(result).toEqual({ sent: true, outcome: "processing" });
    expect(JSON.parse(String(calls[0].init?.body))).toMatchObject({
      transaction: "dx-test-pay-0001",
      amount: 2000,
    });
    expect(rpcCalls.map((c) => c.fn)).toEqual([
      "claim_refund_for_submission",
      "record_refund_submission",
    ]);
    expect(rpcCalls[1].args).toEqual({
      p_refund_id: REFUND,
      p_provider_refund_id: "5",
      p_provider_status: "pending",
    });
  });
  it("does nothing when somebody else holds the refund or it is no longer approved", async () => {
    const calls: { url: string }[] = [];
    const { result } = await run(providerWith({ body: {} }, calls), () => ({
      data: null,
      error: null,
    }));
    expect(result).toEqual({ sent: false, reason: "not_claimable" });
    expect(calls).toHaveLength(0);
  });
  it("a refusal the provider put into words is DEFINITE: the refund is failed and can be retried by a person", async () => {
    const { result, calls } = await run(
      providerWith({ status: 400, body: { status: false, message: "Transaction not eligible" } }),
      (c) =>
        claim(c) ??
        (c.fn === "record_refund_rejection" ? { data: "failed", error: null } : undefined),
    );
    expect(result).toMatchObject({ sent: true, outcome: "failed" });
    expect(calls.at(-1)?.args).toMatchObject({
      p_refund_id: REFUND,
      p_definite: true,
      p_reason: "Transaction not eligible",
    });
  });
  it("NO answer (the provider could not be reached) is UNCERTAIN: recorded as unknown, never retried by this code", async () => {
    const { result, calls } = await run(
      providerWith("offline"),
      (c) =>
        claim(c) ??
        (c.fn === "record_refund_rejection" ? { data: "unknown", error: null } : undefined),
    );
    expect(result).toMatchObject({ sent: true, outcome: "unknown" });
    expect(calls.at(-1)?.args).toMatchObject({ p_definite: false });
    expect(String(calls.at(-1)?.args.p_reason)).toContain("not known whether");
    expect(calls.filter((c) => c.fn === "claim_refund_for_submission")).toHaveLength(1);
  });
  it("a server error (5xx) is UNCERTAIN too", async () => {
    const { result, calls } = await run(
      providerWith({ status: 502, body: { status: false, message: "Bad gateway" } }),
      (c) => claim(c) ?? undefined,
    );
    expect(result).toMatchObject({ outcome: "unknown" });
    expect(calls.at(-1)?.args).toMatchObject({ p_definite: false });
  });
  it("a rate limit (429) means it was not accepted: definite", async () => {
    const { result } = await run(
      providerWith({ status: 429, body: { status: false, message: "Too many requests" } }),
      claim,
    );
    expect(result).toMatchObject({ outcome: "failed" });
  });
  it("if the provider took it but the database could not record that, a person must check: unknown, not failed", async () => {
    const { result, calls } = await run(
      providerWith({ body: { status: true, data: { id: 5, status: "pending" } } }),
      (c) =>
        claim(c) ??
        (c.fn === "record_refund_submission"
          ? { data: null, error: { message: "db down" } }
          : undefined),
    );
    expect(result).toMatchObject({ sent: true, outcome: "unknown" });
    expect(calls.at(-1)).toMatchObject({
      fn: "record_refund_rejection",
      args: { p_definite: false },
    });
  });
  it("a refund claimed for another mode than this server's is failed, not sent", async () => {
    const calls: { url: string }[] = [];
    const { result, calls: rpcCalls } = await run(providerWith({ body: {} }, calls), (c) =>
      c.fn === "claim_refund_for_submission"
        ? { data: claimed({ mode: "live" }), error: null }
        : undefined,
    );
    expect(result).toEqual({ sent: false, reason: "provider_mismatch" });
    expect(calls).toHaveLength(0);
    expect(rpcCalls.at(-1)?.args).toMatchObject({ p_definite: true });
  });
  it("a provider that already says processed is reported as succeeded", async () => {
    const { result } = await run(
      providerWith({ body: { status: true, data: { id: 5, status: "processed" } } }),
      (c) =>
        claim(c) ??
        (c.fn === "record_refund_submission" ? { data: "succeeded", error: null } : undefined),
    );
    expect(result).toEqual({ sent: true, outcome: "succeeded" });
  });
});

describe("the reconciler sends approved refunds", () => {
  function setup(
    rpcHandler: (c: RpcCall) => RpcAnswer | undefined,
    answer: { status?: number; body: unknown } | "offline",
  ) {
    const { rpc, calls } = rpcRecorder((c) => {
      if (c.fn === "payment_attempts_due_for_check") return { data: [], error: null };
      if (c.fn === "close_stale_payment_attempts") return { data: 0, error: null };
      if (c.fn === "expire_unpaid_online_orders")
        return { data: { expired: 0, blocked: 0 }, error: null };
      return rpcHandler(c);
    });
    const handler = createReconcileHandler({
      loadConfig: () => loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
      createProvider: () => providerWith(answer),
      createRpc: () => rpc,
      cronSecret: () => "s",
      now: () => new Date("2026-10-10T12:00:00Z"),
      log: () => {},
    });
    let status = 0;
    let payload: unknown;
    const res = {
      status(c: number) {
        status = c;
        return res;
      },
      json(v: unknown) {
        payload = v;
        return res;
      },
    } as unknown as VercelResponse;
    return {
      run: async () => {
        await handler(
          {
            method: "POST",
            headers: { authorization: "Bearer s" },
            query: {},
          } as unknown as VercelRequest,
          res,
        );
        return { status, payload: payload as Record<string, unknown> };
      },
      calls,
    };
  }
  it("sends each approved refund and counts what happened; flags overdue ones", async () => {
    const s = setup(
      (c) => {
        if (c.fn === "refunds_to_submit") return { data: [{ refund_id: REFUND }], error: null };
        if (c.fn === "claim_refund_for_submission") return { data: claimed(), error: null };
        if (c.fn === "record_refund_submission") return { data: "processing", error: null };
        if (c.fn === "flag_stale_refunds") return { data: 2, error: null };
        return undefined;
      },
      { body: { status: true, data: { id: 5, status: "pending" } } },
    );
    const r = await s.run();
    expect(r.payload).toMatchObject({
      refunds: { sent: 1, failed: 0, unknown: 0 },
      staleRefundsFlagged: 2,
    });
  });
  it("an uncertain refund is counted as unknown and is not sent a second time in the same run", async () => {
    let claims = 0;
    const s = setup((c) => {
      if (c.fn === "refunds_to_submit") return { data: [{ refund_id: REFUND }], error: null };
      if (c.fn === "claim_refund_for_submission") {
        claims += 1;
        return { data: claimed(), error: null };
      }
      return undefined;
    }, "offline");
    const r = await s.run();
    expect(r.payload).toMatchObject({ refunds: { sent: 0, failed: 0, unknown: 1 } });
    expect(claims).toBe(1);
  });
});

describe("the administrator's refund actions", () => {
  function setup(options: {
    admin?: boolean;
    body?: unknown;
    userId?: string | null;
    transition?: RpcAnswer;
    configOn?: boolean;
    answer?: { status?: number; body: unknown } | "offline";
    authorization?: string | null;
    method?: string;
  }) {
    const { rpc, calls } = rpcRecorder((c) => {
      if (c.fn === "payment_user_is_admin") return { data: options.admin ?? true, error: null };
      if (c.fn === "admin_refund_transition")
        return (
          options.transition ?? {
            data: { status: "approved", needs_submission: true },
            error: null,
          }
        );
      if (c.fn === "claim_refund_for_submission") return { data: claimed(), error: null };
      if (c.fn === "record_refund_submission") return { data: "processing", error: null };
      return undefined;
    });
    const handler = createAdminRefundHandler({
      loadConfig: () =>
        options.configOn === false
          ? loadPaymentsConfig({})
          : loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
      createProvider: () =>
        providerWith(
          options.answer ?? { body: { status: true, data: { id: 5, status: "pending" } } },
        ),
      createRpc: () => rpc,
      authenticate: async () => (options.userId === undefined ? ADMIN : options.userId),
      log: () => {},
    });
    const headers: Record<string, string> = {};
    if (options.authorization !== null) headers.authorization = options.authorization ?? "Bearer t";
    let status = 0;
    let payload: unknown;
    const res = {
      status(c: number) {
        status = c;
        return res;
      },
      json(v: unknown) {
        payload = v;
        return res;
      },
    } as unknown as VercelResponse;
    const body =
      options.body === undefined ? { refundId: REFUND, action: "approve" } : options.body;
    return {
      run: async () => {
        await handler(
          { method: options.method ?? "POST", headers, body } as unknown as VercelRequest,
          res,
        );
        return { status, payload: payload as Record<string, unknown> };
      },
      calls,
    };
  }
  it("accepts only POST from a signed-in administrator", async () => {
    expect((await setup({ method: "GET" }).run()).status).toBe(405);
    expect((await setup({ authorization: null }).run()).status).toBe(401);
    expect((await setup({ userId: null }).run()).status).toBe(401);
    const s = setup({ admin: false });
    expect((await s.run()).status).toBe(403);
    expect(s.calls.map((c) => c.fn)).toEqual(["payment_user_is_admin"]);
  });
  it("needs a real refund and a known action", async () => {
    expect((await setup({ body: { refundId: "x", action: "approve" } }).run()).status).toBe(400);
    expect((await setup({ body: { refundId: REFUND, action: "launch" } }).run()).status).toBe(400);
    expect((await setup({ body: null }).run()).status).toBe(400);
  });
  it("approving makes the database change the state and then sends the refund at once", async () => {
    const s = setup({});
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toMatchObject({ status: "approved", sent: true, outcome: "processing" });
    expect(s.calls.map((c) => c.fn)).toEqual([
      "payment_user_is_admin",
      "admin_refund_transition",
      "claim_refund_for_submission",
      "record_refund_submission",
    ]);
    expect(s.calls[1].args).toEqual({
      p_admin_id: ADMIN,
      p_refund_id: REFUND,
      p_action: "approve",
      p_note: null,
    });
  });
  it("cancelling or confirming changes the state only and sends nothing", async () => {
    const s = setup({
      body: { refundId: REFUND, action: "confirm_refunded", note: "Refunded in the dashboard" },
      transition: { data: { status: "succeeded", needs_submission: false }, error: null },
    });
    const r = await s.run();
    expect(r.payload).toEqual({ status: "succeeded" });
    expect(s.calls.map((c) => c.fn)).toEqual(["payment_user_is_admin", "admin_refund_transition"]);
    expect(s.calls[1].args).toMatchObject({ p_note: "Refunded in the dashboard" });
  });
  it("passes the database's reasons on", async () => {
    const s = setup({
      transition: {
        data: null,
        error: {
          message: "Only a refund that is waiting for approval can be approved (it is succeeded).",
        },
      },
    });
    const r = await s.run();
    expect(r.status).toBe(400);
    expect(String(r.payload.error)).toContain("waiting for approval");
  });
  it("when the server is not set up to send, the refund stays approved and says so", async () => {
    const s = setup({ configOn: false });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toMatchObject({ status: "approved", sent: false });
    expect(s.calls.some((c) => c.fn === "claim_refund_for_submission")).toBe(false);
  });
  it("an uncertain answer from the provider is reported as unknown, never as sent or failed", async () => {
    const s = setup({ answer: "offline" });
    const r = await s.run();
    expect(r.payload).toMatchObject({ sent: true, outcome: "unknown" });
  });
});
