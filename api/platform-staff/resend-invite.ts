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

    const { data: member } = await admin
      .from("platform_staff")
      .select("user_id,role,status")
      .eq("id", req.body?.staffId)
      .maybeSingle();
    if (!member || member.role !== "admin" || member.status !== "pending")
      return res
        .status(400)
        .json({ error: "Only pending administrator invitations can be resent" });
    const {
      data: { user: target },
      error,
    } = await admin.auth.admin.getUserById(member.user_id);
    if (error || !target?.email) throw new Error("Invitation account unavailable");
    const { error: sendError } = await admin.auth.resetPasswordForEmail(target.email, {
      redirectTo: trustedSiteUrl("/reset-password"),
    });
    if (sendError) throw sendError;
    return res.status(200).json({ ok: true });
  } catch (error) {
    return res
      .status(error instanceof Error && error.message === "Unauthorized" ? 401 : 400)
      .json({ error: error instanceof Error ? error.message : "Platform operation failed" });
  }
}
