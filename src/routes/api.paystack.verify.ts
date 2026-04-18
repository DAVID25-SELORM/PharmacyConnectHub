import { createFileRoute } from "@tanstack/react-router";
import { supabaseAdmin } from "@/integrations/supabase/client.server";

// Manually verify a transaction by reference.
// Used when the customer returns from the Paystack checkout (callback_url).
// Body: { reference: string }
export const Route = createFileRoute("/api/paystack/verify")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const PAYSTACK_SECRET = process.env.PAYSTACK_SECRET_KEY;
          if (!PAYSTACK_SECRET) return jsonError("Not configured", 500);

          const body = (await request.json()) as { reference?: string };
          if (!body.reference) return jsonError("reference required", 400);

          const r = await fetch(
            `https://api.paystack.co/transaction/verify/${encodeURIComponent(body.reference)}`,
            { headers: { Authorization: `Bearer ${PAYSTACK_SECRET}` } }
          );
          const j = (await r.json()) as {
            status: boolean;
            data?: { status: string; amount: number; reference: string };
          };
          if (!r.ok || !j.status || !j.data) return jsonError("Verify failed", 502);

          const { data: order } = await supabaseAdmin
            .from("orders")
            .select("id, payment_status, total_ghs")
            .eq("paystack_reference", j.data.reference)
            .maybeSingle();

          if (!order) return jsonError("Order not found", 404);

          if (j.data.status === "success") {
            const expected = Math.round(Number(order.total_ghs) * 100);
            if (j.data.amount !== expected) return jsonError("Amount mismatch", 400);
            if (order.payment_status !== "paid") {
              await supabaseAdmin
                .from("orders")
                .update({ payment_status: "paid", paid_at: new Date().toISOString() })
                .eq("id", order.id);
            }
            return Response.json({ status: "paid" });
          }
          return Response.json({ status: j.data.status });
        } catch (e) {
          return jsonError((e as Error).message ?? "Server error", 500);
        }
      },
    },
  },
});

function jsonError(message: string, status: number) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
