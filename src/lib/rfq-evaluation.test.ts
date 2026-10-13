import { describe, expect, it } from "vitest";
import type { QuoteVersion, Requirement, VersionLine } from "./enterprise-rfq";
import {
  allocationPayload,
  buildLineIndex,
  cheapestPlan,
  coverage,
  landedTotal,
  lowestPriceLineIds,
  pricePerRequestedUnit,
  selectionIssues,
  selectionTotals,
  visibleRequirements,
  wholeQuote,
} from "./rfq-evaluation";

const item = (id: string, over: Partial<Requirement> = {}): Requirement =>
  ({
    id,
    rfq_id: "r",
    product_name: `Medicine ${id}`,
    quantity: 100,
    notes: null,
    master_product_id: "m",
    specification: {},
    unit: "pack",
    minimum_shelf_life_days: 30,
    alternatives_allowed: true,
    partial_allowed: true,
    cold_chain_required: false,
    special_handling: null,
    cancelled_quantity: 0,
    ...over,
  }) as Requirement;
const line = (id: string, itemId: string, over: Partial<VersionLine> = {}): VersionLine =>
  ({
    id,
    rfq_quote_id: "q",
    rfq_item_id: itemId,
    product_id: "p",
    quantity: 100,
    unit_price_ghs: 10,
    discount_percent: 0,
    final_unit_price_ghs: 10,
    line_total_ghs: 1000,
    notes: null,
    alternative: false,
    offered_specification: {},
    requested_units_per_offered_unit: 1,
    expiry_date: "2030-01-01",
    batch_number: null,
    expected_available_on: null,
    cold_chain_supported: false,
    special_handling: null,
    ...over,
  }) as VersionLine;
const version = (
  id: string,
  lines: VersionLine[],
  quote: Record<string, unknown> = {},
): QuoteVersion =>
  ({
    id,
    quote_id: `q-${id}`,
    wholesaler_id: `w-${id}`,
    version: 1,
    reason: "",
    created_at: "",
    snapshot: {
      quote: { total_ghs: 1000, delivery_charge_ghs: 50, ...quote },
      items: lines,
      orderDiscountPercent: 0,
      taxTreatment: "",
    },
  }) as unknown as QuoteVersion;

const items = [item("a"), item("b"), item("c", { partial_allowed: false })];
const A = version("A", [
  line("A-a", "a", { final_unit_price_ghs: 10 }),
  line("A-b", "b", { final_unit_price_ghs: 5, quantity: 40 }),
]);
const B = version(
  "B",
  [
    line("B-a", "a", { final_unit_price_ghs: 8 }),
    line("B-b", "b", { final_unit_price_ghs: 7 }),
    line("B-c", "c", { final_unit_price_ghs: 3 }),
  ],
  { total_ghs: 700, delivery_charge_ghs: 0 },
);
const full = (it: Requirement) => it.quantity;

describe("comparing prices", () => {
  it("marks the lowest price per requirement, only where suppliers compete", () => {
    const low = lowestPriceLineIds(buildLineIndex([A, B]));
    expect([...low].sort()).toEqual(["A-b", "B-a"]);
  });
  it("marks every line of a tie", () => {
    const tie = version("T", [line("T-a", "a", { final_unit_price_ghs: 8 })]);
    expect([...lowestPriceLineIds(buildLineIndex([B, tie]))]).toContain("T-a");
  });
  it("compares by price per requested unit when an alternative is packaged differently", () => {
    const alt = line("X", "a", { final_unit_price_ghs: 18, requested_units_per_offered_unit: 2 });
    expect(pricePerRequestedUnit(alt)).toBe(9);
  });
  it("works out the landed total and how much of the request a quotation covers", () => {
    expect(landedTotal(A)).toBe(1050);
    expect(coverage(A, items)).toEqual({ quoted: 2, total: 3, complete: 1 });
  });
});

describe("what an award selection is allowed to be", () => {
  const remaining = full;
  const run = (
    selection: Record<string, string>,
    accepted: Record<string, boolean> = {},
    versions = [A, B],
  ) => selectionIssues(items, versions, selection, accepted, remaining);
  it("accepts a sensible selection and ignores empty or zero entries", () => {
    expect(run({ "A-a": "60", "B-a": "40", "A-b": "", "B-b": "0" }).size).toBe(0);
  });
  it("rejects fractions, and more than a supplier offered", () => {
    expect(run({ "A-a": "2.5" }).get("A-a")).toMatch(/whole number/);
    expect(run({ "A-b": "41" }).get("A-b")).toMatch(/Only 40 offered/);
  });
  it("stops the total across suppliers exceeding what is still needed", () => {
    const issues = run({ "A-a": "70", "B-a": "50" });
    expect(issues.get("A-a")).toMatch(/100 pack still needed/);
    expect(issues.get("B-a")).toMatch(/100 pack still needed/);
    expect(run({ "A-a": "70", "B-a": "30" }).size).toBe(0);
  });
  it("counts only what is still unresolved", () => {
    const left = (it: Requirement) => (it.id === "a" ? 30 : it.quantity);
    expect(selectionIssues(items, [A, B], { "A-a": "40" }, {}, left).get("A-a")).toMatch(
      /30 pack still needed/,
    );
  });
  it("requires an explicit acceptance of an alternative, and converts its units", () => {
    const alt = version("C", [
      line("C-a", "a", { alternative: true, requested_units_per_offered_unit: 2, quantity: 50 }),
    ]);
    expect(run({ "C-a": "10" }, {}, [alt]).get("C-a")).toMatch(/Accept/);
    expect(run({ "C-a": "10" }, { "C-a": true }, [alt]).size).toBe(0);
    expect(run({ "C-a": "50" }, { "C-a": true }, [alt]).size).toBe(0);
    const over = version("D", [
      line("D-a", "a", { alternative: true, requested_units_per_offered_unit: 2, quantity: 80 }),
    ]);
    expect(run({ "D-a": "60" }, { "D-a": true }, [over]).get("D-a")).toMatch(/still needed/);
  });
  it("needs the full quantity where partial supply is not allowed", () => {
    expect(run({ "B-c": "60" }).get("B-c")).toMatch(/partial awards are not allowed/);
    expect(run({ "B-c": "100" }).size).toBe(0);
  });
});

describe("totals and the award request", () => {
  it("totals each supplier's selection and adds its delivery charge once", () => {
    const totals = selectionTotals([A, B], { "A-a": "10", "A-b": "20", "B-a": "5" });
    expect(totals).toEqual([
      { versionId: "A", lines: 2, goods: 200, delivery: 50, total: 250 },
      { versionId: "B", lines: 1, goods: 40, delivery: 0, total: 40 },
    ]);
  });
  it("leaves out suppliers that nothing was chosen from", () => {
    expect(selectionTotals([A, B], { "B-a": "5" }).map((t) => t.versionId)).toEqual(["B"]);
  });
  it("builds the request from positive quantities only", () => {
    const out = allocationPayload(
      [A, B],
      { "A-a": "10", "B-b": "0", "B-a": "3" },
      { "B-a": true },
      "nhis",
    );
    expect(out).toEqual([
      {
        versionId: "A",
        quoteItemId: "A-a",
        quantity: 10,
        acceptAlternative: false,
        category: "nhis",
      },
      {
        versionId: "B",
        quoteItemId: "B-a",
        quantity: 3,
        acceptAlternative: true,
        category: "nhis",
      },
    ]);
  });
  it("selects a whole quotation at its offered quantities", () => {
    expect(wholeQuote(A)).toEqual({ "A-a": "100", "A-b": "40" });
  });
});

describe("cheapest-first starting point", () => {
  it("fills each requirement from the lowest price up and never exceeds what is needed", () => {
    // b: A offers 40 at 5, B offers 100 at 7 -> 40 from A, 60 from B
    const plan = cheapestPlan(items, [A, B], full);
    expect(plan["B-a"]).toBe("100");
    expect(plan["A-a"]).toBeUndefined();
    expect(plan["A-b"]).toBe("40");
    expect(plan["B-b"]).toBe("60");
    expect(selectionIssues(items, [A, B], plan, {}, full).size).toBe(0);
  });
  it("skips resolved requirements and takes only the remainder", () => {
    const left = (it: Requirement) => (it.id === "b" ? 10 : it.id === "a" ? 0 : it.quantity);
    const plan = cheapestPlan(items, [A, B], left);
    expect(plan).toEqual({ "A-b": "10", "B-c": "100" });
  });
  it("never picks an alternative on its own", () => {
    const alt = version("C", [line("C-a", "a", { final_unit_price_ghs: 1, alternative: true })]);
    expect(cheapestPlan(items, [A, alt], full)["C-a"]).toBeUndefined();
  });
  it("gives a no-partial requirement to the cheapest quote that covers all of it, or to nobody", () => {
    const small = version("S", [line("S-c", "c", { quantity: 50, final_unit_price_ghs: 1 })]);
    expect(cheapestPlan(items, [B, small], full)["B-c"]).toBe("100");
    expect(cheapestPlan(items, [B, small], full)["S-c"]).toBeUndefined();
    expect(cheapestPlan(items, [small], full)).toEqual({});
  });
});

describe("which requirements the matrix shows", () => {
  const index = buildLineIndex([A, B]);
  const show = (
    filter: Parameters<typeof visibleRequirements>[4]["filter"],
    search = "",
    selection = {},
  ) =>
    visibleRequirements(items, index, selection, full, { search, filter }).map((i) => items[i].id);
  it("filters by search and by state", () => {
    expect(show("all", "medicine b")).toEqual(["b"]);
    expect(show("unquoted")).toEqual([]);
    expect(show("chosen", "", { "A-b": "5" })).toEqual(["b"]);
    expect(show("open", "", { "A-b": "5" })).toEqual(["a", "c"]);
    expect(show("alternatives")).toEqual([]);
  });
  it("finds requirements nobody quoted", () => {
    expect(
      visibleRequirements(items, buildLineIndex([A]), {}, full, {
        search: "",
        filter: "unquoted",
      }).map((i) => items[i].id),
    ).toEqual(["c"]);
  });
});
