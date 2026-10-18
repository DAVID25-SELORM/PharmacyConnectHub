import { useCallback, useEffect, useState } from "react";
import { History, Lock, Plus } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useSession } from "@/hooks/use-session";
import { fetchPlans, type PlanRow } from "@/lib/billing";
import {
  OWNER_ONLY_NOTICE,
  AUDIENCE_LABELS,
  cancelScheduledChange,
  dateLabel,
  fetchChargingSwitches,
  fetchIsPlatformOwner,
  fetchPlanHistory,
  fetchScheduledChanges,
  setCharging,
  summariseTerms,
  type ChargingSwitches,
  type PlanHistoryRow,
  type ScheduledChange,
} from "@/lib/billing-pricing";
import {
  createPlan,
  latestVersion,
  planCodeError,
  planNameError,
  setPlanAvailability,
} from "@/lib/billing-plans";
import { ActionDialog, type Action } from "./BillingControls";
import { PricingChangeDialog } from "./PricingChangeDialog";

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

function newPlanAction(): Action {
  return {
    id: "new-plan",
    label: "New plan",
    description:
      "Creates the plan with no terms. Set its pricing next, then switch it on, before any business can be put on it. The code cannot be changed afterwards.",
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
          { value: "standard", label: "Standard" },
          { value: "custom", label: "Custom (one business)" },
        ],
        help: "Standard: offered to any business of that kind. Custom: agreed with one business.",
      },
      { key: "description", label: "Description (optional)", type: "text" },
    ],
    submit: "Create plan",
    run: async (v) => {
      const codeProblem = planCodeError(v.code ?? "");
      if (codeProblem) throw new Error(codeProblem);
      const nameProblem = planNameError(v.name ?? "");
      if (nameProblem) throw new Error(nameProblem);
      await createPlan({
        code: v.code,
        businessType: v.business_type === "pharmacy" ? "pharmacy" : "wholesaler",
        name: v.name,
        description: v.description ?? "",
        kind: v.kind === "custom" ? "custom" : "standard",
        reason: v.reason.trim(),
      });
      return `Plan ${v.code.trim()} created. Set its pricing next.`;
    },
  };
}

function availabilityAction(plan: PlanRow): Action {
  const hasPublished = plan.billing_plan_versions.some((v) => v.status === "published");
  return {
    id: `availability-${plan.code}`,
    label: `${plan.name}: switch on or off`,
    description:
      "A plan that is on can be given to a business. A plan that is visible is also shown to businesses choosing a plan. Switching a plan off does not move the businesses already on it.",
    fields: [
      {
        key: "active",
        label: "On: businesses can be put on this plan",
        type: "checkbox",
        initial: String(plan.active),
        help: hasPublished ? undefined : "Set the plan's pricing before switching it on.",
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

function cancelAction(change: ScheduledChange): Action {
  return {
    id: `cancel-${change.id}`,
    label: "Cancel this scheduled change",
    description: `${change.plan_name}: ${summariseTerms(change)} was due to start on ${dateLabel(change.effective_from)}. Cancelling stops it before it starts. The record stays in the history.`,
    fields: [],
    submit: "Cancel the change",
    destructive: true,
    run: async (v) => {
      await cancelScheduledChange(change.id, v.reason.trim());
      return "The scheduled change was cancelled.";
    },
  };
}

function switchesAction(current: ChargingSwitches): Action {
  return {
    id: "charging",
    label: "Subscriptions and commissions",
    description:
      "Switch either off to stop charging it from now on. Orders and billing periods already assessed keep what was recorded, and nothing is charged retroactively when you switch it back on.",
    fields: [
      {
        key: "subs",
        label: "Charge subscriptions",
        type: "checkbox",
        initial: String(current.subscriptions_enabled),
      },
      {
        key: "comm",
        label: "Charge commissions on orders",
        type: "checkbox",
        initial: String(current.commissions_enabled),
      },
    ],
    submit: "Save",
    run: async (v) => {
      const subs = v.subs === "true";
      const comm = v.comm === "true";
      if (subs === current.subscriptions_enabled && comm === current.commissions_enabled)
        throw new Error("Nothing has changed.");
      await setCharging(subs, comm, v.reason.trim());
      return `Subscriptions are ${subs ? "charged" : "not charged"}; commissions are ${comm ? "charged" : "not charged"}.`;
    },
  };
}

const STATUS_TONE: Record<string, string> = {
  published: "border-success/30 bg-success/15 text-success",
  scheduled: "border-primary/30 bg-primary/10 text-primary",
  retired: "border-border bg-muted text-muted-foreground",
  cancelled: "border-border bg-muted text-muted-foreground",
  pending: "border-primary/30 bg-primary/10 text-primary",
  applied: "border-success/30 bg-success/15 text-success",
};

/** Admin → Billing → Pricing & Plans: what is active, what is scheduled, and what will happen to existing subscribers. Only the platform owner can change anything; everyone else sees it read-only. */
export function PricingPlans({ onOpenTab }: { onOpenTab?: (tab: string) => void } = {}) {
  const { user } = useSession();
  const [owner, setOwner] = useState<boolean | null>(null);
  const [plans, setPlans] = useState<PlanRow[] | null>(null);
  const [changes, setChanges] = useState<ScheduledChange[] | null>(null);
  const [switches, setSwitches] = useState<ChargingSwitches | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [action, setAction] = useState<Action | null>(null);
  const [changing, setChanging] = useState<PlanRow | null>(null);
  const [historyPlan, setHistoryPlan] = useState<string>("");
  const [history, setHistory] = useState<PlanHistoryRow[] | null>(null);

  const load = useCallback(async () => {
    try {
      const [p, c, s] = await Promise.all([
        fetchPlans(),
        fetchScheduledChanges(),
        fetchChargingSwitches(),
      ]);
      setPlans(p);
      setChanges(c);
      setSwitches(s);
      setError(null);
    } catch (e) {
      setError(errText(e, "Could not load pricing."));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    if (!user?.id) return;
    let cancelled = false;
    void fetchIsPlatformOwner(user.id).then((o) => {
      if (!cancelled) setOwner(o);
    });
    return () => {
      cancelled = true;
    };
  }, [user?.id]);
  useEffect(() => {
    if (!historyPlan) return setHistory(null);
    let cancelled = false;
    setHistory(null);
    fetchPlanHistory(historyPlan)
      .then((h) => !cancelled && setHistory(h))
      .catch((e) => !cancelled && setError(errText(e, "Could not load the history.")));
    return () => {
      cancelled = true;
    };
  }, [historyPlan, changes]);

  if (error && !plans)
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  if (!plans || !changes) return <Skeleton className="h-40" />;
  const canChange = owner === true;
  const pending = changes.filter((c) => c.status === "pending");
  const pendingFor = (planId: string) => pending.filter((c) => c.plan_id === planId);

  return (
    <div className="space-y-6" data-testid="pricing-plans">
      {owner === false && (
        <Card
          className="flex items-start gap-2 border-warning/40 p-3 text-sm"
          data-testid="owner-only-notice"
        >
          <Lock className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
          {OWNER_ONLY_NOTICE}
        </Card>
      )}

      {/* Current plans */}
      <section className="space-y-3" data-testid="section-plans">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h3 className="font-semibold">Current plans</h3>
            <p className="max-w-3xl text-sm text-muted-foreground">
              What is in force today, and any change that is scheduled. A price change is always a
              new version: businesses already on a plan keep their terms unless the change is
              scheduled for existing subscribers too.
            </p>
          </div>
          {canChange && (
            <Button size="sm" onClick={() => setAction(newPlanAction())} data-testid="new-plan">
              <Plus className="mr-1 h-4 w-4" /> New plan
            </Button>
          )}
        </div>
        <Card className="overflow-x-auto p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Plan</TableHead>
                <TableHead>For</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>In force now</TableHead>
                <TableHead>Scheduled</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {plans.length === 0 && (
                <TableRow>
                  <TableCell colSpan={6} className="py-6 text-center text-muted-foreground">
                    No plans yet.{canChange ? " Create the first one." : ""}
                  </TableCell>
                </TableRow>
              )}
              {plans.map((p) => {
                const v = latestVersion(p);
                const sched = pendingFor(p.id);
                return (
                  <TableRow key={p.id} data-testid="plan-row">
                    <TableCell className="whitespace-nowrap font-medium">
                      {p.name}
                      <span className="block text-xs font-normal text-muted-foreground">
                        {p.code}
                      </span>
                    </TableCell>
                    <TableCell>
                      {p.business_type === "wholesaler" ? "Wholesalers" : "Pharmacies"}
                    </TableCell>
                    <TableCell>
                      <Badge variant="outline">
                        {p.active ? (p.publicly_visible ? "On, visible" : "On, hidden") : "Off"}
                      </Badge>
                    </TableCell>
                    <TableCell className="min-w-56 text-sm">
                      {v ? (
                        <>
                          <span className="font-medium">Version {v.version}</span>
                          <span className="block text-xs text-muted-foreground">
                            {summariseTerms(v)}
                          </span>
                        </>
                      ) : (
                        <span className="text-muted-foreground">No version yet</span>
                      )}
                    </TableCell>
                    <TableCell className="min-w-56 text-sm" data-testid="plan-scheduled">
                      {sched.length === 0 ? (
                        <span className="text-muted-foreground">Nothing scheduled</span>
                      ) : (
                        sched.map((c) => (
                          <div key={c.id}>
                            <Badge variant="outline" className={STATUS_TONE.scheduled}>
                              From {dateLabel(c.effective_from)}
                            </Badge>
                            <span className="block text-xs text-muted-foreground">
                              {summariseTerms(c)} · {AUDIENCE_LABELS[c.audience].toLowerCase()}
                            </span>
                          </div>
                        ))
                      )}
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-right">
                      {canChange && (
                        <>
                          <Button
                            size="sm"
                            variant="outline"
                            onClick={() => setChanging(p)}
                            data-testid="change-pricing"
                          >
                            Change pricing
                          </Button>{" "}
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => setAction(availabilityAction(p))}
                            data-testid="plan-availability"
                          >
                            On / off
                          </Button>{" "}
                        </>
                      )}
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => setHistoryPlan(p.id)}
                        data-testid="plan-history"
                      >
                        <History className="mr-1 h-3.5 w-3.5" aria-hidden="true" /> History
                      </Button>
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </Card>
      </section>

      {/* Scheduled changes */}
      <section className="space-y-3" data-testid="section-scheduled">
        <div>
          <h3 className="font-semibold">Scheduled changes</h3>
          <p className="text-sm text-muted-foreground">
            Pending changes can be cancelled until the day they start. Applied and cancelled ones
            stay here as the record.
          </p>
        </div>
        {changes.length === 0 ? (
          <Card className="p-4 text-sm text-muted-foreground" data-testid="no-scheduled">
            No price change has been scheduled.
          </Card>
        ) : (
          <Card className="overflow-x-auto p-0">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Plan</TableHead>
                  <TableHead>Starts</TableHead>
                  <TableHead>New terms</TableHead>
                  <TableHead>Reaches</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {changes.map((c) => (
                  <TableRow key={c.id} data-testid="scheduled-row">
                    <TableCell className="font-medium">
                      {c.plan_name}
                      <span className="block text-xs font-normal text-muted-foreground">
                        version {c.version}
                      </span>
                    </TableCell>
                    <TableCell className="whitespace-nowrap">
                      {dateLabel(c.effective_from)}
                    </TableCell>
                    <TableCell className="min-w-56 text-xs">{summariseTerms(c)}</TableCell>
                    <TableCell className="text-sm">
                      {AUDIENCE_LABELS[c.audience]}
                      {c.audience === "new_and_existing" && (
                        <span className="block text-xs text-muted-foreground">
                          {c.keep_overrides ? "custom pricing kept" : "custom pricing replaced"}
                        </span>
                      )}
                    </TableCell>
                    <TableCell className="text-sm">
                      <Badge variant="outline" className={STATUS_TONE[c.status]}>
                        {c.status === "pending"
                          ? "Pending"
                          : c.status === "applied"
                            ? "Applied"
                            : "Cancelled"}
                      </Badge>
                      <span className="block text-xs text-muted-foreground">
                        {c.status === "applied"
                          ? `${c.applied_result?.moved ?? 0} moved${c.applied_result?.skipped ? `, ${c.applied_result.skipped} left out` : ""}`
                          : c.status === "cancelled"
                            ? `${c.cancelled_by ?? "someone"}: ${c.cancel_reason ?? ""}`
                            : `${c.created_by ?? "someone"}: ${c.reason}`}
                      </span>
                    </TableCell>
                    <TableCell className="text-right">
                      {canChange && c.status === "pending" && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setAction(cancelAction(c))}
                          data-testid="cancel-change"
                        >
                          Cancel
                        </Button>
                      )}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>
        )}
      </section>

      {/* Charging switches */}
      {switches && (
        <section className="space-y-3" data-testid="section-switches">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 className="font-semibold">Subscriptions and commissions</h3>
              <p className="text-sm text-muted-foreground">
                Each can be switched off on its own, for everyone. It changes what is assessed from
                then on, never what was already recorded.
              </p>
            </div>
            {canChange && (
              <Button
                size="sm"
                variant="outline"
                onClick={() => setAction(switchesAction(switches))}
                data-testid="change-switches"
              >
                Change
              </Button>
            )}
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            {(
              [
                ["Subscriptions", switches.subscriptions_enabled],
                ["Commissions", switches.commissions_enabled],
              ] as const
            ).map(([label, on]) => (
              <Card key={label} className="flex items-center justify-between p-3">
                <span className="font-medium">{label}</span>
                <Badge
                  variant="outline"
                  className={on ? STATUS_TONE.applied : STATUS_TONE.cancelled}
                  data-testid={`switch-${label.toLowerCase()}`}
                >
                  {on ? "Charged" : "Not charged"}
                </Badge>
              </Card>
            ))}
          </div>
        </section>
      )}

      {/* Promotions and business-specific pricing */}
      <section className="space-y-2" data-testid="section-other-pricing">
        <h3 className="font-semibold">Promotions and business-specific pricing</h3>
        <p className="text-sm text-muted-foreground">
          These already exist and work the same way: they sit on top of a plan and never change the
          plan itself.
        </p>
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            onClick={() => onOpenTab?.("promotions")}
            disabled={!onOpenTab}
          >
            Promotions
          </Button>
          <Button
            size="sm"
            variant="outline"
            onClick={() => onOpenTab?.("organizations")}
            disabled={!onOpenTab}
          >
            A business's custom pricing (Organizations)
          </Button>
        </div>
      </section>

      {/* Pricing history */}
      <section className="space-y-3" data-testid="section-history">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 className="font-semibold">Pricing history</h3>
            <p className="text-sm text-muted-foreground">
              Every version of a plan, who set it and why. Versions are never edited.
            </p>
          </div>
          <Select value={historyPlan} onValueChange={setHistoryPlan}>
            <SelectTrigger className="w-64" aria-label="Plan history">
              <SelectValue placeholder="Choose a plan…" />
            </SelectTrigger>
            <SelectContent>
              {plans.map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        {historyPlan && !history && <Skeleton className="h-24" />}
        {history && (
          <Card className="overflow-x-auto p-0" data-testid="history-table">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Version</TableHead>
                  <TableHead>Status</TableHead>
                  <TableHead>Starts</TableHead>
                  <TableHead>Terms</TableHead>
                  <TableHead className="text-right">Businesses on it</TableHead>
                  <TableHead>Set by</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {history.map((h) => (
                  <TableRow key={h.id}>
                    <TableCell className="font-medium">v{h.version}</TableCell>
                    <TableCell>
                      <Badge variant="outline" className={STATUS_TONE[h.status]}>
                        {h.status === "published"
                          ? "In force"
                          : h.status[0].toUpperCase() + h.status.slice(1)}
                      </Badge>
                    </TableCell>
                    <TableCell className="whitespace-nowrap text-sm">
                      {dateLabel(h.effective_from)}
                    </TableCell>
                    <TableCell className="min-w-56 text-xs">{summariseTerms(h)}</TableCell>
                    <TableCell className="text-right tabular-nums">{h.businesses_on_it}</TableCell>
                    <TableCell className="text-xs">
                      {h.created_by ?? "–"}
                      <span className="block text-muted-foreground">{h.reason}</span>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Card>
        )}
      </section>

      <ActionDialog
        action={action}
        onClose={() => setAction(null)}
        onDone={() => {
          setAction(null);
          void load();
        }}
      />
      {changing && (
        <PricingChangeDialog
          plan={changing}
          onClose={() => setChanging(null)}
          onDone={() => {
            setChanging(null);
            void load();
          }}
        />
      )}
    </div>
  );
}
