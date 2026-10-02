import { describe, expect, it } from "vitest";
import {
  buildAwardPayload,
  cheapestLineIds,
  finalUnitPrice,
  masterProductLabel,
  selectEntireQuote,
  summariseAward,
  toIlikeTerm,
  validateAwardSelection,
  validateQuoteDraft,
  validateQuoteTerms,
  validateRfqDraft,
  type MasterProductSuggestion,
  type QuoteLineDraft,
  type RfqItem,
  type RfqQuote,
  type RfqQuoteItem,
} from "./rfq";

const rfqItem = (id: string, name: string, quantity: number): RfqItem => ({
  id,
  rfq_id: "r",
  product_name: name,
  quantity,
  notes: null,
});
const quote = (id: string, wholesaler: string, delivery = 0): RfqQuote => ({
  id,
  rfq_id: "r",
  wholesaler_id: wholesaler,
  status: "submitted",
  total_ghs: 0,
  delivery_notes: null,
  valid_until: null,
  submitted_at: "2026-01-01T00:00:00Z",
  delivery_charge_ghs: delivery,
  lead_time_days: null,
  payment_terms: null,
});
const qLine = (
  id: string,
  quoteId: string,
  itemId: string,
  quantity: number,
  final: number,
): RfqQuoteItem => ({
  id,
  rfq_quote_id: quoteId,
  rfq_item_id: itemId,
  product_id: "p",
  quantity,
  unit_price_ghs: final,
  discount_percent: 0,
  final_unit_price_ghs: final,
  line_total_ghs: quantity * final,
  notes: null,
});
const draft = (overrides: Partial<QuoteLineDraft> = {}): QuoteLineDraft => ({
  rfqItemId: "i1",
  productId: "p1",
  unitPriceGhs: "5",
  quantity: "",
  discountPercent: "",
  notes: "",
  include: true,
  ...overrides,
});

const product = (overrides: Partial<MasterProductSuggestion> = {}): MasterProductSuggestion => ({
  id: "00000000-0000-0000-0000-000000000001",
  name: "Paracetamol",
  generic_name: null,
  brand_name: null,
  strength: null,
  dosage_form: null,
  pack_size: null,
  ...overrides,
});

describe("masterProductLabel", () => {
  it("returns the bare name when there is nothing to add", () => {
    expect(masterProductLabel(product())).toBe("Paracetamol");
  });
  it("appends strength, form and pack size in that order", () => {
    expect(
      masterProductLabel(product({ strength: "500mg", dosage_form: "Tablet", pack_size: "20s" })),
    ).toBe("Paracetamol 500mg Tablet 20s");
  });
  it("does not repeat a part the name already contains (case-insensitive)", () => {
    expect(
      masterProductLabel(
        product({ name: "Paracetamol 500MG", strength: "500mg", dosage_form: "Tablet" }),
      ),
    ).toBe("Paracetamol 500MG Tablet");
  });
  it("ignores blank parts", () => {
    expect(masterProductLabel(product({ strength: "  ", pack_size: "" }))).toBe("Paracetamol");
  });
});

describe("toIlikeTerm", () => {
  it("strips characters that would break a PostgREST or() filter", () => {
    expect(toIlikeTerm("para,cet(amol)%_")).toBe("para cet amol");
  });
  it("strips backslashes too", () => {
    expect(toIlikeTerm("a\\b")).toBe("a b");
  });
  it("collapses whitespace and trims", () => {
    expect(toIlikeTerm("  amox   500 ")).toBe("amox 500");
  });
});

describe("validateRfqDraft", () => {
  const base = {
    title: "Restock",
    wholesalerIds: ["w1"],
    items: [{ productName: "Paracetamol", quantity: "10", notes: "" }],
    responseDeadline: "",
  };
  it("accepts a complete draft", () => {
    expect(validateRfqDraft(base).error).toBeNull();
  });
  it("requires at least one recipient, whether picked or broadcast", () => {
    expect(validateRfqDraft({ ...base, wholesalerIds: [] }).error).toMatch(
      /at least one supplier/i,
    );
  });
});

describe("finalUnitPrice", () => {
  it("applies the discount and rounds to pesewas", () => {
    expect(finalUnitPrice(5, 10)).toBe(4.5);
    expect(finalUnitPrice(10, 33.33)).toBe(6.67);
    expect(finalUnitPrice(5, 0)).toBe(5);
  });
});

describe("validateQuoteDraft: quantity and discount", () => {
  const requested = { i1: 100 };
  it("accepts a blank quantity (meaning the full requested amount)", () => {
    expect(validateQuoteDraft([draft()], requested).error).toBeNull();
  });
  it("accepts a partial quantity within what was requested", () => {
    expect(validateQuoteDraft([draft({ quantity: "60" })], requested).error).toBeNull();
  });
  it("rejects a quantity above what was requested, zero, or fractional", () => {
    expect(validateQuoteDraft([draft({ quantity: "101" })], requested).error).toMatch(/1 to 100/);
    expect(validateQuoteDraft([draft({ quantity: "0" })], requested).error).toBeTruthy();
    expect(validateQuoteDraft([draft({ quantity: "2.5" })], requested).error).toBeTruthy();
  });
  it("rejects a discount of 100% or more, or negative", () => {
    expect(validateQuoteDraft([draft({ discountPercent: "100" })], requested).error).toMatch(
      /less than 100%/,
    );
    expect(validateQuoteDraft([draft({ discountPercent: "-1" })], requested).error).toBeTruthy();
    expect(validateQuoteDraft([draft({ discountPercent: "10" })], requested).error).toBeNull();
  });
  it("rejects a discount that rounds the price down to nothing", () => {
    expect(
      validateQuoteDraft([draft({ unitPriceGhs: "0.01", discountPercent: "99.99" })], requested)
        .error,
    ).toMatch(/after discount/);
  });
});

describe("validateQuoteTerms", () => {
  it("accepts blanks and sensible values", () => {
    expect(
      validateQuoteTerms({ deliveryCharge: "", leadTimeDays: "", paymentTerms: "" }).error,
    ).toBeNull();
    expect(
      validateQuoteTerms({ deliveryCharge: "15", leadTimeDays: "3", paymentTerms: "Net 14" }).error,
    ).toBeNull();
  });
  it("rejects a negative delivery charge and a non-whole or negative lead time", () => {
    expect(
      validateQuoteTerms({ deliveryCharge: "-1", leadTimeDays: "", paymentTerms: "" }).error,
    ).toBeTruthy();
    expect(
      validateQuoteTerms({ deliveryCharge: "", leadTimeDays: "1.5", paymentTerms: "" }).error,
    ).toBeTruthy();
    expect(
      validateQuoteTerms({ deliveryCharge: "", leadTimeDays: "-2", paymentTerms: "" }).error,
    ).toBeTruthy();
  });
});

describe("award selection", () => {
  const items = [rfqItem("i1", "Paracetamol", 100), rfqItem("i2", "Amoxicillin", 20)];
  const quotes = [quote("qa", "wa", 15), quote("qb", "wb")];
  const lines = [
    qLine("a1", "qa", "i1", 60, 4.5),
    qLine("a2", "qa", "i2", 20, 10),
    qLine("b1", "qb", "i1", 100, 4.8),
  ];

  it("keeps only lines with a positive quantity", () => {
    expect(buildAwardPayload({ a1: "60", a2: "0", b1: "" })).toEqual([
      { quoteItemId: "a1", quantity: 60 },
    ]);
  });
  it("requires at least one line", () => {
    expect(validateAwardSelection({}, lines, items).error).toMatch(/at least one line/);
  });
  it("allows splitting an item between suppliers up to the requested quantity", () => {
    expect(validateAwardSelection({ a1: "60", b1: "40" }, lines, items).error).toBeNull();
  });
  it("rejects awarding more than a supplier offered", () => {
    expect(validateAwardSelection({ a1: "61" }, lines, items).error).toMatch(/only offered 60/);
  });
  it("rejects splits that total more than was requested", () => {
    expect(validateAwardSelection({ a1: "60", b1: "41" }, lines, items).error).toMatch(
      /awarded 101 of "Paracetamol"/,
    );
  });
  it("totals each supplier's goods at the final price and counts delivery once per supplier", () => {
    const totals = summariseAward({ a1: "60", a2: "20", b1: "40" }, quotes, lines);
    const a = totals.find((t) => t.quoteId === "qa")!;
    const b = totals.find((t) => t.quoteId === "qb")!;
    expect(a).toMatchObject({ lines: 2, goods: 470, delivery: 15, total: 485 });
    expect(b).toMatchObject({ lines: 1, goods: 192, delivery: 0, total: 192 });
  });
  it("charges no delivery to a supplier that wins nothing", () => {
    expect(summariseAward({ b1: "10" }, quotes, lines).map((t) => t.quoteId)).toEqual(["qb"]);
  });
  it("'select whole quote' picks exactly that supplier's lines at their offered quantities", () => {
    expect(selectEntireQuote("qa", lines)).toEqual({ a1: "60", a2: "20" });
  });
  it("marks the lowest final price per item, including ties, without choosing for the pharmacy", () => {
    const withTie = [...lines, qLine("c1", "qb", "i2", 20, 10)];
    expect([...cheapestLineIds(withTie)].sort()).toEqual(["a1", "a2", "c1"]);
  });
});
