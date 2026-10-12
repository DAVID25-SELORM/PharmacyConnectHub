import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { formatGHS } from "@/lib/format";
import {
  ENTRY_LABELS,
  describeBilledOrder,
  fetchAdminBillingOrganizations,
  fetchAdminBusinessBilling,
  fetchPlans,
  periodLabel,
  type BusinessBillingDetail,
  type OrganizationRow,
  type PlanRow,
} from "@/lib/billing";

const PAGE = 20;
const ALL = "all";
const dateText = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "UTC",
      })
    : "–";

function BusinessDetail({ businessId, flavor }: { businessId: string; flavor: "real" | "shadow" }) {
  const [detail, setDetail] = useState<BusinessBillingDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    setDetail(null);
    setError(null);
    fetchAdminBusinessBilling(businessId, flavor)
      .then((d) => {
        if (!cancelled) setDetail(d);
      })
      .catch((e) => {
        if (!cancelled)
          setError(e instanceof Error ? e.message : "Could not load this organization.");
      });
    return () => {
      cancelled = true;
    };
  }, [businessId, flavor]);

  if (error) return <p className="text-sm text-destructive">{error}</p>;
  if (!detail) return <Skeleton className="h-40" />;
  if (!detail.has_subscription)
    return (
      <p className="text-sm text-muted-foreground">
        This organization has no billing subscription.
      </p>
    );
  const terms = detail.terms_now as Record<string, unknown> | null;
  return (
    <div className="space-y-5 text-sm" data-testid="billing-detail">
      <section className="space-y-1">
        <h4 className="font-semibold">Terms in force</h4>
        {terms ? (
          <p>
            Plan {String(terms.plan_code)} (version {String(terms.plan_version)}):{" "}
            {formatGHS(Number(terms.subscription_amount))} per{" "}
            {Number(terms.billing_interval_months) === 1
              ? "month"
              : `${terms.billing_interval_months} months`}
            , {String(terms.onboarding_free_orders)} launch and {String(terms.monthly_free_orders)}{" "}
            monthly free orders, {String(terms.transaction_fee_percentage)}% fee
            {terms.transaction_fee_cycle_cap !== null
              ? `, capped at ${formatGHS(Number(terms.transaction_fee_cycle_cap))} a month`
              : ", no monthly cap"}
            .
          </p>
        ) : (
          <p className="text-muted-foreground">No terms are in force yet.</p>
        )}
        <p className="text-muted-foreground">
          Mode: {detail.effective_mode}. Subscription status:{" "}
          {String((detail.subscription as Record<string, unknown>).status)}.
        </p>
      </section>
      <section className="space-y-1">
        <h4 className="font-semibold">Launch free orders</h4>
        {(detail.grants ?? []).length === 0 ? (
          <p className="text-muted-foreground">None granted.</p>
        ) : (
          (detail.grants ?? []).map((g) => (
            <p key={g.id}>
              {g.used} of {g.quantity} used ({g.source}, {dateText(g.created_at)}): {g.reason}
            </p>
          ))
        )}
      </section>
      <section className="space-y-1">
        <h4 className="font-semibold">Periods</h4>
        <div className="overflow-x-auto">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Period</TableHead>
                <TableHead className="text-right">Subscription</TableHead>
                <TableHead className="text-right">Fees</TableHead>
                <TableHead className="text-right">Credits</TableHead>
                <TableHead className="text-right">Due</TableHead>
                <TableHead className="text-right">Orders (free / charged)</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(detail.periods ?? []).map((p) => (
                <TableRow key={p.id}>
                  <TableCell className="whitespace-nowrap">
                    {periodLabel(p.period_start, p.period_end)}
                  </TableCell>
                  <TableCell className="text-right">{formatGHS(p.subscription_amount)}</TableCell>
                  <TableCell className="text-right">
                    {formatGHS(p.transaction_fees_amount ?? 0)}
                  </TableCell>
                  <TableCell className="text-right">{formatGHS(p.credits_amount)}</TableCell>
                  <TableCell className="text-right">{formatGHS(p.amount_due)}</TableCell>
                  <TableCell className="text-right">
                    {(p.free_onboarding_orders ?? 0) + (p.free_monthly_orders ?? 0)} /{" "}
                    {p.chargeable_orders ?? 0}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </section>
      <section className="space-y-1">
        <h4 className="font-semibold">Orders</h4>
        {(detail.assessments ?? []).length === 0 ? (
          <p className="text-muted-foreground">No orders assessed.</p>
        ) : (
          <ul className="divide-y">
            {(detail.assessments ?? []).map((a, i) => (
              <li
                key={`${a.order_number}-${a.kind}-${a.adjustment_seq}-${i}`}
                className="flex flex-wrap justify-between gap-2 py-1.5"
              >
                <span>
                  {a.order_number} · {formatGHS(a.billable_gmv)}
                </span>
                <span>{describeBilledOrder(a, formatGHS)}</span>
              </li>
            ))}
          </ul>
        )}
      </section>
      <section className="space-y-1">
        <h4 className="font-semibold">Ledger</h4>
        <ul className="divide-y">
          {(detail.ledger ?? []).map((e, i) => (
            <li
              key={`${e.created_at}-${i}`}
              className="flex flex-wrap justify-between gap-2 py-1.5"
            >
              <span>
                {ENTRY_LABELS[e.entry_type] ?? e.entry_type.replace(/_/g, " ")}
                {e.reason ? <span className="text-muted-foreground"> · {e.reason}</span> : null}
              </span>
              <span>
                {e.credit_amount > 0
                  ? `− ${formatGHS(e.credit_amount)}`
                  : formatGHS(e.charged_amount)}
              </span>
            </li>
          ))}
        </ul>
      </section>
      <section className="space-y-1">
        <h4 className="font-semibold">Audit trail</h4>
        {(detail.audit ?? []).length === 0 ? (
          <p className="text-muted-foreground">Nothing recorded.</p>
        ) : (
          <ul className="divide-y">
            {(detail.audit ?? []).map((a, i) => (
              <li key={`${a.created_at}-${i}`} className="py-1.5">
                {a.activity}{" "}
                <span className="text-xs text-muted-foreground">{dateText(a.created_at)}</span>
                {typeof a.details?.reason === "string" && (
                  <span className="block text-xs text-muted-foreground">{a.details.reason}</span>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>
      {(detail.queue ?? []).length > 0 && (
        <section className="space-y-1">
          <h4 className="font-semibold text-destructive">Billing retries</h4>
          {(detail.queue ?? []).map((q) => (
            <p key={`${q.order_id}-${q.kind}`}>
              {q.kind} · {q.status} · {q.attempts} attempts {q.error ? `· ${q.error}` : ""}
            </p>
          ))}
        </section>
      )}
    </div>
  );
}

export function AdminBillingOrganizationsSection() {
  const [flavor, setFlavor] = useState<"real" | "shadow">("real");
  const [type, setType] = useState(ALL);
  const [plan, setPlan] = useState(ALL);
  const [status, setStatus] = useState(ALL);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [plans, setPlans] = useState<PlanRow[]>([]);
  const [data, setData] = useState<{ total: number; rows: OrganizationRow[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState<OrganizationRow | null>(null);

  useEffect(() => {
    fetchPlans()
      .then(setPlans)
      .catch(() => setPlans([]));
  }, []);
  useEffect(() => {
    const t = window.setTimeout(() => {
      setQuery(search.trim());
      setPage(0);
    }, 300);
    return () => window.clearTimeout(t);
  }, [search]);
  useEffect(() => {
    let cancelled = false;
    setError(null);
    fetchAdminBillingOrganizations({
      flavor,
      businessType: type === ALL ? null : type,
      planCode: plan === ALL ? null : plan,
      status: status === ALL ? null : status,
      search: query || null,
      limit: PAGE,
      offset: page * PAGE,
    })
      .then((d) => {
        if (!cancelled) setData(d);
      })
      .catch((e) => {
        if (!cancelled) setError(e instanceof Error ? e.message : "Could not load organizations.");
      });
    return () => {
      cancelled = true;
    };
  }, [flavor, type, plan, status, query, page]);

  const pages = data ? Math.max(1, Math.ceil(data.total / PAGE)) : 1;
  const reset =
    <T,>(setter: (v: T) => void) =>
    (v: T) => {
      setter(v);
      setPage(0);
    };

  return (
    <div className="space-y-4" data-testid="billing-organizations">
      <div className="flex flex-wrap items-end gap-3">
        <Input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search by name…"
          className="h-9 w-56"
          aria-label="Search organizations"
        />
        <Select value={type} onValueChange={reset(setType)}>
          <SelectTrigger className="h-9 w-40" aria-label="Business type">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL}>All types</SelectItem>
            <SelectItem value="pharmacy">Pharmacies</SelectItem>
            <SelectItem value="wholesaler">Wholesalers</SelectItem>
          </SelectContent>
        </Select>
        <Select value={plan} onValueChange={reset(setPlan)}>
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
        <Select value={status} onValueChange={reset(setStatus)}>
          <SelectTrigger className="h-9 w-44" aria-label="Subscription status">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value={ALL}>All statuses</SelectItem>
            <SelectItem value="trialing">Trialing</SelectItem>
            <SelectItem value="active">Active</SelectItem>
            <SelectItem value="past_due">Past due</SelectItem>
            <SelectItem value="grace_period">Grace period</SelectItem>
            <SelectItem value="suspended">Suspended</SelectItem>
            <SelectItem value="cancelled">Cancelled</SelectItem>
          </SelectContent>
        </Select>
        <Tabs
          value={flavor}
          onValueChange={(v) => reset(setFlavor)(v as "real" | "shadow")}
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
      {!data && !error && <Skeleton className="h-48" />}
      {data && (
        <Card className="overflow-x-auto p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Organization</TableHead>
                <TableHead>Plan</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Mode</TableHead>
                <TableHead className="text-right">Subscription</TableHead>
                <TableHead className="text-right">Fees</TableHead>
                <TableHead className="text-right">Orders (free / charged)</TableHead>
                <TableHead className="text-right">Due</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {data.rows.length === 0 && (
                <TableRow>
                  <TableCell colSpan={8} className="py-6 text-center text-muted-foreground">
                    No organizations match.
                  </TableCell>
                </TableRow>
              )}
              {data.rows.map((r) => (
                <TableRow
                  key={r.business_id}
                  className="cursor-pointer"
                  onClick={() => setOpen(r)}
                  data-testid="org-row"
                >
                  <TableCell className="whitespace-nowrap font-medium">
                    {r.name}
                    <span className="ml-2 text-xs text-muted-foreground">{r.type}</span>
                  </TableCell>
                  <TableCell>{r.plan_name ?? r.plan_code ?? "–"}</TableCell>
                  <TableCell>
                    <Badge variant="outline">{r.paused ? "paused" : r.status}</Badge>
                  </TableCell>
                  <TableCell>{r.effective_mode}</TableCell>
                  <TableCell className="text-right">{formatGHS(r.subscription_amount)}</TableCell>
                  <TableCell className="text-right">
                    {formatGHS(r.transaction_fees_amount)}
                  </TableCell>
                  <TableCell className="text-right">
                    {r.free_onboarding_orders + r.free_monthly_orders} / {r.chargeable_orders}
                  </TableCell>
                  <TableCell className="text-right">{formatGHS(r.amount_due)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Card>
      )}
      {data && data.total > PAGE && (
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">
            Page {page + 1} of {pages} · {data.total} organizations
          </span>
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={page === 0}
              onClick={() => setPage((p) => p - 1)}
            >
              Previous
            </Button>
            <Button
              variant="outline"
              size="sm"
              disabled={page + 1 >= pages}
              onClick={() => setPage((p) => p + 1)}
            >
              Next
            </Button>
          </div>
        </div>
      )}

      <Sheet open={open !== null} onOpenChange={(o) => !o && setOpen(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-2xl">
          <SheetHeader>
            <SheetTitle>{open?.name}</SheetTitle>
            <SheetDescription>
              Billing detail ({flavor === "shadow" ? "shadow: estimated" : "real"}). Read-only.
            </SheetDescription>
          </SheetHeader>
          <div className="mt-4">
            {open && <BusinessDetail businessId={open.business_id} flavor={flavor} />}
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
}
