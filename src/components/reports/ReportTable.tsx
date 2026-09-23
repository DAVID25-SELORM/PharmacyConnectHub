import { AlertCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";

export type ReportColumn<T> = {
  key: string;
  header: string;
  align?: "left" | "right";
  hideOnMobile?: boolean;
  render: (row: T) => React.ReactNode;
};

/**
 * Generic report table: aggregate reports pass every row they have (already bounded to the
 * number of businesses/products in range, never the number of orders); record-level reports
 * pass one page at a time.
 */
export function ReportTable<T extends { id?: string } | Record<string, unknown>>({
  columns,
  rows,
  rowKey,
  loading,
  error,
  onRetry,
  emptyMessage = "No results for this range and these filters.",
  skeletonRows = 6,
}: {
  columns: ReportColumn<T>[];
  rows: T[];
  rowKey: (row: T, index: number) => string;
  loading: boolean;
  error: boolean;
  onRetry: () => void;
  emptyMessage?: string;
  skeletonRows?: number;
}) {
  if (error) {
    return (
      <div
        role="alert"
        className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-8 text-center"
      >
        <AlertCircle className="h-6 w-6 text-warning" aria-hidden="true" />
        <p className="text-sm font-medium">We couldn&apos;t load this report.</p>
        <Button variant="outline" size="sm" onClick={onRetry}>
          Try again
        </Button>
      </div>
    );
  }

  if (loading && rows.length === 0) {
    return (
      <div className="space-y-2" role="status" aria-label="Loading report">
        {Array.from({ length: skeletonRows }, (_, index) => (
          <Skeleton key={index} className="h-11 w-full" />
        ))}
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="rounded-xl border border-dashed border-border p-8 text-center text-sm text-muted-foreground">
        {emptyMessage}
      </div>
    );
  }

  return (
    <div className="overflow-x-auto rounded-xl border border-border" aria-busy={loading}>
      <table className="w-full min-w-[640px] text-left text-sm">
        <thead className="border-b border-border bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
          <tr>
            {columns.map((col) => (
              <th
                key={col.key}
                scope="col"
                className={`px-4 py-3 font-medium ${col.align === "right" ? "text-right" : ""} ${col.hideOnMobile ? "hidden sm:table-cell" : ""}`}
              >
                {col.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {rows.map((row, index) => (
            <tr key={rowKey(row, index)}>
              {columns.map((col) => (
                <td
                  key={col.key}
                  className={`px-4 py-3 ${col.align === "right" ? "text-right tabular-nums" : ""} ${col.hideOnMobile ? "hidden sm:table-cell" : ""}`}
                >
                  {col.render(row)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
