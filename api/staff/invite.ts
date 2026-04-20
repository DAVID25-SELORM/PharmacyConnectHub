import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method not allowed" });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceKey) {
    return res.status(500).json({ error: "Server misconfigured" });
  }

  // 1. Authenticate the caller
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

  // 2. Validate input
  const { businessId, email, role } = req.body ?? {};
  if (!businessId || !email || !role) {
    return res.status(400).json({ error: "businessId, email, and role are required" });
  }
  if (!["manager", "cashier", "assistant"].includes(role)) {
    return res.status(400).json({ error: "Invalid role" });
  }
  const normalizedEmail = String(email).trim().toLowerCase();

  // 3. Prevent self-invite (owner could demote themselves)
  if (caller.email?.toLowerCase() === normalizedEmail) {
    return res.status(400).json({ error: "You cannot invite yourself" });
  }

  // 4. Verify caller owns the business
  const { data: biz } = await admin
    .from("businesses")
    .select("id, owner_id")
    .eq("id", businessId)
    .single();

  if (!biz || biz.owner_id !== caller.id) {
    return res.status(403).json({ error: "Only the business owner can invite staff" });
  }

  // 5. Look up existing user by email via RPC (avoids loading all users)
  const { data: existingUserId } = await admin.rpc("lookup_user_id_by_email", {
    _email: normalizedEmail,
  });

  if (existingUserId) {
    // User exists — add directly as active staff
    const { error: staffErr } = await admin.from("business_staff").upsert(
      {
        business_id: businessId,
        user_id: existingUserId,
        role,
        status: "active",
        invited_by: caller.id,
        joined_at: new Date().toISOString(),
      },
      { onConflict: "business_id,user_id" },
    );

    if (staffErr) {
      return res.status(400).json({ error: staffErr.message });
    }
    return res.status(200).json({ mode: "existing-account" });
  }

  // 6. User does not exist — invite them via email
  const siteUrl = process.env.SITE_URL || req.headers.origin || "";
  const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(
    normalizedEmail,
    {
      data: { is_staff_invite: true },
      redirectTo: `${siteUrl}/dashboard`,
    },
  );

  if (inviteErr || !invited?.user) {
    return res.status(500).json({ error: inviteErr?.message || "Failed to send invite" });
  }

  // 7. Insert staff record as pending
  const { error: staffErr } = await admin.from("business_staff").insert({
    business_id: businessId,
    user_id: invited.user.id,
    role,
    status: "pending",
    invited_by: caller.id,
  });

  if (staffErr) {
    return res.status(500).json({ error: staffErr.message });
  }

  return res.status(200).json({ mode: "invited" });
}
