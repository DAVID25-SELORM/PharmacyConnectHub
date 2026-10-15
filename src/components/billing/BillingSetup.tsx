import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { ChevronDown } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  fetchPlans,
  fetchReconciliation,
  type PlanRow,
  type ReconciliationReport,
} from "@/lib/billing";
import { fetchReadiness, type Readiness } from "@/lib/billing-rollout";
import {
  buildSetupStatus,
  fetchShadowReview,
  type SetupStage,
  type StageKey,
  type ShadowReviewResult,
} from "@/lib/billing-setup";
import { InvoiceSettingsCard } from "./AdminBillingInvoicesSection";
import { ActivationCard, PilotTable } from "./AdminBillingRolloutSection";
import { SetupDashboard, ItemIcon, STAGE_STATUS_TEXT, STAGE_STATUS_TONE } from "./SetupDashboard";
import { SetupPricing } from "./SetupPricing";
import { SetupShadow } from "./SetupShadow";

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

/** The guided Billing Setup: four stages from pricing to the first live pilot, with everything that stops activation in one place. */
export function BillingSetup() {
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [plans, setPlans] = useState<PlanRow[] | null>(null);
  const [reconciliation, setReconciliation] = useState<ReconciliationReport | null>(null);
  const [reconciliationError, setReconciliationError] = useState<string | null>(null);
  const [review, setReview] = useState<ShadowReviewResult | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);
  const [reloadToken, setReloadToken] = useState(0);
  const [open, setOpen] = useState<Set<StageKey> | null>(null);

  const runChecks = useCallback(async () => {
    setChecking(true);
    const [recon, rev] = await Promise.allSettled([fetchReconciliation(), fetchShadowReview()]);
    if (recon.status === "fulfilled") {
      setReconciliation(recon.value);
      setReconciliationError(null);
    } else {
      setReconciliationError(errText(recon.reason, "Could not run the consistency checks."));
    }
    setReview(
      rev.status === "fulfilled"
        ? rev.value
        : { available: false, reason: errText(rev.reason, "Could not run the recalculation.") },
    );
    setChecking(false);
  }, []);

  const load = useCallback(async () => {
    try {
      const [r, p] = await Promise.all([fetchReadiness(), fetchPlans()]);
      setReadiness(r);
      setPlans(p);
      setLoadError(null);
    } catch (e) {
      setLoadError(errText(e, "Could not load the billing setup."));
    }
    setReloadToken((n) => n + 1);
    await runChecks();
  }, [runChecks]);

  useEffect(() => {
    void load();
  }, [load]);

  const status = useMemo(
    () =>
      readiness && plans ? buildSetupStatus({ readiness, plans, reconciliation, review }) : null,
    [readiness, plans, reconciliation, review],
  );

  // Open the stage that has something to do the first time the page knows which that is.
  useEffect(() => {
    if (status && open === null) setOpen(new Set(status.current ? [status.current] : []));
  }, [status, open]);

  const toggle = (key: StageKey, force?: boolean) =>
    setOpen((cur) => {
      const next = new Set(cur ?? []);
      const want = force ?? !next.has(key);
      if (want) next.add(key);
      else next.delete(key);
      return next;
    });
  const openStage = (key: StageKey) => {
    toggle(key, true);
    window.setTimeout(
      () =>
        document
          .getElementById(`stage-${key}`)
          ?.scrollIntoView?.({ behavior: "smooth", block: "start" }),
      50,
    );
  };

  if (loadError && !readiness)
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {loadError}
      </Card>
    );
  if (!readiness || !plans || !status) return <Skeleton className="h-60" />;

  const body = (stage: SetupStage): ReactNode => {
    switch (stage.key) {
      case "configure":
        return (
          <div className="space-y-6">
            <div>
              <h4 className="mb-2 font-semibold">Wholesalers</h4>
              <SetupPricing type="wholesaler" plans={plans} onSaved={() => void load()} />
            </div>
            <details className="rounded-md border p-3">
              <summary className="cursor-pointer font-semibold">
                Pharmacies (only if they will be billed)
              </summary>
              <div className="mt-3">
                <SetupPricing type="pharmacy" plans={plans} onSaved={() => void load()} />
              </div>
            </details>
          </div>
        );
      case "invoices":
        return <InvoiceSettingsCard onSaved={() => void load()} />;
      case "shadow":
        return (
          <SetupShadow
            readiness={readiness}
            reconciliation={reconciliation}
            reconciliationError={reconciliationError}
            review={review}
            checking={checking}
            reloadToken={reloadToken}
            onRecheck={() => void runChecks()}
            onChanged={() => void load()}
          />
        );
      case "activate":
        return readiness.platform_mode === "active" ? (
          <PilotTable onChanged={() => void load()} />
        ) : status.canActivate ? (
          <ActivationCard
            readiness={readiness}
            onDone={() => void load()}
            extraBlockers={status.blockers}
            lockHoldBack
            compact
          />
        ) : (
          <p className="text-sm text-muted-foreground" data-testid="activation-locked">
            Locked. Real billing can be switched on only when stages 1 to 3 are complete. Finish
            what is listed under “What prevents activation” above.
          </p>
        );
    }
  };

  return (
    <div className="space-y-6" data-testid="billing-setup">
      <SetupDashboard
        status={status}
        platformMode={readiness.platform_mode}
        onOpenStage={openStage}
      />
      <div className="space-y-4">
        {status.stages.map((stage) => {
          const isOpen = open?.has(stage.key) ?? false;
          return (
            <Card
              key={stage.key}
              id={`stage-${stage.key}`}
              className="scroll-mt-4 p-0"
              data-testid={`stage-${stage.key}`}
            >
              <button
                type="button"
                className="flex w-full items-start gap-3 p-4 text-left"
                onClick={() => toggle(stage.key)}
                aria-expanded={isOpen}
              >
                <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full border text-sm font-semibold">
                  {stage.number}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="flex flex-wrap items-center gap-2">
                    <span className="font-semibold">{stage.title}</span>
                    <span
                      className={`rounded-full border px-2 py-0.5 text-[11px] font-medium ${STAGE_STATUS_TONE[stage.status]}`}
                    >
                      {STAGE_STATUS_TEXT[stage.status]}
                    </span>
                  </span>
                  <span className="block text-sm text-muted-foreground">{stage.summary}</span>
                </span>
                <ChevronDown
                  className={`mt-1 h-4 w-4 shrink-0 transition-transform ${isOpen ? "rotate-180" : ""}`}
                  aria-hidden="true"
                />
              </button>
              {isOpen && (
                <div className="space-y-4 border-t p-4">
                  <ul className="space-y-2 text-sm" data-testid={`items-${stage.key}`}>
                    {stage.items.map((i) => (
                      <li key={i.key} className="flex items-start gap-2">
                        <ItemIcon status={i.status} />
                        <div>
                          <span className="font-medium">{i.label}</span>
                          {i.blocking ? (
                            <span className="ml-2 text-xs text-muted-foreground">required</span>
                          ) : (
                            <span className="ml-2 text-xs text-muted-foreground">advice</span>
                          )}
                          {i.detail && (
                            <div className="text-xs text-muted-foreground">{i.detail}</div>
                          )}
                        </div>
                      </li>
                    ))}
                  </ul>
                  {body(stage)}
                </div>
              )}
            </Card>
          );
        })}
      </div>
    </div>
  );
}
