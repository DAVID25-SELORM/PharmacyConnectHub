import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { BillingInvoices } from "./BillingInvoices";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatGHS } from "@/lib/format";
import {
  ENTRY_LABELS,
  STATE_LABELS,
  capProgress,
  describeBilledOrder,
  fetchMyBilling,
  periodLabel,
  planSummary,
  stateDetail,
  stateMessage,
  type BillingState,
  type MyBilling,
} from "@/lib/billing";

const dateText = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "UTC",
      })
    : "–";

const stateTone: Record<BillingState, string> = {
  no_subscription: "border-border bg-muted text-muted-foreground",
  not_started: "border-border bg-muted text-muted-foreground",
  trialing: "border-primary/30 bg-primary/10 text-primary",
  active: "border-success/30 bg-success/15 text-success",
  past_due: "border-destructive/30 bg-destructive/15 text-destructive",
  grace_period: "border-warning/30 bg-warning/15 text-warning-foreground",
  suspended: "border-destructive/30 bg-destructive/15 text-destructive",
  paused: "border-border bg-muted text-muted-foreground",
  cancelled: "border-border bg-muted text-muted-foreground",
};

function Stat({
  label,
  value,
  hint,
  testId,
}: {
  label: string;
  value: string;
  hint?: string;
  testId?: string;
}) {
  return (
    <Card className="p-4" data-testid={testId}>
      <div className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </div>
      <div className="mt-1 font-display text-xl font-bold">{value}</div>
      {hint && <div className="mt-0.5 text-xs text-muted-foreground">{hint}</div>}
    </Card>
  );
}

/** A business's own Billing & Subscription page. Everything shown comes from the database for THIS business only; nothing is calculated here. */
export function BillingPanel({ businessId }: { businessId: string }) {
  const [data, setData] = useState<MyBilling | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setData(null);
    setError(null);
    fetchMyBilling(businessId)
      .then((next) => {
        if (!cancelled) setData(next);
      })
      .catch((e) => {
        if (!cancelled) setError(e instanceof Error ? e.message : "Could not load billing.");
      });
    return () => {
      cancelled = true;
    };
  }, [businessId]);

  if (error) {
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  }
  if (!data) {
    return (
      <div className="space-y-3">
        <Skeleton className="h-24" />
        <Skeleton className="h-40" />
      </div>
    );
  }

  const isWholesaler = data.business_type === "wholesaler";
  const period = data.current_period ?? null;
  const progress = period && isWholesaler ? capProgress(period) : null;
  const started = data.state !== "no_subscription" && data.state !== "not_started";

  return (
    <div className="space-y-6" data-testid="billing-panel">
      <Card className="space-y-2 p-4">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="font-display text-lg font-bold">Billing &amp; Subscription</h2>
          <Badge variant="outline" className={stateTone[data.state]} data-testid="billing-state">
            {STATE_LABELS[data.state]}
          </Badge>
        </div>
        <p className="text-sm text-muted-foreground" data-testid="billing-state-message">
          {stateMessage(data.state)}
        </p>
        {stateDetail(data.state, data.subscription, data.restriction) && (
          <p className="text-sm font-medium" data-testid="billing-state-detail">
            {stateDetail(data.state, data.subscription, data.restriction)}
          </p>
        )}
        {data.subscription?.cancel_at_period_end && data.subscription.ends_at && (
          <p className="text-sm text-muted-foreground">
            Your subscription ends on {dateText(data.subscription.ends_at)}.
          </p>
        )}
        {data.subscription?.exempt_from_transaction_fees && (
          <p className="text-sm text-muted-foreground">
            Your business is exempt from platform fees on orders.
          </p>
        )}
      </Card>

      {data.plan && (
        <Card className="space-y-2 p-4" data-testid="billing-plan">
          <h3 className="font-semibold">Your plan: {data.plan.name ?? data.plan.code}</h3>
          <ul className="list-disc space-y-1 pl-5 text-sm">
            {planSummary(data.plan, formatGHS).map((line) => (
              <li key={line}>{line}</li>
            ))}
          </ul>
          {data.state === "trialing" && data.subscription && (
            <p className="text-sm text-muted-foreground">
              Trial: {dateText(data.subscription.trial_start)} to{" "}
              {dateText(data.subscription.trial_end)}
              {data.subscription.trial_days_left !== null
                ? ` (${data.subscription.trial_days_left} days left)`
                : ""}
              .
            </p>
          )}
          {data.state === "not_started" && data.subscription && (
            <p className="text-sm text-muted-foreground">
              Billing is planned to start from {dateText(data.subscription.billing_starts_at)}, once
              it is switched on.
            </p>
          )}
        </Card>
      )}

      {started && period && (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3" data-testid="billing-cards">
            <Stat
              label="Current plan"
              value={data.plan?.name ?? data.plan?.code ?? "–"}
              testId="card-plan"
            />
            <Stat
              label="Subscription"
              value={`${formatGHS(data.plan?.subscription_amount ?? 0)} / ${data.plan?.billing_interval_months === 1 ? "month" : `${data.plan?.billing_interval_months} months`}`}
              hint={`Next billing date ${dateText(data.subscription?.next_billing_date)}`}
              testId="card-subscription"
            />
            {isWholesaler && data.free_orders && (
              <Stat
                label="Free orders"
                value={`${data.free_orders.monthly_used} / ${data.free_orders.monthly_allowance} used this month`}
                hint={`Launch free orders: ${data.free_orders.launch_remaining} of ${data.free_orders.launch_granted} left`}
                testId="card-free-orders"
              />
            )}
            {isWholesaler && (
              <Stat
                label="Eligible sales"
                value={formatGHS(period.billable_gmv ?? 0)}
                hint={`${period.eligible_orders ?? 0} completed eligible orders`}
                testId="card-volume"
              />
            )}
            {isWholesaler && (
              <Stat
                label="Platform fees"
                value={formatGHS(period.transaction_fees_amount ?? 0)}
                hint={
                  period.cap !== null && period.cap !== undefined
                    ? `Capped at ${formatGHS(period.cap)} a month`
                    : undefined
                }
                testId="card-fees"
              />
            )}
            <Stat
              label="Current bill"
              value={formatGHS(period.outstanding_amount)}
              hint={`Period ${periodLabel(period.period_start, period.period_end)}`}
              testId="card-bill"
            />
          </div>

          {progress !== null && period.cap !== null && period.cap !== undefined && (
            <Card className="space-y-2 p-4" data-testid="cap-progress">
              <div className="flex items-center justify-between text-sm">
                <span className="font-medium">Platform fee cap this period</span>
                <span>
                  {formatGHS(period.transaction_fees_amount ?? 0)} of {formatGHS(period.cap)}
                </span>
              </div>
              <Progress value={progress} aria-label="Platform fee cap used" />
              <p className="text-xs text-muted-foreground">
                {period.cap_remaining === 0
                  ? "The cap has been reached: further eligible orders this period carry no platform fee."
                  : `${formatGHS(period.cap_remaining ?? 0)} of fees left before the cap.`}
              </p>
            </Card>
          )}

          <Card className="space-y-3 p-4" data-testid="bill-breakdown">
            <h3 className="font-semibold">
              Your bill for {periodLabel(period.period_start, period.period_end)}
            </h3>
            <Table>
              <TableBody>
                <TableRow>
                  <TableCell>Subscription</TableCell>
                  <TableCell className="text-right">
                    {formatGHS(period.subscription_amount)}
                  </TableCell>
                </TableRow>
                {isWholesaler && (
                  <TableRow>
                    <TableCell>
                      Platform fees
                      <span className="block text-xs text-muted-foreground">
                        {period.eligible_orders ?? 0} completed eligible orders:{" "}
                        {(period.free_onboarding_orders ?? 0) + (period.free_monthly_orders ?? 0)}{" "}
                        free ({period.free_onboarding_orders ?? 0} launch,{" "}
                        {period.free_monthly_orders ?? 0} monthly), {period.chargeable_orders ?? 0}{" "}
                        chargeable, on eligible sales of {formatGHS(period.billable_gmv ?? 0)}
                      </span>
                    </TableCell>
                    <TableCell className="text-right">
                      {formatGHS(period.transaction_fees_amount ?? 0)}
                    </TableCell>
                  </TableRow>
                )}
                {period.debits_amount > 0 && (
                  <TableRow>
                    <TableCell>Adjustments</TableCell>
                    <TableCell className="text-right">{formatGHS(period.debits_amount)}</TableCell>
                  </TableRow>
                )}
                {period.credits_amount > 0 && (
                  <TableRow>
                    <TableCell>Credits</TableCell>
                    <TableCell className="text-right">
                      − {formatGHS(period.credits_amount)}
                    </TableCell>
                  </TableRow>
                )}
                <TableRow className="font-semibold">
                  <TableCell>Total</TableCell>
                  <TableCell className="text-right" data-testid="bill-total">
                    {formatGHS(period.amount_due)}
                  </TableCell>
                </TableRow>
                <TableRow>
                  <TableCell>Paid</TableCell>
                  <TableCell className="text-right">{formatGHS(period.amount_paid)}</TableCell>
                </TableRow>
                <TableRow className="font-semibold">
                  <TableCell>Outstanding balance</TableCell>
                  <TableCell className="text-right">
                    {formatGHS(period.outstanding_amount)}
                  </TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </Card>
        </>
      )}

      {started && !period && (
        <Card className="p-4 text-sm text-muted-foreground">
          Your first billing period is being prepared. It will appear here shortly.
        </Card>
      )}

      {isWholesaler && (data.orders?.length ?? 0) > 0 && (
        <Card className="space-y-3 p-4" data-testid="billed-orders">
          <h3 className="font-semibold">Orders billed</h3>
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Order</TableHead>
                  <TableHead>Delivered</TableHead>
                  <TableHead className="text-right">Eligible amount</TableHead>
                  <TableHead>How it was billed</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.orders!.map((row, i) => (
                  <TableRow key={`${row.order_number}-${row.kind}-${row.adjustment_seq}-${i}`}>
                    <TableCell className="whitespace-nowrap">{row.order_number}</TableCell>
                    <TableCell className="whitespace-nowrap">
                      {dateText(row.delivered_at)}
                    </TableCell>
                    <TableCell className="text-right">{formatGHS(row.billable_gmv)}</TableCell>
                    <TableCell>{describeBilledOrder(row, formatGHS)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}

      {(data.credits_and_adjustments?.length ?? 0) > 0 && (
        <Card className="space-y-3 p-4" data-testid="credits-list">
          <h3 className="font-semibold">Credits and adjustments</h3>
          <ul className="divide-y text-sm">
            {data.credits_and_adjustments!.map((entry, i) => (
              <li
                key={`${entry.created_at}-${i}`}
                className="flex flex-wrap items-center justify-between gap-2 py-2"
              >
                <span>
                  {ENTRY_LABELS[entry.entry_type] ?? entry.entry_type}
                  {entry.reason ? (
                    <span className="text-muted-foreground"> · {entry.reason}</span>
                  ) : null}
                  <span className="ml-2 text-xs text-muted-foreground">
                    {dateText(entry.created_at)}
                  </span>
                </span>
                <span>
                  {entry.credit_amount > 0
                    ? `− ${formatGHS(entry.credit_amount)}`
                    : formatGHS(entry.charged_amount)}
                </span>
              </li>
            ))}
          </ul>
        </Card>
      )}

      <BillingInvoices businessId={businessId} />

      {(data.periods?.length ?? 0) > 0 && (
        <Card className="space-y-3 p-4" data-testid="billing-history">
          <h3 className="font-semibold">Billing history</h3>
          <div className="overflow-x-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Period</TableHead>
                  <TableHead className="text-right">Subscription</TableHead>
                  {isWholesaler && <TableHead className="text-right">Platform fees</TableHead>}
                  <TableHead className="text-right">Total</TableHead>
                  <TableHead className="text-right">Paid</TableHead>
                  <TableHead className="text-right">Balance</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.periods!.map((p) => (
                  <TableRow key={p.period_start}>
                    <TableCell className="whitespace-nowrap">
                      {periodLabel(p.period_start, p.period_end)}
                    </TableCell>
                    <TableCell className="text-right">{formatGHS(p.subscription_amount)}</TableCell>
                    {isWholesaler && (
                      <TableCell className="text-right">
                        {formatGHS(p.transaction_fees_amount ?? 0)}
                      </TableCell>
                    )}
                    <TableCell className="text-right">{formatGHS(p.amount_due)}</TableCell>
                    <TableCell className="text-right">{formatGHS(p.amount_paid)}</TableCell>
                    <TableCell className="text-right">{formatGHS(p.outstanding_amount)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}
    </div>
  );
}
