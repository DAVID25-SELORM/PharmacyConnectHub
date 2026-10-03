// Shared helpers for the Reports module (Platform, Pharmacy, Wholesaler).
// Every report is server-side filtered and aggregated; these helpers only shape requests and
// format results — they never total up raw rows in the browser.

export type ReportRange =
  | "today"
  | "this_week"
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
  { value: "this_week", label: "This week" },
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
  // Genuine numbers (e.g. a -12.50 adjustment) stay numeric; only text that could be read as a
  // formula is neutralised.
  const safe = typeof value !== "number" && /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw;
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

export function reportFilename(prefix: string, ext: "csv" | "xlsx" | "pdf" = "csv") {
  return `drugxone-${prefix}-${new Date().toISOString().slice(0, 10)}.${ext}`;
}

// ---------------------------------------------------------------------------
// XLSX export — same headers/rows shape as the CSV path, reusing the "xlsx" package
// already bundled for product import (src/lib/product-import.ts), lazy-loaded the same way
// so it stays in its own code-split chunk and never loads on a page that doesn't export.
// ---------------------------------------------------------------------------

type XlsxModule = typeof import("xlsx");
let xlsxModulePromise: Promise<XlsxModule> | null = null;
function loadXlsx() {
  xlsxModulePromise ??= import("xlsx");
  return xlsxModulePromise;
}

export type ReportExportSheet = {
  name: string;
  headers: string[];
  rows: Array<Array<string | number>>;
};

export async function downloadXlsx(filename: string, sheets: ReportExportSheet[]) {
  const XLSX = await loadXlsx();
  const workbook = XLSX.utils.book_new();
  for (const sheet of sheets) {
    const worksheet = XLSX.utils.aoa_to_sheet([sheet.headers, ...sheet.rows]);
    // Excel sheet names are capped at 31 characters.
    XLSX.utils.book_append_sheet(workbook, worksheet, sheet.name.slice(0, 31));
  }
  XLSX.writeFile(workbook, filename);
}

// ---------------------------------------------------------------------------
// PDF export — one table per sheet, lazy-loaded (jspdf + jspdf-autotable) the same way as the
// xlsx package above, so neither loads on a page that doesn't export. Landscape by default since
// these tables are usually wider than they are tall; callers should keep to a handful of columns
// that still print legibly rather than dumping every field.
// ---------------------------------------------------------------------------

let pdfModulePromise: Promise<{ jsPDF: typeof import("jspdf").default; autoTable: typeof import("jspdf-autotable").autoTable }> | null = null;
function loadPdf() {
  pdfModulePromise ??= Promise.all([import("jspdf"), import("jspdf-autotable")]).then(([jspdfMod, autoTableMod]) => ({
    jsPDF: jspdfMod.default,
    autoTable: autoTableMod.autoTable,
  }));
  return pdfModulePromise;
}

export async function downloadPdf(filename: string, title: string, sheets: ReportExportSheet[]) {
  const { jsPDF, autoTable } = await loadPdf();
  const doc = new jsPDF({ orientation: "landscape" });
  sheets.forEach((sheet, index) => {
    if (index > 0) doc.addPage();
    doc.setFontSize(14);
    doc.text(sheets.length > 1 ? `${title} — ${sheet.name}` : title, 14, 15);
    doc.setFontSize(9);
    doc.text(new Date().toLocaleString("en-GB"), 14, 21);
    autoTable(doc, {
      head: [sheet.headers],
      body: sheet.rows.map((row) => row.map(String)),
      startY: 26,
      styles: { fontSize: 8, cellPadding: 2 },
      headStyles: { fillColor: [15, 118, 110] },
    });
  });
  doc.save(filename);
}

/** What a report tab's exportRef hands back: the same data the CSV and XLSX exports both
 * render from. `filenamePrefix` excludes the extension — reportFilename() adds it per format.
 * Most tabs export a single table (`headers`/`rows`); a tab combining several tables (e.g. two
 * side-by-side breakdowns) uses `sheets` instead — CSV then downloads one file per sheet (it has
 * no multi-table format of its own), XLSX puts them together as separate sheets in one workbook.
 * A tab returns null when there's nothing to export yet (e.g. data still loading). */
export type ReportExportPayload =
  | { filenamePrefix: string; headers: string[]; rows: Array<Array<string | number>> }
  | { filenamePrefix: string; sheets: ReportExportSheet[] }
  | null;

export function reportExportSheets(payload: NonNullable<ReportExportPayload>): ReportExportSheet[] {
  return "sheets" in payload
    ? payload.sheets
    : [{ name: "Report", headers: payload.headers, rows: payload.rows }];
}

/** Pure planning step for the CSV path: one {filename, csv} per sheet. A single-sheet payload
 * keeps the plain filenamePrefix; a multi-sheet one suffixes each file with its sheet name, since
 * CSV has no multi-table format of its own to fall back on. */
export function reportCsvExports(
  payload: NonNullable<ReportExportPayload>,
): Array<{ filename: string; csv: string }> {
  const sheets = reportExportSheets(payload);
  return sheets.map((sheet) => {
    const suffix = sheets.length > 1 ? `-${sheet.name.toLowerCase().replace(/\s+/g, "-")}` : "";
    return {
      filename: reportFilename(`${payload.filenamePrefix}${suffix}`, "csv"),
      csv: rowsToCsv(sheet.headers, sheet.rows),
    };
  });
}

/** Shared "export" button handler for every Reports page: takes whatever the active tab's
 * exportRef currently returns and renders it as the requested format. A no-op when there's
 * nothing to export yet. */
export function exportReportPayload(payload: ReportExportPayload, ext: "csv" | "xlsx") {
  if (!payload) return;
  if (ext === "xlsx") {
    void downloadXlsx(reportFilename(payload.filenamePrefix, "xlsx"), reportExportSheets(payload));
    return;
  }
  for (const { filename, csv } of reportCsvExports(payload)) downloadCsv(filename, csv);
}
