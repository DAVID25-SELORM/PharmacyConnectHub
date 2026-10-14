import { useCallback, useEffect, useState } from "react";
import { Plus } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
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
import {
  PLAN_TERM_FIELDS,
  createPlan,
  latestVersion,
  describeTermsChange,
  paramsFromTermsForm,
  planCodeError,
  planNameError,
  publishPlanVersion,
  setPlanAvailability,
  termsFormFromVersion,
} from "@/lib/billing-plans";
import { ActionDialog, type Action } from "./BillingControls";

function newPlanAction(): Action {
  return {
    id: "new-plan",
    label: "New plan",
    description:
      "Creates the plan with no terms. Publish its first version, then switch it on, before any business can be put on it. The code cannot be changed afterwards.",
    fields: [
      { key: "code", label: "Code (for example wholesale-growth)", type: "text" },
      { key: "name", label: "Name businesses see", type: "text" },
      {
        key: "business_type",
        label: "For",
        type: "select",
        initial: "wholesaler",
        options: [
          { value: "wholesaler", label: "Wholesalers" },
          { value: "pharmacy", label: "Pharmacies" },
        ],
      },
      {
        key: "kind",
        label: "Kind",
        type: "select",
        initial: "standard",
        options: [
          { value: "standard", label: "Standard: offered to any business of that kind" },
          { value: "custom", label: "Custom: agreed with one business" },
        ],
      },
      { key: "description", label: "Description (optional)", type: "text" },
    ],
    submit: "Create plan",
    run: async (v) => {
      const codeProblem = planCodeError(v.code ?? "");
      if (codeProblem) throw new Error(codeProblem);
      const nameProblem = planNameError(v.name ?? "");
      if (nameProblem) throw new Error(nameProblem);
      if ((v.description ?? "").length > 1000)
        throw new Error("The description is at most 1000 characters.");
      await createPlan({
        code: v.code,
        businessType: v.business_type === "pharmacy" ? "pharmacy" : "wholesaler",
        name: v.name,
        description: v.description ?? "",
        kind: v.kind === "custom" ? "custom" : "standard",
        reason: v.reason.trim(),
      });
      return `Plan ${v.code.trim()} created. Publish its first version next.`;
    },
  };
}

function publishAction(plan: PlanRow): Action {
  const latest = latestVersion(plan);
  const initial = termsFormFromVersion(latest);
  const wholesaler = plan.business_type === "wholesaler";
  const next = (latest?.version ?? 0) + 1;
  return {
    id: `publish-${plan.code}`,
    label: `${plan.name}: publish version ${next}`,
    description: `Publishes version ${next} and retires the one before it. Versions are never edited: businesses already on this plan keep the version they are on until you move them to this one, and every order assessment keeps a snapshot of the terms it used.${
      latest ? "" : " This is the plan's first version."
    }`,
    fields: PLAN_TERM_FIELDS.filter((f) => wholesaler || !f.wholesalerOnly).map((f) => ({
      key: f.key,
      label: f.label,
      type: "text" as const,
      initial: initial[f.key],
      help: f.help,
    })),
    submit: `Publish version ${next}`,
    run: async (v) => {
      const { params, error } = paramsFromTermsForm(v, plan.business_type, {
        currency: latest?.currency,
        entitlements: latest?.entitlements,
        metadata: latest?.metadata,
      });
      if (error) throw new Error(error);
      if (latest && describeTermsChange(initial, v, plan.business_type).length === 0)
        throw new Error("Nothing has changed from the current version.");
      await publishPlanVersion(plan.id, params, v.reason.trim());
      return `Version ${next} of ${plan.name} is published.`;
    },
  };
}

function availabilityAction(plan: PlanRow): Action {
  const hasPublished = plan.billing_plan_versions.some((v) => v.status === "published");
  return {
    id: `availability-${plan.code}`,
    label: `${plan.name}: availability`,
    description:
      "A plan that is on can be given to a business. A plan that is visible is also shown to businesses choosing a plan. Switching a plan off does not move the businesses already on it.",
    fields: [
      {
        key: "active",
        label: "On: businesses can be put on this plan",
        type: "checkbox",
        initial: String(plan.active),
        help: hasPublished ? undefined : "Publish a version of the plan before switching it on.",
      },
      {
        key: "visible",
        label: "Visible to businesses choosing a plan",
        type: "checkbox",
        initial: String(plan.publicly_visible),
      },
    ],
    submit: "Save",
    run: async (v) => {
      const active = v.active === "true";
      const visible = v.visible === "true";
      if (visible && !active) throw new Error("A plan that is switched off cannot be shown.");
      if (active === plan.active && visible === plan.publicly_visible)
        throw new Error("Nothing has changed.");
      await setPlanAvailability(plan.id, active, visible, v.reason.trim());
      return `${plan.name} is ${active ? (visible ? "on and visible" : "on and hidden") : "off"}.`;
    },
  };
}

/** The plans and their versions. Prices change by publishing a new immutable version (an audited administrator operation), never by editing one. */
export function AdminBillingPlansSection() {
  const [plans, setPlans] = useState<PlanRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [action, setAction] = useState<Action | null>(null);

  const load = useCallback(() => {
    fetchPlans()
      .then((p) => {
        setPlans(p);
        setError(null);
      })
      .catch((e) => setError(e instanceof Error ? e.message : "Could not load plans."));
  }, []);
  useEffect(() => {
    load();
  }, [load]);

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
      <div className="flex flex-wrap items-start justify-between gap-3">
        <p className="max-w-3xl text-sm text-muted-foreground">
          Each plan's terms are published as immutable versions. A price change publishes a new
          version; existing subscribers keep the version they are on, and every order assessment
          keeps a snapshot of the terms it used.
        </p>
        <Button size="sm" onClick={() => setAction(newPlanAction())} data-testid="new-plan">
          <Plus className="mr-1 h-4 w-4" /> New plan
        </Button>
      </div>
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
              <TableHead />
            </TableRow>
          </TableHeader>
          <TableBody>
            {plans.length === 0 && (
              <TableRow>
                <TableCell colSpan={11} className="py-6 text-center text-muted-foreground">
                  No plans yet. Create the first one.
                </TableCell>
              </TableRow>
            )}
            {plans.map((p) => {
              const v = latestVersion(p);
              return (
                <TableRow key={p.id} data-testid="plan-row">
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
                  <TableCell>{v ? `v${v.version}` : "No version"}</TableCell>
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
                  <TableCell className="whitespace-nowrap text-right">
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => setAction(publishAction(p))}
                      data-testid="publish-version"
                    >
                      New version
                    </Button>{" "}
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => setAction(availabilityAction(p))}
                      data-testid="plan-availability"
                    >
                      Availability
                    </Button>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </Card>
      <ActionDialog
        action={action}
        onClose={() => setAction(null)}
        onDone={() => {
          setAction(null);
          load();
        }}
      />
    </div>
  );
}
