import { useEffect, useMemo, useState } from "react";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatGHS } from "@/lib/format";
import {
  fetchAdminBillingOverview,
  fetchPlans,
  type AdminBillingOverview,
  type FlavorSummary,
  type PlanRow,
} from "@/lib/billing";

const PERIODS: { value: string; label: string; days: number | "month" }[] = [
  { value: "7", label: "Last 7 days", days: 7 },
  { value: "30", label: "Last 30 days", days: 30 },
  { value: "90", label: "Last 90 days", days: 90 },
  { value: "month", label: "This month", days: "month" },
];
const ALL = "all";

function periodRange(value: string): { from: Date; to: Date } {
  const to = new Date(Date.now() + 60_000);
  const choice = PERIODS.find((p) => p.value === value) ?? PERIODS[1];
  if (choice.days === "month") {
    const now = new Date();
    return { from: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)), to };
  }
  return { from: new Date(to.getTime() - choice.days * 24 * 60 * 60 * 1000), to };
}

function Metric({
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

function Group({
  title,
  note,
  children,
}: {
  title: string;
  note?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-2">
      <div>
        <h3 className="font-display text-base font-bold">{title}</h3>
        {note && <p className="text-xs text-muted-foreground">{note}</p>}
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">{children}</div>
    </section>
  );
}

const pct = (n: number | null) => (n === null ? "–" : `${n}%`);

export function AdminBillingOverviewSection() {
  const [period, setPeriod] = useState("30");
  const [type, setType] = useState(ALL);
  const [plan, setPlan] = useState(ALL);
  const [status, setStatus] = useState(ALL);
  const [flavor, setFlavor] = useState<"real" | "shadow">("real");
  const [plans, setPlans] = useState<PlanRow[]>([]);
  const [data, setData] = useState<AdminBillingOverview | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchPlans()
      .then(setPlans)
      .catch(() => setPlans([]));
  }, []);

  useEffect(() => {
    let cancelled = false;
    setError(null);
    const { from, to } = periodRange(period);
    fetchAdminBillingOverview({
      from,
      to,
      businessType: type === ALL ? null : (type as "pharmacy" | "wholesaler"),
      planCode: plan === ALL ? null : plan,
      status: status === ALL ? null : status,
    })
      .then((next) => {
        if (!cancelled) setData(next);
      })
      .catch((e) => {
        if (!cancelled) setError(e instanceof Error ? e.message : "Could not load billing.");
      });
    return () => {
      cancelled = true;
    };
  }, [period, type, plan, status]);

  const summary: FlavorSummary | null = useMemo(() => (data ? data[flavor] : null), [data, flavor]);

  return (
    <div className="space-y-6" data-testid="billing-overview">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <div className="text-xs font-medium text-muted-foreground">Period</div>
          <Select value={period} onValueChange={setPeriod}>
            <SelectTrigger className="h-9 w-40" aria-label="Period">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {PERIODS.map((p) => (
                <SelectItem key={p.value} value={p.value}>
                  {p.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <div className="text-xs font-medium text-muted-foreground">Business type</div>
          <Select value={type} onValueChange={setType}>
            <SelectTrigger className="h-9 w-40" aria-label="Business type">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>All</SelectItem>
              <SelectItem value="pharmacy">Pharmacies</SelectItem>
              <SelectItem value="wholesaler">Wholesalers</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <div className="text-xs font-medium text-muted-foreground">Plan</div>
          <Select value={plan} onValueChange={setPlan}>
            <SelectTrigger className="h-9 w-48" aria-label="Plan">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>All plans</SelectItem>
              {plans.map((p) => (
                <SelectItem key={p.code} value={p.code}>
                  {p.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <div className="text-xs font-medium text-muted-foreground">Subscription status</div>
          <Select value={status} onValueChange={setStatus}>
            <SelectTrigger className="h-9 w-44" aria-label="Subscription status">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value={ALL}>All</SelectItem>
              <SelectItem value="trialing">Trialing</SelectItem>
              <SelectItem value="active">Active</SelectItem>
              <SelectItem value="past_due">Past due</SelectItem>
              <SelectItem value="grace_period">Grace period</SelectItem>
              <SelectItem value="suspended">Suspended</SelectItem>
              <SelectItem value="cancelled">Cancelled</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <Tabs
          value={flavor}
          onValueChange={(v) => setFlavor(v as "real" | "shadow")}
          className="ml-auto"
        >
          <TabsList>
            <TabsTrigger value="real">Real</TabsTrigger>
            <TabsTrigger value="shadow">Shadow (estimated)</TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      {error && (
        <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
          {error}
        </Card>
      )}
      {!data && !error && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {[0, 1, 2, 3].map((i) => (
            <Skeleton key={i} className="h-24" />
          ))}
        </div>
      )}

      {data && summary && (
        <>
          {data.platform_mode !== "active" && (
            <Card className="border-warning/40 bg-warning/10 p-3 text-sm" data-testid="mode-banner">
              Billing is <strong>{data.platform_mode}</strong>: nothing is being charged.{" "}
              {flavor === "shadow"
                ? "These figures are what the rules WOULD have charged."
                : "Real figures stay empty until billing is active."}
            </Card>
          )}
          {flavor === "shadow" && (
            <Card className="border-border bg-muted p-3 text-sm" data-testid="shadow-banner">
              Shadow figures are estimates: what billing would have been. Nothing is invoiced,
              collected or shown to businesses.
            </Card>
          )}

          <Group
            title="Revenue (accrued)"
            note="By the date each charge was posted. Accrued is not the same as collected."
          >
            <Metric
              label="Total accrued revenue"
              value={formatGHS(summary.accrued_revenue)}
              hint="Subscriptions + transaction fees + adjustments − credits"
              testId="m-accrued"
            />
            <Metric
              label="Subscription revenue"
              value={formatGHS(summary.subscription_revenue)}
              testId="m-subscription"
            />
            <Metric
              label="Transaction fee revenue"
              value={formatGHS(summary.transaction_fee_revenue)}
              testId="m-fees"
            />
            <Metric label="Credits given" value={formatGHS(summary.credits)} testId="m-credits" />
            <Metric
              label="Contracted MRR"
              value={formatGHS(data.subscriptions.contracted_mrr)}
              hint="Active subscriptions, per month"
              testId="m-mrr"
            />
            <Metric
              label="Effective take rate"
              value={pct(summary.take_rate_percent)}
              hint="Transaction fees ÷ fee-eligible sales"
              testId="m-take"
            />
            <Metric
              label="Revenue per paying organization"
              value={
                data.revenue_per_paying_organization === null || flavor === "shadow"
                  ? "–"
                  : formatGHS(data.revenue_per_paying_organization)
              }
              hint={`${data.paying_organizations_in_period} organizations charged`}
            />
          </Group>

          <Group
            title="Marketplace volume (GMV)"
            note="Three different numbers. Cancelled orders are never counted as completed."
          >
            <Metric
              label="Created order value"
              value={formatGHS(data.marketplace.created_value)}
              hint={`${data.marketplace.created_orders} orders (cancelled: ${formatGHS(data.marketplace.cancelled_value)})`}
              testId="m-created"
            />
            <Metric
              label="Completed marketplace GMV"
              value={formatGHS(data.marketplace.completed_gmv)}
              hint={`${data.marketplace.completed_orders} delivered orders, goods only`}
              testId="m-completed"
            />
            <Metric
              label="Fee-eligible GMV"
              value={formatGHS(summary.eligible_gmv)}
              hint={`${summary.eligible_orders} eligible orders`}
              testId="m-eligible"
            />
            <Metric
              label="Free-order use"
              value={`${summary.free_orders} of ${summary.eligible_orders}`}
              hint={
                summary.free_order_share_percent === null
                  ? undefined
                  : `${summary.free_order_share_percent}% of eligible orders were free`
              }
              testId="m-free"
            />
          </Group>

          <Group title="Subscriptions">
            <Metric
              label="Paying wholesalers"
              value={String(data.subscriptions.paying_wholesalers)}
            />
            <Metric
              label="Paying pharmacies"
              value={String(data.subscriptions.paying_pharmacies)}
            />
            <Metric
              label="Trialing"
              value={String(data.subscriptions.trialing)}
              testId="m-trialing"
            />
            <Metric
              label="Past due"
              value={String(data.subscriptions.past_due)}
              testId="m-pastdue"
            />
            <Metric
              label="Subscriptions in total"
              value={String(data.subscriptions.total)}
              hint={`${data.subscriptions.paused} paused · ${data.subscriptions.cancelled} cancelled · ${data.subscriptions.exempt} exempt`}
            />
          </Group>

          <Group
            title="Collections"
            note="Four different numbers: accrued (above), invoiced, collected, and what is still owed on invoices. Accrued is not the same as collected."
          >
            <Metric
              label="Invoiced"
              value={formatGHS(summary.invoiced)}
              hint="Invoices issued in this period"
              testId="m-invoiced"
            />
            <Metric
              label="Collected"
              value={formatGHS(summary.collected)}
              hint="Payments received in this period, less reversals"
              testId="m-collected"
            />
            <Metric
              label="Outstanding"
              value={formatGHS(summary.outstanding)}
              hint="Owed on invoices, not yet paid"
              testId="m-outstanding"
            />
            <Metric
              label="Overdue"
              value={formatGHS(summary.overdue)}
              hint="Part of outstanding that is past its due date"
              testId="m-overdue"
            />
            <Metric
              label="Accrued, not yet invoiced"
              value={formatGHS(summary.not_yet_invoiced ?? 0)}
              hint="The open billing periods"
              testId="m-not-invoiced"
            />
          </Group>
        </>
      )}
    </div>
  );
}
