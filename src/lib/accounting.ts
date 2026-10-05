// Shared helpers for the Accounting pages (accounts receivable for wholesalers, accounts payable for
// pharmacies). Everything financial comes from the database registers; nothing here totals money
// in the browser. These helpers only shape requests, labels and exports.

export type AccountingSide = "wholesaler" | "pharmacy";

/** Who may open the Accounting pages. The database enforces the same rule; this only decides
 * whether to show the link and the page. */
export const ACCOUNTING_ROLES: Record<AccountingSide, string[]> = {
  wholesaler: ["owner", "manager", "finance", "accountant"],
  pharmacy: ["owner", "manager", "accountant"],
};

export function canViewAccounting(side: AccountingSide, role: string | undefined): boolean {
  return role !== undefined && ACCOUNTING_ROLES[side].includes(role);
}

export const SIDE_COPY: Record<
  AccountingSide,
  { title: string; intro: string; party: string; totalLabel: string; paymentsIntro: string }
> = {
  wholesaler: {
    title: "Accounts receivable",
    intro: "What pharmacies owe you on credit, aged by how long each balance is past its due date.",
    party: "Pharmacy",
    totalLabel: "Total receivables",
    paymentsIntro: "Payments you have recorded against credit invoices.",
  },
  pharmacy: {
    title: "Accounts payable",
    intro: "What you owe suppliers on credit, aged by how long each balance is past its due date.",
    party: "Supplier",
    totalLabel: "Total payables",
    paymentsIntro: "Payments recorded against your credit invoices.",
  },
};

// ---------------------------------------------------------------------------
// Aging. The buckets and their boundaries are defined once, in the database
// (credit_aging_bucket); these are just the labels. Labels say the range in words so no meaning
// depends on a colour.
// ---------------------------------------------------------------------------
export type AgingBucketKey = "current" | "d1_30" | "d31_60" | "d61_90" | "d90_plus";

export const AGING_BUCKETS: Array<{ key: AgingBucketKey; label: string }> = [
  { key: "current", label: "Current (not yet due)" },
  { key: "d1_30", label: "1–30 days overdue" },
  { key: "d31_60", label: "31–60 days overdue" },
  { key: "d61_90", label: "61–90 days overdue" },
  { key: "d90_plus", label: "Over 90 days overdue" },
];

export function agingBucketLabel(key: string | null | undefined): string {
  return AGING_BUCKETS.find((bucket) => bucket.key === key)?.label ?? "—";
}

export const INVOICE_STATUS_LABELS: Record<string, string> = {
  not_due: "Not due",
  due_today: "Due today",
  overdue: "Overdue",
  partially_paid: "Partially paid",
  paid: "Paid",
  disputed: "Disputed",
  written_off: "Written off",
  cancelled: "Cancelled",
};

export function invoiceStatusLabel(status: string): string {
  return INVOICE_STATUS_LABELS[status] ?? status;
}

export const PAYMENT_METHOD_LABELS: Record<string, string> = {
  cash: "Cash",
  bank_transfer: "Bank transfer",
  mobile_money: "Mobile money",
  cheque: "Cheque",
  online: "Online",
  other: "Other",
};

export function paymentMethodLabel(method: string): string {
  return PAYMENT_METHOD_LABELS[method] ?? method;
}

// ---------------------------------------------------------------------------
// Rows returned by the registers
// ---------------------------------------------------------------------------
export type InvoiceRow = {
  order_id: string;
  order_number: string;
  counterparty_id: string;
  counterparty_name: string;
  invoice_date: string;
  due_date: string | null;
  invoice_ghs: number | string;
  paid_ghs: number | string;
  outstanding_ghs: number | string;
  status: string;
  days_overdue: number | null;
  aging_bucket: string | null;
  total_count: number | string;
};

export type PaymentRow = {
  payment_id: string;
  paid_at: string;
  counterparty_id: string;
  counterparty_name: string;
  amount_ghs: number | string;
  method: string;
  reference: string | null;
  notes: string | null;
  recorded_by_email: string | null;
  allocated_ghs: number | string;
  unallocated_ghs: number | string;
  reversed_ghs: number | string;
  allocation_count: number;
  has_proof: boolean;
  total_count: number | string;
};

export type AgingSummaryRow = {
  bucket: string;
  invoices: number | string;
  outstanding_ghs: number | string;
};

const num = (value: number | string | null | undefined) => {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
};

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------
export type InvoiceFilters = {
  counterpartyId: string;
  status: string;
  bucket: string;
  invoiceFrom: string;
  invoiceTo: string;
  dueFrom: string;
  dueTo: string;
  minOutstanding: string;
  maxOutstanding: string;
  search: string;
};

export const EMPTY_INVOICE_FILTERS: InvoiceFilters = {
  counterpartyId: "",
  status: "",
  bucket: "",
  invoiceFrom: "",
  invoiceTo: "",
  dueFrom: "",
  dueTo: "",
  minOutstanding: "",
  maxOutstanding: "",
  search: "",
};

export function hasInvoiceFilters(filters: InvoiceFilters): boolean {
  return (Object.keys(EMPTY_INVOICE_FILTERS) as Array<keyof InvoiceFilters>).some(
    (key) => filters[key].trim() !== "",
  );
}

const blankToNull = (value: string) => (value.trim() === "" ? null : value.trim());
const numberOrNull = (value: string) => {
  if (value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
};

/** Arguments for credit_invoice_register(). Blank fields are sent as null (no filter). */
export function invoiceRegisterArgs(
  businessId: string,
  filters: InvoiceFilters,
  paging: { limit: number; offset: number },
) {
  return {
    p_business_id: businessId,
    p_counterparty_id: blankToNull(filters.counterpartyId),
    p_status: blankToNull(filters.status),
    p_bucket: blankToNull(filters.bucket),
    p_invoice_from: blankToNull(filters.invoiceFrom),
    p_invoice_to: blankToNull(filters.invoiceTo),
    p_due_from: blankToNull(filters.dueFrom),
    p_due_to: blankToNull(filters.dueTo),
    p_min_outstanding: numberOrNull(filters.minOutstanding),
    p_max_outstanding: numberOrNull(filters.maxOutstanding),
    p_search: blankToNull(filters.search),
    p_limit: paging.limit,
    p_offset: paging.offset,
  };
}

export type PaymentFilters = { counterpartyId: string; method: string; from: string; to: string };
export const EMPTY_PAYMENT_FILTERS: PaymentFilters = {
  counterpartyId: "",
  method: "",
  from: "",
  to: "",
};

export function paymentRegisterArgs(
  businessId: string,
  filters: PaymentFilters,
  paging: { limit: number; offset: number },
) {
  return {
    p_business_id: businessId,
    p_counterparty_id: blankToNull(filters.counterpartyId),
    p_from: blankToNull(filters.from),
    p_to: blankToNull(filters.to),
    p_method: blankToNull(filters.method),
    p_limit: paging.limit,
    p_offset: paging.offset,
  };
}

/** A message when a "from" date is after its "to" date, otherwise null. */
export function dateRangeProblem(from: string, to: string, label: string): string | null {
  return from && to && from > to ? `${label}: the start date is after the end date.` : null;
}

/** The first range problem in the invoice filters, or null. Min above max counts too. */
export function invoiceFilterProblem(filters: InvoiceFilters): string | null {
  const dates =
    dateRangeProblem(filters.invoiceFrom, filters.invoiceTo, "Invoice date") ??
    dateRangeProblem(filters.dueFrom, filters.dueTo, "Due date");
  if (dates) return dates;
  const min = numberOrNull(filters.minOutstanding);
  const max = numberOrNull(filters.maxOutstanding);
  if (min !== null && max !== null && min > max)
    return "Outstanding: the minimum is above the maximum.";
  return null;
}

/** Plain-language list of the filters in force, for exports and screen readers. */
export function describeInvoiceFilters(
  filters: InvoiceFilters,
  counterpartyName?: string,
): string[] {
  const out: string[] = [];
  if (filters.counterpartyId) out.push(`Party: ${counterpartyName ?? filters.counterpartyId}`);
  if (filters.status)
    out.push(
      `Status: ${invoiceStatusLabel(filters.status === "outstanding" ? "outstanding" : filters.status)}`,
    );
  if (filters.bucket) out.push(`Aging: ${agingBucketLabel(filters.bucket)}`);
  if (filters.invoiceFrom || filters.invoiceTo)
    out.push(`Invoice date: ${filters.invoiceFrom || "…"} to ${filters.invoiceTo || "…"}`);
  if (filters.dueFrom || filters.dueTo)
    out.push(`Due date: ${filters.dueFrom || "…"} to ${filters.dueTo || "…"}`);
  if (filters.minOutstanding || filters.maxOutstanding)
    out.push(`Outstanding: ${filters.minOutstanding || "0"} to ${filters.maxOutstanding || "any"}`);
  if (filters.search) out.push(`Search: ${filters.search}`);
  return out;
}

// ---------------------------------------------------------------------------
// Exports (numbers stay numbers in Excel; dates are ISO so they sort)
// ---------------------------------------------------------------------------
export type ExportSheet = { name: string; headers: string[]; rows: Array<Array<string | number>> };

export function invoiceExportSheet(rows: InvoiceRow[], side: AccountingSide): ExportSheet {
  return {
    name: SIDE_COPY[side].title,
    headers: [
      SIDE_COPY[side].party,
      "Invoice",
      "Invoice date",
      "Due date",
      "Original (GHS)",
      "Paid (GHS)",
      "Outstanding (GHS)",
      "Days overdue",
      "Aging",
      "Status",
    ],
    rows: rows.map((row) => [
      row.counterparty_name,
      row.order_number,
      row.invoice_date,
      row.due_date ?? "",
      num(row.invoice_ghs),
      num(row.paid_ghs),
      num(row.outstanding_ghs),
      row.days_overdue ?? "",
      agingBucketLabel(row.aging_bucket),
      invoiceStatusLabel(row.status),
    ]),
  };
}

export function agingExportSheet(summary: AgingSummaryRow[]): ExportSheet {
  return {
    name: "Aging",
    headers: ["Aging", "Invoices", "Outstanding (GHS)"],
    rows: AGING_BUCKETS.map(({ key, label }) => {
      const row = summary.find((item) => item.bucket === key);
      return [label, num(row?.invoices), num(row?.outstanding_ghs)];
    }),
  };
}

export function paymentExportSheet(rows: PaymentRow[], side: AccountingSide): ExportSheet {
  return {
    name: "Payments",
    headers: [
      "Paid on",
      SIDE_COPY[side].party,
      "Method",
      "Reference",
      "Amount (GHS)",
      "Allocated (GHS)",
      "Unallocated (GHS)",
      "Reversed (GHS)",
      "Recorded by",
      "Notes",
    ],
    rows: rows.map((row) => [
      row.paid_at.slice(0, 10),
      row.counterparty_name,
      paymentMethodLabel(row.method),
      row.reference ?? "",
      num(row.amount_ghs),
      num(row.allocated_ghs),
      num(row.unallocated_ghs),
      num(row.reversed_ghs),
      row.recorded_by_email ?? "",
      row.notes ?? "",
    ]),
  };
}

export const EXPORT_ROW_LIMIT = 2000;

// ---------------------------------------------------------------------------
// Credit account statements: the ledger between one wholesaler and one pharmacy over a date range.
// Every figure comes from credit_account_statement(); nothing is totalled here. These helpers shape
// the request, the wording of each line, the date presets and the exports.
// ---------------------------------------------------------------------------
export type StatementLine = {
  date: string;
  entry_type: string;
  order_id: string | null;
  order_number: string | null;
  method: string | null;
  reference: string | null;
  note: string | null;
  reversed_type: string | null;
  debit: number | string;
  credit: number | string;
  balance: number | string;
};

export type CreditStatement = {
  side: AccountingSide;
  business: { id: string; name: string; city: string | null; region: string | null };
  counterparty: { id: string; name: string; city: string | null; region: string | null };
  from: string;
  to: string;
  opening_balance: number | string;
  total_charges: number | string;
  total_credits: number | string;
  closing_balance: number | string;
  balance_today: number | string;
  line_count: number | string;
  truncated: boolean;
  aging_as_of: string;
  aging: AgingSummaryRow[];
  lines: StatementLine[];
};

export type CounterpartyOption = { counterparty_id: string; counterparty_name: string };

export const ENTRY_TYPE_LABELS: Record<string, string> = {
  invoice: "Invoice",
  payment: "Payment",
  adjustment: "Adjustment",
  credit_note: "Credit note",
  debit_note: "Debit note",
  write_off: "Write-off",
  reversal: "Reversal",
};

export function entryTypeLabel(type: string): string {
  return ENTRY_TYPE_LABELS[type] ?? type;
}

/** One plain-language line per ledger entry, e.g. "Payment (Bank transfer) BT-1 — ORD-100". */
export function statementLineDescription(line: StatementLine): string {
  const order = line.order_number ? ` — ${line.order_number}` : "";
  switch (line.entry_type) {
    case "invoice":
      return `Invoice${order}`;
    case "payment": {
      const method = line.method ? ` (${paymentMethodLabel(line.method)})` : "";
      const reference = line.reference ? ` ${line.reference}` : "";
      return `Payment${method}${reference}${line.order_number ? order : " — on account (not matched to an invoice)"}`;
    }
    case "reversal":
      return `Reversal of ${line.reversed_type ? entryTypeLabel(line.reversed_type).toLowerCase() : "an entry"}${order}`;
    default:
      return `${entryTypeLabel(line.entry_type)}${order}`;
  }
}

export function statementArgs(
  businessId: string,
  counterpartyId: string,
  from: string,
  to: string,
) {
  return {
    p_business_id: businessId,
    p_counterparty_id: counterpartyId,
    p_from: from,
    p_to: to,
  };
}

/** A message when the statement period is unusable, otherwise null. The database checks it again. */
export function statementPeriodProblem(from: string, to: string): string | null {
  if (!from || !to) return "Choose both a start and an end date.";
  if (from > to) return "The start date is after the end date.";
  const days = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
  if (days > 1830) return "A statement can cover at most five years.";
  return null;
}

const iso = (date: Date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;

export type StatementPreset = "this_month" | "last_month" | "last_90_days" | "this_year";

export const STATEMENT_PRESETS: Array<{ key: StatementPreset; label: string }> = [
  { key: "this_month", label: "This month" },
  { key: "last_month", label: "Last month" },
  { key: "last_90_days", label: "Last 90 days" },
  { key: "this_year", label: "This year" },
];

/** Date range for a preset, in the user's local calendar. `today` is a parameter so it can be tested. */
export function statementPresetRange(
  preset: StatementPreset,
  today: Date = new Date(),
): { from: string; to: string } {
  const year = today.getFullYear();
  const month = today.getMonth();
  switch (preset) {
    case "this_month":
      return { from: iso(new Date(year, month, 1)), to: iso(today) };
    case "last_month":
      return { from: iso(new Date(year, month - 1, 1)), to: iso(new Date(year, month, 0)) };
    case "last_90_days":
      return { from: iso(new Date(year, month, today.getDate() - 89)), to: iso(today) };
    case "this_year":
      return { from: iso(new Date(year, 0, 1)), to: iso(today) };
  }
}

/** The filename stem for a statement export, e.g. "statement-good-pharmacy-2026-09-01-to-2026-09-30". */
export function statementFilenameStem(statement: CreditStatement): string {
  const party =
    statement.counterparty.name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "account";
  return `statement-${party}-${statement.from}-to-${statement.to}`;
}

/** Sheets for an export. The first sheet is the statement itself (opening row, every line, closing
 * row), so a CSV, which only has one table, is a complete statement. Excel and PDF add the summary
 * and the ageing. */
export function statementExportSheets(statement: CreditStatement): ExportSheet[] {
  const lineCount = num(statement.line_count);
  const truncatedNote = statement.truncated
    ? `Showing the first ${statement.lines.length} of ${lineCount} lines. Choose a shorter period to see the rest.`
    : "";
  const lines: Array<Array<string | number>> = [
    [statement.from, "Opening balance", "", "", "", "", num(statement.opening_balance), ""],
    ...statement.lines.map((line): Array<string | number> => [
      line.date,
      entryTypeLabel(line.entry_type),
      // A payment is identified by its own reference; everything else by the invoice it touches.
      (line.entry_type === "payment"
        ? (line.reference ?? line.order_number)
        : (line.order_number ?? line.reference)) ?? "",
      statementLineDescription(line),
      num(line.debit) || "",
      num(line.credit) || "",
      num(line.balance),
      line.note ?? "",
    ]),
    [
      statement.to,
      "Closing balance",
      "",
      "",
      "",
      "",
      num(statement.closing_balance),
      truncatedNote,
    ],
  ];
  const party = SIDE_COPY[statement.side].party;
  const summary: Array<Array<string | number>> = [
    ["Account of", statement.business.name],
    [party, statement.counterparty.name],
    ["Period", `${statement.from} to ${statement.to}`],
    ["Opening balance (GHS)", num(statement.opening_balance)],
    ["Charges in period (GHS)", num(statement.total_charges)],
    ["Credits in period (GHS)", num(statement.total_credits)],
    ["Closing balance (GHS)", num(statement.closing_balance)],
    ["Balance today (GHS)", num(statement.balance_today)],
    ["Lines in period", lineCount],
  ];
  if (truncatedNote) summary.push(["Note", truncatedNote]);
  return [
    {
      name: "Statement",
      headers: [
        "Date",
        "Type",
        "Reference",
        "Description",
        "Charges (GHS)",
        "Credits (GHS)",
        "Balance (GHS)",
        "Notes",
      ],
      rows: lines,
    },
    { name: "Summary", headers: ["Item", "Value"], rows: summary },
    {
      ...agingExportSheet(statement.aging),
      name: `Aging as of ${statement.aging_as_of}`.slice(0, 31),
    },
  ];
}
