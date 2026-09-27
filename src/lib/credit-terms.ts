export type CreditTerms = {
  wholesaler_id: string;
  credit_limit_ghs: number;
  payment_terms_days: number;
  outstanding_ghs: number;
  available_ghs: number;
};

const cents = (value: number) => Math.round(value * 100) / 100;

/** Whether a charge of this size can go on the wholesaler's approved credit line right now. */
export function canUseCredit(terms: CreditTerms | undefined, amount: number) {
  return Boolean(terms) && cents(amount) <= cents(Number(terms!.available_ghs));
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
