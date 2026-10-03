import { describe, expect, it } from "vitest";
import {
  CHANGEABLE_SETTLEMENT_METHODS,
  SELECTABLE_SETTLEMENT_METHODS,
  canChangeSettlement,
  effectiveSettlementMethod,
  settlementOptions,
  settlementSummary,
} from "./settlement";

describe("settlementOptions", () => {
  const values = (options: ReturnType<typeof settlementOptions>) => options.map((o) => o.value);

  it("offers every method but credit when the supplier has not approved credit", () => {
    const options = settlementOptions({ state: "none" });
    expect(values(options)).toEqual(["cod", "bank_transfer", "momo", "cheque", "other", "pay_now"]);
  });

  it("offers credit when it is available", () => {
    const options = settlementOptions({ state: "available" });
    expect(options.find((o) => o.value === "credit")).toMatchObject({ disabled: false });
  });

  it("keeps credit visible but disabled, with the reason, when it can't be used", () => {
    const short = settlementOptions({ state: "insufficient", availableLabel: "GHS 2,100.00" });
    expect(short.find((o) => o.value === "credit")).toMatchObject({
      disabled: true,
      reason: "Only GHS 2,100.00 of approved credit is left.",
    });
    for (const state of ["suspended", "blocked"] as const) {
      const option = settlementOptions({ state }).find((o) => o.value === "credit");
      expect(option).toMatchObject({ disabled: true });
      expect(option?.reason).toMatch(new RegExp(state));
    }
  });

  it("never lets Pay Now be chosen: no online payment exists yet", () => {
    for (const state of [{ state: "none" }, { state: "available" }] as const) {
      expect(settlementOptions(state).find((o) => o.value === "pay_now")).toMatchObject({
        disabled: true,
        reason: "Online payment isn't available yet.",
      });
    }
    expect(SELECTABLE_SETTLEMENT_METHODS).not.toContain("pay_now");
  });

  it("does not allow switching to credit or online payment after placing", () => {
    expect(CHANGEABLE_SETTLEMENT_METHODS).not.toContain("credit");
    expect(CHANGEABLE_SETTLEMENT_METHODS).not.toContain("pay_now");
  });
});

describe("effectiveSettlementMethod", () => {
  it("uses the stored method when there is one", () => {
    expect(effectiveSettlementMethod({ settlement_method: "momo", is_credit_order: false })).toBe(
      "momo",
    );
  });
  it("derives it for orders placed before the feature, from what the order itself says", () => {
    expect(effectiveSettlementMethod({ settlement_method: null, is_credit_order: true })).toBe(
      "credit",
    );
    expect(effectiveSettlementMethod({ settlement_method: null, payment_method: "cod" })).toBe(
      "cod",
    );
    expect(effectiveSettlementMethod({ settlement_method: null, payment_method: "paystack" })).toBe(
      "pay_now",
    );
  });
  it("ignores an unknown stored value", () => {
    expect(effectiveSettlementMethod({ settlement_method: "barter", payment_method: "cod" })).toBe(
      "cod",
    );
  });
});

describe("settlementSummary", () => {
  it("says payment pending until it is actually paid, whatever the method", () => {
    expect(settlementSummary("cod", "unpaid")).toBe("Cash on delivery · payment pending");
    expect(settlementSummary("bank_transfer", "unpaid")).toBe("Bank transfer · payment pending");
    expect(settlementSummary("momo", "paid")).toBe("Mobile money · paid");
    expect(settlementSummary("cheque", "failed")).toBe("Cheque · payment failed");
  });
});

describe("canChangeSettlement", () => {
  it("allows an unpaid, non-credit, open order", () => {
    expect(
      canChangeSettlement({ status: "pending", payment_status: "unpaid", is_credit_order: false }),
    ).toBe(true);
    expect(canChangeSettlement({ status: "dispatched", payment_status: "unpaid" })).toBe(true);
  });
  it("blocks paid, credit, delivered and cancelled orders", () => {
    expect(canChangeSettlement({ status: "pending", payment_status: "paid" })).toBe(false);
    expect(
      canChangeSettlement({ status: "pending", payment_status: "unpaid", is_credit_order: true }),
    ).toBe(false);
    expect(canChangeSettlement({ status: "delivered", payment_status: "unpaid" })).toBe(false);
    expect(canChangeSettlement({ status: "cancelled", payment_status: "unpaid" })).toBe(false);
  });
});
