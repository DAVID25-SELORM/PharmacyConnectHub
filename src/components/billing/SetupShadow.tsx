import { useEffect, useState } from "react";
import { CheckCircle2, RefreshCw, XCircle } from "lucide-react";
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
import {
  fetchAdminBillingOrganizations,
  type OrganizationRow,
  type ReconciliationReport,
} from "@/lib/billing";
import type { Readiness } from "@/lib/billing-rollout";
import {
  SHADOW_DAYS_REQUIRED,
  checksHeadline,
  reconciliationProblems,
  type ShadowReviewResult,
} from "@/lib/billing-setup";
import { ActionDialog, type Action } from "./BillingControls";
import { platformSwitchAction, runNowAction } from "./PlatformModeCard";
import { StartSubscriptionDialog } from "./StartSubscriptionDialog";

const errText = (e: unknown, fallback: string) => (e instanceof Error ? e.message : fallback);

function Tile({ label, value, hint }: { label: string; value: string; hint?: string }) {
  return (
    <div className="rounded-lg border p-3">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div className="text-xl font-semibold tabular-nums">{value}</div>
      {hint && <div className="text-xs text-muted-foreground">{hint}</div>}
    </div>
  );
}

/** Stage 3: start the shadow test, add businesses to it, and watch what billing would have charged. Nothing here charges anyone. */
export function SetupShadow({
  readiness,
  reconciliation,
  reconciliationError,
  review,
  checking,
  reloadToken,
  onRecheck,
  onChanged,
}: {
  readiness: Readiness;
  reconciliation: ReconciliationReport | null;
  reconciliationError: string | null;
  review: ShadowReviewResult | null;
  checking: boolean;
  reloadToken: number;
  onRecheck: () => void;
  onChanged: () => void;
}) {
  const [action, setAction] = useState<Action | null>(null);
  const [adding, setAdding] = useState(false);
  const mode = readiness.platform_mode;
  const days = readiness.shadow.days;
  const pct = Math.min(100, Math.round((days / SHADOW_DAYS_REQUIRED) * 100));

  return (
    <div className="space-y-5" data-testid="setup-shadow">
      <div className="flex flex-wrap items-center gap-2">
        {mode === "disabled" ? (
          <Button
            onClick={() => setAction(platformSwitchAction(mode, "shadow"))}
            data-testid="start-shadow"
          >
            Start the shadow test
          </Button>
        ) : (
          <>
            <Badge variant="outline" data-testid="shadow-state">
              {mode === "active" ? "Real billing is on" : "Shadow test running"}
            </Badge>
            <Button variant="outline" onClick={() => setAdding(true)} data-testid="add-to-test">
              Add a business to the test
            </Button>
            <Button
              variant="outline"
              onClick={() => setAction(runNowAction())}
              data-testid="setup-run-now"
            >
              Run billing now
            </Button>
            {mode === "shadow" && (
              <Button
                variant="ghost"
                onClick={() => setAction(platformSwitchAction(mode, "disabled"))}
              >
                Stop the test
              </Button>
            )}
          </>
        )}
      </div>

      {mode !== "disabled" && (
        <div className="space-y-3">
          <div className="space-y-1">
            <div className="flex items-center justify-between text-sm">
              <span className="font-medium" data-testid="shadow-day">
                {readiness.shadow.since
                  ? `Day ${Math.min(days, SHADOW_DAYS_REQUIRED)} of ${SHADOW_DAYS_REQUIRED}`
                  : "Waiting for the first assessment"}
              </span>
              <span className="text-muted-foreground">{pct}%</span>
            </div>
            <div
              className="h-2 overflow-hidden rounded-full bg-muted"
              role="progressbar"
              aria-valuenow={pct}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-label="Shadow test progress"
            >
              <div className="h-full rounded-full bg-primary" style={{ width: `${pct}%` }} />
            </div>
          </div>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Tile label="Orders assessed" value={String(readiness.shadow.orders_assessed)} />
            <Tile
              label="Businesses with orders assessed"
              value={String(readiness.shadow.businesses)}
            />
            <Tile
              label="Would have been charged"
              value={formatGHS(readiness.shadow.estimated_revenue)}
              hint="Fees and subscriptions. Not charged."
            />
            <Tile
              label="Last billing run"
              value={
                readiness.checks.find((c) => c.key === "scheduler")?.ok ? "Running" : "Stopped"
              }
              hint={readiness.checks.find((c) => c.key === "scheduler")?.detail}
            />
          </div>
        </div>
      )}

      <ShadowChecks
        reconciliation={reconciliation}
        reconciliationError={reconciliationError}
        review={review}
        checking={checking}
        onRecheck={onRecheck}
      />
      {mode !== "disabled" && <ShadowResults reloadToken={reloadToken} />}

      <ActionDialog
        action={action}
        onClose={() => setAction(null)}
        onDone={() => {
          setAction(null);
          onChanged();
        }}
      />
      <StartSubscriptionDialog
        open={adding}
        onClose={() => setAdding(false)}
        onDone={() => {
          setAdding(false);
          onChanged();
        }}
      />
    </div>
  );
}

/** The automatic checks: every consistency check, and every shadow fee worked out again. A disagreement is shown with both figures. */
export function ShadowChecks({
  reconciliation,
  reconciliationError,
  review,
  checking,
  onRecheck,
}: {
  reconciliation: ReconciliationReport | null;
  reconciliationError: string | null;
  review: ShadowReviewResult | null;
  checking: boolean;
  onRecheck: () => void;
}) {
  const headline = checksHeadline(reconciliation, review);
  const problems = reconciliationProblems(reconciliation);
  const reviewData = review && review.available ? review.review : null;
  const reviewIssues = reviewData ? reviewData.checks.filter((c) => c.count > 0) : [];
  return (
    <Card className="space-y-3 p-4" data-testid="shadow-checks">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h4 className="font-semibold">Automatic checks</h4>
          <p
            className={`flex items-center gap-1.5 text-sm ${
              headline.tone === "good"
                ? "text-success"
                : headline.tone === "bad"
                  ? "text-destructive"
                  : "text-muted-foreground"
            }`}
            data-testid="checks-headline"
          >
            {headline.tone === "good" && <CheckCircle2 className="h-4 w-4" aria-hidden="true" />}
            {headline.tone === "bad" && <XCircle className="h-4 w-4" aria-hidden="true" />}
            {headline.text}
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={onRecheck} disabled={checking}>
          <RefreshCw
            className={`mr-1 h-4 w-4 ${checking ? "animate-spin" : ""}`}
            aria-hidden="true"
          />
          Run the checks again
        </Button>
      </div>

      {reconciliationError && (
        <p className="text-sm text-destructive" role="alert">
          {reconciliationError}
        </p>
      )}

      {problems.length > 0 && (
        <ul className="space-y-2 text-sm" data-testid="reconciliation-problems">
          {problems.map((p) => (
            <li key={p.label} className="flex items-start gap-2">
              <XCircle
                className={`mt-0.5 h-4 w-4 shrink-0 ${
                  p.severity === "critical" ? "text-destructive" : "text-warning"
                }`}
                aria-hidden="true"
              />
              <div className="min-w-0">
                <span className="font-medium">{p.label}</span>
                <span className="ml-2 tabular-nums text-destructive">{p.count}</span>
                {p.severity === "warning" && (
                  <span className="ml-2 text-xs text-muted-foreground">advice</span>
                )}
                <details className="text-xs text-muted-foreground">
                  <summary className="cursor-pointer">Technical details</summary>
                  <pre className="mt-1 max-h-32 overflow-auto rounded bg-muted p-2">
                    {JSON.stringify(p.details, null, 1)}
                  </pre>
                </details>
              </div>
            </li>
          ))}
        </ul>
      )}

      {review && !review.available && (
        <p className="text-sm text-muted-foreground" data-testid="review-unavailable">
          The independent recalculation of shadow fees is not available yet. {review.reason} It
          needs one database update, and nothing else depends on it.
        </p>
      )}

      {reviewData && (
        <div className="space-y-2" data-testid="review-summary">
          <p className="text-sm text-muted-foreground">
            {reviewData.recomputed} shadow fees were worked out again from the order value and the
            plan terms. Recorded total {formatGHS(reviewData.recorded_fee_total)}, recalculated{" "}
            {formatGHS(reviewData.recalculated_fee_total)}.
          </p>
          {reviewIssues.length > 0 && (
            <ul className="space-y-1 text-sm">
              {reviewIssues.map((c) => (
                <li key={c.key} className="flex items-start gap-2">
                  <XCircle
                    className={`mt-0.5 h-4 w-4 shrink-0 ${
                      c.severity === "critical" ? "text-destructive" : "text-warning"
                    }`}
                    aria-hidden="true"
                  />
                  <span>
                    {c.label}: <span className="tabular-nums text-destructive">{c.count}</span>{" "}
                    {c.count === 1 ? "difference" : "differences"}
                    {c.severity === "warning" && (
                      <span className="ml-2 text-xs text-muted-foreground">advice</span>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          )}
          {reviewData.rows.length > 0 && (
            <div className="overflow-x-auto rounded-md border" data-testid="review-rows">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Order</TableHead>
                    <TableHead>Business</TableHead>
                    <TableHead className="text-right">Recorded</TableHead>
                    <TableHead className="text-right">Recalculated</TableHead>
                    <TableHead className="text-right">Difference</TableHead>
                    <TableHead>What is wrong</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {reviewData.rows.map((r) => (
                    <TableRow key={`${r.check}-${r.order_id}`}>
                      <TableCell className="font-mono text-xs">{r.order_number}</TableCell>
                      <TableCell>{r.business_name}</TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatGHS(r.recorded)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums">
                        {formatGHS(r.recalculated)}
                      </TableCell>
                      <TableCell className="text-right tabular-nums text-destructive">
                        {formatGHS(r.difference)}
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">{r.note}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </div>
      )}
      {checking && !reconciliation && <Skeleton className="h-10" />}
    </Card>
  );
}

/** What shadow billing calculated for each business so far: no arithmetic is needed to read it. */
export function ShadowResults({ reloadToken }: { reloadToken: number }) {
  const [rows, setRows] = useState<OrganizationRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    fetchAdminBillingOrganizations({ flavor: "shadow", limit: 50, offset: 0 })
      .then((r) => {
        if (!cancelled) {
          setRows(r.rows);
          setError(null);
        }
      })
      .catch((e) => {
        if (!cancelled) setError(errText(e, "Could not load the shadow results."));
      });
    return () => {
      cancelled = true;
    };
  }, [reloadToken]);

  return (
    <Card className="space-y-3 p-4" data-testid="shadow-results">
      <div>
        <h4 className="font-semibold">What billing calculated for each business</h4>
        <p className="text-xs text-muted-foreground">
          Worked out automatically from real orders. These are estimates: nobody has been charged.
        </p>
      </div>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {!rows && !error && <Skeleton className="h-20" />}
      {rows && rows.length === 0 && (
        <p className="text-sm text-muted-foreground">
          No business is in the test yet. Use “Add a business to the test”.
        </p>
      )}
      {rows && rows.length > 0 && (
        <div className="overflow-x-auto rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Business</TableHead>
                <TableHead>Plan</TableHead>
                <TableHead className="text-right">Orders (free / charged)</TableHead>
                <TableHead className="text-right">Fees</TableHead>
                <TableHead className="text-right">Subscription</TableHead>
                <TableHead className="text-right">Would be charged</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.business_id} data-testid="shadow-result-row">
                  <TableCell className="font-medium">
                    {r.name}
                    <span className="block text-xs font-normal capitalize text-muted-foreground">
                      {r.type}
                    </span>
                  </TableCell>
                  <TableCell>{r.plan_name ?? r.plan_code ?? "–"}</TableCell>
                  <TableCell className="text-right tabular-nums">
                    {r.free_onboarding_orders + r.free_monthly_orders} / {r.chargeable_orders}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatGHS(r.transaction_fees_amount)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {formatGHS(r.subscription_amount)}
                  </TableCell>
                  <TableCell className="text-right tabular-nums font-medium">
                    {formatGHS(r.amount_due)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </Card>
  );
}
