import { useEffect, useState } from "react";
import { formatGHS } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { fetchOrderPaymentSummary, payForOrder, type OrderPaymentSummary } from "@/lib/payments";

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
  const [paying, setPaying] = useState(false);

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
  const topupDue = Number(summary.topup_due_ghs ?? 0);
  if (paid === 0 && refunds.length === 0 && topupDue === 0) return null;

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
      {topupDue > 0 && (
        <div className="mt-2 rounded-lg bg-warning/10 p-2 text-xs" data-testid="topup-due">
          {summary.side === "pharmacy" ? (
            <>
              <p>
                A price change means this order now costs {formatGHS(topupDue)} more. Pay the
                difference so the supplier can dispatch it.
              </p>
              <Button
                size="sm"
                className="mt-2"
                disabled={paying}
                onClick={async () => {
                  setPaying(true);
                  const result = await payForOrder(orderId, "top_up");
                  if (!result.ok) {
                    toast.error(result.error);
                    setPaying(false);
                  }
                }}
              >
                {paying ? "Opening payment page…" : `Pay ${formatGHS(topupDue)} now`}
              </Button>
            </>
          ) : (
            <p>
              Waiting for the pharmacy to pay {formatGHS(topupDue)} for a price change. The order
              cannot be dispatched until it is paid.
            </p>
          )}
        </div>
      )}
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
