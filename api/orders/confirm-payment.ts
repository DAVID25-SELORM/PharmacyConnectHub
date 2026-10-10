import type { VercelRequest, VercelResponse } from "@vercel/node";
import { createClient } from "@supabase/supabase-js";
import { processCashPortion } from "../_cash-portions.js";
import { sendOrderReceiptEmail } from "../_order-receipts.js";
import { receiptFigures, type ReceiptSupply } from "../_order-supply.js";

type OrderStatus = "pending" | "accepted" | "packed" | "dispatched" | "delivered" | "cancelled";
type PaymentStatus = "unpaid" | "paid" | "refunded" | "failed";

type ManagedOrder = {
  id: string;
  order_number: string;
  status: OrderStatus;
  payment_method: "cod" | "paystack";
  payment_status: PaymentStatus;
  total_ghs: number;
  effective_total_ghs: number | null;
  subtotal_ghs: number | null;
  discount_amount_ghs: number | null;
  delivered_at: string | null;
  paid_at: string | null;
  receipt_sent_at: string | null;
  receipt_sent_to: string | null;
  pharmacy_id: string;
  wholesaler_id: string;
  pharmacy: {
    owner_id: string;
    name: string;
    public_email: string | null;
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
    id: string;
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
  const publishableKey =
    process.env.SUPABASE_PUBLISHABLE_KEY || process.env.VITE_SUPABASE_PUBLISHABLE_KEY;

  if (!supabaseUrl || (!serviceKey && !publishableKey)) {
    return res.status(500).json({
      error:
        "Server misconfigured. Add SUPABASE_URL and either SUPABASE_SERVICE_ROLE_KEY or SUPABASE_PUBLISHABLE_KEY.",
    });
  }

  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing authorization" });
  }

  const callerToken = authHeader.slice(7);
  const admin = serviceKey
    ? createClient(supabaseUrl, serviceKey, {
        auth: {
          storage: undefined,
          persistSession: false,
          autoRefreshToken: false,
        },
      })
    : null;
  const authClient =
    admin ??
    createClient(supabaseUrl, publishableKey as string, {
      auth: {
        storage: undefined,
        persistSession: false,
        autoRefreshToken: false,
      },
    });
  const callerDb = createClient(supabaseUrl, (publishableKey ?? serviceKey) as string, {
    accessToken: async () => callerToken,
    auth: {
      storage: undefined,
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  const {
    data: { user: caller },
    error: authErr,
  } = await authClient.auth.getUser(callerToken);

  if (authErr || !caller) {
    return res.status(401).json({ error: "Invalid token" });
  }

  const orderId = typeof req.body?.orderId === "string" ? req.body.orderId : "";
  if (!orderId) {
    return res.status(400).json({ error: "orderId is required" });
  }
  // Set when the cash for ONE back-order shipment of a cash order is being confirmed (omitted for the order itself).
  const shipmentId =
    typeof req.body?.shipmentId === "string" && req.body.shipmentId ? req.body.shipmentId : null;

  const { data: orderData, error: orderErr } = await callerDb
    .from("orders")
    .select(
      "id,order_number,status,payment_method,payment_status,total_ghs,effective_total_ghs,subtotal_ghs,discount_amount_ghs,delivered_at,paid_at,receipt_sent_at,receipt_sent_to,pharmacy_id,wholesaler_id,pharmacy:businesses!orders_pharmacy_id_fkey(owner_id,name,public_email,city,region),wholesaler:businesses!orders_wholesaler_id_fkey(owner_id,name,city,region),order_items(id,product_name,quantity,unit_price_ghs)",
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
    const { data: staffAccess, error: staffAccessErr } = await callerDb
      .from("business_staff")
      .select("role")
      .eq("business_id", order.wholesaler_id)
      .eq("user_id", caller.id)
      .eq("status", "active")
      .maybeSingle();

    if (staffAccessErr) {
      return res.status(500).json({ error: staffAccessErr.message });
    }

    canManage = Boolean(
      staffAccess && staffAccess.role !== "assistant" && staffAccess.role !== "warehouse",
    );
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

  // A cash order accepted with a back-order is collected and receipted one portion at a time (the main delivery, then each
  // shipment): the database confirms the portion and this sends that portion's own receipt.
  const { data: hasPortions } = await callerDb.rpc("order_has_cash_portions", {
    p_order_id: order.id,
  });
  if (hasPortions === true) {
    const outcome = await processCashPortion({
      mode: "confirm",
      callerDb,
      admin,
      order: { ...order, pharmacy: order.pharmacy, wholesaler: order.wholesaler },
      shipmentId,
      request: req,
    });
    return res.status(outcome.status).json(outcome.body);
  }
  if (shipmentId) {
    return res
      .status(400)
      .json({ error: "This order has no back-order shipments to confirm payment for" });
  }

  // An order whose supply was reduced is receipted at what was supplied. Fail before anything is changed if that cannot be read.
  let supply: ReceiptSupply = null;
  if (order.effective_total_ghs !== null) {
    const { data: supplyData, error: supplyErr } = await callerDb.rpc("order_receipt_supply", {
      p_order_id: order.id,
    });
    if (supplyErr || !supplyData) {
      return res.status(500).json({
        error:
          "This order's supply was changed and its receipt figures could not be loaded. Nothing was changed; please try again.",
      });
    }
    supply = supplyData as ReceiptSupply;
  }
  const figures = receiptFigures(order, supply);

  const paymentConfirmedAt = new Date().toISOString();
  const { data: updatedOrder, error: updateOrderErr } = await callerDb
    .from("orders")
    .update({
      paid_at: order.paid_at ?? paymentConfirmedAt,
      payment_confirmed_at: paymentConfirmedAt,
      payment_confirmed_by: caller.id,
      payment_status: "paid",
    })
    .eq("id", order.id)
    .eq("wholesaler_id", order.wholesaler_id)
    .select("id")
    .maybeSingle();

  if (updateOrderErr) {
    return res.status(500).json({ error: updateOrderErr.message });
  }

  if (!updatedOrder) {
    return res.status(403).json({ error: "Unable to confirm payment for this order" });
  }

  let receiptEmail = order.pharmacy.public_email?.trim() || "";
  let receiptEmailWarning: string | undefined;

  if (admin) {
    const {
      data: { user: pharmacyOwner },
      error: pharmacyOwnerErr,
    } = await admin.auth.admin.getUserById(order.pharmacy.owner_id);

    if (pharmacyOwnerErr) {
      receiptEmailWarning =
        pharmacyOwnerErr.message ||
        "Payment was confirmed, but the receipt email could not be prepared.";
    } else if (pharmacyOwner?.email) {
      receiptEmail = pharmacyOwner.email;
    }
  } else if (!receiptEmail) {
    receiptEmailWarning =
      "Payment was confirmed, but the service role key is not configured to look up the pharmacy account email.";
  }

  if (!receiptEmail) {
    return res.status(200).json({
      ok: true,
      receiptSent: false,
      warning:
        receiptEmailWarning ||
        "Payment was confirmed, but the pharmacy account does not have an email address for the receipt.",
    });
  }

  const emailResult = await sendOrderReceiptEmail({
    toEmail: receiptEmail,
    toName: order.pharmacy.name,
    order: {
      orderId: order.id,
      orderNumber: order.order_number,
      totalGhs: figures.totalGhs,
      deliveryFeeGhs: figures.deliveryFeeGhs,
      deliveredAt: order.delivered_at,
      paidAt: order.paid_at ?? paymentConfirmedAt,
      paymentMethod: order.payment_method,
      items: figures.items,
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
  const receiptUpdateResult = admin
    ? await admin
        .from("orders")
        .update({
          receipt_sent_at: receiptSentAt,
          receipt_sent_to: receiptEmail,
        })
        .eq("id", order.id)
    : await callerDb
        .from("orders")
        .update({
          receipt_sent_at: receiptSentAt,
          receipt_sent_to: receiptEmail,
        })
        .eq("id", order.id);
  const receiptUpdateErr = receiptUpdateResult.error;

  if (receiptUpdateErr) {
    warning =
      "Payment was confirmed and the receipt email was sent, but receipt tracking could not be saved.";
  } else if (admin) {
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
        receipt_sent_to: receiptEmail,
      },
    });

    if (notificationErr) {
      warning =
        "Payment was confirmed and the receipt email was sent, but the in-app receipt notification could not be saved.";
    }
  } else {
    warning =
      receiptEmailWarning ||
      "Payment was confirmed and the receipt email was sent, but the in-app receipt notification could not be saved because the service role key is not configured.";
  }

  return res.status(200).json({
    ok: true,
    receiptSent: true,
    ...(warning ? { warning } : {}),
  });
}
