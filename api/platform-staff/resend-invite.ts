import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

function firstHeaderValue(value: string | string[] | undefined) {
  if (Array.isArray(value)) {
    return value[0];
  }

  return value;
}

function normalizeSiteUrl(value: string | undefined) {
  const trimmed = value?.trim();
  if (!trimmed) {
    return "";
  }

  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed.replace(/\/+$/, "");
  }

  return `https://${trimmed.replace(/\/+$/, "")}`;
}

function getInviteRedirectUrl(req: VercelRequest, path: string) {
  const forwardedHost = firstHeaderValue(req.headers["x-forwarded-host"]);
  const forwardedProto = firstHeaderValue(req.headers["x-forwarded-proto"]) ?? "https";
  const fallbackHost = forwardedHost ?? firstHeaderValue(req.headers.host);

  const siteUrlCandidates = [
    process.env.SITE_URL,
    process.env.VITE_SITE_URL,
    process.env.VERCEL_PROJECT_PRODUCTION_URL,
    process.env.VERCEL_URL,
    firstHeaderValue(req.headers.origin),
    fallbackHost ? `${forwardedProto}://${fallbackHost}` : undefined,
  ];

  for (const candidate of siteUrlCandidates) {
    const normalizedSiteUrl = normalizeSiteUrl(candidate);
    if (!normalizedSiteUrl) {
      continue;
    }

    return new URL(path.replace(/^\/+/, ""), `${normalizedSiteUrl}/`).toString();
  }

  return undefined;
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

  const { staffId } = req.body ?? {};
  if (!staffId) {
    return res.status(400).json({ error: "staffId is required" });
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
    return res.status(403).json({ error: "Only platform admins can resend access emails" });
  }

  const { data: staffRow, error: staffErr } = await admin
    .from("platform_staff")
    .select("id, user_id, role, status")
    .eq("id", staffId)
    .maybeSingle();

  if (staffErr) {
    return res.status(500).json({ error: staffErr.message });
  }

  if (!staffRow) {
    return res.status(404).json({ error: "Platform staff record not found" });
  }

  if (staffRow.role === "owner" && callerStaff.role !== "owner") {
    return res.status(403).json({ error: "Only the platform owner can manage owner access" });
  }

  if (staffRow.status === "inactive") {
    return res
      .status(400)
      .json({ error: "Reactivate this platform staff member before sending an access email" });
  }

  const {
    data: { user: invitedUser },
    error: invitedUserErr,
  } = await admin.auth.admin.getUserById(staffRow.user_id);

  if (invitedUserErr) {
    return res.status(500).json({ error: invitedUserErr.message });
  }

  if (!invitedUser?.email) {
    return res.status(400).json({ error: "The invited user does not have an email address" });
  }

  const redirectTo = getInviteRedirectUrl(req, "/reset-password");
  const { error: resendErr } = await admin.auth.resetPasswordForEmail(invitedUser.email, {
    ...(redirectTo ? { redirectTo } : {}),
  });

  if (resendErr) {
    return res.status(500).json({ error: resendErr.message || "Failed to resend access email" });
  }

  return res.status(200).json({ ok: true });
}
