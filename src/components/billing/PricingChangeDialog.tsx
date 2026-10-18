import { useMemo, useState } from "react";
import { toast } from "sonner";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatGHS } from "@/lib/format";
import type { PlanRow } from "@/lib/billing";
import { reasonError } from "@/lib/billing-controls";
import {
  PLAN_TERM_FIELDS,
  describeTermsChange,
  latestVersion,
  paramsFromTermsForm,
  publishPlanVersion,
  termsFormFromVersion,
} from "@/lib/billing-plans";
import {
  AUDIENCE_LABELS,
  PROTECTED_NOTE,
  RECOMMENDED_TERMS,
  confirmationLines,
  dateLabel,
  previewPriceChange,
  schedulePriceChange,
  scheduleDateError,
  startOfDayUtc,
  tomorrow,
  type PriceAudience,
  type PricePreview,
} from "@/lib/billing-pricing";

type Step = "edit" | "review";

/** Changing a plan's pricing: edit the terms, choose when and for whom, review exactly what would happen, then confirm. Nothing is saved before the last button. */
export function PricingChangeDialog({
  plan,
  onClose,
  onDone,
}: {
  plan: PlanRow;
  onClose: () => void;
  onDone: () => void;
}) {
  const latest = latestVersion(plan);
  const initial = useMemo(() => termsFormFromVersion(latest), [latest]);
  const wholesaler = plan.business_type === "wholesaler";
  const [values, setValues] = useState<Record<string, string>>(initial);
  const [when, setWhen] = useState<"now" | "later">("later");
  const [date, setDate] = useState(tomorrow());
  const [audience, setAudience] = useState<PriceAudience>("new_only");
  const [keep, setKeep] = useState(true);
  const [step, setStep] = useState<Step>("edit");
  const [preview, setPreview] = useState<PricePreview | null>(null);
  const [reason, setReason] = useState("");
  const [understood, setUnderstood] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const set = (k: string, v: string) => setValues((x) => ({ ...x, [k]: v }));
  const effectiveAudience: PriceAudience = when === "now" ? "new_only" : audience;
  const changes = describeTermsChange(initial, values, plan.business_type);

  const review = async () => {
    setError(null);
    if (changes.length === 0) return setError("Nothing has changed from the terms in force.");
    const { params, error: formError } = paramsFromTermsForm(values, plan.business_type, {
      currency: latest?.currency,
      entitlements: latest?.entitlements,
      metadata: latest?.metadata,
    });
    if (formError) return setError(formError);
    if (when === "later") {
      const dateProblem = scheduleDateError(date);
      if (dateProblem) return setError(dateProblem);
    }
    setBusy(true);
    try {
      setPreview(
        await previewPriceChange({
          planId: plan.id,
          params,
          effectiveFrom: when === "later" ? startOfDayUtc(date) : null,
          audience: effectiveAudience,
          keepOverrides: keep,
        }),
      );
      setUnderstood(false);
      setStep("review");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not preview the change.");
    } finally {
      setBusy(false);
    }
  };

  const confirm = async () => {
    if (!preview) return;
    const problem = reasonError(reason);
    if (problem) return setError(problem);
    if (!understood)
      return setError(
        "Tick the box to confirm you understand this changes what businesses are charged.",
      );
    setBusy(true);
    setError(null);
    try {
      const params = preview.proposed_terms as Record<string, unknown>;
      if (when === "now") {
        await publishPlanVersion(plan.id, params, reason.trim());
        toast.success(`${plan.name}: the new terms are in force for new subscribers.`);
      } else {
        await schedulePriceChange({
          planId: plan.id,
          params,
          effectiveFrom: startOfDayUtc(date),
          audience: effectiveAudience,
          keepOverrides: keep,
          expectedAffected:
            effectiveAudience === "new_and_existing" ? preview.existing.affected : null,
          reason: reason.trim(),
        });
        toast.success(
          `${plan.name}: the change is scheduled for ${dateLabel(startOfDayUtc(date))}.`,
        );
      }
      onDone();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not save the change.");
    } finally {
      setBusy(false);
    }
  };

  const lines = preview
    ? confirmationLines({
        preview,
        scheduled: when === "later",
        startsOn: when === "later" ? dateLabel(startOfDayUtc(date)) : null,
      })
    : [];

  return (
    <Dialog open onOpenChange={(o) => !o && !busy && onClose()}>
      <DialogContent
        className="max-h-[92vh] max-w-3xl overflow-y-auto"
        data-testid="pricing-dialog"
      >
        <DialogHeader>
          <DialogTitle>
            {plan.name}: {step === "edit" ? "change pricing" : "review the change"}
          </DialogTitle>
          <DialogDescription>
            {step === "edit"
              ? "A price change is always a new version. Choose the terms, when they start and who they reach, then review it before anything is saved."
              : "Check what will happen. Nothing has been saved yet."}
          </DialogDescription>
        </DialogHeader>

        {step === "edit" && (
          <div className="space-y-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="text-sm text-muted-foreground">
                In force now: {latest ? `version ${latest.version}` : "no version yet"}.
              </p>
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => setValues({ ...RECOMMENDED_TERMS[plan.business_type] })}
                data-testid="use-recommended"
              >
                Use the recommended starting terms
              </Button>
            </div>
            <div className="grid items-start gap-3 sm:grid-cols-2">
              {PLAN_TERM_FIELDS.filter((f) => wholesaler || !f.wholesalerOnly).map((f) => (
                <div key={f.key} className="grid gap-1">
                  <Label htmlFor={`pc-${f.key}`}>{f.label}</Label>
                  <Input
                    id={`pc-${f.key}`}
                    inputMode="decimal"
                    value={values[f.key] ?? ""}
                    onChange={(e) => set(f.key, e.target.value)}
                  />
                  {f.help && <p className="text-xs text-muted-foreground">{f.help}</p>}
                </div>
              ))}
            </div>
            {changes.length > 0 && (
              <ul className="space-y-0.5 text-sm" data-testid="pricing-edit-changes">
                {changes.map((c) => (
                  <li key={c}>{c}</li>
                ))}
              </ul>
            )}

            <fieldset className="space-y-2 rounded-md border p-3">
              <legend className="px-1 text-sm font-semibold">When does it start?</legend>
              <label className="flex items-start gap-2 text-sm">
                <input
                  type="radio"
                  name="when"
                  checked={when === "later"}
                  onChange={() => setWhen("later")}
                  className="mt-1"
                  data-testid="when-later"
                />
                <span>
                  <span className="font-medium">On a future date</span>
                  <span className="block text-xs text-muted-foreground">
                    Scheduled. Nothing changes before that day, and it can be cancelled until then.
                  </span>
                </span>
              </label>
              {when === "later" && (
                <div className="ml-6 grid max-w-xs gap-1">
                  <Label htmlFor="pc-date">Starts on (the earliest is tomorrow)</Label>
                  <Input
                    id="pc-date"
                    type="date"
                    min={tomorrow()}
                    value={date}
                    onChange={(e) => setDate(e.target.value)}
                  />
                </div>
              )}
              <label className="flex items-start gap-2 text-sm">
                <input
                  type="radio"
                  name="when"
                  checked={when === "now"}
                  onChange={() => setWhen("now")}
                  className="mt-1"
                  data-testid="when-now"
                />
                <span>
                  <span className="font-medium">Now, for new subscribers only</span>
                  <span className="block text-xs text-muted-foreground">
                    Takes effect at once for anyone who subscribes from now on. Existing businesses
                    are not changed.
                  </span>
                </span>
              </label>
            </fieldset>

            {when === "later" && (
              <fieldset className="space-y-2 rounded-md border p-3">
                <legend className="px-1 text-sm font-semibold">Who does it reach?</legend>
                {(Object.keys(AUDIENCE_LABELS) as PriceAudience[]).map((a) => (
                  <label key={a} className="flex items-start gap-2 text-sm">
                    <input
                      type="radio"
                      name="audience"
                      checked={audience === a}
                      onChange={() => setAudience(a)}
                      className="mt-1"
                      data-testid={`audience-${a}`}
                    />
                    <span>
                      <span className="font-medium">{AUDIENCE_LABELS[a]}</span>
                      <span className="block text-xs text-muted-foreground">
                        {a === "new_only"
                          ? "Businesses already on this plan keep their current terms until you move them."
                          : "Each existing business moves at the start of its own next billing cycle on or after that date, never earlier."}
                      </span>
                    </span>
                  </label>
                ))}
                {audience === "new_and_existing" && (
                  <label className="ml-6 flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={keep}
                      onChange={(e) => setKeep(e.target.checked)}
                      data-testid="keep-custom"
                    />
                    Keep each business's custom pricing (untick to replace it with the plan's new
                    terms)
                  </label>
                )}
              </fieldset>
            )}
          </div>
        )}

        {step === "review" && preview && (
          <div className="space-y-4" data-testid="pricing-review">
            <div className="space-y-1 rounded-md border p-3 text-sm">
              {lines.map((l) => (
                <p key={l}>{l}</p>
              ))}
            </div>
            {preview.warnings.length > 0 && (
              <ul className="space-y-1 text-sm" data-testid="pricing-warnings">
                {preview.warnings.map((w) => (
                  <li key={w} className="flex items-start gap-2">
                    <AlertTriangle
                      className="mt-0.5 h-4 w-4 shrink-0 text-warning"
                      aria-hidden="true"
                    />
                    {w}
                  </li>
                ))}
              </ul>
            )}
            {preview.existing.businesses.length > 0 && (
              <div className="overflow-x-auto rounded-md border" data-testid="pricing-affected">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Existing business</TableHead>
                      <TableHead className="text-right">Pays now</TableHead>
                      <TableHead className="text-right">Commission now</TableHead>
                      <TableHead>
                        {effectiveAudience === "new_and_existing" ? "Moves on" : "Moves"}
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {preview.existing.businesses.map((b) => (
                      <TableRow key={b.business_id}>
                        <TableCell className="font-medium">
                          {b.business_name}
                          {b.has_overrides && (
                            <span className="block text-xs text-muted-foreground">
                              custom pricing
                            </span>
                          )}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {formatGHS(b.current_amount)}
                        </TableCell>
                        <TableCell className="text-right tabular-nums">
                          {b.current_fee_pct}%
                        </TableCell>
                        <TableCell className="text-sm">
                          {effectiveAudience !== "new_and_existing" ? (
                            "Stays on its current terms"
                          ) : b.skip_reason ? (
                            <span className="text-muted-foreground">
                              Not moved: {b.skip_reason.toLowerCase()}
                            </span>
                          ) : (
                            dateLabel(b.change_from)
                          )}
                        </TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            )}
            <p className="text-xs text-muted-foreground">{PROTECTED_NOTE}</p>
            <div className="grid gap-1">
              <Label htmlFor="pc-reason">Reason (kept in the audit trail)</Label>
              <Textarea
                id="pc-reason"
                rows={2}
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
            </div>
            <label className="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                checked={understood}
                onChange={(e) => setUnderstood(e.target.checked)}
                className="mt-1"
                data-testid="understood"
              />
              I understand this changes what businesses are charged.
            </label>
          </div>
        )}

        {error && (
          <p className="text-sm text-destructive" role="alert" data-testid="pricing-error">
            {error}
          </p>
        )}
        <DialogFooter>
          {step === "review" ? (
            <>
              <Button variant="outline" onClick={() => setStep("edit")} disabled={busy}>
                Back
              </Button>
              <Button onClick={() => void confirm()} disabled={busy} data-testid="pricing-confirm">
                {busy ? "Saving…" : when === "now" ? "Publish now" : "Schedule the change"}
              </Button>
            </>
          ) : (
            <>
              <Button variant="outline" onClick={onClose} disabled={busy}>
                Cancel
              </Button>
              <Button
                onClick={() => void review()}
                disabled={busy}
                data-testid="pricing-review-btn"
              >
                {busy ? "Checking…" : "Review the change"}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
