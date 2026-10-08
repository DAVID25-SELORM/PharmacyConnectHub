import { useEffect, useState } from "react";
import {
  ChevronDown,
  ChevronRight,
  CircleDot,
  ClipboardList,
  MessageSquare,
  PackagePlus,
} from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import { actorText, entryKind, groupTimelineByDay, type TimelineEntry } from "@/lib/order-timeline";
import { formatReportDate } from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

const timeOf = (iso: string) =>
  new Date(iso).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

const KIND_ICON = {
  placed: PackagePlus,
  status: CircleDot,
  event: MessageSquare,
} as const;

/** Everything that has happened to an order, oldest first: placement, each status change, and every recorded
 * event (amendments, approvals, shortages, deliveries). Loaded only when opened. */
export function OrderActivityTimeline({
  orderId,
  refreshKey,
}: {
  orderId: string;
  refreshKey?: number;
}) {
  const [open, setOpen] = useState(false);
  const [entries, setEntries] = useState<TimelineEntry[] | null>(null);
  const [failed, setFailed] = useState(false);
  const [loading, setLoading] = useState(false);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setLoading(true);
    setFailed(false);
    void db
      .rpc("order_timeline", { p_order_id: orderId })
      .then(({ data, error }: { data: TimelineEntry[] | null; error: unknown }) => {
        if (cancelled) return;
        setLoading(false);
        if (error) return setFailed(true);
        setEntries(data ?? []);
      });
    return () => {
      cancelled = true;
    };
  }, [open, orderId, refreshKey, reload]);

  const days = entries ? groupTimelineByDay(entries) : [];

  return (
    <section className="mt-4 rounded-xl border border-border" aria-label="Order activity">
      <button
        type="button"
        className="flex w-full items-center justify-between gap-2 p-3 text-left text-sm font-medium"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="flex items-center gap-2">
          <ClipboardList className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
          Activity
        </span>
        {open ? (
          <ChevronDown className="h-4 w-4" aria-hidden="true" />
        ) : (
          <ChevronRight className="h-4 w-4" aria-hidden="true" />
        )}
      </button>
      {open && (
        <div className="border-t border-border p-3" aria-live="polite">
          {loading && !entries ? (
            <div className="space-y-2" role="status" aria-label="Loading activity">
              <Skeleton className="h-5 w-2/3" />
              <Skeleton className="h-5 w-1/2" />
            </div>
          ) : failed ? (
            <p role="alert" className="text-sm">
              We couldn&apos;t load this order&apos;s activity.{" "}
              <button
                type="button"
                className="text-primary underline"
                onClick={() => setReload((value) => value + 1)}
              >
                Try again
              </button>
            </p>
          ) : days.length === 0 ? (
            <p className="text-sm text-muted-foreground">No activity yet.</p>
          ) : (
            <ol className="space-y-4">
              {days.map((day) => (
                <li key={day.day}>
                  <div className="text-xs font-medium uppercase tracking-wider text-muted-foreground">
                    {formatReportDate(day.entries[0].at)}
                  </div>
                  <ul className="mt-2 space-y-2 border-l border-border pl-4">
                    {day.entries.map((entry, index) => {
                      const Icon =
                        KIND_ICON[entryKind(entry) as keyof typeof KIND_ICON] ?? MessageSquare;
                      return (
                        <li key={`${entry.at}-${index}`} className="relative text-sm">
                          <Icon
                            className="absolute -left-[1.55rem] top-0.5 h-3.5 w-3.5 rounded-full bg-background text-muted-foreground"
                            aria-hidden="true"
                          />
                          <div className="font-medium">{entry.summary}</div>
                          <div className="text-xs text-muted-foreground">
                            {timeOf(entry.at)} · {actorText(entry)}
                          </div>
                        </li>
                      );
                    })}
                  </ul>
                </li>
              ))}
            </ol>
          )}
        </div>
      )}
    </section>
  );
}
