import { beforeEach, expect, it, vi } from "vitest";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import invite from "./platform-staff/invite";
import { receiptHandler } from "./_receipt-delivery";
const s = vi.hoisted(() => ({
  owner: true,
  existing: null as string | null,
  unauthorized: false,
  job: "sent",
  send: vi.fn(),
  rpc: vi.fn(),
  invite: vi.fn(),
}));
vi.mock("./_server-context.js", () => ({
  trustedSiteUrl: () => "https://example.test/reset-password",
  serverContext: async () => {
    if (s.unauthorized) throw new Error("Unauthorized");
    const party = { owner_id: "buyer", name: "Business", city: null, region: null };
    const chain = {
      select: () => chain,
      eq: () => chain,
      single: async () => ({
        data: {
          id: "order",
          order_number: "DX1",
          total_ghs: 10,
          delivered_at: null,
          paid_at: null,
          payment_method: "cod",
          pharmacy: party,
          wholesaler: party,
          order_items: [],
        },
        error: null,
      }),
    };
    return {
      user: { id: "owner" },
      caller: {
        from: () => chain,
        rpc: async (name: string, args: unknown) => {
          s.rpc(name, args);
          return { data: name === "is_platform_owner" ? s.owner : null, error: null };
        },
      },
      admin: {
        rpc: async (name: string, args: Record<string, unknown>) => {
          s.rpc(name, args);
          return {
            data:
              name === "lookup_user_id_by_email"
                ? s.existing
                : name === "claim_order_receipt"
                  ? { status: s.job, claim_id: "claim", payload: args._payload }
                  : null,
            error: null,
          };
        },
        auth: {
          admin: {
            inviteUserByEmail: s.invite,
            getUserById: async () => ({
              data: { user: { email: "buyer@example.test" } },
              error: null,
            }),
          },
        },
      },
    };
  },
}));
vi.mock("./_order-receipts.js", () => ({ sendOrderReceiptEmail: s.send }));
const req = (body: object) => ({ method: "POST", body, headers: {} }) as VercelRequest;
const res = () => {
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  return { response: { status } as unknown as VercelResponse, status, json };
};
beforeEach(() => {
  s.owner = true;
  s.existing = null;
  s.unauthorized = false;
  s.job = "sent";
  s.rpc.mockClear();
  s.invite.mockReset().mockResolvedValue({ data: { user: { id: "new-user" } }, error: null });
  s.send.mockReset().mockResolvedValue({ ok: false, error: "Provider unavailable" });
});
it("rejects unauthorized platform invitation before mutation", async () => {
  s.unauthorized = true;
  const r = res();
  await invite(req({ email: "admin@example.test" }), r.response);
  expect(r.status).toHaveBeenCalledWith(401);
  expect(s.invite).not.toHaveBeenCalled();
});
it("normal admin cannot invite", async () => {
  s.owner = false;
  const r = res();
  await invite(req({ email: "admin@example.test" }), r.response);
  expect(r.status).toHaveBeenCalledWith(403);
  expect(s.invite).not.toHaveBeenCalled();
});
it("existing account cannot be overwritten by owner invitation", async () => {
  s.existing = "protected-owner";
  const r = res();
  await invite(req({ email: "admin@example.test" }), r.response);
  expect(r.status).toHaveBeenCalledWith(409);
  expect(s.invite).not.toHaveBeenCalled();
  expect(s.rpc).not.toHaveBeenCalledWith("manage_platform_member", expect.anything());
});
it("owner invitation explicitly creates pending membership", async () => {
  const r = res();
  await invite(req({ email: "new@example.test" }), r.response);
  expect(s.rpc).toHaveBeenCalledWith("manage_platform_member", {
    _user_id: "new-user",
    _status: "pending",
  });
});
it("recorded receipt success never calls provider again", async () => {
  const r = res();
  await receiptHandler(req({ orderId: "order" }), r.response, false);
  expect(s.send).not.toHaveBeenCalled();
  expect(r.json).toHaveBeenCalledWith(expect.objectContaining({ receiptSent: true }));
});
it("receipt failure keeps confirmed payment and records retry result", async () => {
  s.job = "claimed";
  const r = res();
  await receiptHandler(req({ orderId: "order" }), r.response, true);
  expect(s.rpc).toHaveBeenCalledWith("confirm_order_payment", { _order_id: "order" });
  expect(s.send).toHaveBeenCalledWith(
    expect.objectContaining({ idempotencyKey: "drugxone-receipt/order" }),
  );
  expect(s.rpc).toHaveBeenCalledWith(
    "finish_order_receipt",
    expect.objectContaining({ _error: "Provider unavailable" }),
  );
  expect(r.status).toHaveBeenCalledWith(200);
  expect(r.json).toHaveBeenCalledWith(expect.objectContaining({ ok: true, receiptSent: false }));
});
it("active or uncertain receipt lease never calls provider", async () => {
  for (const status of ["sending", "uncertain"]) {
    s.job = status;
    const r = res();
    await receiptHandler(req({ orderId: "order" }), r.response, false);
  }
  expect(s.send).not.toHaveBeenCalled();
});
