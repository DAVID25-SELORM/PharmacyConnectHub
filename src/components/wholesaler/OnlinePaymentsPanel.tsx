import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { formatGHS, timeAgo } from "@/lib/format";
import {
  fetchSupplierSettlement,
  supplierOnlineStatusLine,
  type SupplierSettlementOverview,
} from "@/lib/payments";

const toneClass = {
  good: "border-success/30 bg-success/15 text-success",
  bad: "border-destructive/30 bg-destructive/15 text-destructive",
  neutral: "border-border bg-muted text-muted-foreground",
};

export function OnlinePaymentsPanel({ wholesalerId }: { wholesalerId: string }) {
  const [days, setDays] = useState("30");
  const [overview, setOverview] = useState<SupplierSettlementOverview | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    fetchSupplierSettlement(wholesalerId, Number(days))
      .then((next) => {
        if (!cancelled) setOverview(next);
      })
      .catch((e) => {
        if (!cancelled)
          setError(e instanceof Error ? e.message : "Could not load online payments.");
      });
    return () => {
      cancelled = true;
    };
  }, [wholesalerId, days]);

  if (error) {
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  }
  if (!overview) return <Skeleton className="h-40" />;

  const line = supplierOnlineStatusLine(overview);
  return (
    <div className="space-y-4" data-testid="supplier-online-payments">
      <Card className="space-y-2 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="font-semibold">Online payments</h3>
          <Badge variant="outline" className={toneClass[line.tone]} data-testid="online-status">
            {line.label}
          </Badge>
        </div>
        <p className="text-sm text-muted-foreground">{line.detail}</p>
        {overview.account && (
          <p className="text-sm" data-testid="settlement-account">
            Settles to {overview.account.business_name}, account ending{" "}
            <strong>{overview.account.last4}</strong>.
          </p>
        )}
      </Card>

      <Card className="space-y-3 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="font-semibold">Received online</h3>
          <Select value={days} onValueChange={setDays}>
            <SelectTrigger className="h-8 w-40 text-xs" aria-label="Period">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="7">Last 7 days</SelectItem>
              <SelectItem value="30">Last 30 days</SelectItem>
              <SelectItem value="90">Last 90 days</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <dl className="grid gap-3 text-sm sm:grid-cols-4" data-testid="settlement-summary">
          <div>
            <dt className="text-xs text-muted-foreground">Received</dt>
            <dd className="font-display text-lg font-bold">
              {formatGHS(overview.summary.received_ghs)}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Platform share</dt>
            <dd className="font-display text-lg font-bold">
              {formatGHS(overview.summary.platform_share_ghs)}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Refunded</dt>
            <dd className="font-display text-lg font-bold">
              {formatGHS(overview.summary.refunded_ghs)}
            </dd>
          </div>
          <div>
            <dt className="text-xs text-muted-foreground">Should settle to you</dt>
            <dd className="font-display text-lg font-bold">
              {formatGHS(overview.summary.to_settle_ghs)}
            </dd>
          </div>
        </dl>
        <p className="text-xs text-muted-foreground">
          An estimate before Paystack&apos;s own fees, for comparing with your Paystack settlement
          report. Payouts arrive on Paystack&apos;s schedule.
        </p>
        {overview.recent.length === 0 ? (
          <p className="text-sm text-muted-foreground">No online payments in this period.</p>
        ) : (
          <ul className="divide-y text-sm">
            {overview.recent.map((row, i) => (
              <li
                key={`${row.order_number}-${row.paid_at}-${i}`}
                className="flex flex-wrap items-center justify-between gap-2 py-2"
              >
                <span>
                  {row.order_number}
                  {row.purpose === "top_up" ? " (extra payment)" : ""}{" "}
                  <span className="text-xs text-muted-foreground">{timeAgo(row.paid_at)}</span>
                </span>
                <span>
                  {formatGHS(row.amount_ghs)}
                  {row.refunded_ghs > 0 && (
                    <span className="ml-2 text-xs text-muted-foreground">
                      refunded {formatGHS(row.refunded_ghs)}
                    </span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
