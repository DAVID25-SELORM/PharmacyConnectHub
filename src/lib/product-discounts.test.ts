import { describe, expect, it } from "vitest";
import { estimateGroup } from "./order-terms";
import { bestRule, makePriceOf, volumeTierTexts, type ProductRule } from "./product-discounts";

const rules: ProductRule[] = [
  { product_id: "amox", wholesaler_id: "w", discount_percent: 12, min_quantity: 1 },
  { product_id: "amox", wholesaler_id: "w", discount_percent: 15, min_quantity: 10 },
];
const general = { discount_type: "percentage", discount_percent: 5, minimum_order_value: 0 };

describe("product rules", () => {
  it("picks the best rule the quantity reaches", () => {
    expect(bestRule(rules, "amox", 2)?.discount_percent).toBe(12);
    expect(bestRule(rules, "amox", 9)?.discount_percent).toBe(12);
    expect(bestRule(rules, "amox", 10)?.discount_percent).toBe(15);
    expect(bestRule(rules, "para", 10)).toBeUndefined();
    expect(bestRule(undefined, "amox", 1)).toBeUndefined();
  });

  it("prefers a product rule over the general discount when pricing an offer", () => {
    const priceOf = makePriceOf({ w: general }, rules);
    expect(priceOf({ id: "amox", price_ghs: 100, wholesaler_id: "w" }, 1)).toBe(88);
    expect(priceOf({ id: "amox", price_ghs: 100, wholesaler_id: "w" }, 10)).toBe(85);
    expect(priceOf({ id: "para", price_ghs: 50, wholesaler_id: "w" }, 1)).toBe(47.5);
  });

  it("describes volume tiers", () => {
    expect(volumeTierTexts(rules, "amox")).toEqual(["15% off from 10 units"]);
    expect(volumeTierTexts(rules, "para")).toEqual([]);
  });
});

describe("cart estimate with product rules (same numbers as the database tests)", () => {
  it("prices a product line by its rule and the rest by the general discount", () => {
    const estimate = estimateGroup(
      [
        { product_id: "amox", price_ghs: 100, quantity: 2 },
        { product_id: "para", price_ghs: 50, quantity: 2 },
      ],
      general,
      undefined,
      rules,
    );
    expect(estimate).toMatchObject({ gross: 300, discount: 29, goods: 271, productRuleLines: 1 });
  });

  it("a volume rule applies at its quantity", () => {
    expect(
      estimateGroup(
        [{ product_id: "amox", price_ghs: 100, quantity: 10 }],
        general,
        undefined,
        rules,
      ),
    ).toMatchObject({ discount: 150, goods: 850 });
    expect(
      estimateGroup(
        [{ product_id: "amox", price_ghs: 100, quantity: 9 }],
        general,
        undefined,
        rules,
      ),
    ).toMatchObject({ discount: 108, goods: 792 });
  });

  it("shares a fixed general discount over the lines without a product rule only", () => {
    const fixed = { discount_type: "fixed", discount_amount: 30, minimum_order_value: 0 };
    const estimate = estimateGroup(
      [
        { product_id: "amox", price_ghs: 100, quantity: 2 },
        { product_id: "para", price_ghs: 50, quantity: 2 },
      ],
      fixed,
      undefined,
      rules,
    );
    expect(estimate).toMatchObject({ discount: 54, goods: 246 });
    expect(
      estimateGroup([{ product_id: "para", price_ghs: 50, quantity: 1 }], fixed, undefined, rules),
    ).toMatchObject({ discount: 30, goods: 20 });
  });

  it("gives no general discount when every line has a product rule", () => {
    const estimate = estimateGroup(
      [{ product_id: "amox", price_ghs: 100, quantity: 2 }],
      { discount_type: "fixed", discount_amount: 30, minimum_order_value: 0 },
      undefined,
      rules,
    );
    expect(estimate).toMatchObject({ discount: 24, productRuleLines: 1 });
  });
});
