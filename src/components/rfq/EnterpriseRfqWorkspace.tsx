import { useCallback, useEffect, useState } from "react";
import { useSession, type Business } from "@/hooks/use-session";
import { DashboardHeader } from "@/components/DashboardShell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { rfqCall, RFQ_STATES, label, type EnterpriseRfq } from "@/lib/enterprise-rfq";
import { EnterpriseRfqEditor } from "./EnterpriseRfqEditor";
import { EnterpriseRfqDetail } from "./EnterpriseRfqDetail";
import { PharmacyRfqDetail } from "./PharmacyRfqDetail";
import { WholesalerRfqDetail } from "./WholesalerRfqDetail";
import { DocumentBrandingSettings } from "@/components/documents/DocumentBrandingSettings";
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
  const [insights, setInsights] = useState<Record<string, unknown>[] | null>(null);
  const [insightPage, setInsightPage] = useState(0);
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
        p_offset: page * 25,
        p_limit: 25,
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
  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="RFQ procurement" showNav />
      <main className="mx-auto max-w-7xl space-y-5 px-4 py-6 sm:px-6">
        <div className="flex flex-wrap justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold">
              {buyer ? "Requests for quotation" : "Supplier RFQ inbox"}
            </h1>
            <p className="text-sm text-muted-foreground">
              Private quotations, supplier confirmation and orders through your existing purchasing
              workflow.
            </p>
          </div>
          <div className="flex gap-2">
            {buyer && process && (
              <Button
                onClick={() => {
                  setDetail(null);
                  setEditing({});
                }}
              >
                New RFQ
              </Button>
            )}
            <Button
              variant="outline"
              onClick={async () => {
                try {
                  setReport(
                    await rfqCall("rfq_procurement_report", {
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
        {manage && (
          <details className="rounded border p-4">
            <summary className="cursor-pointer font-medium">Document branding settings</summary>
            <DocumentBrandingSettings businessId={business.id} businessName={business.name} />
          </details>
        )}
        {report && (
          <section className="rounded border p-4">
            <h2 className="font-semibold">Procurement report for selected dates</h2>
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {Object.entries(report)
                .filter(
                  ([key]) => !["suppliers", "declineReasons", "requestedProducts"].includes(key),
                )
                .map(([key, value]) => (
                  <div key={key}>
                    <p className="text-xs text-muted-foreground">
                      {key.replace(/([A-Z])/g, " $1")}
                    </p>
                    <p className="text-xl">{value == null ? "Not available" : String(value)}</p>
                  </div>
                ))}
            </div>
            <p className="mt-2 text-xs">
              Order values are GHS. Fulfilment follows linked order status. No estimated savings are
              asserted without an approved baseline.
            </p>
            <Button variant="ghost" onClick={() => setReport(null)}>
              Close report
            </Button>
            {Array.isArray(report.suppliers) && (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr>
                      <th>Supplier</th>
                      <th>Orders</th>
                      <th>Delivered</th>
                      <th>Cancelled</th>
                      <th>Spend GHS</th>
                    </tr>
                  </thead>
                  <tbody>
                    {(
                      report.suppliers as {
                        wholesaler_id: string;
                        name: string;
                        orders: number;
                        delivered: number;
                        cancelled: number;
                        spend: number;
                      }[]
                    ).map((s) => (
                      <tr key={s.wholesaler_id}>
                        <td>{s.name}</td>
                        <td>{s.orders}</td>
                        <td>{s.delivered}</td>
                        <td>{s.cancelled}</td>
                        <td>{s.spend}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            {Array.isArray(report.declineReasons) && report.declineReasons.length > 0 && (
              <div className="mt-3">
                <h3 className="font-medium">Invitation decline reasons</h3>
                {(report.declineReasons as { reason: string; count: number }[]).map((x) => (
                  <p key={x.reason} className="text-sm">
                    {x.reason}: {x.count}
                  </p>
                ))}
              </div>
            )}
            {buyer && Array.isArray(report.requestedProducts) && (
              <div className="mt-3">
                <h3 className="font-medium">Most requested medicines</h3>
                {(
                  report.requestedProducts as {
                    master_product_id: string | null;
                    product_name: string;
                    requests: number;
                    requested: number;
                  }[]
                ).map((x, i) => (
                  <p key={`${x.master_product_id ?? x.product_name}:${i}`} className="text-sm">
                    {x.product_name}: {x.requests} requests, {x.requested} units
                  </p>
                ))}
              </div>
            )}
            {buyer && (
              <div className="mt-3 space-y-2">
                <Button
                  variant="outline"
                  onClick={async () => {
                    try {
                      setInsights(
                        await rfqCall("rfq_price_insights", {
                          p_pharmacy_id: business.id,
                          p_offset: insightPage * 25,
                        }),
                      );
                    } catch (e) {
                      setError((e as Error).message);
                    }
                  }}
                >
                  Load medicine price history page {insightPage + 1}
                </Button>
                {insights?.map((i, index) => (
                  <div key={index} className="rounded border p-2 text-sm">
                    <strong>{String(i.medicine)}</strong>
                    <p>
                      {String(i.requests)} requests · Previous unit price:{" "}
                      {String(i.historical_unit_price ?? "unavailable")} GHS · Award unit price:{" "}
                      {String(i.awarded_unit_price ?? "unavailable")} GHS
                    </p>
                    <p>
                      Historical price difference:{" "}
                      {String(i.historical_price_difference_ghs ?? "not comparable")} GHS
                    </p>
                    <p className="text-xs">{String(i.baseline)}</p>
                  </div>
                ))}
                <Button
                  variant="outline"
                  disabled={!insightPage}
                  onClick={() => setInsightPage((p) => p - 1)}
                >
                  Previous history page
                </Button>
                <Button variant="outline" onClick={() => setInsightPage((p) => p + 1)}>
                  Next history page
                </Button>
              </div>
            )}
          </section>
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
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              <Input
                aria-label="Search RFQs"
                placeholder="Search reference or title"
                value={q}
                onChange={(e) => {
                  setQ(e.target.value);
                  setPage(0);
                }}
              />
              <select
                aria-label="RFQ status"
                className="rounded border p-2"
                value={status}
                onChange={(e) => {
                  setStatus(e.target.value);
                  setPage(0);
                }}
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
                onChange={(e) => {
                  setFrom(e.target.value);
                  setPage(0);
                }}
              />
              <Input
                aria-label="To date"
                type="date"
                value={to}
                onChange={(e) => {
                  setTo(e.target.value);
                  setPage(0);
                }}
              />
              <select
                aria-label="Sort RFQs"
                className="rounded border p-2"
                value={sort}
                onChange={(e) => setSort(e.target.value)}
              >
                <option value="newest">Newest first</option>
                <option value="deadline">Deadline first</option>
              </select>
            </div>
            {error && (
              <p role="alert" className="text-destructive">
                {error}
              </p>
            )}
            {loading ? (
              <p role="status">Loading RFQs…</p>
            ) : rows.length === 0 ? (
              <p className="rounded border p-8">No matching RFQs.</p>
            ) : (
              rows.map((r) => (
                <button
                  key={r.id}
                  className="block w-full rounded-xl border p-4 text-left hover:border-primary"
                  onClick={() => (r.enterprise ? setDetail(r.id) : setLegacy(r.id))}
                >
                  <div className="flex flex-wrap justify-between gap-2">
                    <strong>{r.title}</strong>
                    <span>{label(r.display_status ?? r.status)}</span>
                  </div>
                  <p className="text-sm text-muted-foreground">
                    {r.reference} · {r.quote_count ?? 0} quotations ·{" "}
                    {r.response_deadline
                      ? new Date(r.response_deadline).toLocaleDateString()
                      : "No deadline"}
                    {!r.enterprise ? " · Legacy RFQ" : ""}
                  </p>
                </button>
              ))
            )}
            <div className="flex items-center gap-3">
              <Button
                variant="outline"
                disabled={!page || loading}
                onClick={() => setPage((p) => p - 1)}
              >
                Previous
              </Button>
              <span>
                {count} results · Page {page + 1}
              </span>
              <Button
                variant="outline"
                disabled={(page + 1) * 25 >= count || loading}
                onClick={() => setPage((p) => p + 1)}
              >
                Next
              </Button>
            </div>
          </>
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
