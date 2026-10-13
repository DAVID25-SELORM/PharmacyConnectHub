import { describe, expect, it } from "vitest";
import {
  appendLines,
  applyToLines,
  blankLine,
  firstIssueIndex,
  isBlankLine,
  mergeDuplicateLines,
  pageOf,
  removeLines,
  summarize,
  toPayloadItems,
  visibleIndices,
  type RfqLine,
} from "./rfq-lines";
import { rfqRowIssues } from "./rfq-bulk";

const line = (name: string, over: Partial<RfqLine> = {}): RfqLine => ({
  ...blankLine(),
  productName: name,
  ...over,
});
const many = (n: number) => Array.from({ length: n }, (_, i) => line(`Medicine ${i + 1}`));

describe("paging a long list", () => {
  it("shows the requested slice with 1-based positions", () => {
    const p = pageOf(visibleIndices(many(120), new Map(), { search: "", filter: "all" }), 1, 50);
    expect(p.rows[0]).toBe(50);
    expect(p.rows).toHaveLength(50);
    expect([p.from, p.to, p.total, p.pageCount]).toEqual([51, 100, 120, 3]);
  });
  it("keeps the last short page and clamps an out-of-range page", () => {
    const idx = visibleIndices(many(120), new Map(), { search: "", filter: "all" });
    expect(pageOf(idx, 2, 50).rows).toHaveLength(20);
    expect(pageOf(idx, 99, 50).page).toBe(2);
    expect(pageOf(idx, -3, 50).page).toBe(0);
  });
  it("copes with an empty list", () => {
    expect(pageOf([], 0, 25)).toMatchObject({ rows: [], from: 0, to: 0, total: 0, pageCount: 1 });
  });
  it("handles the 500-line limit", () => {
    const p = pageOf(visibleIndices(many(500), new Map(), { search: "", filter: "all" }), 19, 25);
    expect([p.from, p.to, p.pageCount]).toEqual([476, 500, 20]);
  });
});

describe("searching and filtering", () => {
  const lines = [
    line("Paracetamol 500mg", { masterProductId: "p1" }),
    line("Amoxicillin 250mg"),
    line("Vitamin C", { notes: "effervescent", masterProductId: "p3" }),
  ];
  const issues = new Map([[1, "Unmatched"]]);
  it("searches medicine names and notes, ignoring case", () => {
    expect(visibleIndices(lines, issues, { search: "PARA", filter: "all" })).toEqual([0]);
    expect(visibleIndices(lines, issues, { search: "efferv", filter: "all" })).toEqual([2]);
  });
  it("lists only lines that need attention, or only unmatched ones", () => {
    expect(visibleIndices(lines, issues, { search: "", filter: "attention" })).toEqual([1]);
    expect(visibleIndices(lines, issues, { search: "", filter: "unmatched" })).toEqual([1]);
  });
  it("keeps full-list indices so row errors still point at the right line", () => {
    expect(visibleIndices(lines, issues, { search: "mg", filter: "all" })).toEqual([0, 1]);
  });
});

describe("summary", () => {
  it("counts matched, unmatched and flagged lines", () => {
    const lines = [
      line("A", { masterProductId: "x" }),
      line("B"),
      line(""),
      line("C", { coldChainRequired: true }),
    ];
    const s = summarize(lines, new Map([[2, "Enter a medicine name."]]));
    expect(s).toEqual({ total: 4, matched: 1, unmatched: 2, withIssues: 1, coldChain: 1 });
  });
  it("finds the first problem line", () => {
    expect(
      firstIssueIndex(
        new Map([
          [7, "x"],
          [3, "y"],
        ]),
      ),
    ).toBe(3);
    expect(firstIssueIndex(new Map())).toBe(-1);
  });
});

describe("bulk edits", () => {
  it("changes only the selected lines", () => {
    const lines = many(5);
    const chosen = new Set([lines[1].uid, lines[3].uid]);
    const out = applyToLines(lines, chosen, { unit: "carton", coldChainRequired: true });
    expect(out.map((l) => l.unit)).toEqual(["pack", "carton", "pack", "carton", "pack"]);
    expect(out.filter((l) => l.coldChainRequired)).toHaveLength(2);
    expect(lines[1].unit).toBe("pack");
  });
  it("removes the selected lines and keeps the order of the rest", () => {
    const lines = many(4);
    const out = removeLines(lines, new Set([lines[0].uid, lines[2].uid]));
    expect(out.map((l) => l.productName)).toEqual(["Medicine 2", "Medicine 4"]);
  });
});

describe("merging duplicate medicines", () => {
  it("adds quantities into the first occurrence, ignoring case and spacing", () => {
    const { lines, merged } = mergeDuplicateLines([
      line("Paracetamol 500mg", { quantity: "10" }),
      line("Amoxicillin"),
      line("  paracetamol 500MG ", { quantity: "5", notes: "urgent" }),
    ]);
    expect(merged).toBe(1);
    expect(lines.map((l) => [l.productName, l.quantity])).toEqual([
      ["Paracetamol 500mg", "15"],
      ["Amoxicillin", "1"],
    ]);
    expect(lines[0].notes).toBe("urgent");
    expect(rfqRowIssues(lines).size).toBe(0);
  });
  it("keeps a catalogue identity found on a later duplicate", () => {
    const { lines } = mergeDuplicateLines([line("A"), line("a", { masterProductId: "m1" })]);
    expect(lines[0].masterProductId).toBe("m1");
  });
  it("never merges blank rows together and caps the quantity", () => {
    expect(mergeDuplicateLines([line(""), line("")]).merged).toBe(0);
    const big = mergeDuplicateLines([
      line("A", { quantity: "2147483647" }),
      line("A", { quantity: "5" }),
    ]);
    expect(big.lines[0].quantity).toBe("2147483647");
  });
  it("does not invent a total from an invalid quantity", () => {
    const { lines } = mergeDuplicateLines([
      line("A", { quantity: "abc" }),
      line("A", { quantity: "5" }),
    ]);
    expect(lines[0].quantity).toBe("abc");
  });
});

describe("rows and payload", () => {
  it("recognises an untouched row, and any change makes it a real one", () => {
    expect(isBlankLine(blankLine())).toBe(true);
    expect(isBlankLine({ ...blankLine(), productName: "A" })).toBe(false);
    expect(isBlankLine({ ...blankLine(), quantity: "4" })).toBe(false);
    expect(isBlankLine({ ...blankLine(), coldChainRequired: true })).toBe(false);
  });
  it("sends no client-only identity to the database", () => {
    const [item] = toPayloadItems([line("A")]);
    expect(item).not.toHaveProperty("uid");
    expect(item.productName).toBe("A");
  });
  it("gives every new row its own identity", () => {
    expect(new Set(many(50).map((l) => l.uid)).size).toBe(50);
  });
});

describe("adding lines", () => {
  it("appends after the existing lines and drops untouched rows", () => {
    const out = appendLines([line("A"), blankLine()], [line("B"), line("C")]);
    expect(out.lines.map((l) => l.productName)).toEqual(["A", "B", "C"]);
    expect([out.added, out.dropped]).toEqual([2, 0]);
  });
  it("stops at the limit and reports what did not fit", () => {
    const out = appendLines(many(498), many(5), 500);
    expect(out.lines).toHaveLength(500);
    expect([out.added, out.dropped]).toEqual([2, 3]);
  });
  it("adds nothing when the list is already full", () => {
    const out = appendLines(many(500), many(3));
    expect([out.lines.length, out.added, out.dropped]).toEqual([500, 0, 3]);
  });
});
