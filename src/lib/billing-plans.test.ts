import { describe, expect, it } from "vitest";
import {
  describeRun,
  describeTermsChange,
  paramsFromTermsForm,
  planCodeError,
  planNameError,
  termsFormFromVersion,
} from "./billing-plans";

const wholesaler = {
  subscription_amount: "199.00",
  billing_interval_months: "1",
  free_trial_days: "30",
  onboarding_free_orders: "20",
  monthly_free_orders: "5",
  transaction_fee_percentage: "1.5",
  transaction_fee_min: "2",
  transaction_fee_max: "250",
  transaction_fee_cycle_cap: "",
  min_billable_order_amount: "",
  max_users: "",
  max_branches: "",
};

describe("plan code and name", () => {
  it("accepts what the database accepts and nothing else", () => {
    expect(planCodeError("wholesale-growth")).toBeNull();
    expect(planCodeError("p1")).toBeNull();
    for (const bad of ["", "a", "Growth", "1plan", "has space", "x".repeat(41)])
      expect(planCodeError(bad)).not.toBeNull();
  });
  it("needs a name of 2 to 80 characters", () => {
    expect(planNameError("Growth")).toBeNull();
    expect(planNameError(" a ")).not.toBeNull();
    expect(planNameError("x".repeat(81))).not.toBeNull();
  });
});

describe("terms form", () => {
  it("round-trips the latest version through the boxes", () => {
    const form = termsFormFromVersion({
      subscription_amount: 199,
      billing_interval_months: 1,
      free_trial_days: 30,
      onboarding_free_orders: 20,
      monthly_free_orders: 5,
      transaction_fee_percentage: "1.5000",
      transaction_fee_min: 2,
      transaction_fee_max: 250,
      transaction_fee_cycle_cap: null,
      min_billable_order_amount: null,
      max_users: null,
      max_branches: 3,
    });
    expect(form.transaction_fee_percentage).toBe("1.5");
    expect(form.transaction_fee_cycle_cap).toBe("");
    expect(form.max_branches).toBe("3");
    const { params, error } = paramsFromTermsForm(form, "wholesaler");
    expect(error).toBeNull();
    expect(params).toMatchObject({
      subscription_amount: 199,
      transaction_fee_percentage: 1.5,
      transaction_fee_min: 2,
      transaction_fee_max: 250,
      max_branches: 3,
    });
    expect(params).not.toHaveProperty("transaction_fee_cycle_cap");
    expect(params).not.toHaveProperty("max_users");
  });

  it("starts a new plan from zero with a one month period", () => {
    const form = termsFormFromVersion(null);
    expect(form.billing_interval_months).toBe("1");
    expect(form.subscription_amount).toBe("0");
    expect(form.transaction_fee_min).toBe("");
  });

  it("carries the parts the form does not edit, so publishing never drops them", () => {
    const { params } = paramsFromTermsForm(wholesaler, "wholesaler", {
      currency: "GHS",
      entitlements: { reports: true },
      metadata: { note: "x" },
    });
    expect(params).toMatchObject({
      currency: "GHS",
      entitlements: { reports: true },
      metadata: { note: "x" },
    });
    const bare = paramsFromTermsForm(wholesaler, "wholesaler", {
      entitlements: {},
      metadata: null,
    });
    expect(bare.params).not.toHaveProperty("entitlements");
    expect(bare.params).not.toHaveProperty("metadata");
  });

  it("sends a pharmacy plan with no per-order fee whatever the fee boxes hold", () => {
    const { params, error } = paramsFromTermsForm(wholesaler, "pharmacy");
    expect(error).toBeNull();
    expect(params).toMatchObject({
      subscription_amount: 199,
      free_trial_days: 30,
      transaction_fee_percentage: 0,
      onboarding_free_orders: 0,
      monthly_free_orders: 0,
    });
    expect(params).not.toHaveProperty("transaction_fee_max");
  });

  it.each([
    ["subscription_amount", "-5", "Subscription"],
    ["subscription_amount", "12.345", "two decimals"],
    ["subscription_amount", "abc", "Subscription"],
    ["subscription_amount", "", "enter a number"],
    ["billing_interval_months", "13", "between 1 and 12"],
    ["billing_interval_months", "0", "between 1 and 12"],
    ["free_trial_days", "731", "between 0 and 730"],
    ["transaction_fee_percentage", "100.5", "between 0 and 100"],
    ["transaction_fee_percentage", "1.23456", "four decimals"],
    ["onboarding_free_orders", "1.5", "whole number"],
    ["max_users", "0", "at least 1"],
  ])("refuses %s = %s", (key, value, message) => {
    const { params, error } = paramsFromTermsForm({ ...wholesaler, [key]: value }, "wholesaler");
    expect(params).toEqual({});
    expect(error).toContain(message);
  });

  it("refuses a largest fee below the smallest", () => {
    const { error } = paramsFromTermsForm(
      { ...wholesaler, transaction_fee_min: "10", transaction_fee_max: "5" },
      "wholesaler",
    );
    expect(error).toContain("largest fee");
  });

  it("allows a zero fee, a zero subscription and a limit of exactly one", () => {
    const { params, error } = paramsFromTermsForm(
      {
        ...wholesaler,
        subscription_amount: "0",
        transaction_fee_percentage: "0",
        max_users: "1",
      },
      "wholesaler",
    );
    expect(error).toBeNull();
    expect(params).toMatchObject({
      subscription_amount: 0,
      transaction_fee_percentage: 0,
      max_users: 1,
    });
  });

  it("lists only what changed", () => {
    const next = { ...wholesaler, subscription_amount: "249", transaction_fee_cycle_cap: "1000" };
    expect(describeTermsChange(wholesaler, next, "wholesaler")).toEqual([
      "Subscription per billing period (GHS): 199.00 → 249",
      "Most in fees per period (GHS): none → 1000",
    ]);
    expect(describeTermsChange(wholesaler, wholesaler, "wholesaler")).toEqual([]);
  });

  it("does not report fee changes for a pharmacy plan", () => {
    const next = { ...wholesaler, transaction_fee_percentage: "3" };
    expect(describeTermsChange(wholesaler, next, "pharmacy")).toEqual([]);
  });
});

describe("describeRun", () => {
  it("summarises the numbers in a run result", () => {
    expect(describeRun({ assessed: 3, invoices_issued: 1, note: "x" })).toBe(
      "assessed: 3 · invoices issued: 1",
    );
    expect(describeRun({})).toBe("The run finished with nothing to do.");
    expect(describeRun(null)).toBe("Nothing has run yet.");
  });
});
