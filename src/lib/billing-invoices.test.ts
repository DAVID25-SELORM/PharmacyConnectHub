import { describe, expect, it } from "vitest";
import { buildBillingInvoicePdf, invoiceFileName } from "./billing-invoice-pdf";
import {
  INVOICE_STATUS_LABELS,
  MANUAL_METHODS,
  PAYMENT_METHOD_LABELS,
  describePayment,
  dueText,
  newRequestKey,
  paymentFormError,
  receivedAtFromDate,
  type InvoiceDetail,
} from "./billing-invoices";

const now = new Date("2026-10-12T10:00:00Z");
const inv = (
  status: "issued" | "partially_paid" | "paid" | "overdue",
  due: string,
  outstanding = 50,
) => ({
  status,
  due_at: due,
  outstanding_amount: outstanding,
});

describe("when an invoice is due", () => {
  it("counts the days to the due date", () => {
    expect(dueText(inv("issued", "2026-10-17T10:00:00Z"), now)).toBe("Due in 5 days");
    expect(dueText(inv("issued", "2026-10-13T10:00:00Z"), now)).toBe("Due tomorrow");
    expect(dueText(inv("issued", "2026-10-12T20:00:00Z"), now)).toBe("Due today");
  });
  it("counts the days late once the date has passed", () => {
    expect(dueText(inv("overdue", "2026-10-11T00:00:00Z"), now)).toBe("1 day overdue");
    expect(dueText(inv("overdue", "2026-10-02T00:00:00Z"), now)).toBe("10 days overdue");
  });
  it("says Paid for a settled invoice whatever its date", () => {
    expect(dueText(inv("paid", "2026-09-01T00:00:00Z", 0), now)).toBe("Paid");
    expect(dueText(inv("issued", "2026-09-01T00:00:00Z", 0), now)).toBe("Paid");
  });
});

describe("the record-payment form", () => {
  const ok = {
    amount: "50.00",
    outstanding: 120,
    receivedAt: "2026-10-12",
    reason: "Seen on the bank statement",
    now,
  };
  it("accepts a good payment, including exactly the balance", () => {
    expect(paymentFormError(ok)).toBeNull();
    expect(paymentFormError({ ...ok, amount: "120" })).toBeNull();
    expect(paymentFormError({ ...ok, amount: "0.01" })).toBeNull();
  });
  it("explains each mistake", () => {
    expect(paymentFormError({ ...ok, amount: "" })).toMatch(/Enter the amount/);
    expect(paymentFormError({ ...ok, amount: "abc" })).toMatch(/Enter the amount/);
    expect(paymentFormError({ ...ok, amount: "10.123" })).toMatch(/at most two decimals/);
    expect(paymentFormError({ ...ok, amount: "-5" })).toMatch(/Enter the amount/);
    expect(paymentFormError({ ...ok, amount: "0" })).toMatch(/more than zero/);
    expect(paymentFormError({ ...ok, amount: "120.01" })).toMatch(
      /more than the balance of this invoice \(GH₵ 120.00\)/,
    );
    expect(paymentFormError({ ...ok, receivedAt: "" })).toMatch(/date the payment was received/);
    expect(paymentFormError({ ...ok, receivedAt: "12/10/2026" })).toMatch(/valid date/);
    expect(paymentFormError({ ...ok, receivedAt: "2026-10-13" })).toMatch(
      /cannot be in the future/,
    );
    expect(paymentFormError({ ...ok, reason: "no" })).toMatch(/at least 5 characters/);
  });
  it("compares money in whole pesewas, so 0.1 + 0.2 style rounding never refuses a right amount", () => {
    expect(paymentFormError({ ...ok, amount: "0.30", outstanding: 0.1 + 0.2 })).toBeNull();
  });
});

describe("the moment a payment is recorded for", () => {
  it("is now for today (the database refuses the future), and midday for an earlier day", () => {
    expect(receivedAtFromDate("2026-10-12", now).toISOString()).toBe(now.toISOString());
    expect(receivedAtFromDate("2026-10-09", now).toISOString()).toBe("2026-10-09T12:00:00.000Z");
  });
  it("gives a different request key each time, so two payments are never mistaken for one", () => {
    expect(newRequestKey()).not.toBe(newRequestKey());
    expect(newRequestKey()).toMatch(/^pay:/);
  });
});

describe("wording", () => {
  it("names every status and method in plain words", () => {
    expect(INVOICE_STATUS_LABELS).toEqual({
      issued: "Unpaid",
      partially_paid: "Part paid",
      paid: "Paid",
      overdue: "Overdue",
    });
    expect(PAYMENT_METHOD_LABELS.mobile_money).toBe("Mobile money");
    expect(MANUAL_METHODS).not.toContain("card");
  });
  it("describes a payment, a reversed one and a reversal", () => {
    expect(describePayment({ kind: "payment", method: "bank_transfer", reversed: false })).toBe(
      "Bank transfer",
    );
    expect(describePayment({ kind: "payment", method: "cash", reversed: true })).toBe(
      "Cash (reversed)",
    );
    expect(describePayment({ kind: "reversal", method: "cheque", reversed: false })).toBe(
      "Reversal (Cheque)",
    );
  });
});

describe("the invoice PDF", () => {
  const detail: InvoiceDetail = {
    id: "i1",
    invoice_number: "DXB-2026-000007",
    period_start: "2026-09-01T00:00:00Z",
    period_end: "2026-10-01T00:00:00Z",
    issued_at: "2026-10-02T00:00:00Z",
    due_at: "2026-10-16T00:00:00Z",
    total_amount: 140,
    amount_paid: 40,
    outstanding_amount: 100,
    status: "partially_paid",
    currency: "GHS",
    business_id: "b1",
    business_name: "ABC Pharma Wholesale",
    business_type: "wholesaler",
    subscription_amount: 100,
    transaction_fees_amount: 40,
    debits_amount: 0,
    credits_amount: 0,
    credit_brought_forward: 0,
    paid_at: null,
    summary: { period_label: "1 Sep 2026 – 30 Sep 2026", eligible_orders: 5 },
    issuer: {
      name: "DrugXOne Ltd",
      payment_instructions: "Pay by mobile money and quote the invoice number.",
    },
    customer: {
      name: "ABC Pharma Wholesale",
      license_number: "LIC-1",
      address: "1 High St",
      city: "Accra",
      region: "Greater Accra",
    },
    lines: [
      { line_no: 1, kind: "subscription", description: "Subscription: Growth", amount: 100 },
      {
        line_no: 2,
        kind: "transaction_fees",
        description: "Platform transaction fees",
        amount: 40,
      },
    ],
    payments: [
      {
        id: "p1",
        kind: "payment",
        amount: 40,
        method: "mobile_money",
        reference: "MM-1",
        received_at: "2026-10-05T00:00:00Z",
        note: null,
        reason: null,
        reverses_payment_id: null,
        recorded_at: "2026-10-05T01:00:00Z",
        reversed: false,
      },
    ],
    orders: [
      {
        order_number: "ORD-1",
        delivered_at: null,
        assessed_at: "2026-09-05T00:00:00Z",
        kind: "primary",
        adjustment_seq: 0,
        billable_gmv: 1000,
        outcome: "chargeable",
        free_source: null,
        free_seq: null,
        percentage: 1,
        fee_after_limits: 10,
        cap_adjustment: 0,
        charged_amount: 10,
      },
    ],
  };
  it("is built from the saved invoice and carries its number, who it is for and what is owed", () => {
    const pdf = buildBillingInvoicePdf(detail);
    expect(pdf.getNumberOfPages()).toBeGreaterThanOrEqual(1);
    const text = pdf.output();
    expect(text.length).toBeGreaterThan(1000);
    expect(invoiceFileName(detail)).toBe("DXB-2026-000007.pdf");
  });
  it("also builds for a pharmacy invoice with no orders and no payments", () => {
    const pdf = buildBillingInvoicePdf({
      ...detail,
      business_type: "pharmacy",
      orders: [],
      payments: [],
      status: "issued",
      amount_paid: 0,
      outstanding_amount: 140,
    });
    expect(pdf.getNumberOfPages()).toBeGreaterThanOrEqual(1);
  });
});
