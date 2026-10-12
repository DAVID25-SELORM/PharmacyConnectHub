import { describe, expect, it } from "vitest";
import {
  PROMOTION_STATUS_LABELS,
  benefitsFromForm,
  dateFromInput,
  describeBenefits,
  describeOverrides,
  newKey,
  overridesFromForm,
  parseMoney,
  reasonError,
} from "./billing-controls";

describe("a reason", () => {
  it("must say something: five characters once trimmed", () => {
    expect(reasonError("")).not.toBeNull();
    expect(reasonError("   ok  ")).not.toBeNull();
    expect(reasonError("Agreed on the call")).toBeNull();
  });
});

describe("an amount typed by a person", () => {
  it("is more than zero with at most two decimals", () => {
    expect(parseMoney("20")).toBe(20);
    expect(parseMoney(" 10.5 ")).toBe(10.5);
    expect(parseMoney("0")).toBeNull();
    expect(parseMoney("0.00")).toBeNull();
    expect(parseMoney("-5")).toBeNull();
    expect(parseMoney("5.005")).toBeNull();
    expect(parseMoney("1,000")).toBeNull();
    expect(parseMoney("abc")).toBeNull();
    expect(parseMoney("")).toBeNull();
  });
});

describe("the custom-pricing form", () => {
  it("sends only the boxes that were filled in", () => {
    expect(
      overridesFromForm({ transaction_fee_percentage: "2", subscription_amount: "80" }),
    ).toEqual({
      overrides: { transaction_fee_percentage: 2, subscription_amount: 80 },
      error: null,
    });
    expect(overridesFromForm({}).overrides).toEqual({});
  });
  it("lets a limit be removed by typing none, but not a price or a percentage", () => {
    expect(overridesFromForm({ transaction_fee_cycle_cap: "none" }).overrides).toEqual({
      transaction_fee_cycle_cap: null,
    });
    expect(overridesFromForm({ transaction_fee_percentage: "none" }).error).toMatch(
      /enter a number/,
    );
    expect(overridesFromForm({ subscription_amount: "None" }).error).toMatch(/enter a number/);
  });
  it("explains a value that cannot be used", () => {
    expect(overridesFromForm({ transaction_fee_percentage: "150" }).error).toMatch(
      /cannot be more than 100/,
    );
    expect(overridesFromForm({ monthly_free_orders: "2.5" }).error).toMatch(/whole number/);
    expect(overridesFromForm({ subscription_amount: "-3" }).error).toMatch(/enter a number/);
    expect(overridesFromForm({ transaction_fee_max: "x" }).error).toMatch(/or "none"/);
  });
  it("describes overrides in plain words, including a temporary fee waiver", () => {
    expect(
      describeOverrides({
        transaction_fee_percentage: 0.5,
        transaction_fee_cycle_cap: null,
        subscription_amount: 80,
      }),
    ).toEqual([
      "Subscription per period: GH₵ 80.00",
      "Platform fee: 0.5%",
      "Fee cap per period: no limit",
    ]);
    expect(describeOverrides({ exempt_from_transaction_fees: true })).toEqual(["No platform fee"]);
    expect(describeOverrides(null)).toEqual([]);
  });
});

describe("promotions", () => {
  it("describes what a promotion gives", () => {
    expect(
      describeBenefits({
        free_trial_days: 10,
        free_orders: 1,
        subscription_discount_percent: 50,
        discount_days: 60,
        fee_percentage: 0.25,
        fee_days: 30,
        fee_waiver_days: 1,
      }),
    ).toEqual([
      "10 days more free trial",
      "1 free order",
      "50% off the subscription for 60 days",
      "0.25% platform fee for 30 days",
      "no platform fee for 1 day",
    ]);
  });
  it("builds the benefits from the form and requires pairs to be complete", () => {
    expect(benefitsFromForm({ free_orders: "5" })).toEqual({
      benefits: { free_orders: 5 },
      error: null,
    });
    expect(benefitsFromForm({}).error).toMatch(/at least one benefit/);
    expect(benefitsFromForm({ subscription_discount_percent: "20" }).error).toMatch(
      /both the percentage and the days/,
    );
    expect(benefitsFromForm({ fee_days: "30" }).error).toMatch(/both the percentage and the days/);
    expect(benefitsFromForm({ free_orders: "five" }).error).toMatch(/numbers/);
    expect(benefitsFromForm({ fee_percentage: "0", fee_days: "30" }).benefits).toEqual({
      fee_percentage: 0,
      fee_days: 30,
    });
  });
  it("names every status", () => {
    expect(Object.values(PROMOTION_STATUS_LABELS).every((l) => l.length > 2)).toBe(true);
  });
});

describe("small helpers", () => {
  it("turns a date box into midday UTC, or nothing", () => {
    expect(dateFromInput("2026-10-12")?.toISOString()).toBe("2026-10-12T12:00:00.000Z");
    expect(dateFromInput("")).toBeNull();
    expect(dateFromInput("12/10/2026")).toBeNull();
    expect(dateFromInput("2026-13-45")).toBeNull();
  });
  it("makes a new request key every time", () => {
    expect(newKey()).not.toBe(newKey());
    expect(newKey("x")).toMatch(/^x-/);
  });
});
