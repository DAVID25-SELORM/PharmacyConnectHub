import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import { sendOrderReceiptEmail } from "../../src/lib/server/order-receipts";

type OrderStatus = "pending" | "accepted" | "packed" | "dispatched" | "delivered" | "cancelled";
type PaymentStatus = "unpaid" | "paid" | "refunded" | "failed";

type ManagedOrder = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_method: "cod" | "paystack";
  payment_status: PaymentStatus;
  total_ghs: number;
  delivered_at: string | null;
  paid_at: string | null;
  receipt_sent_at: string | null;
  receipt_sent_to: string | null;
  pharmacy_id: string;
  wholesaler_id: string;
  pharmacy: {
    owner_id: string;
    name: string;
    city: string | null;
    region: string | null;
  } | null;
  wholesaler: {
    owner_id: string;
    name: string;
    city: string | null;
    region: string | null;
  } | null;
  order_items: {
    product_name: string;
    quantity: number;
    unit_price_ghs: number;
  }[];
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

  const orderId = typeof req.body?.orderId === "string" ? req.body.orderId : "";
  if (!orderId) {
    return res.status(400).json({ error: "orderId is required" });
  }

  const { data: orderData, error: orderErr } = await admin
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,delivered_at,paid_at,receipt_sent_at,receipt_sent_to,pharmacy_id,wholesaler_id,pharmacy:businesses!orders_pharmacy_id_fkey(owner_id,name,city,region),wholesaler:businesses!orders_wholesaler_id_fkey(owner_id,name,city,region),order_items(product_name,quantity,unit_price_ghs)",
    )
    .eq("id", orderId)
    .maybeSingle();

  if (orderErr) {
    return res.status(500).json({ error: orderErr.message });
  }

  const order = orderData as ManagedOrder | null;
  if (!order || !order.pharmacy || !order.wholesaler) {
    return res.status(404).json({ error: "Order not found" });
  }

  let canManage = order.wholesaler.owner_id === caller.id;
  if (!canManage) {
    const { data: staffAccess, error: staffAccessErr } = await admin
      .from("business_staff")
      .select("role")
      .eq("business_id", order.wholesaler_id)
      .eq("user_id", caller.id)
      .eq("status", "active")
      .maybeSingle();

    if (staffAccessErr) {
      return res.status(500).json({ error: staffAccessErr.message });
    }

    canManage = Boolean(staffAccess && staffAccess.role !== "assistant");
  }

  if (!canManage) {
    return res.status(403).json({
      error: "Only the wholesaler owner or active order-processing staff can send receipts",
    });
  }

  if (order.status !== "delivered") {
    return res
      .status(400)
      .json({ error: "Send the receipt only after the order is marked delivered" });
  }

  if (order.payment_status !== "paid") {
    return res.status(400).json({ error: "Confirm payment first before sending the receipt" });
  }

  const {
    data: { user: pharmacyOwner },
    error: pharmacyOwnerErr,
  } = await admin.auth.admin.getUserById(order.pharmacy.owner_id);

  if (pharmacyOwnerErr) {
    return res
      .status(500)
      .json({ error: pharmacyOwnerErr.message || "Unable to load the pharmacy email address" });
  }

  if (!pharmacyOwner?.email) {
    return res.status(400).json({ error: "The pharmacy account does not have an email address" });
  }

  const emailResult = await sendOrderReceiptEmail({
    toEmail: pharmacyOwner.email,
    toName: order.pharmacy.name,
    order: {
      orderId: order.id,
      orderNumber: order.order_number,
      totalGhs: Number(order.total_ghs),
      deliveredAt: order.delivered_at,
      paidAt: order.paid_at,
      paymentMethod: order.payment_method,
      items: order.order_items.map((item) => ({
        productName: item.product_name,
        quantity: item.quantity,
        unitPriceGhs: Number(item.unit_price_ghs),
      })),
      parties: {
        pharmacy: {
          name: order.pharmacy.name,
          city: order.pharmacy.city,
          region: order.pharmacy.region,
        },
        wholesaler: {
          name: order.wholesaler.name,
          city: order.wholesaler.city,
          region: order.wholesaler.region,
        },
      },
    },
    request: req,
  });

  if (!emailResult.ok) {
    return res.status(500).json({ error: emailResult.error });
  }

  const receiptSentAt = new Date().toISOString();
  const { error: receiptUpdateErr } = await admin
    .from("orders")
    .update({
      receipt_sent_at: receiptSentAt,
      receipt_sent_to: pharmacyOwner.email,
    })
    .eq("id", order.id);

  if (receiptUpdateErr) {
    return res.status(500).json({
      error:
        "The receipt email was sent, but receipt tracking could not be saved. Please refresh the order and try again only if needed.",
    });
  }

  const { error: notificationErr } = await admin.from("notifications").insert({
    user_id: order.pharmacy.owner_id,
    type: "receipt_sent",
    title: order.receipt_sent_at ? "Receipt re-emailed" : "Receipt emailed",
    body:
      `Your receipt for order #${order.order_number} from ${order.wholesaler.name} ` +
      `has been ${order.receipt_sent_at ? "sent again" : "emailed"}.`,
    metadata: {
      order_id: order.id,
      order_number: order.order_number,
      receipt_sent_to: pharmacyOwner.email,
      resent: Boolean(order.receipt_sent_at),
    },
  });

  if (notificationErr) {
    return res.status(200).json({
      sent: true,
      warning:
        "The receipt email was sent, but the in-app receipt notification could not be saved.",
    });
  }

  return res.status(200).json({ sent: true });
}
