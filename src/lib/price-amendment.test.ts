import { describe, expect, it } from "vitest";
import type { Amendment, OrderAmendmentsView } from "./order-amendments";
import {
  canProposePriceChange,
  draftPrice,
  parsePrice,
  priceAcceptanceConsequence,
  priceDraftFromView,
  priceDraftTotals,
  pricePayload,
  priceResponseSummary,
  priceSummary,
  validatePriceDraft,
} from "./price-amendment";

const view = (overrides: Partial<OrderAmendmentsView> = {}): OrderAmendmentsView => ({
  order_id: "o1",
  order_number: "ORD-1",
  status: "accepted",
  original_total: 2000,
  current_total: 2000,
  amended: false,
  is_credit_order: true,
  open_amendment_id: null,
  stock_evidence: true,
  lines: [
    {
      order_item_id: "a",
      product_name: "BO A",
      ordered_qty: 10,
      supplied_qty: 10,
      unit_price_ghs: 100,
    },
    {
      order_item_id: "b",
      product_name: "BO B",
      ordered_qty: 20,
      supplied_qty: 15,
      unit_price_ghs: 50,
    },
  ],
  amendments: [],
  ...overrides,
});

describe("who can start a price change", () => {
  it("only while the order is being prepared and nothing else is open", () => {
    expect(canProposePriceChange(view(), "accepted")).toBe(true);
    expect(canProposePriceChange(view(), "ready_for_dispatch")).toBe(true);
    expect(canProposePriceChange(view(), "pending")).toBe(false);
    expect(canProposePriceChange(view(), "dispatched")).toBe(false);
    expect(canProposePriceChange(view({ open_amendment_id: "x" }), "accepted")).toBe(false);
    expect(canProposePriceChange(null, "accepted")).toBe(false);
  });

  it("not on a cash order that has been paid, but on a paid credit order", () => {
    expect(canProposePriceChange(view({ is_credit_order: false }), "accepted", "paid")).toBe(false);
    expect(canProposePriceChange(view({ is_credit_order: false }), "accepted", "unpaid")).toBe(
      true,
    );
    expect(canProposePriceChange(view(), "accepted", "paid")).toBe(true);
  });
});

describe("the draft", () => {
  it("starts untouched and works on the units now committed", () => {
    const draft = priceDraftFromView(view());
    expect(draft.map((line) => [line.committed_qty, line.current_price, line.next])).toEqual([
      [10, 100, ""],
      [15, 50, ""],
    ]);
    expect(pricePayload(draft)).toEqual([]);
  });

  it("accepts only amounts above zero with at most two decimals", () => {
    expect(parsePrice("12")).toBe(12);
    expect(parsePrice(" 12.5 ")).toBe(12.5);
    expect(parsePrice("12.50")).toBe(12.5);
    expect(parsePrice("12.505")).toBeNull();
    expect(parsePrice("0")).toBeNull();
    expect(parsePrice("-3")).toBeNull();
    expect(parsePrice("abc")).toBeNull();
    expect(parsePrice("1e3")).toBeNull();
  });

  it("works out the effect per line and in total (+200 on BO A, -75 on BO B)", () => {
    const draft = priceDraftFromView(view()).map((line) =>
      line.order_item_id === "a" ? { ...line, next: "120" } : { ...line, next: "45" },
    );
    expect(draftPrice(draft[0])).toEqual({ value: 120, changed: true });
    expect(priceDraftTotals(draft, 2000)).toEqual({ changedLines: 2, delta: 125, newTotal: 2125 });
    expect(pricePayload(draft)).toEqual([
      { order_item_id: "a", unit_price_ghs: 120 },
      { order_item_id: "b", unit_price_ghs: 45 },
    ]);
  });

  it("sends only the lines whose price really changes", () => {
    const draft = priceDraftFromView(view()).map((line) =>
      line.order_item_id === "a" ? { ...line, next: "100" } : { ...line, next: "45" },
    );
    expect(pricePayload(draft)).toEqual([{ order_item_id: "b", unit_price_ghs: 45 }]);
  });

  it("explains what is wrong, in order", () => {
    const base = priceDraftFromView(view());
    expect(validatePriceDraft(base, "supplier cost", 2000)).toMatch(/at least one product/);
    expect(
      validatePriceDraft(
        base.map((l) => ({ ...l, next: "abc" })),
        "supplier cost",
        2000,
      ),
    ).toMatch(/Enter the new price of BO A/);
    expect(
      validatePriceDraft(
        base.map((l) => ({ ...l, next: String(l.current_price) })),
        "supplier cost",
        2000,
      ),
    ).toMatch(/same as its current price/);
    const priced = base.map((l) => ({ ...l, next: l.order_item_id === "a" ? "120" : "" }));
    expect(validatePriceDraft(priced, "no", 2000)).toMatch(/reason/);
    expect(validatePriceDraft(priced, "supplier cost", 2000)).toBeNull();
  });
});

const amendment = (overrides: Partial<Amendment> = {}): Amendment => ({
  id: "a1",
  version: 1,
  kind: "price_change",
  status: "proposed",
  reason: "cost",
  proposed_at: "2026-10-09T10:00:00Z",
  proposed_by_label: "Alpha",
  original_total: 2000,
  proposed_total: 2100,
  delta: 100,
  response_choice: null,
  response_note: null,
  responded_at: null,
  responded_by_label: null,
  stock_mode: null,
  lines: [
    {
      order_item_id: "a",
      product_name: "BO A",
      ordered_qty: 10,
      prior_supplied_qty: 10,
      supplied_qty: 10,
      short_qty: 0,
      unit_price_ghs: 100,
      proposed_unit_price_ghs: 120,
      note: null,
      stock_treatment: null,
    },
  ],
  messages: [],
  ...overrides,
});

describe("wording", () => {
  it("tells the pharmacy what it is being asked to approve", () => {
    expect(priceSummary(amendment())).toMatch(/new prices on 1 product/);
    expect(priceSummary(amendment())).toMatch(/Nothing changes unless you approve it/);
  });

  it("says plainly what approving means for the money", () => {
    expect(priceAcceptanceConsequence(true, 100)).toMatch(
      /debit note for .*100.00.* within your credit limit/,
    );
    expect(priceAcceptanceConsequence(true, -10)).toMatch(/credit note for .*10.00/);
    expect(priceAcceptanceConsequence(false, 50)).toMatch(/pay .*50.00.* more on delivery/);
    expect(priceAcceptanceConsequence(false, -50)).toMatch(/pay .*50.00.* less on delivery/);
    expect(priceAcceptanceConsequence(true, 0)).toMatch(/no money moves/);
  });

  it("describes where a proposal ended", () => {
    expect(priceResponseSummary(amendment({ status: "accepted" }))).toMatch(/Approved/);
    expect(priceResponseSummary(amendment({ status: "rejected" }))).toMatch(/Rejected/);
    expect(priceResponseSummary(amendment({ status: "withdrawn" }))).toMatch(/Withdrawn/);
    expect(
      priceResponseSummary(amendment({ status: "withdrawn", response_choice: "order_cancelled" })),
    ).toMatch(/cancelled/);
    expect(priceResponseSummary(amendment({ status: "proposed" }))).toMatch(/Waiting/);
  });
});
