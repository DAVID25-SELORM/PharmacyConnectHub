import { AlertCircle, ChevronRight } from "lucide-react";
import type { ReactNode } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  activityLabel,
  actorLabel,
  categoryLabel,
  summarizeDetails,
  type ActivityRow,
} from "@/lib/activity-log";
import { formatActivityTime } from "@/lib/activity-log";
import { timeAgo } from "@/lib/format";

/** Badge text carries the meaning (category + event); colour is only decoration. */
export function EventBadge({ activity }: { activity: string }) {
  return (
    <div className="flex flex-col items-start gap-1">
      <Badge variant="secondary" className="max-w-full whitespace-normal text-left font-medium">
        {activityLabel(activity)}
      </Badge>
      <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
        {categoryLabel(activity)}
      </span>
    </div>
  );
}

type Props = {
  rows: ActivityRow[];
  loading: boolean;
  error: boolean;
  onRetry: () => void;
  onOpen: (row: ActivityRow) => void;
  /** Rendered when there are no rows and the list is not filtered. */
  emptyState: ReactNode;
  /** Rendered instead of `emptyState` when a filter is active. */
  filteredEmptyState?: ReactNode;
  filtered?: boolean;
  skeletonRows?: number;
};

export function ActivityTable({
  rows,
  loading,
  error,
  onRetry,
  onOpen,
  emptyState,
  filteredEmptyState,
  filtered = false,
  skeletonRows = 6,
}: Props) {
  if (error) {
    return (
      <div
        role="alert"
        className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-8 text-center"
      >
        <AlertCircle className="h-6 w-6 text-warning" aria-hidden="true" />
        <p className="text-sm font-medium">We couldn&apos;t load recent activity.</p>
        <Button variant="outline" size="sm" onClick={onRetry}>
          Try again
        </Button>
      </div>
    );
  }

  if (loading && rows.length === 0) {
    return (
      <div className="space-y-2" role="status" aria-label="Loading activity">
        {Array.from({ length: skeletonRows }, (_, index) => (
          <Skeleton key={index} className="h-12 w-full" />
        ))}
      </div>
    );
  }

  if (rows.length === 0) {
    return <>{filtered && filteredEmptyState ? filteredEmptyState : emptyState}</>;
  }

  return (
    <div aria-busy={loading}>
      {/* Tablet and desktop */}
      <div className="hidden overflow-hidden rounded-xl border border-border md:block">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-border bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th scope="col" className="px-4 py-3 font-medium">
                Time
              </th>
              <th scope="col" className="px-4 py-3 font-medium">
                Event
              </th>
              <th scope="col" className="px-4 py-3 font-medium">
                Organization
              </th>
              <th scope="col" className="hidden px-4 py-3 font-medium lg:table-cell">
                Actor
              </th>
              <th scope="col" className="hidden px-4 py-3 font-medium xl:table-cell">
                Record
              </th>
              <th scope="col" className="hidden px-4 py-3 font-medium xl:table-cell">
                Details
              </th>
              <th scope="col" className="w-10 px-2 py-3">
                <span className="sr-only">Open details</span>
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((row) => (
              <tr key={row.id} className="align-top hover:bg-muted/30">
                <td className="whitespace-nowrap px-4 py-3">
                  <div>{formatActivityTime(row.created_at)}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {timeAgo(row.created_at)}
                  </div>
                </td>
                <td className="px-4 py-3">
                  <EventBadge activity={row.activity} />
                </td>
                <td className="px-4 py-3 font-medium">{row.organization ?? "Drugxone"}</td>
                <td
                  className="hidden max-w-[16rem] truncate px-4 py-3 text-muted-foreground lg:table-cell"
                  title={actorLabel(row.performed_by_email)}
                >
                  {actorLabel(row.performed_by_email)}
                </td>
                <td
                  className="hidden px-4 py-3 font-mono text-xs xl:table-cell"
                  title={row.record_label ?? row.record_type}
                >
                  {(row.record_label ?? row.record_type).slice(0, 24)}
                </td>
                <td className="hidden max-w-xs px-4 py-3 text-muted-foreground xl:table-cell">
                  {summarizeDetails(row.details) || "—"}
                </td>
                <td className="px-2 py-3 text-right">
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label={`View details: ${activityLabel(row.activity)}, ${row.organization ?? "Drugxone"}`}
                    onClick={() => onOpen(row)}
                  >
                    <ChevronRight className="h-4 w-4" aria-hidden="true" />
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Mobile: cards keep time, event, organization, actor and the detail action */}
      <ul className="space-y-2 md:hidden">
        {rows.map((row) => (
          <li key={row.id}>
            <button
              type="button"
              onClick={() => onOpen(row)}
              className="w-full rounded-xl border border-border p-3 text-left focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring"
            >
              <div className="flex items-start justify-between gap-2">
                <EventBadge activity={row.activity} />
                <span className="whitespace-nowrap text-xs text-muted-foreground">
                  {timeAgo(row.created_at)}
                </span>
              </div>
              <div className="mt-2 text-sm font-medium">{row.organization ?? "Drugxone"}</div>
              <div className="mt-0.5 truncate text-xs text-muted-foreground">
                {actorLabel(row.performed_by_email)} · {formatActivityTime(row.created_at)}
              </div>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
