import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import { normalizeBrandingImage } from "./_branding-image.js";

export default async function upload(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return res.status(503).json({ error: "Logo upload is unavailable." });
  const token = req.headers.authorization?.replace(/^Bearer /, "");
  if (!token) return res.status(401).json({ error: "Sign in first." });
  const admin = createClient(url, key, { auth: { persistSession: false } });
  const {
    data: { user },
    error,
  } = await admin.auth.getUser(token);
  if (error || !user) return res.status(401).json({ error: "Sign in again." });
  const businessId = req.body?.businessId;
  if (typeof businessId !== "string" || !/^[0-9a-f-]{36}$/i.test(businessId))
    return res.status(400).json({ error: "Invalid business." });
  const caller = createClient(url, key, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false },
  });
  const { data: allowed, error: denied } = await caller.rpc("can_manage_document_branding", {
    p_business_id: businessId,
  });
  if (denied || !allowed) {
    await admin
      .from("document_branding_events")
      .insert({
        business_id: businessId,
        actor_id: user.id,
        action: "upload_rejected",
        details: { reason: "permission" },
      });
    return res.status(403).json({ error: "Business manager permission is required." });
  }
  try {
    const encoded = req.body?.image;
    if (
      typeof encoded !== "string" ||
      encoded.length > 2796204 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)
    )
      throw new Error("Invalid image payload.");
    const output = await normalizeBrandingImage(Buffer.from(encoded, "base64"));
    const path = `${businessId}/${randomUUID()}.webp`;
    const { error: uploadError } = await admin.storage
      .from("business-document-logos")
      .upload(path, output, { contentType: "image/webp", upsert: false });
    if (uploadError) throw new Error("Could not store the logo. Please retry.");
    const { error: assetError } = await admin
      .from("document_branding_assets")
      .insert({ path, business_id: businessId, uploaded_by: user.id, byte_size: output.length });
    if (assetError) throw new Error("Could not register the logo. Please retry.");
    const { error: auditError } = await admin
      .from("document_branding_events")
      .insert({
        business_id: businessId,
        actor_id: user.id,
        action: "logo_uploaded",
        details: { path },
      });
    if (auditError) throw new Error("Logo audit could not be recorded. Please retry.");
    return res.status(200).json({ path });
  } catch (error) {
    await admin
      .from("document_branding_events")
      .insert({
        business_id: businessId,
        actor_id: user.id,
        action: "upload_rejected",
        details: { reason: "validation_or_storage" },
      });
    return res
      .status(400)
      .json({ error: error instanceof Error ? error.message : "Logo upload failed." });
  }
}
