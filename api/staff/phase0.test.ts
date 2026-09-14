import { beforeEach, describe, expect, it, vi } from "vitest";
import type { VercelRequest, VercelResponse } from "@vercel/node";
import updateStaff from "./update";
import inviteStaff from "./invite";

const state = vi.hoisted(() => ({
  owner: "owner-a",
  targetEmail: "target@example.test",
  existingUser: "target-user" as string | null,
  membershipBusiness: "business-a",
  membershipStatus: "active",
  updates: [] as unknown[],
  globalUpdate: vi.fn(),
  invite: vi.fn(),
  profileWrite: vi.fn(),
}));

vi.mock("@supabase/supabase-js", () => ({
  createClient: () => ({
    auth: {
      getUser: async () => ({
        data: { user: { id: "owner-a", email: "owner@example.test" } },
        error: null,
      }),
      admin: {
        getUserById: async () => ({
          data: { user: { id: "target-user", email: state.targetEmail } },
          error: null,
        }),
        updateUserById: state.globalUpdate,
        inviteUserByEmail: state.invite,
      },
    },
    rpc: async () => ({ data: state.existingUser, error: null }),
    from: (table: string) => {
      const filters: Record<string, unknown> = {};
      const result = () => {
        let data: unknown = null;
        if (table === "businesses") data = { id: "business-a", owner_id: state.owner };
        if (table === "business_staff" && filters.business_id === state.membershipBusiness)
          data = {
            id: "staff-a",
            user_id: "target-user",
            role: "assistant",
            status: state.membershipStatus,
            joined_at: "2026-01-01",
          };
        return { data, error: null };
      };
      const chain = {
        select: () => chain,
        eq: (key: string, value: unknown) => {
          filters[key] = value;
          return chain;
        },
        in: () => chain,
        limit: () => chain,
        single: async () => result(),
        maybeSingle: async () => result(),
        update: (value: unknown) => {
          state.updates.push({ table, value });
          return chain;
        },
        upsert: (value: unknown) => {
          state.profileWrite(value);
          return chain;
        },
        insert: (value: unknown) => {
          state.updates.push({ table, value });
          return chain;
        },
        then: (resolve: (value: unknown) => unknown) => Promise.resolve(result()).then(resolve),
      };
      return chain;
    },
  }),
}));

function request(body: object) {
  return { method: "POST", headers: { authorization: "Bearer test-token" }, body } as VercelRequest;
}
function response() {
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  return { res: { status } as unknown as VercelResponse, status, json };
}
const payload = () => ({
  businessId: "business-a",
  staffId: "staff-a",
  email: state.targetEmail,
  role: "manager",
  status: "active",
});

beforeEach(() => {
  vi.stubEnv("SUPABASE_URL", "https://example.test");
  vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "test-only-placeholder");
  state.owner = "owner-a";
  state.existingUser = "target-user";
  state.membershipBusiness = "business-a";
  state.membershipStatus = "active";
  state.updates = [];
  vi.clearAllMocks();
});

describe("Phase 0 tenant staff API boundaries", () => {
  it("rejects changing an existing user's global email", async () => {
    const r = response();
    await updateStaff(request({ ...payload(), email: "attacker@example.test" }), r.res);
    expect(r.status).toHaveBeenCalledWith(403);
    expect(state.globalUpdate).not.toHaveBeenCalled();
    expect(state.profileWrite).not.toHaveBeenCalled();
    expect(state.updates).toEqual([]);
  });
  it("only updates tenant membership, ignoring global profile and credential payloads", async () => {
    const r = response();
    await updateStaff(
      request({ ...payload(), fullName: "Overwrite", phone: "999", password: "attacker-password" }),
      r.res,
    );
    expect(r.status).toHaveBeenCalledWith(200);
    expect(state.globalUpdate).not.toHaveBeenCalled();
    expect(state.profileWrite).not.toHaveBeenCalled();
    expect(state.updates).toEqual([{ table: "business_staff", value: { role: "manager" } }]);
  });
  it("rejects silently attaching an existing account", async () => {
    const r = response();
    await inviteStaff(
      request({ businessId: "business-a", email: state.targetEmail, role: "assistant" }),
      r.res,
    );
    expect(r.status).toHaveBeenCalledWith(409);
    expect(state.updates).toEqual([]);
    expect(state.invite).not.toHaveBeenCalled();
  });
  it("does not create a membership when Auth rejects an invitation", async () => {
    state.existingUser = null;
    state.invite.mockResolvedValueOnce({
      data: null,
      error: { message: "Account already exists" },
    });
    const r = response();
    await inviteStaff(
      request({ businessId: "business-a", email: state.targetEmail, role: "assistant" }),
      r.res,
    );
    expect(r.status).toHaveBeenCalledWith(500);
    expect(state.updates).toEqual([]);
  });
  it("creates a new invited account only as pending membership", async () => {
    state.existingUser = null;
    state.invite.mockResolvedValueOnce({ data: { user: { id: "new-invitee" } }, error: null });
    const r = response();
    await inviteStaff(
      request({ businessId: "business-a", email: state.targetEmail, role: "assistant" }),
      r.res,
    );
    expect(r.status).toHaveBeenCalledWith(200);
    expect(state.updates).toEqual([
      {
        table: "business_staff",
        value: {
          business_id: "business-a",
          user_id: "new-invitee",
          role: "assistant",
          status: "pending",
          invited_by: "owner-a",
        },
      },
    ]);
  });
  it("cannot update a membership belonging to a different business", async () => {
    state.membershipBusiness = "business-b";
    const r = response();
    await updateStaff(request(payload()), r.res);
    expect(r.status).toHaveBeenCalledWith(404);
    expect(state.updates).toEqual([]);
  });
  it("cannot manage another business", async () => {
    state.owner = "owner-b";
    const r = response();
    await updateStaff(request(payload()), r.res);
    expect(r.status).toHaveBeenCalledWith(403);
    expect(state.updates).toEqual([]);
  });
  it("cannot activate a pending invitation", async () => {
    state.membershipStatus = "pending";
    const r = response();
    await updateStaff(request(payload()), r.res);
    expect(r.status).toHaveBeenCalledWith(400);
    expect(state.updates).toEqual([]);
  });
});
