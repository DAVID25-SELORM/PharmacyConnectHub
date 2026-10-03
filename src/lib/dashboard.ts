// Pure helpers behind the pharmacy / wholesaler dashboard overview. Every figure is derived from
// rows the database has already scoped to the viewer's business (RLS or a permission-checked RPC);
// nothing here widens access, it only decides what to show a given staff role.

import type { BusinessStaffRole } from "@/hooks/use-session";

export type DashboardAccess = {
  /** Credit balances, overdue invoices, receivables / payables. */
  finance: boolean;
  /** Stock levels and expiry. */
  inventory: boolean;
  /** RFQs and quotations. */
  rfq: boolean;
  /** The business audit log (owner / manager / accountant -- same gate as list_audit_log). */
  activity: boolean;
};

const has = (role: BusinessStaffRole | undefined, allowed: BusinessStaffRole[]) =>
  role !== undefined && allowed.includes(role);

export function pharmacyDashboardAccess(role: BusinessStaffRole | undefined): DashboardAccess {
  return {
    finance: has(role, ["owner", "manager", "finance", "accountant"]),
    inventory: has(role, ["owner", "manager", "cashier", "warehouse"]),
    rfq: has(role, ["owner", "manager", "cashier"]),
    activity: has(role, ["owner", "manager", "accountant"]),
  };
}

export function wholesalerDashboardAccess(role: BusinessStaffRole | undefined): DashboardAccess {
  return {
    finance: has(role, ["owner", "manager", "finance", "accountant"]),
    inventory: has(role, ["owner", "manager", "warehouse"]),
    rfq: has(role, ["owner", "manager", "cashier", "warehouse"]),
    activity: has(role, ["owner", "manager", "accountant"]),
  };
}

const DAY_MS = 86_400_000;

/** Whole days from `today` (local midnight) to a yyyy-mm-dd date; negative when in the past. */
export function daysUntil(date: string, today: Date = new Date()): number {
  const start = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime();
  const [y, m, d] = date.slice(0, 10).split("-").map(Number);
  return Math.round((new Date(y, m - 1, d).getTime() - start) / DAY_MS);
}

export type CreditInvoiceRow = {
  due_date: string | null;
  outstanding_ghs: number | string;
  status: string;
};

export type CreditSummary = {
  outstanding: number;
  invoiceCount: number;
  overdueCount: number;
  overdueTotal: number;
  dueSoonCount: number;
  dueSoonTotal: number;
};

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;
const owed = (row: CreditInvoiceRow) => Number(row.outstanding_ghs) || 0;

function isOverdue(row: CreditInvoiceRow, today: Date) {
  if (row.status === "overdue") return true;
  return row.due_date !== null && daysUntil(row.due_date, today) < 0;
}

/** Totals for the rows list_credit_invoices returns with status "outstanding" (everything still
 * owed, including disputed invoices). "Due soon" means due within the next 7 days. */
export function summariseCredit(rows: CreditInvoiceRow[], today: Date = new Date()): CreditSummary {
  const summary: CreditSummary = {
    outstanding: 0,
    invoiceCount: 0,
    overdueCount: 0,
    overdueTotal: 0,
    dueSoonCount: 0,
    dueSoonTotal: 0,
  };
  for (const row of rows) {
    const amount = owed(row);
    if (amount <= 0) continue;
    summary.outstanding += amount;
    summary.invoiceCount += 1;
    if (isOverdue(row, today)) {
      summary.overdueCount += 1;
      summary.overdueTotal += amount;
    } else if (row.due_date !== null && daysUntil(row.due_date, today) <= 7) {
      summary.dueSoonCount += 1;
      summary.dueSoonTotal += amount;
    }
  }
  summary.outstanding = money(summary.outstanding);
  summary.overdueTotal = money(summary.overdueTotal);
  summary.dueSoonTotal = money(summary.dueSoonTotal);
  return summary;
}

export type AgingBucket = { label: string; total: number; count: number };

/** Outstanding balances grouped by how late they are. Invoices with no due date count as not yet due. */
export function agingBuckets(rows: CreditInvoiceRow[], today: Date = new Date()): AgingBucket[] {
  const buckets: AgingBucket[] = [
    { label: "Not yet due", total: 0, count: 0 },
    { label: "1–30 days late", total: 0, count: 0 },
    { label: "31–60 days late", total: 0, count: 0 },
    { label: "Over 60 days late", total: 0, count: 0 },
  ];
  for (const row of rows) {
    const amount = owed(row);
    if (amount <= 0) continue;
    const late = row.due_date ? -daysUntil(row.due_date, today) : 0;
    const index = late <= 0 ? 0 : late <= 30 ? 1 : late <= 60 ? 2 : 3;
    buckets[index].total += amount;
    buckets[index].count += 1;
  }
  return buckets.map((bucket) => ({ ...bucket, total: money(bucket.total) }));
}

export type InventoryRow = {
  stock: number;
  reorder_level: number | null;
  expiry_date: string | null;
};

export type InventoryCounts = { lowStock: number; outOfStock: number; expiringSoon: number };

export const EXPIRING_SOON_DAYS = 30;

/** Out of stock and low stock are disjoint (an empty shelf is "out", not also "low"). Expiring soon
 * includes anything already past its expiry date. */
export function inventoryCounts(rows: InventoryRow[], today: Date = new Date()): InventoryCounts {
  const counts: InventoryCounts = { lowStock: 0, outOfStock: 0, expiringSoon: 0 };
  for (const row of rows) {
    if (row.stock <= 0) counts.outOfStock += 1;
    else if (row.reorder_level !== null && row.stock <= row.reorder_level) counts.lowStock += 1;
    if (row.expiry_date && daysUntil(row.expiry_date, today) <= EXPIRING_SOON_DAYS)
      counts.expiringSoon += 1;
  }
  return counts;
}

export type RfqLite = { id: string; response_deadline: string | null };

/** Open RFQs whose response deadline falls within the next `days` days (and hasn't already passed). */
export function rfqsClosingSoon(rfqs: RfqLite[], days = 3, now: Date = new Date()): number {
  return rfqs.filter((rfq) => {
    if (!rfq.response_deadline) return false;
    const left = (new Date(rfq.response_deadline).getTime() - now.getTime()) / DAY_MS;
    return left >= 0 && left <= days;
  }).length;
}

export type AttentionTone = "danger" | "warning" | "info";

export type AttentionItem = {
  key: string;
  label: string;
  detail: string;
  count: number;
  tone: AttentionTone;
  to: string;
  search?: Record<string, string>;
};

/** Keeps only items with something to act on, most urgent tone first, stable within a tone. */
export function sortAttention(items: AttentionItem[]): AttentionItem[] {
  const rank: Record<AttentionTone, number> = { danger: 0, warning: 1, info: 2 };
  return items
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => item.count > 0)
    .sort((a, b) => rank[a.item.tone] - rank[b.item.tone] || a.index - b.index)
    .map(({ item }) => item);
}
