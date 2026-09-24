import { useCallback, useEffect, useState } from "react";
import { Download, Printer } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import { downloadCsv, formatGHSCell, formatReportDate } from "@/lib/reports";
import {
  lineDescription,
  statementPrintHtml,
  statementRange,
  statementToCsv,
  type Statement,
} from "@/lib/statement";

function isoDate(date: Date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

/** Statement of account between one wholesaler and one pharmacy, shared by both sides. */
export function StatementView({
  wholesalerId,
  pharmacyId,
}: {
  wholesalerId: string;
  pharmacyId: string;
}) {
  const [fromDate, setFromDate] = useState(() => {
    const start = new Date();
    start.setDate(1);
    return isoDate(start);
  });
  const [toDate, setToDate] = useState(() => isoDate(new Date()));
  const [applied, setApplied] = useState({ from: fromDate, to: toDate });
  const [statement, setStatement] = useState<Statement | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  const load = useCallback(async () => {
    const range = statementRange(applied.from, applied.to);
    if (!range) {
      setLoading(false);
      setStatement(null);
      return;
    }
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await (supabase as any).rpc("customer_statement", {
      p_wholesaler_id: wholesalerId,
      p_pharmacy_id: pharmacyId,
      p_from: range.from,
      p_to: range.to,
    });
    if (rpcError || !data) {
      setError(true);
      setStatement(null);
    } else {
      setStatement(data as Statement);
    }
    setLoading(false);
  }, [wholesalerId, pharmacyId, applied]);

  const apply = () => {
    if (!statementRange(fromDate, toDate)) return toast.error("Choose a valid date range.");
    setApplied({ from: fromDate, to: toDate });
  };

  useEffect(() => {
    void load();
  }, [load]);

  const print = () => {
    if (!statement) return;
    const win = window.open("", "_blank");
    if (!win) return toast.error("Allow pop-ups to print the statement.");
    win.document.open();
    win.document.write(statementPrintHtml(statement));
    win.document.close();
  };

  const exportCsv = () => {
    if (!statement) return;
    downloadCsv(
      `drugxone-statement-${statement.pharmacy.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}-${applied.from}-to-${applied.to}.csv`,
      statementToCsv(statement),
    );
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <label className="text-sm">
          <span className="mb-1 block text-muted-foreground">From</span>
          <Input
            type="date"
            value={fromDate}
            max={toDate}
            onChange={(event) => setFromDate(event.target.value)}
          />
        </label>
        <label className="text-sm">
          <span className="mb-1 block text-muted-foreground">To</span>
          <Input
            type="date"
            value={toDate}
            min={fromDate}
            onChange={(event) => setToDate(event.target.value)}
          />
        </label>
        <Button onClick={apply} disabled={loading}>
          Apply
        </Button>
        <div className="ml-auto flex gap-2">
          <Button variant="outline" size="sm" onClick={exportCsv} disabled={!statement}>
            <Download className="mr-1 h-4 w-4" aria-hidden="true" />
            CSV
          </Button>
          <Button variant="outline" size="sm" onClick={print} disabled={!statement}>
            <Printer className="mr-1 h-4 w-4" aria-hidden="true" />
            Print
          </Button>
        </div>
      </div>

      {loading ? (
        <div className="space-y-2" role="status" aria-label="Loading statement">
          <Skeleton className="h-16 w-full" />
          <Skeleton className="h-32 w-full" />
        </div>
      ) : error ? (
        <div
          role="alert"
          className="rounded-xl border border-dashed border-border p-6 text-center text-sm"
        >
          We couldn&apos;t load this statement.
          <div>
            <Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>
              Try again
            </Button>
          </div>
        </div>
      ) : statement ? (
        <>
          <div className="grid gap-3 sm:grid-cols-4">
            {[
              ["Opening balance", statement.opening_balance],
              ["Charges", statement.total_debits],
              ["Payments", statement.total_credits],
              ["Closing balance", statement.closing_balance],
            ].map(([label, value]) => (
              <div key={label as string} className="rounded-xl border border-border p-3">
                <div className="text-xs uppercase tracking-wider text-muted-foreground">
                  {label}
                </div>
                <div className="mt-1 font-display text-lg font-bold tabular-nums">
                  {formatGHSCell(value as number)}
                </div>
              </div>
            ))}
          </div>
          <div className="overflow-x-auto rounded-xl border border-border">
            <table className="w-full min-w-[560px] text-left text-sm">
              <thead className="bg-muted/40 text-xs uppercase tracking-wider text-muted-foreground">
                <tr>
                  <th scope="col" className="p-2">
                    Date
                  </th>
                  <th scope="col" className="p-2">
                    Description
                  </th>
                  <th scope="col" className="p-2 text-right">
                    Charges
                  </th>
                  <th scope="col" className="p-2 text-right">
                    Payments
                  </th>
                  <th scope="col" className="p-2 text-right">
                    Balance
                  </th>
                </tr>
              </thead>
              <tbody>
                {statement.lines.length === 0 && (
                  <tr>
                    <td colSpan={5} className="p-4 text-center text-muted-foreground">
                      No activity in this period.
                    </td>
                  </tr>
                )}
                {statement.lines.map((line, index) => (
                  <tr key={`${line.order_id}-${line.kind}-${index}`} className="border-t">
                    <td className="p-2 whitespace-nowrap">{formatReportDate(line.date)}</td>
                    <td className="p-2">{lineDescription(line)}</td>
                    <td className="p-2 text-right tabular-nums">
                      {line.debit ? formatGHSCell(line.debit) : ""}
                    </td>
                    <td className="p-2 text-right tabular-nums">
                      {line.credit ? formatGHSCell(line.credit) : ""}
                    </td>
                    <td className="p-2 text-right tabular-nums">{formatGHSCell(line.balance)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {statement.truncated && (
            <p className="text-sm text-warning">
              Showing the first 2,000 of {statement.line_count} lines. Choose a shorter date range
              to see the rest.
            </p>
          )}
          <p className="text-xs text-muted-foreground">
            Charges are orders as placed; payments are recorded when the wholesaler confirms
            payment. Cancelled and refunded orders are not included.
          </p>
        </>
      ) : null}
    </div>
  );
}
