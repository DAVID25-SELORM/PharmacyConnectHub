import { describe, expect, it } from "vitest";
import {
  STATE_LABELS,
  capProgress,
  describeBilledOrder,
  periodLabel,
  planSummary,
  stateMessage,
  type BillingOrderRow,
  type BillingState,
  type MyBilling,
} from "./billing";

const money = (n: number) => `GH₵ ${n.toFixed(2)}`;
const row = (extra: Partial<BillingOrderRow>): BillingOrderRow => ({
  order_number: "ORD-1",
  delivered_at: null,
  assessed_at: "2026-10-01T00:00:00Z",
  kind: "primary",
  adjustment_seq: 0,
  billable_gmv: 1000,
  outcome: "chargeable",
  free_source: null,
  free_seq: null,
  percentage: 0.75,
  fee_after_limits: 7.5,
  cap_adjustment: 0,
  charged_amount: 7.5,
  ...extra,
});

describe("how an order's billing is described", () => {
  it("names the launch and monthly free orders with their number", () => {
    expect(
      describeBilledOrder(
        row({
          outcome: "free_onboarding",
          free_source: "onboarding",
          free_seq: 3,
          charged_amount: 0,
        }),
        money,
      ),
    ).toBe("Free: launch order 3");
    expect(
      describeBilledOrder(
        row({ outcome: "free_monthly", free_source: "monthly", free_seq: 2, charged_amount: 0 }),
        money,
      ),
    ).toBe("Free: monthly allowance 2");
  });
  it("shows a platform fee in cedis", () => {
    expect(describeBilledOrder(row({}), money)).toBe("Platform fee GH₵ 7.50");
  });
  it("says when the monthly cap reduced or removed the fee", () => {
    expect(describeBilledOrder(row({ charged_amount: 20, cap_adjustment: 20 }), money)).toBe(
      "Platform fee GH₵ 20.00 (monthly cap reached)",
    );
    expect(describeBilledOrder(row({ charged_amount: 0, cap_adjustment: 40 }), money)).toBe(
      "Monthly fee cap reached: no fee",
    );
  });
  it("describes a change after delivery as a credit or a further fee", () => {
    expect(
      describeBilledOrder(
        row({ kind: "adjustment", adjustment_seq: 1, charged_amount: -1 }),
        money,
      ),
    ).toBe("Change after delivery: Platform fee credited GH₵ 1.00");
    expect(
      describeBilledOrder(row({ kind: "adjustment", adjustment_seq: 2, charged_amount: 3 }), money),
    ).toBe("Change after delivery: Platform fee GH₵ 3.00");
    expect(
      describeBilledOrder(
        row({
          kind: "adjustment",
          adjustment_seq: 1,
          outcome: "free_adjustment",
          charged_amount: 0,
        }),
        money,
      ),
    ).toBe("Change after delivery: Free (the order was free)");
  });
  it("explains exempt, excluded and below-minimum orders without technical words", () => {
    expect(describeBilledOrder(row({ outcome: "exempt", charged_amount: 0 }), money)).toMatch(
      /exempt/,
    );
    expect(describeBilledOrder(row({ outcome: "excluded", charged_amount: 0 }), money)).toBe(
      "Not billed",
    );
    expect(
      describeBilledOrder(row({ outcome: "below_minimum", charged_amount: 0 }), money),
    ).toMatch(/below the minimum/);
  });
});

describe("the monthly cap progress", () => {
  it("is a percentage of the cap, never above 100", () => {
    expect(capProgress({ transaction_fees_amount: 10, cap: 50 })).toBe(20);
    expect(capProgress({ transaction_fees_amount: 50, cap: 50 })).toBe(100);
    expect(capProgress({ transaction_fees_amount: 80, cap: 50 })).toBe(100);
    expect(capProgress({ transaction_fees_amount: 0, cap: 1500 })).toBe(0);
  });
  it("is nothing when there is no cap", () => {
    expect(capProgress({ transaction_fees_amount: 10, cap: null })).toBeNull();
    expect(capProgress({ transaction_fees_amount: 10 })).toBeNull();
    expect(capProgress({ transaction_fees_amount: null, cap: 0 })).toBeNull();
  });
});

describe("period labels", () => {
  it("shows the last day a period covers, because its end is exclusive", () => {
    expect(periodLabel("2026-10-01T00:00:00Z", "2026-11-01T00:00:00Z")).toBe("1 Oct – 31 Oct 2026");
    expect(periodLabel("2026-01-31T00:00:00Z", "2026-02-28T00:00:00Z")).toBe(
      "31 Jan – 27 Feb 2026",
    );
  });
});

describe("what a plan says about itself", () => {
  const plan: NonNullable<MyBilling["plan"]> = {
    name: "Growth",
    code: "growth",
    subscription_amount: 100,
    billing_interval_months: 1,
    free_trial_days: 30,
    onboarding_free_orders: 5,
    monthly_free_orders: 2,
    transaction_fee_percentage: 0.75,
    transaction_fee_min: null,
    transaction_fee_max: null,
    transaction_fee_cycle_cap: 1500,
  };
  it("lists the price, trial, free orders, fee and cap in plain words (never 'completely free')", () => {
    const lines = planSummary(plan, money);
    expect(lines).toEqual([
      "GH₵ 100.00 / month",
      "30-day free trial",
      "5 free launch orders",
      "2 free orders every month",
      "0.75% platform fee on eligible orders after the free ones",
      "platform fees capped at GH₵ 1500.00 a month",
    ]);
    expect(lines.join(" ")).not.toMatch(/completely free/i);
  });
  it("uses the singular for a single free order", () => {
    const lines = planSummary(
      { ...plan, onboarding_free_orders: 1, monthly_free_orders: 1 },
      money,
    );
    expect(lines).toContain("1 free launch order");
    expect(lines).toContain("1 free order every month");
  });
  it("says nothing about fees for a plan without one (a pharmacy)", () => {
    const lines = planSummary(
      {
        ...plan,
        onboarding_free_orders: null,
        monthly_free_orders: null,
        transaction_fee_percentage: null,
        transaction_fee_cycle_cap: null,
        free_trial_days: 0,
        subscription_amount: 50,
      },
      money,
    );
    expect(lines).toEqual(["GH₵ 50.00 / month"]);
  });
  it("shows per-order limits when they exist", () => {
    const lines = planSummary({ ...plan, transaction_fee_min: 2, transaction_fee_max: 200 }, money);
    expect(lines).toContain("at least GH₵ 2.00 per order");
    expect(lines).toContain("at most GH₵ 200.00 per order");
  });
});

describe("every billing state has plain wording", () => {
  const states = Object.keys(STATE_LABELS) as BillingState[];
  it("has a label and a message for each state, without implementation terms", () => {
    for (const state of states) {
      expect(STATE_LABELS[state].length).toBeGreaterThan(3);
      expect(stateMessage(state).length).toBeGreaterThan(10);
      expect(stateMessage(state)).not.toMatch(/ledger|assessment|rpc|shadow/i);
    }
  });
  it("tells a business that billing has not started and nothing is charged", () => {
    expect(stateMessage("not_started")).toMatch(/Nothing is being charged/);
  });
});
