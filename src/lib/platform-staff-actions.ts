import { supabase } from "@/integrations/supabase/client";

export type PlatformStaffRole = "owner" | "admin";
export type PlatformStaffStatus = "active" | "inactive" | "pending";

export type PlatformStaffMember = {
  id: string;
  user_id: string;
  role: PlatformStaffRole;
  status: PlatformStaffStatus;
  invited_at: string;
  joined_at: string | null;
  full_name: string | null;
  phone: string | null;
  user_email: string | null;
};

type InvitePlatformStaffInput = {
  email: string;
};

type InvitePlatformStaffResult = {
  mode: "existing-account" | "invited";
};

type ResendPlatformStaffInviteInput = {
  staffId: string;
};

type UpdatePlatformStaffMemberInput = {
  staffId: string;
  fullName: string;
  email: string;
  phone: string;
  role: PlatformStaffRole;
  status: PlatformStaffStatus;
};

async function getRequiredSession() {
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session) {
    throw new Error("You must be signed in to manage platform staff.");
  }

  return session;
}

function sortPlatformStaffMembers(left: PlatformStaffMember, right: PlatformStaffMember) {
  const roleOrder: Record<PlatformStaffRole, number> = {
    owner: 0,
    admin: 1,
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

export async function listPlatformStaff(): Promise<PlatformStaffMember[]> {
  const { data, error } = await supabase.rpc("list_platform_staff");

  if (error) {
    throw new Error(error.message || "Failed to load platform staff");
  }

  return ((data ?? []) as PlatformStaffMember[]).sort(sortPlatformStaffMembers);
}

export async function invitePlatformStaff(
  input: InvitePlatformStaffInput,
): Promise<InvitePlatformStaffResult> {
  const session = await getRequiredSession();

  const res = await fetch("/api/platform-staff/invite", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      email: input.email.trim().toLowerCase(),
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to add platform staff");
  }

  return { mode: data.mode };
}

export async function resendPlatformStaffInvite(
  input: ResendPlatformStaffInviteInput,
): Promise<{ ok: true }> {
  const session = await getRequiredSession();

  const res = await fetch("/api/platform-staff/resend-invite", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
      staffId: input.staffId,
    }),
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(data.error || "Failed to resend access email");
  }

  return { ok: true };
}

export async function updatePlatformStaffMember(
  input: UpdatePlatformStaffMemberInput,
): Promise<{ ok: true }> {
  const session = await getRequiredSession();

  const res = await fetch("/api/platform-staff/update", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({
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
    throw new Error(data.error || "Failed to update platform staff");
  }

  return { ok: true };
}
