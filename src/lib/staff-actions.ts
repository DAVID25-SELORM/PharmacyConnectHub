import { supabase } from "@/integrations/supabase/client";
import type { BusinessStaffRole } from "@/hooks/use-session";

export type ManageableStaffRole = "manager" | "cashier" | "assistant";
export type StaffStatus = "active" | "inactive" | "pending";

export type StaffMember = {
  id: string;
  user_id: string;
  role: BusinessStaffRole;
  status: StaffStatus;
  invited_at: string;
  joined_at: string | null;
  full_name: string | null;
  phone: string | null;
  user_email: string | null;
};

type InviteBusinessStaffInput = {
  businessId: string;
  email: string;
  role: ManageableStaffRole;
};

type InviteBusinessStaffResult = {
  mode: "existing-account";
};

function sortStaffMembers(left: StaffMember, right: StaffMember) {
  const roleOrder: Record<BusinessStaffRole, number> = {
    owner: 0,
    manager: 1,
    cashier: 2,
    assistant: 3,
  };

  const leftRole = roleOrder[left.role] ?? 99;
  const rightRole = roleOrder[right.role] ?? 99;
  if (leftRole !== rightRole) {
    return leftRole - rightRole;
  }

  const leftJoined = left.joined_at ?? left.invited_at;
  const rightJoined = right.joined_at ?? right.invited_at;
  return new Date(rightJoined).getTime() - new Date(leftJoined).getTime();
}

async function getAccessToken() {
  const {
    data: { session },
  } = await supabase.auth.getSession();
  return session?.access_token ?? "";
}

export async function listBusinessStaff(businessId: string): Promise<StaffMember[]> {
  const accessToken = await getAccessToken();

  if (accessToken) {
    try {
      const response = await fetch("/api/staff/list", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ businessId }),
      });

      const payload = (await response.json().catch(() => null)) as {
        error?: string;
        staff?: StaffMember[];
      } | null;

      if (response.ok) {
        return (payload?.staff ?? []).sort(sortStaffMembers);
      }

      if (response.status === 401 || response.status === 403) {
        throw new Error(payload?.error || "Failed to load team members");
      }

      console.error("Staff list API failed; falling back to direct business_staff query.", {
        businessId,
        payload,
        status: response.status,
      });
    } catch (error) {
      console.error("Staff list API request failed; falling back to direct business_staff query.", {
        businessId,
        error,
      });
    }
  }

  const { data: fallbackData, error: fallbackError } = await supabase
    .from("business_staff")
    .select("id,user_id,role,status,invited_at,joined_at")
    .eq("business_id", businessId);

  if (fallbackError) {
    throw new Error(fallbackError.message || "Failed to load team members");
  }

  return (
    (fallbackData ?? []) as Array<
      Pick<StaffMember, "id" | "user_id" | "role" | "status" | "invited_at" | "joined_at">
    >
  )
    .map((member) => ({
      ...member,
      full_name: null,
      phone: null,
      user_email: null,
    }))
    .sort(sortStaffMembers);
}

/**
 * Add a staff member to a business by email.
 * Uses the Supabase RPC function 'add_business_staff_by_email' which:
 * - Looks up the user by email
 * - Adds them as active staff immediately (no invitation flow)
 * - Returns error if user doesn't exist
 */
export async function inviteBusinessStaff(
  input: InviteBusinessStaffInput,
): Promise<InviteBusinessStaffResult> {
  const { error } = await supabase.rpc("add_business_staff_by_email", {
    _business_id: input.businessId,
    _email: input.email.trim().toLowerCase(),
    _role: input.role,
  });

  if (error) {
    throw new Error(error.message || "Failed to add staff member");
  }

  return {
    mode: "existing-account",
  };
}

/**
 * Mark that the current user has joined their staff role.
 * This is a no-op in the direct RPC implementation since users are added as 'active' immediately.
 */
export async function markStaffMembershipJoined(): Promise<{ ok: true }> {
  // In the RPC implementation, staff are added as 'active' immediately
  // No additional action needed
  return { ok: true };
}
