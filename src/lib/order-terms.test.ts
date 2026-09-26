import { describe, expect, it } from "vitest";
import { describeTerms, estimateGroup, validateTermsForm, type OrderTerms } from "./order-terms";

const terms: OrderTerms = {
  wholesaler_id: "w",
  min_order_value_ghs: 300,
  delivery_fee_ghs: 20,
  free_delivery_threshold_ghs: 1000,
};
const pct5 = { discount_type: "percentage", discount_percent: 5, minimum_order_value: 0 };

describe("estimateGroup (mirrors the checkout rules)", () => {
  it("applies the discount first, then the minimum and the fee on the goods total", () => {
    // 3 x 100 = 300 gross, 285 after 5% -> below the 300 minimum
    const low = estimateGroup([{ price_ghs: 100, quantity: 3 }], pct5, terms);
    expect(low).toMatchObject({
      gross: 300,
      discount: 15,
      goods: 285,
      deliveryFee: 20,
      shortfall: 15,
      minimumMet: false,
    });
    // 4 x 100 -> 380 net, fee 20, total 400
    const ok = estimateGroup([{ price_ghs: 100, quantity: 4 }], pct5, terms);
    expect(ok).toMatchObject({
      goods: 380,
      deliveryFee: 20,
      total: 400,
      shortfall: 0,
      minimumMet: true,
    });
  });

  it("waives the fee only when the discounted goods reach the free-delivery amount", () => {
    expect(estimateGroup([{ price_ghs: 100, quantity: 10 }], pct5, terms)).toMatchObject({
      goods: 950,
      deliveryFee: 20,
      total: 970,
      freeDeliveryRemaining: 50,
    });
    expect(estimateGroup([{ price_ghs: 100, quantity: 11 }], pct5, terms)).toMatchObject({
      goods: 1045,
      deliveryFee: 0,
      total: 1045,
      freeDeliveryRemaining: null,
    });
  });

  it("behaves as before when a wholesaler has no terms or no discount", () => {
    expect(estimateGroup([{ price_ghs: 10, quantity: 2 }], undefined, undefined)).toMatchObject({
      goods: 20,
      deliveryFee: 0,
      total: 20,
      shortfall: 0,
      minimumMet: true,
      freeDeliveryRemaining: null,
    });
  });

  it("only applies a discount whose own minimum is reached, and caps fixed discounts", () => {
    const gated = { discount_type: "percentage", discount_percent: 10, minimum_order_value: 500 };
    expect(estimateGroup([{ price_ghs: 100, quantity: 4 }], gated, undefined).discount).toBe(0);
    expect(estimateGroup([{ price_ghs: 100, quantity: 5 }], gated, undefined).discount).toBe(50);
    const fixed = { discount_type: "fixed", discount_amount: 500, minimum_order_value: 0 };
    expect(estimateGroup([{ price_ghs: 10, quantity: 2 }], fixed, undefined)).toMatchObject({
      discount: 20,
      goods: 0,
    });
  });
});

describe("terms text and form", () => {
  it("describes terms briefly", () => {
    expect(describeTerms(undefined)).toBeNull();
    expect(describeTerms({ ...terms, min_order_value_ghs: 0, delivery_fee_ghs: 0 })).toBeNull();
    expect(describeTerms(terms)).toBe(
      "Min. order GHS 300.00 · Delivery GHS 20.00, free from GHS 1,000.00",
    );
    expect(describeTerms({ ...terms, free_delivery_threshold_ghs: null })).toBe(
      "Min. order GHS 300.00 · Delivery GHS 20.00",
    );
  });

  it("validates the terms form like the database does", () => {
    expect(validateTermsForm({ min: "300", fee: "20", freeFrom: "1000" })).toMatchObject({
      error: null,
      min: 300,
      fee: 20,
      freeFrom: 1000,
    });
    expect(validateTermsForm({ min: "", fee: "", freeFrom: "" })).toMatchObject({
      error: null,
      min: 0,
      fee: 0,
      freeFrom: null,
    });
    expect(validateTermsForm({ min: "-1", fee: "0", freeFrom: "" }).error).toMatch(/minimum order/);
    expect(validateTermsForm({ min: "0", fee: "-5", freeFrom: "" }).error).toMatch(/delivery fee/);
    expect(validateTermsForm({ min: "0", fee: "0", freeFrom: "500" }).error).toMatch(
      /Set a delivery fee/,
    );
    expect(validateTermsForm({ min: "300", fee: "20", freeFrom: "100" }).error).toMatch(
      /cannot be lower/,
    );
    expect(validateTermsForm({ min: "0", fee: "20", freeFrom: "0" }).error).toMatch(/above zero/);
  });
});
