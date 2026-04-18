import { createFileRoute } from "@tanstack/react-router";
import { supabaseAdmin } from "@/integrations/supabase/client.server";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/integrations/supabase/types";

// Initializes a Paystack transaction for an existing order.
// Body: { orderId: string }
// Returns: { authorization_url, access_code, reference }
export const Route = createFileRoute("/api/paystack/init")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const authHeader = request.headers.get("authorization");
          if (!authHeader?.startsWith("Bearer ")) {
            return jsonError("Unauthorized", 401);
          }
          const token = authHeader.slice(7);

          const SUPABASE_URL = process.env.SUPABASE_URL!;
          const PUB_KEY = process.env.SUPABASE_PUBLISHABLE_KEY!;
          const PAYSTACK_SECRET = process.env.PAYSTACK_SECRET_KEY;
          if (!PAYSTACK_SECRET) return jsonError("Paystack not configured", 500);

          // Verify token & get user
          const userClient = createClient<Database>(SUPABASE_URL, PUB_KEY, {
            global: { headers: { Authorization: `Bearer ${token}` } },
            auth: { persistSession: false, autoRefreshToken: false },
          });
          const { data: claimsData, error: claimsErr } = await userClient.auth.getClaims(token);
          if (claimsErr || !claimsData?.claims?.sub) return jsonError("Invalid token", 401);
          const userId = claimsData.claims.sub;

          const body = (await request.json()) as { orderId?: string };
          if (!body.orderId) return jsonError("orderId required", 400);

          // Fetch order + verify ownership via pharmacy business
          const { data: order, error: orderErr } = await supabaseAdmin
            .from("orders")
            .select("id, order_number, total_ghs, payment_status, payment_method, pharmacy_id, pharmacy:businesses!orders_pharmacy_id_fkey(owner_id)")
            .eq("id", body.orderId)
            .single();
          if (orderErr || !order) return jsonError("Order not found", 404);
          const pharmacyOwner = (order.pharmacy as { owner_id: string } | null)?.owner_id;
          if (pharmacyOwner !== userId) return jsonError("Forbidden", 403);
          if (order.payment_status === "paid") return jsonError("Already paid", 400);

          // Get user email
          const { data: userData } = await supabaseAdmin.auth.admin.getUserById(userId);
          const email = userData.user?.email;
          if (!email) return jsonError("User email missing", 400);

          // Initialize Paystack transaction
          const reference = `${order.order_number}-${Date.now()}`;
          const psRes = await fetch("https://api.paystack.co/transaction/initialize", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${PAYSTACK_SECRET}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              email,
              amount: Math.round(Number(order.total_ghs) * 100), // pesewas
              currency: "GHS",
              reference,
              metadata: { order_id: order.id, order_number: order.order_number },
              callback_url: new URL("/pharmacy?tab=orders", request.url).toString(),
            }),
          });
          const psJson = (await psRes.json()) as {
            status: boolean;
            message: string;
            data?: { authorization_url: string; access_code: string; reference: string };
          };
          if (!psRes.ok || !psJson.status || !psJson.data) {
            return jsonError(psJson.message || "Paystack init failed", 502);
          }

          // Save reference to order
          await supabaseAdmin
            .from("orders")
            .update({
              payment_method: "paystack",
              paystack_reference: psJson.data.reference,
              paystack_access_code: psJson.data.access_code,
            })
            .eq("id", order.id);

          return Response.json({
            authorization_url: psJson.data.authorization_url,
            access_code: psJson.data.access_code,
            reference: psJson.data.reference,
          });
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
