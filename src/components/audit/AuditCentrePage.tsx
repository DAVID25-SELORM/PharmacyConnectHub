import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Download, Search, ShieldAlert, X } from "lucide-react";
import { toast } from "sonner";
import { DashboardHeader } from "@/components/DashboardShell";
import { AuditLogDetailSheet } from "@/components/audit/AuditLogDetailSheet";
import { AuditLogTable } from "@/components/audit/AuditLogTable";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import {
  AUDIT_EXPORT_ROW_LIMIT,
  RECORD_TYPE_OPTIONS,
  auditFilterKey,
  auditLogToCsv,
  buildAuditRpcArgs,
  hasActiveAuditFilters,
  paginate,
  type AuditCursor,
  type AuditFilters,
  type AuditLogRow,
} from "@/lib/audit-centre";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

const selectClass =
  "h-10 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

const CAN_VIEW_ROLES = new Set(["owner", "manager", "accountant"]);

export function AuditCentrePage({
  filters,
  onFiltersChange,
}: {
  filters: AuditFilters;
  /** Replaces the URL search with exactly this set (only non-default values are written). */
  onFiltersChange: (filters: AuditFilters) => void;
}) {
  const { business } = useSession();

  const [rows, setRows] = useState<AuditLogRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [detailRow, setDetailRow] = useState<AuditLogRow | null>(null);
  const requestId = useRef(0);

  const [qInput, setQInput] = useState(filters.q);
  const debouncedQ = useDebouncedValue(qInput, 400);

  const setFilters = useCallback(
    (patch: Partial<AuditFilters>) => {
      onFiltersChange({ ...filters, ...patch });
    },
    [filters, onFiltersChange],
  );

  useEffect(() => {
    const q = debouncedQ.trim();
    if (q !== filters.q && (q.length === 0 || q.length >= 2)) setFilters({ q });
  }, [debouncedQ]); // eslint-disable-line react-hooks/exhaustive-deps

  const key = auditFilterKey(filters);
  const [pager, setPager] = useState<{ key: string; cursors: AuditCursor[]; index: number }>({
    key,
    cursors: [null],
    index: 0,
  });
  const current = pager.key === key ? pager : { key, cursors: [null] as AuditCursor[], index: 0 };
  const pageIndex = current.index;
  const cursor = current.cursors[current.index] ?? null;

  const canView = Boolean(business && CAN_VIEW_ROLES.has(business.staff_role));

  const fetchPage = useCallback(async () => {
    if (!business || !canView) return;
    const id = ++requestId.current;
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await db.rpc(
      "list_audit_log",
      buildAuditRpcArgs(business.id, filters, cursor, filters.limit),
    );
    if (id !== requestId.current) return;

    if (rpcError) {
      setError(true);
      setLoading(false);
      return;
    }

    const { page, hasMore: more, nextCursor } = paginate((data as AuditLogRow[]) ?? [], filters.limit);
    setRows(page);
    setHasMore(more);
    setPager((previous) => {
      const base = previous.key === key ? previous : { key, cursors: [null] as AuditCursor[], index: 0 };
      const cursors = base.cursors.slice(0, base.index + 1);
      if (nextCursor) cursors[base.index + 1] = nextCursor;
      return { ...base, cursors };
    });
    setLoading(false);
  }, [business, canView, cursor, filters, key]);

  useEffect(() => {
    void fetchPage();
  }, [key, pageIndex]); // eslint-disable-line react-hooks/exhaustive-deps

  const clearFilters = () => {
    setQInput("");
    onFiltersChange({ ...filters, q: "", recordType: "", range: "", from: "", to: "" });
  };

  const exportCsv = async () => {
    if (!business) return;
    setExporting(true);
    try {
      const collected: AuditLogRow[] = [];
      let cur: AuditCursor = null;
      while (collected.length < AUDIT_EXPORT_ROW_LIMIT) {
        const { data, error: rpcError } = await db.rpc(
          "list_audit_log",
          buildAuditRpcArgs(business.id, filters, cur, 200),
        );
        if (rpcError) throw rpcError;
        const { page, nextCursor } = paginate((data as AuditLogRow[]) ?? [], 200);
        collected.push(...page);
        if (!nextCursor) break;
        cur = nextCursor;
      }

      const blob = new Blob([auditLogToCsv(collected)], { type: "text/csv;charset=utf-8" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `drugxone-audit-log-${new Date().toISOString().slice(0, 10)}.csv`;
      link.click();
      URL.revokeObjectURL(url);
      toast.success(
        collected.length >= AUDIT_EXPORT_ROW_LIMIT
          ? `Exported the newest ${AUDIT_EXPORT_ROW_LIMIT.toLocaleString()} matching events. Narrow the filters to export older ones.`
          : `Exported ${collected.length.toLocaleString()} events.`,
      );
    } catch {
      toast.error("We couldn't export the audit log. Please try again.");
    } finally {
      setExporting(false);
    }
  };

  const filtered = hasActiveAuditFilters(filters);

  if (!business) return null;

  if (!canView) {
    return (
      <div className="min-h-screen bg-background">
        <DashboardHeader subtitle="Audit log" showNav={true} />
        <main className="mx-auto max-w-3xl px-4 py-16 sm:px-6 lg:px-8">
          <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-10 text-center">
            <ShieldAlert className="h-8 w-8 text-muted-foreground" aria-hidden="true" />
            <p className="font-medium">You don&apos;t have access to the audit log</p>
            <p className="max-w-sm text-sm text-muted-foreground">
              Only the owner, a manager, or an accountant for {business.name} can view it.
            </p>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Audit log" showNav={true} />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">Audit log</h1>
            <p className="mt-1 text-muted-foreground">
              A record of financially sensitive actions for {business.name}: RFQs, credit ledger
              entries, and catalog imports.
            </p>
          </div>
          <Button variant="outline" onClick={() => void exportCsv()} disabled={exporting}>
            <Download className="mr-2 h-4 w-4" aria-hidden="true" />
            {exporting ? "Exporting..." : "Export"}
          </Button>
        </div>

        <Card className="mt-6 p-4">
          <form
            role="search"
            aria-label="Filter audit log"
            className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
            onSubmit={(event) => event.preventDefault()}
          >
            <div className="relative sm:col-span-2">
              <Label htmlFor="audit-search" className="sr-only">
                Search audit log
              </Label>
              <Search
                className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted-foreground"
                aria-hidden="true"
              />
              <Input
                id="audit-search"
                value={qInput}
                onChange={(event) => setQInput(event.target.value)}
                placeholder="Search event or record..."
                className="pl-9"
                autoComplete="off"
              />
            </div>

            <div>
              <Label htmlFor="audit-record-type" className="sr-only">
                Record type
              </Label>
              <select
                id="audit-record-type"
                className={selectClass}
                value={filters.recordType}
                onChange={(event) => setFilters({ recordType: event.target.value })}
              >
                <option value="">All record types</option>
                {RECORD_TYPE_OPTIONS.map((item) => (
                  <option key={item.value} value={item.value}>
                    {item.label}
                  </option>
                ))}
              </select>
            </div>

            <div>
              <Label htmlFor="audit-range" className="sr-only">
                Date range
              </Label>
              <select
                id="audit-range"
                className={selectClass}
                value={filters.range}
                onChange={(event) => setFilters({ range: event.target.value as AuditFilters["range"] })}
              >
                <option value="">Any time</option>
                <option value="today">Today</option>
                <option value="7d">Last 7 days</option>
                <option value="30d">Last 30 days</option>
                <option value="custom">Custom range</option>
              </select>
            </div>

            {filters.range === "custom" && (
              <>
                <div>
                  <Label htmlFor="audit-from" className="text-xs text-muted-foreground">
                    From
                  </Label>
                  <Input
                    id="audit-from"
                    type="date"
                    value={filters.from}
                    onChange={(event) => setFilters({ from: event.target.value })}
                  />
                </div>
                <div>
                  <Label htmlFor="audit-to" className="text-xs text-muted-foreground">
                    To
                  </Label>
                  <Input
                    id="audit-to"
                    type="date"
                    value={filters.to}
                    onChange={(event) => setFilters({ to: event.target.value })}
                  />
                </div>
              </>
            )}

            <div className="flex items-end gap-2">
              <div className="flex-1">
                <Label htmlFor="audit-limit" className="sr-only">
                  Rows per page
                </Label>
                <select
                  id="audit-limit"
                  className={selectClass}
                  value={filters.limit}
                  onChange={(event) => setFilters({ limit: Number(event.target.value) as AuditFilters["limit"] })}
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
          <AuditLogTable
            rows={rows}
            loading={loading}
            error={error}
            onRetry={() => void fetchPage()}
            onOpen={setDetailRow}
            filtered={filtered}
            skeletonRows={8}
            emptyState={
              <div className="rounded-xl border border-dashed border-border p-10 text-center">
                <p className="font-medium">No audit events yet</p>
                <p className="mt-1 text-sm text-muted-foreground">
                  RFQ, credit ledger, and import activity will appear here as they happen.
                </p>
              </div>
            }
            filteredEmptyState={
              <div className="rounded-xl border border-dashed border-border p-10 text-center">
                <p className="font-medium">No events match your filters</p>
                <Button className="mt-3" variant="outline" size="sm" onClick={clearFilters}>
                  Clear filters
                </Button>
              </div>
            }
          />
        </div>

        {!error && (rows.length > 0 || pageIndex > 0) && (
          <nav aria-label="Audit log pages" className="mt-4 flex items-center justify-between gap-2">
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

      <AuditLogDetailSheet row={detailRow} onClose={() => setDetailRow(null)} />
    </div>
  );
}
