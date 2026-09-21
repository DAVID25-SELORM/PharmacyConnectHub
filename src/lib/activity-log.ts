// Shared helpers for the platform Activity Log (dashboard preview and /admin/activity).
// Raw `activity` strings in audit_logs are never rewritten; they are only mapped for display.

export type ActivityRow = {
  id: string;
  created_at: string;
  activity: string;
  organization: string | null;
  performed_by_email: string | null;
  record_type: string;
  record_id: string | null;
  record_label: string | null;
  details: unknown;
};

export type ActivityDetail = ActivityRow & {
  performed_by: string | null;
  ip_address: string | null;
};

export type ActivityCategory = "verification" | "orders" | "payments" | "staff" | "inventory";

export const ACTIVITY_CATEGORIES: Array<{ value: ActivityCategory; label: string }> = [
  { value: "verification", label: "Verification" },
  { value: "orders", label: "Orders" },
  { value: "payments", label: "Payments" },
  { value: "staff", label: "Staff" },
  { value: "inventory", label: "Inventory" },
];

const ORDER_EVENTS = new Set([
  "Order placed",
  "Order pending",
  "Order accepted",
  "Order packed",
  "Order dispatched",
  "Order delivered",
  "Order cancelled",
]);
const PAYMENT_EVENTS = new Set([
  "Payment unpaid",
  "Payment paid",
  "Payment refunded",
  "Payment failed",
]);
const STAFF_EVENTS = new Set([
  "Business staff invited",
  "Business staff updated",
  "Platform staff invited",
  "Platform staff updated",
]);

const VERIFICATION_EVENTS = new Set([
  "Pharmacy submitted",
  "Wholesaler submitted",
  "Business approved",
  "Business rejected",
  "Business verification updated",
  "Verification resubmitted",
]);

/** Mirrors the category patterns in admin_list_activity(). */
export function categorizeActivity(activity: string): ActivityCategory | "other" {
  if (VERIFICATION_EVENTS.has(activity)) return "verification";
  if (ORDER_EVENTS.has(activity)) return "orders";
  if (PAYMENT_EVENTS.has(activity)) return "payments";
  if (STAFF_EVENTS.has(activity)) return "staff";
  if (activity === "Inventory imported") return "inventory";
  return "other";
}

const DISPLAY_LABELS: Record<string, string> = {
  "Pharmacy submitted": "Verification submitted (pharmacy)",
  "Wholesaler submitted": "Verification submitted (wholesaler)",
  "Business staff invited": "Staff invited",
  "Business staff updated": "Staff updated",
  "Platform staff invited": "Platform staff invited",
  "Platform staff updated": "Platform staff updated",
  "Inventory imported": "Inventory imported",
};

export function activityLabel(activity: string) {
  return DISPLAY_LABELS[activity] ?? activity;
}

export function categoryLabel(activity: string) {
  const category = categorizeActivity(activity);
  return ACTIVITY_CATEGORIES.find((item) => item.value === category)?.label ?? "System";
}

/** Known event strings written by the database triggers, for the Event filter. */
export const KNOWN_ACTIVITY_OPTIONS: Array<{ value: string; label: string }> = [
  "Pharmacy submitted",
  "Wholesaler submitted",
  "Business approved",
  "Business rejected",
  "Business verification updated",
  "Verification resubmitted",
  "Order placed",
  "Order accepted",
  "Order packed",
  "Order dispatched",
  "Order delivered",
  "Order cancelled",
  "Payment paid",
  "Payment unpaid",
  "Payment refunded",
  "Payment failed",
  "Business staff invited",
  "Business staff updated",
  "Platform staff invited",
  "Platform staff updated",
  "Inventory imported",
].map((value) => ({ value, label: activityLabel(value) }));

// ---------------------------------------------------------------------------
// Sensitive metadata
// ---------------------------------------------------------------------------

const SENSITIVE_KEY =
  /(token|secret|password|passwd|authorization|api[_-]?key|service[_-]?role|smtp|credential|private[_-]?key|bearer|cookie)/i;

export const REDACTED = "[redacted]";

/** Display-layer safety net; the database already redacts these keys before returning rows. */
export function redactDetails(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactDetails);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
        key,
        SENSITIVE_KEY.test(key) ? REDACTED : redactDetails(entry),
      ]),
    );
  }
  return value;
}

export function humanizeKey(key: string) {
  const text = key.replace(/[_-]+/g, " ").trim();
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function formatScalar(value: unknown): string {
  if (value === null || value === undefined || value === "") return "";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** Flat, readable key/value rows for the detail drawer (objects flattened with dotted keys). */
export function detailRows(details: unknown): Array<{ key: string; value: string }> {
  const safe = redactDetails(details);
  if (!safe || typeof safe !== "object" || Array.isArray(safe)) {
    const text = formatScalar(safe);
    return text ? [{ key: "Details", value: text }] : [];
  }

  const rows: Array<{ key: string; value: string }> = [];
  const walk = (prefix: string, value: unknown) => {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
        walk(prefix ? `${prefix} ${key}` : key, entry);
      }
      return;
    }
    const text = formatScalar(value);
    if (text) rows.push({ key: humanizeKey(prefix), value: text });
  };
  walk("", safe);
  return rows;
}

/** One short line for tables: first few non-empty details, never raw JSON. */
export function summarizeDetails(details: unknown, maxItems = 3, maxLength = 90): string {
  const rows = detailRows(details).slice(0, maxItems);
  if (rows.length === 0) return "";
  const text = rows.map((row) => `${row.key}: ${row.value}`).join(" · ");
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}…` : text;
}

export function formatActivityTime(iso: string) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return date.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
}

export function shortId(id: string | null | undefined, length = 8) {
  if (!id) return "";
  return id.length > length ? `${id.slice(0, length)}…` : id;
}

export function actorLabel(email: string | null | undefined) {
  return email && email.trim() ? email : "System";
}

// ---------------------------------------------------------------------------
// Filters, URL state and RPC arguments
// ---------------------------------------------------------------------------

export type ActivityRange = "today" | "7d" | "30d" | "custom";

export type ActivityFilters = {
  q: string;
  category: ActivityCategory | "";
  event: string;
  org: string;
  orgType: "pharmacy" | "wholesaler" | "";
  actor: string;
  range: ActivityRange | "";
  from: string; // yyyy-mm-dd (UTC day)
  to: string; // yyyy-mm-dd (UTC day, inclusive)
  limit: 25 | 50 | 100;
};

export const EMPTY_FILTERS: ActivityFilters = {
  q: "",
  category: "",
  event: "",
  org: "",
  orgType: "",
  actor: "",
  range: "",
  from: "",
  to: "",
  limit: 50,
};

const RANGES: ActivityRange[] = ["today", "7d", "30d", "custom"];
const ORG_TYPES = ["pharmacy", "wholesaler"] as const;
const LIMITS = [25, 50, 100] as const;
const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

function text(value: unknown, max = 120) {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

/** Coerces untrusted URL search params into a valid filter set. */
export function parseActivitySearch(search: Record<string, unknown>): ActivityFilters {
  const category = text(search.category) as ActivityCategory;
  const orgType = text(search.orgType) as ActivityFilters["orgType"];
  const range = text(search.range) as ActivityRange;
  const limit = Number(search.limit);
  const from = text(search.from, 10);
  const to = text(search.to, 10);

  return {
    q: text(search.q),
    category: ACTIVITY_CATEGORIES.some((item) => item.value === category) ? category : "",
    event: text(search.event),
    org: text(search.org),
    orgType: (ORG_TYPES as readonly string[]).includes(orgType) ? orgType : "",
    actor: text(search.actor),
    range: RANGES.includes(range) ? range : "",
    from: DATE_ONLY.test(from) ? from : "",
    to: DATE_ONLY.test(to) ? to : "",
    limit: (LIMITS as readonly number[]).includes(limit) ? (limit as ActivityFilters["limit"]) : 50,
  };
}

/** Only non-default values are written to the URL. No secrets ever go in query parameters. */
export function activityFiltersToSearch(filters: ActivityFilters): Record<string, string | number> {
  const search: Record<string, string | number> = {};
  if (filters.q) search.q = filters.q;
  if (filters.category) search.category = filters.category;
  if (filters.event) search.event = filters.event;
  if (filters.org) search.org = filters.org;
  if (filters.orgType) search.orgType = filters.orgType;
  if (filters.actor) search.actor = filters.actor;
  if (filters.range) search.range = filters.range;
  if (filters.range === "custom") {
    if (filters.from) search.from = filters.from;
    if (filters.to) search.to = filters.to;
  }
  if (filters.limit !== 50) search.limit = filters.limit;
  return search;
}

export function hasActiveFilters(filters: ActivityFilters) {
  return Object.keys(activityFiltersToSearch({ ...filters, limit: 50 })).length > 0;
}

/** Stable key: changing any filter changes it, which resets the pagination cursor. */
export function filterKey(filters: ActivityFilters) {
  return JSON.stringify(activityFiltersToSearch(filters));
}

export type ActivityCursor = { created_at: string; id: string } | null;

function nextDay(date: string) {
  const d = new Date(`${date}T00:00:00.000Z`);
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString();
}

/** Arguments for admin_list_activity. The RPC returns up to limit + 1 rows so "has next page" is known. */
export function buildActivityRpcArgs(
  filters: ActivityFilters,
  cursor: ActivityCursor,
  limit: number = filters.limit,
) {
  const custom = filters.range === "custom";
  return {
    p_search: filters.q.length >= 2 ? filters.q : null,
    p_category: filters.category || null,
    p_activity: filters.event || null,
    p_organization: filters.org || null,
    p_org_type: filters.orgType || null,
    p_actor: filters.actor || null,
    p_range: filters.range || null,
    p_from: custom && filters.from ? `${filters.from}T00:00:00.000Z` : null,
    p_to: custom && filters.to ? nextDay(filters.to) : null,
    p_cursor_created_at: cursor?.created_at ?? null,
    p_cursor_id: cursor?.id ?? null,
    p_limit: limit,
  };
}

/** Splits the fetched rows into the visible page and the cursor for the next one. */
export function paginate(rows: ActivityRow[], limit: number) {
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

export const EXPORT_ROW_LIMIT = 5000;

function csvCell(value: unknown) {
  const raw = value === null || value === undefined ? "" : String(value);
  // Neutralise spreadsheet formula injection.
  const safe = /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw;
  return `"${safe.replace(/"/g, '""')}"`;
}

export function activityToCsv(rows: ActivityRow[]) {
  const header = ["Time (UTC)", "Event", "Category", "Organization", "Actor", "Record", "Details"];
  const lines = rows.map((row) =>
    [
      row.created_at,
      activityLabel(row.activity),
      categoryLabel(row.activity),
      row.organization ?? "",
      actorLabel(row.performed_by_email),
      row.record_label ?? row.record_type,
      summarizeDetails(row.details, 6, 300),
    ]
      .map(csvCell)
      .join(","),
  );
  return [header.map(csvCell).join(","), ...lines].join("\r\n");
}
