import { beforeEach, expect, it, vi } from "vitest";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import handler from "./create";
const state = vi.hoisted(() => ({ rpc: vi.fn(), getUser: vi.fn() }));
vi.mock("@supabase/supabase-js", () => ({
  createClient: () => ({ auth: { getUser: state.getUser }, rpc: state.rpc }),
}));
beforeEach(() => {
  vi.stubEnv("SUPABASE_URL", "https://example.test");
  vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "test-only");
  state.rpc.mockReset().mockResolvedValue({ data: 2, error: null });
  state.getUser
    .mockReset()
    .mockResolvedValue({ data: { user: { id: "authenticated-user" } }, error: null });
});
async function call(body: object) {
  let status = 0;
  let data: unknown;
  const res = {
    status: (n: number) => {
      status = n;
      return res;
    },
    json: (v: unknown) => {
      data = v;
      return res;
    },
  };
  await handler(
    { method: "POST", headers: { authorization: "Bearer test" }, body } as VercelRequest,
    res as VercelResponse,
  );
  return { status, data };
}
const payload = {
  pharmacyId: "pharmacy",
  requestId: "11111111-1111-4111-8111-111111111111",
  items: [{ productId: "product", quantity: 2 }],
};
it("requires a durable key before invoking checkout", async () => {
  expect((await call({ ...payload, requestId: "" })).status).toBe(400);
  expect(state.rpc).not.toHaveBeenCalled();
});
it("forwards key and derives actor from authenticated token", async () => {
  expect((await call({ ...payload, callerId: "attacker" })).data).toEqual({ orderCount: 2 });
  expect(state.rpc).toHaveBeenCalledWith("create_marketplace_orders", {
    _caller_id: "authenticated-user",
    _pharmacy_id: "pharmacy",
    _items: payload.items,
    _request_id: payload.requestId,
  });
});
it("rejects invalid quantities", async () => {
  expect((await call({ ...payload, items: [{ productId: "product", quantity: -1 }] })).status).toBe(
    400,
  );
});
it("does not checkout with an invalid token", async () => {
  state.getUser.mockResolvedValue({ data: { user: null }, error: { message: "bad token" } });
  expect((await call(payload)).status).toBe(401);
  expect(state.rpc).not.toHaveBeenCalled();
});
it("reports idempotency payload conflicts without generating another key", async () => {
  state.rpc.mockResolvedValue({
    data: null,
    error: { message: "Checkout request ID already used for different data" },
  });
  expect((await call(payload)).status).toBe(400);
  expect(state.rpc).toHaveBeenCalledTimes(1);
});
