// Small display helpers shared by the RFQ screens.

export const RFQ_PAYMENT_OPTIONS: [string, string][] = [
  ["cod", "Cash on delivery"],
  ["credit", "Credit"],
  ["bank_transfer", "Bank transfer"],
  ["momo", "Mobile money"],
  ["cheque", "Cheque"],
  ["other", "Other"],
];
export const paymentLabel = (value: string) =>
  RFQ_PAYMENT_OPTIONS.find(([v]) => v === value)?.[1] ?? value.replaceAll("_", " ");

export const RFQ_CATEGORY_OPTIONS: [string, string][] = [
  ["cash_private", "Cash / private"],
  ["nhis", "NHIS"],
  ["other", "Other"],
];

export const rfqDate = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" })
    : "Not set";

export const rfqDateTime = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" })
    : "Not set";

/** Plain names for the commercial terms a buyer can ask a supplier to revise. */
export const RFQ_TERM_LABELS: Record<string, string> = {
  price: "Unit price",
  quantity: "Quantity",
  delivery: "Delivery date or fee",
  credit: "Payment terms",
  substitution: "Product substitution",
};

export type StatusTone = "success" | "primary" | "warning" | "danger" | "muted";
/** A colour for a request, invitation, award or negotiation status. Unknown statuses stay neutral. */
export function statusTone(status: string): StatusTone {
  switch (status) {
    case "completed":
    case "confirmed":
    case "accepted":
    case "submitted":
    case "delivered":
      return "success";
    case "open":
    case "evaluation":
    case "in_progress":
      return "primary";
    case "partially_awarded":
    case "pending":
    case "requested":
    case "countered":
      return "warning";
    case "cancelled":
    case "declined":
    case "rejected":
    case "expired":
    case "conversion_failed":
      return "danger";
    default:
      return "muted";
  }
}

/** The procurement report's figures, grouped and named for a reader. */
export const REPORT_GROUPS: {
  title: string;
  fields: [key: string, label: string, unit?: "ghs" | "percent" | "hours"][];
}[] = [
  {
    title: "Requests",
    fields: [
      ["rfqs", "Total requests"],
      ["completed", "Completed"],
    ],
  },
  {
    title: "Invitations",
    fields: [
      ["invitations", "Sent"],
      ["viewedInvitations", "Viewed"],
      ["acceptedInvitations", "Accepted"],
      ["declinedInvitations", "Declined"],
      ["submittedInvitations", "Quoted"],
      ["pendingInvitations", "Waiting"],
    ],
  },
  {
    title: "Quotations",
    fields: [
      ["quotes", "Quotations"],
      ["submittedQuotes", "Submitted"],
      ["submittedQuotesNotAwarded", "Not awarded"],
      ["awardWinRatePercent", "Award win rate", "percent"],
      ["averageResponseHours", "Average response", "hours"],
    ],
  },
  {
    title: "Awards and orders",
    fields: [
      ["confirmedAwards", "Confirmed awards"],
      ["declinedAwards", "Declined awards"],
      ["conversionFailures", "Order failures"],
      ["orders", "Orders created"],
      ["orderedValue", "Ordered value", "ghs"],
      ["creditValue", "On credit", "ghs"],
    ],
  },
];

const HOUR = 3_600_000;
/** How the quotation deadline stands, in a few words: "Closes in 3 days", "Closed 2 days ago" or "No deadline". */
export function deadlineHint(iso: string | null | undefined, now: number = Date.now()): string {
  if (!iso) return "No deadline";
  const gap = Date.parse(iso) - now;
  const span = (ms: number) => {
    const hours = Math.max(1, Math.round(Math.abs(ms) / HOUR));
    if (hours < 48) return `${hours} hour${hours === 1 ? "" : "s"}`;
    const days = Math.round(hours / 24);
    return `${days} day${days === 1 ? "" : "s"}`;
  };
  return gap >= 0 ? `Closes in ${span(gap)}` : `Closed ${span(gap)} ago`;
}

/** A figure from the procurement report, with its unit. A missing figure reads as a dash. */
export function reportValue(value: unknown, unit?: "ghs" | "percent" | "hours"): string {
  if (value === null || value === undefined || value === "") return "–";
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value);
  if (unit === "ghs")
    return `GH₵ ${n.toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  if (unit === "percent") return `${n}%`;
  if (unit === "hours") return `${n} h`;
  return n.toLocaleString("en-GB");
}
