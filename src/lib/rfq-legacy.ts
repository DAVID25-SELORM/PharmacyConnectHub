// Pure helpers for the older single-supplier RFQ quotation screen. They show, line by line, the same problems
// validateQuoteDraft reports one at a time, and keep the list searchable and filterable when it is long.
import { finalUnitPrice, type QuoteLineDraft, type RfqItem } from "./rfq";

export type LegacyFilter = "all" | "included" | "excluded" | "attention";

/** Why a line chosen for the quotation cannot be sent yet, or null. Lines not chosen have no problems. */
export function legacyLineIssue(line: QuoteLineDraft, item: RfqItem): string | null {
  if (!line.include) return null;
  if (!line.productId) return "Choose your product.";
  const price = Number(line.unitPriceGhs);
  if (line.unitPriceGhs.trim() === "" || !Number.isFinite(price) || price <= 0)
    return "Enter a unit price above zero.";
  if (line.quantity.trim() !== "") {
    const qty = Number(line.quantity);
    if (!Number.isInteger(qty) || qty < 1 || qty > item.quantity)
      return `Available quantity must be a whole number from 1 to ${item.quantity}.`;
  }
  if (line.discountPercent.trim() !== "") {
    const discount = Number(line.discountPercent);
    if (!Number.isFinite(discount) || discount < 0 || discount >= 100)
      return "A discount must be at least 0% and less than 100%.";
    if (finalUnitPrice(price, discount) <= 0) return "The price after discount must be above zero.";
  }
  return null;
}

export function legacyIssues(
  lines: QuoteLineDraft[],
  items: Map<string, RfqItem>,
): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of lines) {
    const item = items.get(line.rfqItemId);
    const issue = item ? legacyLineIssue(line, item) : null;
    if (issue) out.set(line.rfqItemId, issue);
  }
  return out;
}

export type LegacySummary = {
  total: number;
  included: number;
  withIssues: number;
  estimate: number;
};

/** How much is being quoted, and what it adds up to (price after discount x available quantity). */
export function legacySummary(
  lines: QuoteLineDraft[],
  items: Map<string, RfqItem>,
  issues: Map<string, string>,
): LegacySummary {
  let estimate = 0;
  let included = 0;
  for (const line of lines) {
    if (!line.include) continue;
    included++;
    const item = items.get(line.rfqItemId);
    if (!item || issues.has(line.rfqItemId)) continue;
    const qty = line.quantity.trim() ? Number(line.quantity) : item.quantity;
    estimate += finalUnitPrice(Number(line.unitPriceGhs), Number(line.discountPercent) || 0) * qty;
  }
  return {
    total: lines.length,
    included,
    withIssues: issues.size,
    estimate: Math.round((estimate + Number.EPSILON) * 100) / 100,
  };
}

export function visibleLegacyIndices(
  lines: QuoteLineDraft[],
  items: Map<string, RfqItem>,
  issues: Map<string, string>,
  view: { search: string; filter: LegacyFilter },
): number[] {
  const term = view.search.trim().toLowerCase();
  const out: number[] = [];
  lines.forEach((line, index) => {
    const item = items.get(line.rfqItemId);
    if (term && !`${item?.product_name ?? ""} ${item?.notes ?? ""}`.toLowerCase().includes(term))
      return;
    if (view.filter === "included" && !line.include) return;
    if (view.filter === "excluded" && line.include) return;
    if (view.filter === "attention" && !issues.has(line.rfqItemId)) return;
    out.push(index);
  });
  return out;
}

export const setIncluded = (
  lines: QuoteLineDraft[],
  ids: ReadonlySet<string>,
  include: boolean,
): QuoteLineDraft[] => lines.map((l) => (ids.has(l.rfqItemId) ? { ...l, include } : l));

export const applyLegacy = (
  lines: QuoteLineDraft[],
  ids: ReadonlySet<string>,
  patch: Partial<Omit<QuoteLineDraft, "rfqItemId">>,
): QuoteLineDraft[] => lines.map((l) => (ids.has(l.rfqItemId) ? { ...l, ...patch } : l));
