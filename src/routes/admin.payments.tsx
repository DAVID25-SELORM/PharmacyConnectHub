import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, Loader2, RefreshCw } from "lucide-react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { AdminNav } from "@/components/admin/AdminNav";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { formatGHS, timeAgo } from "@/lib/format";
import {
  alertKindLabel,
  describeReverify,
  fetchPaymentOverview,
  resolvePaymentAlert,
  reverifyOrderPayment,
  type PaymentAlert,
  type PaymentOverview,
} from "@/lib/payments-admin";

export const Route = createFileRoute("/admin/payments")({
  head: () => ({ meta: [{ title: "Payments - Drugxone" }] }),
  component: AdminPaymentsPage,
});

const REFRESH_MS = 30000;

const severityClass: Record<string, string> = {
  critical: "bg-destructive/15 text-destructive border-destructive/30",
  warning: "bg-warning/15 text-warning-foreground border-warning/30",
  info: "bg-muted text-muted-foreground border-border",
};

const attemptClass = (status: string, refund: boolean) =>
  refund || status === "flagged"
    ? "bg-destructive/15 text-destructive border-destructive/30"
    : status === "succeeded"
      ? "bg-success/15 text-success border-success/30"
      : status === "failed" || status === "abandoned" || status === "expired"
        ? "bg-muted text-muted-foreground border-border"
        : "bg-warning/15 text-warning-foreground border-warning/30";

function AdminPaymentsPage() {
  const [overview, setOverview] = useState<PaymentOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [resolving, setResolving] = useState<PaymentAlert | null>(null);
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [reverifying, setReverifying] = useState<string | null>(null);
  const [showResolved, setShowResolved] = useState(false);

  const load = useCallback(async () => {
    setRefreshing(true);
    try {
      setOverview(await fetchPaymentOverview());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load payments.");
    } finally {
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void load();
    const timer = setInterval(() => void load(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [load]);

  const reverify = async (orderId: string) => {
    setReverifying(orderId);
    try {
      toast.info(describeReverify(await reverifyOrderPayment(orderId)));
      await load();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not re-verify.");
    } finally {
      setReverifying(null);
    }
  };

  const resolve = async () => {
    if (!resolving) return;
    setSaving(true);
    try {
      await resolvePaymentAlert(resolving.id, note.trim());
      toast.success("Alert marked as dealt with.");
      setResolving(null);
      setNote("");
      await load();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Could not resolve the alert.");
    } finally {
      setSaving(false);
    }
  };

  const open = overview?.alerts.filter((a) => a.status === "open") ?? [];
  const resolved = overview?.alerts.filter((a) => a.status === "resolved") ?? [];
  const counts = overview?.counts;

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Payments" isAdmin={true} />
      <AdminNav />
      <main className="mx-auto max-w-7xl space-y-6 px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="font-display text-2xl font-bold">Online payments</h1>
            <p className="text-sm text-muted-foreground">
              Payments made through the platform, and anything that needs a person to look at it.
            </p>
          </div>
          <div className="flex items-center gap-2">
            {overview?.settings && (
              <Badge
                variant="secondary"
                className={`border ${overview.settings.enabled ? "bg-success/15 text-success border-success/30" : "bg-muted text-muted-foreground border-border"}`}
                data-testid="payments-switch"
              >
                {overview.settings.enabled
                  ? `Online payments on (${overview.settings.mode} mode)`
                  : "Online payments off"}
              </Badge>
            )}
            <Button variant="outline" size="sm" onClick={() => void load()} disabled={refreshing}>
              <RefreshCw
                className={`mr-1 h-4 w-4 ${refreshing ? "animate-spin" : ""}`}
                aria-hidden="true"
              />
              Refresh
            </Button>
          </div>
        </div>

        {error && (
          <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
            {error}
          </Card>
        )}

        {!overview && !error && (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {[0, 1, 2, 3].map((i) => (
              <Skeleton key={i} className="h-24" />
            ))}
          </div>
        )}

        {counts && (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Card className="p-4" data-testid="count-alerts">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">
                Need attention
              </div>
              <div
                className={`mt-1 font-display text-2xl font-bold ${counts.open_critical > 0 ? "text-destructive" : ""}`}
              >
                {counts.open_alerts}
              </div>
              <div className="text-xs text-muted-foreground">{counts.open_critical} critical</div>
            </Card>
            <Card className="p-4" data-testid="count-refunds">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">
                Refunds needed
              </div>
              <div className="mt-1 font-display text-2xl font-bold">{counts.refunds_required}</div>
              <div className="text-xs text-muted-foreground">Money received that must go back</div>
            </Card>
            <Card className="p-4" data-testid="count-awaiting">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">
                Awaiting payment
              </div>
              <div className="mt-1 font-display text-2xl font-bold">{counts.awaiting_payment}</div>
              <div className="text-xs text-muted-foreground">Online orders not yet paid</div>
            </Card>
            <Card className="p-4" data-testid="count-paid">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">
                Paid, last 24 hours
              </div>
              <div className="mt-1 font-display text-2xl font-bold">
                {formatGHS(counts.paid_24h_ghs)}
              </div>
              <div className="text-xs text-muted-foreground">{counts.paid_24h} payment(s)</div>
            </Card>
          </div>
        )}

        {overview && (
          <section aria-labelledby="alerts-heading" className="space-y-3">
            <h2 id="alerts-heading" className="font-display text-lg font-bold">
              Needs attention
            </h2>
            {open.length === 0 ? (
              <Card
                className="flex items-center gap-2 p-4 text-sm text-muted-foreground"
                data-testid="no-alerts"
              >
                <CheckCircle2 className="h-4 w-4 text-success" aria-hidden="true" />
                Nothing needs attention right now.
              </Card>
            ) : (
              open.map((alert) => (
                <Card key={alert.id} className="p-4" data-testid="alert">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="min-w-0 space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge
                          variant="secondary"
                          className={`gap-1 border ${severityClass[alert.severity]}`}
                        >
                          <AlertTriangle className="h-3 w-3" aria-hidden="true" />
                          {alertKindLabel(alert.kind)}
                        </Badge>
                        {alert.order_number && (
                          <span className="text-sm font-medium">{alert.order_number}</span>
                        )}
                        <span className="text-xs text-muted-foreground">
                          {timeAgo(alert.created_at)}
                          {alert.occurrences > 1 ? ` · seen ${alert.occurrences} times` : ""}
                        </span>
                      </div>
                      <p className="text-sm">{alert.summary}</p>
                    </div>
                    <div className="flex gap-2">
                      {alert.order_id && (
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={reverifying === alert.order_id}
                          onClick={() => void reverify(alert.order_id as string)}
                        >
                          {reverifying === alert.order_id ? (
                            <Loader2 className="mr-1 h-4 w-4 animate-spin" aria-hidden="true" />
                          ) : null}
                          Re-verify
                        </Button>
                      )}
                      <Button
                        size="sm"
                        onClick={() => {
                          setResolving(alert);
                          setNote("");
                        }}
                      >
                        Mark as dealt with
                      </Button>
                    </div>
                  </div>
                </Card>
              ))
            )}
            {resolved.length > 0 && (
              <div>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => setShowResolved((v) => !v)}
                  aria-expanded={showResolved}
                >
                  {showResolved ? "Hide" : "Show"} recently resolved ({resolved.length})
                </Button>
                {showResolved && (
                  <div className="mt-2 space-y-2">
                    {resolved.map((alert) => (
                      <Card key={alert.id} className="p-3 text-sm text-muted-foreground">
                        <span className="font-medium text-foreground">
                          {alertKindLabel(alert.kind)}
                        </span>
                        {alert.order_number ? ` · ${alert.order_number}` : ""} · {alert.summary}
                        <div className="text-xs">
                          Resolved {alert.resolved_at ? timeAgo(alert.resolved_at) : ""}
                          {alert.resolution_note ? `: ${alert.resolution_note}` : ""}
                        </div>
                      </Card>
                    ))}
                  </div>
                )}
              </div>
            )}
          </section>
        )}

        {overview && (
          <section aria-labelledby="attempts-heading" className="space-y-3">
            <h2 id="attempts-heading" className="font-display text-lg font-bold">
              Recent payment attempts
            </h2>
            {overview.attempts.length === 0 ? (
              <Card className="p-4 text-sm text-muted-foreground">No payment attempts yet.</Card>
            ) : (
              <Card className="overflow-x-auto p-0">
                <table className="w-full text-sm">
                  <thead className="border-b border-border text-left text-xs uppercase tracking-wider text-muted-foreground">
                    <tr>
                      <th className="px-3 py-2">Started</th>
                      <th className="px-3 py-2">Order</th>
                      <th className="px-3 py-2">Pharmacy to supplier</th>
                      <th className="px-3 py-2 text-right">Amount</th>
                      <th className="px-3 py-2">Status</th>
                      <th className="px-3 py-2">Last checked</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-border">
                    {overview.attempts.map((a) => (
                      <tr key={a.id} data-testid="attempt">
                        <td className="whitespace-nowrap px-3 py-2">{timeAgo(a.initiated_at)}</td>
                        <td className="px-3 py-2 font-medium">{a.order_number}</td>
                        <td className="px-3 py-2">
                          {a.pharmacy ?? "—"} <span className="text-muted-foreground">to</span>{" "}
                          {a.wholesaler ?? "—"}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-right">
                          {formatGHS(a.amount_ghs)}
                        </td>
                        <td className="px-3 py-2">
                          <Badge
                            variant="secondary"
                            className={`border ${attemptClass(a.status, a.refund_required)}`}
                          >
                            {a.status}
                            {a.refund_required ? " · refund needed" : ""}
                          </Badge>
                          {a.flag_reason && (
                            <div className="mt-0.5 text-xs text-muted-foreground">
                              {a.flag_reason.replace(/_/g, " ")}
                            </div>
                          )}
                          {a.failure_reason && (
                            <div className="mt-0.5 text-xs text-muted-foreground">
                              {a.failure_reason}
                            </div>
                          )}
                        </td>
                        <td className="whitespace-nowrap px-3 py-2 text-muted-foreground">
                          {a.last_checked_at ? timeAgo(a.last_checked_at) : "never"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </Card>
            )}
          </section>
        )}
      </main>

      <Dialog
        open={resolving !== null}
        onOpenChange={(openState) => !openState && setResolving(null)}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Mark as dealt with</DialogTitle>
            <DialogDescription>
              {resolving?.summary} Say what was done, so the next person can see it. This does not
              move any money.
            </DialogDescription>
          </DialogHeader>
          <Textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={500}
            rows={4}
            placeholder="For example: refunded GH₵ 20.00 from the Paystack dashboard on 10 Oct and told the pharmacy."
            aria-label="What was done"
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setResolving(null)}>
              Cancel
            </Button>
            <Button disabled={saving || note.trim().length < 5} onClick={() => void resolve()}>
              {saving ? "Saving…" : "Mark as dealt with"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
