import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Search, X } from "lucide-react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { ActivityDetailSheet } from "@/components/admin/ActivityDetailSheet";
import { ActivityTable } from "@/components/admin/ActivityTable";
import { AdminNav } from "@/components/admin/AdminNav";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { supabase } from "@/integrations/supabase/client";
import {
  ACTIVITY_CATEGORIES,
  EMPTY_FILTERS,
  EXPORT_ROW_LIMIT,
  KNOWN_ACTIVITY_OPTIONS,
  activityFiltersToSearch,
  activityToCsv,
  buildActivityRpcArgs,
  filterKey,
  hasActiveFilters,
  paginate,
  parseActivitySearch,
  type ActivityCursor,
  type ActivityFilters,
  type ActivityRow,
} from "@/lib/activity-log";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const Route = createFileRoute("/admin/activity")({
  head: () => ({ meta: [{ title: "Activity Log - Drugxone" }] }),
  validateSearch: (search: Record<string, unknown>) => ({
    ...parseActivitySearch(search),
    eventId: typeof search.eventId === "string" && UUID.test(search.eventId) ? search.eventId : "",
  }),
  component: ActivityPage,
});

const selectClass =
  "h-10 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

function ActivityPage() {
  const navigate = useNavigate({ from: "/admin/activity" });
  const search = Route.useSearch();
  const { eventId, ...filters } = search as ActivityFilters & { eventId: string };

  const [rows, setRows] = useState<ActivityRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [orgOptions, setOrgOptions] = useState<string[]>([]);
  const requestId = useRef(0);

  // Text inputs are debounced before they reach the URL (and therefore the server).
  const [qInput, setQInput] = useState(filters.q);
  const [actorInput, setActorInput] = useState(filters.actor);
  const [orgInput, setOrgInput] = useState(filters.org);
  const debouncedQ = useDebouncedValue(qInput, 400);
  const debouncedActor = useDebouncedValue(actorInput, 400);
  const debouncedOrg = useDebouncedValue(orgInput, 400);

  const setFilters = useCallback(
    (patch: Partial<ActivityFilters>) => {
      const next = { ...filters, ...patch };
      void navigate({
        search: { ...activityFiltersToSearch(next), ...(eventId ? { eventId } : {}) } as never,
        replace: true,
      });
    },
    [eventId, filters, navigate],
  );

  useEffect(() => {
    const q = debouncedQ.trim();
    if (q !== filters.q && (q.length === 0 || q.length >= 2)) setFilters({ q });
  }, [debouncedQ]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const actor = debouncedActor.trim();
    if (actor !== filters.actor) setFilters({ actor });
  }, [debouncedActor]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const org = debouncedOrg.trim();
    if (org !== filters.org) setFilters({ org });
  }, [debouncedOrg]); // eslint-disable-line react-hooks/exhaustive-deps

  // Bounded organization autocomplete: at most 8 names, never the whole directory.
  useEffect(() => {
    const term = debouncedOrg.trim();
    if (term.length < 2) {
      setOrgOptions([]);
      return;
    }
    let cancelled = false;
    void supabase
      .from("businesses")
      .select("name")
      .ilike("name", `${term.replace(/[%_\\]/g, "\\$&")}%`)
      .order("name")
      .limit(8)
      .then(({ data }) => {
        if (!cancelled) setOrgOptions((data ?? []).map((row) => row.name as string));
      });
    return () => {
      cancelled = true;
    };
  }, [debouncedOrg]);

  // Pagination state is stored together with the filter set it belongs to. When the filters
  // change, the stored cursors are ignored immediately (same render), so a cursor created under
  // one filter set is never sent with another.
  const key = filterKey(filters as ActivityFilters);
  const [pager, setPager] = useState<{ key: string; cursors: ActivityCursor[]; index: number }>({
    key,
    cursors: [null],
    index: 0,
  });
  const current =
    pager.key === key ? pager : { key, cursors: [null] as ActivityCursor[], index: 0 };
  const pageIndex = current.index;
  const cursor = current.cursors[current.index] ?? null;

  const fetchPage = useCallback(async () => {
    const id = ++requestId.current;
    setLoading(true);
    setError(false);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error: rpcError } = await (supabase as any).rpc(
      "admin_list_activity",
      buildActivityRpcArgs(filters as ActivityFilters, cursor, filters.limit),
    );
    if (id !== requestId.current) return; // a newer request superseded this one

    if (rpcError) {
      setError(true);
      setLoading(false);
      return;
    }

    const {
      page,
      hasMore: more,
      nextCursor,
    } = paginate((data as ActivityRow[]) ?? [], filters.limit);
    setRows(page);
    setHasMore(more);
    setPager((previous) => {
      const base =
        previous.key === key ? previous : { key, cursors: [null] as ActivityCursor[], index: 0 };
      const cursors = base.cursors.slice(0, base.index + 1);
      if (nextCursor) cursors[base.index + 1] = nextCursor;
      return { ...base, cursors };
    });
    setLoading(false);
  }, [cursor, filters, key]);

  useEffect(() => {
    void fetchPage();
  }, [key, pageIndex]); // eslint-disable-line react-hooks/exhaustive-deps

  const clearFilters = () => {
    setQInput("");
    setActorInput("");
    setOrgInput("");
    void navigate({ search: { ...(eventId ? { eventId } : {}) } as never, replace: true });
  };

  const openRow = (row: ActivityRow) =>
    void navigate({
      search: { ...activityFiltersToSearch(filters as ActivityFilters), eventId: row.id } as never,
      replace: true,
    });
  const closeRow = () =>
    void navigate({
      search: activityFiltersToSearch(filters as ActivityFilters) as never,
      replace: true,
    });

  const exportCsv = async () => {
    setExporting(true);
    try {
      const collected: ActivityRow[] = [];
      let cursor: ActivityCursor = null;
      while (collected.length < EXPORT_ROW_LIMIT) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const { data, error: rpcError } = await (supabase as any).rpc(
          "admin_list_activity",
          buildActivityRpcArgs(filters as ActivityFilters, cursor, 200),
        );
        if (rpcError) throw rpcError;
        const { page, nextCursor } = paginate((data as ActivityRow[]) ?? [], 200);
        collected.push(...page);
        if (!nextCursor) break;
        cursor = nextCursor;
      }

      const blob = new Blob([activityToCsv(collected)], { type: "text/csv;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `drugxone-activity-${new Date().toISOString().slice(0, 10)}.csv`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success(
        collected.length >= EXPORT_ROW_LIMIT
          ? `Exported the newest ${EXPORT_ROW_LIMIT.toLocaleString()} matching events. Narrow the filters to export older ones.`
          : `Exported ${collected.length.toLocaleString()} events.`,
      );
    } catch {
      toast.error("We couldn't export the activity log. Please try again.");
    } finally {
      setExporting(false);
    }
  };

  const filtered = hasActiveFilters(filters as ActivityFilters);

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Activity log" isAdmin={true} />
      <AdminNav />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">Activity Log</h1>
            <p className="mt-1 text-muted-foreground">
              Search and review platform events across DrugXOne.
            </p>
          </div>
          <Button variant="outline" onClick={() => void exportCsv()} disabled={exporting}>
            <Download className="mr-2 h-4 w-4" aria-hidden="true" />
            {exporting ? "Exporting..." : "Export Activity"}
          </Button>
        </div>

        <Card className="mt-6 p-4">
          <form
            role="search"
            aria-label="Filter activity"
            className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
            onSubmit={(event) => event.preventDefault()}
          >
            <div className="relative sm:col-span-2">
              <Label htmlFor="activity-search" className="sr-only">
                Search activity
              </Label>
              <Search
                className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted-foreground"
                aria-hidden="true"
              />
              <Input
                id="activity-search"
                value={qInput}
                onChange={(event) => setQInput(event.target.value)}
                placeholder="Search organization, actor, record or event..."
                className="pl-9"
                autoComplete="off"
              />
            </div>

            <div>
              <Label htmlFor="activity-category" className="sr-only">
                Category
              </Label>
              <select
                id="activity-category"
                className={selectClass}
                value={filters.category}
                onChange={(event) =>
                  setFilters({ category: event.target.value as ActivityFilters["category"] })
                }
              >
                <option value="">All categories</option>
                {ACTIVITY_CATEGORIES.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <Label htmlFor="activity-event" className="sr-only">
                Event type
              </Label>
              <select
                id="activity-event"
                className={selectClass}
                value={filters.event}
                onChange={(event) => setFilters({ event: event.target.value })}
              >
                <option value="">All events</option>
                {KNOWN_ACTIVITY_OPTIONS.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <Label htmlFor="activity-range" className="sr-only">
                Date range
              </Label>
              <select
                id="activity-range"
                className={selectClass}
                value={filters.range}
                onChange={(event) =>
                  setFilters({ range: event.target.value as ActivityFilters["range"] })
                }
              >
                <option value="">Any time</option>
                <option value="today">Today</option>
                <option value="7d">Last 7 days</option>
                <option value="30d">Last 30 days</option>
                <option value="custom">Custom range</option>
              </select>
            </div>

            <div>
              <Label htmlFor="activity-org-type" className="sr-only">
                Organization type
              </Label>
              <select
                id="activity-org-type"
                className={selectClass}
                value={filters.orgType}
                onChange={(event) =>
                  setFilters({ orgType: event.target.value as ActivityFilters["orgType"] })
                }
              >
                <option value="">All organizations</option>
                <option value="pharmacy">Pharmacies</option>
                <option value="wholesaler">Wholesalers</option>
              </select>
            </div>

            <div>
              <Label htmlFor="activity-org" className="sr-only">
                Organization name
              </Label>
              <Input
                id="activity-org"
                list="activity-org-options"
                value={orgInput}
                onChange={(event) => setOrgInput(event.target.value)}
                placeholder="Organization name"
                autoComplete="off"
              />
              <datalist id="activity-org-options">
                {orgOptions.map((name) => (
                  <option key={name} value={name} />
                ))}
              </datalist>
            </div>

            <div>
              <Label htmlFor="activity-actor" className="sr-only">
                Actor
              </Label>
              <Input
                id="activity-actor"
                value={actorInput}
                onChange={(event) => setActorInput(event.target.value)}
                placeholder='Actor email or "system"'
                autoComplete="off"
              />
            </div>

            {filters.range === "custom" && (
              <>
                <div>
                  <Label htmlFor="activity-from" className="text-xs text-muted-foreground">
                    From
                  </Label>
                  <Input
                    id="activity-from"
                    type="date"
                    value={filters.from}
                    onChange={(event) => setFilters({ from: event.target.value })}
                  />
                </div>
                <div>
                  <Label htmlFor="activity-to" className="text-xs text-muted-foreground">
                    To
                  </Label>
                  <Input
                    id="activity-to"
                    type="date"
                    value={filters.to}
                    onChange={(event) => setFilters({ to: event.target.value })}
                  />
                </div>
              </>
            )}

            <div className="flex items-end gap-2">
              <div className="flex-1">
                <Label htmlFor="activity-limit" className="sr-only">
                  Rows per page
                </Label>
                <select
                  id="activity-limit"
                  className={selectClass}
                  value={filters.limit}
                  onChange={(event) =>
                    setFilters({ limit: Number(event.target.value) as ActivityFilters["limit"] })
                  }
                >
                  <option value={25}>25 per page</option>
                  <option value={50}>50 per page</option>
                  <option value={100}>100 per page</option>
                </select>
              </div>
              {filtered && (
                <Button type="button" variant="ghost" size="sm" onClick={clearFilters}>
                  <X className="mr-1 h-4 w-4" aria-hidden="true" />
                  Clear
                </Button>
              )}
            </div>
          </form>
        </Card>

        <div className="mt-6">
          <ActivityTable
            rows={rows}
            loading={loading}
            error={error}
            onRetry={() => void fetchPage()}
            onOpen={openRow}
            filtered={filtered}
            skeletonRows={8}
            emptyState={
              <div className="rounded-xl border border-dashed border-border p-10 text-center">
                <p className="font-medium">No activity yet</p>
                <p className="mt-1 text-sm text-muted-foreground">
                  Platform activity will appear here as businesses, orders and admin actions are
                  recorded.
                </p>
              </div>
            }
            filteredEmptyState={
              <div className="rounded-xl border border-dashed border-border p-10 text-center">
                <p className="font-medium">No activity matches your filters</p>
                <Button className="mt-3" variant="outline" size="sm" onClick={clearFilters}>
                  Clear filters
                </Button>
              </div>
            }
          />
        </div>

        {!error && (rows.length > 0 || pageIndex > 0) && (
          <nav aria-label="Activity pages" className="mt-4 flex items-center justify-between gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={pageIndex === 0 || loading}
              onClick={() => setPager({ ...current, index: Math.max(0, current.index - 1) })}
            >
              <ChevronLeft className="mr-1 h-4 w-4" aria-hidden="true" />
              Previous
            </Button>
            <span className="text-sm text-muted-foreground" aria-live="polite">
              Page {pageIndex + 1} · newest first
            </span>
            <Button
              variant="outline"
              size="sm"
              disabled={!hasMore || loading}
              onClick={() => setPager({ ...current, index: current.index + 1 })}
            >
              Next
              <ChevronRight className="ml-1 h-4 w-4" aria-hidden="true" />
            </Button>
          </nav>
        )}
      </main>

      <ActivityDetailSheet activityId={eventId || null} onClose={closeRow} />
    </div>
  );
}
