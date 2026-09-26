import { formatGHSCell, formatReportDate, rowsToCsv } from "@/lib/reports";

export type StatementLine = {
  date: string;
  kind: "order" | "payment" | "return";
  order_id: string;
  order_number: string;
  debit: number;
  credit: number;
  discount: number;
  balance: number;
};

export type Statement = {
  wholesaler: { id: string; name: string; city: string | null; region: string | null };
  pharmacy: { id: string; name: string; city: string | null; region: string | null };
  from: string;
  to: string;
  opening_balance: number;
  total_debits: number;
  total_credits: number;
  closing_balance: number;
  line_count: number;
  truncated: boolean;
  lines: StatementLine[];
};

export const SEGMENT_LABELS: Record<string, string> = {
  new: "New",
  active: "Active",
  high_value: "High value",
  dormant: "Dormant",
  discount: "Discount customer",
};

export function lineDescription(line: Pick<StatementLine, "kind" | "order_number">) {
  if (line.kind === "order") return `Order ${line.order_number}`;
  if (line.kind === "return") return `Return credited ${line.order_number}`;
  return `Payment received for ${line.order_number}`;
}

/** yyyy-mm-dd inputs -> [from, to) timestamps; the end date is inclusive for the person choosing it. */
export function statementRange(fromDate: string, toDate: string) {
  const from = new Date(`${fromDate}T00:00:00`);
  const to = new Date(`${toDate}T00:00:00`);
  if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime())) return null;
  to.setDate(to.getDate() + 1);
  if (from >= to) return null;
  return { from: from.toISOString(), to: to.toISOString() };
}

export function statementToCsv(statement: Statement) {
  const money = (value: number) => Number(value).toFixed(2);
  const rows: Array<Array<string | number>> = [
    ["", "Opening balance", "", "", money(statement.opening_balance)],
    ...statement.lines.map(
      (line): Array<string | number> => [
        formatReportDate(line.date),
        lineDescription(line),
        line.debit ? money(line.debit) : "",
        line.credit ? money(line.credit) : "",
        money(line.balance),
      ],
    ),
    [
      "",
      "Closing balance",
      money(statement.total_debits),
      money(statement.total_credits),
      money(statement.closing_balance),
    ],
  ];
  return rowsToCsv(
    ["Date", "Description", "Charges (GHS)", "Payments (GHS)", "Balance (GHS)"],
    rows,
  );
}

export function escapeHtml(value: unknown) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => {
    const map: Record<string, string> = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    };
    return map[char];
  });
}

/** A self-contained printable page; every value from the database is escaped. */
export function statementPrintHtml(statement: Statement) {
  const rows = statement.lines
    .map(
      (line) =>
        `<tr><td>${escapeHtml(formatReportDate(line.date))}</td><td>${escapeHtml(lineDescription(line))}</td>` +
        `<td class="n">${line.debit ? escapeHtml(formatGHSCell(line.debit)) : ""}</td>` +
        `<td class="n">${line.credit ? escapeHtml(formatGHSCell(line.credit)) : ""}</td>` +
        `<td class="n">${escapeHtml(formatGHSCell(line.balance))}</td></tr>`,
    )
    .join("");
  const place = (b: { city: string | null; region: string | null }) =>
    escapeHtml([b.city, b.region].filter(Boolean).join(", "));
  return `<!doctype html><html><head><meta charset="utf-8"><title>Statement - ${escapeHtml(statement.pharmacy.name)}</title>
<style>body{font-family:Arial,sans-serif;margin:32px;color:#111}h1{font-size:20px;margin:0 0 4px}table{border-collapse:collapse;width:100%;margin-top:16px;font-size:13px}
th,td{border-bottom:1px solid #ddd;padding:6px 8px;text-align:left}th{background:#f3f4f6}.n{text-align:right}.sum{margin-top:16px;font-size:14px}.sum div{display:flex;justify-content:space-between;max-width:360px;padding:2px 0}
.muted{color:#555;font-size:12px}</style></head><body>
<h1>Statement of account</h1>
<div class="muted">${escapeHtml(formatReportDate(statement.from))} to ${escapeHtml(formatReportDate(new Date(new Date(statement.to).getTime() - 1).toISOString()))}</div>
<p><strong>${escapeHtml(statement.wholesaler.name)}</strong><br><span class="muted">${place(statement.wholesaler)}</span></p>
<p>Customer: <strong>${escapeHtml(statement.pharmacy.name)}</strong><br><span class="muted">${place(statement.pharmacy)}</span></p>
<table><thead><tr><th>Date</th><th>Description</th><th class="n">Charges</th><th class="n">Payments</th><th class="n">Balance</th></tr></thead><tbody>
<tr><td></td><td><strong>Opening balance</strong></td><td></td><td></td><td class="n">${escapeHtml(formatGHSCell(statement.opening_balance))}</td></tr>${rows}
</tbody></table>
<div class="sum"><div><span>Total charges</span><span>${escapeHtml(formatGHSCell(statement.total_debits))}</span></div>
<div><span>Total payments</span><span>${escapeHtml(formatGHSCell(statement.total_credits))}</span></div>
<div><strong>Closing balance</strong><strong>${escapeHtml(formatGHSCell(statement.closing_balance))}</strong></div></div>
${statement.truncated ? '<p class="muted">Only the first 2,000 lines are shown. Choose a shorter date range for the full list.</p>' : ""}
<p class="muted">Generated by Drugxone. Cancelled and refunded orders are not included.</p>
<script>window.onload=function(){window.print()}</script></body></html>`;
}
