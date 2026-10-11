import { describe, expect, it } from "vitest";
import { onlinePaymentBlockedReason, supplierOnlineStatusLine } from "./payments";
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

describe("what a supplier sees about online payments", () => {
  const base = {
    online_enabled: true,
    mode: "test" as const,
    split_mode: "subaccount" as const,
    ready: true,
    account: null,
    summary: {
      payments: 0,
      received_ghs: 0,
      platform_share_ghs: 0,
      refunded_ghs: 0,
      to_settle_ghs: 0,
    },
    recent: [],
  };
  it("says online payments are off, and asks nothing of the supplier", () => {
    expect(
      supplierOnlineStatusLine({ ...base, online_enabled: false, ready: false }),
    ).toMatchObject({
      label: "Online payments are off",
      tone: "neutral",
    });
  });
  it("says customers can pay, and where the money goes", () => {
    expect(supplierOnlineStatusLine(base)).toMatchObject({
      tone: "good",
      label: "Customers can pay you online",
    });
    expect(supplierOnlineStatusLine({ ...base, split_mode: "none" }).detail).toMatch(
      /no real money moves/,
    );
  });
  it("explains each way it cannot work and what to do", () => {
    const not = { ...base, ready: false };
    expect(supplierOnlineStatusLine(not)).toMatchObject({
      tone: "bad",
      label: "No settlement account yet",
    });
    expect(
      supplierOnlineStatusLine({
        ...not,
        account: { status: "pending", bank_code: "GCB", last4: "1234", business_name: "A" },
      }).label,
    ).toBe("Your settlement account is being set up");
    expect(
      supplierOnlineStatusLine({
        ...not,
        account: { status: "inactive", bank_code: "GCB", last4: "1234", business_name: "A" },
      }),
    ).toMatchObject({ tone: "bad", label: "Your settlement account is switched off" });
    expect(
      supplierOnlineStatusLine({
        ...not,
        account: { status: "failed", bank_code: "GCB", last4: "1234", business_name: "A" },
      }).label,
    ).toBe("No settlement account yet");
  });
});
