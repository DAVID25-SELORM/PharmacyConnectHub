// Shared helpers for the Reports module (Platform, Pharmacy, Wholesaler).
// Every report is server-side filtered and aggregated; these helpers only shape requests and
// format results — they never total up raw rows in the browser.

export type ReportRange =
  | "today"
  | "7d"
  | "30d"
  | "this_month"
  | "last_month"
  | "this_quarter"
  | "this_year"
  | "custom"
  | "all";

export const REPORT_RANGES: Array<{ value: ReportRange; label: string }> = [
  { value: "today", label: "Today" },
  { value: "7d", label: "Last 7 days" },
  { value: "30d", label: "Last 30 days" },
  { value: "this_month", label: "This month" },
  { value: "last_month", label: "Last month" },
  { value: "this_quarter", label: "This quarter" },
  { value: "this_year", label: "This year" },
  { value: "all", label: "All time" },
  { value: "custom", label: "Custom range" },
];

export type ReportRangeState = {
  range: ReportRange;
  from: string; // yyyy-mm-dd, custom only
  to: string; // yyyy-mm-dd, custom only (inclusive)
};

export const DEFAULT_RANGE: ReportRangeState = { range: "all", from: "", to: "" };

/** Arguments the resolve_report_range() RPC/DB helper expects. */
export function rangeToRpcArgs(state: ReportRangeState) {
  const custom = state.range === "custom";
  return {
    p_range: state.range,
    p_from: custom && state.from ? `${state.from}T00:00:00.000Z` : null,
    p_to: custom && state.to ? `${state.to}T23:59:59.999Z` : null,
  };
}

export function formatGHSCell(value: number | string | null | undefined) {
  const n = Number(value ?? 0);
  return `GHS ${n.toLocaleString("en-GH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function formatReportDate(iso: string | null | undefined) {
  if (!iso) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
}

export function formatReportDateTime(iso: string | null | undefined) {
  if (!iso) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
}

// ---------------------------------------------------------------------------
// CSV export — generic, reused by every report table. Same formula-injection and
// quote-escaping protections as the Activity Log export.
// ---------------------------------------------------------------------------

function csvCell(value: unknown) {
  const raw = value === null || value === undefined ? "" : String(value);
  const safe = /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw;
  return `"${safe.replace(/"/g, '""')}"`;
}

export function rowsToCsv(headers: string[], rows: Array<Array<string | number>>) {
  const lines = rows.map((row) => row.map(csvCell).join(","));
  return [headers.map(csvCell).join(","), ...lines].join("\r\n");
}

export function downloadCsv(filename: string, csv: string) {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}

export function reportFilename(prefix: string) {
  return `drugxone-${prefix}-${new Date().toISOString().slice(0, 10)}.csv`;
}
