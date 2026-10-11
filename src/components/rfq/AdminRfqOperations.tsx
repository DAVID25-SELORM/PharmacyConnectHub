import { useState } from "react";
import { rfqCall } from "@/lib/enterprise-rfq";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
type Report = {
  rfqs: number;
  pharmacies: number;
  suppliers: number;
  quotes: number;
  orders: number;
  failed: number;
  cancelled: number;
  rows: {
    id: string;
    reference: string;
    title: string;
    status: string;
    failed_conversions: number;
  }[];
};
export function AdminRfqOperations() {
  const [report, setReport] = useState<Report | null>(null);
  const [page, setPage] = useState(0);
  const [reason, setReason] = useState("");
  const [error, setError] = useState("");
  const [investigation, setInvestigation] = useState<unknown>(null);
  const load = async (next: number) => {
    try {
      setReport(await rfqCall("rfq_platform_report", { p_offset: next * 25, p_limit: 25 }));
      setPage(next);
      setError("");
    } catch (e) {
      setError((e as Error).message);
    }
  };
  return (
    <details className="my-4 rounded border p-4">
      <summary className="font-semibold">RFQ operations and audited investigations</summary>
      <Button variant="outline" onClick={() => void load(0)}>
        Load operational report
      </Button>
      {report && (
        <>
          <p>
            {report.rfqs} RFQs · {report.pharmacies} pharmacies · {report.suppliers} suppliers ·{" "}
            {report.quotes} quotes · {report.orders} orders · {report.failed} failed conversions ·{" "}
            {report.cancelled} cancellations
          </p>
          <label className="block">
            Investigation reason (recorded in the audit log)
            <Input value={reason} onChange={(e) => setReason(e.target.value)} />
          </label>
          {report.rows.map((r) => (
            <div
              key={r.id}
              className="flex flex-wrap items-center justify-between gap-2 border-t py-2"
            >
              <span>
                {r.reference}: {r.title} · {r.status} · {r.failed_conversions} failed conversions
              </span>
              <Button
                variant="outline"
                disabled={reason.trim().length < 10}
                onClick={async () => {
                  try {
                    setInvestigation(
                      await rfqCall("investigate_rfq", { p_rfq_id: r.id, p_reason: reason }),
                    );
                    setError("");
                  } catch (e) {
                    setError((e as Error).message);
                  }
                }}
              >
                Open audited investigation
              </Button>
            </div>
          ))}
          <div className="flex gap-2">
            <Button variant="outline" disabled={!page} onClick={() => void load(page - 1)}>
              Previous RFQs
            </Button>
            <Button
              variant="outline"
              disabled={report.rows.length < 25}
              onClick={() => void load(page + 1)}
            >
              Next RFQs
            </Button>
          </div>
        </>
      )}
      {error && <p role="alert">{error}</p>}
      {investigation != null && (
        <div>
          <p className="font-semibold">Restricted commercial investigation</p>
          <pre className="max-h-96 overflow-auto whitespace-pre-wrap break-all text-xs">
            {JSON.stringify(investigation, null, 2)}
          </pre>
          <Button variant="ghost" onClick={() => setInvestigation(null)}>
            Close investigation
          </Button>
        </div>
      )}
    </details>
  );
}
