import { describe, expect, it } from "vitest";
import {
  applyLegacy,
  legacyIssues,
  legacyLineIssue,
  legacySummary,
  setIncluded,
  visibleLegacyIndices,
} from "./rfq-legacy";
import { validateQuoteDraft, type QuoteLineDraft, type RfqItem } from "./rfq";

const item = (id: string, name = `Item ${id}`, quantity = 10): RfqItem =>
  ({ id, rfq_id: "r", product_name: name, quantity, notes: null }) as RfqItem;
const line = (id: string, over: Partial<QuoteLineDraft> = {}): QuoteLineDraft => ({
  rfqItemId: id,
  productId: "p",
  unitPriceGhs: "5",
  quantity: "",
  discountPercent: "",
  notes: "",
  include: true,
  ...over,
});
const a = item("a");

describe("one line of a legacy quotation", () => {
  it("has no problems when it is complete, or when it is not being quoted", () => {
    expect(legacyLineIssue(line("a"), a)).toBeNull();
    expect(
      legacyLineIssue(line("a", { include: false, productId: "", unitPriceGhs: "" }), a),
    ).toBeNull();
  });
  it("needs a product and a price above zero", () => {
    expect(legacyLineIssue(line("a", { productId: "" }), a)).toMatch(/Choose your product/);
    expect(legacyLineIssue(line("a", { unitPriceGhs: "" }), a)).toMatch(/unit price/);
    expect(legacyLineIssue(line("a", { unitPriceGhs: "0" }), a)).toMatch(/unit price/);
  });
  it("keeps the available quantity within what was requested", () => {
    expect(legacyLineIssue(line("a", { quantity: "11" }), a)).toMatch(/1 to 10/);
    expect(legacyLineIssue(line("a", { quantity: "2.5" }), a)).toMatch(/whole number/);
    expect(legacyLineIssue(line("a", { quantity: "10" }), a)).toBeNull();
  });
  it("keeps the discount sensible", () => {
    expect(legacyLineIssue(line("a", { discountPercent: "100" }), a)).toMatch(/discount/i);
    expect(legacyLineIssue(line("a", { discountPercent: "-1" }), a)).toMatch(/discount/i);
    expect(legacyLineIssue(line("a", { discountPercent: "10" }), a)).toBeNull();
  });
  it("agrees with the existing whole-quotation validation about what is valid", () => {
    const cases = [
      line("a"),
      line("a", { productId: "" }),
      line("a", { unitPriceGhs: "-3" }),
      line("a", { quantity: "99" }),
      line("a", { discountPercent: "100" }),
      line("a", { quantity: "4", discountPercent: "5" }),
    ];
    for (const c of cases) {
      const whole = validateQuoteDraft([c], { a: 10 });
      expect(legacyLineIssue(c, a) === null).toBe(whole.error === null);
    }
  });
});

describe("summary and filtering", () => {
  const items = new Map(
    [item("a", "Amoxicillin"), item("b", "Paracetamol"), item("c", "Vitamin C")].map((i) => [
      i.id,
      i,
    ]),
  );
  const lines = [
    line("a", { unitPriceGhs: "10", discountPercent: "10", quantity: "5" }),
    line("b", { productId: "" }),
    line("c", { include: false }),
  ];
  const issues = legacyIssues(lines, items);
  it("finds the lines that need attention", () => {
    expect([...issues.keys()]).toEqual(["b"]);
  });
  it("counts and totals only the lines that are ready, at the price after discount", () => {
    expect(legacySummary(lines, items, issues)).toEqual({
      total: 3,
      included: 2,
      withIssues: 1,
      estimate: 45,
    });
  });
  it("uses the full requested quantity when no available quantity is given", () => {
    const s = legacySummary([line("a", { unitPriceGhs: "2" })], items, new Map());
    expect(s.estimate).toBe(20);
  });
  it("filters and searches", () => {
    const show = (filter: Parameters<typeof visibleLegacyIndices>[3]["filter"], search = "") =>
      visibleLegacyIndices(lines, items, issues, { search, filter });
    expect(show("included")).toEqual([0, 1]);
    expect(show("excluded")).toEqual([2]);
    expect(show("attention")).toEqual([1]);
    expect(show("all", "PARA")).toEqual([1]);
  });
  it("includes or changes only the chosen lines", () => {
    expect(setIncluded(lines, new Set(["c"]), true).map((l) => l.include)).toEqual([
      true,
      true,
      true,
    ]);
    expect(
      applyLegacy(lines, new Set(["a"]), { discountPercent: "3" }).map((l) => l.discountPercent),
    ).toEqual(["3", "", ""]);
  });
});
