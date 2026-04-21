import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";

type RequestItem = {
  productId: string;
  quantity: number;
};

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

  const pharmacyId = typeof req.body?.pharmacyId === "string" ? req.body.pharmacyId : "";
  const items = Array.isArray(req.body?.items) ? (req.body.items as RequestItem[]) : [];

  if (!pharmacyId || items.length === 0) {
    return res.status(400).json({ error: "pharmacyId and at least one item are required" });
  }

  if (
    items.some(
      (item) =>
        typeof item?.productId !== "string" ||
        !item.productId ||
        !Number.isInteger(item.quantity) ||
        item.quantity <= 0,
    )
  ) {
    return res.status(400).json({ error: "Each item needs a valid productId and quantity" });
  }

  const { data, error } = await admin.rpc("create_marketplace_orders", {
    _caller_id: caller.id,
    _items: items,
    _pharmacy_id: pharmacyId,
  });

  if (error) {
    return res.status(400).json({ error: error.message || "Failed to place order" });
  }

  return res.status(200).json({
    orderCount: Number(data) || 0,
  });
}
