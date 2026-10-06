// Pure helpers behind the pharmacy / wholesaler dashboard overview. Every figure is derived from
// rows the database has already scoped to the viewer's business (RLS or a permission-checked RPC);
// nothing here widens access, it only decides what to show a given staff role.

import type { BusinessStaffRole } from "@/hooks/use-session";
import { canViewAccounting } from "@/lib/accounting";

export type DashboardAccess = {
  /** Credit balances, overdue invoices, receivables / payables. Exactly who can open Accounting. */
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
    finance: canViewAccounting("pharmacy", role),
    inventory: has(role, ["owner", "manager", "cashier", "warehouse"]),
    rfq: has(role, ["owner", "manager", "cashier"]),
    activity: has(role, ["owner", "manager", "accountant"]),
  };
}

export function wholesalerDashboardAccess(role: BusinessStaffRole | undefined): DashboardAccess {
  return {
    finance: canViewAccounting("wholesaler", role),
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

/** What accounting_overview() returns. Every figure is computed in the database, with the same invoices,
 * outstanding balances and aging rule as the Accounting registers; nothing here totals money. */
export type AccountingOverview = {
  side: "wholesaler" | "pharmacy";
  as_of: string;
  outstanding_ghs: number | string;
  invoice_count: number | string;
  overdue_ghs: number | string;
  overdue_count: number | string;
  due_soon_ghs: number | string;
  due_soon_count: number | string;
  disputed_ghs: number | string;
  disputed_count: number | string;
  aging: Array<{ bucket: string; invoices: number | string; outstanding_ghs: number | string }>;
  top_overdue: Array<{
    counterparty_id: string;
    counterparty_name: string;
    overdue_ghs: number | string;
    invoices: number | string;
    oldest_days_overdue: number | string;
  }>;
  payments_30d: { count: number | string; total_ghs: number | string };
  on_account: { total_ghs: number | string; parties: number | string };
};

export type AgingBucket = { label: string; total: number; count: number };

export type CreditSummary = {
  outstanding: number;
  invoiceCount: number;
  overdueCount: number;
  overdueTotal: number;
  dueSoonCount: number;
  dueSoonTotal: number;
};

/** The headline figures as plain numbers. "Due soon" is due from today up to 7 days ahead and not yet overdue. */
export function overviewSummary(overview: AccountingOverview): CreditSummary {
  return {
    outstanding: Number(overview.outstanding_ghs),
    invoiceCount: Number(overview.invoice_count),
    overdueCount: Number(overview.overdue_count),
    overdueTotal: Number(overview.overdue_ghs),
    dueSoonCount: Number(overview.due_soon_count),
    dueSoonTotal: Number(overview.due_soon_ghs),
  };
}

/** Short labels for the chart's axis (days past the due date); the five buckets are defined once, in the database. */
const CHART_BUCKETS: Array<{ key: string; label: string }> = [
  { key: "current", label: "Not yet due" },
  { key: "d1_30", label: "1–30 days" },
  { key: "d31_60", label: "31–60 days" },
  { key: "d61_90", label: "61–90 days" },
  { key: "d90_plus", label: "Over 90" },
];

/** The aging chart's bars from the overview: always all five buckets, zero where nothing is owed. */
export function overviewAging(overview: AccountingOverview | null | undefined): AgingBucket[] {
  return CHART_BUCKETS.map(({ key, label }) => {
    const row = overview?.aging.find((item) => item.bucket === key);
    return { label, total: Number(row?.outstanding_ghs ?? 0), count: Number(row?.invoices ?? 0) };
  });
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
