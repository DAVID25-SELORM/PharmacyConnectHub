// Pure rules for the supplier's quotation lines. They mirror what save_enterprise_quote enforces so a
// supplier sees problems before submitting; the database remains the authority and checks everything again.
import type { Requirement } from "./enterprise-rfq";

export type DraftLine = {
  rfqItemId: string;
  productId: string;
  quantity: string;
  unitPriceGhs: string;
  discountPercent: string;
  alternative: boolean;
  conversion: string;
  expiryDate: string;
  batchNumber: string;
  expectedAvailableOn: string;
  coldChainSupported: boolean;
  specialHandling: string;
  notes: string;
};

export type QuoteFilter = "all" | "quoted" | "unquoted" | "attention";

export const blankDraftLine = (item: Requirement): DraftLine => ({
  rfqItemId: item.id,
  productId: "",
  quantity: String(item.quantity),
  unitPriceGhs: "",
  discountPercent: "0",
  alternative: false,
  conversion: "1",
  expiryDate: "",
  batchNumber: "",
  expectedAvailableOn: "",
  coldChainSupported: false,
  specialHandling: "",
  notes: "",
});

export const isQuoted = (line: DraftLine) => Boolean(line.productId);

const DAY = 86_400_000;
const isoDay = (date: Date) => date.toISOString().slice(0, 10);
const addDays = (iso: string, days: number) =>
  isoDay(new Date(Date.parse(`${iso}T00:00:00Z`) + days * DAY));

/** The last day that is too early: an expiry must fall strictly after it. */
export function expiryFloor(
  expectedDelivery: string | null,
  minimumShelfLifeDays: number,
  today: string,
): string {
  const start = expectedDelivery && expectedDelivery > today ? expectedDelivery : today;
  return addDays(start, minimumShelfLifeDays);
}

export type IssueContext = {
  expectedDelivery: string | null;
  /** Today as YYYY-MM-DD (UTC, like the database). */
  today: string;
  /** Catalogue identity of the chosen product: undefined while unknown, null when it has none. */
  offeredMaster?: string | null;
};

const wholeNumber = (text: string) => text.trim() !== "" && Number.isSafeInteger(Number(text));

/** Why a quoted line cannot be submitted yet, or null when it is fine. Unquoted lines have no issues. */
export function lineIssue(line: DraftLine, item: Requirement, ctx: IssueContext): string | null {
  if (!isQuoted(line)) return null;
  const qty = Number(line.quantity);
  if (!wholeNumber(line.quantity) || qty <= 0) return "Enter a whole number of units to offer.";
  const ratio = line.alternative ? Number(line.conversion) : 1;
  if (!(ratio > 0)) return "Enter how many requested units one offered unit supplies.";
  const supplied = qty * ratio;
  if (supplied > item.quantity)
    return `That is more than the ${item.quantity} ${item.unit} requested.`;
  if (!item.partial_allowed && supplied !== item.quantity)
    return `The buyer needs the full ${item.quantity} ${item.unit}: partial supply is not allowed.`;
  const price = Number(line.unitPriceGhs);
  if (line.unitPriceGhs.trim() === "" || !(price > 0)) return "Enter a unit price above zero.";
  const discount = Number(line.discountPercent || 0);
  if (!(discount >= 0 && discount < 100))
    return "Discount must be from 0 up to (not including) 100.";
  if (!line.expiryDate) return "Enter the expiry date.";
  const floor = expiryFloor(ctx.expectedDelivery, item.minimum_shelf_life_days, ctx.today);
  if (line.expiryDate <= floor)
    return `Expiry must be after ${floor} to give ${item.minimum_shelf_life_days} days of shelf life.`;
  if (item.cold_chain_required && !line.coldChainSupported)
    return "Confirm cold chain: this medicine requires it.";
  if (line.alternative && !item.alternatives_allowed)
    return "The buyer does not allow alternatives on this line.";
  if (
    !line.alternative &&
    ctx.offeredMaster !== undefined &&
    ctx.offeredMaster !== item.master_product_id
  )
    return "This is not the requested catalogue medicine. Mark it as an alternative, or choose another product.";
  return null;
}

export function lineIssues(
  lines: DraftLine[],
  items: Map<string, Requirement>,
  ctx: (line: DraftLine) => IssueContext,
): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of lines) {
    const item = items.get(line.rfqItemId);
    if (!item) continue;
    const issue = lineIssue(line, item, ctx(line));
    if (issue) out.set(line.rfqItemId, issue);
  }
  return out;
}

// Money: same two-step rounding as the database (price after line discount, then after order discount).
const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;
export const finalUnitPrice = (line: DraftLine, orderDiscountPercent: number) =>
  round2(
    round2(Number(line.unitPriceGhs) * (1 - Number(line.discountPercent || 0) / 100)) *
      (1 - orderDiscountPercent / 100),
  );

export type QuoteSummary = {
  total: number;
  quoted: number;
  unquoted: number;
  withIssues: number;
  estimate: number;
};

export function summarizeQuote(
  lines: DraftLine[],
  issues: Map<string, string>,
  orderDiscountPercent: number,
): QuoteSummary {
  const quoted = lines.filter(isQuoted);
  const estimate = quoted
    .filter((l) => !issues.has(l.rfqItemId))
    .reduce((sum, l) => sum + finalUnitPrice(l, orderDiscountPercent) * Number(l.quantity), 0);
  return {
    total: lines.length,
    quoted: quoted.length,
    unquoted: lines.length - quoted.length,
    withIssues: issues.size,
    estimate: round2(estimate),
  };
}

export function visibleQuoteIndices(
  lines: DraftLine[],
  items: Map<string, Requirement>,
  issues: Map<string, string>,
  view: { search: string; filter: QuoteFilter },
): number[] {
  const term = view.search.trim().toLowerCase();
  const out: number[] = [];
  lines.forEach((line, index) => {
    const item = items.get(line.rfqItemId);
    if (term && !(item?.product_name ?? "").toLowerCase().includes(term)) return;
    if (view.filter === "quoted" && !isQuoted(line)) return;
    if (view.filter === "unquoted" && isQuoted(line)) return;
    if (view.filter === "attention" && !issues.has(line.rfqItemId)) return;
    out.push(index);
  });
  return out;
}

export const applyToDraft = (
  lines: DraftLine[],
  ids: ReadonlySet<string>,
  patch: Partial<Omit<DraftLine, "rfqItemId">>,
): DraftLine[] => lines.map((l) => (ids.has(l.rfqItemId) ? { ...l, ...patch } : l));

/** Stop quoting the selected lines: forget the product and everything quoted against it. */
export const stopQuoting = (
  lines: DraftLine[],
  ids: ReadonlySet<string>,
  items: Map<string, Requirement>,
) =>
  lines.map((l) => {
    const item = items.get(l.rfqItemId);
    return ids.has(l.rfqItemId) && item ? blankDraftLine(item) : l;
  });

/** Offer the full requested quantity on the selected quoted lines. */
export const offerFullQuantity = (
  lines: DraftLine[],
  ids: ReadonlySet<string>,
  items: Map<string, Requirement>,
) =>
  lines.map((l) => {
    const item = items.get(l.rfqItemId);
    return ids.has(l.rfqItemId) && item && isQuoted(l) && !l.alternative
      ? { ...l, quantity: String(item.quantity) }
      : l;
  });

/** Fill empty prices on the chosen quoted lines from the supplier's catalogue list prices; never overwrites a price. */
export function fillPrices(
  lines: DraftLine[],
  ids: ReadonlySet<string>,
  priceOf: (productId: string) => number | undefined,
): { lines: DraftLine[]; filled: number } {
  let filled = 0;
  const next = lines.map((l) => {
    if (!ids.has(l.rfqItemId) || !isQuoted(l) || l.unitPriceGhs.trim() !== "") return l;
    const price = priceOf(l.productId);
    if (!(price !== undefined && price > 0)) return l;
    filled++;
    return { ...l, unitPriceGhs: price.toFixed(2) };
  });
  return { lines: next, filled };
}

/**
 * Lines the supplier has not started quoting, matched to the supplier's own catalogue by exact catalogue
 * identity. A requested medicine with several candidate products is left for the supplier to choose.
 */
export function matchCatalogue(
  lines: DraftLine[],
  items: Map<string, Requirement>,
  candidates: Map<string, string[]>,
): { lines: DraftLine[]; matched: number; ambiguous: number } {
  let matched = 0;
  let ambiguous = 0;
  const next = lines.map((l) => {
    if (isQuoted(l)) return l;
    const master = items.get(l.rfqItemId)?.master_product_id;
    const options = master ? (candidates.get(master) ?? []) : [];
    if (options.length === 1) {
      matched++;
      return { ...l, productId: options[0] };
    }
    if (options.length > 1) ambiguous++;
    return l;
  });
  return { lines: next, matched, ambiguous };
}

/** What is sent to the database. A conversion other than 1 only makes sense for an explicit alternative. */
export const toPayloadLines = (lines: DraftLine[]) =>
  lines.filter(isQuoted).map((l) => ({ ...l, conversion: l.alternative ? l.conversion : "1" }));
