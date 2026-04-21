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
      error: "Only the wholesaler owner or active order-processing staff can confirm payment",
    });
  }

  if (order.status !== "delivered") {
    return res.status(400).json({
      error: "Mark this order as delivered before confirming payment and sending a receipt",
    });
  }

  if (order.payment_status === "paid") {
    return res.status(400).json({ error: "Payment has already been confirmed for this order" });
  }

  if (order.payment_status !== "unpaid") {
    return res.status(400).json({ error: "Only unpaid orders can be confirmed as paid" });
  }

  const paymentConfirmedAt = new Date().toISOString();
  const { error: updateOrderErr } = await admin
    .from("orders")
    .update({
      paid_at: order.paid_at ?? paymentConfirmedAt,
      payment_confirmed_at: paymentConfirmedAt,
      payment_confirmed_by: caller.id,
      payment_status: "paid",
    })
    .eq("id", order.id)
    .eq("wholesaler_id", order.wholesaler_id);

  if (updateOrderErr) {
    return res.status(500).json({ error: updateOrderErr.message });
  }

  const {
    data: { user: pharmacyOwner },
    error: pharmacyOwnerErr,
  } = await admin.auth.admin.getUserById(order.pharmacy.owner_id);

  if (pharmacyOwnerErr) {
    return res.status(200).json({
      ok: true,
      receiptSent: false,
      warning:
        pharmacyOwnerErr.message ||
        "Payment was confirmed, but the receipt email could not be prepared.",
    });
  }

  if (!pharmacyOwner?.email) {
    return res.status(200).json({
      ok: true,
      receiptSent: false,
      warning:
        "Payment was confirmed, but the pharmacy account does not have an email address for the receipt.",
    });
  }

  const emailResult = await sendOrderReceiptEmail({
    toEmail: pharmacyOwner.email,
    toName: order.pharmacy.name,
    order: {
      orderId: order.id,
      orderNumber: order.order_number,
      totalGhs: Number(order.total_ghs),
      deliveredAt: order.delivered_at,
      paidAt: order.paid_at ?? paymentConfirmedAt,
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
    return res.status(200).json({
      ok: true,
      receiptSent: false,
      warning: emailResult.error,
    });
  }

  let warning: string | undefined;

  const receiptSentAt = new Date().toISOString();
  const { error: receiptUpdateErr } = await admin
    .from("orders")
    .update({
      receipt_sent_at: receiptSentAt,
      receipt_sent_to: pharmacyOwner.email,
    })
    .eq("id", order.id);

  if (receiptUpdateErr) {
    warning =
      "Payment was confirmed and the receipt email was sent, but receipt tracking could not be saved.";
  } else {
    const { error: notificationErr } = await admin.from("notifications").insert({
      user_id: order.pharmacy.owner_id,
      type: "receipt_sent",
      title: "Receipt emailed",
      body:
        `Your receipt for order #${order.order_number} from ${order.wholesaler.name} ` +
        "has been emailed after payment confirmation.",
      metadata: {
        order_id: order.id,
        order_number: order.order_number,
        receipt_sent_to: pharmacyOwner.email,
      },
    });

    if (notificationErr) {
      warning =
        "Payment was confirmed and the receipt email was sent, but the in-app receipt notification could not be saved.";
    }
  }

  return res.status(200).json({
    ok: true,
    receiptSent: true,
    ...(warning ? { warning } : {}),
  });
}
