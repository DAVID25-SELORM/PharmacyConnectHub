import { describe, expect, it } from "vitest";
import { suggestAllocation, validateAllocations, validatePaymentHeader } from "./credit-ledger";

describe("validatePaymentHeader", () => {
  it("accepts a positive amount and a method", () => {
    expect(validatePaymentHeader({ amount: "150", method: "cash" })).toEqual({
      error: null,
      amount: 150,
    });
  });

  it("rejects a zero, negative or non-numeric amount", () => {
    expect(validatePaymentHeader({ amount: "0", method: "cash" }).error).toBeTruthy();
    expect(validatePaymentHeader({ amount: "-5", method: "cash" }).error).toBeTruthy();
    expect(validatePaymentHeader({ amount: "abc", method: "cash" }).error).toBeTruthy();
  });

  it("rejects a missing method", () => {
    expect(validatePaymentHeader({ amount: "150", method: "" }).error).toBeTruthy();
    expect(validatePaymentHeader({ amount: "150", method: "invented" }).error).toBeTruthy();
  });

  it("rejects payments that round to zero", () => {
    expect(validatePaymentHeader({ amount: "0.001", method: "cash" }).error).toBeTruthy();
  });
});

describe("validateAllocations", () => {
  it("rounds each line before summing, matching the RPC", () => {
    const allocations = [
      { order_id: "a", amount: "0.006", outstanding_ghs: 1 },
      { order_id: "b", amount: "0.006", outstanding_ghs: 1 },
    ];
    expect(validateAllocations(0.01, allocations).error).toBeTruthy();
    expect(validateAllocations(0.02, allocations)).toEqual({
      error: null,
      allocated: 0.02,
      unallocated: 0,
    });
  });

  it("rejects duplicate invoices, invalid balances and sub-cent allocations", () => {
    const line = { order_id: "a", amount: "1", outstanding_ghs: 10 };
    expect(validateAllocations(10, [line, line]).error).toBeTruthy();
    expect(validateAllocations(10, [{ ...line, outstanding_ghs: NaN }]).error).toBeTruthy();
    expect(validateAllocations(10, [{ ...line, amount: "0.001" }]).error).toBeTruthy();
    expect(validateAllocations(NaN, []).error).toBeTruthy();
  });

  it("accepts allocations that fit within both the payment and each invoice's outstanding", () => {
    const result = validateAllocations(150, [
      { order_id: "a", amount: "80", outstanding_ghs: 80 },
      { order_id: "b", amount: "60", outstanding_ghs: 60 },
    ]);
    expect(result).toEqual({ error: null, allocated: 140, unallocated: 10 });
  });

  it("rejects an allocation exceeding that invoice's outstanding balance", () => {
    const result = validateAllocations(150, [
      { order_id: "a", amount: "999", outstanding_ghs: 80 },
    ]);
    expect(result.error).toBeTruthy();
  });

  it("rejects allocations summing to more than the payment amount", () => {
    const result = validateAllocations(10, [{ order_id: "a", amount: "50", outstanding_ghs: 80 }]);
    expect(result.error).toBeTruthy();
  });

  it("rejects a zero or non-numeric allocation amount", () => {
    expect(
      validateAllocations(10, [{ order_id: "a", amount: "0", outstanding_ghs: 80 }]).error,
    ).toBeTruthy();
    expect(
      validateAllocations(10, [{ order_id: "a", amount: "x", outstanding_ghs: 80 }]).error,
    ).toBeTruthy();
  });

  it("an empty allocation list is valid (whole payment left unallocated)", () => {
    expect(validateAllocations(150, [])).toEqual({ error: null, allocated: 0, unallocated: 150 });
  });
});

describe("suggestAllocation", () => {
  it("suggests whatever remains, capped at the invoice's outstanding balance", () => {
    expect(suggestAllocation(150, 80)).toBe(80);
    expect(suggestAllocation(50, 80)).toBe(50);
    expect(suggestAllocation(0, 80)).toBe(0);
  });

  it("never suggests a negative amount when nothing is left to allocate", () => {
    expect(suggestAllocation(-10, 80)).toBe(0);
  });
});
