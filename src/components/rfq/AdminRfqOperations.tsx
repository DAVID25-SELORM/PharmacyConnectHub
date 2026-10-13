import { useState } from "react";
import { AlertTriangle } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { rfqCall } from "@/lib/enterprise-rfq";
import { rfqDate } from "@/lib/rfq-format";
import { RfqReasonDialog } from "./RfqReasonDialog";
import { RfqStatusBadge } from "./RfqStatusBadge";
import { TablePager } from "./TablePager";

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
    created_at?: string;
    failed_conversions: number;
  }[];
};

const PAGE = 25;
const MIN_REASON = 10;

const humanise = (key: string) => key.replace(/([A-Z])/g, " $1").replaceAll("_", " ");

/** Platform-wide RFQ figures, and audited access to one request's restricted commercial records. */
export function AdminRfqOperations() {
  const [report, setReport] = useState<Report | null>(null);
  const [page, setPage] = useState(0);
  const [error, setError] = useState("");
  const [asking, setAsking] = useState<Report["rows"][number] | null>(null);
  const [investigation, setInvestigation] = useState<{
    reference: string;
    data: Record<string, unknown>;
  } | null>(null);

  const load = async (next: number) => {
    try {
      setReport(
        await rfqCall<Report>("rfq_platform_report", { p_offset: next * PAGE, p_limit: PAGE }),
      );
      setPage(next);
      setError("");
    } catch (e) {
      setError((e as Error).message);
    }
  };

  const tiles: [label: string, value: number, alert?: boolean][] = report
    ? [
        ["Requests", report.rfqs],
        ["Pharmacies", report.pharmacies],
        ["Suppliers", report.suppliers],
        ["Quotations", report.quotes],
        ["Orders created", report.orders],
        ["Failed conversions", report.failed, report.failed > 0],
        ["Cancelled", report.cancelled],
      ]
    : [];
  const paged = report && {
    rows: [],
    page,
    pageCount: Math.max(1, Math.ceil(report.rfqs / PAGE)),
    from: report.rows.length ? page * PAGE + 1 : 0,
    to: page * PAGE + report.rows.length,
    total: report.rfqs,
  };

  return (
    <Card className="my-4">
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between sm:space-y-0">
        <div className="space-y-1.5">
          <CardTitle className="text-lg">RFQ operations</CardTitle>
          <CardDescription>
            Figures across the platform, and audited investigations. Opening a request&apos;s
            commercial records needs a specific reason, which is written to the audit log.
          </CardDescription>
        </div>
        <Button type="button" variant="outline" onClick={() => void load(report ? page : 0)}>
          {report ? "Refresh" : "Load operational report"}
        </Button>
      </CardHeader>
      <CardContent className="space-y-4">
        {error && (
          <p
            role="alert"
            className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive"
          >
            {error}
          </p>
        )}
        {report && (
          <>
            <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-7">
              {tiles.map(([label, value, alert]) => (
                <div
                  key={label}
                  className={`rounded-lg border p-3 ${alert ? "border-destructive/40 bg-destructive/5" : ""}`}
                >
                  <dt className="text-xs text-muted-foreground">{label}</dt>
                  <dd
                    className={`text-xl font-semibold tabular-nums ${alert ? "text-destructive" : ""}`}
                  >
                    {value.toLocaleString("en-GB")}
                  </dd>
                </div>
              ))}
            </dl>
            <div className="overflow-hidden rounded-lg border">
              <div className="overflow-x-auto">
                <Table className="min-w-[720px]">
                  <TableHeader>
                    <TableRow className="bg-muted/40 hover:bg-muted/40">
                      <TableHead className="w-36">Reference</TableHead>
                      <TableHead>Request</TableHead>
                      <TableHead className="w-40">Status</TableHead>
                      <TableHead className="w-32">Created</TableHead>
                      <TableHead className="w-40 text-right">Failed conversions</TableHead>
                      <TableHead className="w-40">
                        <span className="sr-only">Investigate</span>
                      </TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {report.rows.length === 0 ? (
                      <TableRow>
                        <TableCell
                          colSpan={6}
                          className="py-10 text-center text-sm text-muted-foreground"
                        >
                          No requests yet.
                        </TableCell>
                      </TableRow>
                    ) : (
                      report.rows.map((r) => (
                        <TableRow key={r.id}>
                          <TableCell className="font-mono text-xs text-muted-foreground">
                            {r.reference}
                          </TableCell>
                          <TableCell className="font-medium">{r.title}</TableCell>
                          <TableCell>
                            <RfqStatusBadge value={r.status} />
                          </TableCell>
                          <TableCell className="text-sm text-muted-foreground">
                            {r.created_at ? rfqDate(r.created_at) : "–"}
                          </TableCell>
                          <TableCell className="text-right">
                            {r.failed_conversions > 0 ? (
                              <Badge variant="destructive" className="gap-1 tabular-nums">
                                <AlertTriangle className="h-3 w-3" /> {r.failed_conversions}
                              </Badge>
                            ) : (
                              <span className="tabular-nums text-muted-foreground">0</span>
                            )}
                          </TableCell>
                          <TableCell className="text-right">
                            <Button
                              type="button"
                              variant="outline"
                              size="sm"
                              onClick={() => setAsking(r)}
                            >
                              Investigate…
                            </Button>
                          </TableCell>
                        </TableRow>
                      ))
                    )}
                  </TableBody>
                </Table>
              </div>
              {paged && (
                <TablePager
                  paged={paged}
                  size={PAGE}
                  onSize={() => {}}
                  onPage={(next) => void load(next)}
                  showSize={false}
                />
              )}
            </div>
          </>
        )}
      </CardContent>

      {asking && (
        <RfqReasonDialog
          title={`Investigate ${asking.reference}`}
          description="This opens restricted commercial records. The reason is recorded in the audit log with your name."
          label="Reason for the investigation"
          placeholder="Be specific: what you are looking into and why"
          confirmLabel="Open investigation"
          minLength={MIN_REASON}
          busy={false}
          onClose={() => setAsking(null)}
          onSubmit={async (reason) => {
            try {
              const data = await rfqCall<Record<string, unknown>>("investigate_rfq", {
                p_rfq_id: asking.id,
                p_reason: reason,
              });
              setInvestigation({ reference: asking.reference, data });
              setError("");
              return true;
            } catch (e) {
              setError((e as Error).message);
              return false;
            }
          }}
        />
      )}

      {investigation && (
        <Dialog open onOpenChange={(open) => !open && setInvestigation(null)}>
          <DialogContent className="max-h-[90vh] max-w-3xl overflow-y-auto">
            <DialogHeader>
              <DialogTitle>Restricted commercial investigation</DialogTitle>
              <DialogDescription>
                {investigation.reference}. This access has been recorded in the audit log.
              </DialogDescription>
            </DialogHeader>
            <div className="space-y-2">
              {Object.entries(investigation.data).map(([key, value]) => (
                <details
                  key={key}
                  className="rounded-lg border px-3 py-2"
                  open={!Array.isArray(value)}
                >
                  <summary className="cursor-pointer text-sm font-medium capitalize">
                    {humanise(key)}
                    {Array.isArray(value) && (
                      <span className="ml-2 font-normal text-muted-foreground">
                        ({value.length})
                      </span>
                    )}
                  </summary>
                  <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-all rounded bg-muted/50 p-2 text-xs">
                    {JSON.stringify(value, null, 2)}
                  </pre>
                </details>
              ))}
            </div>
            <DialogFooter>
              <Button type="button" onClick={() => setInvestigation(null)}>
                Close
              </Button>
            </DialogFooter>
          </DialogContent>
        </Dialog>
      )}
    </Card>
  );
}
