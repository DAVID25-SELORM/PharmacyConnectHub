import type { AppRole, Business } from "@/hooks/use-session";

export type WorkspaceAccessInput = {
  loading: boolean;
  hasUser: boolean;
  loadError: boolean;
  roles: AppRole[];
  business: Pick<Business, "verification_status"> | null;
  businessCount: number;
  /** Only the workspace chooser (/dashboard) may render without an active business. */
  allowWorkspaceChooser?: boolean;
};

export type WorkspaceAccessDecision =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "redirect"; to: "/login" | "/onboarding" | "/admin" | "/dashboard" }
  | { kind: "allow" };

/**
 * Decides whether the current session may see an operational business workspace.
 * Business verification is authoritative: pending and rejected businesses (and their
 * staff) are sent to onboarding. Unknown state fails closed.
 */
export function resolveWorkspaceAccess(input: WorkspaceAccessInput): WorkspaceAccessDecision {
  if (input.loading) return { kind: "loading" };
  if (!input.hasUser) return { kind: "redirect", to: "/login" };
  if (input.loadError) return { kind: "error" };

  if (!input.business) {
    if (input.businessCount > 1) {
      return input.allowWorkspaceChooser
        ? { kind: "allow" }
        : { kind: "redirect", to: "/dashboard" };
    }
    return input.roles.includes("admin")
      ? { kind: "redirect", to: "/admin" }
      : { kind: "redirect", to: "/onboarding" };
  }

  if (input.business.verification_status !== "approved") {
    return { kind: "redirect", to: "/onboarding" };
  }

  return { kind: "allow" };
}
