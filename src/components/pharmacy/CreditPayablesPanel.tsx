import { useCallback, useEffect, useState } from "react";
import { ChevronDown, ChevronUp, Wallet } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { ReportKpis, type ReportKpi } from "@/components/reports/ReportKpis";
import { CreditAgingBar } from "@/components/credit/CreditAgingBar";
import { supabase } from "@/integrations/supabase/client";
import { formatGHS } from "@/lib/format";
import { formatReportDate, formatReportDateTime } from "@/lib/reports";
import {
  CREDIT_INVOICE_STATUS_LABELS,
  CREDIT_INVOICE_STATUS_STYLES,
  type CreditInvoice,
  type CreditInvoiceStatus,
  type PharmacyApSummary,
} from "@/lib/credit-ledger";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const rpc = (name: string, args: Record<string, unknown>) => (supabase as any).rpc(name, args);

const STATUS_FILTERS: Array<{ value: string; label: string }> = [
  { value: "outstanding", label: "Outstanding" },
  { value: "overdue", label: "Overdue" },
  { value: "due_today", label: "Due today" },
  { value: "partially_paid", label: "Partially paid" },
  { value: "disputed", label: "Disputed" },
  { value: "paid", label: "Paid" },
  { value: "written_off", label: "Written off" },
  { value: "", label: "All" },
];

type LedgerLine = {
  id: string;
  entry_type: string;
  direction: "debit" | "credit";
  amount_ghs: number;
  note: string | null;
  created_at: string;
};

function StatusBadge({ status }: { status: CreditInvoiceStatus }) {
  return (
    <Badge variant="secondary" className={`border ${CREDIT_INVOICE_STATUS_STYLES[status]}`}>
      {CREDIT_INVOICE_STATUS_LABELS[status]}
    </Badge>
  );
}

/** Accounts Payable summary for a pharmacy: what it owes across every supplier it has credit
 * with. Read-only -- settling a balance is the wholesaler's action (they record the payment once
 * the money actually arrives), not something a pharmacy does from here. */
function ApSummaryCard({ pharmacyId }: { pharmacyId: string }) {
  const [summary, setSummary] = useState<PharmacyApSummary | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    void rpc("pharmacy_ap_summary", { p_pharmacy_id: pharmacyId }).then(
      ({ data }: { data: PharmacyApSummary | null }) => {
        if (cancelled) return;
        setSummary(data ?? null);
        setLoading(false);
      },
    );
    return () => {
      cancelled = true;
    };
  }, [pharmacyId]);

  const kpis: ReportKpi[] = [
    { label: "Total Owed", value: summary ? formatGHS(summary.total_supplier_debt_ghs) : "—" },
    { label: "Due This Week", value: summary ? formatGHS(summary.due_this_week_ghs) : "—" },
    { label: "Due This Month", value: summary ? formatGHS(summary.due_this_month_ghs) : "—" },
    { label: "Overdue", value: summary ? formatGHS(summary.overdue_ghs) : "—" },
    { label: "Paid This Month", value: summary ? formatGHS(summary.paid_this_month_ghs) : "—" },
  ];

  return (
    <Card className="p-5">
      <h2 className="font-display text-xl font-bold">Accounts payable</h2>
      <p className="mt-1 text-sm text-muted-foreground">
        What you owe across every supplier that has approved credit for you.
      </p>
      <div className="mt-4">
        <ReportKpis items={kpis} loading={loading} />
      </div>
      {!loading && summary && (
        <>
          <div className="mt-5">
            <h3 className="text-sm font-medium text-muted-foreground">Aging</h3>
            <div className="mt-2">
              <CreditAgingBar aging={summary.aging} />
            </div>
          </div>
          {summary.outstanding_by_wholesaler.length > 0 && (
            <div className="mt-5">
              <h3 className="text-sm font-medium text-muted-foreground">Owed by supplier</h3>
              <ul className="mt-2 divide-y divide-border rounded-xl border border-border text-sm">
                {summary.outstanding_by_wholesaler.map((row) => (
                  <li key={row.wholesaler_id} className="flex items-center justify-between gap-3 p-3">
                    <span>{row.wholesaler_name}</span>
                    <span className="text-muted-foreground">
                      {formatGHS(row.outstanding_ghs)} · {row.invoice_count} invoice
                      {row.invoice_count === 1 ? "" : "s"}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}
    </Card>
  );
}

export function CreditPayablesPanel({ pharmacyId }: { pharmacyId: string }) {
  const [invoices, setInvoices] = useState<CreditInvoice[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [statusFilter, setStatusFilter] = useState("outstanding");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [ledgerLines, setLedgerLines] = useState<LedgerLine[]>([]);
  const [ledgerLoading, setLedgerLoading] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(false);
    const { data, error: rpcError } = await rpc("list_credit_invoices", {
      p_wholesaler_id: null,
      p_pharmacy_id: pharmacyId,
      p_status: statusFilter || null,
    });
    if (rpcError) setError(true);
    else setInvoices(Array.isArray(data) ? (data as CreditInvoice[]) : []);
    setLoading(false);
  }, [pharmacyId, statusFilter]);

  useEffect(() => {
    void load();
  }, [load]);

  const toggleExpand = async (invoice: CreditInvoice) => {
    if (expandedId === invoice.order_id) {
      setExpandedId(null);
      return;
    }
    setExpandedId(invoice.order_id);
    setLedgerLoading(true);
    const { data, error: rpcError } = await rpc("get_credit_invoice", { p_order_id: invoice.order_id });
    setLedgerLoading(false);
    if (rpcError || !data) {
      setLedgerLines([]);
      return;
    }
    setLedgerLines(Array.isArray(data.lines) ? (data.lines as LedgerLine[]) : []);
  };

  return (
    <div className="space-y-6">
      <ApSummaryCard pharmacyId={pharmacyId} />
      <Card className="p-5">
        <div className="flex items-center gap-2">
          <Wallet className="h-5 w-5 text-primary" aria-hidden="true" />
          <h2 className="font-display text-xl font-bold">Credit invoices</h2>
        </div>
        <p className="mt-1 text-sm text-muted-foreground">
          Every credit order you've placed, and where it stands. Your supplier records the payment
          once they've received it.
        </p>

        <div className="mt-4 flex flex-wrap gap-2">
          {STATUS_FILTERS.map((filter) => (
            <Button
              key={filter.value || "all"}
              type="button"
              size="sm"
              variant={statusFilter === filter.value ? "secondary" : "ghost"}
              onClick={() => setStatusFilter(filter.value)}
            >
              {filter.label}
            </Button>
          ))}
        </div>

        <div className="mt-4">
          {loading ? (
            <div className="space-y-2">
              <Skeleton className="h-16 w-full" />
              <Skeleton className="h-16 w-full" />
            </div>
          ) : error ? (
            <p role="alert" className="text-sm">
              We couldn&apos;t load credit invoices.{" "}
              <button type="button" className="text-primary underline" onClick={() => void load()}>
                Try again
              </button>
            </p>
          ) : invoices.length === 0 ? (
            <p className="text-sm text-muted-foreground">No credit invoices match this filter.</p>
          ) : (
            <ul className="divide-y divide-border rounded-xl border border-border text-sm">
              {invoices.map((invoice) => {
                const expanded = expandedId === invoice.order_id;
                return (
                  <li key={invoice.order_id} className="p-3">
                    <div className="flex flex-wrap items-center justify-between gap-3">
                      <div>
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="font-medium">{invoice.order_number}</span>
                          <StatusBadge status={invoice.status} />
                        </div>
                        <div className="text-muted-foreground">
                          {invoice.wholesaler_name} · {formatGHS(invoice.outstanding_ghs)} outstanding
                          of {formatGHS(invoice.invoice_ghs)}
                          {invoice.due_date ? ` · due ${formatReportDate(invoice.due_date)}` : " · due date set on delivery"}
                        </div>
                      </div>
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        onClick={() => void toggleExpand(invoice)}
                        aria-expanded={expanded}
                      >
                        {expanded ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
                      </Button>
                    </div>

                    {expanded && (
                      <div className="mt-3 rounded-lg border border-border bg-muted/20 p-3">
                        {ledgerLoading ? (
                          <Skeleton className="h-10 w-full" />
                        ) : ledgerLines.length === 0 ? (
                          <p className="text-xs text-muted-foreground">No ledger entries.</p>
                        ) : (
                          <ul className="space-y-1.5">
                            {ledgerLines.map((line) => (
                              <li key={line.id} className="flex items-center justify-between gap-3 text-xs">
                                <span className="text-muted-foreground">
                                  {formatReportDateTime(line.created_at)} · {line.entry_type.replace(/_/g, " ")}
                                  {line.note ? ` · ${line.note}` : ""}
                                </span>
                                <span className={line.direction === "debit" ? "text-destructive" : "text-success"}>
                                  {line.direction === "debit" ? "+" : "-"}
                                  {formatGHS(line.amount_ghs)}
                                </span>
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </Card>
    </div>
  );
}
