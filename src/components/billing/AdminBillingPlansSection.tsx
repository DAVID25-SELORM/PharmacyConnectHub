import { useEffect, useState } from "react";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatGHS } from "@/lib/format";
import { fetchPlans, type PlanRow } from "@/lib/billing";

/** The plans and their published versions, read-only. Prices change by publishing a new immutable version (an audited administrator operation), never by editing here. */
export function AdminBillingPlansSection() {
  const [plans, setPlans] = useState<PlanRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    fetchPlans()
      .then(setPlans)
      .catch((e) => setError(e instanceof Error ? e.message : "Could not load plans."));
  }, []);

  if (error) {
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  }
  if (!plans) return <Skeleton className="h-40" />;
  return (
    <div className="space-y-4" data-testid="billing-plans">
      <p className="text-sm text-muted-foreground">
        Each plan's terms are published as immutable versions. A price change publishes a new
        version; existing subscribers keep the version they are on, and every order assessment keeps
        a snapshot of the terms it used.
      </p>
      <Card className="overflow-x-auto p-0">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Plan</TableHead>
              <TableHead>For</TableHead>
              <TableHead>Availability</TableHead>
              <TableHead>Latest version</TableHead>
              <TableHead className="text-right">Subscription</TableHead>
              <TableHead className="text-right">Trial</TableHead>
              <TableHead className="text-right">Free orders (launch / monthly)</TableHead>
              <TableHead className="text-right">Fee</TableHead>
              <TableHead className="text-right">Per-order limits</TableHead>
              <TableHead className="text-right">Monthly cap</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {plans.length === 0 && (
              <TableRow>
                <TableCell colSpan={10} className="py-6 text-center text-muted-foreground">
                  No plans yet.
                </TableCell>
              </TableRow>
            )}
            {plans.map((p) => {
              const v = [...p.billing_plan_versions].sort((a, b) => b.version - a.version)[0];
              return (
                <TableRow key={p.id}>
                  <TableCell className="whitespace-nowrap font-medium">
                    {p.name}
                    <span className="block text-xs text-muted-foreground">{p.code}</span>
                  </TableCell>
                  <TableCell>
                    {p.business_type === "wholesaler" ? "Wholesalers" : "Pharmacies"}
                  </TableCell>
                  <TableCell>
                    <Badge variant="outline">
                      {p.active ? (p.publicly_visible ? "On, visible" : "On, hidden") : "Off"}
                    </Badge>
                  </TableCell>
                  <TableCell>{v ? `v${v.version}` : "–"}</TableCell>
                  <TableCell className="text-right">
                    {v
                      ? `${formatGHS(v.subscription_amount)} / ${v.billing_interval_months === 1 ? "mo" : `${v.billing_interval_months} mo`}`
                      : "–"}
                  </TableCell>
                  <TableCell className="text-right">
                    {v ? `${v.free_trial_days} days` : "–"}
                  </TableCell>
                  <TableCell className="text-right">
                    {v ? `${v.onboarding_free_orders} / ${v.monthly_free_orders}` : "–"}
                  </TableCell>
                  <TableCell className="text-right">
                    {v ? `${Number(v.transaction_fee_percentage)}%` : "–"}
                  </TableCell>
                  <TableCell className="text-right">
                    {v
                      ? `${v.transaction_fee_min === null ? "no min" : formatGHS(v.transaction_fee_min)} / ${v.transaction_fee_max === null ? "no max" : formatGHS(v.transaction_fee_max)}`
                      : "–"}
                  </TableCell>
                  <TableCell className="text-right">
                    {v
                      ? v.transaction_fee_cycle_cap === null
                        ? "none"
                        : formatGHS(v.transaction_fee_cycle_cap)
                      : "–"}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </Card>
    </div>
  );
}
