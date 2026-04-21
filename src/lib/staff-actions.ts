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
  mode: "existing-account" | "invited";
};

type ResendBusinessStaffInviteInput = {
  businessId: string;
  staffId: string;
};

type UpdateBusinessStaffMemberInput = {
  businessId: string;
  staffId: string;
  fullName: string;
  email: string;
  phone: string;
  role: BusinessStaffRole;
  status: StaffStatus;
};

async function getRequiredSession() {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    throw new Error("You must be signed in to manage staff.");
  }

  return session;
}

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

export async function listBusinessStaff(businessId: string): Promise<StaffMember[]> {
  const { data, error } = await supabase.rpc("list_business_staff", {
    _business_id: businessId,
  });

  if (error) {
    throw new Error(error.message || "Failed to load team members");
  }

  return ((data ?? []) as StaffMember[]).sort(sortStaffMembers);
}

/**
 * Add a staff member to a business by email.
 * Calls the /api/staff/invite serverless endpoint which:
 * - Adds existing users as active staff immediately
 * - Sends an email invite to new users and adds them as pending staff
 */
export async function inviteBusinessStaff(
  input: InviteBusinessStaffInput,
): Promise<InviteBusinessStaffResult> {
  const session = await getRequiredSession();

  const res = await fetch("/api/staff/invite", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      businessId: input.businessId,
      email: input.email.trim().toLowerCase(),
      role: input.role,
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to add staff member");
  }

  return { mode: data.mode };
}

export async function resendBusinessStaffInvite(
  input: ResendBusinessStaffInviteInput,
): Promise<{ ok: true }> {
  const session = await getRequiredSession();

  const res = await fetch("/api/staff/resend-invite", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      businessId: input.businessId,
      staffId: input.staffId,
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to resend access email");
  }

  return { ok: true };
}

export async function updateBusinessStaffMember(
  input: UpdateBusinessStaffMemberInput,
): Promise<{ ok: true }> {
  const session = await getRequiredSession();

  const res = await fetch("/api/staff/update", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      businessId: input.businessId,
      staffId: input.staffId,
      fullName: input.fullName,
      email: input.email.trim().toLowerCase(),
      phone: input.phone,
      role: input.role,
      status: input.status,
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to update staff member");
  }

  return { ok: true };
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
