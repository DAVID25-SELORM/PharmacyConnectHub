import { useCallback, useEffect, useState } from "react";
import { Search } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useSession, type Business } from "@/hooks/use-session";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { rfqCall, RFQ_STATES, label, type EnterpriseRfq } from "@/lib/enterprise-rfq";
import { EnterpriseRfqEditor } from "./EnterpriseRfqEditor";
import { EnterpriseRfqDetail } from "./EnterpriseRfqDetail";
import { PharmacyRfqDetail } from "./PharmacyRfqDetail";
import { RfqListTable, RFQ_LIST_PAGE } from "./RfqListTable";
import { RfqProcurementReport } from "./RfqProcurementReport";
import { WholesalerRfqDetail } from "./WholesalerRfqDetail";

const selectClass =
  "h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring";

export function EnterpriseRfqWorkspace() {
  const { business } = useSession();
  return business ? <RfqWorkspace key={business.id} business={business} /> : null;
}

function RfqWorkspace({ business }: { business: Business }) {
  const [rows, setRows] = useState<EnterpriseRfq[]>([]);
  const [count, setCount] = useState(0);
  const [page, setPage] = useState(0);
  const [q, setQ] = useState("");
  const query = useDebouncedValue(q, 250);
  const [status, setStatus] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [sort, setSort] = useState("newest");
  const [detail, setDetail] = useState<string | null>(null);
  const [legacy, setLegacy] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ initial?: EnterpriseRfq; repeat?: boolean } | null>(
    null,
  );
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [report, setReport] = useState<Record<string, unknown> | null>(null);
  const buyer = business?.type === "pharmacy";
  const manage = ["owner", "manager"].includes(business?.staff_role ?? "");
  const process = ["owner", "manager", "cashier", ...(!buyer ? ["warehouse"] : [])].includes(
    business?.staff_role ?? "",
  );
  const load = useCallback(async () => {
    if (!business) return;
    setLoading(true);
    setError("");
    try {
      const data = await rfqCall<{ rows: EnterpriseRfq[]; count: number }>("list_enterprise_rfqs", {
        p_business_id: business.id,
        p_filters: { q: query, status, from, to, sort },
        p_offset: page * RFQ_LIST_PAGE,
        p_limit: RFQ_LIST_PAGE,
      });
      setRows(data.rows);
      setCount(data.count);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, [business, query, status, from, to, sort, page]);
  useEffect(() => {
    void load();
  }, [load]);
  useEffect(() => {
    if (business)
      void rfqCall("refresh_rfq_reminders", { p_business_id: business.id }).catch((e) =>
        setError(e.message),
      );
  }, [business]);
  useEffect(() => {
    const selected = new URLSearchParams(window.location.search).get("rfq");
    if (selected && /^[0-9a-f-]{36}$/i.test(selected)) setDetail(selected);
  }, []);
  if (!business) return null;
  const browsing = !editing && !detail;
  const filtered = Boolean(q || status || from || to);
  const filter =
    <T,>(set: (value: T) => void) =>
    (value: T) => {
      set(value);
      setPage(0);
    };
  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="RFQ procurement" showNav />
      <main className="mx-auto max-w-7xl space-y-6 px-4 py-6 sm:px-6">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="space-y-1">
            <h1 className="text-2xl font-bold tracking-tight">
              {buyer ? "Requests for quotation" : "Supplier RFQ inbox"}
            </h1>
            <p className="max-w-2xl text-sm text-muted-foreground">
              Private quotations, supplier confirmation and orders through your existing purchasing
              workflow.
            </p>
            {manage && (
              <Link to="/settings" className="text-sm text-primary underline">
                Manage document branding in Business Settings
              </Link>
            )}
          </div>
          <div className="flex gap-2">
            {buyer && process && (
              <Button
                type="button"
                onClick={() => {
                  setDetail(null);
                  setEditing({});
                }}
              >
                New RFQ
              </Button>
            )}
            <Button
              type="button"
              variant="outline"
              onClick={async () => {
                try {
                  setReport(
                    await rfqCall<Record<string, unknown>>("rfq_procurement_report", {
                      p_business_id: business.id,
                      p_from: from || null,
                      p_to: to || null,
                    }),
                  );
                } catch (e) {
                  setError((e as Error).message);
                }
              }}
            >
              Procurement report
            </Button>
          </div>
        </div>

        {report && (
          <RfqProcurementReport
            report={report}
            buyer={buyer}
            businessId={business.id}
            onClose={() => setReport(null)}
            onError={setError}
          />
        )}

        {editing ? (
          <EnterpriseRfqEditor
            key={`${editing.initial?.id ?? "new"}:${editing.repeat}`}
            businessId={business.id}
            initial={editing.initial}
            repeat={editing.repeat}
            onCancel={() => setEditing(null)}
            onSaved={(id) => {
              setEditing(null);
              setDetail(id);
              void load();
            }}
          />
        ) : detail ? (
          <EnterpriseRfqDetail
            key={detail}
            id={detail}
            businessId={business.id}
            canManage={manage}
            canProcess={process}
            onClose={() => setDetail(null)}
            onEdit={(initial, repeat) => {
              setDetail(null);
              setEditing({ initial, repeat });
            }}
            onChanged={() => void load()}
          />
        ) : (
          <>
            <div className="grid gap-3 rounded-lg border bg-card p-3 sm:grid-cols-2 lg:grid-cols-[minmax(0,2fr)_1fr_1fr_1fr_1fr]">
              <div className="relative">
                <Search className="pointer-events-none absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
                <Input
                  aria-label="Search RFQs"
                  placeholder="Search reference or title"
                  className="pl-8"
                  value={q}
                  onChange={(e) => filter(setQ)(e.target.value)}
                />
              </div>
              <select
                aria-label="RFQ status"
                className={selectClass}
                value={status}
                onChange={(e) => filter(setStatus)(e.target.value)}
              >
                <option value="">All statuses</option>
                {RFQ_STATES.map((s) => (
                  <option key={s} value={s}>
                    {label(s)}
                  </option>
                ))}
              </select>
              <Input
                aria-label="From date"
                type="date"
                value={from}
                onChange={(e) => filter(setFrom)(e.target.value)}
              />
              <Input
                aria-label="To date"
                type="date"
                value={to}
                onChange={(e) => filter(setTo)(e.target.value)}
              />
              <select
                aria-label="Sort RFQs"
                className={selectClass}
                value={sort}
                onChange={(e) => setSort(e.target.value)}
              >
                <option value="newest">Newest first</option>
                <option value="deadline">Deadline first</option>
              </select>
            </div>
            {filtered && (
              <div className="-mt-3 flex items-center gap-2 text-xs text-muted-foreground">
                <span className="tabular-nums">
                  {count} matching request{count === 1 ? "" : "s"}
                </span>
                <Button
                  type="button"
                  variant="link"
                  size="sm"
                  className="h-auto p-0 text-xs"
                  onClick={() => {
                    setQ("");
                    setStatus("");
                    setFrom("");
                    setTo("");
                    setPage(0);
                  }}
                >
                  Clear filters
                </Button>
              </div>
            )}
            {error && (
              <p
                role="alert"
                className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
              >
                {error}
              </p>
            )}
            <RfqListTable
              rows={rows}
              loading={loading}
              count={count}
              page={page}
              onPage={setPage}
              onOpen={(r) => (r.enterprise ? setDetail(r.id) : setLegacy(r.id))}
            />
          </>
        )}
        {!browsing && error && (
          <p
            role="alert"
            className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          >
            {error}
          </p>
        )}
        {buyer ? (
          <PharmacyRfqDetail
            rfqId={legacy}
            open={!!legacy}
            canAward={manage}
            canCancel={process}
            onOpenChange={(open) => !open && setLegacy(null)}
            onChanged={() => void load()}
          />
        ) : (
          <WholesalerRfqDetail
            rfqId={legacy}
            wholesalerId={business.id}
            canQuote={process}
            open={!!legacy}
            onOpenChange={(open) => !open && setLegacy(null)}
            onChanged={() => void load()}
          />
        )}
      </main>
    </div>
  );
}
