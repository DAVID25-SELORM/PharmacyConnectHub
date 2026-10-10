import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import { loadPaymentsConfig } from "../_payments/config.js";

const VALID_ITEM_CATEGORIES = new Set(["nhis", "cash_private", "other"]);
const VALID_SETTLEMENT_METHODS = new Set([
  "cod",
  "credit",
  "bank_transfer",
  "momo",
  "cheque",
  "other",
]);

type RequestItem = {
  productId: string;
  quantity: number;
  category?: string;
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
  const requestId = typeof req.body?.requestId === "string" ? req.body.requestId : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)) {
    return res
      .status(400)
      .json({ error: "A valid checkout request ID is required. Refresh and try again." });
  }
  const items = Array.isArray(req.body?.items) ? (req.body.items as RequestItem[]) : [];
  const creditWholesalerIds = Array.isArray(req.body?.creditWholesalerIds)
    ? (req.body.creditWholesalerIds as unknown[]).filter(
        (id): id is string => typeof id === "string" && id.length > 0,
      )
    : [];

  // Payment method per supplier. Online payment is refused here unless this server is set up for it, and again in the
  // database unless the platform switch is on; choosing a method is never treated as payment (the order stays unpaid
  // until the provider confirms it).
  const rawMethods = req.body?.settlementMethods;
  const settlementMethods: Record<string, string> = {};
  if (rawMethods !== undefined && rawMethods !== null) {
    if (typeof rawMethods !== "object" || Array.isArray(rawMethods)) {
      return res
        .status(400)
        .json({ error: "settlementMethods must be a map of supplier to method" });
    }
    for (const [wholesalerId, method] of Object.entries(rawMethods as Record<string, unknown>)) {
      if (method === "pay_now") {
        if (!loadPaymentsConfig().ok) {
          return res
            .status(400)
            .json({ error: "Online payment is not available yet. Choose another payment method." });
        }
        settlementMethods[wholesalerId] = method;
        continue;
      }
      if (typeof method !== "string" || !VALID_SETTLEMENT_METHODS.has(method)) {
        return res.status(400).json({ error: "Invalid payment method" });
      }
      settlementMethods[wholesalerId] = method;
    }
  }

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

  if (
    items.some((item) => item.category !== undefined && !VALID_ITEM_CATEGORIES.has(item.category))
  ) {
    return res.status(400).json({ error: "Invalid purchase category" });
  }

  // A real checkout must classify every line (NHIS / Cash); the database enforces it and reports
  // how many lines are missing, so the cart can point the user at them.
  const { data, error } = await admin.rpc("create_marketplace_orders_once", {
    _request_id: requestId,
    _caller_id: caller.id,
    _items: items,
    _pharmacy_id: pharmacyId,
    _credit_wholesaler_ids: creditWholesalerIds,
    _settlement_methods: settlementMethods,
  });

  if (error) {
    return res.status(400).json({ error: error.message || "Failed to place order" });
  }

  // Orders placed for online payment are not paid yet: tell the page which ones are waiting, so it can send the customer to pay.
  let awaitingPayment: { orderId: string; orderNumber: string; wholesalerId: string; amountGhs: number }[] = [];
  if (Object.values(settlementMethods).includes("pay_now")) {
    const { data: request } = await admin
      .from("marketplace_checkout_requests")
      .select("created_at")
      .eq("pharmacy_id", pharmacyId)
      .eq("request_id", requestId)
      .maybeSingle();
    if (request?.created_at) {
      const { data: waiting } = await admin
        .from("orders")
        .select("id, order_number, wholesaler_id, total_ghs")
        .eq("pharmacy_id", pharmacyId)
        .eq("payment_method", "paystack")
        .eq("payment_status", "unpaid")
        .eq("status", "pending")
        .gte("created_at", request.created_at)
        .order("created_at", { ascending: true });
      awaitingPayment = (waiting ?? []).map((order) => ({
        orderId: order.id,
        orderNumber: order.order_number,
        wholesalerId: order.wholesaler_id,
        amountGhs: Number(order.total_ghs),
      }));
    }
  }

  return res.status(200).json({
    orderCount: Number(data) || 0,
    ...(awaitingPayment.length > 0 ? { awaitingPayment } : {}),
  });
}
