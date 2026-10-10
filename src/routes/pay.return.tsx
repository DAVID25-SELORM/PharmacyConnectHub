import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { CheckCircle2, Clock, Loader2, XCircle } from "lucide-react";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { useSession } from "@/hooks/use-session";
import { formatGHS } from "@/lib/format";
import {
  fetchOrderPaymentSummary,
  payForOrder,
  returnMessage,
  verifyOrderPayment,
  type OrderPaymentSummary,
  type VerifyStatus,
} from "@/lib/payments";

export const Route = createFileRoute("/pay/return")({
  head: () => ({ meta: [{ title: "Payment - Drugxone" }] }),
  validateSearch: (search: Record<string, unknown>): { order?: string; purpose?: "top_up" } => ({
    purpose: search.purpose === "top_up" ? "top_up" : undefined,
    order: typeof search.order === "string" ? search.order : undefined,
  }),
  component: PayReturnPage,
});

const RETRY_MS = 4000;
const MAX_CHECKS = 30;

/**
 * Where the customer lands after the provider's checkout page. Being sent here proves nothing: this page only asks the server to
 * check with the provider, and shows what the database then says. It keeps asking for a couple of minutes (a mobile money
 * approval can take a moment) and never marks anything paid by itself.
 */
function PayReturnPage() {
  const navigate = useNavigate();
  const { order, purpose } = Route.useSearch();
  const { loading: sessionLoading, user, roles } = useSession();
  const [status, setStatus] = useState<VerifyStatus | "checking" | "unreachable">("checking");
  const [summary, setSummary] = useState<OrderPaymentSummary | null>(null);
  const [retrying, setRetrying] = useState(false);
  const [exhausted, setExhausted] = useState(false);
  const [payError, setPayError] = useState<string | null>(null);
  const checks = useRef(0);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!sessionLoading && !user) void navigate({ to: "/login" });
  }, [sessionLoading, user, navigate]);

  const check = useCallback(async () => {
    if (!order) return;
    checks.current += 1;
    let next: VerifyStatus | "unreachable";
    try {
      next = await verifyOrderPayment(order);
    } catch {
      next = "unreachable";
    }
    setStatus(next);
    const info = await fetchOrderPaymentSummary(order);
    if (info) setSummary(info);
    const settled = next === "paid" || next === "failed" || next === "flagged";
    if (settled) return;
    if (checks.current >= MAX_CHECKS) {
      setExhausted(true);
      return;
    }
    timer.current = setTimeout(() => void check(), RETRY_MS);
  }, [order]);

  useEffect(() => {
    if (!user || !order) return;
    checks.current = 0;
    setExhausted(false);
    void check();
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, [user, order, check]);

  const message = returnMessage(status);
  const Icon =
    message.tone === "good"
      ? CheckCircle2
      : message.tone === "bad"
        ? XCircle
        : status === "checking"
          ? Loader2
          : Clock;
  const canTryAgain = status === "failed" || status === "not_paid";
  const online = summary && summary.online ? summary : null;

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Payment" showNav={true} isAdmin={roles.includes("admin")} />
      <main className="mx-auto max-w-xl px-4 py-10 sm:px-6">
        <Card className="p-6 text-center" data-testid="pay-return">
          {!order ? (
            <>
              <XCircle className="mx-auto h-10 w-10 text-destructive" aria-hidden="true" />
              <h1 className="mt-3 font-display text-xl font-bold">
                We could not find this payment
              </h1>
              <p className="mt-2 text-sm text-muted-foreground">
                Open your orders to see where it stands.
              </p>
            </>
          ) : (
            <>
              <Icon
                className={`mx-auto h-10 w-10 ${
                  message.tone === "good"
                    ? "text-success"
                    : message.tone === "bad"
                      ? "text-destructive"
                      : "text-muted-foreground"
                } ${status === "checking" ? "animate-spin" : ""}`}
                aria-hidden="true"
              />
              <h1 className="mt-3 font-display text-xl font-bold" data-testid="pay-return-title">
                {message.title}
              </h1>
              <p
                className="mt-2 text-sm text-muted-foreground"
                role="status"
                data-testid="pay-return-body"
              >
                {message.body}
              </p>
              {online && (
                <p className="mt-3 text-sm">
                  Order <span className="font-medium">{online.order_number}</span> ·{" "}
                  {formatGHS(online.amount_ghs)}
                </p>
              )}
              {exhausted && status !== "paid" && (
                <p className="mt-3 text-sm text-muted-foreground">
                  We are still waiting for the provider to confirm. If you completed the payment,
                  your order will update as soon as it does.
                </p>
              )}
              {payError && <p className="mt-3 text-sm text-destructive">{payError}</p>}
            </>
          )}
          <div className="mt-6 flex flex-wrap justify-center gap-2">
            {order && (exhausted || status === "unreachable") && status !== "paid" && (
              <Button
                variant="outline"
                onClick={() => {
                  checks.current = 0;
                  setExhausted(false);
                  setStatus("checking");
                  void check();
                }}
              >
                Check again
              </Button>
            )}
            {order && canTryAgain && (
              <Button
                disabled={retrying}
                onClick={async () => {
                  setRetrying(true);
                  setPayError(null);
                  const result = await payForOrder(order, purpose ?? "order");
                  if (!result.ok) {
                    setPayError(result.error);
                    setRetrying(false);
                  }
                }}
              >
                {retrying ? "Opening payment page…" : "Pay now"}
              </Button>
            )}
            <Button asChild variant={status === "paid" ? "default" : "outline"}>
              <a href="/pharmacy?tab=orders">Go to my orders</a>
            </Button>
          </div>
        </Card>
      </main>
    </div>
  );
}
