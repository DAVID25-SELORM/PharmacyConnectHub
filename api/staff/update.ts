import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

type StaffRole = "owner" | "manager" | "cashier" | "assistant";
type StaffStatus = "active" | "inactive" | "pending";

const validRoles = new Set<StaffRole>(["owner", "manager", "cashier", "assistant"]);
const validStatuses = new Set<StaffStatus>(["active", "inactive", "pending"]);

function normalizeOptionalText(value: unknown) {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function isAllowedStatusTransition(currentStatus: StaffStatus, nextStatus: StaffStatus) {
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

  const { businessId, staffId, fullName, email, phone, role, status } = req.body ?? {};
  const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
  const normalizedFullName = normalizeOptionalText(fullName);
  const normalizedPhone = normalizeOptionalText(phone);

  if (!businessId || !staffId || !normalizedEmail) {
    return res.status(400).json({ error: "businessId, staffId, and email are required" });
  }

  if (role !== undefined && (typeof role !== "string" || !validRoles.has(role as StaffRole))) {
    return res.status(400).json({ error: "Invalid role" });
  }

  if (
    status !== undefined &&
    (typeof status !== "string" || !validStatuses.has(status as StaffStatus))
  ) {
    return res.status(400).json({ error: "Invalid status" });
  }

  const [{ data: business, error: businessErr }, { data: adminRole, error: adminRoleErr }] =
    await Promise.all([
      admin.from("businesses").select("id, owner_id").eq("id", businessId).maybeSingle(),
      admin
        .from("user_roles")
        .select("role")
        .eq("user_id", caller.id)
        .eq("role", "admin")
        .maybeSingle(),
    ]);

  if (businessErr) {
    return res.status(500).json({ error: businessErr.message });
  }

  if (adminRoleErr) {
    return res.status(500).json({ error: adminRoleErr.message });
  }

  const isAdmin = Boolean(adminRole);
  if (!business || (business.owner_id !== caller.id && !isAdmin)) {
    return res
      .status(403)
      .json({ error: "Only the business owner or an admin can edit staff details" });
  }

  const { data: staffRow, error: staffErr } = await admin
    .from("business_staff")
    .select("id, user_id, role, status, joined_at")
    .eq("id", staffId)
    .eq("business_id", businessId)
    .maybeSingle();

  if (staffErr) {
    return res.status(500).json({ error: staffErr.message });
  }

  if (!staffRow) {
    return res.status(404).json({ error: "Staff record not found" });
  }

  const nextRole = (typeof role === "string" ? role : staffRow.role) as StaffRole;
  const nextStatus = (typeof status === "string" ? status : staffRow.status) as StaffStatus;
  const isOwnerRecord = staffRow.user_id === business.owner_id;

  if (isOwnerRecord && nextRole !== "owner") {
    return res.status(400).json({ error: "The business owner must keep the owner role" });
  }

  if (isOwnerRecord && nextStatus !== "active") {
    return res.status(400).json({ error: "The business owner must remain active" });
  }

  if (!isOwnerRecord && nextRole === "owner") {
    return res.status(400).json({ error: "Owner role is reserved for the business owner" });
  }

  if (!isAllowedStatusTransition(staffRow.status as StaffStatus, nextStatus)) {
    return res.status(400).json({ error: "That status change is not allowed" });
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
    role?: StaffRole;
    status?: StaffStatus;
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
      .from("business_staff")
      .update(staffUpdate)
      .eq("id", staffId)
      .eq("business_id", businessId);

    if (updateStaffErr) {
      return res.status(500).json({ error: updateStaffErr.message });
    }
  }

  return res.status(200).json({ ok: true });
}
