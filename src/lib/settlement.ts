// Settlement (payment) method: HOW the pharmacy intends to pay a supplier order. This is separate
// from the purchase classification (NHIS / Cash: WHY it is bought) and from the payment STATUS
// (whether money has actually been received). Choosing a method is never proof of payment: every
// method starts unpaid, and only a recorded payment (or, later, a confirmed online payment) moves an
// order to paid.

export type SettlementMethod =
  "pay_now" | "cod" | "credit" | "bank_transfer" | "momo" | "cheque" | "other";

export const SETTLEMENT_LABELS: Record<SettlementMethod, string> = {
  pay_now: "Pay now (online)",
  cod: "Cash on delivery",
  credit: "Credit",
  bank_transfer: "Bank transfer",
  momo: "Mobile money",
  cheque: "Cheque",
  other: "Other",
};

/** Methods that can be chosen at checkout today. "pay_now" is deliberately absent: there is no
 * online payment integration yet, and an order must never claim a payment that wasn't taken. */
export const SELECTABLE_SETTLEMENT_METHODS: SettlementMethod[] = [
  "cod",
  "credit",
  "bank_transfer",
  "momo",
  "cheque",
  "other",
];

/** Methods that may be switched to after an order is placed. Credit is excluded (it is backed by a
 * ledger invoice and a credit-limit check) and so is online payment. */
export const CHANGEABLE_SETTLEMENT_METHODS: SettlementMethod[] = [
  "cod",
  "bank_transfer",
  "momo",
  "cheque",
  "other",
];

export type SettlementOption = {
  value: SettlementMethod;
  label: string;
  disabled: boolean;
  /** Why the option can't be chosen, shown next to it. */
  reason?: string;
};

export type CreditAvailability =
  | { state: "none" }
  | { state: "available" }
  | { state: "insufficient"; availableLabel: string }
  | { state: "suspended" }
  | { state: "blocked" }
  | { state: "scheduled"; startsLabel: string };

/**
 * Keep credit discoverable even when unavailable; approval and limit checks still gate selection.
 */
export function settlementOptions(credit: CreditAvailability): SettlementOption[] {
  const options: SettlementOption[] = SELECTABLE_SETTLEMENT_METHODS.map((value) => ({
    value,
    label: SETTLEMENT_LABELS[value],
    disabled: false,
  }));

  const creditOption = options.find((option) => option.value === "credit");
  if (creditOption && credit.state === "none") {
    creditOption.disabled = true;
    creditOption.reason = "Ask this supplier to approve a credit account.";
  }
  if (creditOption && credit.state === "insufficient") {
    creditOption.disabled = true;
    creditOption.reason = `Only ${credit.availableLabel} of approved credit is left.`;
  }
  if (creditOption && credit.state === "suspended") {
    creditOption.disabled = true;
    creditOption.reason = "This supplier has suspended your credit.";
  }
  if (creditOption && credit.state === "scheduled") {
    creditOption.disabled = true;
    creditOption.reason = `Credit starts on ${credit.startsLabel}.`;
  }
  if (creditOption && credit.state === "blocked") {
    creditOption.disabled = true;
    creditOption.reason = "This supplier has blocked your credit.";
  }

  options.push({
    value: "pay_now",
    label: SETTLEMENT_LABELS.pay_now,
    disabled: true,
    reason: "Online payment isn't available yet.",
  });
  return options;
}

/** What a stored order shows. Orders placed before this feature have no stored method: they were
 * either on credit or pay-on-delivery, which the order itself says. */
export function effectiveSettlementMethod(order: {
  settlement_method?: string | null;
  is_credit_order?: boolean | null;
  payment_method?: string | null;
}): SettlementMethod {
  const stored = order.settlement_method;
  if (stored && stored in SETTLEMENT_LABELS) return stored as SettlementMethod;
  if (order.is_credit_order) return "credit";
  return order.payment_method === "paystack" ? "pay_now" : "cod";
}

export type PaymentStatusLike = "unpaid" | "paid" | "refunded" | "failed";

/** "Bank transfer · payment pending", "Cash on delivery · paid" ... */
export function settlementSummary(method: SettlementMethod, status: PaymentStatusLike): string {
  const state =
    status === "paid"
      ? "paid"
      : status === "failed"
        ? "payment failed"
        : status === "refunded"
          ? "refunded"
          : "payment pending";
  return `${SETTLEMENT_LABELS[method]} · ${state}`;
}

/** Whether a placed order's method can still be changed (mirrors the database rule): unpaid, not on
 * credit, and not delivered or cancelled. */
export function canChangeSettlement(order: {
  status: string;
  payment_status: string;
  is_credit_order?: boolean | null;
}): boolean {
  return (
    order.payment_status === "unpaid" &&
    !order.is_credit_order &&
    order.status !== "delivered" &&
    order.status !== "cancelled"
  );
}
