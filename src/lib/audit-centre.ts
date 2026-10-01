// Shared helpers for the business-scoped Audit Centre (/pharmacy/audit, /wholesaler/audit).
// Backed by list_audit_log(), which only returns rows already tagged with the viewer's business_id
// (RFQ actions, credit ledger actions, and the two product-catalog import flows -- see
// 20261011100000_audit_centre_schema.sql for which older call sites are NOT yet tagged and so won't
// appear here). Reuses the already-tested, generic formatting helpers from activity-log.ts; does not
// touch that file's category/label maps, which are specific to the admin-only platform-wide page.
import {
  actorLabel,
  detailRows,
  formatActivityTime,
  redactDetails,
  shortId,
  summarizeDetails,
} from "@/lib/activity-log";

export { actorLabel, detailRows, formatActivityTime, redactDetails, shortId, summarizeDetails };

export type AuditLogRow = {
  id: string;
  created_at: string;
  activity: string;
  record_type: string;
  record_id: string | null;
  record_label: string | null;
  performed_by_email: string | null;
  details: unknown;
};

const DISPLAY_LABELS: Record<string, string> = {
  "RFQ created": "RFQ created",
  "RFQ cancelled": "RFQ cancelled",
  "RFQ awarded": "RFQ awarded",
  "RFQ quote submitted": "Quote submitted",
  "RFQ quote withdrawn": "Quote withdrawn",
  "Credit payment recorded": "Payment recorded",
  "Credit ledger adjustment recorded": "Ledger adjustment",
  "Credit invoice written off": "Invoice written off",
  "Credit ledger entry reversed": "Ledger entry reversed",
  "Credit invoice disputed": "Invoice disputed",
  "Credit invoice dispute cleared": "Dispute cleared",
  "Pharmacy inventory imported": "Inventory imported",
  "Inventory imported": "Catalog imported",
  "Pharmacy submitted": "Verification submitted",
  "Wholesaler submitted": "Verification submitted",
  "Business approved": "Business approved",
  "Business rejected": "Business rejected",
  "Business verification updated": "Verification updated",
};

export function auditActivityLabel(activity: string) {
  return DISPLAY_LABELS[activity] ?? activity;
}

type AuditCategory = "rfq" | "credit" | "inventory" | "verification" | "other";

const RFQ_EVENTS = new Set([
  "RFQ created",
  "RFQ cancelled",
  "RFQ awarded",
  "RFQ quote submitted",
  "RFQ quote withdrawn",
]);
const CREDIT_EVENTS = new Set([
  "Credit payment recorded",
  "Credit ledger adjustment recorded",
  "Credit invoice written off",
  "Credit ledger entry reversed",
  "Credit invoice disputed",
  "Credit invoice dispute cleared",
]);
const INVENTORY_EVENTS = new Set(["Pharmacy inventory imported", "Inventory imported"]);
const VERIFICATION_EVENTS = new Set([
  "Pharmacy submitted",
  "Wholesaler submitted",
  "Business approved",
  "Business rejected",
  "Business verification updated",
]);

export function auditCategory(activity: string): AuditCategory {
  if (RFQ_EVENTS.has(activity)) return "rfq";
  if (CREDIT_EVENTS.has(activity)) return "credit";
  if (INVENTORY_EVENTS.has(activity)) return "inventory";
  if (VERIFICATION_EVENTS.has(activity)) return "verification";
  return "other";
}

const CATEGORY_LABELS: Record<AuditCategory, string> = {
  rfq: "RFQ",
  credit: "Credit",
  inventory: "Inventory",
  verification: "Verification",
  other: "Other",
};

export function auditCategoryLabel(activity: string) {
  return CATEGORY_LABELS[auditCategory(activity)];
}

export const RECORD_TYPE_OPTIONS: Array<{ value: string; label: string }> = [
  { value: "rfq", label: "RFQ" },
  { value: "rfq_quote", label: "RFQ quote" },
  { value: "business", label: "Business / credit" },
  { value: "order", label: "Order / invoice" },
  { value: "pharmacy_inventory_item", label: "Inventory item" },
  { value: "product", label: "Product" },
];

// ---------------------------------------------------------------------------
// Filters, URL state and RPC arguments
// ---------------------------------------------------------------------------

export type AuditRange = "today" | "7d" | "30d" | "custom";

export type AuditFilters = {
  q: string;
  recordType: string;
  range: AuditRange | "";
  from: string; // yyyy-mm-dd
  to: string; // yyyy-mm-dd, inclusive
  limit: 25 | 50 | 100;
};

export const EMPTY_AUDIT_FILTERS: AuditFilters = {
  q: "",
  recordType: "",
  range: "",
  from: "",
  to: "",
  limit: 50,
};

const RANGES: AuditRange[] = ["today", "7d", "30d", "custom"];
const LIMITS = [25, 50, 100] as const;
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const RECORD_TYPES = new Set(RECORD_TYPE_OPTIONS.map((o) => o.value));

function text(value: unknown, max = 120) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

export function parseAuditSearch(search: Record<string, unknown>): AuditFilters {
  const recordType = text(search.recordType);
  const range = text(search.range) as AuditRange;
  const limit = Number(search.limit);
  const from = text(search.from, 10);
  const to = text(search.to, 10);

  return {
    q: text(search.q),
    recordType: RECORD_TYPES.has(recordType) ? recordType : "",
    range: RANGES.includes(range) ? range : "",
    from: DATE_ONLY.test(from) ? from : "",
    to: DATE_ONLY.test(to) ? to : "",
    limit: (LIMITS as readonly number[]).includes(limit) ? (limit as AuditFilters["limit"]) : 50,
  };
}

export function auditFiltersToSearch(filters: AuditFilters): Record<string, string | number> {
  const search: Record<string, string | number> = {};
  if (filters.q) search.q = filters.q;
  if (filters.recordType) search.recordType = filters.recordType;
  if (filters.range) search.range = filters.range;
  if (filters.range === "custom") {
    if (filters.from) search.from = filters.from;
    if (filters.to) search.to = filters.to;
  }
  if (filters.limit !== 50) search.limit = filters.limit;
  return search;
}

export function hasActiveAuditFilters(filters: AuditFilters) {
  return Object.keys(auditFiltersToSearch({ ...filters, limit: 50 })).length > 0;
}

export function auditFilterKey(filters: AuditFilters) {
  return JSON.stringify(auditFiltersToSearch(filters));
}

export type AuditCursor = { created_at: string; id: string } | null;

function nextDay(date: string) {
  const d = new Date(`${date}T00:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString();
}

function rangeStart(range: AuditRange) {
  if (range === "today") return new Date(new Date().toISOString().slice(0, 10) + "T00:00:00.000Z").toISOString();
  if (range === "7d") return new Date(Date.now() - 7 * 86400_000).toISOString();
  if (range === "30d") return new Date(Date.now() - 30 * 86400_000).toISOString();
  return null;
}

/** Arguments for list_audit_log. The RPC returns up to limit + 1 rows so "has next page" is known. */
export function buildAuditRpcArgs(
  businessId: string,
  filters: AuditFilters,
  cursor: AuditCursor,
  limit: number = filters.limit,
) {
  const custom = filters.range === "custom";
  return {
    p_business_id: businessId,
    p_from: custom ? (filters.from ? `${filters.from}T00:00:00.000Z` : null) : rangeStart(filters.range as AuditRange),
    p_to: custom && filters.to ? nextDay(filters.to) : null,
    p_record_type: filters.recordType || null,
    p_search: filters.q.length >= 2 ? filters.q : null,
    p_cursor_created_at: cursor?.created_at ?? null,
    p_cursor_id: cursor?.id ?? null,
    p_limit: limit,
  };
}

export function paginate(rows: AuditLogRow[], limit: number) {
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  return {
    page,
    hasMore: rows.length > limit,
    nextCursor: rows.length > limit && last ? { created_at: last.created_at, id: last.id } : null,
  };
}

// ---------------------------------------------------------------------------
// CSV export (filtered, capped)
// ---------------------------------------------------------------------------

export const AUDIT_EXPORT_ROW_LIMIT = 5000;

function csvCell(value: unknown) {
  const raw = value === null || value === undefined ? "" : String(value);
  const safe = /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw;
  return `"${safe.replace(/"/g, '""')}"`;
}

export function auditLogToCsv(rows: AuditLogRow[]) {
  const header = ["Time (UTC)", "Event", "Category", "Actor", "Record", "Details"];
  const lines = rows.map((row) =>
    [
      row.created_at,
      auditActivityLabel(row.activity),
      auditCategoryLabel(row.activity),
      actorLabel(row.performed_by_email),
      row.record_label ?? row.record_type,
      summarizeDetails(row.details, 6, 300),
    ]
      .map(csvCell)
      .join(","),
  );
  return [header.map(csvCell).join(","), ...lines].join("\r\n");
}
