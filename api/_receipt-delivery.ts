import type { VercelRequest, VercelResponse } from "@vercel/node";
import { z } from "zod";
import { serverContext } from "./_server-context.js";
import { sendOrderReceiptEmail } from "./_order-receipts.js";
const party = z.object({
  owner_id: z.string(),
  name: z.string(),
  city: z.string().nullable(),
  region: z.string().nullable(),
});
const orderSchema = z.object({
  id: z.string(),
  order_number: z.string(),
  total_ghs: z.coerce.number(),
  delivered_at: z.string().nullable(),
  paid_at: z.string().nullable(),
  payment_method: z.enum(["cod", "paystack"]),
  pharmacy: party,
  wholesaler: party,
  order_items: z.array(
    z.object({ product_name: z.string(), quantity: z.number(), unit_price_ghs: z.coerce.number() }),
  ),
});
const receiptSchema = z.object({
  toEmail: z.string().email(),
  toName: z.string(),
  order: z.object({
    orderId: z.string(),
    orderNumber: z.string(),
    totalGhs: z.number(),
    deliveredAt: z.string().nullable(),
    paidAt: z.string().nullable(),
    paymentMethod: z.enum(["cod", "paystack"]),
    items: z.array(
      z.object({ productName: z.string(), quantity: z.number(), unitPriceGhs: z.number() }),
    ),
    parties: z.object({
      pharmacy: party.omit({ owner_id: true }),
      wholesaler: party.omit({ owner_id: true }),
    }),
  }),
});
export async function receiptHandler(req: VercelRequest, res: VercelResponse, confirm: boolean) {
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  let paymentConfirmed = false;
  try {
    const { admin, caller, user } = await serverContext(req);
    const id = typeof req.body?.orderId === "string" ? req.body.orderId : "";
    if (!id) return res.status(400).json({ error: "orderId required" });
    if (confirm) {
      const { error } = await caller.rpc("confirm_order_payment", { _order_id: id });
      if (error) return res.status(400).json({ error: error.message });
      paymentConfirmed = true;
    }
    // Caller RLS authorizes reading the order; the claim RPC independently authorizes sending.
    const { data, error } = await caller
      .from("orders")
      .select(
        "id,order_number,total_ghs,delivered_at,paid_at,payment_method,pharmacy:businesses!orders_pharmacy_id_fkey(owner_id,name,city,region),wholesaler:businesses!orders_wholesaler_id_fkey(owner_id,name,city,region),order_items(product_name,quantity,unit_price_ghs)",
      )
      .eq("id", id)
      .single();
    if (error) throw new Error(error.message);
    const order = orderSchema.parse(data);
    const {
      data: { user: buyer },
      error: buyerError,
    } = await admin.auth.admin.getUserById(order.pharmacy.owner_id);
    if (buyerError || !buyer?.email)
      throw new Error("Receipt recipient unavailable; payment remains confirmed.");
    const payload = receiptSchema.parse({
      toEmail: buyer.email,
      toName: order.pharmacy.name,
      order: {
        orderId: id,
        orderNumber: order.order_number,
        totalGhs: order.total_ghs,
        deliveredAt: order.delivered_at,
        paidAt: order.paid_at,
        paymentMethod: order.payment_method,
        items: order.order_items.map((i) => ({
          productName: i.product_name,
          quantity: i.quantity,
          unitPriceGhs: i.unit_price_ghs,
        })),
        parties: { pharmacy: order.pharmacy, wholesaler: order.wholesaler },
      },
    });
    const { data: claimed, error: claimError } = await admin.rpc("claim_order_receipt", {
      _order_id: id,
      _caller_id: user.id,
      _payload: payload,
    });
    if (claimError) throw new Error(claimError.message);
    const job = z
      .object({
        status: z.string(),
        claim_id: z.string().optional(),
        payload: receiptSchema.optional(),
      })
      .parse(claimed);
    if (job.status === "sent")
      return res.status(200).json({ ok: true, sent: true, receiptSent: true });
    if (job.status !== "claimed" || !job.claim_id || !job.payload)
      return res.status(200).json({
        ok: true,
        sent: false,
        receiptSent: false,
        warning:
          job.status === "uncertain"
            ? "Receipt outcome requires provider review before another send."
            : "Receipt delivery is already in progress.",
      });
    const result = await sendOrderReceiptEmail({
      ...job.payload,
      idempotencyKey: `drugxone-receipt/${id}`,
    });
    const { error: finishError } = await admin.rpc("finish_order_receipt", {
      _order_id: id,
      _claim_id: job.claim_id,
      _provider_id: result.ok ? (result.providerId ?? null) : null,
      _error: result.ok ? null : result.error,
    });
    if (finishError)
      return res.status(200).json({
        ok: true,
        sent: result.ok,
        receiptSent: result.ok,
        warning: "Receipt tracking awaits recovery. Retry uses the same delivery identity.",
      });
    return res.status(200).json({
      ok: true,
      sent: result.ok,
      receiptSent: result.ok,
      ...(!result.ok ? { warning: result.error } : {}),
    });
  } catch (error) {
    return res
      .status(paymentConfirmed ? 200 : 400)
      .json(
        paymentConfirmed
          ? { ok: true, receiptSent: false, warning: "Payment confirmed; receipt retry required." }
          : { error: error instanceof Error ? error.message : "Receipt operation failed" },
      );
  }
}
