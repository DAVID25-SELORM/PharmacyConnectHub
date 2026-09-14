import type { VercelRequest, VercelResponse } from "@vercel/node";
import { serverContext } from "../_server-context.js";
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  try {
    const { admin, caller, user } = await serverContext(req);
    const { data: owner, error: ownerError } = await caller.rpc("is_platform_owner", {
      _user_id: user.id,
    });
    if (ownerError || !owner)
      return res.status(403).json({ error: "Only the platform owner can manage platform staff" });

    const { data: member, error } = await admin
      .from("platform_staff")
      .select("user_id,role")
      .eq("id", req.body?.staffId)
      .maybeSingle();
    if (error || !member) return res.status(404).json({ error: "Member not found" });
    if (req.body?.role && req.body.role !== member.role)
      return res.status(403).json({ error: "Owner role cannot be reassigned" });
    const { error: change } = await caller.rpc("manage_platform_member", {
      _user_id: member.user_id,
      _status: req.body?.status,
    });
    if (change) return res.status(400).json({ error: change.message });
    return res.status(200).json({ ok: true });
  } catch (error) {
    return res
      .status(error instanceof Error && error.message === "Unauthorized" ? 401 : 400)
      .json({ error: error instanceof Error ? error.message : "Platform operation failed" });
  }
}
