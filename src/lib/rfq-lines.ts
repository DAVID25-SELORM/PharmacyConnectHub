// Pure helpers for the RFQ medicine list: filtering, paging, bulk edits and de-duplication.
// The screen is a thin layer over these so a request with hundreds of lines stays predictable.

export const RFQ_MAX_LINES = 500;
export const RFQ_MAX_SUPPLIERS = 100;
export const RFQ_UNITS = ["pack", "box", "bottle", "unit", "carton"] as const;
export const RFQ_PAGE_SIZES = [25, 50, 100] as const;
const MAX_QUANTITY = 2147483647;

export type RfqLine = {
  /** Stable identity for React keys and selection; never sent to the database. */
  uid: string;
  productName: string;
  quantity: string;
  notes: string;
  masterProductId: string | null;
  unit: string;
  shelfLifeDays: number;
  alternativesAllowed: boolean;
  partialAllowed: boolean;
  coldChainRequired: boolean;
  specialHandling: string;
};

let counter = 0;
const newUid = () =>
  typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : `line-${Date.now()}-${counter++}`;

export const blankLine = (): RfqLine => ({
  uid: newUid(),
  productName: "",
  quantity: "1",
  notes: "",
  masterProductId: null,
  unit: "pack",
  shelfLifeDays: 90,
  alternativesAllowed: false,
  partialAllowed: true,
  coldChainRequired: false,
  specialHandling: "",
});

/** An untouched row: no medicine named and nothing else changed. */
export const isBlankLine = (line: RfqLine): boolean => {
  const base = blankLine();
  return (
    !line.productName.trim() &&
    !line.notes.trim() &&
    !line.specialHandling.trim() &&
    line.masterProductId === null &&
    line.quantity === base.quantity &&
    line.unit === base.unit &&
    line.shelfLifeDays === base.shelfLifeDays &&
    line.alternativesAllowed === base.alternativesAllowed &&
    line.partialAllowed === base.partialAllowed &&
    line.coldChainRequired === base.coldChainRequired
  );
};

/** What is sent to the database: the line without its client-only identity. */
export const toPayloadItems = (lines: RfqLine[]) => lines.map(({ uid: _uid, ...item }) => item);

export type LineFilter = "all" | "attention" | "unmatched";
export type LineView = { search: string; filter: LineFilter };

/** Indices (into the full list) of the lines the current search and filter show, in list order. */
export function visibleIndices(
  lines: RfqLine[],
  issues: Map<number, string>,
  view: LineView,
): number[] {
  const term = view.search.trim().toLowerCase();
  const out: number[] = [];
  lines.forEach((line, index) => {
    if (term && !`${line.productName} ${line.notes}`.toLowerCase().includes(term)) return;
    if (view.filter === "attention" && !issues.has(index)) return;
    if (view.filter === "unmatched" && line.masterProductId) return;
    out.push(index);
  });
  return out;
}

export type Paged = {
  rows: number[];
  page: number;
  pageCount: number;
  /** 1-based position of the first and last row shown, 0 when the list is empty. */
  from: number;
  to: number;
  total: number;
};

export function pageOf(indices: number[], page: number, size: number): Paged {
  const total = indices.length;
  const pageCount = Math.max(1, Math.ceil(total / size));
  const current = Math.min(Math.max(0, page), pageCount - 1);
  const start = current * size;
  const rows = indices.slice(start, start + size);
  return {
    rows,
    page: current,
    pageCount,
    from: rows.length ? start + 1 : 0,
    to: start + rows.length,
    total,
  };
}

export type LineSummary = {
  total: number;
  matched: number;
  unmatched: number;
  withIssues: number;
  coldChain: number;
};

export function summarize(lines: RfqLine[], issues: Map<number, string>): LineSummary {
  const named = lines.filter((l) => l.productName.trim());
  return {
    total: lines.length,
    matched: named.filter((l) => l.masterProductId).length,
    unmatched: named.filter((l) => !l.masterProductId).length,
    withIssues: issues.size,
    coldChain: lines.filter((l) => l.coldChainRequired).length,
  };
}

export const applyToLines = (
  lines: RfqLine[],
  uids: ReadonlySet<string>,
  patch: Partial<Omit<RfqLine, "uid">>,
): RfqLine[] => lines.map((l) => (uids.has(l.uid) ? { ...l, ...patch } : l));

export const removeLines = (lines: RfqLine[], uids: ReadonlySet<string>): RfqLine[] =>
  lines.filter((l) => !uids.has(l.uid));

const nameKey = (line: RfqLine) => line.productName.trim().toLowerCase();

/** Rows that repeat a medicine are combined into the first occurrence, adding their quantities. */
export function mergeDuplicateLines(lines: RfqLine[]): { lines: RfqLine[]; merged: number } {
  const first = new Map<string, number>();
  const out: RfqLine[] = [];
  let merged = 0;
  for (const line of lines) {
    const key = nameKey(line);
    const at = key ? first.get(key) : undefined;
    if (at === undefined) {
      if (key) first.set(key, out.length);
      out.push(line);
      continue;
    }
    const keep = out[at];
    const a = Number(keep.quantity);
    const b = Number(line.quantity);
    const valid = (n: number) => Number.isSafeInteger(n) && n > 0;
    out[at] = {
      ...keep,
      quantity: valid(a) && valid(b) ? String(Math.min(a + b, MAX_QUANTITY)) : keep.quantity,
      masterProductId: keep.masterProductId ?? line.masterProductId,
      notes: [keep.notes, line.notes].filter((n, i, all) => n && all.indexOf(n) === i).join(" "),
    };
    merged++;
  }
  return { lines: out, merged };
}

/** First line (by list order) that needs attention, or -1. */
export const firstIssueIndex = (issues: Map<number, string>): number =>
  issues.size ? Math.min(...issues.keys()) : -1;

/** Adds lines to the end of the list, dropping untouched rows and respecting the per-RFQ limit. */
export function appendLines(
  existing: RfqLine[],
  incoming: RfqLine[],
  max = RFQ_MAX_LINES,
): { lines: RfqLine[]; added: number; dropped: number } {
  const kept = existing.filter((l) => !isBlankLine(l));
  const room = Math.max(0, max - kept.length);
  const take = incoming.slice(0, room);
  return { lines: [...kept, ...take], added: take.length, dropped: incoming.length - take.length };
}
