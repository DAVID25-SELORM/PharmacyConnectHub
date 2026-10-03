// Credit ledger: shared types + client-side validation for the payment-recording UI.
// The database repeats every check here (record_credit_payment) -- this is just to fail fast
// with a clear message before making the round trip.

export type CreditInvoiceStatus =
  "not_due" | "partially_paid" | "paid" | "due_today" | "overdue" | "written_off" | "disputed";

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

export type CreditAging = {
  current: number;
  days_1_30: number;
  days_31_60: number;
  days_61_90: number;
  days_90_plus: number;
};

export type WholesalerArSummary = {
  total_credit_sales_ghs: number;
  total_outstanding_ghs: number;
  due_within_7_days_ghs: number;
  due_within_30_days_ghs: number;
  overdue_ghs: number;
  collected_this_month_ghs: number;
  invoice_count: number;
  outstanding_invoice_count: number;
  aging: CreditAging;
  outstanding_by_pharmacy: Array<{
    pharmacy_id: string;
    pharmacy_name: string;
    outstanding_ghs: number;
    invoice_count: number;
  }>;
};

export type PharmacyApSummary = {
  total_supplier_debt_ghs: number;
  due_this_week_ghs: number;
  due_this_month_ghs: number;
  overdue_ghs: number;
  paid_this_month_ghs: number;
  invoice_count: number;
  outstanding_invoice_count: number;
  aging: CreditAging;
  outstanding_by_wholesaler: Array<{
    wholesaler_id: string;
    wholesaler_name: string;
    outstanding_ghs: number;
    invoice_count: number;
  }>;
};

export const AGING_BUCKET_LABELS: Array<{ key: keyof CreditAging; label: string }> = [
  { key: "current", label: "Current" },
  { key: "days_1_30", label: "1-30 days" },
  { key: "days_31_60", label: "31-60 days" },
  { key: "days_61_90", label: "61-90 days" },
  { key: "days_90_plus", label: "90+ days" },
];

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
  if (!Number.isFinite(amount) || cents(amount) <= 0) {
    return { error: "Enter a payment amount greater than zero." };
  }
  if (!PAYMENT_METHODS.some((method) => method.value === input.method)) {
    return { error: "Choose a payment method." };
  }
  return { error: null, amount: cents(amount) };
}

/** Validates the allocation list against the payment amount, mirroring record_credit_payment's
 * own checks so the user sees the problem before the round trip. */
export function validateAllocations(
  amount: number,
  allocations: Array<{ order_id: string; amount: string; outstanding_ghs: number }>,
) {
  if (!Number.isFinite(amount) || cents(amount) <= 0) {
    return { error: "Enter a payment amount greater than zero." };
  }
  let sum = 0;
  const seen = new Set<string>();
  for (const a of allocations) {
    if (!a.order_id || seen.has(a.order_id)) {
      return { error: "Select each invoice only once." };
    }
    seen.add(a.order_id);
    const value = Number(a.amount);
    if (!Number.isFinite(value) || cents(value) <= 0) {
      return { error: "Each selected invoice needs an allocation amount greater than zero." };
    }
    if (!Number.isFinite(a.outstanding_ghs) || cents(value) > cents(a.outstanding_ghs)) {
      return { error: "An allocation cannot exceed that invoice's outstanding balance." };
    }
    // The RPC rounds each allocation before summing. Sum integer pesewas here too.
    sum += Math.round(value * 100);
  }
  const allocated = sum / 100;
  if (allocated > cents(amount)) {
    return { error: "The allocations add up to more than the payment amount." };
  }
  return { error: null, allocated, unallocated: cents(cents(amount) - allocated) };
}

/** Default allocation for a freshly-checked invoice: whatever is still unapplied from the
 * payment amount, capped at that invoice's own outstanding balance. */
export function suggestAllocation(remainingToAllocate: number, outstanding: number) {
  return cents(Math.max(0, Math.min(remainingToAllocate, outstanding)));
}
