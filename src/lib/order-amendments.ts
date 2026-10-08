// Partial fulfilment: types for what get_order_amendments returns, and the pure helpers the screens use to word and
// validate a proposal. The database does the real enforcement; these only mirror its rules so people get a clear
// message before they submit, and so the wording is the same everywhere.
import { formatGHS } from "@/lib/format";

export type AmendmentStatus =
  "proposed" | "clarification_requested" | "accepted" | "rejected" | "withdrawn";

export type AmendmentLine = {
  order_item_id: string;
  product_name: string;
  ordered_qty: number;
  prior_supplied_qty: number;
  supplied_qty: number;
  short_qty: number;
  unit_price_ghs: number;
  note: string | null;
  /** Only sent to the wholesaler's side. */
  stock_treatment: "none" | "release" | "write_off" | null;
};

export type AmendmentMessage = {
  side: "wholesaler" | "pharmacy";
  message: string;
  at: string;
  author_label: string | null;
};

export type Amendment = {
  id: string;
  version: number;
  kind: "partial_fulfilment" | "price_change";
  status: AmendmentStatus;
  reason: string;
  proposed_at: string;
  proposed_by_label: string | null;
  original_total: number;
  proposed_total: number;
  delta: number;
  response_choice: string | null;
  response_note: string | null;
  responded_at: string | null;
  responded_by_label: string | null;
  stock_mode: "none" | "evidence" | null;
  lines: AmendmentLine[];
  messages: AmendmentMessage[];
};

export type SupplyLine = {
  order_item_id: string;
  product_name: string;
  ordered_qty: number;
  supplied_qty: number;
  unit_price_ghs: number;
};

export type OrderAmendmentsView = {
  order_id: string;
  order_number: string;
  status: string;
  original_total: number;
  current_total: number;
  amended: boolean;
  is_credit_order: boolean;
  open_amendment_id: string | null;
  stock_evidence: boolean | null;
  lines: SupplyLine[];
  amendments: Amendment[];
};

/** Statuses in which the wholesaler can still change what it will supply. */
export const SUPPLY_CHANGE_STATUSES = ["accepted", "picking", "packed", "ready_for_dispatch"];

export const AMENDMENT_STATUS_LABELS: Record<AmendmentStatus, string> = {
  proposed: "Awaiting the pharmacy's decision",
  clarification_requested: "Question open",
  accepted: "Accepted",
  rejected: "Rejected",
  withdrawn: "Withdrawn",
};

export function isOpenAmendment(amendment: Pick<Amendment, "status">): boolean {
  return amendment.status === "proposed" || amendment.status === "clarification_requested";
}

export function openAmendment(view: OrderAmendmentsView | null): Amendment | null {
  if (!view) return null;
  return view.amendments.find(isOpenAmendment) ?? null;
}

/** Can the wholesaler start a new supply change on this order right now? */
export function canProposeSupplyChange(
  view: OrderAmendmentsView | null,
  orderStatus: string,
  paymentStatus?: string | null,
): boolean {
  if (!view || view.open_amendment_id) return false;
  if (!SUPPLY_CHANGE_STATUSES.includes(orderStatus)) return false;
  if (!view.is_credit_order && paymentStatus === "paid") return false;
  return view.lines.some((line) => line.supplied_qty > 0);
}

// ---------------------------------------------------------------------------------------------------------------------
// The wholesaler's draft
// ---------------------------------------------------------------------------------------------------------------------
export type DraftLine = {
  order_item_id: string;
  product_name: string;
  ordered_qty: number;
  current_qty: number;
  unit_price_ghs: number;
  /** What the person typed ("" = untouched). */
  supply: string;
  treatment: "release" | "write_off" | "";
};

export function draftFromView(view: OrderAmendmentsView): DraftLine[] {
  return view.lines.map((line) => ({
    order_item_id: line.order_item_id,
    product_name: line.product_name,
    ordered_qty: line.ordered_qty,
    current_qty: line.supplied_qty,
    unit_price_ghs: Number(line.unit_price_ghs),
    supply: "",
    treatment: "",
  }));
}

/** The quantity the draft would supply for a line: what was typed, or the current quantity when nothing was typed. */
export function draftSupply(line: DraftLine): number | null {
  if (line.supply.trim() === "") return line.current_qty;
  if (!/^\d{1,9}$/.test(line.supply.trim())) return null;
  return Number(line.supply.trim());
}

export function draftShort(line: DraftLine): number {
  const supply = draftSupply(line);
  return supply === null ? 0 : Math.max(line.current_qty - supply, 0);
}

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

export type DraftTotals = {
  shortUnits: number;
  shortLines: number;
  shortValue: number;
  newTotal: number;
  suppliedUnits: number;
};

export function draftTotals(lines: DraftLine[], currentTotal: number): DraftTotals {
  let shortUnits = 0;
  let shortLines = 0;
  let shortValue = 0;
  let suppliedUnits = 0;
  for (const line of lines) {
    const supply = draftSupply(line) ?? line.current_qty;
    const short = Math.max(line.current_qty - supply, 0);
    suppliedUnits += Math.min(supply, line.current_qty);
    if (short > 0) {
      shortLines += 1;
      shortUnits += short;
      shortValue += money(short * line.unit_price_ghs);
    }
  }
  return {
    shortUnits,
    shortLines,
    shortValue: money(shortValue),
    newTotal: money(currentTotal - shortValue),
    suppliedUnits,
  };
}

/** The first thing wrong with a draft, in plain words, or null when it can be sent. */
export function validateDraft(
  lines: DraftLine[],
  reason: string,
  stockEvidence: boolean,
): string | null {
  for (const line of lines) {
    const supply = draftSupply(line);
    if (supply === null) return `Enter a whole number of units for ${line.product_name}.`;
    if (supply > line.current_qty) {
      return `You cannot supply more of ${line.product_name} than the ${line.current_qty} currently committed.`;
    }
    if (supply < line.current_qty && stockEvidence && line.treatment === "") {
      return `Say what happens to the stock for ${line.product_name}: release it to stock, or write it off.`;
    }
  }
  const totals = draftTotals(lines, 0);
  if (totals.shortLines === 0) return "Enter a smaller quantity for at least one product.";
  if (totals.suppliedUnits === 0) {
    return "Supplying nothing is a cancellation. Cancel the order instead.";
  }
  const trimmed = reason.trim();
  if (trimmed.length < 3) return "Give a reason for the shortage.";
  if (trimmed.length > 500) return "Keep the reason under 500 characters.";
  return null;
}

/** The p_lines argument for propose_partial_fulfilment: only the lines that change. */
export function proposalPayload(lines: DraftLine[], stockEvidence: boolean) {
  return lines
    .filter((line) => draftShort(line) > 0)
    .map((line) => ({
      order_item_id: line.order_item_id,
      supplied_qty: draftSupply(line) as number,
      ...(stockEvidence && line.treatment ? { stock_treatment: line.treatment } : {}),
    }));
}

// ---------------------------------------------------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------------------------------------------------
/** "GH₵550.00 less" / "GH₵40.00 more" / "no change". */
export function deltaPhrase(delta: number): string {
  const rounded = money(delta);
  if (rounded === 0) return "no change";
  return rounded < 0 ? `${formatGHS(Math.abs(rounded))} less` : `${formatGHS(rounded)} more`;
}

/** What the pharmacy is being asked to accept, in a sentence. */
export function pharmacySummary(
  amendment: Pick<Amendment, "lines" | "original_total" | "proposed_total">,
): string {
  const short = amendment.lines.filter((line) => line.short_qty > 0);
  const units = short.reduce((sum, line) => sum + line.short_qty, 0);
  const total = deltaPhrase(amendment.proposed_total - amendment.original_total);
  return `The wholesaler can supply less than you ordered: ${units} unit${units === 1 ? "" : "s"} short on ${short.length} product${short.length === 1 ? "" : "s"}. The order total would change from ${formatGHS(amendment.original_total)} to ${formatGHS(amendment.proposed_total)} (${total}).`;
}

/** What accepting means for the money, said plainly. */
export function acceptanceConsequence(isCredit: boolean, delta: number): string {
  const less = formatGHS(Math.abs(money(delta)));
  return isCredit
    ? `If you accept, the remaining quantity is cancelled and a credit note for ${less} is issued against this order's invoice. Nothing else on your account changes.`
    : `If you accept, the remaining quantity is cancelled and you will pay ${less} less on delivery.`;
}

export function responseSummary(amendment: Amendment): string {
  switch (amendment.status) {
    case "accepted":
      return "Accepted. The remaining quantity was cancelled.";
    case "rejected":
      return "Rejected. The order stood as placed.";
    case "withdrawn":
      return amendment.response_choice === "order_cancelled"
        ? "Closed because the order was cancelled."
        : "Withdrawn by the wholesaler. The order stood as placed.";
    case "clarification_requested":
      return "The pharmacy asked a question and is waiting for a reply.";
    default:
      return "Waiting for the pharmacy's decision. The order cannot be dispatched until it is decided.";
  }
}
