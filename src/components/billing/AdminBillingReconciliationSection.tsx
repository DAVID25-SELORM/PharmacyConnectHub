import { useCallback, useEffect, useState } from "react";
import { CheckCircle2, RefreshCw, XCircle } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  RECONCILIATION_LABELS,
  fetchReconciliation,
  type ReconciliationReport,
} from "@/lib/billing";

/** The billing consistency checks, read-only. A finding means two records disagree: nothing here changes any money. */
export function AdminBillingReconciliationSection() {
  const [report, setReport] = useState<ReconciliationReport | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setReport(await fetchReconciliation());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not run the checks.");
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);

  if (error) {
    return (
      <Card className="border-destructive/40 p-4 text-sm text-destructive" role="alert">
        {error}
      </Card>
    );
  }
  if (!report) return <Skeleton className="h-40" />;
  return (
    <div className="space-y-4" data-testid="billing-reconciliation">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <Badge
          variant="outline"
          className={
            report.healthy
              ? "border-success/30 bg-success/15 text-success"
              : "border-destructive/30 bg-destructive/15 text-destructive"
          }
          data-testid="reconciliation-status"
        >
          {report.healthy ? "Everything agrees" : "Something needs attention"}
        </Badge>
        <Button variant="outline" size="sm" onClick={() => void load()} disabled={loading}>
          <RefreshCw
            className={`mr-1 h-4 w-4 ${loading ? "animate-spin" : ""}`}
            aria-hidden="true"
          />
          Run the checks again
        </Button>
      </div>
      <Card className="divide-y p-0">
        {report.checks.map((c) => (
          <div
            key={c.check}
            className="flex items-start gap-3 p-3 text-sm"
            data-testid="reconciliation-check"
          >
            {c.count === 0 ? (
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" aria-label="ok" />
            ) : (
              <XCircle
                className="mt-0.5 h-4 w-4 shrink-0 text-destructive"
                aria-label="needs attention"
              />
            )}
            <div className="min-w-0">
              <div className="font-medium">
                {RECONCILIATION_LABELS[c.check] ?? c.check}
                {c.count > 0 && <span className="ml-2 text-destructive">{c.count}</span>}
              </div>
              {c.count > 0 && (
                <pre className="mt-1 max-h-32 overflow-auto rounded bg-muted p-2 text-xs">
                  {JSON.stringify(c.details, null, 1)}
                </pre>
              )}
            </div>
          </div>
        ))}
      </Card>
      <p className="text-xs text-muted-foreground">
        Checked {new Date(report.checked_at).toLocaleString("en-GB")}.
      </p>
    </div>
  );
}
