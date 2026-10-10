import { describe, expect, it } from "vitest";
import { onlinePaymentBlockedReason } from "./payments";
import { settlementOptions } from "./settlement";

describe("when Pay now cannot be chosen for a supplier", () => {
  it("is allowed for a supplier that can take online payments, with no limit", () => {
    expect(
      onlinePaymentBlockedReason({ supplierReady: true, total: 99999, maxOrderGhs: null }),
    ).toBeNull();
  });
  it("is blocked for a supplier without a settlement account, whatever the amount", () => {
    expect(
      onlinePaymentBlockedReason({ supplierReady: false, total: 10, maxOrderGhs: null }),
    ).toMatch(/can't take online payments yet/);
  });
  it("is blocked above the limit and names it, but allowed exactly at the limit", () => {
    expect(
      onlinePaymentBlockedReason({ supplierReady: true, total: 500.01, maxOrderGhs: 500 }),
    ).toMatch(/limited to GH₵ 500\.00 per order/);
    expect(
      onlinePaymentBlockedReason({ supplierReady: true, total: 500, maxOrderGhs: 500 }),
    ).toBeNull();
  });
});

describe("the Pay now option at checkout", () => {
  const payNow = (features: Parameters<typeof settlementOptions>[1]) =>
    settlementOptions({ state: "none" }, features).find((o) => o.value === "pay_now");

  it("shows the reason when a supplier cannot take it, and never offers it while online payments are off", () => {
    expect(
      payNow({
        onlinePayments: true,
        onlineBlockedReason: "This supplier can't take online payments yet.",
      }),
    ).toEqual({
      value: "pay_now",
      label: "Pay now (online)",
      disabled: true,
      reason: "This supplier can't take online payments yet.",
    });
    expect(payNow({ onlinePayments: false, onlineBlockedReason: null })).toMatchObject({
      disabled: true,
    });
    expect(payNow({ onlinePayments: false })).toMatchObject({
      disabled: true,
      reason: "Online payment isn't available yet.",
    });
  });
  it("is offered when nothing blocks it", () => {
    expect(payNow({ onlinePayments: true, onlineBlockedReason: null })).toEqual({
      value: "pay_now",
      label: "Pay now (online)",
      disabled: false,
    });
  });
});
