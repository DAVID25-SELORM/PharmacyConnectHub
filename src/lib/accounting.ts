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
