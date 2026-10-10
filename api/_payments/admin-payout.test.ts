import type { VercelRequest, VercelResponse } from "@vercel/node";
import { describe, expect, it } from "vitest";
import { createAdminPayoutHandler, serverChecks } from "./admin-payout-handler";
import { loadPaymentsConfig } from "./config";
import { PaystackProvider } from "./paystack";
import type { RpcFn } from "./webhook-handler";

const SECRET = "sk_test_unit_test_key";
const ADMIN = "99999999-2222-4333-8444-555555555555";
const SUPPLIER = "11111111-2222-4333-8444-555555555555";
const ACCOUNT = "22222222-2222-4333-8444-555555555555";

type RpcCall = { fn: string; args: Record<string, unknown> };
type RpcAnswer = { data: unknown; error: { message: string } | null };

function setup(options: {
  admin?: boolean;
  userId?: string | null;
  authorization?: string | null;
  method?: string;
  body?: unknown;
  configOn?: boolean;
  rpc?: (call: RpcCall) => RpcAnswer | undefined;
  provider?: { status?: number; body: unknown } | "offline";
  env?: Record<string, string | undefined>;
  noRpc?: boolean;
}) {
  const rpcCalls: RpcCall[] = [];
  const providerCalls: { url: string; init?: RequestInit }[] = [];
  const logs: string[] = [];
  const fetchImpl = (async (url: string, init?: RequestInit) => {
    providerCalls.push({ url, init });
    const a = options.provider ?? {
      body: { status: true, data: { subaccount_code: "ACCT_made1" } },
    };
    if (a === "offline") throw new Error("offline");
    return new Response(JSON.stringify(a.body), { status: a.status ?? 200 });
  }) as unknown as typeof fetch;
  const handler = createAdminPayoutHandler({
    loadConfig: () =>
      options.configOn === false
        ? loadPaymentsConfig({})
        : loadPaymentsConfig({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: SECRET }),
    createProvider: (c) => new PaystackProvider({ secretKey: c.secretKey, fetchImpl }),
    createRpc: () =>
      options.noRpc
        ? null
        : (((fn, args) => {
            const call = { fn, args };
            rpcCalls.push(call);
            const a = options.rpc?.(call);
            if (a) return Promise.resolve(a);
            if (fn === "payment_user_is_admin")
              return Promise.resolve({ data: options.admin ?? true, error: null });
            if (fn === "begin_payout_account")
              return Promise.resolve({ data: ACCOUNT, error: null });
            if (fn === "finish_payout_account")
              return Promise.resolve({ data: "active", error: null });
            if (fn === "admin_set_payout_account_status")
              return Promise.resolve({ data: "inactive", error: null });
            return Promise.resolve({ data: null, error: null });
          }) as RpcFn),
    authenticate: async () => (options.userId === undefined ? ADMIN : options.userId),
    env: () => options.env ?? {},
    log: (m) => logs.push(m),
  });
  const headers: Record<string, string> = {};
  if (options.authorization !== null) headers.authorization = options.authorization ?? "Bearer t";
  const req = {
    method: options.method ?? "POST",
    headers,
    body: options.body,
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

const register = (extra: Record<string, unknown> = {}) => ({
  action: "register",
  wholesalerId: SUPPLIER,
  businessName: "Alpha Wholesale Ltd",
  bankCode: "GCB",
  accountNumber: "0123 4567-890",
  ...extra,
});

describe("who may use it", () => {
  it("accepts only POST, a signed-in session and a platform administrator", async () => {
    expect((await setup({ method: "GET" }).run()).status).toBe(405);
    expect((await setup({ authorization: null }).run()).status).toBe(401);
    expect((await setup({ userId: null }).run()).status).toBe(401);
    const s = setup({ admin: false, body: register() });
    expect((await s.run()).status).toBe(403);
    expect(s.providerCalls).toHaveLength(0);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["payment_user_is_admin"]);
    expect((await setup({ noRpc: true }).run()).status).toBe(500);
  });
  it("refuses an unknown action", async () => {
    expect((await setup({ body: { action: "delete_everything" } }).run()).status).toBe(400);
  });
});

describe("registering a settlement account", () => {
  it("records it first, creates it at the provider with the full number, finishes the record with the code, and keeps only the last four digits", async () => {
    const s = setup({ body: register() });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload).toEqual({ id: ACCOUNT, status: "active" });
    expect(s.rpcCalls.map((c) => c.fn)).toEqual([
      "payment_user_is_admin",
      "begin_payout_account",
      "finish_payout_account",
    ]);
    expect(s.rpcCalls[1].args).toEqual({
      p_admin_id: ADMIN,
      p_wholesaler_id: SUPPLIER,
      p_mode: "test",
      p_business_name: "Alpha Wholesale Ltd",
      p_bank_code: "GCB",
      p_account_last4: "7890",
    });
    expect(s.rpcCalls[2].args).toEqual({
      p_id: ACCOUNT,
      p_subaccount_code: "ACCT_made1",
      p_failure: null,
    });
    expect(JSON.parse(String(s.providerCalls[0].init?.body)).account_number).toBe("01234567890");
  });
  it("the full account number appears in no database call, no log and no answer", async () => {
    const s = setup({ body: register() });
    const r = await s.run();
    const everything = JSON.stringify([s.rpcCalls, s.logs, r]);
    expect(everything).not.toContain("01234567890");
    expect(everything).not.toContain("0123456789");
  });
  it("a provider refusal is final: recorded as failed with the reason, and the person is told", async () => {
    const s = setup({
      body: register(),
      provider: { status: 400, body: { status: false, message: "Account number is invalid" } },
    });
    const r = await s.run();
    expect(r.status).toBe(400);
    expect(String(r.payload.error)).toContain("Account number is invalid");
    const finish = s.rpcCalls.find((c) => c.fn === "finish_payout_account")!;
    expect(finish.args.p_subaccount_code).toBeNull();
    expect(String(finish.args.p_failure)).toContain("refused");
    expect(JSON.stringify(s.logs)).not.toContain("01234567890");
  });
  it("a lost answer is recorded as failed with a warning to look at the provider's dashboard first", async () => {
    const s = setup({ body: register(), provider: "offline" });
    const r = await s.run();
    expect(r.status).toBe(502);
    expect(String(r.payload.error)).toMatch(/dashboard/);
    expect(
      String(s.rpcCalls.find((c) => c.fn === "finish_payout_account")!.args.p_failure),
    ).toMatch(/dashboard/);
  });
  it("a database refusal (an account already exists, not a wholesaler) means the provider is never asked", async () => {
    const s = setup({
      body: register(),
      rpc: (c) =>
        c.fn === "begin_payout_account"
          ? {
              data: null,
              error: {
                message:
                  "This supplier already has a settlement account for this mode. Switch it off first to replace it.",
              },
            }
          : undefined,
    });
    const r = await s.run();
    expect(r.status).toBe(400);
    expect(s.providerCalls).toHaveLength(0);
  });
  it("if the provider made it but it cannot be recorded, say so plainly", async () => {
    const s = setup({
      body: register(),
      rpc: (c) =>
        c.fn === "finish_payout_account" ? { data: null, error: { message: "boom" } } : undefined,
    });
    const r = await s.run();
    expect(r.status).toBe(500);
    expect(String(r.payload.error)).toMatch(/created at the provider but could not be recorded/);
  });
  it("checks every field before anything happens", async () => {
    for (const extra of [
      { wholesalerId: "nope" },
      { businessName: "A" },
      { businessName: 5 },
      { bankCode: "bad code!" },
      { bankCode: undefined },
      { accountNumber: "12ab" },
      { accountNumber: "123" },
      { accountNumber: "1".repeat(25) },
    ]) {
      const s = setup({ body: register(extra) });
      expect((await s.run()).status).toBe(400);
      expect(s.rpcCalls.map((c) => c.fn)).toEqual(["payment_user_is_admin"]);
      expect(s.providerCalls).toHaveLength(0);
    }
  });
  it("needs the server to be configured for online payments", async () => {
    const s = setup({ body: register(), configOn: false });
    expect((await s.run()).status).toBe(503);
    expect(s.rpcCalls.map((c) => c.fn)).toEqual(["payment_user_is_admin"]);
  });
});

describe("the other actions", () => {
  it("lists the banks", async () => {
    const s = setup({
      body: { action: "banks" },
      provider: { body: { status: true, data: [{ name: "GCB Bank", code: "GCB" }] } },
    });
    const r = await s.run();
    expect(r.payload).toEqual({ banks: [{ name: "GCB Bank", code: "GCB" }] });
  });
  it("says so when the list cannot be read", async () => {
    expect((await setup({ body: { action: "banks" }, provider: "offline" }).run()).status).toBe(
      502,
    );
  });
  it("switches an account off or on (also while online payments are not configured here), and refuses a bad request", async () => {
    const s = setup({
      body: { action: "set_active", accountId: ACCOUNT, active: false },
      configOn: false,
    });
    const r = await s.run();
    expect(r.payload).toEqual({ status: "inactive" });
    expect(s.rpcCalls[1]).toEqual({
      fn: "admin_set_payout_account_status",
      args: { p_admin_id: ADMIN, p_id: ACCOUNT, p_active: false },
    });
    expect(
      (await setup({ body: { action: "set_active", accountId: "x", active: false } }).run()).status,
    ).toBe(400);
    expect(
      (await setup({ body: { action: "set_active", accountId: ACCOUNT, active: "no" } }).run())
        .status,
    ).toBe(400);
  });
  it("passes the database's reason on", async () => {
    const s = setup({
      body: { action: "set_active", accountId: ACCOUNT, active: true },
      rpc: (c) =>
        c.fn === "admin_set_payout_account_status"
          ? {
              data: null,
              error: { message: "Only a switched-off account can be switched back on." },
            }
          : undefined,
    });
    const r = await s.run();
    expect(r.status).toBe(400);
    expect(r.payload.error).toBe("Only a switched-off account can be switched back on.");
  });
});

describe("the server's own checks", () => {
  const good = {
    PAYMENTS_MODE: "test",
    PAYSTACK_SECRET_KEY: SECRET,
    CRON_SECRET: "c",
    SITE_URL: "https://x.test",
  };
  it("answers yes or no for each, and never reveals a value", async () => {
    const s = setup({ body: { action: "checks" }, env: good, configOn: false });
    const r = await s.run();
    expect(r.status).toBe(200);
    expect(r.payload.mode).toBe("test");
    const checks = r.payload.checks as { key: string; ok: boolean }[];
    expect(checks.every((c) => c.ok)).toBe(true);
    const text = JSON.stringify(r.payload);
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain("https://x.test");
  });
  it("catches a missing mode, a key of the wrong kind, a missing live switch, a missing scheduler secret, a missing site address and a local stand-in", () => {
    const ok = (env: Record<string, string | undefined>, key: string) =>
      serverChecks(env).checks.find((c) => c.key === key)!.ok;
    expect(ok({}, "mode_set")).toBe(false);
    expect(ok({ ...good, PAYMENTS_MODE: "live" }, "key_matches_mode")).toBe(false);
    expect(ok({ PAYMENTS_MODE: "live", PAYSTACK_SECRET_KEY: "sk_live_x" }, "live_switch")).toBe(
      false,
    );
    expect(
      ok(
        { PAYMENTS_MODE: "live", PAYSTACK_SECRET_KEY: "sk_live_x", PAYMENTS_LIVE_ENABLED: "yes" },
        "live_switch",
      ),
    ).toBe(true);
    expect(ok({ ...good, CRON_SECRET: "" }, "cron_secret")).toBe(false);
    expect(ok({ ...good, SITE_URL: undefined }, "site_address")).toBe(false);
    expect(ok({ ...good, PAYSTACK_BASE_URL: "http://127.0.0.1:4010" }, "no_local_stand_in")).toBe(
      false,
    );
    expect(ok({ PAYMENTS_MODE: "test", PAYSTACK_SECRET_KEY: "garbage" }, "key_present")).toBe(
      false,
    );
  });
  it("is for administrators only", async () => {
    expect((await setup({ body: { action: "checks" }, admin: false }).run()).status).toBe(403);
  });
});
