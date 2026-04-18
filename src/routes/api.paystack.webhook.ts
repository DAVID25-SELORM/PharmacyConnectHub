import { createFileRoute } from "@tanstack/react-router";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import crypto from "node:crypto";

// Paystack webhook handler.
// Configure in Paystack dashboard: https://<your-domain>/api/paystack/webhook
export const Route = createFileRoute("/api/paystack/webhook")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const PAYSTACK_SECRET = process.env.PAYSTACK_SECRET_KEY;
        if (!PAYSTACK_SECRET) return new Response("Not configured", { status: 500 });

        const signature = request.headers.get("x-paystack-signature");
        const raw = await request.text();
        const computed = crypto
          .createHmac("sha512", PAYSTACK_SECRET)
          .update(raw)
          .digest("hex");

        if (!signature || signature !== computed) {
          return new Response("Invalid signature", { status: 401 });
        }

        let payload: any;
        try {
          payload = JSON.parse(raw);
        } catch {
          return new Response("Bad JSON", { status: 400 });
        }

        const event = payload?.event as string;
        const data = payload?.data ?? {};
        const reference = data?.reference as string | undefined;
        if (!reference) return new Response("ok", { status: 200 });

        // Find the order by reference
        const { data: order } = await supabaseAdmin
          .from("orders")
          .select("id, payment_status, total_ghs")
          .eq("paystack_reference", reference)
          .maybeSingle();

        if (!order) {
          // Not our order — acknowledge to avoid retries
          return new Response("ok", { status: 200 });
        }

        if (event === "charge.success") {
          // Verify amount matches (pesewas)
          const expected = Math.round(Number(order.total_ghs) * 100);
          if (Number(data.amount) !== expected) {
            return new Response("Amount mismatch", { status: 400 });
          }
          if (order.payment_status !== "paid") {
            await supabaseAdmin
              .from("orders")
              .update({ payment_status: "paid", paid_at: new Date().toISOString() })
              .eq("id", order.id);
          }
        } else if (event === "charge.failed") {
          if (order.payment_status === "unpaid") {
            await supabaseAdmin
              .from("orders")
              .update({ payment_status: "failed" })
              .eq("id", order.id);
          }
        }

        return new Response("ok", { status: 200 });
      },
    },
  },
});
