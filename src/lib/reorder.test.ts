import { describe, expect, it } from "vitest";
import {
  comparisonHighlights,
  mergeIntoCart,
  netPrice,
  resolveLine,
  sortOffers,
  summarizeResolved,
  type DiscountMap,
  type Offer,
} from "./reorder";

const offer = (
  id: string,
  wholesaler: string,
  price: number,
  stock: number,
  extra: Partial<Offer> = {},
): Offer => ({
  id,
  wholesaler_id: wholesaler,
  price_ghs: price,
  stock,
  wholesaler: { name: wholesaler.toUpperCase() },
  ...extra,
});

const none: DiscountMap = {};

describe("netPrice", () => {
  it("applies an unconditional percentage discount", () => {
    expect(
      netPrice(
        { price_ghs: 100 },
        { discount_type: "percentage", discount_percent: 5, minimum_order_value: 0 },
      ),
    ).toBe(95);
  });
  it("applies a fixed discount and never goes negative", () => {
    expect(
      netPrice(
        { price_ghs: 10 },
        { discount_type: "fixed", discount_amount: 3, minimum_order_value: 0 },
      ),
    ).toBe(7);
    expect(
      netPrice(
        { price_ghs: 2 },
        { discount_type: "fixed", discount_amount: 3, minimum_order_value: 0 },
      ),
    ).toBe(0);
  });
  it("ignores discounts that need a minimum order value (checkout decides)", () => {
    expect(
      netPrice(
        { price_ghs: 100 },
        { discount_type: "percentage", discount_percent: 10, minimum_order_value: 500 },
      ),
    ).toBe(100);
  });
  it("returns the list price without a discount", () => {
    expect(netPrice({ price_ghs: "14.2" }, undefined)).toBe(14.2);
  });
});

describe("comparison", () => {
  const offers = [
    offer("a", "a", 14.2, 10, { lead_time_days: 1 }),
    offer("b", "b", 13.8, 5, { lead_time_days: 2 }),
    offer("c", "c", 12, 0),
  ];

  it("marks the cheapest net price among in-stock offers only", () => {
    expect(comparisonHighlights(offers, none).cheapestId).toBe("b");
  });
  it("accounts for discounts when choosing the best net price", () => {
    const discounts: DiscountMap = {
      a: { discount_type: "percentage", discount_percent: 10, minimum_order_value: 0 },
    };
    expect(comparisonHighlights(offers, discounts).cheapestId).toBe("a"); // 12.78 < 13.80
  });
  it("marks the fastest only when lead times actually differ", () => {
    expect(comparisonHighlights(offers, none).fastestId).toBe("a");
    expect(
      comparisonHighlights(
        [
          offer("a", "a", 1, 1, { lead_time_days: 2 }),
          offer("b", "b", 2, 1, { lead_time_days: 2 }),
        ],
        none,
      ).fastestId,
    ).toBeNull();
  });
  it("sorts by net price with out-of-stock offers last", () => {
    expect(sortOffers(offers, none, "net-price").map((o) => o.id)).toEqual(["b", "a", "c"]);
    expect(sortOffers(offers, none, "fastest").map((o) => o.id)).toEqual(["a", "b", "c"]);
    expect(sortOffers(offers, none, "supplier").map((o) => o.id)).toEqual(["a", "b", "c"]);
  });
});

describe("resolveLine", () => {
  const catalogue = new Map<string, Offer[]>([
    ["m1", [offer("a", "a", 14, 100), offer("b", "b", 12, 3, { minimum_order_quantity: 2 })]],
    ["m2", [offer("c", "c", 5, 0)]],
    ["m3", [offer("d", "d", 5, 1, { minimum_order_quantity: 5 })]],
  ]);

  it("uses the preferred supplier when it can supply", () => {
    const r = resolveLine(
      { masterProductId: "m1", name: "X", quantity: 10, preferredWholesalerId: "a" },
      catalogue,
      none,
    );
    expect(r.status).toBe("ready");
    expect(r.offer?.id).toBe("a");
    expect(r.quantity).toBe(10);
  });
  it("falls back to the best net price and says so when the usual supplier cannot supply", () => {
    const r = resolveLine({ masterProductId: "m2", name: "X", quantity: 1 }, catalogue, none);
    expect(r.status).toBe("unavailable");
    const r2 = resolveLine(
      { masterProductId: "m1", name: "X", quantity: 2, preferredWholesalerId: "zzz" },
      catalogue,
      none,
    );
    expect(r2.status).toBe("adjusted");
    expect(r2.switchedSupplier).toBe(true);
    expect(r2.offer?.id).toBe("b");
    expect(r2.note).toMatch(/Usual supplier/);
  });
  it("picks the best net price when there is no preference", () => {
    const r = resolveLine({ masterProductId: "m1", name: "X", quantity: 2 }, catalogue, none);
    expect(r.offer?.id).toBe("b");
    expect(r.unitPrice).toBe(12);
  });
  it("caps quantity at stock and reports it", () => {
    const r = resolveLine(
      { masterProductId: "m1", name: "X", quantity: 50, preferredWholesalerId: "b" },
      catalogue,
      none,
    );
    expect(r.quantity).toBe(3);
    expect(r.status).toBe("adjusted");
    expect(r.note).toMatch(/Only 3 in stock/);
  });
  it("raises quantity to the minimum order quantity", () => {
    const r = resolveLine(
      { masterProductId: "m1", name: "X", quantity: 1, preferredWholesalerId: "b" },
      catalogue,
      none,
    );
    expect(r.quantity).toBe(2);
    expect(r.note).toMatch(/minimum order of 2/);
  });
  it("marks unavailable: no offers, no stock, stock below the minimum", () => {
    expect(
      resolveLine({ masterProductId: "gone", name: "X", quantity: 1 }, catalogue, none).note,
    ).toMatch(/No longer listed/);
    expect(
      resolveLine({ masterProductId: null, name: "X", quantity: 1 }, catalogue, none).status,
    ).toBe("unavailable");
    expect(
      resolveLine({ masterProductId: "m2", name: "X", quantity: 1 }, catalogue, none).note,
    ).toMatch(/Out of stock/);
    expect(
      resolveLine({ masterProductId: "m3", name: "X", quantity: 1 }, catalogue, none).note,
    ).toMatch(/below the suppliers' minimum/);
  });
  it("summarises availability", () => {
    const lines = [
      resolveLine(
        { masterProductId: "m1", name: "A", quantity: 10, preferredWholesalerId: "a" },
        catalogue,
        none,
      ),
      resolveLine({ masterProductId: "m2", name: "B", quantity: 1 }, catalogue, none),
    ];
    expect(summarizeResolved(lines)).toEqual({
      total: 2,
      available: 1,
      unavailable: 1,
      adjusted: 0,
      estimatedTotal: 140,
    });
  });
});

describe("mergeIntoCart", () => {
  it("adds new lines, merges existing ones and never exceeds stock", () => {
    const { cart, added } = mergeIntoCart(
      [{ productId: "a", quantity: 4 }],
      [
        { productId: "a", quantity: 5, stock: 6 },
        { productId: "b", quantity: 2, stock: 10 },
        { productId: "c", quantity: 1, stock: 0 },
      ],
    );
    expect(cart).toEqual([
      { productId: "a", quantity: 6 },
      { productId: "b", quantity: 2 },
    ]);
    expect(added).toBe(2);
  });
});
