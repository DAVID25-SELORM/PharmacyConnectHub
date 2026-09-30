// Credit ledger: shared types + client-side validation for the payment-recording UI.
// The database repeats every check here (record_credit_payment) -- this is just to fail fast
// with a clear message before making the round trip.

export type CreditInvoiceStatus =
  | "not_due"
  | "partially_paid"
  | "paid"
  | "due_today"
  | "overdue"
  | "written_off"
  | "disputed";

export type CreditInvoice = {
  order_id: string;
  order_number: string;
  wholesaler_id: string;
  wholesaler_name: string;
  pharmacy_id: string;
  pharmacy_name: string;
  created_at: string;
  due_date: string | null;
  invoice_ghs: number;
  paid_ghs: number;
  outstanding_ghs: number;
  status: CreditInvoiceStatus;
};

export const CREDIT_INVOICE_STATUS_LABELS: Record<CreditInvoiceStatus, string> = {
  not_due: "Not due",
  partially_paid: "Partially paid",
  paid: "Paid",
  due_today: "Due today",
  overdue: "Overdue",
  written_off: "Written off",
  disputed: "Disputed",
};

export const CREDIT_INVOICE_STATUS_STYLES: Record<CreditInvoiceStatus, string> = {
  not_due: "bg-muted text-muted-foreground border-border",
  partially_paid: "bg-primary/15 text-primary border-primary/30",
  paid: "bg-success/15 text-success border-success/30",
  due_today: "bg-warning/15 text-warning-foreground border-warning/30",
  overdue: "bg-destructive/15 text-destructive border-destructive/30",
  written_off: "bg-muted text-muted-foreground border-border",
  disputed: "bg-accent/15 text-accent border-accent/30",
};

export const PAYMENT_METHODS = [
  { value: "cash", label: "Cash" },
  { value: "bank_transfer", label: "Bank transfer" },
  { value: "mobile_money", label: "Mobile money" },
  { value: "cheque", label: "Cheque" },
  { value: "online", label: "Online payment" },
  { value: "other", label: "Other" },
] as const;

export type PaymentAllocationDraft = {
  order_id: string;
  order_number: string;
  outstanding_ghs: number;
  selected: boolean;
  amount: string; // controlled input, parsed on submit
};

const cents = (value: number) => Math.round(value * 100) / 100;

/** Validates the payment header (amount + method) before submitting. */
export function validatePaymentHeader(input: { amount: string; method: string }) {
  const amount = Number(input.amount);
  if (!Number.isFinite(amount) || amount <= 0) {
    return { error: "Enter a payment amount greater than zero." };
  }
  if (!input.method) {
    return { error: "Choose a payment method." };
  }
  return { error: null, amount };
}

/** Validates the allocation list against the payment amount, mirroring record_credit_payment's
 * own checks so the user sees the problem before the round trip. */
export function validateAllocations(
  amount: number,
  allocations: Array<{ order_id: string; amount: string; outstanding_ghs: number }>,
) {
  let sum = 0;
  for (const a of allocations) {
    const value = Number(a.amount);
    if (!Number.isFinite(value) || value <= 0) {
      return { error: "Each selected invoice needs an allocation amount greater than zero." };
    }
    if (cents(value) > cents(a.outstanding_ghs)) {
      return { error: "An allocation cannot exceed that invoice's outstanding balance." };
    }
    sum += value;
  }
  if (cents(sum) > cents(amount)) {
    return { error: "The allocations add up to more than the payment amount." };
  }
  return { error: null, allocated: cents(sum), unallocated: cents(amount - sum) };
}

/** Default allocation for a freshly-checked invoice: whatever is still unapplied from the
 * payment amount, capped at that invoice's own outstanding balance. */
export function suggestAllocation(remainingToAllocate: number, outstanding: number) {
  return cents(Math.max(0, Math.min(remainingToAllocate, outstanding)));
}
