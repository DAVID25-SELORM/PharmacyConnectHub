// Cash (pay on delivery) orders that were accepted with a back-order are collected, and receipted, one portion at a time: the main
// delivery and each back-order shipment. The database does the work (confirm_cash_collection, cash_collection_receipt,
// mark_collection_receipt_sent); this module is the glue the two receipt endpoints share.
import type { VercelRequest } from "@vercel/node";
import type { SupabaseClient } from "@supabase/supabase-js";
import { sendOrderReceiptEmail, type OrderReceiptPayload } from "./_order-receipts.js";

/** What cash_collection_receipt returns for one collected portion. */
export type PortionReceipt = {
  collection_id: string;
  order_number: string;
  total_ghs: number | string;
  delivery_fee_ghs: number | string | null;
  delivered_at: string | null;
  paid_at: string | null;
  receipt_sent_at: string | null;
  receipt_sent_to: string | null;
  items: Array<{ product_name: string; quantity: number; unit_price_ghs: number | string }>;
};

type PortionOrder = {
  id: string;
  order_number: string;
  payment_method: "cod" | "paystack";
  pharmacy: {
    owner_id: string;
    name: string;
    public_email?: string | null;
    city: string | null;
    region: string | null;
  };
  wholesaler: { name: string; city: string | null; region: string | null };
};

/** The receipt email payload for one portion: its own lines and its own amount, labelled with the shipment when it is one. */
export function portionReceiptPayload(
  order: PortionOrder,
  receipt: PortionReceipt,
): OrderReceiptPayload {
  return {
    orderId: order.id,
    orderNumber: receipt.order_number,
    totalGhs: Number(receipt.total_ghs),
    deliveryFeeGhs: Number(receipt.delivery_fee_ghs ?? 0),
    deliveredAt: receipt.delivered_at,
    paidAt: receipt.paid_at,
    paymentMethod: order.payment_method,
    items: receipt.items
      .filter((item) => item.quantity > 0)
      .map((item) => ({
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
  };
}

type PortionResult = { status: number; body: Record<string, unknown> };

/** Confirms (mode "confirm") and/or (re)sends the receipt for one portion of a cash order collected portion by portion. */
export async function processCashPortion(args: {
  mode: "confirm" | "resend";
  callerDb: SupabaseClient;
  admin: SupabaseClient | null;
  order: PortionOrder;
  shipmentId: string | null;
  request: VercelRequest;
}): Promise<PortionResult> {
  const { mode, callerDb, admin, order, shipmentId, request } = args;
  const ids = { p_order_id: order.id, p_shipment_id: shipmentId };

  if (mode === "confirm") {
    const { error } = await callerDb.rpc("confirm_cash_collection", ids);
    if (error) return { status: 400, body: { error: error.message } };
  }

  const { data: receiptData, error: receiptErr } = await callerDb.rpc(
    "cash_collection_receipt",
    ids,
  );
  if (receiptErr) return { status: 400, body: { error: receiptErr.message } };
  const receipt = receiptData as PortionReceipt | null;
  if (!receipt) {
    return {
      status: 400,
      body: { error: "Confirm payment for this delivery first before sending its receipt" },
    };
  }

  let receiptEmail = order.pharmacy.public_email?.trim() || "";
  let warning: string | undefined;
  if (admin) {
    const {
      data: { user: pharmacyOwner },
      error: ownerErr,
    } = await admin.auth.admin.getUserById(order.pharmacy.owner_id);
    if (ownerErr) {
      warning = ownerErr.message || "The receipt email could not be prepared.";
    } else if (pharmacyOwner?.email) {
      receiptEmail = pharmacyOwner.email;
    }
  } else if (!receiptEmail) {
    warning = "The service role key is not configured to look up the pharmacy account email.";
  }
  const prefix = mode === "confirm" ? "Payment was confirmed, but " : "";

  if (!receiptEmail) {
    return {
      status: 200,
      body: {
        ok: true,
        receiptSent: false,
        sent: false,
        warning: `${prefix}${warning ?? "the pharmacy account does not have an email address for the receipt."}`,
      },
    };
  }

  const emailResult = await sendOrderReceiptEmail({
    toEmail: receiptEmail,
    toName: order.pharmacy.name,
    order: portionReceiptPayload(order, receipt),
    request,
  });
  if (!emailResult.ok) {
    return {
      status: 200,
      body: { ok: true, receiptSent: false, sent: false, warning: emailResult.error },
    };
  }

  const { error: markErr } = await callerDb.rpc("mark_collection_receipt_sent", {
    p_collection_id: receipt.collection_id,
    p_email: receiptEmail,
  });
  if (markErr) {
    warning = `${prefix || ""}the receipt email was sent, but receipt tracking could not be saved.`;
  } else if (admin) {
    const { error: notificationErr } = await admin.from("notifications").insert({
      user_id: order.pharmacy.owner_id,
      type: "receipt_sent",
      title: "Receipt emailed",
      body:
        `Your receipt for order #${receipt.order_number} from ${order.wholesaler.name} ` +
        "has been emailed after payment confirmation.",
      metadata: {
        order_id: order.id,
        order_number: order.order_number,
        receipt_sent_to: receiptEmail,
      },
    });
    if (notificationErr) {
      warning = `${prefix}the receipt email was sent, but the in-app receipt notification could not be saved.`;
    }
  }
  return {
    status: 200,
    body: { ok: true, receiptSent: true, sent: true, ...(warning ? { warning } : {}) },
  };
}
