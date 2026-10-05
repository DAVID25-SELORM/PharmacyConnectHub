export type CreditTerms = {
  wholesaler_id: string;
  credit_limit_ghs: number;
  payment_terms_days: number;
  outstanding_ghs: number;
  available_ghs: number;
  /** active | suspended | blocked. Suspended and blocked relationships take no new credit orders. */
  status?: "active" | "suspended" | "blocked";
  /** A one-time over-limit approval from the supplier: the largest single order it covers. */
  override_max_order_ghs?: number | string | null;
  override_expires_at?: string | null;
};

const cents = (value: number) => Math.round(value * 100) / 100;

/** The supplier's unexpired one-time over-limit approval, if any. */
export function activeOverride(
  terms: CreditTerms | undefined,
  now: Date = new Date(),
): { maxOrderGhs: number; expiresAt: string } | null {
  if (!terms || terms.override_max_order_ghs == null || !terms.override_expires_at) return null;
  const max = Number(terms.override_max_order_ghs);
  if (!Number.isFinite(max) || max <= 0) return null;
  if (new Date(terms.override_expires_at).getTime() <= now.getTime()) return null;
  return { maxOrderGhs: max, expiresAt: terms.override_expires_at };
}

const isActive = (terms: CreditTerms) => terms.status === undefined || terms.status === "active";

/** True when this charge does not fit the remaining limit but the one-time override covers it. */
export function usesOverride(
  terms: CreditTerms | undefined,
  amount: number,
  now: Date = new Date(),
) {
  const override = activeOverride(terms, now);
  return (
    Boolean(terms) &&
    isActive(terms!) &&
    override !== null &&
    Number.isFinite(amount) &&
    amount > 0 &&
    cents(amount) > cents(Number(terms!.available_ghs)) &&
    cents(amount) <= cents(override.maxOrderGhs)
  );
}

/**
 * Whether a charge of this size can go on the wholesaler's approved credit line right now: it fits
 * the remaining limit, or the supplier's one-time override covers it. Suspended and blocked lines
 * never can, override or not. The database repeats the check.
 */
export function canUseCredit(
  terms: CreditTerms | undefined,
  amount: number,
  now: Date = new Date(),
) {
  return (
    Boolean(terms) &&
    isActive(terms!) &&
    Number.isFinite(amount) &&
    amount > 0 &&
    ((Number.isFinite(Number(terms!.available_ghs)) &&
      cents(amount) <= cents(Number(terms!.available_ghs))) ||
      usesOverride(terms, amount, now))
  );
}

const money = (value: number) =>
  `GHS ${Number(value).toLocaleString("en-GH", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export function creditSummary(terms: CreditTerms) {
  return `${money(terms.available_ghs)} available of ${money(terms.credit_limit_ghs)} · ${terms.payment_terms_days}-day terms`;
}

/** Validates the wholesaler's credit-terms form. The database repeats every check. */
export function validateCreditForm(input: { limit: string; days: string }) {
  const limit = Number(input.limit);
  const days = Number(input.days);
  if (!Number.isFinite(limit) || limit <= 0 || limit > 10_000_000) {
    return { error: "The credit limit must be above 0 and at most 10,000,000." };
  }
  if (!Number.isInteger(days) || days < 1 || days > 365) {
    return { error: "Payment terms must be a whole number of days between 1 and 365." };
  }
  return { error: null, limit, days };
}
