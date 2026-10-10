import { createHmac } from "node:crypto";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import { describe, expect, it } from "vitest";
import { loadPaymentsConfig } from "./config";
import { PaystackProvider } from "./paystack";
import { createWebhookHandler, readRawBody, type RpcFn } from "./webhook-handler";

const SECRET = "sk_test_unit_test_key";
const sign = (body: string) => createHmac("sha512", SECRET).update(body).digest("hex");
const chargeBody = (extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    event: "charge.success",
    data: { id: 555, reference: "dx-test-abc", domain: "test", status: "success", ...extra },
  });

type RpcCall = { fn: string; args: Record<string, unknown> };

function setup(options: {
  verify?: { status?: number; body: unknown } | "offline";
  rpc?: (call: RpcCall) => { data: unknown; error: { message: string } | null };
  config?: ReturnType<typeof loadPaymentsConfig>;
  body?: string;
  signature?: string | null;
  method?: string;
  noRpc?: boolean;
}) {
  const rpcCalls: RpcCall[] = [];
  const logs: string[] = [];
  const fetchImpl = (async () => {
    if (options.verify === "offline") throw new Error("offline");
    const v = options.verify ?? {
      body: {
        status: true,
        data: {
          id: 555,
          status: "success",
          reference: "dx-test-abc",
          amount: 10000,
          currency: "GHS",
          channel: "card",
          fees: 150,
          domain: "test",
        },
      },
    };
    return new Response(JSON.stringify(v.body), {
      status: v.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  }) as unknown as typeof fetch;
  const body = options.body ?? chargeBody();
  const handler = createWebhookHandler({
    loadConfig: () =>
      options.config ?? loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
    createProvider: (config) => new PaystackProvider({ secretKey: config.secretKey, fetchImpl }),
    createRpc: () =>
      options.noRpc
        ? null
        : (((fn, args) => {
            const call = { fn, args };
            rpcCalls.push(call);
            const answer =
              options.rpc?.(call) ??
              (fn === "record_payment_provider_event"
                ? {
                    data: { event_id: "e1", duplicate: false, already_processed: false },
                    error: null,
                  }
                : fn === "apply_payment_result"
                  ? { data: { outcome: "applied" }, error: null }
                  : { data: null, error: null });
            return Promise.resolve(answer);
          }) as RpcFn),
    readRawBody: async () => Buffer.from(body),
    log: (message) => logs.push(message),
  });
  const headers: Record<string, string> = {};
  if (options.signature !== null) headers["x-paystack-signature"] = options.signature ?? sign(body);
  const req = { method: options.method ?? "POST", headers } as unknown as VercelRequest;
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
      return { status, payload };
    },
    rpcCalls,
    logs,
  };
}

describe("the payments webhook", () => {
  it("accepts only POST", async () => {
    expect((await setup({ method: "GET" }).run()).status).toBe(405);
  });

  it("does nothing while online payments are off", async () => {
    const s = setup({ config: loadPaymentsConfig({}) });
    expect((await s.run()).status).toBe(503);
    expect(s.rpcCalls).toHaveLength(0);
  });

  it("refuses a missing or wrong signature (401) and stores nothing", async () => {
    for (const signature of [null, "00", sign("another body")]) {
      const s = setup({ signature });
      expect((await s.run()).status).toBe(401);
      expect(s.rpcCalls).toHaveLength(0);
    }
  });

  it("refuses a correctly signed body that is not JSON (400)", async () => {
    const s = setup({ body: "not json" });
    expect((await s.run()).status).toBe(400);
    expect(s.rpcCalls).toHaveLength(0);
  });

  it("acknowledges and ignores a notification from the other mode", async () => {
    const s = setup({ body: chargeBody({ domain: "live" }) });
    const result = await s.run();
    expect(result).toEqual({ status: 200, payload: { ignored: "mode" } });
    expect(s.rpcCalls).toHaveLength(0);
  });

  it("stores the notification, verifies with Paystack, applies the VERIFIED result, and records the outcome", async () => {
    const s = setup({});
    const result = await s.run();
    expect(result).toEqual({ status: 200, payload: { outcome: "applied" } });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "record_payment_provider_event",
      "apply_payment_result",
      "finish_payment_provider_event",
    ]);
    expect(s.rpcCalls[0].args).toMatchObject({
      p_provider: "paystack",
      p_dedupe_key: "charge.success:555",
      p_event_type: "charge.success",
      p_reference: "dx-test-abc",
      p_mode: "test",
    });
    expect(s.rpcCalls[1].args).toMatchObject({
      p_reference: "dx-test-abc",
      p_provider_status: "success",
      p_amount_minor: 10000,
      p_currency: "GHS",
      p_source: "webhook",
      p_event_id: "e1",
    });
    expect(s.rpcCalls[2].args).toMatchObject({ p_event_id: "e1", p_outcome: "applied" });
  });

  it("applies what Paystack says, not what the notification claims", async () => {
    // The notification says success, but Paystack's own answer is that the payment failed.
    const s = setup({
      verify: {
        body: {
          status: true,
          data: {
            status: "failed",
            reference: "dx-test-abc",
            amount: 10000,
            currency: "GHS",
            gateway_response: "Declined",
          },
        },
      },
      rpc: (call) =>
        call.fn === "apply_payment_result"
          ? { data: { outcome: "failed" }, error: null }
          : { data: { event_id: "e1", already_processed: false }, error: null },
    });
    await s.run();
    expect(s.rpcCalls[1].args).toMatchObject({
      p_provider_status: "failed",
      p_failure_reason: "Declined",
    });
  });

  it("does nothing more for a notification it has already processed", async () => {
    const s = setup({
      rpc: () => ({
        data: { event_id: "e1", duplicate: true, already_processed: true },
        error: null,
      }),
    });
    expect(await s.run()).toEqual({ status: 200, payload: { duplicate: true } });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["record_payment_provider_event"]);
  });

  it("stores and acknowledges events it does not act on", async () => {
    const body = JSON.stringify({
      event: "transfer.success",
      data: { id: 9, reference: "t-1", domain: "test" },
    });
    const s = setup({ body });
    expect(await s.run()).toEqual({ status: 200, payload: { outcome: "ignored" } });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "record_payment_provider_event",
      "finish_payment_provider_event",
    ]);
  });

  it("answers 500 (so Paystack tries again) when Paystack cannot be asked, and records the failure", async () => {
    const s = setup({ verify: "offline" });
    const result = await s.run();
    expect(result.status).toBe(500);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "record_payment_provider_event",
      "finish_payment_provider_event",
    ]);
    expect(s.rpcCalls[1].args).toMatchObject({ p_outcome: "error" });
    expect(s.logs.some((line) => line.includes("provider"))).toBe(true);
  });

  it("answers 500 when the database refuses the result, and records the failure", async () => {
    const s = setup({
      rpc: (call) =>
        call.fn === "apply_payment_result"
          ? { data: null, error: { message: "boom" } }
          : { data: { event_id: "e1", already_processed: false }, error: null },
    });
    expect((await s.run()).status).toBe(500);
    expect(s.rpcCalls[s.rpcCalls.length - 1].args).toMatchObject({
      p_outcome: "error",
      p_error: "boom",
    });
  });

  it("answers 500 when the notification cannot be stored, without applying anything", async () => {
    const s = setup({ rpc: () => ({ data: null, error: { message: "down" } }) });
    expect((await s.run()).status).toBe(500);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["record_payment_provider_event"]);
  });

  it("answers 500 when the database is not configured", async () => {
    expect((await setup({ noRpc: true }).run()).status).toBe(500);
  });
});

describe("reading the raw body", () => {
  it("returns the exact bytes of the request, whatever the chunking", async () => {
    async function* chunks() {
      yield Buffer.from('{"a":');
      yield "1}";
    }
    const raw = await readRawBody(chunks() as unknown as VercelRequest);
    expect(raw.toString("utf8")).toBe('{"a":1}');
  });
});
