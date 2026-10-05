import { useCallback, useEffect, useMemo, useState } from "react";
import { Download } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { supabase } from "@/integrations/supabase/client";
import {
  AGING_BUCKETS,
  SIDE_COPY,
  STATEMENT_PRESETS,
  entryTypeLabel,
  statementArgs,
  statementExportSheets,
  statementFilenameStem,
  statementLineDescription,
  statementPeriodProblem,
  statementPresetRange,
  type AccountingSide,
  type CounterpartyOption,
  type CreditStatement,
  type StatementLine,
} from "@/lib/accounting";
import { formatGHS } from "@/lib/format";
import {
  downloadCsv,
  downloadPdf,
  downloadXlsx,
  formatReportDate,
  reportFilename,
  rowsToCsv,
} from "@/lib/reports";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

const selectClass =
  "h-10 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

type PanelError = "unavailable" | "denied" | "failed" | null;

/** A negative balance is credit held on account (an overpayment); say so in words. */
function balanceText(value: number | string) {
  const n = Number(value);
  return n < 0 ? `${formatGHS(Math.abs(n))} credit` : formatGHS(n);
}

function errorKind(error: { message?: string; code?: string }): PanelError {
  if (error.code === "PGRST202" || /could not find the function/i.test(error.message ?? ""))
    return "unavailable";
  if (/do not have access/i.test(error.message ?? "")) return "denied";
  return "failed";
}

export function StatementPanel({
  businessId,
  businessName,
  side,
}: {
  businessId: string;
  businessName: string;
  side: AccountingSide;
}) {
  const copy = SIDE_COPY[side];
  const [options, setOptions] = useState<CounterpartyOption[] | null>(null);
  const [counterpartyId, setCounterpartyId] = useState("");
  const [range, setRange] = useState(() => statementPresetRange("this_month"));
  const [statement, setStatement] = useState<CreditStatement | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<PanelError>(null);
  const [reloadKey, setReloadKey] = useState(0);
  const [exporting, setExporting] = useState(false);
  const problem = statementPeriodProblem(range.from, range.to);

  useEffect(() => {
    let cancelled = false;
    void db
      .rpc("credit_counterparties", { p_business_id: businessId })
      .then(
        ({
          data,
          error: rpcError,
        }: {
          data: CounterpartyOption[] | null;
          error: { message?: string; code?: string } | null;
        }) => {
          if (cancelled) return;
          if (rpcError) return setError(errorKind(rpcError));
          const rows = data ?? [];
          setOptions(rows);
          // With only one party there is nothing to choose.
          if (rows.length === 1) setCounterpartyId(rows[0].counterparty_id);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, reloadKey]);

  useEffect(() => {
    if (!counterpartyId || problem) {
      setStatement(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    void db
      .rpc(
        "credit_account_statement",
        statementArgs(businessId, counterpartyId, range.from, range.to),
      )
      .then(
        ({
          data,
          error: rpcError,
        }: {
          data: CreditStatement | null;
          error: { message?: string; code?: string } | null;
        }) => {
          if (cancelled) return;
          setLoading(false);
          if (rpcError || !data) {
            setStatement(null);
            return setError(rpcError ? errorKind(rpcError) : "failed");
          }
          setStatement(data);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, counterpartyId, range.from, range.to, problem, reloadKey]);

  const sortedOptions = useMemo(
    () =>
      [...(options ?? [])].sort((a, b) => a.counterparty_name.localeCompare(b.counterparty_name)),
    [options],
  );

  const runExport = useCallback(
    async (format: "csv" | "xlsx" | "pdf") => {
      if (!statement || exporting) return;
      setExporting(true);
      try {
        const sheets = statementExportSheets(statement);
        const stem = statementFilenameStem(statement);
        if (statement.truncated)
          toast.message(
            `The export has the first ${statement.lines.length} of ${statement.line_count} lines. Choose a shorter period to export the rest.`,
          );
        if (format === "csv")
          downloadCsv(reportFilename(stem, "csv"), rowsToCsv(sheets[0].headers, sheets[0].rows));
        else if (format === "xlsx") await downloadXlsx(reportFilename(stem, "xlsx"), sheets);
        else
          await downloadPdf(
            reportFilename(stem, "pdf"),
            `Statement of account — ${businessName} and ${statement.counterparty.name}`,
            sheets,
          );
      } catch {
        toast.error("We couldn't export this right now. Please try again.");
      } finally {
        setExporting(false);
      }
    },
    [statement, exporting, businessName],
  );

  if (error === "unavailable")
    return (
      <Card className="mt-4 p-8 text-center text-sm text-muted-foreground">
        Statements are being set up. Invoices and payments are available in the other tabs.
      </Card>
    );
  if (error === "denied")
    return (
      <Card className="mt-4 p-8 text-center text-sm text-muted-foreground">
        You don&apos;t have access to statements for {businessName}.
      </Card>
    );

  return (
    <div className="mt-4 space-y-4">
      <Card className="p-4">
        <p className="mb-3 text-sm text-muted-foreground">
          Every credit invoice, payment, credit note and write-off between {businessName} and one{" "}
          {copy.party.toLowerCase()}, with a running balance. Cash orders are not included.
        </p>
        <form
          aria-label="Statement period"
          className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
          onSubmit={(event) => event.preventDefault()}
        >
          <div className="sm:col-span-2">
            <Label htmlFor="st-party">{copy.party}</Label>
            <select
              id="st-party"
              className={selectClass}
              value={counterpartyId}
              onChange={(event) => setCounterpartyId(event.target.value)}
              disabled={options === null}
            >
              {options?.length !== 1 && (
                <option value="">Choose a {copy.party.toLowerCase()}…</option>
              )}
              {sortedOptions.map((option) => (
                <option key={option.counterparty_id} value={option.counterparty_id}>
                  {option.counterparty_name}
                </option>
              ))}
            </select>
          </div>
          <div>
            <Label htmlFor="st-from">From</Label>
            <Input
              id="st-from"
              type="date"
              value={range.from}
              max={range.to || undefined}
              onChange={(event) =>
                setRange((current) => ({ ...current, from: event.target.value }))
              }
            />
          </div>
          <div>
            <Label htmlFor="st-to">To</Label>
            <Input
              id="st-to"
              type="date"
              value={range.to}
              min={range.from || undefined}
              onChange={(event) => setRange((current) => ({ ...current, to: event.target.value }))}
            />
          </div>
        </form>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          {STATEMENT_PRESETS.map((preset) => (
            <Button
              key={preset.key}
              type="button"
              size="sm"
              variant="outline"
              onClick={() => setRange(statementPresetRange(preset.key))}
            >
              {preset.label}
            </Button>
          ))}
          <div className="ml-auto">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" disabled={!statement || exporting}>
                  <Download className="mr-2 h-4 w-4" aria-hidden="true" />
                  {exporting ? "Exporting…" : "Export"}
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onSelect={() => void runExport("csv")}>CSV</DropdownMenuItem>
                <DropdownMenuItem onSelect={() => void runExport("xlsx")}>Excel</DropdownMenuItem>
                <DropdownMenuItem onSelect={() => void runExport("pdf")}>PDF</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
        {problem && (
          <p role="alert" className="mt-3 text-sm text-destructive">
            {problem}
          </p>
        )}
      </Card>

      <div aria-live="polite">
        {error === "failed" ? (
          <Card className="p-6 text-center text-sm">
            <p role="alert">We couldn&apos;t load this statement just now.</p>
            <Button
              className="mt-3"
              variant="outline"
              onClick={() => {
                setError(null);
                setReloadKey((key) => key + 1);
              }}
            >
              Try again
            </Button>
          </Card>
        ) : options !== null && options.length === 0 ? (
          <Card className="p-8 text-center text-sm text-muted-foreground">
            No credit relationships yet, so there are no statements to show.
          </Card>
        ) : !counterpartyId ? (
          <Card className="p-8 text-center text-sm text-muted-foreground">
            Choose a {copy.party.toLowerCase()} to see the statement.
          </Card>
        ) : problem ? null : loading || !statement ? (
          <div className="space-y-2" role="status" aria-label="Loading statement">
            <Skeleton className="h-16 w-full" />
            <Skeleton className="h-32 w-full" />
          </div>
        ) : (
          <StatementBody statement={statement} />
        )}
      </div>
    </div>
  );
}

function StatementBody({ statement }: { statement: CreditStatement }) {
  const summary = [
    ["Opening balance", statement.opening_balance],
    ["Charges", statement.total_charges],
    ["Credits", statement.total_credits],
    ["Closing balance", statement.closing_balance],
  ] as const;
  const showToday = Number(statement.balance_today) !== Number(statement.closing_balance);
  return (
    <div className="space-y-4">
      <div>
        <h2 className="font-display text-xl font-bold">{statement.counterparty.name}</h2>
        <p className="text-sm text-muted-foreground">
          {formatReportDate(statement.from)} to {formatReportDate(statement.to)}
        </p>
      </div>
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        {summary.map(([label, value]) => (
          <Card key={label} className="p-4">
            <div className="text-xs uppercase tracking-wider text-muted-foreground">{label}</div>
            <div className="mt-1.5 font-display text-xl font-bold">{balanceText(value)}</div>
          </Card>
        ))}
      </div>
      {showToday && (
        <p className="text-sm text-muted-foreground">
          Balance today (after this period): <strong>{balanceText(statement.balance_today)}</strong>
        </p>
      )}

      {statement.lines.length === 0 ? (
        <Card className="p-8 text-center text-sm text-muted-foreground">
          No credit activity in this period.
        </Card>
      ) : (
        <StatementLines lines={statement.lines} />
      )}
      {statement.truncated && (
        <p role="status" className="text-sm text-warning">
          Showing the first {statement.lines.length} of {Number(statement.line_count)} lines. Choose
          a shorter period to see the rest. The totals above cover the whole period.
        </p>
      )}

      <section aria-label="Overdue now">
        <h3 className="text-sm font-medium">
          Still owed, by how overdue (as of {formatReportDate(statement.aging_as_of)})
        </h3>
        <div className="mt-2 grid grid-cols-2 gap-3 md:grid-cols-5">
          {AGING_BUCKETS.map(({ key, label }) => {
            const row = statement.aging.find((item) => item.bucket === key);
            return (
              <Card key={key} className="p-3">
                <div className="text-xs text-muted-foreground">{label}</div>
                <div className="mt-1 font-medium">
                  {formatGHS(Number(row?.outstanding_ghs ?? 0))}
                </div>
              </Card>
            );
          })}
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          This is what is overdue on invoices today. It can differ from the closing balance, which
          also counts payments on account and adjustments not matched to an invoice.
        </p>
      </section>
    </div>
  );
}

function StatementLines({ lines }: { lines: StatementLine[] }) {
  return (
    <>
      <div className="hidden overflow-x-auto rounded-xl border border-border md:block">
        <table className="w-full text-sm">
          <caption className="sr-only">Statement lines</caption>
          <thead className="bg-muted/50 text-left text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th scope="col" className="p-3">
                Date
              </th>
              <th scope="col" className="p-3">
                Type
              </th>
              <th scope="col" className="p-3">
                Description
              </th>
              <th scope="col" className="p-3 text-right">
                Charges
              </th>
              <th scope="col" className="p-3 text-right">
                Credits
              </th>
              <th scope="col" className="p-3 text-right">
                Balance
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {lines.map((line, index) => (
              <tr key={index}>
                <td className="p-3 whitespace-nowrap">{formatReportDate(line.date)}</td>
                <td className="p-3">{entryTypeLabel(line.entry_type)}</td>
                <td className="p-3">
                  {statementLineDescription(line)}
                  {line.note && <div className="text-xs text-muted-foreground">{line.note}</div>}
                </td>
                <td className="p-3 text-right whitespace-nowrap">
                  {Number(line.debit) ? formatGHS(Number(line.debit)) : ""}
                </td>
                <td className="p-3 text-right whitespace-nowrap">
                  {Number(line.credit) ? formatGHS(Number(line.credit)) : ""}
                </td>
                <td className="p-3 text-right font-medium whitespace-nowrap">
                  {balanceText(line.balance)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-3 md:hidden">
        {lines.map((line, index) => (
          <li key={index}>
            <Card className="p-4 text-sm">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-medium">{statementLineDescription(line)}</div>
                  <div className="text-xs text-muted-foreground">
                    {formatReportDate(line.date)} · {entryTypeLabel(line.entry_type)}
                  </div>
                  {line.note && (
                    <div className="mt-1 text-xs text-muted-foreground">{line.note}</div>
                  )}
                </div>
                <div className="shrink-0 text-right whitespace-nowrap">
                  <div className="font-medium">
                    {Number(line.debit)
                      ? `+ ${formatGHS(Number(line.debit))}`
                      : `− ${formatGHS(Number(line.credit))}`}
                  </div>
                  <div className="text-xs text-muted-foreground">
                    Balance {balanceText(line.balance)}
                  </div>
                </div>
              </div>
            </Card>
          </li>
        ))}
      </ul>
    </>
  );
}
