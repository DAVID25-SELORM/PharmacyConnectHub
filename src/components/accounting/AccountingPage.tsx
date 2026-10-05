import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronLeft, ChevronRight, Download, Search, ShieldAlert, X } from "lucide-react";
import { toast } from "sonner";
import { StatementPanel } from "@/components/accounting/StatementPanel";
import { DashboardHeader } from "@/components/DashboardShell";
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
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useDebouncedValue } from "@/hooks/use-debounced-value";
import { useSession } from "@/hooks/use-session";
import { supabase } from "@/integrations/supabase/client";
import {
  AGING_BUCKETS,
  EMPTY_INVOICE_FILTERS,
  EMPTY_PAYMENT_FILTERS,
  EXPORT_ROW_LIMIT,
  INVOICE_STATUS_LABELS,
  PAYMENT_METHOD_LABELS,
  SIDE_COPY,
  agingBucketLabel,
  agingExportSheet,
  canViewAccounting,
  describeInvoiceFilters,
  hasInvoiceFilters,
  invoiceExportSheet,
  invoiceFilterProblem,
  invoiceRegisterArgs,
  invoiceStatusLabel,
  paymentExportSheet,
  paymentMethodLabel,
  paymentRegisterArgs,
  type AccountingSide,
  type AgingSummaryRow,
  type ExportSheet,
  type InvoiceFilters,
  type InvoiceRow,
  type PaymentFilters,
  type PaymentRow,
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

const PAGE_SIZE = 50;
const selectClass =
  "h-10 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring";

type View = "invoices" | "payments" | "statements";

export function AccountingPage({ side }: { side: AccountingSide }) {
  const { business } = useSession();
  const copy = SIDE_COPY[side];
  const [view, setView] = useState<View>("invoices");

  // Invoices
  const [filters, setFilters] = useState<InvoiceFilters>(EMPTY_INVOICE_FILTERS);
  const debouncedSearch = useDebouncedValue(filters.search, 350);
  const [page, setPage] = useState(0);
  const [invoices, setInvoices] = useState<InvoiceRow[]>([]);
  const [invoiceTotal, setInvoiceTotal] = useState(0);
  const [summary, setSummary] = useState<AgingSummaryRow[] | null>(null);
  // Payments
  const [payFilters, setPayFilters] = useState<PaymentFilters>(EMPTY_PAYMENT_FILTERS);
  const [payPage, setPayPage] = useState(0);
  const [payments, setPayments] = useState<PaymentRow[]>([]);
  const [paymentTotal, setPaymentTotal] = useState(0);

  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [denied, setDenied] = useState(false);
  // True when the database functions behind this page are not installed yet (page deployed first).
  const [unavailable, setUnavailable] = useState(false);
  // Bumped by "Try again" to re-run the loaders.
  const [reloadKey, setReloadKey] = useState(0);
  const [exporting, setExporting] = useState(false);
  const [counterparties, setCounterparties] = useState<Record<string, string>>({});

  const businessId = business?.id;
  const allowed = canViewAccounting(side, business?.staff_role);
  const effectiveFilters = useMemo(
    () => ({ ...filters, search: debouncedSearch }),
    [filters, debouncedSearch],
  );
  const problem = invoiceFilterProblem(effectiveFilters);

  const remember = useCallback(
    (rows: Array<{ counterparty_id: string; counterparty_name: string }>) => {
      setCounterparties((current) => {
        const next = { ...current };
        for (const row of rows) next[row.counterparty_id] = row.counterparty_name;
        return next;
      });
    },
    [],
  );

  const onRpcError = useCallback((error: { message?: string; code?: string } | null) => {
    if (!error) return false;
    if (error.code === "PGRST202" || /could not find the function/i.test(error.message ?? ""))
      setUnavailable(true);
    else if (/do not have access/i.test(error.message ?? "")) setDenied(true);
    else setFailed(true);
    return true;
  }, []);

  // Invoice register
  useEffect(() => {
    if (!businessId || !allowed || view !== "invoices" || problem) return;
    let cancelled = false;
    setLoading(true);
    setFailed(false);
    void db
      .rpc(
        "credit_invoice_register",
        invoiceRegisterArgs(businessId, effectiveFilters, {
          limit: PAGE_SIZE,
          offset: page * PAGE_SIZE,
        }),
      )
      .then(
        ({ data, error }: { data: InvoiceRow[] | null; error: { message?: string } | null }) => {
          if (cancelled) return;
          setLoading(false);
          if (onRpcError(error)) return;
          const rows = data ?? [];
          setInvoices(rows);
          setInvoiceTotal(rows.length > 0 ? Number(rows[0].total_count) : 0);
          remember(rows);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, allowed, view, effectiveFilters, page, problem, reloadKey, onRpcError, remember]);

  // Aging summary (follows the party filter, not the other filters: it is the whole picture for that party)
  useEffect(() => {
    if (!businessId || !allowed) return;
    let cancelled = false;
    void db
      .rpc("credit_aging_summary", {
        p_business_id: businessId,
        p_counterparty_id: filters.counterpartyId || null,
      })
      .then(
        ({
          data,
          error,
        }: {
          data: AgingSummaryRow[] | null;
          error: { message?: string } | null;
        }) => {
          if (cancelled || onRpcError(error)) return;
          setSummary(data ?? []);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, allowed, filters.counterpartyId, onRpcError]);

  // Payment register
  useEffect(() => {
    if (!businessId || !allowed || view !== "payments") return;
    let cancelled = false;
    setLoading(true);
    setFailed(false);
    void db
      .rpc(
        "list_credit_payments",
        paymentRegisterArgs(businessId, payFilters, {
          limit: PAGE_SIZE,
          offset: payPage * PAGE_SIZE,
        }),
      )
      .then(
        ({ data, error }: { data: PaymentRow[] | null; error: { message?: string } | null }) => {
          if (cancelled) return;
          setLoading(false);
          if (onRpcError(error)) return;
          const rows = data ?? [];
          setPayments(rows);
          setPaymentTotal(rows.length > 0 ? Number(rows[0].total_count) : 0);
          remember(rows);
        },
      );
    return () => {
      cancelled = true;
    };
  }, [businessId, allowed, view, payFilters, payPage, reloadKey, onRpcError, remember]);

  const setFilter = (patch: Partial<InvoiceFilters>) => {
    setFilters((current) => ({ ...current, ...patch }));
    setPage(0);
  };
  const setPayFilter = (patch: Partial<PaymentFilters>) => {
    setPayFilters((current) => ({ ...current, ...patch }));
    setPayPage(0);
  };

  const counterpartyOptions = useMemo(
    () => Object.entries(counterparties).sort((a, b) => a[1].localeCompare(b[1])),
    [counterparties],
  );

  const runExport = async (format: "csv" | "xlsx" | "pdf") => {
    if (!businessId || exporting) return;
    setExporting(true);
    try {
      let sheets: ExportSheet[];
      let filenamePrefix: string;
      let title = `${copy.title} — ${business?.name ?? ""}`;
      if (view === "invoices") {
        const { data, error } = await db.rpc(
          "credit_invoice_register",
          invoiceRegisterArgs(businessId, effectiveFilters, { limit: EXPORT_ROW_LIMIT, offset: 0 }),
        );
        if (error) throw error;
        const rows = (data ?? []) as InvoiceRow[];
        sheets = [invoiceExportSheet(rows, side)];
        if (format !== "csv") sheets.push(agingExportSheet(summary ?? []));
        filenamePrefix = side === "wholesaler" ? "accounts-receivable" : "accounts-payable";
        const applied = describeInvoiceFilters(
          effectiveFilters,
          counterparties[effectiveFilters.counterpartyId],
        );
        if (applied.length > 0) title += ` (${applied.join("; ")})`;
        if (rows.length >= EXPORT_ROW_LIMIT)
          toast.message(
            `Exported the first ${EXPORT_ROW_LIMIT} matching invoices. Narrow the filters to export the rest.`,
          );
      } else {
        const { data, error } = await db.rpc(
          "list_credit_payments",
          paymentRegisterArgs(businessId, payFilters, { limit: EXPORT_ROW_LIMIT, offset: 0 }),
        );
        if (error) throw error;
        sheets = [paymentExportSheet((data ?? []) as PaymentRow[], side)];
        filenamePrefix = "credit-payments";
        title = `Credit payments — ${business?.name ?? ""}`;
      }
      if (format === "csv")
        downloadCsv(
          reportFilename(filenamePrefix, "csv"),
          rowsToCsv(sheets[0].headers, sheets[0].rows),
        );
      else if (format === "xlsx")
        await downloadXlsx(reportFilename(filenamePrefix, "xlsx"), sheets);
      else await downloadPdf(reportFilename(filenamePrefix, "pdf"), title, sheets);
    } catch {
      toast.error("We couldn't export this right now. Please try again.");
    } finally {
      setExporting(false);
    }
  };

  if (!business) return null;

  if (unavailable) {
    return (
      <div className="min-h-screen bg-background">
        <DashboardHeader subtitle="Accounting" showNav={true} />
        <main className="mx-auto max-w-3xl px-4 py-16 sm:px-6 lg:px-8">
          <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-10 text-center">
            <p className="font-medium">{copy.title} is being set up</p>
            <p className="max-w-sm text-sm text-muted-foreground">
              This section isn&apos;t ready yet. Your credit invoices and payments are still
              available under Credit.
            </p>
          </div>
        </main>
      </div>
    );
  }

  if (!allowed || denied) {
    return (
      <div className="min-h-screen bg-background">
        <DashboardHeader subtitle="Accounting" showNav={true} />
        <main className="mx-auto max-w-3xl px-4 py-16 sm:px-6 lg:px-8">
          <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed border-border p-10 text-center">
            <ShieldAlert className="h-8 w-8 text-muted-foreground" aria-hidden="true" />
            <p className="font-medium">You don&apos;t have access to accounting</p>
            <p className="max-w-sm text-sm text-muted-foreground">
              Only{" "}
              {side === "wholesaler"
                ? "the owner, a manager, finance or an accountant"
                : "the owner, a manager or an accountant"}{" "}
              for {business.name} can view it.
            </p>
          </div>
        </main>
      </div>
    );
  }

  const totalOwed = (summary ?? []).reduce((sum, row) => sum + Number(row.outstanding_ghs), 0);
  const pages = Math.max(
    1,
    Math.ceil((view === "invoices" ? invoiceTotal : paymentTotal) / PAGE_SIZE),
  );
  const currentPage = view === "invoices" ? page : payPage;
  const goPage = (next: number) => (view === "invoices" ? setPage(next) : setPayPage(next));

  return (
    <div className="min-h-screen bg-background">
      <DashboardHeader subtitle="Accounting" showNav={true} />
      <main className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="font-display text-3xl font-bold">{copy.title}</h1>
            <p className="mt-1 max-w-2xl text-muted-foreground">{copy.intro}</p>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button asChild variant="outline">
              <Link
                to={side === "wholesaler" ? "/wholesaler" : "/pharmacy"}
                search={{ tab: "credit" }}
              >
                Record payments &amp; invoice details
              </Link>
            </Button>
            {view !== "statements" && (
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" disabled={exporting}>
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
            )}
          </div>
        </div>

        <section aria-label="Aging summary" className="mt-6">
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
            <Card className="col-span-2 p-4 md:col-span-3 xl:col-span-1">
              <div className="text-xs uppercase tracking-wider text-muted-foreground">
                {copy.totalLabel}
              </div>
              <div className="mt-1.5 font-display text-2xl font-bold">
                {summary ? formatGHS(totalOwed) : "—"}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">Still owed, all ages.</p>
            </Card>
            {AGING_BUCKETS.map(({ key, label }) => {
              const row = summary?.find((item) => item.bucket === key);
              const active = filters.bucket === key;
              return (
                <button
                  key={key}
                  type="button"
                  aria-pressed={active}
                  onClick={() => {
                    setView("invoices");
                    setFilter({ bucket: active ? "" : key });
                  }}
                  className={`rounded-xl border p-4 text-left transition-colors hover:bg-muted/50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring ${active ? "border-primary bg-primary/5" : "border-border"}`}
                >
                  <div className="text-xs uppercase tracking-wider text-muted-foreground">
                    {label}
                  </div>
                  <div className="mt-1.5 font-display text-xl font-bold">
                    {summary ? formatGHS(Number(row?.outstanding_ghs ?? 0)) : "—"}
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {summary
                      ? `${Number(row?.invoices ?? 0)} invoice${Number(row?.invoices ?? 0) === 1 ? "" : "s"}`
                      : ""}
                    {active ? " · filtering" : ""}
                  </p>
                </button>
              );
            })}
          </div>
        </section>

        <Tabs value={view} onValueChange={(value) => setView(value as View)} className="mt-8">
          <TabsList>
            <TabsTrigger value="invoices">Invoices</TabsTrigger>
            <TabsTrigger value="payments">Payments</TabsTrigger>
            <TabsTrigger value="statements">Statements</TabsTrigger>
          </TabsList>
        </Tabs>

        {view === "statements" ? (
          <StatementPanel businessId={business.id} businessName={business.name} side={side} />
        ) : (
          <>
            {view === "invoices" ? (
              <Card className="mt-4 p-4">
                <form
                  role="search"
                  aria-label="Filter invoices"
                  className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
                  onSubmit={(event) => event.preventDefault()}
                >
                  <div className="relative sm:col-span-2">
                    <Label htmlFor="acc-search" className="sr-only">
                      Search
                    </Label>
                    <Search
                      className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted-foreground"
                      aria-hidden="true"
                    />
                    <Input
                      id="acc-search"
                      className="pl-9"
                      placeholder={`Search ${copy.party.toLowerCase()} or invoice number`}
                      value={filters.search}
                      onChange={(event) => setFilter({ search: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-party">{copy.party}</Label>
                    <select
                      id="acc-party"
                      className={selectClass}
                      value={filters.counterpartyId}
                      onChange={(event) => setFilter({ counterpartyId: event.target.value })}
                    >
                      <option value="">All</option>
                      {counterpartyOptions.map(([id, name]) => (
                        <option key={id} value={id}>
                          {name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="acc-status">Status</Label>
                    <select
                      id="acc-status"
                      className={selectClass}
                      value={filters.status}
                      onChange={(event) => setFilter({ status: event.target.value })}
                    >
                      <option value="">All</option>
                      <option value="outstanding">Still owed</option>
                      {Object.entries(INVOICE_STATUS_LABELS).map(([value, label]) => (
                        <option key={value} value={value}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="acc-bucket">Aging</Label>
                    <select
                      id="acc-bucket"
                      className={selectClass}
                      value={filters.bucket}
                      onChange={(event) => setFilter({ bucket: event.target.value })}
                    >
                      <option value="">All</option>
                      {AGING_BUCKETS.map(({ key, label }) => (
                        <option key={key} value={key}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="acc-due-from">Due from</Label>
                    <Input
                      id="acc-due-from"
                      type="date"
                      value={filters.dueFrom}
                      onChange={(event) => setFilter({ dueFrom: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-due-to">Due to</Label>
                    <Input
                      id="acc-due-to"
                      type="date"
                      value={filters.dueTo}
                      onChange={(event) => setFilter({ dueTo: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-inv-from">Invoice from</Label>
                    <Input
                      id="acc-inv-from"
                      type="date"
                      value={filters.invoiceFrom}
                      onChange={(event) => setFilter({ invoiceFrom: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-inv-to">Invoice to</Label>
                    <Input
                      id="acc-inv-to"
                      type="date"
                      value={filters.invoiceTo}
                      onChange={(event) => setFilter({ invoiceTo: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-min">Outstanding at least (GHS)</Label>
                    <Input
                      id="acc-min"
                      type="number"
                      min={0}
                      step="0.01"
                      value={filters.minOutstanding}
                      onChange={(event) => setFilter({ minOutstanding: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="acc-max">Outstanding at most (GHS)</Label>
                    <Input
                      id="acc-max"
                      type="number"
                      min={0}
                      step="0.01"
                      value={filters.maxOutstanding}
                      onChange={(event) => setFilter({ maxOutstanding: event.target.value })}
                    />
                  </div>
                  {hasInvoiceFilters(filters) && (
                    <div className="flex items-end">
                      <Button
                        type="button"
                        variant="ghost"
                        onClick={() => {
                          setFilters(EMPTY_INVOICE_FILTERS);
                          setPage(0);
                        }}
                      >
                        <X className="mr-1 h-4 w-4" aria-hidden="true" /> Clear filters
                      </Button>
                    </div>
                  )}
                </form>
                {problem && (
                  <p role="alert" className="mt-3 text-sm text-destructive">
                    {problem}
                  </p>
                )}
              </Card>
            ) : (
              <Card className="mt-4 p-4">
                <p className="mb-3 text-sm text-muted-foreground">{copy.paymentsIntro}</p>
                <form
                  role="search"
                  aria-label="Filter payments"
                  className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4"
                  onSubmit={(event) => event.preventDefault()}
                >
                  <div>
                    <Label htmlFor="pay-party">{copy.party}</Label>
                    <select
                      id="pay-party"
                      className={selectClass}
                      value={payFilters.counterpartyId}
                      onChange={(event) => setPayFilter({ counterpartyId: event.target.value })}
                    >
                      <option value="">All</option>
                      {counterpartyOptions.map(([id, name]) => (
                        <option key={id} value={id}>
                          {name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="pay-method">Method</Label>
                    <select
                      id="pay-method"
                      className={selectClass}
                      value={payFilters.method}
                      onChange={(event) => setPayFilter({ method: event.target.value })}
                    >
                      <option value="">All</option>
                      {Object.entries(PAYMENT_METHOD_LABELS).map(([value, label]) => (
                        <option key={value} value={value}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="pay-from">Paid from</Label>
                    <Input
                      id="pay-from"
                      type="date"
                      value={payFilters.from}
                      onChange={(event) => setPayFilter({ from: event.target.value })}
                    />
                  </div>
                  <div>
                    <Label htmlFor="pay-to">Paid to</Label>
                    <Input
                      id="pay-to"
                      type="date"
                      value={payFilters.to}
                      onChange={(event) => setPayFilter({ to: event.target.value })}
                    />
                  </div>
                </form>
              </Card>
            )}

            <div className="mt-4" aria-live="polite">
              {failed ? (
                <Card className="p-6 text-center text-sm">
                  <p role="alert">We couldn&apos;t load this just now.</p>
                  <Button
                    className="mt-3"
                    variant="outline"
                    onClick={() => {
                      setFailed(false);
                      setReloadKey((key) => key + 1);
                    }}
                  >
                    Try again
                  </Button>
                </Card>
              ) : loading ? (
                <div className="space-y-2" role="status" aria-label="Loading">
                  <Skeleton className="h-10 w-full" />
                  <Skeleton className="h-10 w-full" />
                  <Skeleton className="h-10 w-full" />
                </div>
              ) : view === "invoices" ? (
                invoices.length === 0 ? (
                  <Card className="p-8 text-center text-sm text-muted-foreground">
                    {hasInvoiceFilters(filters)
                      ? "No invoices match these filters."
                      : "No credit invoices yet."}
                  </Card>
                ) : (
                  <InvoiceTable rows={invoices} side={side} />
                )
              ) : payments.length === 0 ? (
                <Card className="p-8 text-center text-sm text-muted-foreground">
                  No payments match these filters.
                </Card>
              ) : (
                <PaymentTable rows={payments} />
              )}
            </div>

            <div className="mt-3 flex items-center justify-between text-sm text-muted-foreground">
              <span>
                {view === "invoices" ? invoiceTotal : paymentTotal}{" "}
                {view === "invoices" ? "invoice" : "payment"}
                {(view === "invoices" ? invoiceTotal : paymentTotal) === 1 ? "" : "s"}
              </span>
              <div className="flex items-center gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  disabled={currentPage === 0}
                  onClick={() => goPage(currentPage - 1)}
                  aria-label="Previous page"
                >
                  <ChevronLeft className="h-4 w-4" aria-hidden="true" />
                </Button>
                <span>
                  Page {currentPage + 1} of {pages}
                </span>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={currentPage + 1 >= pages}
                  onClick={() => goPage(currentPage + 1)}
                  aria-label="Next page"
                >
                  <ChevronRight className="h-4 w-4" aria-hidden="true" />
                </Button>
              </div>
            </div>
          </>
        )}
      </main>
    </div>
  );
}

function InvoiceTable({ rows, side }: { rows: InvoiceRow[]; side: AccountingSide }) {
  return (
    <>
      <div className="hidden overflow-x-auto rounded-xl border border-border md:block">
        <table className="w-full text-sm">
          <caption className="sr-only">Credit invoices</caption>
          <thead className="bg-muted/50 text-left text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th scope="col" className="p-3">
                {SIDE_COPY[side].party}
              </th>
              <th scope="col" className="p-3">
                Invoice
              </th>
              <th scope="col" className="p-3">
                Invoice date
              </th>
              <th scope="col" className="p-3">
                Due date
              </th>
              <th scope="col" className="p-3 text-right">
                Original
              </th>
              <th scope="col" className="p-3 text-right">
                Paid
              </th>
              <th scope="col" className="p-3 text-right">
                Outstanding
              </th>
              <th scope="col" className="p-3 text-right">
                Days overdue
              </th>
              <th scope="col" className="p-3">
                Aging
              </th>
              <th scope="col" className="p-3">
                Status
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((row) => (
              <tr key={row.order_id}>
                <td className="p-3 font-medium">{row.counterparty_name}</td>
                <td className="p-3">{row.order_number}</td>
                <td className="p-3 whitespace-nowrap">{formatReportDate(row.invoice_date)}</td>
                <td className="p-3 whitespace-nowrap">
                  {row.due_date ? formatReportDate(row.due_date) : "—"}
                </td>
                <td className="p-3 text-right">{formatGHS(Number(row.invoice_ghs))}</td>
                <td className="p-3 text-right">{formatGHS(Number(row.paid_ghs))}</td>
                <td className="p-3 text-right font-medium">
                  {formatGHS(Number(row.outstanding_ghs))}
                </td>
                <td className="p-3 text-right">{row.days_overdue ?? "—"}</td>
                <td className="p-3">{agingBucketLabel(row.aging_bucket)}</td>
                <td className="p-3">{invoiceStatusLabel(row.status)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-3 md:hidden">
        {rows.map((row) => (
          <li key={row.order_id}>
            <Card className="p-4 text-sm">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-medium">{row.counterparty_name}</div>
                  <div className="text-xs text-muted-foreground">
                    {row.order_number} · {formatReportDate(row.invoice_date)}
                  </div>
                </div>
                <span className="text-xs font-medium">{invoiceStatusLabel(row.status)}</span>
              </div>
              <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
                <dt className="text-muted-foreground">Due</dt>
                <dd className="text-right">
                  {row.due_date ? formatReportDate(row.due_date) : "—"}
                </dd>
                <dt className="text-muted-foreground">Original</dt>
                <dd className="text-right">{formatGHS(Number(row.invoice_ghs))}</dd>
                <dt className="text-muted-foreground">Paid</dt>
                <dd className="text-right">{formatGHS(Number(row.paid_ghs))}</dd>
                <dt className="text-muted-foreground">Outstanding</dt>
                <dd className="text-right font-medium">{formatGHS(Number(row.outstanding_ghs))}</dd>
                <dt className="text-muted-foreground">Aging</dt>
                <dd className="text-right">
                  {agingBucketLabel(row.aging_bucket)}
                  {row.days_overdue ? ` (${row.days_overdue} days)` : ""}
                </dd>
              </dl>
            </Card>
          </li>
        ))}
      </ul>
    </>
  );
}

function PaymentTable({ rows }: { rows: PaymentRow[] }) {
  return (
    <>
      <div className="hidden overflow-x-auto rounded-xl border border-border md:block">
        <table className="w-full text-sm">
          <caption className="sr-only">Credit payments</caption>
          <thead className="bg-muted/50 text-left text-xs uppercase tracking-wider text-muted-foreground">
            <tr>
              <th scope="col" className="p-3">
                Paid on
              </th>
              <th scope="col" className="p-3">
                Party
              </th>
              <th scope="col" className="p-3">
                Method
              </th>
              <th scope="col" className="p-3">
                Reference
              </th>
              <th scope="col" className="p-3 text-right">
                Amount
              </th>
              <th scope="col" className="p-3 text-right">
                Allocated
              </th>
              <th scope="col" className="p-3 text-right">
                Unallocated
              </th>
              <th scope="col" className="p-3 text-right">
                Reversed
              </th>
              <th scope="col" className="p-3">
                Recorded by
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((row) => (
              <tr key={row.payment_id}>
                <td className="p-3 whitespace-nowrap">{formatReportDate(row.paid_at)}</td>
                <td className="p-3 font-medium">{row.counterparty_name}</td>
                <td className="p-3">{paymentMethodLabel(row.method)}</td>
                <td className="p-3">{row.reference ?? "—"}</td>
                <td className="p-3 text-right font-medium">{formatGHS(Number(row.amount_ghs))}</td>
                <td className="p-3 text-right">{formatGHS(Number(row.allocated_ghs))}</td>
                <td className="p-3 text-right">{formatGHS(Number(row.unallocated_ghs))}</td>
                <td className="p-3 text-right">
                  {Number(row.reversed_ghs) > 0 ? formatGHS(Number(row.reversed_ghs)) : "—"}
                </td>
                <td className="p-3">{row.recorded_by_email ?? "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <ul className="space-y-3 md:hidden">
        {rows.map((row) => (
          <li key={row.payment_id}>
            <Card className="p-4 text-sm">
              <div className="flex items-start justify-between gap-2">
                <div>
                  <div className="font-medium">{row.counterparty_name}</div>
                  <div className="text-xs text-muted-foreground">
                    {formatReportDate(row.paid_at)} · {paymentMethodLabel(row.method)}
                    {row.reference ? ` · ${row.reference}` : ""}
                  </div>
                </div>
                <span className="font-medium">{formatGHS(Number(row.amount_ghs))}</span>
              </div>
              <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
                <dt className="text-muted-foreground">Allocated</dt>
                <dd className="text-right">{formatGHS(Number(row.allocated_ghs))}</dd>
                <dt className="text-muted-foreground">Unallocated</dt>
                <dd className="text-right">{formatGHS(Number(row.unallocated_ghs))}</dd>
                {Number(row.reversed_ghs) > 0 && (
                  <>
                    <dt className="text-muted-foreground">Reversed</dt>
                    <dd className="text-right">{formatGHS(Number(row.reversed_ghs))}</dd>
                  </>
                )}
              </dl>
            </Card>
          </li>
        ))}
      </ul>
    </>
  );
}
