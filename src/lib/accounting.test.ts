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
  statementArgs,
  statementExportSheets,
  statementFilenameStem,
  statementLineDescription,
  statementPeriodProblem,
  statementPresetRange,
  type CreditStatement,
  type InvoiceRow,
  type PaymentRow,
  type StatementLine,
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

const line = (overrides: Partial<StatementLine>): StatementLine => ({
  date: "2026-09-10",
  entry_type: "invoice",
  order_id: "o1",
  order_number: "ORD-100",
  method: null,
  reference: null,
  note: null,
  reversed_type: null,
  debit: 0,
  credit: 0,
  balance: 0,
  ...overrides,
});

const statement: CreditStatement = {
  side: "wholesaler",
  business: { id: "w1", name: "Alpha Wholesale", city: null, region: null },
  counterparty: { id: "p1", name: "Good Pharmacy", city: null, region: null },
  from: "2026-09-01",
  to: "2026-09-30",
  opening_balance: "500.00",
  total_charges: "300.00",
  total_credits: "200.00",
  closing_balance: "600.00",
  balance_today: "525.00",
  line_count: 2,
  truncated: false,
  aging_as_of: "2026-10-05",
  aging: [{ bucket: "d1_30", invoices: 1, outstanding_ghs: "300.00" }],
  lines: [
    line({ debit: "300.00", balance: "800.00" }),
    line({
      date: "2026-09-12",
      entry_type: "payment",
      order_number: null,
      method: "bank_transfer",
      reference: "BT-1",
      credit: "200.00",
      balance: "600.00",
      note: "Part payment",
    }),
  ],
};

describe("statement line wording", () => {
  it("says what each ledger entry is in plain words", () => {
    expect(statementLineDescription(line({}))).toBe("Invoice — ORD-100");
    expect(
      statementLineDescription(
        line({ entry_type: "payment", method: "cash", reference: "C-1", order_number: "ORD-100" }),
      ),
    ).toBe("Payment (Cash) C-1 — ORD-100");
    expect(statementLineDescription(line({ entry_type: "payment", order_number: null }))).toBe(
      "Payment — on account (not matched to an invoice)",
    );
    expect(
      statementLineDescription(line({ entry_type: "reversal", reversed_type: "payment" })),
    ).toBe("Reversal of payment — ORD-100");
    expect(statementLineDescription(line({ entry_type: "credit_note" }))).toBe(
      "Credit note — ORD-100",
    );
    expect(statementLineDescription(line({ entry_type: "write_off", order_number: null }))).toBe(
      "Write-off",
    );
  });
});

describe("statement requests and periods", () => {
  it("sends the party and the period", () => {
    expect(statementArgs("w1", "p1", "2026-09-01", "2026-09-30")).toEqual({
      p_business_id: "w1",
      p_counterparty_id: "p1",
      p_from: "2026-09-01",
      p_to: "2026-09-30",
    });
  });

  it("catches a missing, backwards or over-long period", () => {
    expect(statementPeriodProblem("", "2026-09-30")).toMatch(/both/);
    expect(statementPeriodProblem("2026-10-01", "2026-09-30")).toMatch(/after/);
    expect(statementPeriodProblem("2015-01-01", "2026-09-30")).toMatch(/five years/);
    expect(statementPeriodProblem("2026-09-30", "2026-09-30")).toBeNull();
    expect(statementPeriodProblem("2026-01-01", "2026-12-31")).toBeNull();
  });

  it("builds the presets from the calendar, including across a year end", () => {
    const today = new Date(2026, 9, 5); // 5 Oct 2026
    expect(statementPresetRange("this_month", today)).toEqual({
      from: "2026-10-01",
      to: "2026-10-05",
    });
    expect(statementPresetRange("last_month", today)).toEqual({
      from: "2026-09-01",
      to: "2026-09-30",
    });
    expect(statementPresetRange("last_90_days", today)).toEqual({
      from: "2026-07-08",
      to: "2026-10-05",
    });
    expect(statementPresetRange("this_year", today)).toEqual({
      from: "2026-01-01",
      to: "2026-10-05",
    });
    const january = new Date(2027, 0, 15);
    expect(statementPresetRange("last_month", january)).toEqual({
      from: "2026-12-01",
      to: "2026-12-31",
    });
  });

  it("names the export file after the party and period", () => {
    expect(statementFilenameStem(statement)).toBe(
      "statement-good-pharmacy-2026-09-01-to-2026-09-30",
    );
  });
});

describe("statement exports", () => {
  it("makes the first sheet a complete statement: opening row, every line, closing row", () => {
    const [sheet] = statementExportSheets(statement);
    expect(sheet.headers).toEqual([
      "Date",
      "Type",
      "Reference",
      "Description",
      "Charges (GHS)",
      "Credits (GHS)",
      "Balance (GHS)",
      "Notes",
    ]);
    expect(sheet.rows).toHaveLength(4);
    expect(sheet.rows[0]).toEqual(["2026-09-01", "Opening balance", "", "", "", "", 500, ""]);
    expect(sheet.rows[1]).toEqual([
      "2026-09-10",
      "Invoice",
      "ORD-100",
      "Invoice — ORD-100",
      300,
      "",
      800,
      "",
    ]);
    expect(sheet.rows[2]).toEqual([
      "2026-09-12",
      "Payment",
      "BT-1",
      "Payment (Bank transfer) BT-1 — on account (not matched to an invoice)",
      "",
      200,
      600,
      "Part payment",
    ]);
    expect(sheet.rows[3]).toEqual(["2026-09-30", "Closing balance", "", "", "", "", 600, ""]);
    for (const row of sheet.rows) expect(row).toHaveLength(sheet.headers.length);
  });

  it("identifies a payment by its own reference even when it is matched to an invoice", () => {
    const [sheet] = statementExportSheets({
      ...statement,
      lines: [
        line({
          entry_type: "payment",
          method: "cash",
          reference: "C-9",
          order_number: "ORD-100",
          credit: "50.00",
          balance: "450.00",
        }),
      ],
    });
    expect(sheet.rows[1][2]).toBe("C-9");
  });

  it("keeps money as numbers and adds a summary and the ageing for Excel and PDF", () => {
    const sheets = statementExportSheets(statement);
    expect(sheets.map((sheet) => sheet.name)).toEqual([
      "Statement",
      "Summary",
      "Aging as of 2026-10-05",
    ]);
    expect(sheets[1].rows).toContainEqual(["Closing balance (GHS)", 600]);
    expect(sheets[1].rows).toContainEqual(["Balance today (GHS)", 525]);
    expect(sheets[1].rows).toContainEqual(["Charges in period (GHS)", 300]);
    expect(sheets[2].rows[1]).toEqual(["1–30 days overdue", 1, 300]);
  });

  it("says so in the closing row and the summary when the statement was cut short", () => {
    const cut = { ...statement, truncated: true, line_count: 2500 };
    const sheets = statementExportSheets(cut);
    const closing = sheets[0].rows[sheets[0].rows.length - 1];
    expect(String(closing[7])).toMatch(/first 2 of 2500 lines/);
    expect(sheets[1].rows.some((row) => row[0] === "Note")).toBe(true);
  });

  it("shows the supplier on the pharmacy side", () => {
    const sheets = statementExportSheets({ ...statement, side: "pharmacy" });
    expect(sheets[1].rows[1][0]).toBe("Supplier");
  });
});
