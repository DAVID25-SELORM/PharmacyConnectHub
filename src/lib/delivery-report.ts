// Delivery reconciliation: types for what get_order_delivery_reports returns, and the pure helpers the screens use to word and
// validate a report and the wholesaler's decisions. The database enforces every rule; these only mirror them.
import { formatGHS } from "@/lib/format";

export type ReportStatus = "submitted" | "resolved" | "disputed" | "withdrawn" | "received_in_full";
export type DiscrepancyKind = "missing" | "damaged" | "rejected";
export type Outcome = "credit" | "return" | "reject";

export type ExpectedLine = {
  order_item_id: string;
  product_name: string;
  quantity: number;
  unit_price_ghs: number;
};

export type DeliveryEntry = {
  shipment_id: string | null;
  label: string;
  sort: string;
  delivered_at: string | null;
  delivered: boolean;
  expected: ExpectedLine[];
};

export type ReportLine = {
  id: string;
  order_item_id: string;
  product_name: string;
  unit_price_ghs: number;
  expected: number;
  received: number;
  missing: number;
  damaged: number;
  rejected: number;
  reason: string | null;
};

export type ReportDecision = {
  line_id: string;
  kind: DiscrepancyKind;
  quantity: number;
  outcome: Outcome;
  amount: number;
  return_number: string | null;
};

export type DeliveryReport = {
  id: string;
  shipment_id: string | null;
  status: ReportStatus;
  note: string | null;
  submitted_at: string;
  submitted_by_label: string | null;
  resolved_at: string | null;
  resolved_by_label: string | null;
  resolution_note: string | null;
  credit_total: number;
  lines: ReportLine[];
  decisions: ReportDecision[];
};

export type OrderDeliveryReports = { deliveries: DeliveryEntry[]; reports: DeliveryReport[] };

export const REPORT_STATUS_LABELS: Record<ReportStatus, string> = {
  submitted: "Waiting for the wholesaler's check",
  resolved: "Checked and settled",
  disputed: "Not accepted by the wholesaler",
  withdrawn: "Withdrawn",
  received_in_full: "Received in full",
};

export const KIND_LABELS: Record<DiscrepancyKind, string> = {
  missing: "Missing",
  damaged: "Damaged",
  rejected: "Rejected",
};

export const OUTCOME_LABELS: Record<Outcome, string> = {
  credit: "Credit it",
  return: "Take the goods back",
  reject: "Reject the claim",
};

export const DELIVERY_REPORT_WINDOW_DAYS = 30;

/** The report that currently stands for a delivery (not withdrawn, not disputed), if any. */
export function liveReport(
  reports: DeliveryReport[],
  shipmentId: string | null,
): DeliveryReport | null {
  return (
    reports.find(
      (report) =>
        report.shipment_id === shipmentId &&
        (report.status === "submitted" ||
          report.status === "resolved" ||
          report.status === "received_in_full"),
    ) ?? null
  );
}

/** Still inside the window in which a delivery can be reported on. */
export function withinReportWindow(deliveredAt: string | null, now = Date.now()): boolean {
  if (!deliveredAt) return true;
  return now <= new Date(deliveredAt).getTime() + DELIVERY_REPORT_WINDOW_DAYS * 24 * 3600 * 1000;
}

/** The outcomes the wholesaler may choose for a kind of discrepancy: missing goods cannot be taken back. */
export function outcomesFor(kind: DiscrepancyKind): Outcome[] {
  return kind === "missing" ? ["credit", "reject"] : ["return", "credit", "reject"];
}

// ---------------------------------------------------------------------------------------------------------------------
// The pharmacy's draft
// ---------------------------------------------------------------------------------------------------------------------
export type ReportDraftLine = {
  order_item_id: string;
  product_name: string;
  unit_price_ghs: number;
  expected: number;
  missing: string;
  damaged: string;
  rejected: string;
  reason: string;
};

export function reportDraft(expected: ExpectedLine[]): ReportDraftLine[] {
  return expected.map((line) => ({
    order_item_id: line.order_item_id,
    product_name: line.product_name,
    unit_price_ghs: Number(line.unit_price_ghs),
    expected: line.quantity,
    missing: "",
    damaged: "",
    rejected: "",
    reason: "",
  }));
}

const count = (text: string): number | null => {
  const trimmed = text.trim();
  if (trimmed === "") return 0;
  return /^\d{1,9}$/.test(trimmed) ? Number(trimmed) : null;
};

export function draftCounts(line: ReportDraftLine) {
  return {
    missing: count(line.missing),
    damaged: count(line.damaged),
    rejected: count(line.rejected),
  };
}

export function draftReceived(line: ReportDraftLine): number | null {
  const { missing, damaged, rejected } = draftCounts(line);
  if (missing === null || damaged === null || rejected === null) return null;
  return line.expected - missing - damaged - rejected;
}

export function draftHasProblem(lines: ReportDraftLine[]): boolean {
  return lines.some((line) => {
    const { missing, damaged, rejected } = draftCounts(line);
    return (missing ?? 0) + (damaged ?? 0) + (rejected ?? 0) > 0;
  });
}

export function validateReportDraft(lines: ReportDraftLine[]): string | null {
  for (const line of lines) {
    const { missing, damaged, rejected } = draftCounts(line);
    if (missing === null || damaged === null || rejected === null) {
      return `Enter whole numbers for ${line.product_name}.`;
    }
    if (missing + damaged + rejected > line.expected) {
      return `You cannot report more than the ${line.expected} delivered of ${line.product_name}.`;
    }
    if (missing + damaged + rejected > 0 && line.reason.trim().length < 3) {
      return `Say what went wrong with ${line.product_name}.`;
    }
  }
  return null;
}

/** The p_lines argument for submit_delivery_report: only the lines with a problem. */
export function reportPayload(lines: ReportDraftLine[]) {
  return lines
    .filter((line) => {
      const { missing, damaged, rejected } = draftCounts(line);
      return (missing ?? 0) + (damaged ?? 0) + (rejected ?? 0) > 0;
    })
    .map((line) => {
      const { missing, damaged, rejected } = draftCounts(line);
      return {
        order_item_id: line.order_item_id,
        missing: missing ?? 0,
        damaged: damaged ?? 0,
        rejected: rejected ?? 0,
        reason: line.reason.trim(),
      };
    });
}

// ---------------------------------------------------------------------------------------------------------------------
// The wholesaler's decisions
// ---------------------------------------------------------------------------------------------------------------------
export type Discrepancy = {
  key: string;
  line_id: string;
  kind: DiscrepancyKind;
  product_name: string;
  quantity: number;
  unit_price_ghs: number;
  reason: string | null;
};

/** Every discrepancy in a report, one entry per line and kind. */
export function discrepancies(report: Pick<DeliveryReport, "lines">): Discrepancy[] {
  const out: Discrepancy[] = [];
  for (const line of report.lines) {
    for (const kind of ["missing", "damaged", "rejected"] as const) {
      const quantity = line[kind];
      if (quantity > 0) {
        out.push({
          key: `${line.id}:${kind}`,
          line_id: line.id,
          kind,
          product_name: line.product_name,
          quantity,
          unit_price_ghs: Number(line.unit_price_ghs),
          reason: line.reason,
        });
      }
    }
  }
  return out;
}

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

export function decisionCredit(
  items: Discrepancy[],
  choices: Record<string, Outcome | "">,
): number {
  return money(
    items.reduce(
      (sum, item) =>
        choices[item.key] === "credit" ? sum + item.quantity * item.unit_price_ghs : sum,
      0,
    ),
  );
}

export function validateDecisions(
  items: Discrepancy[],
  choices: Record<string, Outcome | "">,
  note: string,
): string | null {
  for (const item of items) {
    if (!choices[item.key])
      return `Choose what to do about the ${KIND_LABELS[item.kind].toLowerCase()} ${item.product_name}.`;
  }
  if (items.some((item) => choices[item.key] === "reject") && note.trim().length < 3) {
    return "Explain to the pharmacy why a claim is rejected.";
  }
  return null;
}

export function decisionsPayload(items: Discrepancy[], choices: Record<string, Outcome | "">) {
  return items.map((item) => ({
    line_id: item.line_id,
    kind: item.kind,
    outcome: choices[item.key],
  }));
}

// ---------------------------------------------------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------------------------------------------------
export function reportSummary(report: DeliveryReport): string {
  if (report.status === "received_in_full") return "The pharmacy confirmed everything arrived.";
  const parts = discrepancies(report).map(
    (item) => `${item.quantity} ${KIND_LABELS[item.kind].toLowerCase()} ${item.product_name}`,
  );
  return parts.join(", ");
}

export function decisionSummary(report: DeliveryReport): string | null {
  if (report.status === "disputed")
    return "The wholesaler did not accept this report. Nothing was changed.";
  if (report.status !== "resolved") return null;
  const returns = report.decisions.filter((decision) => decision.outcome === "return");
  const rejected = report.decisions.filter((decision) => decision.outcome === "reject");
  const pieces: string[] = [];
  if (report.credit_total > 0) pieces.push(`${formatGHS(report.credit_total)} credited`);
  if (returns.length > 0) {
    const numbers = [...new Set(returns.map((decision) => decision.return_number).filter(Boolean))];
    pieces.push(`goods to be returned${numbers.length ? ` (${numbers.join(", ")})` : ""}`);
  }
  if (rejected.length > 0)
    pieces.push(`${rejected.length} item${rejected.length === 1 ? "" : "s"} not accepted`);
  return pieces.join("; ");
}
