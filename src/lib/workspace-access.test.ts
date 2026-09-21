import { describe, expect, it } from "vitest";
import { resolveWorkspaceAccess, type WorkspaceAccessInput } from "./workspace-access";

const base: WorkspaceAccessInput = {
  loading: false,
  hasUser: true,
  loadError: false,
  roles: ["pharmacy"],
  business: { verification_status: "approved" },
  businessCount: 1,
};

const decide = (overrides: Partial<WorkspaceAccessInput>) =>
  resolveWorkspaceAccess({ ...base, ...overrides });

describe("resolveWorkspaceAccess", () => {
  it("shows a neutral loading state while resolving", () => {
    expect(decide({ loading: true })).toEqual({ kind: "loading" });
  });

  it("sends signed-out users to login", () => {
    expect(decide({ hasUser: false, business: null, businessCount: 0 })).toEqual({
      kind: "redirect",
      to: "/login",
    });
  });

  it("fails closed when status cannot be resolved", () => {
    expect(decide({ loadError: true })).toEqual({ kind: "error" });
    expect(decide({ loadError: true, business: null, businessCount: 0 })).toEqual({
      kind: "error",
    });
  });

  it.each(["pending", "rejected"] as const)("sends %s businesses to onboarding", (status) => {
    expect(decide({ business: { verification_status: status } })).toEqual({
      kind: "redirect",
      to: "/onboarding",
    });
    expect(decide({ roles: ["wholesaler"], business: { verification_status: status } })).toEqual({
      kind: "redirect",
      to: "/onboarding",
    });
  });

  it("does not let staff bypass business verification", () => {
    // Staff resolve the same business record; its status is what matters.
    expect(decide({ roles: [], business: { verification_status: "pending" } })).toEqual({
      kind: "redirect",
      to: "/onboarding",
    });
  });

  it("allows approved businesses", () => {
    expect(decide({})).toEqual({ kind: "allow" });
    expect(decide({ roles: ["wholesaler"] })).toEqual({ kind: "allow" });
  });

  it("sends users without a business to onboarding, admins to /admin", () => {
    expect(decide({ business: null, businessCount: 0 })).toEqual({
      kind: "redirect",
      to: "/onboarding",
    });
    expect(decide({ business: null, businessCount: 0, roles: ["admin"] })).toEqual({
      kind: "redirect",
      to: "/admin",
    });
  });

  it("only allows the chooser to render without an active business", () => {
    expect(decide({ business: null, businessCount: 2 })).toEqual({
      kind: "redirect",
      to: "/dashboard",
    });
    expect(decide({ business: null, businessCount: 2, allowWorkspaceChooser: true })).toEqual({
      kind: "allow",
    });
  });

  it("re-evaluates on status change (pending -> approved)", () => {
    expect(decide({ business: { verification_status: "pending" } }).kind).toBe("redirect");
    expect(decide({ business: { verification_status: "approved" } }).kind).toBe("allow");
  });
});

describe("resolveWorkspaceAccess with several businesses", () => {
  const businesses = {
    approved: { verification_status: "approved" as const },
    pending: { verification_status: "pending" as const },
  };

  it("evaluates the selected business, not the user", () => {
    const selectApproved = resolveWorkspaceAccess({
      ...base,
      business: businesses.approved,
      businessCount: 2,
    });
    const selectPending = resolveWorkspaceAccess({
      ...base,
      business: businesses.pending,
      businessCount: 2,
    });

    expect(selectApproved).toEqual({ kind: "allow" });
    expect(selectPending).toEqual({ kind: "redirect", to: "/onboarding" });
  });

  it("does not open any workspace until one is chosen", () => {
    expect(resolveWorkspaceAccess({ ...base, business: null, businessCount: 2 })).toEqual({
      kind: "redirect",
      to: "/dashboard",
    });
  });
});
