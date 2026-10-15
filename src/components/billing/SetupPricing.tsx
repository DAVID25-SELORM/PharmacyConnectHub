import { useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import type { PlanRow } from "@/lib/billing";
import { reasonError } from "@/lib/billing-controls";
import {
  PLAN_TERM_FIELDS,
  describeTermsChange,
  latestVersion,
  termsFormFromVersion,
  type PlanTermsKey,
} from "@/lib/billing-plans";
import {
  STANDARD_PLAN,
  describePricingSave,
  pricingSteps,
  pricingTarget,
  savePricing,
} from "@/lib/billing-setup";

type Kind = "wholesaler" | "pharmacy";

const GROUPS: { title: string; hint: string; keys: PlanTermsKey[]; wholesalerOnly?: boolean }[] = [
  {
    title: "Subscription",
    hint: "What the business pays each billing period, and how long it is free at the start.",
    keys: ["subscription_amount", "billing_interval_months", "free_trial_days"],
  },
  {
    title: "Free orders",
    hint: "Orders that are not charged a fee: a one-time launch allowance, and some every period.",
    keys: ["onboarding_free_orders", "monthly_free_orders"],
    wholesalerOnly: true,
  },
  {
    title: "Transaction fee",
    hint: "Charged to the wholesaler on each delivered order after its free orders are used.",
    keys: [
      "transaction_fee_percentage",
      "transaction_fee_min",
      "transaction_fee_max",
      "transaction_fee_cycle_cap",
    ],
    wholesalerOnly: true,
  },
];
const MORE: PlanTermsKey[] = ["min_billable_order_amount", "max_users", "max_branches"];

/** The pricing form for one kind of business: one plan, edited in plain boxes. Saving uses the existing audited plan operations. */
export function SetupPricing({
  type,
  plans,
  onSaved,
}: {
  type: Kind;
  plans: PlanRow[];
  onSaved: () => void;
}) {
  const target = useMemo(() => pricingTarget(plans, type), [plans, type]);
  const latest = target ? latestVersion(target) : undefined;
  const initial = useMemo(() => termsFormFromVersion(latest), [latest]);
  const [values, setValues] = useState<Record<string, string>>(initial);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // A saved change (or a different plan) starts the form again from what is now saved. Reloading the same figures leaves what is being typed alone.
  const initialKey = JSON.stringify(initial);
  useEffect(() => {
    setValues(initial);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialKey, target?.id]);

  const set = (key: string, v: string) => setValues((x) => ({ ...x, [key]: v }));
  const fields = new Map(PLAN_TERM_FIELDS.map((f) => [f.key, f]));
  const changes = describeTermsChange(initial, values, type);
  const steps = pricingSteps(target, type, values);
  const next = (latest?.version ?? 0) + 1;
  const preview =
    steps.length === 0
      ? "Nothing has changed."
      : [
          steps.includes("create") ? `Create the plan "${STANDARD_PLAN[type].name}"` : null,
          steps.includes("publish")
            ? `publish version ${next}${target && latest ? ` (replacing version ${latest.version})` : ""}`
            : null,
          steps.includes("activate") ? "switch the plan on" : null,
        ]
          .filter(Boolean)
          .join(", then ") + ".";

  const save = async () => {
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    setBusy(true);
    setError(null);
    try {
      const r = await savePricing({ plan: target, type, values, reason: reason.trim() });
      toast.success(describePricingSave(r.steps, target?.name ?? STANDARD_PLAN[type].name));
      setReason("");
      onSaved();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not save the pricing.");
    } finally {
      setBusy(false);
    }
  };

  const box = (key: PlanTermsKey) => {
    const f = fields.get(key)!;
    return (
      <div key={key} className="grid gap-1">
        <Label htmlFor={`price-${type}-${key}`}>{f.label}</Label>
        <Input
          id={`price-${type}-${key}`}
          inputMode="decimal"
          value={values[key] ?? ""}
          onChange={(e) => set(key, e.target.value)}
        />
        {f.help && <p className="text-xs text-muted-foreground">{f.help}</p>}
      </div>
    );
  };

  return (
    <div className="space-y-4" data-testid={`pricing-${type}`}>
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="font-medium">
          {target ? target.name : `${STANDARD_PLAN[type].name} (not created yet)`}
        </span>
        {target && (
          <>
            <Badge variant="outline">{latest ? `version ${latest.version}` : "no terms yet"}</Badge>
            <Badge variant="outline">{target.active ? "On" : "Off"}</Badge>
          </>
        )}
      </div>

      {GROUPS.filter((g) => !g.wholesalerOnly || type === "wholesaler").map((g) => (
        <fieldset key={g.title} className="space-y-2 rounded-md border p-3">
          <legend className="px-1 text-sm font-semibold">{g.title}</legend>
          <p className="text-xs text-muted-foreground">{g.hint}</p>
          <div className="grid items-start gap-3 sm:grid-cols-2">{g.keys.map(box)}</div>
        </fieldset>
      ))}

      <details className="rounded-md border p-3">
        <summary className="cursor-pointer text-sm font-semibold">More options</summary>
        <div className="mt-3 grid items-start gap-3 sm:grid-cols-2">
          {MORE.filter((k) => type === "wholesaler" || !fields.get(k)?.wholesalerOnly).map(box)}
        </div>
      </details>

      {changes.length > 0 && (
        <ul className="space-y-0.5 text-sm" data-testid={`pricing-changes-${type}`}>
          {changes.map((c) => (
            <li key={c}>{c}</li>
          ))}
        </ul>
      )}
      <p className="text-sm text-muted-foreground" data-testid={`pricing-preview-${type}`}>
        {preview}
        {steps.includes("publish") && target
          ? " Businesses already on this plan keep their current version until you move them (Organizations, then the business, then Change the plan)."
          : ""}
      </p>
      <div className="grid gap-1">
        <Label htmlFor={`price-${type}-reason`}>Reason (kept in the audit trail)</Label>
        <Textarea
          id={`price-${type}-reason`}
          rows={2}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
        />
      </div>
      {error && (
        <p className="text-sm text-destructive" role="alert" data-testid={`pricing-error-${type}`}>
          {error}
        </p>
      )}
      <Button
        onClick={() => void save()}
        disabled={busy || steps.length === 0}
        data-testid={`pricing-save-${type}`}
      >
        {busy ? "Saving…" : "Save pricing"}
      </Button>
    </div>
  );
}
