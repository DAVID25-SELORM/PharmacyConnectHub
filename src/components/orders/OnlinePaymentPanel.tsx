import { useEffect, useState } from "react";
import { formatGHS } from "@/lib/format";
import { fetchOrderPaymentSummary, type OrderPaymentSummary } from "@/lib/payments";

const REFUND_STATUS: Record<string, string> = {
  requested: "being arranged",
  approved: "being sent",
  submitting: "being sent",
  processing: "on its way",
  succeeded: "returned",
  failed: "being looked into",
  unknown: "being looked into",
};

const REFUND_REASON: Record<string, string> = {
  late_payment: "paid after the order was cancelled",
  double_payment: "paid twice",
  cancelled_after_payment: "order cancelled",
  order_changed: "order changed",
  amendment_reduction: "order reduced",
  delivery_credit: "delivery problem",
  manual: "",
};

/** What either side of an online order may know about its payment: what was paid, what has been returned, and any refund on its way. Nothing for other orders. */
export function OnlinePaymentPanel({
  orderId,
  paymentMethod,
  refreshKey,
}: {
  orderId: string;
  paymentMethod?: string | null;
  refreshKey?: number;
}) {
  const [summary, setSummary] = useState<OrderPaymentSummary | null>(null);

  useEffect(() => {
    if (paymentMethod !== "paystack") return;
    let cancelled = false;
    void fetchOrderPaymentSummary(orderId).then((next) => {
      if (!cancelled) setSummary(next);
    });
    return () => {
      cancelled = true;
    };
  }, [orderId, paymentMethod, refreshKey]);

  if (paymentMethod !== "paystack" || !summary || !summary.online) return null;
  const paid = Number(summary.paid_ghs ?? 0);
  const refunded = Number(summary.refunded_ghs ?? 0);
  const refunds = (summary.refunds ?? []).filter((r) => r.status !== "cancelled");
  if (paid === 0 && refunds.length === 0) return null;

  return (
    <div
      className="mt-4 rounded-xl border border-border p-3 text-sm"
      data-testid="online-payment-panel"
    >
      <div className="text-xs uppercase tracking-wider text-muted-foreground">Online payment</div>
      <div className="mt-1 font-medium">
        Paid {formatGHS(paid)}
        {refunded > 0 ? ` · ${formatGHS(refunded)} refunded` : ""}
      </div>
      {summary.refund_required && refunds.length === 0 && (
        <p className="mt-1 text-xs text-muted-foreground">
          A refund is due on this order and is being arranged.
        </p>
      )}
      {refunds.length > 0 && (
        <ul className="mt-1 space-y-0.5 text-xs text-muted-foreground">
          {refunds.map((r, i) => (
            <li key={i}>
              Refund of {formatGHS(r.amount_ghs)}
              {REFUND_REASON[r.reason] ? ` (${REFUND_REASON[r.reason]})` : ""}:{" "}
              {REFUND_STATUS[r.status] ?? r.status}
              {r.status === "succeeded"
                ? ". It can take several business days to reach the account."
                : ""}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
