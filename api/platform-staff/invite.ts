import type { VercelRequest, VercelResponse } from "@vercel/node";
import { serverContext, trustedSiteUrl } from "../_server-context.js";
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  try {
    const { admin, caller, user } = await serverContext(req);
    const { data: owner, error: ownerError } = await caller.rpc("is_platform_owner", {
      _user_id: user.id,
    });
    if (ownerError || !owner)
      return res.status(403).json({ error: "Only the platform owner can manage platform staff" });

    const email = typeof req.body?.email === "string" ? req.body.email.trim().toLowerCase() : "";
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
      return res.status(400).json({ error: "Valid email required" });
    const { data: existing, error: lookupError } = await admin.rpc("lookup_user_id_by_email", {
      _email: email,
    });
    if (lookupError) throw lookupError;
    if (existing)
      return res
        .status(409)
        .json({ error: "An account already exists. No platform membership was changed." });
    const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { is_staff_invite: true, invite_interface: "platform" },
      redirectTo: trustedSiteUrl("/reset-password"),
    });
    if (error || !data.user) throw error ?? new Error("Invitation failed");
    const { error: membershipError } = await caller.rpc("manage_platform_member", {
      _user_id: data.user.id,
      _status: "pending",
    });
    if (membershipError) throw membershipError;
    return res.status(200).json({ mode: "invited" });
  } catch (error) {
    return res
      .status(error instanceof Error && error.message === "Unauthorized" ? 401 : 400)
      .json({ error: error instanceof Error ? error.message : "Platform operation failed" });
  }
}
