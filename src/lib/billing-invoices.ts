// Platform billing invoices, from the screens' side. A business reads its own invoices; an administrator reads all of them and records the payments that arrive (bank transfer, mobile
// money, cash, cheque). The browser never works out an amount owed: it shows what the database issued and sends only "this much was received, this way, on this date, for this reason".
import { supabase } from "@/integrations/supabase/client";
import type { BillingOrderRow } from "./billing";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const db = supabase as any;

export type InvoiceStatus = "issued" | "partially_paid" | "paid" | "overdue";

export type InvoiceRow = {
  id: string;
  invoice_number: string;
  period_start: string;
  period_end: string;
  issued_at: string;
  due_at: string;
  total_amount: number;
  amount_paid: number;
  outstanding_amount: number;
  status: InvoiceStatus;
  currency: string;
  business_id?: string;
  business_name?: string;
  business_type?: string;
};

export type PaymentRow = {
  id: string;
  invoice_number: string;
  kind: "payment" | "reversal";
  amount: number;
  method: PaymentMethod;
  reference: string | null;
  received_at: string;
  currency: string;
};

export type MyInvoices = {
  count: number;
  outstanding_total: number;
  overdue_total: number;
  paid_total: number;
  credit_available: number;
  invoices: InvoiceRow[];
  payments: PaymentRow[];
};

export type InvoiceLine = {
  line_no: number;
  kind: string;
  description: string;
  amount: number;
};

export type InvoicePayment = {
  id: string;
  kind: "payment" | "reversal";
  amount: number;
  method: PaymentMethod;
  reference: string | null;
  received_at: string;
  note: string | null;
  reason: string | null;
  reverses_payment_id: string | null;
  recorded_at: string;
  recorded_by_email?: string | null;
  reversed: boolean;
};

export type InvoiceDetail = InvoiceRow & {
  business_id: string;
  business_name: string;
  business_type: string;
  subscription_amount: number;
  transaction_fees_amount: number;
  debits_amount: number;
  credits_amount: number;
  credit_brought_forward: number;
  paid_at: string | null;
  summary: {
    plan_name?: string | null;
    plan_code?: string | null;
    period_label?: string | null;
    eligible_orders?: number | null;
    free_onboarding_orders?: number | null;
    free_monthly_orders?: number | null;
    chargeable_orders?: number | null;
    billable_gmv?: number | null;
    fees_before_cap?: number | null;
    transaction_fee_percentage?: number | null;
    transaction_fee_cycle_cap?: number | null;
  };
  issuer: Record<string, string>;
  customer: Record<string, string | null>;
  lines: InvoiceLine[];
  payments: InvoicePayment[];
  orders: BillingOrderRow[];
};

export type AdminInvoices = {
  count: number;
  totals: { invoiced: number; paid: number; outstanding: number; overdue: number };
  invoices: InvoiceRow[];
};

export async function fetchMyInvoices(
  businessId: string,
  limit = 24,
  offset = 0,
): Promise<MyInvoices> {
  const { data, error } = await db.rpc("billing_my_invoices", {
    p_business_id: businessId,
    p_limit: limit,
    p_offset: offset,
  });
  if (error) throw new Error(error.message);
  return data as MyInvoices;
}

export async function fetchMyInvoice(invoiceId: string): Promise<InvoiceDetail> {
  const { data, error } = await db.rpc("billing_my_invoice", { p_invoice_id: invoiceId });
  if (error) throw new Error(error.message);
  return data as InvoiceDetail;
}

export type AdminInvoiceFilters = {
  status?: InvoiceStatus | null;
  businessType?: "pharmacy" | "wholesaler" | null;
  search?: string;
  limit?: number;
  offset?: number;
};

export async function fetchAdminInvoices(filters: AdminInvoiceFilters): Promise<AdminInvoices> {
  const { data, error } = await db.rpc("admin_billing_invoices", {
    p_status: filters.status ?? null,
    p_business_type: filters.businessType ?? null,
    p_search: filters.search?.trim() || null,
    p_limit: filters.limit ?? 25,
    p_offset: filters.offset ?? 0,
  });
  if (error) throw new Error(error.message);
  return data as AdminInvoices;
}

export async function fetchAdminInvoice(invoiceId: string): Promise<InvoiceDetail> {
  const { data, error } = await db.rpc("admin_billing_invoice_detail", { p_invoice_id: invoiceId });
  if (error) throw new Error(error.message);
  return data as InvoiceDetail;
}

export type PaymentMethod = "bank_transfer" | "mobile_money" | "cash" | "cheque" | "card" | "other";

export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  bank_transfer: "Bank transfer",
  mobile_money: "Mobile money",
  cash: "Cash",
  cheque: "Cheque",
  card: "Card",
  other: "Other",
};

/** The methods an administrator can record by hand (card is for a later automatic provider). */
export const MANUAL_METHODS: PaymentMethod[] = [
  "bank_transfer",
  "mobile_money",
  "cash",
  "cheque",
  "other",
];

export type RecordPaymentInput = {
  invoiceId: string;
  amount: number;
  method: PaymentMethod;
  reference: string;
  receivedAt: Date;
  note: string;
  reason: string;
  /** One key per "Record payment" click sequence: sending it twice records it once. */
  requestKey: string;
};

export async function recordPayment(input: RecordPaymentInput): Promise<{
  payment_id: string;
  replayed: boolean;
  invoice_status: InvoiceStatus;
  outstanding: number;
}> {
  const { data, error } = await db.rpc("admin_billing_record_payment", {
    p_invoice_id: input.invoiceId,
    p_amount: input.amount,
    p_method: input.method,
    p_reference: input.reference.trim() || null,
    p_received_at: input.receivedAt.toISOString(),
    p_note: input.note.trim() || null,
    p_reason: input.reason,
    p_idempotency_key: input.requestKey,
  });
  if (error) throw new Error(error.message);
  return data;
}

export async function reversePayment(
  paymentId: string,
  reason: string,
): Promise<{ reversal_id: string; invoice_status: InvoiceStatus; outstanding: number }> {
  const { data, error } = await db.rpc("admin_billing_reverse_payment", {
    p_payment_id: paymentId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
  return data;
}

export type InvoiceSettings = {
  payment_terms_days: number;
  invoice_delay_hours: number;
  issuer: Record<string, string>;
};

export async function fetchInvoiceSettings(): Promise<InvoiceSettings> {
  const { data, error } = await db
    .from("billing_settings")
    .select("payment_terms_days, invoice_delay_hours, issuer")
    .single();
  if (error) throw new Error(error.message);
  return data as InvoiceSettings;
}

export async function saveInvoiceSettings(
  settings: InvoiceSettings,
  reason: string,
): Promise<InvoiceSettings> {
  const { data, error } = await db.rpc("admin_billing_set_invoice_settings", {
    p_payment_terms_days: settings.payment_terms_days,
    p_invoice_delay_hours: settings.invoice_delay_hours,
    p_issuer: settings.issuer,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
  return data as InvoiceSettings;
}

// ---------------------------------------------------------------------------
// Wording and small checks (pure, tested)
// ---------------------------------------------------------------------------
export const dateText = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleDateString("en-GB", {
        day: "numeric",
        month: "short",
        year: "numeric",
        timeZone: "UTC",
      })
    : "–";

export const INVOICE_STATUS_TONE: Record<InvoiceStatus, string> = {
  issued: "border-primary/30 bg-primary/10 text-primary",
  partially_paid: "border-warning/30 bg-warning/15 text-warning-foreground",
  paid: "border-success/30 bg-success/15 text-success",
  overdue: "border-destructive/30 bg-destructive/15 text-destructive",
};

export const INVOICE_STATUS_LABELS: Record<InvoiceStatus, string> = {
  issued: "Unpaid",
  partially_paid: "Part paid",
  paid: "Paid",
  overdue: "Overdue",
};

export const ISSUER_FIELDS: { key: string; label: string; multiline?: boolean }[] = [
  { key: "name", label: "Name on invoices" },
  { key: "address", label: "Address" },
  { key: "email", label: "Email" },
  { key: "phone", label: "Phone" },
  { key: "website", label: "Website" },
  { key: "payment_instructions", label: "How to pay (shown on every invoice)", multiline: true },
  { key: "tax_note", label: "Tax note (optional)", multiline: true },
];

const DAY = 86_400_000;

/** "Due in 5 days", "Due today", "3 days overdue", "Paid". The date is the server's; only the wording is made here. */
export function dueText(
  inv: Pick<InvoiceRow, "status" | "due_at" | "outstanding_amount">,
  now: Date = new Date(),
): string {
  if (inv.status === "paid" || inv.outstanding_amount <= 0) return "Paid";
  const ahead = new Date(inv.due_at).getTime() - now.getTime();
  if (ahead >= 0) {
    const days = Math.floor(ahead / DAY);
    if (days > 1) return `Due in ${days} days`;
    return days === 1 ? "Due tomorrow" : "Due today";
  }
  const late = Math.max(1, Math.floor(-ahead / DAY));
  return late === 1 ? "1 day overdue" : `${late} days overdue`;
}

/** Checks the form before it is sent. The database checks again; this is only so a mistake is explained on the spot. */
export function paymentFormError(input: {
  amount: string;
  outstanding: number;
  receivedAt: string;
  reason: string;
  now?: Date;
}): string | null {
  const text = input.amount.trim();
  if (!/^\d+(\.\d{1,2})?$/.test(text))
    return "Enter the amount received, with at most two decimals.";
  const amount = Number(text);
  if (amount <= 0) return "The amount must be more than zero.";
  if (Math.round(amount * 100) > Math.round(input.outstanding * 100))
    return `This is more than the balance of this invoice (GH₵ ${input.outstanding.toFixed(2)}).`;
  if (!input.receivedAt) return "Enter the date the payment was received.";
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(input.receivedAt) ||
    Number.isNaN(new Date(`${input.receivedAt}T12:00:00Z`).getTime())
  )
    return "Enter a valid date.";
  if (input.receivedAt > (input.now ?? new Date()).toISOString().slice(0, 10))
    return "The date received cannot be in the future.";
  if (input.reason.trim().length < 5) return "Give a reason of at least 5 characters.";
  return null;
}

/** The moment to record for a "date received": the current moment if it is today (the database refuses the future), otherwise midday on that day. */
export function receivedAtFromDate(date: string, now: Date = new Date()): Date {
  return date === now.toISOString().slice(0, 10) ? now : new Date(`${date}T12:00:00Z`);
}

export function newRequestKey(): string {
  return typeof crypto !== "undefined" && "randomUUID" in crypto
    ? `pay:${crypto.randomUUID()}`
    : `pay:${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

/** What a payment record is called in a list: "Payment" or "Reversal", with the method. */
export function describePayment(p: Pick<InvoicePayment, "kind" | "method" | "reversed">): string {
  const method = PAYMENT_METHOD_LABELS[p.method] ?? p.method;
  if (p.kind === "reversal") return `Reversal (${method})`;
  return p.reversed ? `${method} (reversed)` : method;
}
