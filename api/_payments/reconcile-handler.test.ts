import type { VercelRequest, VercelResponse } from "@vercel/node";
import { describe, expect, it } from "vitest";
import { createAdminReverifyHandler } from "./admin-handler";
import { loadPaymentsConfig } from "./config";
import { PaystackProvider } from "./paystack";
import { createReconcileHandler } from "./reconcile-handler";
import type { RpcFn } from "./webhook-handler";

const SECRET = "sk_test_unit_test_key";
const CRON = "cron-secret-value";
const ORDER = "11111111-2222-4333-8444-555555555555";
const ADMIN = "99999999-2222-4333-8444-555555555555";

type RpcCall = { fn: string; args: Record<string, unknown> };
type RpcAnswer = { data: unknown; error: { message: string } | null };

function makeFetch(options: {
  verify?: Record<string, { status?: number; body: unknown } | "offline">;
  list?: { pages: unknown[][]; fail?: boolean };
}) {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => {
    calls.push(url);
    if (url.includes("/transaction/verify/")) {
      const ref = decodeURIComponent(url.split("/transaction/verify/")[1]);
      const a = options.verify?.[ref];
      if (a === "offline") throw new Error("offline");
      if (!a)
        return new Response(JSON.stringify({ status: false, message: "not found" }), {
          status: 404,
        });
      return new Response(JSON.stringify(a.body), { status: a.status ?? 200 });
    }
    if (url.includes("/transaction?")) {
      if (options.list?.fail) throw new Error("offline");
      const page = Number(new URL(url).searchParams.get("page") ?? "1");
      const rows = options.list?.pages[page - 1] ?? [];
      return new Response(
        JSON.stringify({
          status: true,
          data: rows,
          meta: { page, pageCount: options.list?.pages.length ?? 1 },
        }),
        { status: 200 },
      );
    }
    return new Response("{}", { status: 404 });
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

const paid = (reference: string, extra: Record<string, unknown> = {}) => ({
  status: true,
  data: {
    id: 1,
    status: "success",
    reference,
    amount: 2000,
    currency: "GHS",
    channel: "card",
    fees: 50,
    domain: "test",
    ...extra,
  },
});

function res() {
  let status = 0;
  let payload: unknown;
  const r = {
    status(code: number) {
      status = code;
      return r;
    },
    json(value: unknown) {
      payload = value;
      return r;
    },
  } as unknown as VercelResponse;
  return { r, get: () => ({ status, payload: payload as Record<string, unknown> }) };
}

function setupReconcile(options: {
  method?: string;
  authorization?: string | null;
  job?: string;
  noteFails?: boolean;
  cron?: string | undefined;
  config?: ReturnType<typeof loadPaymentsConfig>;
  rpc?: (call: RpcCall) => RpcAnswer | undefined;
  verify?: Record<string, { status?: number; body: unknown } | "offline">;
  list?: { pages: unknown[][]; fail?: boolean };
}) {
  const rpcCalls: RpcCall[] = [];
  const noted: string[] = [];
  const logs: string[] = [];
  const { fetchImpl, calls } = makeFetch(options);
  const handler = createReconcileHandler({
    loadConfig: () =>
      options.config ?? loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
    createProvider: (c) => new PaystackProvider({ secretKey: c.secretKey, fetchImpl }),
    createRpc: () =>
      ((fn, args) => {
        const call = { fn, args };
        // Noting that the scheduler ran is checked on its own (see "the scheduler is noted").
        if (fn === "record_reconciler_run") {
          if (options.noteFails) return Promise.reject(new Error("database down"));
          noted.push(String(args.p_job));
          return Promise.resolve({ data: null, error: null });
        }
        rpcCalls.push(call);
        const a = options.rpc?.(call);
        if (a) return Promise.resolve(a);
        if (fn === "payment_attempts_due_for_check")
          return Promise.resolve({ data: [], error: null });
        if (fn === "close_stale_payment_attempts") return Promise.resolve({ data: 0, error: null });
        if (fn === "expire_unpaid_online_orders")
          return Promise.resolve({ data: { expired: 0, blocked: 0 }, error: null });
        if (fn === "reconcile_provider_transactions")
          return Promise.resolve({ data: { checked: 0, to_verify: [], alerts: 0 }, error: null });
        return Promise.resolve({ data: null, error: null });
      }) as RpcFn,
    cronSecret: () => ("cron" in options ? options.cron : CRON),
    now: () => new Date("2026-10-10T12:00:00Z"),
    log: (m) => logs.push(m),
  });
  const headers: Record<string, string> = {};
  if (options.authorization !== null)
    headers.authorization = options.authorization ?? `Bearer ${CRON}`;
  const req = {
    method: options.method ?? "POST",
    headers,
    query: { job: options.job },
  } as unknown as VercelRequest;
  const out = res();
  return {
    run: async () => {
      await handler(req, out.r);
      return out.get();
    },
    rpcCalls,
    noted,
    calls,
    logs,
  };
}

describe("the reconciler: who may call it", () => {
  it("accepts only GET and POST", async () => {
    expect((await setupReconcile({ method: "DELETE" }).run()).status).toBe(405);
  });
  it("is unavailable until a secret is configured", async () => {
    const s = setupReconcile({ cron: undefined });
    expect((await s.run()).status).toBe(503);
    expect(s.rpcCalls).toHaveLength(0);
  });
  it("refuses a missing or wrong secret without touching anything", async () => {
    for (const authorization of [null, "Bearer nope", "Basic abc", `Bearer ${CRON}x`]) {
      const s = setupReconcile({ authorization });
      expect((await s.run()).status).toBe(401);
      expect(s.rpcCalls).toHaveLength(0);
      expect(s.calls).toHaveLength(0);
    }
  });
  it("does nothing, successfully, while online payments are off", async () => {
    const s = setupReconcile({ config: loadPaymentsConfig({}) });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload.skipped).toBeTruthy();
    expect(s.rpcCalls).toHaveLength(0);
  });
  it("the scheduler is noted even while online payments are off (so readiness can see it runs), for each job", async () => {
    const off = setupReconcile({ config: loadPaymentsConfig({}) });
    await off.run();
    expect(off.noted).toEqual(["frequent"]);
    const daily = setupReconcile({ job: "daily" });
    await daily.run();
    expect(daily.noted).toEqual(["daily"]);
  });
  it("a failure to note the run never stops the run", async () => {
    const s = setupReconcile({ noteFails: true });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(s.logs.some((l) => l.includes("could not note"))).toBe(true);
    expect(s.rpcCalls.some((c) => c.fn === "payment_attempts_due_for_check")).toBe(true);
  });
  it("an unauthorised call is not noted", async () => {
    const s = setupReconcile({ authorization: "Bearer wrong" });
    expect((await s.run()).status).toBe(401);
    expect(s.noted).toEqual([]);
  });
  it("reports a misconfiguration as an error", async () => {
    const s = setupReconcile({
      config: loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: "sk_live_x" }),
    });
    expect((await s.run()).status).toBe(500);
  });
});

describe("the frequent job", () => {
  const due =
    (...refs: string[]) =>
    (c: RpcCall) =>
      c.fn === "payment_attempts_due_for_check"
        ? {
            data: refs.map((reference, i) => ({
              attempt_id: `a${i}`,
              provider: "paystack",
              mode: "test",
              reference,
              order_id: ORDER,
            })),
            error: null,
          }
        : undefined;

  it("verifies each due attempt with the provider, applies the answer, marks it checked, then closes stale attempts and expires orders", async () => {
    const s = setupReconcile({
      rpc: (c) =>
        c.fn === "apply_payment_result"
          ? { data: { outcome: "applied", order_paid: true }, error: null }
          : due("dx-test-1")(c),
      verify: { "dx-test-1": { body: paid("dx-test-1") } },
    });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toMatchObject({
      job: "frequent",
      checked: 1,
      applied: 1,
      providerErrors: 0,
      closedStale: 0,
      expiry: { expired: 0, blocked: 0 },
    });
    const fns = s.rpcCalls.map((c) => c.fn);
    expect(fns).toEqual([
      "payment_attempts_due_for_check",
      "apply_payment_result",
      "mark_attempt_checked",
      "close_stale_payment_attempts",
      "expire_unpaid_online_orders",
      "refunds_to_submit",
      "flag_stale_refunds",
      "flag_unrefunded_balances",
    ]);
    expect(s.rpcCalls[1].args).toMatchObject({
      p_source: "reconcile",
      p_reference: "dx-test-1",
      p_provider_status: "success",
      p_amount_minor: 2000,
    });
    expect(s.rpcCalls[2].args).toEqual({ p_attempt_id: "a0" });
  });

  it("counts a reference the provider has never heard of as checked, not as a problem", async () => {
    const s = setupReconcile({ rpc: due("dx-test-never") });
    const r = await s.run();
    expect(r.payload).toMatchObject({ checked: 1, unknownAtProvider: 1, providerErrors: 0 });
    expect(s.rpcCalls.map((c) => c.fn)).toContain("mark_attempt_checked");
    expect(s.rpcCalls.some((c) => c.fn === "apply_payment_result")).toBe(false);
  });

  it("when the provider cannot be reached the attempt is NOT marked checked, an alert is raised, and expiry is still asked (the database refuses unchecked orders)", async () => {
    const s = setupReconcile({ rpc: due("dx-test-1"), verify: { "dx-test-1": "offline" } });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toMatchObject({ checked: 0, providerErrors: 1 });
    expect(s.rpcCalls.some((c) => c.fn === "mark_attempt_checked")).toBe(false);
    const problem = s.rpcCalls.find((c) => c.fn === "report_payment_job_problem");
    expect(problem?.args).toMatchObject({
      p_kind: "provider_unreachable",
      p_dedupe_key: "provider_unreachable:test",
    });
    expect(s.rpcCalls.some((c) => c.fn === "expire_unpaid_online_orders")).toBe(true);
  });

  it("ignores attempts of another mode, and an answer from another mode", async () => {
    const s = setupReconcile({
      rpc: (c) =>
        c.fn === "payment_attempts_due_for_check"
          ? {
              data: [
                { attempt_id: "x", provider: "paystack", mode: "live", reference: "dx-live-1" },
                { attempt_id: "y", provider: "paystack", mode: "test", reference: "dx-test-2" },
              ],
              error: null,
            }
          : undefined,
      verify: { "dx-test-2": { body: paid("dx-test-2", { domain: "live" }) } },
    });
    const r = await s.run();
    expect(r.payload).toMatchObject({ checked: 0, providerErrors: 0 });
    expect(s.rpcCalls.some((c) => c.fn === "apply_payment_result")).toBe(false);
  });

  it("fails clearly when the list of attempts cannot be read", async () => {
    const s = setupReconcile({
      rpc: (c) =>
        c.fn === "payment_attempts_due_for_check"
          ? { data: null, error: { message: "db down" } }
          : undefined,
    });
    expect((await s.run()).status).toBe(500);
    expect(s.rpcCalls.some((c) => c.fn === "expire_unpaid_online_orders")).toBe(false);
  });
});

describe("the daily comparison", () => {
  const row = (reference: string, status = "success", amount = 2000) => ({
    reference,
    status,
    amount,
    currency: "GHS",
    id: 1,
    channel: "card",
  });

  it("lists the provider's transactions across pages, compares, verifies what is paid but not applied, then compares finally", async () => {
    const s = setupReconcile({
      job: "daily",
      list: { pages: [[row("dx-test-1")], [row("dx-test-2")]] },
      rpc: (c) => {
        if (c.fn === "reconcile_provider_transactions" && c.args.p_final === false)
          return { data: { checked: 2, to_verify: ["dx-test-2"], alerts: 0 }, error: null };
        if (c.fn === "reconcile_provider_transactions")
          return { data: { checked: 2, to_verify: [], alerts: 1 }, error: null };
        if (c.fn === "apply_payment_result")
          return { data: { outcome: "applied", order_paid: true }, error: null };
        return undefined;
      },
      verify: { "dx-test-2": { body: paid("dx-test-2") } },
    });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toMatchObject({
      job: "daily",
      listed: 2,
      complete: true,
      considered: 2,
      verified: 1,
      applied: 1,
      alertsRaised: 1,
    });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "reconcile_provider_transactions",
      "apply_payment_result",
      "reconcile_provider_transactions",
    ]);
    const first = s.rpcCalls[0].args;
    expect(first).toMatchObject({
      p_provider: "paystack",
      p_mode: "test",
      p_complete: true,
      p_final: false,
    });
    expect(first.p_transactions).toEqual([
      { reference: "dx-test-1", status: "success", amount_minor: 2000, currency: "GHS" },
      { reference: "dx-test-2", status: "success", amount_minor: 2000, currency: "GHS" },
    ]);
    expect(new Date(String(first.p_to)).getTime() - new Date(String(first.p_from)).getTime()).toBe(
      25 * 3600 * 1000,
    );
    expect(s.rpcCalls[2].args).toMatchObject({ p_final: true });
  });

  it("an unreachable provider list raises an alert and the comparison does not run on partial data", async () => {
    const s = setupReconcile({ job: "daily", list: { pages: [], fail: true } });
    const r = await s.run();
    expect(r.status).toBe(502);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["report_payment_job_problem"]);
  });

  it("a list that is too long to read in full is reported as incomplete, so 'missing at the provider' is not judged", async () => {
    const pages = Array.from({ length: 25 }, (_, i) => [row(`dx-test-p${i}`)]);
    const s = setupReconcile({ job: "daily", list: { pages } });
    const r = await s.run();
    expect(r.payload).toMatchObject({ complete: false, listed: 20 });
    expect(s.rpcCalls[0].args).toMatchObject({ p_complete: false });
  });

  it("a database failure in the comparison is an error, not a silent success", async () => {
    const s = setupReconcile({
      job: "daily",
      list: { pages: [[]] },
      rpc: (c) =>
        c.fn === "reconcile_provider_transactions"
          ? { data: null, error: { message: "boom" } }
          : undefined,
    });
    expect((await s.run()).status).toBe(500);
  });
});

describe("the admin's re-verify", () => {
  function setup(options: {
    userId?: string | null;
    admin?: boolean;
    body?: unknown;
    attempts?: unknown[];
    verify?: Record<string, { status?: number; body: unknown } | "offline">;
    apply?: unknown;
    authorization?: string | null;
    method?: string;
  }) {
    const rpcCalls: RpcCall[] = [];
    const { fetchImpl } = makeFetch({ verify: options.verify });
    const handler = createAdminReverifyHandler({
      loadConfig: () => loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
      createProvider: (c) => new PaystackProvider({ secretKey: c.secretKey, fetchImpl }),
      createRpc: () =>
        ((fn, args) => {
          rpcCalls.push({ fn, args });
          if (fn === "payment_user_is_admin")
            return Promise.resolve({ data: options.admin ?? true, error: null });
          if (fn === "admin_attempts_to_reverify")
            return Promise.resolve({ data: options.attempts ?? [], error: null });
          if (fn === "apply_payment_result")
            return Promise.resolve({
              data: options.apply ?? { outcome: "applied", order_paid: true },
              error: null,
            });
          return Promise.resolve({ data: null, error: null });
        }) as RpcFn,
      authenticate: async () => (options.userId === undefined ? ADMIN : options.userId),
      log: () => {},
    });
    const headers: Record<string, string> = {};
    if (options.authorization !== null) headers.authorization = options.authorization ?? "Bearer t";
    const req = {
      method: options.method ?? "POST",
      headers,
      body: options.body === undefined ? { orderId: ORDER } : options.body,
    } as unknown as VercelRequest;
    const out = res();
    return {
      run: async () => {
        await handler(req, out.r);
        return out.get();
      },
      rpcCalls,
    };
  }

  it("accepts only POST, with a signed-in user", async () => {
    expect((await setup({ method: "GET" }).run()).status).toBe(405);
    expect((await setup({ authorization: null }).run()).status).toBe(401);
    expect((await setup({ userId: null }).run()).status).toBe(401);
  });
  it("refuses anyone who is not a platform administrator, before asking the provider anything", async () => {
    const s = setup({
      admin: false,
      attempts: [{ attempt_id: "a", provider: "paystack", mode: "test", reference: "dx-test-1" }],
    });
    expect((await s.run()).status).toBe(403);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["payment_user_is_admin"]);
  });
  it("needs a real order id", async () => {
    expect((await setup({ body: { orderId: "x" } }).run()).status).toBe(400);
  });
  it("verifies the order's attempts and records the answer through the one function", async () => {
    const s = setup({
      attempts: [{ attempt_id: "a", provider: "paystack", mode: "test", reference: "dx-test-1" }],
      verify: { "dx-test-1": { body: paid("dx-test-1") } },
    });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toEqual({
      orderPaid: true,
      outcomes: [{ reference: "dx-test-1", outcome: "applied" }],
    });
    expect(s.rpcCalls.find((c) => c.fn === "apply_payment_result")?.args).toMatchObject({
      p_source: "reconcile",
      p_amount_minor: 2000,
    });
  });
  it("says when the provider could not be reached, without claiming anything", async () => {
    const s = setup({
      attempts: [{ attempt_id: "a", provider: "paystack", mode: "test", reference: "dx-test-1" }],
      verify: { "dx-test-1": "offline" },
    });
    const r = await s.run();
    expect(r.payload).toEqual({
      orderPaid: false,
      outcomes: [{ reference: "dx-test-1", outcome: "could_not_check_provider" }],
    });
  });
});
