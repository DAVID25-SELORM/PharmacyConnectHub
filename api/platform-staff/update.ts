import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

type PlatformStaffRole = "owner" | "admin";
type PlatformStaffStatus = "active" | "inactive" | "pending";

const validRoles = new Set<PlatformStaffRole>(["owner", "admin"]);
const validStatuses = new Set<PlatformStaffStatus>(["active", "inactive", "pending"]);

function normalizeOptionalText(value: unknown) {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function isAllowedStatusTransition(
  currentStatus: PlatformStaffStatus,
  nextStatus: PlatformStaffStatus,
) {
  if (currentStatus === nextStatus) {
    return true;
  }

  if (currentStatus === "pending") {
    return nextStatus === "active" || nextStatus === "inactive";
  }

  if (currentStatus === "active") {
    return nextStatus === "inactive";
  }

  return nextStatus === "active";
}

async function hasBusinessAccess(admin: ReturnType<typeof createClient>, userId: string) {
  const [{ data: ownedBusiness }, { data: activeBusinessStaff }] = await Promise.all([
    admin.from("businesses").select("id").eq("owner_id", userId).limit(1).maybeSingle(),
    admin
      .from("business_staff")
      .select("id")
      .eq("user_id", userId)
      .in("status", ["active", "pending"])
      .limit(1)
      .maybeSingle(),
  ]);

  return Boolean(ownedBusiness || activeBusinessStaff);
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceKey) {
    return res.status(500).json({ error: "Server misconfigured" });
  }

  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing authorization" });
  }

  const admin = createClient(supabaseUrl, serviceKey);
  const {
    data: { user: caller },
    error: authErr,
  } = await admin.auth.getUser(authHeader.slice(7));

  if (authErr || !caller) {
    return res.status(401).json({ error: "Invalid token" });
  }

  const { staffId, fullName, email, phone, role, status } = req.body ?? {};
  const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
  const normalizedFullName = normalizeOptionalText(fullName);
  const normalizedPhone = normalizeOptionalText(phone);

  if (!staffId || !normalizedEmail) {
    return res.status(400).json({ error: "staffId and email are required" });
  }

  if (
    role !== undefined &&
    (typeof role !== "string" || !validRoles.has(role as PlatformStaffRole))
  ) {
    return res.status(400).json({ error: "Invalid role" });
  }

  if (
    status !== undefined &&
    (typeof status !== "string" || !validStatuses.has(status as PlatformStaffStatus))
  ) {
    return res.status(400).json({ error: "Invalid status" });
  }

  const { data: callerStaff, error: callerStaffErr } = await admin
    .from("platform_staff")
    .select("role")
    .eq("user_id", caller.id)
    .eq("status", "active")
    .maybeSingle();

  if (callerStaffErr) {
    return res.status(500).json({ error: callerStaffErr.message });
  }

  if (!callerStaff) {
    return res.status(403).json({ error: "Only platform admins can edit platform staff" });
  }

  const { data: staffRow, error: staffErr } = await admin
    .from("platform_staff")
    .select("id, user_id, role, status, joined_at")
    .eq("id", staffId)
    .maybeSingle();

  if (staffErr) {
    return res.status(500).json({ error: staffErr.message });
  }

  if (!staffRow) {
    return res.status(404).json({ error: "Platform staff record not found" });
  }

  const nextRole = (typeof role === "string" ? role : staffRow.role) as PlatformStaffRole;
  const nextStatus = (typeof status === "string" ? status : staffRow.status) as PlatformStaffStatus;
  const isOwnerRecord = staffRow.role === "owner";

  if (isOwnerRecord && callerStaff.role !== "owner") {
    return res.status(403).json({ error: "Only the platform owner can edit owner details" });
  }

  if (isOwnerRecord && nextRole !== "owner") {
    return res.status(400).json({ error: "The platform owner must keep the owner role" });
  }

  if (isOwnerRecord && nextStatus !== "active") {
    return res.status(400).json({ error: "The platform owner must remain active" });
  }

  if (!isOwnerRecord && nextRole === "owner") {
    return res.status(400).json({ error: "Owner role is reserved for the platform owner" });
  }

  if (!isAllowedStatusTransition(staffRow.status as PlatformStaffStatus, nextStatus)) {
    return res.status(400).json({ error: "That status change is not allowed" });
  }

  const isGrantingPlatformAccess =
    !isOwnerRecord &&
    nextStatus !== "inactive" &&
    (staffRow.status === "inactive" || nextStatus !== staffRow.status);

  if (isGrantingPlatformAccess && (await hasBusinessAccess(admin, staffRow.user_id))) {
    return res.status(400).json({
      error:
        "This person already has business workspace access. Keep business staff and platform staff separate.",
    });
  }

  const {
    data: { user: targetUser },
    error: userErr,
  } = await admin.auth.admin.getUserById(staffRow.user_id);

  if (userErr || !targetUser) {
    return res.status(500).json({ error: userErr?.message || "Unable to load staff account" });
  }

  const currentEmail = targetUser.email?.trim().toLowerCase() ?? "";
  if (normalizedEmail !== currentEmail) {
    const { error: updateUserErr } = await admin.auth.admin.updateUserById(staffRow.user_id, {
      email: normalizedEmail,
      email_confirm: true,
    });

    if (updateUserErr) {
      return res.status(400).json({ error: updateUserErr.message || "Failed to update email" });
    }
  }

  const { error: profileErr } = await admin.from("profiles").upsert(
    {
      id: staffRow.user_id,
      full_name: normalizedFullName,
      phone: normalizedPhone,
    },
    { onConflict: "id" },
  );

  if (profileErr) {
    return res.status(500).json({ error: profileErr.message });
  }

  const staffUpdate: {
    joined_at?: string;
    role?: PlatformStaffRole;
    status?: PlatformStaffStatus;
  } = {};

  if (nextRole !== staffRow.role) {
    staffUpdate.role = nextRole;
  }

  if (nextStatus !== staffRow.status) {
    staffUpdate.status = nextStatus;
    if (nextStatus === "active" && !staffRow.joined_at) {
      staffUpdate.joined_at = new Date().toISOString();
    }
  }

  if (Object.keys(staffUpdate).length > 0) {
    const { error: updateStaffErr } = await admin
      .from("platform_staff")
      .update(staffUpdate)
      .eq("id", staffId);

    if (updateStaffErr) {
      return res.status(500).json({ error: updateStaffErr.message });
    }
  }

  return res.status(200).json({ ok: true });
}
