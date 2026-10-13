import { describe, expect, it } from "vitest";
import type { Requirement } from "./enterprise-rfq";
import {
  applyToDraft,
  blankDraftLine,
  expiryFloor,
  fillPrices,
  lineIssue,
  lineIssues,
  matchCatalogue,
  offerFullQuantity,
  stopQuoting,
  summarizeQuote,
  toPayloadLines,
  visibleQuoteIndices,
  type DraftLine,
} from "./rfq-quote-lines";

const item = (over: Partial<Requirement> = {}): Requirement =>
  ({
    id: "i1",
    rfq_id: "r1",
    product_name: "Paracetamol 500mg",
    quantity: 100,
    notes: null,
    master_product_id: "m1",
    specification: {},
    unit: "pack",
    minimum_shelf_life_days: 90,
    alternatives_allowed: false,
    partial_allowed: true,
    cold_chain_required: false,
    special_handling: null,
    cancelled_quantity: 0,
    ...over,
  }) as Requirement;
const ctx = {
  expectedDelivery: "2026-11-01",
  today: "2026-10-13",
  offeredMaster: "m1" as string | null | undefined,
};
const good = (it: Requirement, over: Partial<DraftLine> = {}): DraftLine => ({
  ...blankDraftLine(it),
  productId: "p1",
  unitPriceGhs: "10",
  expiryDate: "2027-12-31",
  ...over,
});

describe("expiry floor", () => {
  it("counts the shelf life from the expected delivery when it is later than today", () => {
    expect(expiryFloor("2026-11-01", 90, "2026-10-13")).toBe("2027-01-30");
  });
  it("counts from today when there is no delivery date or it has passed", () => {
    expect(expiryFloor(null, 90, "2026-10-13")).toBe("2027-01-11");
    expect(expiryFloor("2026-01-01", 30, "2026-10-13")).toBe("2026-11-12");
  });
});

describe("one quoted line", () => {
  const it1 = item();
  it("accepts a complete, valid line and ignores lines that are not being quoted", () => {
    expect(lineIssue(good(it1), it1, ctx)).toBeNull();
    expect(lineIssue(blankDraftLine(it1), it1, ctx)).toBeNull();
  });
  it("needs a whole number of units that does not exceed the request", () => {
    expect(lineIssue(good(it1, { quantity: "2.5" }), it1, ctx)).toMatch(/whole number/);
    expect(lineIssue(good(it1, { quantity: "0" }), it1, ctx)).toMatch(/whole number/);
    expect(lineIssue(good(it1, { quantity: "101" }), it1, ctx)).toMatch(/more than the 100 pack/);
    expect(lineIssue(good(it1, { quantity: "60" }), it1, ctx)).toBeNull();
  });
  it("requires exactly the full quantity when partial supply is not allowed", () => {
    const full = item({ partial_allowed: false });
    expect(lineIssue(good(full, { quantity: "60" }), full, ctx)).toMatch(/full 100 pack/);
    expect(lineIssue(good(full, { quantity: "100" }), full, ctx)).toBeNull();
  });
  it("needs a positive price and a sensible discount", () => {
    expect(lineIssue(good(it1, { unitPriceGhs: "" }), it1, ctx)).toMatch(/unit price/);
    expect(lineIssue(good(it1, { unitPriceGhs: "0" }), it1, ctx)).toMatch(/unit price/);
    expect(lineIssue(good(it1, { discountPercent: "100" }), it1, ctx)).toMatch(/Discount/);
    expect(lineIssue(good(it1, { discountPercent: "-1" }), it1, ctx)).toMatch(/Discount/);
    expect(lineIssue(good(it1, { discountPercent: "99.99" }), it1, ctx)).toBeNull();
  });
  it("needs an expiry strictly after the shelf-life floor", () => {
    expect(lineIssue(good(it1, { expiryDate: "" }), it1, ctx)).toMatch(/expiry date/);
    expect(lineIssue(good(it1, { expiryDate: "2027-01-30" }), it1, ctx)).toMatch(
      /after 2027-01-30/,
    );
    expect(lineIssue(good(it1, { expiryDate: "2027-01-31" }), it1, ctx)).toBeNull();
  });
  it("requires a cold chain confirmation when the buyer needs one", () => {
    const cold = item({ cold_chain_required: true });
    expect(lineIssue(good(cold), cold, ctx)).toMatch(/cold chain/);
    expect(lineIssue(good(cold, { coldChainSupported: true }), cold, ctx)).toBeNull();
  });
  it("treats a different catalogue medicine as an alternative that must be allowed", () => {
    const other = { ...ctx, offeredMaster: "m2" };
    expect(lineIssue(good(it1), it1, other)).toMatch(/not the requested catalogue medicine/);
    expect(lineIssue(good(it1, { alternative: true }), it1, other)).toMatch(
      /does not allow alternatives/,
    );
    const alt = item({ alternatives_allowed: true });
    expect(lineIssue(good(alt, { alternative: true, conversion: "1" }), alt, other)).toBeNull();
  });
  it("does not judge the medicine identity until the product is known", () => {
    expect(lineIssue(good(it1), it1, { ...ctx, offeredMaster: undefined })).toBeNull();
  });
  it("scales the offered quantity by the alternative conversion", () => {
    const alt = item({ alternatives_allowed: true });
    expect(
      lineIssue(good(alt, { alternative: true, quantity: "60", conversion: "2" }), alt, ctx),
    ).toMatch(/more than/);
    expect(
      lineIssue(good(alt, { alternative: true, quantity: "50", conversion: "2" }), alt, ctx),
    ).toBeNull();
    expect(lineIssue(good(alt, { alternative: true, conversion: "0" }), alt, ctx)).toMatch(
      /units one offered unit/,
    );
  });
});

describe("summary and money", () => {
  const a = item({ id: "a" });
  const b = item({ id: "b" });
  const c = item({ id: "c" });
  const items = new Map([a, b, c].map((i) => [i.id, i]));
  it("counts quoted, unquoted and problem lines and estimates the total like the database", () => {
    const lines = [
      good(a, { rfqItemId: "a", quantity: "10", unitPriceGhs: "10.00", discountPercent: "10" }),
      good(b, { rfqItemId: "b", unitPriceGhs: "" }),
      blankDraftLine(c),
    ];
    const issues = lineIssues(lines, items, () => ctx);
    expect([...issues.keys()]).toEqual(["b"]);
    const s = summarizeQuote(lines, issues, 5);
    expect([s.total, s.quoted, s.unquoted, s.withIssues]).toEqual([3, 2, 1, 1]);
    // 10.00 less 10% = 9.00, less 5% order discount = 8.55, times 10 units
    expect(s.estimate).toBe(85.5);
  });
});

describe("filtering", () => {
  const a = item({ id: "a", product_name: "Amoxicillin" });
  const b = item({ id: "b", product_name: "Paracetamol" });
  const items = new Map([a, b].map((i) => [i.id, i]));
  const lines = [good(a, { rfqItemId: "a" }), blankDraftLine(b)];
  const issues = new Map([["a", "x"]]);
  it("filters by state and searches the requested names", () => {
    expect(visibleQuoteIndices(lines, items, issues, { search: "", filter: "quoted" })).toEqual([
      0,
    ]);
    expect(visibleQuoteIndices(lines, items, issues, { search: "", filter: "unquoted" })).toEqual([
      1,
    ]);
    expect(visibleQuoteIndices(lines, items, issues, { search: "", filter: "attention" })).toEqual([
      0,
    ]);
    expect(visibleQuoteIndices(lines, items, issues, { search: "PARA", filter: "all" })).toEqual([
      1,
    ]);
  });
});

describe("bulk actions", () => {
  const a = item({ id: "a", quantity: 50 });
  const b = item({ id: "b", quantity: 70 });
  const items = new Map([a, b].map((i) => [i.id, i]));
  const lines = [
    good(a, { rfqItemId: "a", quantity: "10" }),
    good(b, { rfqItemId: "b", quantity: "5", discountPercent: "3" }),
  ];
  it("applies a change to the chosen lines only", () => {
    const out = applyToDraft(lines, new Set(["b"]), { discountPercent: "12" });
    expect(out.map((l) => l.discountPercent)).toEqual(["0", "12"]);
  });
  it("offers the full requested quantity on quoted lines", () => {
    expect(offerFullQuantity(lines, new Set(["a", "b"]), items).map((l) => l.quantity)).toEqual([
      "50",
      "70",
    ]);
  });
  it("leaves alternatives alone when filling quantities", () => {
    const alt = [{ ...lines[0], alternative: true }, lines[1]];
    expect(offerFullQuantity(alt, new Set(["a", "b"]), items).map((l) => l.quantity)).toEqual([
      "10",
      "70",
    ]);
  });
  it("stops quoting and forgets the quoted values", () => {
    const out = stopQuoting(lines, new Set(["a"]), items);
    expect(out[0].productId).toBe("");
    expect(out[0].unitPriceGhs).toBe("");
    expect(out[0].quantity).toBe("50");
    expect(out[1].productId).toBe("p1");
  });
});

describe("catalogue matching", () => {
  const a = item({ id: "a", master_product_id: "m1" });
  const b = item({ id: "b", master_product_id: "m2" });
  const c = item({ id: "c", master_product_id: null });
  const d = item({ id: "d", master_product_id: "m4" });
  const items = new Map([a, b, c, d].map((i) => [i.id, i]));
  it("fills only exact, unambiguous matches and never overwrites existing choices", () => {
    const lines = [
      blankDraftLine(a),
      blankDraftLine(b),
      blankDraftLine(c),
      { ...blankDraftLine(d), productId: "mine" },
    ];
    const out = matchCatalogue(
      lines,
      items,
      new Map([
        ["m1", ["p1"]],
        ["m2", ["p2", "p3"]],
        ["m4", ["p4"]],
      ]),
    );
    expect(out.lines.map((l) => l.productId)).toEqual(["p1", "", "", "mine"]);
    expect([out.matched, out.ambiguous]).toEqual([1, 1]);
  });
});

describe("payload", () => {
  it("sends only quoted lines and ignores a stale conversion on a normal line", () => {
    const it1 = item();
    const lines = [good(it1, { conversion: "2" }), blankDraftLine(item({ id: "z" }))];
    const out = toPayloadLines(lines);
    expect(out).toHaveLength(1);
    expect(out[0].conversion).toBe("1");
    expect(toPayloadLines([good(it1, { alternative: true, conversion: "2" })])[0].conversion).toBe(
      "2",
    );
  });
});

describe("filling prices from the catalogue", () => {
  const a = item({ id: "a" });
  const lines = [
    good(a, { rfqItemId: "a", productId: "p1", unitPriceGhs: "" }),
    good(a, { rfqItemId: "b", productId: "p2", unitPriceGhs: "7.00" }),
    { ...blankDraftLine(a), rfqItemId: "c" },
    good(a, { rfqItemId: "d", productId: "p9", unitPriceGhs: "" }),
  ];
  it("fills only empty prices on chosen quoted lines and leaves existing prices alone", () => {
    const out = fillPrices(
      lines,
      new Set(["a", "b", "c", "d"]),
      (id) => ({ p1: 12.5, p2: 99 })[id as "p1" | "p2"],
    );
    expect(out.filled).toBe(1);
    expect(out.lines.map((l) => l.unitPriceGhs)).toEqual(["12.50", "7.00", "", ""]);
  });
  it("skips lines that are not chosen", () => {
    expect(fillPrices(lines, new Set(["b"]), () => 5).filled).toBe(0);
  });
});
