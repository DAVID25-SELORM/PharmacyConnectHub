import { describe, expect, it } from "vitest";
import {
  AGING_BUCKETS,
  EMPTY_INVOICE_FILTERS,
  agingBucketLabel,
  agingExportSheet,
  canViewAccounting,
  describeInvoiceFilters,
  hasInvoiceFilters,
  invoiceExportSheet,
  invoiceFilterProblem,
  invoiceRegisterArgs,
  paymentExportSheet,
  paymentRegisterArgs,
  type InvoiceRow,
  type PaymentRow,
} from "./accounting";

const invoice: InvoiceRow = {
  order_id: "o1",
  order_number: "ORD-100",
  counterparty_id: "p1",
  counterparty_name: "Good Pharmacy",
  invoice_date: "2026-08-20",
  due_date: "2026-09-19",
  invoice_ghs: "10000.00",
  paid_ghs: "8000.00",
  outstanding_ghs: "2000.00",
  status: "partially_paid",
  days_overdue: 45,
  aging_bucket: "d31_60",
  total_count: 1,
};

describe("who may open Accounting", () => {
  it("matches the database rule for each side", () => {
    for (const role of ["owner", "manager", "finance", "accountant"])
      expect(canViewAccounting("wholesaler", role)).toBe(true);
    for (const role of ["cashier", "assistant", "warehouse", undefined])
      expect(canViewAccounting("wholesaler", role)).toBe(false);
    for (const role of ["owner", "manager", "accountant"])
      expect(canViewAccounting("pharmacy", role)).toBe(true);
    for (const role of ["cashier", "assistant", "finance", undefined])
      expect(canViewAccounting("pharmacy", role)).toBe(false);
  });
});

describe("aging labels", () => {
  it("states each range in words so meaning never depends on colour", () => {
    expect(AGING_BUCKETS.map((bucket) => bucket.label)).toEqual([
      "Current (not yet due)",
      "1–30 days overdue",
      "31–60 days overdue",
      "61–90 days overdue",
      "Over 90 days overdue",
    ]);
    expect(agingBucketLabel("d31_60")).toBe("31–60 days overdue");
    expect(agingBucketLabel(null)).toBe("—");
  });
});

describe("invoice register arguments", () => {
  it("sends blanks as null so nothing is filtered", () => {
    expect(invoiceRegisterArgs("w1", EMPTY_INVOICE_FILTERS, { limit: 50, offset: 0 })).toEqual({
      p_business_id: "w1",
      p_counterparty_id: null,
      p_status: null,
      p_bucket: null,
      p_invoice_from: null,
      p_invoice_to: null,
      p_due_from: null,
      p_due_to: null,
      p_min_outstanding: null,
      p_max_outstanding: null,
      p_search: null,
      p_limit: 50,
      p_offset: 0,
    });
  });

  it("passes filters through, parsing amounts and ignoring invalid numbers", () => {
    const args = invoiceRegisterArgs(
      "w1",
      {
        ...EMPTY_INVOICE_FILTERS,
        bucket: "d90_plus",
        minOutstanding: "100.50",
        maxOutstanding: "abc",
        search: " ideal ",
      },
      { limit: 25, offset: 50 },
    );
    expect(args).toMatchObject({
      p_bucket: "d90_plus",
      p_min_outstanding: 100.5,
      p_max_outstanding: null,
      p_search: "ideal",
      p_limit: 25,
      p_offset: 50,
    });
  });

  it("knows when any filter is active", () => {
    expect(hasInvoiceFilters(EMPTY_INVOICE_FILTERS)).toBe(false);
    expect(hasInvoiceFilters({ ...EMPTY_INVOICE_FILTERS, search: "  " })).toBe(false);
    expect(hasInvoiceFilters({ ...EMPTY_INVOICE_FILTERS, status: "overdue" })).toBe(true);
  });
});

describe("filter problems", () => {
  it("catches a date range that runs backwards and an amount range with min above max", () => {
    expect(
      invoiceFilterProblem({
        ...EMPTY_INVOICE_FILTERS,
        dueFrom: "2026-10-10",
        dueTo: "2026-10-01",
      }),
    ).toMatch(/Due date/);
    expect(
      invoiceFilterProblem({
        ...EMPTY_INVOICE_FILTERS,
        invoiceFrom: "2026-10-10",
        invoiceTo: "2026-10-01",
      }),
    ).toMatch(/Invoice date/);
    expect(
      invoiceFilterProblem({
        ...EMPTY_INVOICE_FILTERS,
        minOutstanding: "500",
        maxOutstanding: "100",
      }),
    ).toMatch(/minimum is above/);
    expect(
      invoiceFilterProblem({
        ...EMPTY_INVOICE_FILTERS,
        dueFrom: "2026-10-01",
        dueTo: "2026-10-10",
      }),
    ).toBeNull();
  });

  it("describes the filters in force in plain words", () => {
    expect(
      describeInvoiceFilters(
        { ...EMPTY_INVOICE_FILTERS, counterpartyId: "p1", bucket: "d31_60", dueFrom: "2026-09-01" },
        "Good Pharmacy",
      ),
    ).toEqual(["Party: Good Pharmacy", "Aging: 31–60 days overdue", "Due date: 2026-09-01 to …"]);
    expect(describeInvoiceFilters(EMPTY_INVOICE_FILTERS)).toEqual([]);
  });
});

describe("exports", () => {
  it("keeps numbers as numbers, names the counterparty column per side, and states aging in words", () => {
    const wholesaler = invoiceExportSheet([invoice], "wholesaler");
    const pharmacy = invoiceExportSheet([invoice], "pharmacy");
    expect(wholesaler.headers[0]).toBe("Pharmacy");
    expect(pharmacy.headers[0]).toBe("Supplier");
    expect(wholesaler.rows[0]).toHaveLength(wholesaler.headers.length);
    expect(wholesaler.rows[0]).toEqual([
      "Good Pharmacy",
      "ORD-100",
      "2026-08-20",
      "2026-09-19",
      10000,
      8000,
      2000,
      45,
      "31–60 days overdue",
      "Partially paid",
    ]);
  });

  it("exports an aging sheet with all five buckets, zero where nothing is owed", () => {
    const sheet = agingExportSheet([
      { bucket: "d31_60", invoices: "3", outstanding_ghs: "2200.00" },
    ]);
    expect(sheet.rows).toEqual([
      ["Current (not yet due)", 0, 0],
      ["1–30 days overdue", 0, 0],
      ["31–60 days overdue", 3, 2200],
      ["61–90 days overdue", 0, 0],
      ["Over 90 days overdue", 0, 0],
    ]);
  });

  it("exports payments with allocated, unallocated and reversed amounts", () => {
    const payment: PaymentRow = {
      payment_id: "pay1",
      paid_at: "2026-10-02T09:30:00Z",
      counterparty_id: "p1",
      counterparty_name: "Good Pharmacy",
      amount_ghs: "500.00",
      method: "cash",
      reference: "CASH-1",
      notes: null,
      recorded_by_email: "acc@x.test",
      allocated_ghs: "100.00",
      unallocated_ghs: "400.00",
      reversed_ghs: "100.00",
      allocation_count: 1,
      has_proof: false,
      total_count: 1,
    };
    const sheet = paymentExportSheet([payment], "wholesaler");
    expect(sheet.rows[0]).toEqual([
      "2026-10-02",
      "Good Pharmacy",
      "Cash",
      "CASH-1",
      500,
      100,
      400,
      100,
      "acc@x.test",
      "",
    ]);
    expect(sheet.rows[0]).toHaveLength(sheet.headers.length);
  });

  it("builds payment register arguments", () => {
    expect(
      paymentRegisterArgs(
        "w1",
        { counterpartyId: "", method: "cash", from: "2026-10-01", to: "" },
        { limit: 50, offset: 0 },
      ),
    ).toMatchObject({
      p_counterparty_id: null,
      p_method: "cash",
      p_from: "2026-10-01",
      p_to: null,
    });
  });
});
