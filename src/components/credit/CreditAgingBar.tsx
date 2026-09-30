import { formatGHS } from "@/lib/format";
import { AGING_BUCKET_LABELS, type CreditAging } from "@/lib/credit-ledger";

/** A simple proportional bar + legend for the standard AR/AP aging buckets (current / 1-30 /
 * 31-60 / 61-90 / 90+), shared by the wholesaler and pharmacy dashboards. */
export function CreditAgingBar({ aging }: { aging: CreditAging }) {
  const total = AGING_BUCKET_LABELS.reduce((sum, b) => sum + Number(aging[b.key] ?? 0), 0);
  const colors: Record<string, string> = {
    current: "bg-success",
    days_1_30: "bg-warning",
    days_31_60: "bg-accent",
    days_61_90: "bg-destructive/70",
    days_90_plus: "bg-destructive",
  };

  return (
    <div>
      {total > 0 && (
        <div className="flex h-2.5 w-full overflow-hidden rounded-full bg-muted">
          {AGING_BUCKET_LABELS.map((b) => {
            const value = Number(aging[b.key] ?? 0);
            if (value <= 0) return null;
            return (
              <div
                key={b.key}
                className={colors[b.key]}
                style={{ width: `${(value / total) * 100}%` }}
                title={`${b.label}: ${formatGHS(value)}`}
              />
            );
          })}
        </div>
      )}
      <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-5">
        {AGING_BUCKET_LABELS.map((b) => (
          <div key={b.key} className="rounded-lg border border-border p-2 text-xs">
            <div className="flex items-center gap-1.5 text-muted-foreground">
              <span className={`h-2 w-2 rounded-full ${colors[b.key]}`} aria-hidden="true" />
              {b.label}
            </div>
            <div className="mt-1 font-display text-sm font-bold">{formatGHS(aging[b.key] ?? 0)}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
