import { describe, expect, it } from "vitest";
import {
  acceptanceConsequence,
  canProposeSupplyChange,
  deltaPhrase,
  draftFromView,
  draftShort,
  draftSupply,
  draftTotals,
  openAmendment,
  pharmacySummary,
  proposalPayload,
  responseSummary,
  validateDraft,
  type Amendment,
  type DraftLine,
  type OrderAmendmentsView,
} from "./order-amendments";

const view = (overrides: Partial<OrderAmendmentsView> = {}): OrderAmendmentsView => ({
  order_id: "o1",
  order_number: "ORD-1",
  status: "packed",
  original_total: 2100,
  current_total: 2100,
  amended: false,
  is_credit_order: true,
  open_amendment_id: null,
  stock_evidence: true,
  lines: [
    {
      order_item_id: "a",
      product_name: "PF A",
      ordered_qty: 10,
      supplied_qty: 10,
      unit_price_ghs: 100,
    },
    {
      order_item_id: "b",
      product_name: "PF B",
      ordered_qty: 20,
      supplied_qty: 20,
      unit_price_ghs: 50,
    },
    {
      order_item_id: "c",
      product_name: "PF C",
      ordered_qty: 5,
      supplied_qty: 5,
      unit_price_ghs: 20,
    },
  ],
  amendments: [],
  ...overrides,
});

const amendment = (overrides: Partial<Amendment> = {}): Amendment => ({
  id: "x",
  version: 1,
  kind: "partial_fulfilment",
  status: "proposed",
  reason: "Short",
  proposed_at: "2026-10-08T10:00:00Z",
  proposed_by_label: "Alpha Wholesale",
  original_total: 2100,
  proposed_total: 1550,
  delta: -550,
  response_choice: null,
  response_note: null,
  responded_at: null,
  responded_by_label: null,
  stock_mode: null,
  lines: [
    {
      order_item_id: "a",
      product_name: "PF A",
      ordered_qty: 10,
      prior_supplied_qty: 10,
      supplied_qty: 7,
      short_qty: 3,
      unit_price_ghs: 100,
      note: null,
      stock_treatment: null,
    },
    {
      order_item_id: "b",
      product_name: "PF B",
      ordered_qty: 20,
      prior_supplied_qty: 20,
      supplied_qty: 15,
      short_qty: 5,
      unit_price_ghs: 50,
      note: null,
      stock_treatment: null,
    },
  ],
  messages: [],
  ...overrides,
});

const draft = (
  supply: Record<string, string>,
  treat: Record<string, "release" | "write_off" | ""> = {},
): DraftLine[] =>
  draftFromView(view()).map((line) => ({
    ...line,
    supply: supply[line.order_item_id] ?? "",
    treatment: treat[line.order_item_id] ?? "",
  }));

describe("draft arithmetic", () => {
  it("an untouched line keeps its current quantity", () => {
    const [line] = draft({});
    expect(draftSupply(line)).toBe(10);
    expect(draftShort(line)).toBe(0);
  });

  it("totals the shortage and the new order total at the agreed unit prices", () => {
    const lines = draft({ a: "7", b: "15" });
    expect(draftTotals(lines, 2100)).toEqual({
      shortUnits: 8,
      shortLines: 2,
      shortValue: 550,
      newTotal: 1550,
      suppliedUnits: 7 + 15 + 5,
    });
  });

  it("rejects non-numeric input without treating it as zero", () => {
    const [line] = draft({ a: "2.5" });
    expect(draftSupply(line)).toBeNull();
    expect(draftShort(line)).toBe(0);
  });

  it("works from the current commitment on an already amended order", () => {
    const amended = view({
      lines: [
        {
          order_item_id: "a",
          product_name: "PF A",
          ordered_qty: 10,
          supplied_qty: 7,
          unit_price_ghs: 100,
        },
      ],
      current_total: 1550,
    });
    const lines = draftFromView(amended).map((line) => ({ ...line, supply: "6" }));
    expect(draftTotals(lines, 1550)).toMatchObject({
      shortUnits: 1,
      shortValue: 100,
      newTotal: 1450,
    });
  });
});

describe("validation", () => {
  it("accepts a good draft", () => {
    expect(validateDraft(draft({ a: "7" }, { a: "release" }), "Supplier short", true)).toBeNull();
  });

  it("asks what happens to the stock when the order has stock evidence", () => {
    expect(validateDraft(draft({ a: "7" }), "Supplier short", true)).toMatch(/release it to stock/);
    expect(validateDraft(draft({ a: "7" }), "Supplier short", false)).toBeNull();
  });

  it("refuses more than is committed, fractions, no reduction and supplying nothing", () => {
    expect(validateDraft(draft({ a: "11" }, { a: "release" }), "x1x", true)).toMatch(
      /cannot supply more/,
    );
    expect(validateDraft(draft({ a: "1.5" }), "x1x", false)).toMatch(/whole number/);
    expect(validateDraft(draft({}), "x1x", false)).toMatch(/smaller quantity/);
    expect(
      validateDraft(
        draft({ a: "0", b: "0", c: "0" }, { a: "release", b: "release", c: "release" }),
        "x1x",
        true,
      ),
    ).toMatch(/cancellation/);
  });

  it("needs a reason", () => {
    expect(validateDraft(draft({ a: "7" }, { a: "release" }), "  ", true)).toMatch(/reason/);
    expect(validateDraft(draft({ a: "7" }, { a: "release" }), "x".repeat(501), true)).toMatch(
      /500/,
    );
  });
});

describe("payload", () => {
  it("sends only the lines that change, with their stock treatment", () => {
    const payload = proposalPayload(
      draft({ a: "7", b: "15" }, { a: "release", b: "write_off" }),
      true,
    );
    expect(payload).toEqual([
      { order_item_id: "a", supplied_qty: 7, stock_treatment: "release" },
      { order_item_id: "b", supplied_qty: 15, stock_treatment: "write_off" },
    ]);
  });

  it("omits the treatment when the order has no stock evidence", () => {
    expect(proposalPayload(draft({ a: "7" }, { a: "release" }), false)).toEqual([
      { order_item_id: "a", supplied_qty: 7 },
    ]);
  });
});

describe("who can propose", () => {
  it("only while the order is being prepared and nothing is open", () => {
    expect(canProposeSupplyChange(view(), "packed")).toBe(true);
    expect(canProposeSupplyChange(view(), "pending")).toBe(false);
    expect(canProposeSupplyChange(view(), "dispatched")).toBe(false);
    expect(canProposeSupplyChange(view({ open_amendment_id: "x" }), "packed")).toBe(false);
    expect(canProposeSupplyChange(null, "packed")).toBe(false);
  });

  it("a paid non-credit order cannot be amended, a paid credit order can", () => {
    expect(canProposeSupplyChange(view({ is_credit_order: false }), "packed", "paid")).toBe(false);
    expect(canProposeSupplyChange(view({ is_credit_order: true }), "packed", "paid")).toBe(true);
  });

  it("finds the open proposal", () => {
    expect(
      openAmendment(
        view({
          amendments: [
            amendment({ status: "rejected" }),
            amendment({ id: "y", status: "proposed" }),
          ],
        }),
      )?.id,
    ).toBe("y");
    expect(openAmendment(view({ amendments: [amendment({ status: "accepted" })] }))).toBeNull();
  });
});

describe("wording", () => {
  it("states the change in money plainly", () => {
    expect(deltaPhrase(-550)).toMatch(/less$/);
    expect(deltaPhrase(40)).toMatch(/more$/);
    expect(deltaPhrase(0)).toBe("no change");
  });

  it("summarises the proposal for the pharmacy", () => {
    const text = pharmacySummary(amendment());
    expect(text).toMatch(/8 units short on 2 products/);
    expect(text).toMatch(/2100\.00/);
    expect(text).toMatch(/1550\.00/);
  });

  it("explains what accepting does, for credit and cash orders", () => {
    expect(acceptanceConsequence(true, -550)).toMatch(/credit note/);
    expect(acceptanceConsequence(false, -550)).toMatch(/pay .* less on delivery/);
  });

  it("describes each outcome", () => {
    expect(responseSummary(amendment({ status: "rejected" }))).toMatch(/stood as placed/);
    expect(
      responseSummary(amendment({ status: "withdrawn", response_choice: "order_cancelled" })),
    ).toMatch(/cancelled/);
    expect(responseSummary(amendment({ status: "proposed" }))).toMatch(/cannot be dispatched/);
  });
});
