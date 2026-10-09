// Price amendments: the pure helpers the screens use to build, validate and word a price proposal. The database enforces every
// rule (who may propose, the window, the credit limit); these only mirror them so people get a clear message before they submit.
import { formatGHS } from "@/lib/format";
import { deltaPhrase, type Amendment, type OrderAmendmentsView } from "@/lib/order-amendments";

const money = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

/** Statuses in which prices can still be changed (the same window as a supply change). */
export const PRICE_CHANGE_STATUSES = ["accepted", "picking", "packed", "ready_for_dispatch"];

/** Can the owner or a manager start a price change on this order right now? */
export function canProposePriceChange(
  view: OrderAmendmentsView | null,
  orderStatus: string,
  paymentStatus?: string | null,
): boolean {
  if (!view || view.open_amendment_id) return false;
  if (!PRICE_CHANGE_STATUSES.includes(orderStatus)) return false;
  if (!view.is_credit_order && paymentStatus === "paid") return false;
  return view.lines.length > 0;
}

/** Whether an order has anything to show in the price-change area (a price proposal, or a button to start one). */
export function hasPriceChangeContent(
  view: OrderAmendmentsView,
  side: "wholesaler" | "pharmacy",
  canPropose: boolean,
  orderStatus: string,
  paymentStatus?: string | null,
): boolean {
  return (
    view.amendments.some((amendment) => amendment.kind === "price_change") ||
    (side === "wholesaler" && canPropose && canProposePriceChange(view, orderStatus, paymentStatus))
  );
}

export type PriceDraftLine = {
  order_item_id: string;
  product_name: string;
  /** Units the wholesaler is committed to supply now: the price change is worked out on these. */
  committed_qty: number;
  /** The price in force. */
  current_price: number;
  /** What the person typed ("" = untouched). */
  next: string;
};

export function priceDraftFromView(view: OrderAmendmentsView): PriceDraftLine[] {
  return view.lines.map((line) => ({
    order_item_id: line.order_item_id,
    product_name: line.product_name,
    committed_qty: line.supplied_qty,
    current_price: Number(line.unit_price_ghs),
    next: "",
  }));
}

/** The new price typed for a line: null when it is not a valid amount (more than zero, at most two decimals). */
export function parsePrice(text: string): number | null {
  const trimmed = text.trim();
  if (!/^\d{1,9}(\.\d{1,2})?$/.test(trimmed)) return null;
  const value = Number(trimmed);
  return value > 0 ? value : null;
}

/** The line's new price, or null when untouched or invalid; `changed` is true only for a different, valid price. */
export function draftPrice(line: PriceDraftLine): { value: number | null; changed: boolean } {
  if (line.next.trim() === "") return { value: null, changed: false };
  const value = parsePrice(line.next);
  return { value, changed: value !== null && value !== line.current_price };
}

export type PriceDraftTotals = {
  changedLines: number;
  delta: number;
  newTotal: number;
};

export function priceDraftTotals(lines: PriceDraftLine[], currentTotal: number): PriceDraftTotals {
  let changedLines = 0;
  let delta = 0;
  for (const line of lines) {
    const { value, changed } = draftPrice(line);
    if (!changed || value === null) continue;
    changedLines += 1;
    delta += money((value - line.current_price) * line.committed_qty);
  }
  return { changedLines, delta: money(delta), newTotal: money(currentTotal + delta) };
}

/** The first thing wrong with a draft, in plain words, or null when it can be sent. */
export function validatePriceDraft(
  lines: PriceDraftLine[],
  reason: string,
  currentTotal: number,
): string | null {
  for (const line of lines) {
    if (line.next.trim() === "") continue;
    const { value, changed } = draftPrice(line);
    if (value === null) {
      return `Enter the new price of ${line.product_name} as an amount in cedis with at most two decimals, more than zero.`;
    }
    if (!changed) return `The new price of ${line.product_name} is the same as its current price.`;
  }
  const totals = priceDraftTotals(lines, currentTotal);
  if (totals.changedLines === 0) return "Enter a different price for at least one product.";
  if (totals.newTotal < 0) return "The new total cannot be negative.";
  const trimmed = reason.trim();
  if (trimmed.length < 3) return "Give a reason for the price change.";
  if (trimmed.length > 500) return "Keep the reason under 500 characters.";
  return null;
}

/** The p_lines argument for propose_price_amendment: only the lines whose price changes. */
export function pricePayload(lines: PriceDraftLine[]) {
  return lines.flatMap((line) => {
    const { value, changed } = draftPrice(line);
    return changed && value !== null
      ? [{ order_item_id: line.order_item_id, unit_price_ghs: value }]
      : [];
  });
}

// ---------------------------------------------------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------------------------------------------------
/** What the pharmacy is being asked to approve, in a sentence. */
export function priceSummary(
  amendment: Pick<Amendment, "lines" | "original_total" | "proposed_total">,
): string {
  const lines = amendment.lines.filter((line) => line.proposed_unit_price_ghs !== null);
  const total = deltaPhrase(amendment.proposed_total - amendment.original_total);
  return `The wholesaler proposes new prices on ${lines.length} product${lines.length === 1 ? "" : "s"}. The order total would change from ${formatGHS(amendment.original_total)} to ${formatGHS(amendment.proposed_total)} (${total}). Nothing changes unless you approve it.`;
}

/** What approving means for the money, said plainly. */
export function priceAcceptanceConsequence(isCredit: boolean, delta: number): string {
  const amount = formatGHS(Math.abs(money(delta)));
  if (money(delta) === 0)
    return "The prices change but the order total stays the same, so no money moves.";
  if (isCredit) {
    return delta < 0
      ? `If you approve, a credit note for ${amount} is issued against this order's invoice. Nothing else on your account changes.`
      : `If you approve, a debit note for ${amount} is added to this order's invoice, within your credit limit.`;
  }
  return delta < 0
    ? `If you approve, you will pay ${amount} less on delivery.`
    : `If you approve, you will pay ${amount} more on delivery.`;
}

export function priceResponseSummary(amendment: Amendment): string {
  switch (amendment.status) {
    case "accepted":
      return "Approved. The new prices apply.";
    case "rejected":
      return "Rejected. The prices stood as agreed.";
    case "withdrawn":
      return amendment.response_choice === "order_cancelled"
        ? "Closed because the order was cancelled."
        : "Withdrawn by the wholesaler. The prices stood as agreed.";
    case "clarification_requested":
      return "The pharmacy asked a question and is waiting for a reply.";
    default:
      return "Waiting for the pharmacy's decision. The order cannot be dispatched until it is decided.";
  }
}
