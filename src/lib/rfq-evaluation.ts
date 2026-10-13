// Pure helpers for the buyer's evaluation of quotations: the comparison matrix, price comparisons,
// award selections and the checks the database makes again before it accepts an award.
import type { QuoteVersion, Requirement, VersionLine } from "./enterprise-rfq";

/** Offered units chosen to award, keyed by quotation line id. */
export type Selection = Record<string, string>;
/** Alternatives the buyer has explicitly accepted, keyed by quotation line id. */
export type Accepted = Record<string, boolean>;

export const RFQ_MAX_ALLOCATIONS = 500;

const ratioOf = (line: VersionLine) => Number(line.requested_units_per_offered_unit) || 1;
/** Price per requested unit, so offers that package a medicine differently can be compared. */
export const pricePerRequestedUnit = (line: VersionLine) =>
  Number(line.final_unit_price_ghs) / ratioOf(line);

export const landedTotal = (version: QuoteVersion) =>
  Number(version.snapshot.quote.total_ghs) +
  Number(version.snapshot.quote.delivery_charge_ghs || 0);

/** requirement id -> quotation version id -> that version's line */
export type LineIndex = Map<string, Map<string, VersionLine>>;
export function buildLineIndex(versions: QuoteVersion[]): LineIndex {
  const index: LineIndex = new Map();
  for (const version of versions)
    for (const line of version.snapshot.items) {
      const row = index.get(line.rfq_item_id) ?? new Map<string, VersionLine>();
      row.set(version.id, line);
      index.set(line.rfq_item_id, row);
    }
  return index;
}

/** Lines with the lowest price per requested unit on their requirement, when at least two suppliers quoted it. */
export function lowestPriceLineIds(index: LineIndex): Set<string> {
  const out = new Set<string>();
  for (const row of index.values()) {
    const lines = [...row.values()];
    if (lines.length < 2) continue;
    const best = Math.min(...lines.map(pricePerRequestedUnit));
    for (const line of lines) if (pricePerRequestedUnit(line) === best) out.add(line.id);
  }
  return out;
}

export type Coverage = { quoted: number; total: number; complete: number };
/** How much of the request a quotation answers, and on how many lines it offers the full quantity. */
export function coverage(version: QuoteVersion, items: Requirement[]): Coverage {
  const byItem = new Map(version.snapshot.items.map((l) => [l.rfq_item_id, l]));
  let quoted = 0;
  let complete = 0;
  for (const item of items) {
    const line = byItem.get(item.id);
    if (!line) continue;
    quoted++;
    if (Number(line.quantity) * ratioOf(line) >= item.quantity) complete++;
  }
  return { quoted, total: items.length, complete };
}

const chosen = (value: string | undefined) => (value ?? "").trim() !== "" && Number(value) !== 0;

/** Why a chosen award quantity would be refused, keyed by quotation line id. */
export function selectionIssues(
  items: Requirement[],
  versions: QuoteVersion[],
  selection: Selection,
  accepted: Accepted,
  remaining: (item: Requirement) => number,
): Map<string, string> {
  const issues = new Map<string, string>();
  const itemMap = new Map(items.map((i) => [i.id, i]));
  const perItem = new Map<string, { id: string; requested: number }[]>();
  for (const version of versions)
    for (const line of version.snapshot.items) {
      if (!chosen(selection[line.id])) continue;
      const item = itemMap.get(line.rfq_item_id);
      if (!item) continue;
      const qty = Number(selection[line.id]);
      if (!Number.isInteger(qty) || qty <= 0) {
        issues.set(line.id, "Use a whole number of units.");
        continue;
      }
      if (qty > Number(line.quantity)) {
        issues.set(line.id, `Only ${line.quantity} offered.`);
        continue;
      }
      const requested = qty * ratioOf(line);
      if (!Number.isInteger(requested)) {
        issues.set(line.id, "The conversion must give whole requested units.");
        continue;
      }
      if (line.alternative && !accepted[line.id]) {
        issues.set(line.id, "Accept the specification and conversion to award this alternative.");
        continue;
      }
      if (!item.partial_allowed && requested !== item.quantity) {
        issues.set(
          line.id,
          `Needs the full ${item.quantity} ${item.unit}: partial awards are not allowed.`,
        );
        continue;
      }
      perItem.set(item.id, [...(perItem.get(item.id) ?? []), { id: line.id, requested }]);
    }
  for (const [itemId, picks] of perItem) {
    const item = itemMap.get(itemId)!;
    const left = remaining(item);
    if (picks.reduce((sum, p) => sum + p.requested, 0) > left)
      for (const pick of picks)
        issues.set(pick.id, `More than the ${left} ${item.unit} still needed across suppliers.`);
  }
  return issues;
}

export type SelectionTotal = {
  versionId: string;
  lines: number;
  goods: number;
  delivery: number;
  total: number;
};
/** Per supplier: lines chosen, goods value and its delivery charge (charged once per award). */
export function selectionTotals(versions: QuoteVersion[], selection: Selection): SelectionTotal[] {
  const out: SelectionTotal[] = [];
  for (const version of versions) {
    let lines = 0;
    let goods = 0;
    for (const line of version.snapshot.items) {
      if (!chosen(selection[line.id])) continue;
      const qty = Number(selection[line.id]);
      if (!(qty > 0)) continue;
      lines++;
      goods += qty * Number(line.final_unit_price_ghs);
    }
    if (!lines) continue;
    const delivery = Number(version.snapshot.quote.delivery_charge_ghs || 0);
    out.push({ versionId: version.id, lines, goods, delivery, total: goods + delivery });
  }
  return out;
}

/** The award request sent to the database. */
export function allocationPayload(
  versions: QuoteVersion[],
  selection: Selection,
  accepted: Accepted,
  category: string,
) {
  return versions.flatMap((version) =>
    version.snapshot.items
      .filter((line) => Number(selection[line.id]) > 0)
      .map((line) => ({
        versionId: version.id,
        quoteItemId: line.id,
        quantity: Number(selection[line.id]),
        acceptAlternative: accepted[line.id] ?? false,
        category,
      })),
  );
}

/** Choose a whole quotation: every line at its full offered quantity. */
export const wholeQuote = (version: QuoteVersion): Selection =>
  Object.fromEntries(version.snapshot.items.map((l) => [l.id, String(l.quantity)]));

/**
 * A starting point, not a decision: for each requirement still open, fill from the lowest price per requested
 * unit upward until it is covered. Alternatives are never chosen automatically, and a requirement that
 * does not allow partial supply is given to the cheapest quote that covers all of it.
 */
export function cheapestPlan(
  items: Requirement[],
  versions: QuoteVersion[],
  remaining: (item: Requirement) => number,
): Selection {
  const index = buildLineIndex(versions);
  const plan: Selection = {};
  for (const item of items) {
    let left = remaining(item);
    if (left <= 0) continue;
    const candidates = [...(index.get(item.id)?.values() ?? [])]
      .filter((l) => !l.alternative && Number(l.quantity) > 0 && ratioOf(l) === 1)
      .sort(
        (a, b) => pricePerRequestedUnit(a) - pricePerRequestedUnit(b) || a.id.localeCompare(b.id),
      );
    if (!item.partial_allowed) {
      const whole = candidates.find((l) => Number(l.quantity) >= item.quantity);
      if (whole && left === item.quantity) plan[whole.id] = String(item.quantity);
      continue;
    }
    for (const line of candidates) {
      if (left <= 0) break;
      const take = Math.min(Number(line.quantity), left);
      plan[line.id] = String(take);
      left -= take;
    }
  }
  return plan;
}

export type MatrixFilter = "all" | "open" | "chosen" | "alternatives" | "unquoted";

/** Requirements the matrix shows for a search term and filter, as indices into `items`. */
export function visibleRequirements(
  items: Requirement[],
  index: LineIndex,
  selection: Selection,
  remaining: (item: Requirement) => number,
  view: { search: string; filter: MatrixFilter },
): number[] {
  const term = view.search.trim().toLowerCase();
  const out: number[] = [];
  items.forEach((item, i) => {
    if (term && !item.product_name.toLowerCase().includes(term)) return;
    const lines = [...(index.get(item.id)?.values() ?? [])];
    if (view.filter === "unquoted" && lines.length) return;
    if (view.filter === "alternatives" && !lines.some((l) => l.alternative)) return;
    if (view.filter === "chosen" && !lines.some((l) => chosen(selection[l.id]))) return;
    if (
      view.filter === "open" &&
      (remaining(item) <= 0 || lines.some((l) => chosen(selection[l.id])))
    )
      return;
    out.push(i);
  });
  return out;
}
