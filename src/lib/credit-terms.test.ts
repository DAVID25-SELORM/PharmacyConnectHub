import { describe, expect, it } from "vitest";
import { canUseCredit, creditSummary, validateCreditForm, type CreditTerms } from "./credit-terms";

const terms: CreditTerms = {
  wholesaler_id: "w",
  credit_limit_ghs: 700,
  payment_terms_days: 15,
  outstanding_ghs: 190,
  available_ghs: 510,
};

describe("credit terms helpers", () => {
  it("allows a charge only up to the available amount", () => {
    expect(canUseCredit(terms, 510)).toBe(true);
    expect(canUseCredit(terms, 510.01)).toBe(false);
    expect(canUseCredit(undefined, 10)).toBe(false);
  });

  it("summarises credit terms", () => {
    expect(creditSummary(terms)).toBe("GHS 510.00 available of GHS 700.00 · 15-day terms");
  });

  it("refuses suspended or blocked credit even when the balance fits", () => {
    expect(canUseCredit({ ...terms, status: "suspended" }, 100)).toBe(false);
    expect(canUseCredit({ ...terms, status: "blocked" }, 100)).toBe(false);
    expect(canUseCredit({ ...terms, status: "active" }, 100)).toBe(true);
  });

  it("refuses invalid charges and unavailable balance data", () => {
    for (const amount of [0, -1, NaN, Infinity]) {
      expect(canUseCredit(terms, amount)).toBe(false);
    }
    expect(canUseCredit({ ...terms, available_ghs: Infinity }, 100)).toBe(false);
  });

  it("validates the credit terms form like the database does", () => {
    expect(validateCreditForm({ limit: "700", days: "15" })).toMatchObject({
      error: null,
      limit: 700,
      days: 15,
    });
    expect(validateCreditForm({ limit: "0", days: "15" }).error).toMatch(/credit limit/);
    expect(validateCreditForm({ limit: "-5", days: "15" }).error).toMatch(/credit limit/);
    expect(validateCreditForm({ limit: "700", days: "0" }).error).toMatch(/Payment terms/);
    expect(validateCreditForm({ limit: "700", days: "400" }).error).toMatch(/Payment terms/);
    expect(validateCreditForm({ limit: "700", days: "15.5" }).error).toMatch(/whole number/);
  });
});
