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
  /** "This order costs less than was paid and no refund is on the way": a refund of the difference can be requested. */
  balance_refund_missing?: boolean;
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

export type RefundStatus =
  | "requested"
  | "approved"
  | "submitting"
  | "processing"
  | "succeeded"
  | "failed"
  | "unknown"
  | "cancelled";

export type PaymentRefund = {
  id: string;
  order_id: string;
  order_number: string;
  pharmacy: string | null;
  amount_ghs: number;
  reason: string;
  status: RefundStatus;
  method: "provider" | "manual";
  failure_reason: string | null;
  note: string | null;
  created_at: string;
  approved_at: string | null;
  submitted_at: string | null;
  completed_at: string | null;
  reference: string;
};

export type PaymentOverview = {
  settings: { enabled: boolean; mode: "test" | "live"; auto_refunds: boolean } | null;
  counts: {
    open_alerts: number;
    open_critical: number;
    refunds_required: number;
    refunds_open: number;
    awaiting_payment: number;
    paid_24h: number;
    paid_24h_ghs: number;
  };
  alerts: PaymentAlert[];
  refunds: PaymentRefund[];
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
  refund_failed: "Refund failed",
  refund_stuck: "Refund needs checking",
  refund_unmatched: "Unmatched refund",
};

export type RefundAction = "approve" | "retry" | "cancel" | "confirm_refunded" | "mark_failed";

export type RefundActionResult = {
  status?: string;
  sent?: boolean;
  outcome?: "processing" | "succeeded" | "failed" | "unknown";
  message?: string;
};

/** Approve, retry, cancel, confirm as refunded, or mark as not sent. Approving and retrying also send the refund at once. */
export function refundAction(
  refundId: string,
  action: RefundAction,
  note?: string,
): Promise<RefundActionResult> {
  return postWithSession<RefundActionResult>("/api/payments/admin-refund", {
    refundId,
    action,
    note: note ?? null,
  });
}

/** Asks for a refund of the difference on an order that costs less than was paid and has no refund on the way. It still waits for approval. */
export function requestBalanceRefund(
  orderId: string,
): Promise<{ requestedMinor: number; unplacedMinor: number }> {
  return postWithSession<{ requestedMinor: number; unplacedMinor: number }>(
    "/api/payments/admin-refund",
    {
      orderId,
      action: "request_balance_refund",
    },
  );
}

export const REFUND_REASON_LABELS: Record<string, string> = {
  late_payment: "Paid after the order was cancelled",
  double_payment: "Paid twice",
  cancelled_after_payment: "Order cancelled after payment",
  order_changed: "Order changed after payment",
  amendment_reduction: "Order reduced after payment",
  delivery_credit: "Delivery problem credit",
  manual: "Manual",
};

export const REFUND_STATUS_LABELS: Record<RefundStatus, string> = {
  requested: "Waiting for approval",
  approved: "Approved, sending",
  submitting: "Being sent",
  processing: "With the provider",
  succeeded: "Refunded",
  failed: "Failed",
  unknown: "Outcome unknown: check the provider",
  cancelled: "Cancelled",
};

/** What an administrator may do to a refund in each state (the database enforces the same rules). */
export function refundActionsFor(
  status: RefundStatus,
): { action: RefundAction; label: string; needsNote: boolean }[] {
  switch (status) {
    case "requested":
      return [
        { action: "approve", label: "Approve and send", needsNote: false },
        { action: "confirm_refunded", label: "Already refunded", needsNote: true },
        { action: "cancel", label: "Cancel", needsNote: false },
      ];
    case "approved":
      return [
        { action: "confirm_refunded", label: "Already refunded", needsNote: true },
        { action: "cancel", label: "Cancel", needsNote: false },
      ];
    case "submitting":
      return [{ action: "confirm_refunded", label: "Already refunded", needsNote: true }];
    case "processing":
      return [
        { action: "confirm_refunded", label: "Confirm refunded", needsNote: true },
        { action: "mark_failed", label: "Not sent", needsNote: true },
      ];
    case "unknown":
      return [
        { action: "confirm_refunded", label: "Confirm refunded", needsNote: true },
        { action: "mark_failed", label: "Not sent", needsNote: true },
      ];
    case "failed":
      return [
        { action: "retry", label: "Retry", needsNote: false },
        { action: "confirm_refunded", label: "Already refunded", needsNote: true },
        { action: "cancel", label: "Cancel", needsNote: false },
      ];
    default:
      return [];
  }
}

/** A plain sentence for what happened when a refund was approved, retried, or otherwise changed. */
export function describeRefundAction(result: RefundActionResult): string {
  if (result.sent === false && result.message) return result.message;
  if (result.outcome === "processing")
    return "The refund was sent to the provider. It is processing.";
  if (result.outcome === "succeeded") return "The provider reports the refund as completed.";
  if (result.outcome === "failed")
    return "The provider refused the refund. It is marked as failed; you can retry it.";
  if (result.outcome === "unknown")
    return "It is not known whether the provider received the refund. Check the provider's dashboard before doing anything else.";
  return "Done.";
}

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
