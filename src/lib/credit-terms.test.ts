import { describe, expect, it } from "vitest";
import {
  activeOverride,
  canUseCredit,
  creditSummary,
  usesOverride,
  validateCreditForm,
  type CreditTerms,
} from "./credit-terms";

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

const now = new Date("2026-10-05T12:00:00Z");
const withOverride = (max: number | string, expires = "2026-10-12T12:00:00Z"): CreditTerms => ({
  ...terms,
  override_max_order_ghs: max,
  override_expires_at: expires,
});

describe("one-time over-limit override", () => {
  it("lets an order above the remaining limit through, up to the override maximum", () => {
    expect(canUseCredit(terms, 600, now)).toBe(false);
    expect(canUseCredit(withOverride(800), 600, now)).toBe(true);
    expect(canUseCredit(withOverride(800), 800, now)).toBe(true);
    expect(canUseCredit(withOverride(800), 800.01, now)).toBe(false);
  });

  it("only reports an override as used when the order does not fit the limit", () => {
    expect(usesOverride(withOverride(800), 500, now)).toBe(false); // fits 510 available
    expect(usesOverride(withOverride(800), 600, now)).toBe(true);
    expect(usesOverride(terms, 600, now)).toBe(false);
  });

  it("ignores an expired override", () => {
    const expired = withOverride(800, "2026-10-05T11:59:00Z");
    expect(activeOverride(expired, now)).toBeNull();
    expect(canUseCredit(expired, 600, now)).toBe(false);
  });

  it("accepts the numeric string the database returns", () => {
    expect(activeOverride(withOverride("800.00"), now)).toEqual({
      maxOrderGhs: 800,
      expiresAt: "2026-10-12T12:00:00Z",
    });
  });

  it("never beats a suspended or blocked line", () => {
    for (const status of ["suspended", "blocked"] as const) {
      const line = { ...withOverride(800), status };
      expect(canUseCredit(line, 600, now)).toBe(false);
      expect(usesOverride(line, 600, now)).toBe(false);
    }
  });

  it("a credit line that has not started yet can never be used, with or without an override", () => {
    const notStarted = {
      ...withOverride(800),
      status: "scheduled" as const,
      starts_on: "2026-10-20",
    };
    expect(canUseCredit(notStarted, 100, now)).toBe(false);
    expect(canUseCredit(notStarted, 600, now)).toBe(false);
    expect(usesOverride(notStarted, 600, now)).toBe(false);
  });

  it("has no override when the fields are absent or invalid", () => {
    expect(activeOverride(undefined, now)).toBeNull();
    expect(activeOverride(terms, now)).toBeNull();
    expect(
      activeOverride(
        { ...terms, override_max_order_ghs: 0, override_expires_at: "2026-10-12T12:00:00Z" },
        now,
      ),
    ).toBeNull();
  });
});
