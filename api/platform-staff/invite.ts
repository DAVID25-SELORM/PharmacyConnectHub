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

  const { email } = req.body ?? {};
  const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
  if (!normalizedEmail) {
    return res.status(400).json({ error: "email is required" });
  }

  if (caller.email?.toLowerCase() === normalizedEmail) {
    return res.status(400).json({ error: "You cannot invite yourself" });
  }

  const { data: callerStaff, error: callerStaffErr } = await admin
    .from("platform_staff")
    .select("id")
    .eq("user_id", caller.id)
    .eq("status", "active")
    .maybeSingle();

  if (callerStaffErr) {
    return res.status(500).json({ error: callerStaffErr.message });
  }

  if (!callerStaff) {
    return res.status(403).json({ error: "Only platform admins can invite platform staff" });
  }

  const { data: existingUserId } = await admin.rpc("lookup_user_id_by_email", {
    _email: normalizedEmail,
  });

  if (existingUserId && (await hasBusinessAccess(admin, existingUserId))) {
    return res.status(400).json({
      error:
        "This person already has business workspace access. Keep business staff and platform staff separate.",
    });
  }

  if (existingUserId) {
    const { error: staffErr } = await admin.from("platform_staff").upsert(
      {
        user_id: existingUserId,
        role: "admin",
        status: "active",
        invited_by: caller.id,
        joined_at: new Date().toISOString(),
      },
      { onConflict: "user_id" },
    );

    if (staffErr) {
      return res.status(400).json({ error: staffErr.message });
    }

    return res.status(200).json({ mode: "existing-account" });
  }

  const redirectTo = getInviteRedirectUrl(req, "/reset-password");
  const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(
    normalizedEmail,
    {
      data: { is_staff_invite: true, invite_interface: "platform" },
      ...(redirectTo ? { redirectTo } : {}),
    },
  );

  if (inviteErr || !invited?.user) {
    return res.status(500).json({ error: inviteErr?.message || "Failed to send invite" });
  }

  const { error: staffErr } = await admin.from("platform_staff").insert({
    user_id: invited.user.id,
    role: "admin",
    status: "pending",
    invited_by: caller.id,
  });

  if (staffErr) {
    return res.status(500).json({ error: staffErr.message });
  }

  return res.status(200).json({ mode: "invited" });
}
