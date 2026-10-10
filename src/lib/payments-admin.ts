// The platform administrators' view of online payments: what needs attention, and the recent payment attempts. Read through admin-only database
// functions; the only things an administrator can do here are to ask the provider again about an order's payment and to mark an alert as dealt with.
import { supabase } from "@/integrations/supabase/client";
import { postWithSession } from "@/lib/order-actions";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type PaymentAlert = {
  id: string;
  kind: string;
  severity: "info" | "warning" | "critical";
  order_id: string | null;
  order_number: string | null;
  summary: string;
  status: "open" | "resolved";
  occurrences: number;
  created_at: string;
  last_seen_at: string;
  resolved_at: string | null;
  resolution_note: string | null;
};

export type PaymentAttemptRow = {
  id: string;
  order_id: string;
  order_number: string;
  pharmacy: string | null;
  wholesaler: string | null;
  reference: string;
  mode: "test" | "live";
  amount_ghs: number;
  status: string;
  flag_reason: string | null;
  refund_required: boolean;
  channel: string | null;
  initiated_at: string;
  paid_at: string | null;
  last_checked_at: string | null;
  failure_reason: string | null;
};

export type PaymentOverview = {
  settings: { enabled: boolean; mode: "test" | "live" } | null;
  counts: {
    open_alerts: number;
    open_critical: number;
    refunds_required: number;
    awaiting_payment: number;
    paid_24h: number;
    paid_24h_ghs: number;
  };
  alerts: PaymentAlert[];
  attempts: PaymentAttemptRow[];
};

export async function fetchPaymentOverview(): Promise<PaymentOverview> {
  const { data, error } = await db.rpc("admin_payment_overview");
  if (error) throw new Error(error.message || "Could not load payments.");
  return data as PaymentOverview;
}

export async function resolvePaymentAlert(alertId: string, note: string): Promise<void> {
  const { error } = await db.rpc("admin_resolve_payment_alert", {
    p_alert_id: alertId,
    p_note: note,
  });
  if (error) throw new Error(error.message || "Could not resolve the alert.");
}

export type ReverifyResult = {
  orderPaid: boolean;
  outcomes: { reference: string; outcome: string }[];
};

/** Asks the provider again about the order's payment attempts. The answer is recorded the same way as everywhere else. */
export function reverifyOrderPayment(orderId: string): Promise<ReverifyResult> {
  return postWithSession<ReverifyResult>("/api/payments/admin-reverify", { orderId });
}

export const ALERT_KIND_LABELS: Record<string, string> = {
  flagged_payment: "Payment not applied",
  refund_required: "Refund needed",
  paid_not_applied: "Paid, not applied",
  unknown_at_provider: "Unknown payment",
  missing_at_provider: "Missing at provider",
  status_mismatch: "Status differs",
  amount_mismatch: "Amount differs",
  provider_unreachable: "Provider unreachable",
  expiry_blocked: "Order kept open",
};

export function alertKindLabel(kind: string): string {
  return ALERT_KIND_LABELS[kind] ?? kind.replace(/_/g, " ");
}

/** A plain sentence for what a re-verify found, for the toast. */
export function describeReverify(result: ReverifyResult): string {
  if (result.orderPaid) return "The provider confirms the payment and the order is now paid.";
  if (result.outcomes.length === 0) return "There was nothing to check for this order.";
  const outcomes = new Set(result.outcomes.map((o) => o.outcome));
  if (outcomes.has("flagged") || outcomes.has("late"))
    return "The provider shows a payment that cannot be applied to this order. It stays flagged.";
  if ([...outcomes].some((o) => o.startsWith("could_not_check")))
    return "The provider could not be reached. Nothing was changed.";
  return "The provider does not show a completed payment for this order.";
}
